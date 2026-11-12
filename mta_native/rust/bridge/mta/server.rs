//! MTA 发送端 TLS 服务器。
//!
//! 基于 `tokio-rustls` + `hyper`，单个 TLS 端口同时承载：
//! - `GET /websocket`（带 `Upgrade: websocket`）：升级后交由 [`crate::bridge::mta::ws`] 执行状态机；
//! - `GET /download?taskId=<id>`：按文件清单流式生成 ZIP（条目恒 `Deflated`、chunked、无 `Content-Length`）
//!   写入响应体并上报发送进度。
//!
//! 服务端证书在启动时用核心 `rcgen` 运行时生成（不落盘、不入库）。

use std::convert::Infallible;
use std::io::Write;
use std::pin::Pin;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use tokio::io::AsyncRead;
use tokio::net::TcpListener;
use tokio::sync::watch;
use tokio_rustls::rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio_rustls::rustls::ServerConfig;
use tokio_rustls::TlsAcceptor;

use crate::bridge::event::{send_event, BridgeEvent};
use crate::bridge::mta::zip_stream;
use crate::bridge::mta::{ws, DownloadPhase, MtaContext};

/// 进度上报节流间隔
const PROGRESS_INTERVAL: Duration = Duration::from_millis(200);
/// 响应体分块通道容量（块）
const BODY_CHANNEL_CAPACITY: usize = 8;
/// 发送诊断日志最小输出间隔（约 1 s）
const DIAG_LOG_INTERVAL: Duration = Duration::from_secs(1);
/// 字节速率换算用的每 MiB
const BYTES_PER_MIB: f64 = 1024.0 * 1024.0;

/// 响应体类型（统一装箱，便于在同一路由返回空体与流式体）。
type BoxBody = http_body_util::combinators::BoxBody<Bytes, std::io::Error>;

/// 用运行时生成的自签名证书构造 rustls 服务端配置。
pub fn build_tls_config() -> anyhow::Result<Arc<ServerConfig>> {
    let cert = localsend::crypto::cert::generate_self_signed()?;
    let certs: Vec<CertificateDer<'static>> = {
        let mut reader = std::io::BufReader::new(cert.certificate_pem.as_bytes());
        rustls_pemfile::certs(&mut reader)?
            .into_iter()
            .map(CertificateDer::from)
            .collect()
    };
    if certs.is_empty() {
        anyhow::bail!("自签名证书为空");
    }
    let key: PrivateKeyDer<'static> = {
        let mut reader = std::io::BufReader::new(cert.private_key_pem.as_bytes());
        let mut keys = rustls_pemfile::pkcs8_private_keys(&mut reader)?;
        if keys.is_empty() {
            anyhow::bail!("自签名证书未包含 PKCS#8 私钥");
        }
        PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(keys.remove(0)))
    };
    let config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)?;
    Ok(Arc::new(config))
}

/// 接受 TLS 连接并逐个升级为 HTTP/1 连接（支持 upgrade），直到任务被 abort
/// 或取消令牌触发。
pub async fn run_server(
    listener: TcpListener,
    tls_config: Arc<ServerConfig>,
    ctx: Arc<MtaContext>,
) {
    let acceptor = TlsAcceptor::from(tls_config);
    loop {
        let (stream, peer) = tokio::select! {
            biased;
            _ = ctx.cancel.cancelled() => {
                log::debug!("MTA accept 循环收到取消，退出");
                return;
            }
            accepted = listener.accept() => match accepted {
                Ok(pair) => pair,
                Err(e) => {
                    log::warn!("MTA accept 失败: {e}");
                    continue;
                }
            },
        };
        log::debug!("MTA 接收到连接: {peer}");
        // 传输 WS 小控制帧时避免 Nagle 算法引入额外延迟（低风险，不改变 HTTP/协议行为）
        if let Err(e) = stream.set_nodelay(true) {
            log::debug!("MTA 设置 TCP_NODELAY 失败 ({peer}): {e}");
        }
        let acceptor = acceptor.clone();
        let conn_ctx = Arc::clone(&ctx);
        tokio::spawn(async move {
            // TLS 握手 + 连接服务全程感知取消：stop_server 时连接
            // future 被 drop，底层 TLS/TCP 流随之关闭，下载立即截断
            tokio::select! {
                biased;
                _ = conn_ctx.cancel.cancelled() => {
                    log::debug!("MTA 连接任务收到取消，关闭连接 peer={peer}");
                }
                result = async {
                    match acceptor.accept(stream).await {
                        Ok(tls_stream) => serve_connection(tls_stream, conn_ctx.clone()).await,
                        Err(e) => log::warn!("MTA TLS 握手失败 ({peer}): {e}"),
                    }
                } => result,
            }
        });
    }
}

/// 在单个 TLS 连接上提供 HTTP/1 服务（开启 upgrade 支持）。
async fn serve_connection<S>(stream: S, ctx: Arc<MtaContext>)
where
    S: AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    let io = TokioIo::new(stream);
    let service = service_fn(move |req: Request<Incoming>| {
        let req_ctx = Arc::clone(&ctx);
        async move { handle(req, req_ctx).await }
    });
    if let Err(e) = hyper::server::conn::http1::Builder::new()
        .serve_connection(io, service)
        .with_upgrades()
        .await
    {
        // 对端/网络拆除时，优雅关闭底层 IO 可能失败（hyper Kind::Shutdown），
        // 属正常收尾而非传输故障，仅以 trace 记录，避免发送页日志出现误导性错误。
        if e.is_shutdown() {
            log::debug!("MTA 连接收尾: {e}");
        } else {
            log::debug!("MTA 连接结束: {e}");
        }
    }
}

/// 路由分发。
async fn handle(
    req: Request<Incoming>,
    ctx: Arc<MtaContext>,
) -> Result<Response<BoxBody>, Infallible> {
    let path = req.uri().path();
    match path {
        "/websocket" => Ok(handle_websocket(req, ctx).await),
        "/download" => Ok(handle_download(req, ctx).await),
        "/thumbnail" => Ok(handle_thumbnail(req, ctx).await),
        _ => Ok(text_response(StatusCode::NOT_FOUND, "未知路径")),
    }
}

/// `/websocket`：完成握手响应并把升级后的连接交给 WS 状态机。
async fn handle_websocket(req: Request<Incoming>, ctx: Arc<MtaContext>) -> Response<BoxBody> {
    // RFC 6455 握手要求：Upgrade 头须为 websocket、Connection 须含 upgrade，
    // 只校验 Sec-WebSocket-Key 会放过非升级请求（其对端行为不可预期）
    let upgrade_ok = req
        .headers()
        .get("upgrade")
        .and_then(|v| v.to_str().ok())
        .map(|v| v.eq_ignore_ascii_case("websocket"))
        .unwrap_or(false);
    let connection_ok = req
        .headers()
        .get("connection")
        .and_then(|v| v.to_str().ok())
        .map(|v| {
            v.to_ascii_lowercase()
                .split(',')
                .any(|t| t.trim() == "upgrade")
        })
        .unwrap_or(false);
    if !upgrade_ok || !connection_ok {
        return text_response(StatusCode::BAD_REQUEST, "缺少 Upgrade/Connection 升级头");
    }
    let key = match req.headers().get("sec-websocket-key") {
        Some(value) => value.as_bytes().to_vec(),
        None => return text_response(StatusCode::BAD_REQUEST, "缺少 Sec-WebSocket-Key"),
    };
    let accept = tokio_tungstenite::tungstenite::handshake::derive_accept_key(&key);
    let upgrade_ctx = Arc::clone(&ctx);
    tokio::spawn(async move {
        match hyper::upgrade::on(req).await {
            Ok(upgraded) => {
                log::debug!("MTA WS 升级成功");
                let io = TokioIo::new(upgraded);
                ws::run_ws(io, upgrade_ctx).await;
            }
            Err(e) => {
                // 已有活跃 WS 连接时，本次升级失败来自第三方连接（如对端
                // 只发握手即断开），不能据此判死进行中的发送会话——
                // 与 run_ws 的单连接守卫语义保持一致
                if upgrade_ctx.ws_connected.load(Ordering::SeqCst) {
                    log::warn!("MTA WS 升级失败（已有活跃连接，忽略）: {e}");
                } else {
                    send_event(
                        &upgrade_ctx.event_tx,
                        BridgeEvent::MtaSendFailed {
                            reason: format!("WebSocket 升级失败: {e}"),
                        },
                    )
                    .await;
                }
            }
        }
    });
    Response::builder()
        .status(StatusCode::SWITCHING_PROTOCOLS)
        .header("connection", "Upgrade")
        .header("upgrade", "websocket")
        .header("sec-websocket-accept", accept)
        .body(empty_body())
        .unwrap_or_else(|_| text_response(StatusCode::INTERNAL_SERVER_ERROR, "构造升级响应失败"))
}

/// `/thumbnail?taskId=`：返回发送端预览缩略图（JPEG）。
///
/// 缩略图在起服时一次性读入内存（`MtaContext.thumbnail`），此处只做定长响应；
/// 未提供或 taskId 不匹配一律 404，对端据此按「无预览」处理。与 `/download` 相互独立：
/// 对端在确认阶段先取缩略图、后下载，故此处不消费 `download_served`。
async fn handle_thumbnail(req: Request<Incoming>, ctx: Arc<MtaContext>) -> Response<BoxBody> {
    let task_id = query_param(req.uri().query().unwrap_or(""), "taskId");
    build_thumbnail_response(&ctx, task_id.as_deref())
}

/// 构造缩略图响应：taskId 不匹配或本次未提供缩略图时返回 404（定长 JPEG 响应）。
fn build_thumbnail_response(ctx: &MtaContext, task_id: Option<&str>) -> Response<BoxBody> {
    if task_id != Some(ctx.task_id.as_str()) {
        log::warn!(
            "MTA 缩略图 taskId 不匹配 期望={} 实际={:?}",
            ctx.task_id,
            task_id
        );
        return text_response(StatusCode::NOT_FOUND, "taskId 不匹配");
    }
    match &ctx.thumbnail {
        Some(thumbnail) => {
            log::debug!(
                "MTA 缩略图请求命中 taskId={} 尺寸={}x{} 字节={}",
                ctx.task_id,
                thumbnail.width,
                thumbnail.height,
                thumbnail.bytes.len()
            );
            Response::builder()
                .status(StatusCode::OK)
                .header("content-type", "image/jpeg")
                .header("content-length", thumbnail.bytes.len().to_string())
                .header("connection", "close")
                .body(full_body(Bytes::from(thumbnail.bytes.clone())))
                .unwrap_or_else(|_| {
                    text_response(StatusCode::INTERNAL_SERVER_ERROR, "构造缩略图响应失败")
                })
        }
        None => {
            log::debug!("MTA 缩略图请求但本次未提供 taskId={}", ctx.task_id);
            text_response(StatusCode::NOT_FOUND, "未提供缩略图")
        }
    }
}

/// `/download?taskId=`：校验任务并构造流式下载响应。
async fn handle_download(req: Request<Incoming>, ctx: Arc<MtaContext>) -> Response<BoxBody> {
    let task_id = query_param(req.uri().query().unwrap_or(""), "taskId");
    let (response, _diag) = build_download_response(&ctx, task_id.as_deref()).await;
    response
}

/// 构造下载响应。
///
/// 响应体按文件清单流式生成 ZIP（所有条目恒 `Deflated`，见 `zip_stream`），采用 chunked
/// （不设 `Content-Length`）。一次性下载使用 `Connection: close`：让对端在接收完 ZIP
/// 后立即关闭连接，避免 keep-alive 连接在服务器/群组拆除时被强制中断、触发 shutdown
/// 错误。发送 fd 所有权单次移交：接管时才逐条目登记消费（`write_zip_stream_with_take`），
/// 中途失败时其后未接管的 fd 仍由 `stop_server` 统一收尾；重复下载请求直接拒绝。
///
/// 返回响应与发送诊断句柄：诊断句柄供测试读取出网终值，生产路径直接丢弃即可
/// （计数状态由源读取闭包与响应体持有的克隆维持）。
async fn build_download_response(
    ctx: &MtaContext,
    task_id: Option<&str>,
) -> (Response<BoxBody>, Option<SharedSendDiagnostics>) {
    if task_id != Some(ctx.task_id.as_str()) {
        log::warn!(
            "MTA 下载 taskId 不匹配 期望={} 实际={:?}",
            ctx.task_id,
            task_id
        );
        return (text_response(StatusCode::NOT_FOUND, "taskId 不匹配"), None);
    }
    // fd 所有权单次移交：已构造过下载响应即拒绝，防止重复 from_raw_fd 双关
    if ctx.download_served.swap(true, Ordering::SeqCst) {
        log::warn!("MTA 重复下载请求被拒绝 taskId={}", ctx.task_id);
        return (text_response(StatusCode::CONFLICT, "下载已消费"), None);
    }

    // 通知 WS 状态机下载已开始
    log::debug!(
        "MTA 下载开始 taskId={} 文件数={} 源总字节={}",
        ctx.task_id,
        ctx.file_count,
        ctx.total_size
    );
    ctx.phase_tx.send_replace(DownloadPhase::Started);

    let (tx, rx) =
        tokio::sync::mpsc::channel::<Result<Bytes, std::io::Error>>(BODY_CHANNEL_CAPACITY);
    // 条目清单（fd/路径/声明大小/修改时间）直接用于写出，CRC 由写出库自动计算
    let files = ctx.files.clone();
    // 发送诊断：源读取与出网两路速率（源读取线程与 hyper 连接任务并发写入）。
    // 进度上报同时读取其出网累计（网络字节口径），故先于上报器创建。
    let diag = Arc::new(std::sync::Mutex::new(SendDiagnostics::new(&ctx.task_id)));
    let reporter = ProgressReporter {
        event_tx: ctx.event_tx.clone(),
        phase_tx: ctx.phase_tx.clone(),
        task_id: ctx.task_id.clone(),
        total: ctx.total_size,
        last_report: Instant::now(),
        logged_milestone: 0,
        net: Arc::clone(&diag),
    };
    let source_diag = Arc::clone(&diag);
    // fd 消费登记：接管第 i 个条目的 fd 前置位 fds_consumed[i]，
    // 使中途失败时其后未接管的 fd 仍可由 stop_server 的收尾路径关闭（防泄漏）
    let fds_consumed = Arc::clone(&ctx.fds_consumed);
    // ZIP 生成与源文件读取为阻塞操作，走 spawn_blocking 避免占死 tokio worker
    tokio::task::spawn_blocking(move || {
        let mut writer = ChannelWriter { tx };
        let mut reporter = reporter;
        match zip_stream::write_zip_stream_with_take(
            &mut writer,
            &files,
            |sent| {
                reporter.on_source_bytes(sent);
                // 源读取字节接入发送诊断；锁异常静默降级，不影响传输主流程
                if let Ok(mut diag) = source_diag.lock() {
                    diag.record_source(sent);
                }
            },
            |entry_index| {
                // 在互斥临界区内完成「检查 + 登记」，与停止路径的「检查 + 关闭」互斥：
                // 已被停止路径关闭时返回 false，调用方不再 from_raw_fd，避免双关
                match fds_consumed.lock() {
                    Ok(mut consumed) => {
                        if let Some(flag) = consumed.get_mut(entry_index) {
                            if *flag {
                                return false;
                            }
                            *flag = true;
                            return true;
                        }
                        // 索引越界（不应发生）：按接管成功继续，fd 由 File 关闭
                        true
                    }
                    // 锁中毒：已无兜底关闭路径，按接管成功继续，fd 由 File 关闭
                    Err(_) => true,
                }
            },
        ) {
            Ok(result) => {
                if let Ok(mut diag) = source_diag.lock() {
                    diag.record_outcome("成功");
                }
                reporter.complete(result.total_size);
            }
            Err(e) if is_peer_disconnect_error(&e) => {
                // 对端中途取消：下载连接断开导致写出失败。
                // 置下载阶段为 PeerAborted，供 WS 状态机立即终结本次发送，
                // 不再等待对端 status（否则将空等到状态等待超时）。
                log::warn!("MTA 下载被对端中止 taskId={}: {e:#}", reporter.task_id);
                if let Ok(mut diag) = source_diag.lock() {
                    diag.record_outcome("中止");
                }
                reporter.peer_aborted();
            }
            Err(e) => {
                // 读取失败/取消等其他错误：不挂起，直接结束响应体（连接随之收尾）
                log::warn!("MTA 流式生成 ZIP 失败 taskId={}: {e:#}", reporter.task_id);
                let _ = writer.tx.blocking_send(Err(std::io::Error::other(e.to_string())));
                reporter.peer_aborted();
                if let Ok(mut diag) = source_diag.lock() {
                    diag.record_outcome("失败");
                }
            }
        }
    });

    let safe_name: String = ctx
        .file_name
        .chars()
        .map(|c| {
            if c == '"' || c == '\r' || c == '\n' || c.is_control() || c == '/' || c == '\\' {
                '_'
            } else {
                c
            }
        })
        .collect();
    let response = Response::builder()
        .status(StatusCode::OK)
        .header("content-type", "application/zip")
        .header("connection", "close")
        .header(
            "content-disposition",
            format!("attachment; filename=\"{safe_name}\""),
        )
        .body(
            ZipStreamBody {
                rx,
                diag: Arc::clone(&diag),
                phase_tx: ctx.phase_tx.clone(),
                last_activity: Instant::now(),
            }
            .boxed(),
        )
        .unwrap_or_else(|_| text_response(StatusCode::INTERNAL_SERVER_ERROR, "构造下载响应失败"));
    (response, Some(diag))
}

/// 流式 ZIP 响应体：从生产者任务按块接收 ZIP 字节，长度未知（chunked）。
///
/// 持共享发送诊断句柄：数据帧在此计量「出网」字节（hyper 从本结构取走响应体字节
/// 并写入连接，是字节真正离开进程的观测点），EOF/错误时输出终态汇总。
struct ZipStreamBody {
    rx: tokio::sync::mpsc::Receiver<Result<Bytes, std::io::Error>>,
    /// 共享发送诊断（出网计量与终态汇总）
    diag: SharedSendDiagnostics,
    phase_tx: watch::Sender<DownloadPhase>,
    last_activity: Instant,
}

impl http_body::Body for ZipStreamBody {
    type Data = Bytes;
    type Error = std::io::Error;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<http_body::Frame<Bytes>, std::io::Error>>> {
        let this = self.get_mut();
        match this.rx.poll_recv(cx) {
            Poll::Ready(Some(Ok(chunk))) => {
                // 数据帧即出网字节：累计并节流输出；锁异常静默降级，不影响传输主流程
                let frame_len = chunk.len() as u64;
                let now = Instant::now();
                if frame_len > 0 && now.duration_since(this.last_activity) >= Duration::from_secs(1) {
                    this.last_activity = now;
                    this.phase_tx.send_if_modified(|phase| *phase == DownloadPhase::Started);
                }
                if let Ok(mut diag) = this.diag.lock() {
                    diag.record_net(frame_len);
                }
                Poll::Ready(Some(Ok(http_body::Frame::data(chunk))))
            }
            Poll::Ready(Some(Err(e))) => {
                // 响应体以错误中止：输出截至此刻的发送汇总
                if let Ok(diag) = this.diag.lock() {
                    diag.summary("中止");
                }
                Poll::Ready(Some(Err(e)))
            }
            Poll::Ready(None) => {
                // EOF：源读取必然已结束（生产端已随 write_zip_stream 返回而关闭通道），
                // 此刻两路终值均完整；汇总采用源读取任务登记的真实结局
                //（因对端断开而关闭通道时，不能一律记为成功）
                if let Ok(mut diag) = this.diag.lock() {
                    let outcome = diag.take_outcome("成功");
                    diag.summary(&outcome);
                }
                Poll::Ready(None)
            }
            Poll::Pending => Poll::Pending,
        }
    }

    fn size_hint(&self) -> http_body::SizeHint {
        // 长度未知 → hyper 使用分块传输编码
        http_body::SizeHint::default()
    }
}

/// 把写出的 ZIP 字节块送入响应体通道；对端断开时返回写入错误以上游停止生成。
struct ChannelWriter {
    tx: tokio::sync::mpsc::Sender<Result<Bytes, std::io::Error>>,
}

impl Write for ChannelWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let chunk = Bytes::copy_from_slice(buf);
        self.tx
            .blocking_send(Ok(chunk))
            .map_err(|_| std::io::Error::new(std::io::ErrorKind::BrokenPipe, "下载连接已关闭"))?;
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// 发送进度上报：按时间节流上报"已读源字节"，结束时无条件上报终值。
///
/// 每次上报同时携带出网字节累计（网络字节口径），供展示层以网络速率呈现；
/// 出网计数由响应体帧消费侧（[`ZipStreamBody::poll_frame`]）写入，本结构与解析
/// 写出线程通过共享诊断句柄读取。
struct ProgressReporter {
    event_tx: Option<tokio::sync::mpsc::Sender<BridgeEvent>>,
    phase_tx: watch::Sender<DownloadPhase>,
    task_id: String,
    total: u64,
    last_report: Instant,
    /// 已记录的下载进度里程碑（25% 步进），避免逐块刷屏
    logged_milestone: u32,
    /// 共享发送诊断（读取累计出网字节）
    net: SharedSendDiagnostics,
}

impl ProgressReporter {
    /// 条目数据写出过程中回调（节流）。
    fn on_source_bytes(&mut self, sent: u64) {
        let now = Instant::now();
        if now.duration_since(self.last_report) < PROGRESS_INTERVAL {
            return;
        }
        self.last_report = now;
        self.report(sent, false);
    }

    /// 结束：无条件上报终值。
    fn complete(&mut self, sent: u64) {
        self.report(sent, true);
    }

    /// 对端断开/中止下载连接：置下载阶段为 PeerAborted，供 WS 状态机立即收尾。
    fn peer_aborted(&self) {
        self.phase_tx.send_replace(DownloadPhase::PeerAborted);
    }

    /// 上报一次进度并记录 25% 里程碑。
    fn report(&mut self, sent: u64, finished: bool) {
        let percent = if self.total > 0 {
            sent as f64 / self.total as f64 * 100.0
        } else {
            0.0
        };
        // 出网字节：进度事件与诊断共用同一计数器；锁异常静默降级为 0，不影响传输主流程
        let network_bytes = self.net.lock().map(|diag| diag.net_total()).unwrap_or(0);
        if let Some(tx) = &self.event_tx {
            let _ = tx.try_send(BridgeEvent::MtaSendProgress {
                sent_bytes: sent,
                total_bytes: self.total,
                percent,
                network_bytes,
            });
        }
        let milestone = (percent / 25.0) as u32 * 25;
        if finished || milestone > self.logged_milestone {
            self.logged_milestone = milestone;
            log::debug!(
                "MTA 发送进度 taskId={} sent={} total={} 出网={} percent={:.1}",
                self.task_id,
                sent,
                self.total,
                network_bytes,
                percent
            );
        }
    }
}

/// 共享发送诊断句柄：源读取线程与 hyper 连接任务并发写入，内部互斥锁串行化
type SharedSendDiagnostics = Arc<std::sync::Mutex<SendDiagnostics>>;

/// 发送过程诊断：两路速率（源读取 / 出网）与终态汇总。
///
/// 「源读取」为 ZIP 生成流程消费源文件字节的速率（spawn_blocking 线程回调），
/// 「出网」为响应体数据帧实际交给 hyper 写连接的速率（[`ZipStreamBody::poll_frame`]），
/// 两路速率差用于判别「源读取慢」还是「网络慢」。仅在 [`DIAG_LOG_INTERVAL`]
/// 节流下输出 debug 级日志，计数不参与传输决策。
struct SendDiagnostics {
    /// 会话标识（输出到每条日志，供按会话过滤）
    task_id: String,
    /// 下载开始时刻（汇总耗时基准）
    started: Instant,
    /// 上次输出周期日志的时刻
    last_log: Instant,
    /// 累计源读取字节
    source_total: u64,
    /// 累计出网字节
    net_total: u64,
    /// 上次输出时的累计源读取字节（瞬时速率基准）
    last_source: u64,
    /// 上次输出时的累计出网字节（瞬时速率基准）
    last_net: u64,
    /// 源读取任务登记的真实结局（"成功"/"中止"/"失败"）：响应体 EOF 汇总采用，
    /// 避免「blocking 任务出错后仅 drop 通道」被误记为成功
    final_outcome: Option<String>,
}

impl SendDiagnostics {
    fn new(task_id: &str) -> Self {
        let now = Instant::now();
        SendDiagnostics {
            task_id: task_id.to_string(),
            started: now,
            last_log: now,
            source_total: 0,
            net_total: 0,
            last_source: 0,
            last_net: 0,
            final_outcome: None,
        }
    }

    /// 源读取任务结束时登记真实结局（供响应体 EOF 汇总采用）。
    fn record_outcome(&mut self, outcome: &str) {
        self.final_outcome = Some(outcome.to_string());
    }

    /// 取出已登记的结局（未登记/已取时回退给定默认值）。
    fn take_outcome(&mut self, fallback: &str) -> String {
        self.final_outcome
            .take()
            .unwrap_or_else(|| fallback.to_string())
    }

    /// 源读取回调：更新累计源读取字节，达到节流间隔时输出一次两路速率。
    fn record_source(&mut self, sent: u64) {
        self.source_total = sent;
        self.maybe_log();
    }

    /// 出网回调：累计响应体数据帧字节，达到节流间隔时输出一次两路速率。
    fn record_net(&mut self, len: u64) {
        self.net_total += len;
        self.maybe_log();
    }

    /// 当前累计出网字节（供进度事件上报网络字节口径，用于速率展示）。
    fn net_total(&self) -> u64 {
        self.net_total
    }

    /// 距上次输出达到节流间隔时，输出一次两路瞬时速率与累计值（debug 级）。
    fn maybe_log(&mut self) {
        let now = Instant::now();
        let elapsed = now.duration_since(self.last_log);
        if elapsed < DIAG_LOG_INTERVAL {
            return;
        }
        let secs = elapsed.as_secs_f64();
        log::debug!(
            "MTA 发送速率 taskId={} 源读取={:.1}MiB/s 出网={:.1}MiB/s 源累计={}B 出网累计={}B 平均={:.1}MiB/s",
            self.task_id,
            lane_rate(self.source_total, self.last_source, secs),
            lane_rate(self.net_total, self.last_net, secs),
            self.source_total,
            self.net_total,
            average_rate(
                self.source_total,
                now.duration_since(self.started).as_secs_f64()
            ),
        );
        self.last_log = now;
        self.last_source = self.source_total;
        self.last_net = self.net_total;
    }

    /// 终态汇总：输出总耗时、两路总字节与源读取平均速率（debug 级）。
    fn summary(&self, outcome: &str) {
        let secs = self.started.elapsed().as_secs_f64();
        log::debug!(
            "MTA 发送汇总({outcome}) taskId={} 耗时={:.2}s 源读取={}B 出网={}B 平均速率={:.1}MiB/s",
            self.task_id,
            secs,
            self.source_total,
            self.net_total,
            average_rate(self.source_total, secs),
        );
    }
}

/// 计算单路区间速率（MiB/s）：字节差 ÷ 时间差 ÷ MiB；时间差非正或计数回退时返回 0。
fn lane_rate(current: u64, last: u64, secs: f64) -> f64 {
    if secs > 0.0 {
        (current.saturating_sub(last)) as f64 / secs / BYTES_PER_MIB
    } else {
        0.0
    }
}

/// 计算全程平均速率（MiB/s）：总字节 ÷ 总耗时 ÷ MiB；耗时非正时返回 0。
fn average_rate(total: u64, secs: f64) -> f64 {
    if secs > 0.0 {
        total as f64 / secs / BYTES_PER_MIB
    } else {
        0.0
    }
}

/// 判断流式写出错误是否源于对端断开/中止下载连接。
///
/// 写入响应体通道时对端断开会使 [`ChannelWriter::write`] 返回 `BrokenPipe`；
/// 沿错误链查找 `std::io::Error` 并比对断连类错误码，避免把源文件读取失败
/// 等本端错误也误判为对端取消。
fn is_peer_disconnect_error(err: &anyhow::Error) -> bool {
    for cause in err.chain() {
        if let Some(io_err) = cause.downcast_ref::<std::io::Error>() {
            if matches!(
                io_err.kind(),
                std::io::ErrorKind::BrokenPipe
                    | std::io::ErrorKind::ConnectionReset
                    | std::io::ErrorKind::ConnectionAborted
            ) {
                return true;
            }
        }
    }
    false
}

/// 构造空体响应。
fn empty_body() -> BoxBody {
    full_body(Bytes::new())
}

/// 构造指定字节的完整响应体。
fn full_body(bytes: Bytes) -> BoxBody {
    Full::new(bytes).map_err(std::io::Error::other).boxed()
}

/// 文本响应。
fn text_response(status: StatusCode, message: &str) -> Response<BoxBody> {
    Response::builder()
        .status(status)
        .header("content-type", "text/plain; charset=utf-8")
        .body(full_body(Bytes::from(message.to_string())))
        .unwrap_or_else(|_| Response::new(empty_body()))
}

/// 解析查询参数（第一个匹配项，百分号解码失败时回退原文）。
fn query_param(query: &str, key: &str) -> Option<String> {
    for pair in query.split('&') {
        if let Some((k, v)) = pair.split_once('=') {
            if k == key {
                return Some(percent_decode(v));
            }
        } else if pair == key {
            return Some(String::new());
        }
    }
    None
}

/// 百分号解码（非法序列保留原文，避免匹配失败）。
fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && bytes[i + 1].is_ascii_hexdigit()
            && bytes[i + 2].is_ascii_hexdigit()
        {
            let hex = &s[i + 1..i + 3];
            if let Ok(b) = u8::from_str_radix(hex, 16) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| s.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bridge::mta::zip_stream::MtaFileEntry;
    use crate::bridge::mta::MtaThumbnail;
    use std::sync::atomic::{AtomicBool, AtomicUsize};

    /// 构造一个最小可用的 MtaContext（持单条源文件清单；size 按实际文件大小回填，
    /// 与 ArkTS statSync 语义一致）。
    fn test_ctx(task_id: &str, files: Vec<MtaFileEntry>, total_size: u64) -> MtaContext {
        let (phase_tx, _phase_rx) = watch::channel(DownloadPhase::Idle);
        let file_count = files.len();
        MtaContext {
            task_id: task_id.to_string(),
            sender_id: "s1".to_string(),
            sender_name: "tester".to_string(),
            files,
            file_name: "a.txt".to_string(),
            mime_type: "application/zip".to_string(),
            thumbnail: None,
            file_count,
            total_size,
            text_content: None,
            sender_brand_id: None,
            sender_brand: None,
            event_tx: None,
            phase_tx,
            ws_connected: AtomicBool::new(false),
            cancel: tokio_util::sync::CancellationToken::new(),
            fds_consumed: Arc::new(std::sync::Mutex::new(vec![false; file_count])),
            download_served: AtomicBool::new(false),
            peer_frames: AtomicUsize::new(0),
            reject_pending: AtomicBool::new(false),
            reject_notify: tokio::sync::Notify::new(),
        }
    }

    /// 下载响应应为 chunked（无 Content-Length）并显式声明 Connection: close，
    /// 且响应体是可按标准读取器解开的 ZIP。
    #[tokio::test]
    async fn download_response_streams_valid_chunked_zip() {
        let dir = std::env::temp_dir().join(format!("mta_server_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let source = dir.join("a.txt");
        std::fs::write(&source, b"hello server").unwrap();
        let files = vec![MtaFileEntry {
            fd_send: -1,
            path: source.to_string_lossy().to_string(),
            entry_name: "1/a.txt".into(),
            last_modified_ms: None,
            size_bytes: b"hello server".len() as u64,
        }];
        let ctx = test_ctx("task-1", files, 12);

        let (resp, diag) = build_download_response(&ctx, Some("task-1")).await;
        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(resp.headers().get("connection").unwrap(), "close");
        assert_eq!(
            resp.headers().get("content-type").unwrap(),
            "application/zip"
        );
        assert!(resp.headers().get("content-length").is_none());

        let body = resp.into_body().collect().await.unwrap().to_bytes();
        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(body.to_vec())).unwrap();
        assert_eq!(archive.len(), 1);
        let mut entry = archive.by_index(0).unwrap();
        assert_eq!(entry.name(), "1/a.txt");
        let mut content = String::new();
        use std::io::Read as _;
        entry.read_to_string(&mut content).unwrap();
        assert_eq!(content, "hello server");

        // 出网终值应等于响应体总字节（响应体即完整 ZIP）
        let diag = diag.expect("taskId 匹配时应返回诊断句柄");
        assert_eq!(diag.lock().unwrap().net_total, body.len() as u64);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// taskId 不匹配时应返回 404，且不启动流式生成。
    #[tokio::test]
    async fn download_response_rejects_mismatched_task() {
        let dir = std::env::temp_dir().join(format!("mta_server_test_bad_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let source = dir.join("a.txt");
        std::fs::write(&source, b"x").unwrap();
        let files = vec![MtaFileEntry {
            fd_send: -1,
            path: source.to_string_lossy().to_string(),
            entry_name: "1/a.txt".into(),
            last_modified_ms: None,
            size_bytes: 0,
        }];
        let ctx = test_ctx("task-1", files, 1);

        let (resp, diag) = build_download_response(&ctx, Some("other")).await;
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
        assert!(diag.is_none(), "taskId 不匹配时不应创建诊断句柄");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 缩略图响应应为定长 JPEG（显式 Content-Length），且与下载路径互不影响。
    #[tokio::test]
    async fn thumbnail_response_serves_fixed_length_jpeg() {
        let mut ctx = test_ctx("task-thumb", vec![], 0);
        let jpeg: Vec<u8> = vec![0xFF, 0xD8, 0xFF, 0xD9];
        ctx.thumbnail = Some(MtaThumbnail {
            bytes: jpeg.clone(),
            width: 240,
            height: 320,
        });

        let resp = build_thumbnail_response(&ctx, Some("task-thumb"));
        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(resp.headers().get("content-type").unwrap(), "image/jpeg");
        assert_eq!(
            resp.headers().get("content-length").unwrap(),
            jpeg.len().to_string().as_str()
        );
        assert_eq!(resp.headers().get("connection").unwrap(), "close");
        let body = resp.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(body.to_vec(), jpeg);

        // 缩略图请求不消费下载：同一会话仍可正常构造下载响应
        assert!(
            !ctx.download_served.load(Ordering::SeqCst),
            "缩略图请求不得占用下载名额"
        );
    }

    /// 未提供缩略图时返回 404（对端据此按无预览处理，不影响后续下载）。
    #[tokio::test]
    async fn thumbnail_response_404_when_not_provided() {
        let ctx = test_ctx("task-thumb2", vec![], 0);
        let resp = build_thumbnail_response(&ctx, Some("task-thumb2"));
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }

    /// taskId 不匹配时返回 404。
    #[tokio::test]
    async fn thumbnail_response_rejects_mismatched_task() {
        let ctx = test_ctx("task-thumb3", vec![], 0);
        let resp = build_thumbnail_response(&ctx, Some("other"));
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }

    /// 断连类 io 错误应被识别为对端断开，本端读取类错误不误判。
    #[test]
    fn detects_peer_disconnect_errors_only() {
        let broken = anyhow::Error::new(std::io::Error::new(
            std::io::ErrorKind::BrokenPipe,
            "下载连接已关闭",
        ));
        assert!(is_peer_disconnect_error(&broken));
        let reset = anyhow::Error::new(std::io::Error::new(
            std::io::ErrorKind::ConnectionReset,
            "reset",
        ));
        assert!(is_peer_disconnect_error(&reset));
        // 源文件读取失败等本端错误不应被当作对端取消
        assert!(!is_peer_disconnect_error(&anyhow::anyhow!(
            "读取待发送文件失败"
        )));
    }

    /// 节流窗口内回调应静默：速率基准不变，累计值持续更新。
    #[test]
    fn send_diag_stays_silent_within_throttle_window() {
        let mut diag = SendDiagnostics::new("t-throttle");
        let initial_log = diag.last_log;
        diag.record_source(512);
        diag.record_net(256);
        assert_eq!(diag.last_log, initial_log, "节流窗口内不应刷新输出基准");
        assert_eq!(diag.last_source, 0);
        assert_eq!(diag.last_net, 0);
        // 累计值不受节流影响
        assert_eq!(diag.source_total, 512);
        assert_eq!(diag.net_total, 256);
    }

    /// 达到节流间隔后的回调应刷新两路速率基准。
    #[test]
    fn send_diag_updates_baselines_after_interval() {
        let mut diag = SendDiagnostics::new("t-baseline");
        // 人为回拨上次输出时刻，模拟已超过节流间隔
        diag.last_log -= DIAG_LOG_INTERVAL;
        diag.record_net(1024);
        assert_eq!(diag.last_net, 1024);
        diag.last_log -= DIAG_LOG_INTERVAL;
        diag.record_source(2048);
        assert_eq!(diag.last_source, 2048);
        assert!(diag.last_log > diag.started);
    }

    /// 发送进度事件携带出网字节累计（网络字节口径）：展示层据此计算网络速率，
    /// 与有效数据口径的进度分子分离。
    #[tokio::test]
    async fn send_progress_event_carries_network_bytes() {
        let (tx, mut rx) = tokio::sync::mpsc::channel::<BridgeEvent>(8);
        let (phase_tx, _phase_rx) = watch::channel(DownloadPhase::Idle);
        let diag = Arc::new(std::sync::Mutex::new(SendDiagnostics::new("t-progress")));
        diag.lock().unwrap().record_net(4096);
        let mut reporter = ProgressReporter {
            event_tx: Some(tx),
            phase_tx,
            task_id: "t-progress".to_string(),
            total: 8192,
            last_report: Instant::now(),
            logged_milestone: 0,
            net: Arc::clone(&diag),
        };
        reporter.complete(8192);

        match rx.try_recv().expect("完成时必须无条件上报进度事件") {
            BridgeEvent::MtaSendProgress {
                sent_bytes,
                total_bytes,
                percent,
                network_bytes,
            } => {
                assert_eq!(sent_bytes, 8192);
                assert_eq!(total_bytes, 8192);
                assert_eq!(network_bytes, 4096);
                assert_eq!(percent, 100.0);
            }
            other => panic!("应上报 MtaSendProgress，实际: {other:?}"),
        }
    }

    /// 速率换算口径：字节差 ÷ 时间差 ÷ MiB；时间差非正或计数回退时返回 0。
    #[test]
    fn send_diag_lane_rate_matches_receive_convention() {
        // 1 MiB 增量 / 1s = 1.0 MiB/s
        assert!((lane_rate(1024 * 1024, 0, 1.0) - 1.0).abs() < 1e-9);
        // 2 MiB 增量 / 0.5s = 4.0 MiB/s
        assert!((lane_rate(3 * 1024 * 1024, 1024 * 1024, 0.5) - 4.0).abs() < 1e-9);
        assert_eq!(lane_rate(100, 0, 0.0), 0.0);
        assert_eq!(lane_rate(0, 100, 1.0), 0.0);
    }

    /// 汇总平均速率：总字节 ÷ 总耗时 ÷ MiB；零字节/零耗时会话不 panic。
    #[test]
    fn send_diag_average_rate_and_zero_byte_summary() {
        assert!((average_rate(2 * 1024 * 1024, 2.0) - 1.0).abs() < 1e-9);
        assert_eq!(average_rate(123, 0.0), 0.0);
        // 零字节会话的终态汇总可正常输出（速率不可计算时以 0 占位）
        SendDiagnostics::new("t-zero").summary("成功");
    }

    /// 对端中途放弃下载（响应体被丢弃）应把下载阶段置为 PeerAborted，
    /// 供 WS 状态机立即收尾，而不是静默等待状态超时。
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn peer_disconnect_marks_download_phase_aborted() {
        let dir = std::env::temp_dir().join(format!("mta_server_abort_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let source = dir.join("big.bin");
        // 大于响应体通道容量（8 × 256KiB），确保写出持续到对端断开
        std::fs::write(&source, vec![7u8; 4 * 1024 * 1024]).unwrap();
        let files = vec![MtaFileEntry {
            fd_send: -1,
            path: source.to_string_lossy().to_string(),
            entry_name: "1/big.bin".into(),
            last_modified_ms: None,
            size_bytes: 4 * 1024 * 1024,
        }];
        let ctx = test_ctx("task-abort", files, 4 * 1024 * 1024);
        let mut phase_rx = ctx.phase_tx.subscribe();

        let (resp, _diag) = build_download_response(&ctx, Some("task-abort")).await;
        // 立即丢弃响应体：等价于对端断开下载连接（无人再消费 ZIP 字节）
        drop(resp);

        let waited = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if *phase_rx.borrow() == DownloadPhase::PeerAborted {
                    break true;
                }
                if phase_rx.changed().await.is_err() {
                    break false;
                }
            }
        })
        .await;
        assert_eq!(waited, Ok(true), "对端断开应置下载阶段为 PeerAborted");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
