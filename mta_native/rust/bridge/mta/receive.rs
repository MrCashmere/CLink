//! MTA 接收端 Rust 主导下载。
//!
//! Rust 直接发起 HTTPS 下载（`reqwest` + 跳过服务端证书校验）、边收边流式解压
//! （复用 [`crate::bridge::mta::unzip_stream`]），把 ZIP 条目**直接写入目标目录**：
//! 仅取文件名防路径穿越、忽略目录条目、重名加 `(n)`、还原条目修改时间、强制
//! 条目数与解压总字节上限；并按"已解压字节 ÷ 声明总大小"经桥接事件上报进度。
//!
//! 网络语义等价重建：连接超时、响应码非 200 判定、下载停滞看门狗（基于数据到达
//! 时间）、取消令牌、失败清理（删除本次已写入的目标文件）与可读日志。
//! ArkTS 仅负责协议交互与业务接线。

use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use serde::Serialize;
use tokio_util::sync::CancellationToken;

use crate::bridge::event::{send_event, BridgeEvent};
use crate::bridge::lock;
use crate::bridge::mta::unzip_stream::{
    self, PushbackReader, ZipEntryHandler, ZipEntryInfo, ZipParseOptions,
};
use crate::bridge::state::BridgeState;
use crate::bridge::throttle::ProgressThrottle;

/// 下载响应体分块通道容量（块）；满时暂停读取响应体形成背压
const BODY_CHANNEL_CAPACITY: usize = 8;
/// 落盘写缓冲大小（1 MiB）：目标目录常位于共享存储（FUSE），大缓冲减少小写放大
const WRITE_BUFFER_SIZE: usize = 1024 * 1024;
/// 网络数据块合并阈值（256 KiB）：小块累积到阈值再整体交付解析线程，
/// 减少逐小块拷贝与线程交接；取值为写盘缓冲的约数以保持数据粒度一致
const BODY_MERGE_THRESHOLD: usize = 256 * 1024;
/// 接收诊断日志最小输出间隔（约 1 s）
const DIAG_LOG_INTERVAL: Duration = Duration::from_secs(1);
/// 字节速率换算用的每 MiB
const BYTES_PER_MIB: f64 = 1024.0 * 1024.0;
/// 缺省连接超时
pub const DEFAULT_CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
/// 缺省下载停滞超时（基于数据到达时间）
pub const DEFAULT_STALL_TIMEOUT: Duration = Duration::from_secs(30);
/// 缺省等待响应头超时（连接建立后至收到响应头/首字节；与连接/停滞同量级）
pub const DEFAULT_HEADER_TIMEOUT: Duration = Duration::from_secs(30);

/// 落盘条目元数据（返回给 ArkTS 用于接收历史、相册与展示）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReceivedEntry {
    /// 文件名（仅文件名，已剥离路径前缀）
    pub name: String,
    /// 解压后字节数
    pub size: u64,
    /// 条目修改时间（Unix 毫秒；不可用时为 0）
    pub modified_unix_ms: i64,
    /// 落盘后的完整路径（可能因重名带 `(n)` 后缀）
    pub saved_path: String,
}

/// 接收下载的网络超时参数。
#[derive(Debug, Clone, Copy)]
pub struct ReceiveTimeouts {
    /// 连接超时
    pub connect: Duration,
    /// 下载停滞超时（连续无新数据即失败）
    pub stall: Duration,
    /// 等待响应头超时（连接建立后至收到响应头/首字节）
    pub header: Duration,
}

impl Default for ReceiveTimeouts {
    fn default() -> Self {
        ReceiveTimeouts {
            connect: DEFAULT_CONNECT_TIMEOUT,
            stall: DEFAULT_STALL_TIMEOUT,
            header: DEFAULT_HEADER_TIMEOUT,
        }
    }
}

/// 从已就绪的 ZIP 读取器把条目直接写入目标目录，返回落盘元数据。
///
/// 失败（含取消、超限、损坏）时删除本次已写入的目标文件，避免残留半成品。
/// 与网络层解耦，便于对解析/落盘/回滚做单元测试。
/// `progress` 累计解压产出字节，`written` 累计实际写盘字节（均供接收诊断）。
pub fn extract_zip_to_dir<R: Read>(
    reader: R,
    target_dir: &Path,
    options: &ZipParseOptions,
    progress: &AtomicU64,
    written: &AtomicU64,
) -> anyhow::Result<Vec<ReceivedEntry>> {
    fs::create_dir_all(target_dir)
        .map_err(|e| anyhow::anyhow!("创建目标目录失败 {}: {e}", target_dir.display()))?;

    let mut handler = FileEntryHandler {
        dir: target_dir.to_path_buf(),
        created: Vec::new(),
        entries: Vec::new(),
        buffer: vec![0u8; WRITE_BUFFER_SIZE],
        written,
    };
    let mut pushback = PushbackReader::new(reader);
    match unzip_stream::parse_zip(&mut pushback, options, progress, &mut handler) {
        Ok(()) => Ok(handler.entries),
        Err(error) => {
            for path in &handler.created {
                let _ = fs::remove_file(path);
            }
            Err(anyhow::anyhow!(error))
        }
    }
}

/// Rust 主导的接收下载：请求 `/download`、流式解压并写入 `target_dir`。
///
/// 成功返回落盘元数据；失败（响应码异常、停滞、取消、解压/写盘失败）返回
/// 可读错误，且本次已写入的目标文件已被清理。
#[allow(clippy::too_many_arguments)]
pub async fn receive_download(
    state: &Mutex<BridgeState>,
    go_ip: &str,
    port: u16,
    task_id: &str,
    target_dir: &str,
    total_bytes: u64,
    options: ZipParseOptions,
    cancel: CancellationToken,
    timeouts: ReceiveTimeouts,
) -> anyhow::Result<Vec<ReceivedEntry>> {
    if target_dir.is_empty() {
        anyhow::bail!("目标目录不能为空");
    }
    let target = PathBuf::from(target_dir);
    fs::create_dir_all(&target)
        .map_err(|e| anyhow::anyhow!("创建目标目录失败 {target_dir}: {e}"))?;

    let event_tx = lock(state).event_tx.clone();
    let client = build_client(timeouts.connect)?;
    let mut url = reqwest::Url::parse(&format!("https://{go_ip}:{port}/download"))?;
    url.query_pairs_mut().append_pair("taskId", task_id);

    // 等待响应头阶段同样受取消与响应头超时约束：connect_timeout 仅覆盖建连，
    // 连接建立后对端迟迟不返回响应头/首字节时须按停滞失败处理，避免无限等待
    let response = tokio::select! {
        biased;
        _ = cancel.cancelled() => {
            anyhow::bail!("下载已取消");
        }
        outcome = tokio::time::timeout(
            timeouts.header,
            client.get(url).header("Accept", "application/zip").send(),
        ) => {
            match outcome {
                Err(_) => anyhow::bail!(
                    "等待下载响应头超时（{}ms）",
                    timeouts.header.as_millis()
                ),
                Ok(Ok(response)) => response,
                Ok(Err(e)) => anyhow::bail!("发起 MTA 下载请求失败: {e}"),
            }
        }
    };
    if cancel.is_cancelled() {
        anyhow::bail!("下载已取消");
    }
    let status = response.status();
    if status != reqwest::StatusCode::OK {
        anyhow::bail!("下载响应码异常: {}", status.as_u16());
    }
    log::debug!("MTA 接收开始 taskId={task_id} target={target_dir} 声明总量={total_bytes}");

    let progress = Arc::new(AtomicU64::new(0));
    let progress_writer = progress.clone();
    let written = Arc::new(AtomicU64::new(0));
    let written_writer = written.clone();
    let (tx, rx) = tokio::sync::mpsc::channel::<Vec<u8>>(BODY_CHANNEL_CAPACITY);
    let parse_dir = target.clone();
    // 解析/写盘为阻塞操作，走 spawn_blocking；输入数据经通道按到达顺序喂入
    let parse_task = tokio::task::spawn_blocking(move || {
        let reader = ChannelReader::new(rx);
        extract_zip_to_dir(
            reader,
            &parse_dir,
            &options,
            &progress_writer,
            &written_writer,
        )
    });

    report_receive_progress(&event_tx, task_id, 0, total_bytes, None, 0, false).await;

    let mut stream = response.bytes_stream();
    let mut throttle = ProgressThrottle::new();
    let mut merger = ChunkMerger::new(BODY_MERGE_THRESHOLD);
    let mut diag = ReceiveDiagnostics::new(task_id);
    let mut network_bytes: u64 = 0;
    let mut failure: Option<String> = None;
    // 网络字节是否已全部读入（响应体正常结束）；true 时仍在解压/落盘
    let mut network_finished = false;

    loop {
        let chunk = tokio::select! {
            biased;
            _ = cancel.cancelled() => {
                failure = Some("下载已取消".to_string());
                break;
            }
            outcome = tokio::time::timeout(
                timeouts.stall,
                futures_util::StreamExt::next(&mut stream),
            ) => {
                match outcome {
                    Err(_) => {
                        failure = Some(format!(
                            "下载停滞超时（{}ms 内无新数据）",
                            timeouts.stall.as_millis()
                        ));
                        break;
                    }
                    Ok(None) => {
                        network_finished = true;
                        break;
                    }
                    Ok(Some(Err(e))) => {
                        failure = Some(format!("下载流错误: {e}"));
                        break;
                    }
                    Ok(Some(Ok(chunk))) => chunk,
                }
            }
        };
        network_bytes += chunk.len() as u64;
        diag.record_chunk(chunk.len());
        // 累积到阈值再整体入队：保持到达顺序，减少逐小块交接与拷贝
        if let Some(merged) = merger.push(&chunk) {
            // The parser waits for EOF after the verified footer. A dropped receiver
            // here means the archive was rejected.
            if tx.send(merged).await.is_err() { break; }
        }
        diag.maybe_log(
            network_bytes,
            progress.load(Ordering::Relaxed),
            written.load(Ordering::Relaxed),
        );
        if throttle.allow(Instant::now()) {
            let received = progress.load(Ordering::Relaxed);
            report_receive_progress(&event_tx, task_id, received, total_bytes, None, network_bytes, false)
                .await;
        }
    }

    // 网络数据已全部读入、解析任务仍在解压/落盘：上报一次终值并把网络收完标记送达
    // 展示层（阶段文案切换为「解压/保存中」，此后不再以网络速率呈现）。
    if network_finished {
        report_receive_progress(
            &event_tx,
            task_id,
            progress.load(Ordering::Relaxed),
            total_bytes,
            None,
            network_bytes,
            true,
        )
        .await;
    }

    // 冲刷不足阈值的残余数据后再关闭通道（EOF）：正常结束时最后一块不丢失，
    // 失败时也已交付的字节仍按原顺序交给解析端处理
    if let Some(tail) = merger.flush() {
        let _ = tx.send(tail).await;
    }
    // 关闭输入通道（EOF）让解析任务收尾；失败路径下解析任务依据自身记录回滚已写文件
    drop(tx);
    let parsed = parse_task
        .await
        .map_err(|e| anyhow::anyhow!("解压任务异常: {e}"))?;

    // 接收结束汇总（debug 级；成功与失败均输出，便于定位瓶颈）
    let final_uncompressed = progress.load(Ordering::Relaxed);
    let final_written = written.load(Ordering::Relaxed);
    match &parsed {
        Ok(entries) => diag.summary(
            network_bytes,
            final_uncompressed,
            final_written,
            entries.len(),
            "成功",
        ),
        Err(_) => diag.summary(network_bytes, final_uncompressed, final_written, 0, "失败"),
    }

    match parsed {
        Ok(entries) if failure.is_some() || !network_finished || cancel.is_cancelled() => {
            for entry in &entries { let _ = fs::remove_file(&entry.saved_path); }
            Err(anyhow::anyhow!("{}", failure.unwrap_or_else(|| "下载未正常结束或已取消".to_string())))
        }
        Ok(entries) => {
            let received = progress.load(Ordering::Relaxed);
            report_receive_progress(
                &event_tx,
                task_id,
                received,
                total_bytes,
                Some(100.0),
                network_bytes,
                true,
            )
            .await;
            log::info!(
                "MTA 接收完成 taskId={task_id} 条目数={} 解压字节={received} 网络字节={network_bytes}",
                entries.len()
            );
            Ok(entries)
        }
        Err(error) => {
            let reason = failure.unwrap_or_else(|| "接收解压失败".to_string());
            Err(anyhow::anyhow!("{reason}（解析任务: {error:#}）"))
        }
    }
}

/// 按"已解压字节 ÷ 声明总大小"上报接收进度（可丢弃事件）。
///
/// `percent_override` 为 `Some` 时使用给定百分比（完成态无条件 100%）。
/// `network_bytes` 为网络读入字节累计（网络口径，供展示层计算速率）；
/// `network_done` 为网络数据是否已全部读入（true 表示仍在解压/落盘）。
async fn report_receive_progress(
    event_tx: &Option<tokio::sync::mpsc::Sender<BridgeEvent>>,
    task_id: &str,
    received_bytes: u64,
    total_bytes: u64,
    percent_override: Option<f64>,
    network_bytes: u64,
    network_done: bool,
) {
    let percent = match percent_override {
        Some(value) => value,
        None => {
            if total_bytes > 0 {
                (received_bytes as f64 / total_bytes as f64 * 100.0).clamp(0.0, 100.0)
            } else {
                0.0
            }
        }
    };
    send_event(
        event_tx,
        BridgeEvent::MtaReceiveProgress {
            task_id: task_id.to_owned(),
            received_bytes,
            total_bytes,
            percent,
            network_bytes,
            network_done,
        },
    )
    .await;
}

/// 构造跳过服务端证书校验的下载客户端（仅用于 MTA 自签名场景）。
fn build_client(connect_timeout: Duration) -> anyhow::Result<reqwest::Client> {
    // 安装 rustls ring crypto provider（幂等）：reqwest 以 rustls-no-provider 构建
    let _ = rustls::crypto::ring::default_provider().install_default();
    reqwest::Client::builder()
        .use_rustls_tls()
        .danger_accept_invalid_certs(true)
        .connect_timeout(connect_timeout)
        .build()
        .map_err(|e| anyhow::anyhow!("构造 MTA 下载客户端失败: {e}"))
}

/// 拉取发送端提供的缩略图：`GET /thumbnail?taskId=<任务 ID>`，与下载走同一 TLS 通道
/// （自签名证书跳过校验）。响应为 `application/octet-stream`（不携带格式），故按魔数识别
/// 图片格式并以对应扩展名写入 `target_dir`，成功时返回落盘路径。
///
/// 仅用于接收确认阶段的预览：任何失败都返回错误文本，由调用方按「无预览」处理，
/// 不阻断接收主流程。
pub async fn fetch_thumbnail(
    go_ip: &str,
    port: u16,
    task_id: &str,
    target_dir: &str,
    connect_timeout: Duration,
    max_bytes: u64,
) -> anyhow::Result<String> {
    let client = build_client(connect_timeout)?;
    let mut url = reqwest::Url::parse(&format!("https://{go_ip}:{port}/thumbnail"))
        .map_err(|e| anyhow::anyhow!("缩略图 URL 非法: {e}"))?;
    url.query_pairs_mut().append_pair("taskId", task_id);
    let mut response = client
        .get(url)
        .timeout(connect_timeout)
        .send()
        .await
        .map_err(|e| anyhow::anyhow!("请求缩略图失败: {e}"))?;
    if !response.status().is_success() {
        anyhow::bail!("缩略图响应码异常: {}", response.status());
    }
    if let Some(len) = response.content_length() {
        if len > max_bytes {
            anyhow::bail!("缩略图超出上限: {len} 字节");
        }
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|e| anyhow::anyhow!("读取缩略图失败: {e}"))? {
        if (bytes.len() as u64).saturating_add(chunk.len() as u64) > max_bytes {
            anyhow::bail!("缩略图超出上限: {max_bytes} 字节");
        }
        bytes.extend_from_slice(&chunk);
    }
    let extension = sniff_image_extension(&bytes);
    // 任务标识仅允许安全字符，防止路径穿越
    if !task_id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        anyhow::bail!("任务标识非法");
    }
    let path = format!("{target_dir}/mta_thumb_{task_id}.{extension}");
    std::fs::write(&path, &bytes).map_err(|e| anyhow::anyhow!("写入缩略图失败 {path}: {e}"))?;
    log::debug!(
        "MTA 缩略图已保存 格式={extension} 字节={} 路径={path}",
        bytes.len()
    );
    Ok(path)
}

/// 按魔数识别图片格式（对端按 `application/octet-stream` 返回，无格式提示）；
/// 识别不出时用 `bin`，由调用方按不可展示处理。
fn sniff_image_extension(bytes: &[u8]) -> &'static str {
    if bytes.len() >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
        return "jpg";
    }
    if bytes.len() >= 8 && bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        return "png";
    }
    if bytes.len() >= 6 && bytes.starts_with(b"GIF8") {
        return "gif";
    }
    if bytes.len() >= 12 && bytes.starts_with(b"RIFF") && &bytes[8..12] == b"WEBP" {
        return "webp";
    }
    if bytes.len() >= 2 && bytes.starts_with(&[0x42, 0x4D]) {
        return "bmp";
    }
    "bin"
}

/// 逐条目写入目标目录，并记录本次已产出文件供失败回滚。
struct FileEntryHandler<'a> {
    /// 目标目录
    dir: PathBuf,
    /// 本次已创建的文件（失败/取消时删除）
    created: Vec<PathBuf>,
    /// 已落盘条目元数据
    entries: Vec<ReceivedEntry>,
    /// 条目处理复用的写盘缓冲（大缓冲避免共享存储下的小写放大）
    buffer: Vec<u8>,
    /// 累计实际写盘字节（供接收速率诊断）
    written: &'a AtomicU64,
}

impl ZipEntryHandler for FileEntryHandler<'_> {
    fn handle_entry(&mut self, info: &ZipEntryInfo, data: &mut dyn Read) -> Result<(), String> {
        let (path, mut file) = create_unique_target(&self.dir, &info.name)
            .map_err(|e| format!("创建目标文件失败 {}: {e}", info.name))?;
        self.created.push(path.clone());
        let written = copy_to_file(data, &mut file, &mut self.buffer, self.written)
            .map_err(|e| format!("写入目标文件失败 {}: {e}", path.display()))?;
        use std::io::Write as _;
        file.flush()
            .map_err(|e| format!("写入目标文件失败 {}: {e}", path.display()))?;
        drop(file);

        if info.modified_unix_ms > 0 {
            if let Err(e) = set_modified_time(&path, info.modified_unix_ms) {
                log::warn!("还原文件修改时间失败 {}: {e}", path.display());
            }
        }

        self.entries.push(ReceivedEntry {
            name: info.name.clone(),
            size: written,
            modified_unix_ms: info.modified_unix_ms,
            saved_path: path.to_string_lossy().to_string(),
        });
        Ok(())
    }
}

/// 用固定大缓冲把 `data` 读到 EOF 并写入 `file`，返回写入字节数。
///
/// 相比 `io::copy` 的 8 KiB 通用缓冲，大缓冲显著减少共享存储（FUSE）下的写调用次数；
/// 正确处理短读与 EOF（`read` 返回 0 即结束），并容忍被信号中断的读。
/// 每写一段即累加 `written`，使长条目在写入过程中也能被诊断观测。
fn copy_to_file(
    data: &mut dyn Read,
    file: &mut File,
    buffer: &mut [u8],
    written: &AtomicU64,
) -> io::Result<u64> {
    use std::io::Write as _;
    let mut total: u64 = 0;
    loop {
        let n = match data.read(buffer) {
            Ok(0) => break,
            Ok(n) => n,
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        file.write_all(&buffer[..n])?;
        total += n as u64;
        written.fetch_add(n as u64, Ordering::Relaxed);
    }
    Ok(total)
}

/// 在目标目录中生成不冲突的文件路径（重名加 `(n)` 后缀）。
fn create_unique_target(dir: &Path, name: &str) -> io::Result<(PathBuf, File)> {
    let (base, ext) = split_name(name);
    for index in 0..10_000 {
        let path = if index == 0 { dir.join(name) } else { dir.join(format!("{base}({index}){ext}")) };
        match fs::OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => return Ok((path, file)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }
    Err(io::Error::new(io::ErrorKind::AlreadyExists, "文件名冲突超过上限"))
}

/// 拆分文件名的主干与扩展名；隐藏文件（`.` 开头）整体视为主干。
fn split_name(name: &str) -> (&str, &str) {
    match name.rfind('.') {
        Some(pos) if pos > 0 => (&name[..pos], &name[pos..]),
        _ => (name, ""),
    }
}

/// 按 Unix 毫秒还原文件修改时间。
fn set_modified_time(path: &Path, modified_unix_ms: i64) -> io::Result<()> {
    let millis = modified_unix_ms.max(0) as u64;
    let when = SystemTime::UNIX_EPOCH + Duration::from_millis(millis);
    let file = fs::OpenOptions::new().write(true).open(path)?;
    file.set_modified(when)
}

/// 把异步下载的数据块按到达顺序桥接给阻塞解析线程（发送端 drop 后视为 EOF）。
struct ChannelReader {
    rx: tokio::sync::mpsc::Receiver<Vec<u8>>,
    current: Vec<u8>,
    pos: usize,
}

impl ChannelReader {
    fn new(rx: tokio::sync::mpsc::Receiver<Vec<u8>>) -> Self {
        ChannelReader {
            rx,
            current: Vec::new(),
            pos: 0,
        }
    }
}

impl Read for ChannelReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        loop {
            if self.pos < self.current.len() {
                let available = self.current.len() - self.pos;
                let n = std::cmp::min(available, buf.len());
                buf[..n].copy_from_slice(&self.current[self.pos..self.pos + n]);
                self.pos += n;
                return Ok(n);
            }
            match self.rx.blocking_recv() {
                Some(chunk) => {
                    self.current = chunk;
                    self.pos = 0;
                }
                None => return Ok(0),
            }
        }
    }
}

/// 网络数据块合并器：按到达顺序把小块累积到阈值后整体交付。
///
/// 网络侧逐 chunk 入队会造成大量小块拷贝与线程交接；合并后按移动语义交付，
/// 减少交接次数且内存有界（单块不超过阈值加上最后一块的大小）。
struct ChunkMerger {
    /// 合并阈值（字节）
    threshold: usize,
    /// 尚未达到阈值的累积数据
    pending: Vec<u8>,
}

impl ChunkMerger {
    fn new(threshold: usize) -> Self {
        ChunkMerger {
            threshold,
            pending: Vec::with_capacity(threshold),
        }
    }

    /// 追加一块数据；累积达到阈值时返回合并块（按移动交付），否则返回 `None`。
    fn push(&mut self, chunk: &[u8]) -> Option<Vec<u8>> {
        self.pending.extend_from_slice(chunk);
        if self.pending.len() >= self.threshold {
            Some(std::mem::replace(
                &mut self.pending,
                Vec::with_capacity(self.threshold),
            ))
        } else {
            None
        }
    }

    /// 冲刷残余数据（流结束或失败时调用）；无残余返回 `None`。
    ///
    /// 调用方须在冲刷后再关闭通道，保证字节顺序与 EOF 语义不变。
    fn flush(&mut self) -> Option<Vec<u8>> {
        if self.pending.is_empty() {
            return None;
        }
        Some(std::mem::take(&mut self.pending))
    }
}

/// 接收过程诊断：三速率（网络读入 / 解压产出 / 写盘）与 HTTP 数据块大小统计。
///
/// 仅在 [`DIAG_LOG_INTERVAL`] 节流下输出 debug 级日志；接收结束时输出一次汇总。
/// 计数仅用于日志，不参与传输决策，也不在非 debug 级产生额外输出。
struct ReceiveDiagnostics {
    /// 会话标识（输出到每条日志，供按会话过滤）
    task_id: String,
    /// 接收起始时刻
    started: Instant,
    /// 上次输出诊断的时刻
    last_log: Instant,
    /// 上次输出时的累计网络读入字节
    last_network: u64,
    /// 上次输出时的累计解压产出字节
    last_uncompressed: u64,
    /// 上次输出时的累计写盘字节
    last_written: u64,
    /// HTTP 数据块最小字节数（无块时为 `usize::MAX`）
    chunk_min: usize,
    /// HTTP 数据块最大字节数
    chunk_max: usize,
    /// HTTP 数据块数
    chunk_count: u64,
    /// HTTP 数据块字节总和（求均值）
    chunk_sum: u64,
}

impl ReceiveDiagnostics {
    fn new(task_id: &str) -> Self {
        let now = Instant::now();
        ReceiveDiagnostics {
            task_id: task_id.to_string(),
            started: now,
            last_log: now,
            last_network: 0,
            last_uncompressed: 0,
            last_written: 0,
            chunk_min: usize::MAX,
            chunk_max: 0,
            chunk_count: 0,
            chunk_sum: 0,
        }
    }

    /// 记录一个 HTTP 数据块的字节数。
    fn record_chunk(&mut self, len: usize) {
        if len == 0 {
            return;
        }
        self.chunk_min = self.chunk_min.min(len);
        self.chunk_max = self.chunk_max.max(len);
        self.chunk_count += 1;
        self.chunk_sum += len as u64;
    }

    /// 距上次输出达到节流间隔时，输出一次瞬时与累计速率（debug 级）。
    fn maybe_log(&mut self, network: u64, uncompressed: u64, written: u64) {
        let now = Instant::now();
        let elapsed = now.duration_since(self.last_log);
        if elapsed < DIAG_LOG_INTERVAL {
            return;
        }
        let secs = elapsed.as_secs_f64();
        let total_secs = now.duration_since(self.started).as_secs_f64();
        let instant = |current: u64, last: u64| -> f64 {
            if secs > 0.0 {
                (current.saturating_sub(last)) as f64 / secs / BYTES_PER_MIB
            } else {
                0.0
            }
        };
        log::debug!(
            "MTA 接收速率 taskId={} 网络读入={:.1}MiB/s 解压产出={:.1}MiB/s 写盘={:.1}MiB/s 平均={:.1}MiB/s",
            self.task_id,
            instant(network, self.last_network),
            instant(uncompressed, self.last_uncompressed),
            instant(written, self.last_written),
            if total_secs > 0.0 {
                network as f64 / total_secs / BYTES_PER_MIB
            } else {
                0.0
            }
        );
        self.last_log = now;
        self.last_network = network;
        self.last_uncompressed = uncompressed;
        self.last_written = written;
    }

    /// 接收结束时输出该次汇总（总字节、平均速率、块大小分布；debug 级）。
    fn summary(
        &self,
        network: u64,
        uncompressed: u64,
        written: u64,
        entries: usize,
        outcome: &str,
    ) {
        let secs = self.started.elapsed().as_secs_f64();
        let avg_rate = if secs > 0.0 {
            network as f64 / secs / BYTES_PER_MIB
        } else {
            0.0
        };
        let (min_chunk, avg_chunk) = if self.chunk_count > 0 {
            (
                self.chunk_min as u64,
                self.chunk_sum as f64 / self.chunk_count as f64,
            )
        } else {
            (0, 0.0)
        };
        log::debug!(
            "MTA 接收汇总({outcome}) taskId={} 耗时={:.2}s 网络读入={network}B 解压产出={uncompressed}B \
             写盘={written}B 条目数={entries} 平均速率={:.1}MiB/s HTTP块 min={min_chunk}B \
             max={}B avg={:.0}B count={}",
            self.task_id,
            secs,
            avg_rate,
            self.chunk_max,
            avg_chunk,
            self.chunk_count
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bridge::mta::unzip_stream::ZipParseOptions;
    use std::sync::atomic::AtomicU64;

    /// 构造独立临时目录。
    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("mta_receive_{tag}_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// 构造最小合法 ZIP（单条；条目恒为 Deflate 压缩，与发送端写出的格式一致）。
    fn stored_zip(name: &str, data: &[u8]) -> Vec<u8> {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let tag = format!("stored_src_{}", COUNTER.fetch_add(1, Ordering::Relaxed));
        let dir = temp_dir(&tag);
        let source = dir.join("src.bin");
        fs::write(&source, data).unwrap();
        let files = vec![crate::bridge::mta::zip_stream::MtaFileEntry {
            fd_send: -1,
            path: source.to_string_lossy().to_string(),
            entry_name: format!("1/{name}"),
            last_modified_ms: Some(1_600_000_000_000),
            size_bytes: data.len() as u64,
        }];
        let mut zip_bytes: Vec<u8> = Vec::new();
        crate::bridge::mta::zip_stream::write_zip_stream(&mut zip_bytes, &files, |_| {}).unwrap();
        let _ = fs::remove_dir_all(&dir);
        zip_bytes
    }

    /// 构造最小合法 ZIP（多条，按给定顺序；条目恒为 Deflate 压缩）。
    fn stored_zip_multi(entries: &[(&str, &[u8])]) -> Vec<u8> {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let tag = format!("stored_multi_{}", COUNTER.fetch_add(1, Ordering::Relaxed));
        let dir = temp_dir(&tag);
        let mut files = Vec::new();
        for (index, (name, data)) in entries.iter().enumerate() {
            let source = dir.join(format!("src_{index}.bin"));
            fs::write(&source, data).unwrap();
            files.push(crate::bridge::mta::zip_stream::MtaFileEntry {
                fd_send: -1,
                path: source.to_string_lossy().to_string(),
                entry_name: format!("1/{name}"),
                last_modified_ms: Some(1_600_000_000_000),
                size_bytes: data.len() as u64,
            });
        }
        let mut zip_bytes: Vec<u8> = Vec::new();
        crate::bridge::mta::zip_stream::write_zip_stream(&mut zip_bytes, &files, |_| {}).unwrap();
        let _ = fs::remove_dir_all(&dir);
        zip_bytes
    }

    fn options(max_entries: u64, max_total: u64) -> ZipParseOptions {
        // 单条目上限在通用用例中不限制（0），专门的条目上限用例自行构造选项
        ZipParseOptions::new(max_entries, max_total, 0, Arc::new(|| false))
    }

    #[test]
    fn extract_writes_metadata_and_restores_time() {
        let dir = temp_dir("extract");
        let out = dir.join("out");
        let zip_bytes = stored_zip("a.txt", b"hello mta");
        let progress = AtomicU64::new(0);
        let written = AtomicU64::new(0);

        let entries = extract_zip_to_dir(
            io::Cursor::new(&zip_bytes),
            &out,
            &options(10, 1024 * 1024),
            &progress,
            &written,
        )
        .unwrap();

        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name, "a.txt");
        assert_eq!(entries[0].size, 9);
        assert_eq!(entries[0].modified_unix_ms, 1_600_000_000_000);
        assert_eq!(fs::read(out.join("a.txt")).unwrap(), b"hello mta");
        assert_eq!(progress.load(Ordering::Relaxed), 9);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn extract_renames_duplicate_with_index() {
        let dir = temp_dir("dup");
        let out = dir.join("out");
        fs::create_dir_all(&out).unwrap();
        fs::write(out.join("a.txt"), b"existing").unwrap();
        let zip_bytes = stored_zip("a.txt", b"incoming");
        let progress = AtomicU64::new(0);
        let written = AtomicU64::new(0);

        let entries = extract_zip_to_dir(
            io::Cursor::new(&zip_bytes),
            &out,
            &options(10, 1024 * 1024),
            &progress,
            &written,
        )
        .unwrap();

        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name, "a.txt");
        assert!(entries[0].saved_path.ends_with("a(1).txt"));
        assert_eq!(fs::read(out.join("a(1).txt")).unwrap(), b"incoming");
        assert_eq!(fs::read(out.join("a.txt")).unwrap(), b"existing");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn extract_rolls_back_on_corrupt_zip() {
        let dir = temp_dir("rollback");
        let out = dir.join("out");
        // 首条完整写出后立即截断：解析出错并回滚已写文件
        let mut zip_bytes = stored_zip("a.txt", b"hello mta");
        // 本地头 30 字节 + 名称 "1/a.txt" 7 字节，保留部分条目数据后截断
        zip_bytes.truncate(30 + "1/a.txt".len() + 3);
        let progress = AtomicU64::new(0);
        let written = AtomicU64::new(0);

        let result = extract_zip_to_dir(
            io::Cursor::new(&zip_bytes),
            &out,
            &options(10, 1024 * 1024),
            &progress,
            &written,
        );
        assert!(result.is_err());
        assert!(!out.join("a.txt").exists(), "失败后应回滚已写入文件");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn extract_rolls_back_on_cancel() {
        let dir = temp_dir("cancel");
        let out = dir.join("out");
        let zip_bytes = stored_zip("a.txt", b"hello mta");
        let progress = AtomicU64::new(0);
        let written = AtomicU64::new(0);
        let cancelled = Arc::new(|| true);
        let opts = ZipParseOptions::new(10, 1024 * 1024, 0, cancelled);

        let result = extract_zip_to_dir(
            io::Cursor::new(&zip_bytes),
            &out,
            &opts,
            &progress,
            &written,
        );
        assert!(result.is_err());
        assert!(!out.join("a.txt").exists(), "取消后应回滚已写入文件");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn large_buffer_writes_across_multiple_entries() {
        let dir = temp_dir("large_multi");
        let out = dir.join("out");
        // 首条目数据跨越大缓冲边界（1 MiB + 偏移），后接多个小条目
        let big: Vec<u8> = (0..(WRITE_BUFFER_SIZE + 4096))
            .map(|i| (i % 251) as u8)
            .collect();
        let small = b"small entry".to_vec();
        let zip_bytes = stored_zip_multi(&[
            ("first.bin", big.as_slice()),
            ("second.txt", small.as_slice()),
            ("third.bin", b"tail".as_slice()),
        ]);
        let progress = AtomicU64::new(0);
        let written = AtomicU64::new(0);

        let entries = extract_zip_to_dir(
            io::Cursor::new(&zip_bytes),
            &out,
            &options(10, 64 * 1024 * 1024),
            &progress,
            &written,
        )
        .unwrap();

        // 多条目顺序与内容均正确，跨缓冲边界不损坏
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].name, "first.bin");
        assert_eq!(entries[1].name, "second.txt");
        assert_eq!(entries[2].name, "third.bin");
        assert_eq!(fs::read(out.join("first.bin")).unwrap(), big);
        assert_eq!(fs::read(out.join("second.txt")).unwrap(), small);
        assert_eq!(fs::read(out.join("third.bin")).unwrap(), b"tail");
        assert_eq!(entries[0].size, big.len() as u64);
        // 写盘计数与实际落盘字节一致
        assert_eq!(
            written.load(Ordering::Relaxed),
            (big.len() + small.len() + 4) as u64
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn large_buffer_rolls_back_on_truncated_entry() {
        let dir = temp_dir("large_truncate");
        let out = dir.join("out");
        // 不可压缩载荷：压缩后字节数仍接近原始大小，截断点必然落在条目数据中途
        let big: Vec<u8> = {
            let mut state: u32 = 0x1234_5678;
            (0..WRITE_BUFFER_SIZE + 1024)
                .map(|_| {
                    state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                    (state >> 24) as u8
                })
                .collect()
        };
        let mut zip_bytes = stored_zip_multi(&[
            ("big.jpg", big.as_slice()),
            ("next.bin", b"next".as_slice()),
        ]);
        // 截断到首条目数据中途：解析失败应回滚已写入的大文件
        zip_bytes.truncate(30 + "1/big.jpg".len() + WRITE_BUFFER_SIZE / 2);
        let progress = AtomicU64::new(0);
        let written = AtomicU64::new(0);

        let result = extract_zip_to_dir(
            io::Cursor::new(&zip_bytes),
            &out,
            &options(10, 64 * 1024 * 1024),
            &progress,
            &written,
        );
        assert!(result.is_err());
        assert!(!out.join("big.jpg").exists(), "失败后应回滚已写入的大文件");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn chunk_merger_preserves_order_and_flushes_remainder() {
        let mut merger = ChunkMerger::new(16);
        let mut delivered: Vec<u8> = Vec::new();

        // 达到阈值前不交付
        assert!(merger.push(b"abc").is_none());
        assert!(merger.push(b"defgh").is_none());
        // 累积恰达阈值时交付，内容与到达顺序一致
        let merged = merger.push(b"ijklmnop").expect("达到阈值应交付");
        delivered.extend_from_slice(&merged);
        assert_eq!(delivered, b"abcdefghijklmnop");

        // 末尾不足阈值的数据经 flush 冲刷，不丢失
        assert!(merger.push(b"qr").is_none());
        let tail = merger.flush().expect("应冲刷残余");
        assert_eq!(tail, b"qr");
        // 无残余时 flush 返回 None
        assert!(merger.flush().is_none());
    }

    #[test]
    fn chunk_merger_orders_data_across_boundaries() {
        let mut merger = ChunkMerger::new(8);
        let input: Vec<u8> = (0..=255u8).collect();
        let mut output: Vec<u8> = Vec::new();
        for chunk in input.chunks(3) {
            if let Some(merged) = merger.push(chunk) {
                output.extend_from_slice(&merged);
            }
        }
        if let Some(tail) = merger.flush() {
            output.extend_from_slice(&tail);
        }
        assert_eq!(output, input, "合并后字节顺序必须与到达顺序一致");
    }

    #[test]
    fn unique_target_path_uses_index() {
        let dir = temp_dir("unique");
        fs::write(dir.join("photo.jpg"), b"x").unwrap();
        assert!(create_unique_target(&dir, "photo.jpg").unwrap().0.ends_with("photo(1).jpg"));
        // 隐藏文件整体视为主干
        assert!(create_unique_target(&dir, ".hidden").unwrap().0.ends_with(".hidden"));
        let _ = fs::remove_dir_all(&dir);
    }
}
