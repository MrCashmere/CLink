//! MTA WS 连接上的发送端状态机。
//!
//! 对端（接收端）连入本机 TLS 端口并升级为 WebSocket 后，发送端主动：
//! 发 `versionNegotiation` → 等 ack → 发 `sendRequest` → 等 ack →
//! 等 `/download` 开始 → 等对端 `status`（按「类型 + 原因」组合判定成功/
//! 部分完成/拒绝/超时/失败）。任一步超时或连接中断即发 `MtaSendFailed`。
//! 进度由下载 body 直接上报，本处不重复。
//!
//! 收尾：所有会话结束统一经 [`terminate_session`]——在确保结束类指示（结果回执 / 取消状态）
//! 已被对端读取之后，以**连接终止**（**不发 WebSocket 关闭帧**）结束会话。目标对端
//! （OkHttp WebSocket 客户端）只在自身发起关闭时才回调其「关闭完成」，收到服务端关闭帧后即
//! 停止读取，故服务端发关闭帧只会触发其空实现的「关闭中」回调，对端自身收尾（解除忙态）永不
//! 执行；改为终止连接可使其进入可处理的「连接失败终止」路径。成功路径仅在收到对端终态并回送
//! 确认之后才终止；终态之前不得以成功语义结束会话，取消/拒绝/失败路径保持既有
//! 「先回送结果再收尾」语义。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::protocol::Role;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;

use crate::bridge::event::{send_event, BridgeEvent};
use crate::bridge::mta::protocol::{self, SendRequestPayload, StatusKind};
use crate::bridge::mta::{DownloadPhase, MtaContext};

/// versionNegotiation 消息 ID
const VERSION_ID: u32 = 0;
/// sendRequest 消息 ID
const SEND_REQUEST_ID: u32 = 1;
/// 等待版本协商 ack 超时
const VERSION_ACK_TIMEOUT: Duration = Duration::from_secs(10);
/// 等待 sendRequest ack 超时：与对端实现（小米互传）的等待窗口一致取 30s——
/// 对端自身等待本端 ack 也是 30s，本端若只等 10s 会在对端 ack 偏慢时提前判失败
const SEND_REQUEST_ACK_TIMEOUT: Duration = Duration::from_secs(30);
/// 等待对端传输状态超时（含下载耗时）
const STATUS_WAIT_TIMEOUT: Duration = Duration::from_secs(180);
/// 会话终止前「确保结束类指示（结果回执 / 取消状态）已被对端读取」的有界宽限。
///
/// `ws.send` 内部含 flush，结束类指示写出后即离开本端发送路径；本端在终止连接前继续驱动
/// 读取该有界宽限，给对端读取该指示留出时间，避免因抢断连接而丢失指示。独立常量，便于真机
/// 标定；取较小值（300ms），不对收尾路径引入可感知的额外等待。
///
/// 取值收口：终态路径最坏收尾等待 = 对端先行关闭宽限（[`PEER_FIRST_CLOSE_GRACE`]，2s）+ 本
/// 宽限（300ms）≈ 2.3s，不长于修复前「先给对端机会自行关闭（2s）+ 发关闭帧后再等待回应
/// （1s）≈ 3s」，故不劣于现状；取消/失败路径无结束类指示，不等待本宽限。
const PRE_TERMINATE_GRACE: Duration = Duration::from_millis(300);
/// 是否启用「对端主动先行关闭」快路径（仅终态路径参与；取消/失败路径不等待）。
const PEER_FIRST_CLOSE_ENABLED: bool = true;
/// 「对端主动先行关闭」快路径的等待上限：该宽限内读到对端关闭帧或连接结束即直接结束会话
/// （跳过终止前送达宽限）。保留既有「先给对端机会自行关闭」的宽限（2s，与修复前同值）作为
/// 可选快路径，故不改变对先行关闭对端的既有行为；不再是会话结束的前置条件。
const PEER_FIRST_CLOSE_GRACE: Duration = Duration::from_secs(2);
/// 对端中途取消（下载连接断开）时对外发射的可读失败原因
const PEER_ABORT_REASON: &str = "对端已取消（下载连接中断）";

/// WS 连接占位守卫：持有期间 `ws_connected` 为 true，run_ws 结束
/// （正常收尾 / 出错 / 取消 / panic，即任何 return 与 unwinding）时
/// 由 Drop 复位，允许对端断开后重连。
struct WsSlotGuard<'a>(&'a AtomicBool);

impl Drop for WsSlotGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

/// 会话内相对耗时（毫秒）：以 WS 会话任务开始时刻为基准。
/// 使逐帧诊断与收尾统计的时间线可自证，不受 ArkTS 侧 500ms 日志轮询节奏影响。
fn elapsed_ms(start: tokio::time::Instant) -> u128 {
    start.elapsed().as_millis()
}

/// WS 会话收尾统计守卫：在 [`run_ws`] 的任何返回路径（正常收尾 / 出错 / 取消 / panic 展开）
/// 释放时输出一次本会话统计——从对端读到的报文数与会话相对耗时，
/// 供区分「对端未发送」与「本端漏收」。
struct SessionSummaryGuard<'a> {
    /// 会话上下文（携带会话级报文计数）
    ctx: &'a MtaContext,
    /// 会话开始时刻（相对耗时基准）
    session_start: tokio::time::Instant,
}

impl Drop for SessionSummaryGuard<'_> {
    fn drop(&mut self) {
        log::debug!(
            "MTA WS 会话结束 收到对端报文数={} 相对耗时={}ms",
            self.ctx.peer_frames.load(Ordering::SeqCst),
            elapsed_ms(self.session_start)
        );
    }
}

/// 在已升级的 WS 连接上执行 MTA 发送端状态机。
pub async fn run_ws<S>(stream: S, ctx: Arc<MtaContext>)
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    if !ctx.mark_ws_connected() {
        log::warn!("MTA 已存在 WS 连接，忽略重复连接");
        return;
    }
    let _slot = WsSlotGuard(&ctx.ws_connected);
    // 会话统计守卫：任何返回路径（正常收尾 / 出错 / 取消 / panic 展开）都会输出一次收尾统计
    let session_start = tokio::time::Instant::now();
    let _summary = SessionSummaryGuard {
        ctx: &ctx,
        session_start,
    };
    let mut ws = WebSocketStream::from_raw_socket(stream, Role::Server, None).await;
    // 升级握手期间服务器可能已被停止：立即退出，不再发起协商
    if ctx.cancel.is_cancelled() {
        log::debug!("MTA WS 升级完成但服务器已取消，直接终止会话");
        terminate_session(&mut ws, TerminatePath::Cancel, session_start, false).await;
        return;
    }
    // 本地已登记取消意图（用户在对端接入前取消）：对端刚接入即回送取消状态并收尾，
    // 不推进版本协商与 sendRequest
    if ctx.is_reject_pending() {
        log::debug!("MTA 本地已取消，对端接入后直接回送取消状态");
        reject_peer(&ctx, &mut ws, session_start).await;
        return;
    }
    send_event(&ctx.event_tx, BridgeEvent::MtaWsConnected).await;

    // 1) 版本协商
    let negotiation = protocol::build_message(
        "action",
        VERSION_ID,
        "versionNegotiation",
        Some(&protocol::version_negotiation_payload()),
    );
    log::debug!(
        "MTA 发送版本协商 type=action id={VERSION_ID} name=versionNegotiation version={}",
        protocol::PROTOCOL_VERSION
    );
    if let Err(e) = ws.send(Message::text(negotiation)).await {
        fail_ws(
            &ctx,
            &mut ws,
            session_start,
            format!("发送版本协商失败: {e}"),
        )
        .await;
        return;
    }
    let version_ack = match wait_ack(
        &ctx,
        &mut ws,
        "versionNegotiation",
        VERSION_ACK_TIMEOUT,
        session_start,
    )
    .await
    {
        AckOutcome::Ack(payload) => payload,
        AckOutcome::StatusTerminated { ack_sent } => {
            // 等待确认期间即收到对端 status：终态事件已发射并回送确认，之后才终止会话
            terminate_session(
                &mut ws,
                TerminatePath::PeerTerminal,
                session_start,
                ack_sent,
            )
            .await;
            return;
        }
        AckOutcome::Cancelled => return,
        AckOutcome::Failed(reason) => {
            fail_ws(&ctx, &mut ws, session_start, reason).await;
            return;
        }
    };
    // 校验对端选定版本（宽松策略：ack 未携带 version 时视为兼容，与接收端一致）
    if let Some(reason) = check_version_ack(version_ack.as_deref()) {
        fail_ws(&ctx, &mut ws, session_start, reason).await;
        return;
    }
    send_event(
        &ctx.event_tx,
        BridgeEvent::MtaVersionNegotiated {
            version: protocol::PROTOCOL_VERSION,
        },
    )
    .await;

    // 取消意图在版本协商后登记：直接回送取消状态，不抢先发送 sendRequest
    if ctx.is_reject_pending() {
        log::debug!("MTA 本地已取消，跳过 sendRequest 直接回送取消状态");
        reject_peer(&ctx, &mut ws, session_start).await;
        return;
    }

    // 2) 发送 sendRequest
    let payload = SendRequestPayload {
        task_id: ctx.task_id.clone(),
        id: ctx.task_id.clone(),
        sender_id: ctx.sender_id.clone(),
        sender_name: ctx.sender_name.clone(),
        file_name: ctx.file_name.clone(),
        mime_type: ctx.mime_type.clone(),
        file_count: ctx.file_count,
        total_size: ctx.total_size,
        // 仅当本次确实提供缩略图时才写路径与尺寸：对端以「字段存在且宽高非 0」作为索取前提
        thumbnail: ctx
            .thumbnail
            .as_ref()
            .map(|_| format!("/thumbnail?taskId={}", ctx.task_id)),
        thumbnail_width: ctx.thumbnail.as_ref().map(|t| t.width),
        thumbnail_height: ctx.thumbnail.as_ref().map(|t| t.height),
        cat_share_text: ctx.text_content.clone(),
        sender_brand_id: ctx.sender_brand_id,
        sender_brand: ctx.sender_brand.clone(),
    };
    let request = protocol::build_message(
        "action",
        SEND_REQUEST_ID,
        "sendRequest",
        Some(&protocol::send_request_json(&payload)),
    );
    log::debug!(
        "MTA 发送接收请求 type=action id={SEND_REQUEST_ID} name=sendRequest taskId={} fileCount={} totalSize={} mimeType={} thumbnail={}",
        ctx.task_id,
        ctx.file_count,
        ctx.total_size,
        ctx.mime_type,
        if ctx.thumbnail.is_some() { "有" } else { "无" }
    );
    if let Err(e) = ws.send(Message::text(request)).await {
        fail_ws(
            &ctx,
            &mut ws,
            session_start,
            format!("发送 sendRequest 失败: {e}"),
        )
        .await;
        return;
    }
    match wait_ack(
        &ctx,
        &mut ws,
        "sendRequest",
        SEND_REQUEST_ACK_TIMEOUT,
        session_start,
    )
    .await
    {
        AckOutcome::Ack(_) => {}
        AckOutcome::StatusTerminated { ack_sent } => {
            // 确认到达前先收到拒绝/成功状态：终态已定并回送确认，不再等待下载与后续状态
            terminate_session(
                &mut ws,
                TerminatePath::PeerTerminal,
                session_start,
                ack_sent,
            )
            .await;
            return;
        }
        AckOutcome::Cancelled => return,
        AckOutcome::Failed(reason) => {
            fail_ws(&ctx, &mut ws, session_start, reason).await;
            return;
        }
    }
    send_event(
        &ctx.event_tx,
        BridgeEvent::MtaSendRequestSent {
            task_id: ctx.task_id.clone(),
        },
    )
    .await;

    // 3) 等待下载开始/完成与对端 status
    let mut phase_rx = ctx.phase_tx.subscribe();
    // 订阅时下载可能已开始（对端在 ack 后立即发起 /download）；也可能已因对端断开而中止
    let initial_phase = *phase_rx.borrow();
    if initial_phase == DownloadPhase::PeerAborted {
        fail_ws(&ctx, &mut ws, session_start, PEER_ABORT_REASON.to_string()).await;
        return;
    }
    let mut download_started = initial_phase != DownloadPhase::Idle;
    if download_started {
        send_event(
            &ctx.event_tx,
            BridgeEvent::MtaDownloadStarted {
                task_id: ctx.task_id.clone(),
            },
        )
        .await;
    }
    let mut deadline = tokio::time::Instant::now() + STATUS_WAIT_TIMEOUT;
    loop {
        tokio::select! {
            biased;
            // 本地停止服务器：终止会话，不发送失败事件
            // （取消是本地主动行为，UI 已退出传输页）
            _ = ctx.cancel.cancelled() => {
                log::debug!("MTA WS 状态机收到取消，终止会话");
                terminate_session(&mut ws, TerminatePath::Cancel, session_start, false).await;
                return;
            }
            // 本地登记取消意图（对端已连接：协商中/等待确认中/传输中）：立即回送取消状态并收尾
            _ = ctx.reject_notify.notified() => {
                if ctx.is_reject_pending() {
                    log::debug!("MTA 本地已取消，回送取消状态并结束状态机");
                    reject_peer(&ctx, &mut ws, session_start).await;
                    return;
                }
            }
            changed = phase_rx.changed() => {
                if changed.is_err() {
                    // 纯防御：phase 发送端由 Arc 全程持有，正常不会关闭；
                    // 一旦意外关闭则跳出循环，由循环尾按对端中止收尾
                    break;
                }
                let phase = *phase_rx.borrow();
                if phase == DownloadPhase::PeerAborted {
                    // 对端中途取消：下载连接已断开，立即终结发送状态机，
                    // 不再等待不会到来的 status（避免空等到状态等待超时）
                    fail_ws(&ctx, &mut ws, session_start, PEER_ABORT_REASON.to_string()).await;
                    return;
                }
                if phase == DownloadPhase::Started {
                    // Reset the idle budget only on the start of HTTP download or outgoing body data.
                    deadline = tokio::time::Instant::now() + STATUS_WAIT_TIMEOUT;
                    if !download_started {
                        download_started = true;
                        send_event(
                            &ctx.event_tx,
                            BridgeEvent::MtaDownloadStarted { task_id: ctx.task_id.clone() },
                        ).await;
                    }
                }
            }
            maybe = ws.next() => {
                match maybe {
                    Some(Ok(frame)) => {
                        // 会话级报文计数：每读到一帧即累加，供收尾统计判定「本端是否读到对端报文」
                        ctx.peer_frames.fetch_add(1, Ordering::SeqCst);
                        match frame_text(&frame) {
                            Some(text) => {
                                if let TextOutcome::Status { ack_sent } =
                                    dispatch_text(&ctx, &mut ws, text.as_str(), None, session_start).await
                                {
                                    // 时序约束：仅在收到对端终态并回送确认之后才终止会话（终态之前
                                    // 不得以成功语义结束）。对端只把未完成条目标记为失败，终态后终止
                                    // 不会把已完成传输误记为中断；ack_sent 为真时终止前保留宽限确保
                                    // 结果回执被对端读取，不因抢断连接而丢失。
                                    terminate_session(&mut ws, TerminatePath::PeerTerminal, session_start, ack_sent).await;
                                    return;
                                }
                            }
                            None => {
                                if matches!(frame, Message::Close(_)) {
                                    fail_ws(&ctx, &mut ws, session_start, "对端关闭了连接".to_string()).await;
                                    return;
                                }
                                // 非文本帧（Ping/Pong/其它）原样忽略；记日志以免"收到却无痕"
                                log::debug!(
                                    "MTA 收到非文本 WS 帧，忽略 相对耗时={}ms",
                                    elapsed_ms(session_start)
                                );
                            }
                        }
                    }
                    None => {
                        fail_ws(&ctx, &mut ws, session_start, "对端关闭了连接".to_string()).await;
                        return;
                    }
                    Some(Err(e)) => {
                        fail_ws(&ctx, &mut ws, session_start, format!("WS 读取错误: {e}")).await;
                        return;
                    }
                }
            }
            _ = tokio::time::sleep_until(deadline) => {
                fail_ws(&ctx, &mut ws, session_start, "等待对端传输状态超时".to_string()).await;
                return;
            }
        }
    }
    // 仅 phase 通道意外关闭（纯防御路径）会到达此处：按对端中止语义收尾
    fail_ws(&ctx, &mut ws, session_start, PEER_ABORT_REASON.to_string()).await;
}

/// 处理对端 status 消息并发射完成/部分完成/拒绝/失败事件。
///
/// 结果按「类型 + 原因」组合判定（见 [`protocol::classify_status`]）：成功类型 + 部分接收
/// 原因表示对端只收了部分文件，必须发部分完成事件而非成功事件。
async fn handle_status(ctx: &MtaContext, payload: &str) {
    let kind = protocol::classify_status(payload);
    let raw_reason = protocol::status_reason(payload);
    log::debug!("MTA 对端状态 kind={:?} reason={}", kind, raw_reason);
    match kind {
        StatusKind::Ok => {
            send_event(
                &ctx.event_tx,
                BridgeEvent::MtaSendCompleted {
                    task_id: ctx.task_id.clone(),
                },
            )
            .await;
        }
        StatusKind::Partial => {
            let reason = if raw_reason.is_empty() {
                "对端仅接收部分文件".to_string()
            } else {
                raw_reason
            };
            send_event(&ctx.event_tx, BridgeEvent::MtaSendPartial { reason }).await;
        }
        StatusKind::Refused => {
            let reason = if raw_reason.is_empty() {
                "对方拒绝".to_string()
            } else {
                raw_reason
            };
            send_event(&ctx.event_tx, BridgeEvent::MtaSendRejected { reason }).await;
        }
        StatusKind::TimedOut => {
            let reason = if raw_reason.is_empty() {
                "对方接收超时".to_string()
            } else {
                format!("对方接收超时（{raw_reason}）")
            };
            send_event(&ctx.event_tx, BridgeEvent::MtaSendFailed { reason }).await;
        }
        StatusKind::Other => {
            send_event(
                &ctx.event_tx,
                BridgeEvent::MtaSendFailed {
                    reason: format!("对端返回未知状态: {payload}"),
                },
            )
            .await;
        }
    }
}

/// [`wait_ack`] 的等待结果。
enum AckOutcome {
    /// 收到匹配 name 的确认报文（payload 可能为空串）
    Ack(Option<String>),
    /// 等待期间收到对端 status 并已发射终态事件：调用方应立即收尾，不再推进状态机。
    /// `ack_sent` 表示对端状态的结果回执（结束类指示）是否已成功写出。
    StatusTerminated { ack_sent: bool },
    /// 等待期间本地登记取消意图：取消状态已回送并收尾，调用方应立即返回
    Cancelled,
    /// 等待失败（超时 / 对端关闭 / 读取错误），携带可读原因
    Failed(String),
}

/// 一条收到的文本报文经 [`dispatch_text`] 处理后的归类。
enum TextOutcome {
    /// 命中期望的确认报文，携带其 payload
    Expected(String),
    /// 收到对端 status 并已发射终态事件：调用方应立即收尾。
    /// `ack_sent` 表示对端状态的结果回执（结束类指示）是否已成功写出。
    Status { ack_sent: bool },
    /// 其它报文（已按需回 ack 或忽略）
    Other,
}

/// 取 WS 帧承载的文本：Text 原样返回；Binary 按 UTF-8 解码（少数实现以二进制帧承载文本）；
/// Close/Ping/Pong 等无文本帧返回 None。
fn frame_text(message: &Message) -> Option<String> {
    match message {
        Message::Text(text) => Some(text.as_str().to_string()),
        Message::Binary(bytes) => std::str::from_utf8(&bytes[..]).ok().map(|s| s.to_string()),
        _ => None,
    }
}

/// 处理一条收到的 WS 文本报文（确认等待与状态等待两处共用）：
/// 对任意动作类消息回送确认（部分厂商接收端等待确认后才收尾）；
/// 收到 `status` 时调用 [`handle_status`] 并返回 [`TextOutcome::Status`]；
/// 命中 `expect_name` 返回 [`TextOutcome::Expected`]；无法解析的报文记日志后按
/// [`TextOutcome::Other`] 处理——避免"收到却无痕"导致问题不可诊断。
async fn dispatch_text<S>(
    ctx: &MtaContext,
    ws: &mut WebSocketStream<S>,
    text: &str,
    expect_name: Option<&str>,
    session_start: tokio::time::Instant,
) -> TextOutcome
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let message = match protocol::parse_message(text) {
        Some(message) => message,
        None => {
            log::debug!(
                "MTA 收到未识别的 WS 报文，忽略 相对耗时={}ms: {text}",
                elapsed_ms(session_start)
            );
            return TextOutcome::Other;
        }
    };
    log::debug!(
        "MTA 收到 WS 报文 {}:{}:{} payload={} 相对耗时={}ms",
        message.msg_type,
        message.id,
        message.name,
        message.payload,
        elapsed_ms(session_start)
    );
    // 对任意动作类消息回送确认；对 status 而言该确认即本端结束类指示（结果回执）。
    // ack_sent 记录其是否成功写出，供收尾时判定「指示已送出」并据此决定是否保留送达宽限。
    let ack_sent = match protocol::build_ack(&message) {
        Some(ack) => {
            log::debug!(
                "MTA 发送确认 type=ack id={} name={}",
                message.id,
                message.name
            );
            match ws.send(Message::text(ack)).await {
                Ok(()) => true,
                Err(e) => {
                    log::warn!("MTA 回送 ack 失败: {e}");
                    false
                }
            }
        }
        None => false,
    };
    if message.name == "status" {
        handle_status(ctx, &message.payload).await;
        return TextOutcome::Status { ack_sent };
    }
    if let Some(want) = expect_name {
        if message.name == want {
            return TextOutcome::Expected(message.payload);
        }
    }
    TextOutcome::Other
}

/// 等待指定 name 的 ack 消息（type 不限定）。
///
/// 等待期间到达的报文按主循环同款语义处理：对任意动作类消息回送确认（部分厂商接收端等待
/// 确认后才收尾）；一旦收到对端 `status` 即调用 [`handle_status`] 并返回
/// [`AckOutcome::StatusTerminated`]——快速拒绝时状态常与 `sendRequest` 确认几乎同时到达、
/// 先后不定，若在此处丢弃状态，发送端将空等到状态等待超时（用户长时间无反馈）。
async fn wait_ack<S>(
    ctx: &MtaContext,
    ws: &mut WebSocketStream<S>,
    name: &str,
    timeout: Duration,
    session_start: tokio::time::Instant,
) -> AckOutcome
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        tokio::select! {
            biased;
            // 本地停止服务器：终止会话，不发送失败事件（与主循环的取消分支同语义）；
            // 缺此分支会空等到 ack 超时再误发一次失败事件
            _ = ctx.cancel.cancelled() => {
                log::debug!("MTA WS 握手等待 {name} 确认期间收到取消，终止会话");
                terminate_session(ws, TerminatePath::Cancel, session_start, false).await;
                return AckOutcome::Cancelled;
            }
            // 本地登记取消意图：立即回送取消状态并收尾，不再等待对端确认
            _ = ctx.reject_notify.notified() => {
                if ctx.is_reject_pending() {
                    log::debug!("MTA 本地已取消（等待 {name} 确认期间），回送取消状态");
                    reject_peer(ctx, ws, session_start).await;
                    return AckOutcome::Cancelled;
                }
            }
            maybe = ws.next() => {
                match maybe {
                    Some(Ok(frame)) => {
                        // 会话级报文计数：每读到一帧即累加（含确认等待期间的帧）
                        ctx.peer_frames.fetch_add(1, Ordering::SeqCst);
                        match frame_text(&frame) {
                            Some(text) => {
                                match dispatch_text(ctx, ws, text.as_str(), Some(name), session_start).await {
                                    TextOutcome::Expected(payload) => {
                                        return AckOutcome::Ack(Some(payload))
                                    }
                                    TextOutcome::Status { ack_sent } => {
                                        return AckOutcome::StatusTerminated { ack_sent }
                                    }
                                    TextOutcome::Other => {}
                                }
                            }
                            None => {
                                if matches!(frame, Message::Close(_)) {
                                    return AckOutcome::Failed("对端关闭了连接".to_string());
                                }
                                log::debug!(
                                    "MTA 收到非文本 WS 帧，忽略 相对耗时={}ms",
                                    elapsed_ms(session_start)
                                );
                            }
                        }
                    }
                    None => return AckOutcome::Failed("对端关闭了连接".to_string()),
                    Some(Err(e)) => return AckOutcome::Failed(format!("WS 读取错误: {e}")),
                }
            }
            _ = tokio::time::sleep_until(deadline) => {
                return AckOutcome::Failed(format!("等待 {name} 确认超时"));
            }
        }
    }
}

/// 校验版本协商 ack：payload 携带 version 且与本端协议版本不一致时返回错误文本。
/// 宽松策略：payload 缺失、为空、解析失败或无 version 字段均视为兼容。
fn check_version_ack(payload: Option<&str>) -> Option<String> {
    let payload = payload?;
    if payload.is_empty() {
        return None;
    }
    #[derive(serde::Deserialize)]
    struct VersionAck {
        version: Option<i64>,
    }
    match serde_json::from_str::<VersionAck>(payload) {
        Ok(ack) => match ack.version {
            Some(v) if v != protocol::PROTOCOL_VERSION => Some(format!(
                "对端选定协议版本 {v} 与本端 {} 不兼容",
                protocol::PROTOCOL_VERSION
            )),
            _ => None,
        },
        Err(_) => None,
    }
}

/// 记录并发射发送失败事件，随后终止会话。
///
/// 先发事件再终止：失败路径的用户可见结果与既有路径一致（不因收尾过程而延后呈现）；
/// 失败路径无结束类指示需送达，终止过程不等待，连接已断裂时立即返回，不引入额外等待。
async fn fail_ws<S>(
    ctx: &MtaContext,
    ws: &mut WebSocketStream<S>,
    session_start: tokio::time::Instant,
    reason: String,
) where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    log::error!("MTA 发送失败: {reason}");
    send_event(&ctx.event_tx, BridgeEvent::MtaSendFailed { reason }).await;
    terminate_session(ws, TerminatePath::Fail, session_start, false).await;
}

/// 回送取消状态并收尾：写取消状态 → 终止会话 → 发出 `MtaRejectSent`。
///
/// 取消状态仅在对端连接可写时视为「已通知对端」并发事件；写入失败（对端接入后立即断开）
/// 不发事件，由上层按「未能通知对端」收尾。返回后调用方应立即结束状态机，
/// 不再推进握手、也不等待对端状态。语义保持既有口径：先回送结果，再完成收尾过程；
/// 取消状态即本路径的结束类指示，写入成功时在终止前保留有界宽限确保其被对端读取。
async fn reject_peer<S>(
    ctx: &MtaContext,
    ws: &mut WebSocketStream<S>,
    session_start: tokio::time::Instant,
) where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let message = protocol::cancel_status_message(&ctx.task_id);
    log::debug!("MTA 回送取消状态 taskId={}", ctx.task_id);
    let sent = ws.send(Message::text(message)).await.is_ok();
    terminate_session(ws, TerminatePath::Reject, session_start, sent).await;
    if sent {
        send_event(
            &ctx.event_tx,
            BridgeEvent::MtaRejectSent {
                task_id: ctx.task_id.clone(),
            },
        )
        .await;
    } else {
        log::warn!(
            "MTA 回送取消状态失败（对端连接不可写）taskId={}",
            ctx.task_id
        );
    }
}

/// 会话终止的收尾路径（用于可观测性：日志标注本次终止来自哪条路径）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TerminatePath {
    /// 收到对端传输终态并回送确认之后（成功/部分完成/拒绝/超时均经此路径）
    PeerTerminal,
    /// 本地取消并已回送取消状态之后
    Reject,
    /// 本地停止服务器（取消是本地主动行为）
    Cancel,
    /// 失败收尾
    Fail,
}

impl TerminatePath {
    /// 日志标签
    fn label(self) -> &'static str {
        match self {
            TerminatePath::PeerTerminal => "对端终态后",
            TerminatePath::Reject => "回送取消状态后",
            TerminatePath::Cancel => "本地取消",
            TerminatePath::Fail => "失败收尾",
        }
    }

    /// 是否先给对端机会自行关闭（保留为可选快路径；取消/失败路径不等待，避免额外延时）
    fn peer_first_close(self) -> bool {
        matches!(self, TerminatePath::PeerTerminal)
    }
}

/// 统一「会话终止」过程：在确保结束类指示（结果回执 / 取消状态）已被对端读取之后，
/// 以**连接终止**结束会话。
///
/// **不发 WebSocket 关闭帧**：目标对端（OkHttp WebSocket 客户端）的「关闭完成」回调只在
/// 客户端自身发起关闭时触发，且收到服务端关闭帧后即停止读取——服务端发关闭帧只会触发其
/// 空实现的「关闭中」回调，对端自身收尾（解除忙态）永不执行。直接终止连接（由调用方返回后
/// 释放 `WebSocketStream`，Drop 关闭底层流）使对端进入其可处理的「连接失败终止」路径并完成
/// 自身收尾；结束语义由已发送的结果报文承载，不依赖关闭帧。
///
/// 时序约束：本函数只服务于收尾，禁止在收到对端终态之前以成功语义调用；成功路径必须先由
/// [`dispatch_text`] 分派终态事件并回送确认，之后才调用本函数。
///
/// `directive_delivered` 表示本路径是否已向对端写出结束类指示（结果回执 / 取消状态）：为真时
/// 在终止连接前保留有界宽限，确保该指示被对端读取（不因抢断连接而丢失）；为假（无指示或写入
/// 失败）不额外等待。对端主动先行关闭时走快路径直接结束。
async fn terminate_session<S>(
    ws: &mut WebSocketStream<S>,
    path: TerminatePath,
    session_start: tokio::time::Instant,
    directive_delivered: bool,
) where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let wait_start = tokio::time::Instant::now();
    // 可选快路径：终态路径先给对端机会自行关闭（对端随即关闭时无需再等待）
    let peer_closed_first = PEER_FIRST_CLOSE_ENABLED
        && path.peer_first_close()
        && wait_peer_close(ws, PEER_FIRST_CLOSE_GRACE).await;
    let mut peer_closed_during_grace = false;
    if !peer_closed_first && directive_delivered {
        // 终止连接前保留有界宽限：继续驱动读取（丢弃对端后续帧），给对端读取结束类指示留出时间
        peer_closed_during_grace = wait_peer_close(ws, PRE_TERMINATE_GRACE).await;
    }
    // 以连接终止结束会话：不发 WS 关闭帧。直接返回后由调用方释放 WebSocketStream 关闭底层流，
    // 使对端进入其可处理的「连接失败终止」路径并完成自身收尾。
    //
    // 可观测性字段：「指示已送出」记录结束类指示（结果回执 / 取消状态）是否已在终止前写出
    // （被对端读取无法在本端直接观测，故以「已写出 + 有界送达宽限」为其可观测代理）；
    // 「终止方式」恒为连接终止；「对端先关」/「宽限内对端结束」描述对端先行关闭快路径与
    // 宽限内的连接结束；「终止前等待」「相对耗时」给出收尾耗时，用于核对不引入可感知额外等待。
    log::debug!(
        "MTA WS 会话终止 path={} 终止方式=连接终止(未发送关闭帧) 指示已送出={} 对端先关={} 宽限内对端结束={} 终止前等待={}ms 相对耗时={}ms",
        path.label(),
        if directive_delivered { "是" } else { "否" },
        if peer_closed_first { "是" } else { "否" },
        if peer_closed_during_grace { "是" } else { "否" },
        wait_start.elapsed().as_millis(),
        elapsed_ms(session_start),
    );
}

/// 等待对端关闭 WS 连接或超时/连接结束后再返回。
/// 返回 true 表示读到对端的关闭帧（对端主动先行关闭）；false 表示超时或连接自然结束。
/// 供「对端先行关闭」快路径与「终止前指示送达」宽限共用；期间收到的其它帧一律忽略。
async fn wait_peer_close<S>(ws: &mut WebSocketStream<S>, timeout: Duration) -> bool
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        tokio::select! {
            maybe = ws.next() => {
                match maybe {
                    Some(Ok(Message::Close(_))) => return true,
                    None | Some(Err(_)) => return false,
                    _ => {}
                }
            }
            _ = tokio::time::sleep_until(deadline) => return false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 构造测试用 MtaContext（空文件清单），同时返回相位通道发送端，
    /// 供测试驱动相位迁移。
    fn test_context_with_phase(
        task_id: &str,
        event_tx: tokio::sync::mpsc::Sender<BridgeEvent>,
    ) -> (Arc<MtaContext>, tokio::sync::watch::Sender<DownloadPhase>) {
        use crate::bridge::mta::MtaFileEntry;
        let (phase_tx, _phase_rx) = tokio::sync::watch::channel(DownloadPhase::Idle);
        let ctx = Arc::new(MtaContext {
            task_id: task_id.to_string(),
            sender_id: "s1".to_string(),
            sender_name: "tester".to_string(),
            files: Vec::<MtaFileEntry>::new(),
            file_name: "a.txt".to_string(),
            mime_type: "application/zip".to_string(),
            thumbnail: None,
            file_count: 0,
            total_size: 0,
            text_content: None,
            sender_brand_id: None,
            sender_brand: None,
            event_tx: Some(event_tx),
            phase_tx: phase_tx.clone(),
            ws_connected: AtomicBool::new(false),
            cancel: tokio_util::sync::CancellationToken::new(),
            fds_consumed: Arc::new(std::sync::Mutex::new(Vec::new())),
            download_served: AtomicBool::new(false),
            peer_frames: std::sync::atomic::AtomicUsize::new(0),
            reject_pending: AtomicBool::new(false),
            reject_notify: tokio::sync::Notify::new(),
        });
        (ctx, phase_tx)
    }

    /// 构造测试用 MtaContext（空文件清单）：事件经返回通道消费；取消意图由测试侧
    /// 经返回的 `Arc` 登记。
    fn test_context(
        task_id: &str,
        event_tx: tokio::sync::mpsc::Sender<BridgeEvent>,
    ) -> Arc<MtaContext> {
        test_context_with_phase(task_id, event_tx).0
    }

    /// 排空事件通道并返回 `MtaRejectSent` 携带的任务 ID（未收到返回 `None`）。
    fn drain_reject_sent(rx: &mut tokio::sync::mpsc::Receiver<BridgeEvent>) -> Option<String> {
        let mut task_id: Option<String> = None;
        while let Ok(event) = rx.try_recv() {
            if let BridgeEvent::MtaRejectSent { task_id: id } = event {
                task_id = Some(id);
            }
        }
        task_id
    }

    /// 下载因对端断开被置为 PeerAborted 时，WS 状态机须立即终结并发射发送失败事件，
    /// 不再空等到状态等待超时。以内存双向流模拟已升级的 WS 连接。
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn peer_abort_phase_terminates_ws_state_machine() {
        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(32);
        let (ctx, phase_tx) = test_context_with_phase("t-abort", event_tx);

        let (server_io, client_io) = tokio::io::duplex(32 * 1024);
        let task = tokio::spawn(async move { run_ws(server_io, ctx).await });
        let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;

        // 版本协商 → 回 ack
        let negotiation = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(negotiation.contains("versionNegotiation"));
        client
            .send(Message::text("ack:0:versionNegotiation?{\"version\":1}"))
            .await
            .unwrap();
        // sendRequest → 回空 ack
        let request = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(request.contains("sendRequest"));
        client
            .send(Message::text("ack:1:sendRequest"))
            .await
            .unwrap();

        // 对端中途取消：下载阶段转终止态
        phase_tx.send_replace(DownloadPhase::PeerAborted);

        let finished = tokio::time::timeout(Duration::from_secs(5), task).await;
        assert!(finished.is_ok(), "对端中止后 WS 状态机应立即结束");

        let mut failed_reason: Option<String> = None;
        while let Ok(event) = event_rx.try_recv() {
            if let BridgeEvent::MtaSendFailed { reason } = event {
                failed_reason = Some(reason);
            }
        }
        let reason = failed_reason.expect("应发射 MtaSendFailed");
        assert!(reason.contains("取消"), "失败原因应可读: {reason}");
    }

    /// 用户在对端接入前取消（取消意图已置位）：对端接入后立即收到取消状态并发
    /// `MtaRejectSent`，且状态机不推进版本协商与 sendRequest。
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn reject_intent_before_connect_sends_cancel_status() {
        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(32);
        let ctx = test_context("t-reject-pre", event_tx);
        // 对端接入前即登记取消意图
        ctx.mark_reject_pending();

        let (server_io, client_io) = tokio::io::duplex(32 * 1024);
        let runner = Arc::clone(&ctx);
        let task = tokio::spawn(async move { run_ws(server_io, runner).await });
        let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;

        // 首帧即取消状态（不经过版本协商）
        let first = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(
            !first.contains("versionNegotiation"),
            "取消意图已生效时不应推进版本协商: {first}"
        );
        assert!(first.contains("status"), "首帧应为取消状态: {first}");
        assert!(first.contains("\"type\":3"), "应为终止类型: {first}");
        assert!(first.contains("user refuse"), "应携带拒绝原因: {first}");
        assert!(first.contains("t-reject-pre"), "应携带 taskId: {first}");

        let finished = tokio::time::timeout(Duration::from_secs(5), task).await;
        assert!(finished.is_ok(), "回送取消状态后状态机应立即结束");
        assert_eq!(
            drain_reject_sent(&mut event_rx).as_deref(),
            Some("t-reject-pre")
        );
    }

    /// 取消意图在「等待版本确认」期间登记：立即回送取消状态、关闭连接并发出
    /// `MtaRejectSent` 后收尾（不抢先发送 sendRequest）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn reject_intent_during_version_ack_sends_cancel_status() {
        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(32);
        let ctx = test_context("t-reject-ver", event_tx);
        let (server_io, client_io) = tokio::io::duplex(32 * 1024);
        let runner = Arc::clone(&ctx);
        let task = tokio::spawn(async move { run_ws(server_io, runner).await });
        let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;

        let negotiation = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(negotiation.contains("versionNegotiation"));
        // 不回版本 ack，改为登记取消意图
        ctx.mark_reject_pending();

        let cancel = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(cancel.contains("status"), "应回送取消状态: {cancel}");
        assert!(cancel.contains("user refuse"), "应携带拒绝原因: {cancel}");
        assert!(
            !cancel.contains("sendRequest"),
            "不应抢先发送 sendRequest: {cancel}"
        );

        let finished = tokio::time::timeout(Duration::from_secs(5), task).await;
        assert!(finished.is_ok(), "回送取消状态后状态机应立即结束");
        assert_eq!(
            drain_reject_sent(&mut event_rx).as_deref(),
            Some("t-reject-ver")
        );
    }

    /// 取消意图在「等待 sendRequest 确认」期间登记：立即回送取消状态并发
    /// `MtaRejectSent` 后收尾。
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn reject_intent_during_send_request_ack_sends_cancel_status() {
        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(32);
        let ctx = test_context("t-reject-req", event_tx);
        let (server_io, client_io) = tokio::io::duplex(32 * 1024);
        let runner = Arc::clone(&ctx);
        let task = tokio::spawn(async move { run_ws(server_io, runner).await });
        let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;

        // 版本协商 → 回 ack
        let negotiation = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(negotiation.contains("versionNegotiation"));
        client
            .send(Message::text("ack:0:versionNegotiation?{\"version\":1}"))
            .await
            .unwrap();
        // 收到 sendRequest（未抢先取消）后登记取消意图，不回确认
        let request = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(request.contains("sendRequest"));
        ctx.mark_reject_pending();

        let cancel = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(cancel.contains("status"), "应回送取消状态: {cancel}");
        assert!(cancel.contains("user refuse"), "应携带拒绝原因: {cancel}");

        let finished = tokio::time::timeout(Duration::from_secs(5), task).await;
        assert!(finished.is_ok(), "回送取消状态后状态机应立即结束");
        assert_eq!(
            drain_reject_sent(&mut event_rx).as_deref(),
            Some("t-reject-req")
        );
    }

    /// 取消意图在「等待对端状态」期间登记（含传输中取消）：立即回送取消状态并发
    /// `MtaRejectSent` 后收尾。
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn reject_intent_during_status_wait_sends_cancel_status() {
        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(32);
        let ctx = test_context("t-reject-status", event_tx);
        let (server_io, client_io) = tokio::io::duplex(32 * 1024);
        let runner = Arc::clone(&ctx);
        let task = tokio::spawn(async move { run_ws(server_io, runner).await });
        let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;

        // 版本协商 → 回 ack；sendRequest → 回空 ack
        let negotiation = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(negotiation.contains("versionNegotiation"));
        client
            .send(Message::text("ack:0:versionNegotiation?{\"version\":1}"))
            .await
            .unwrap();
        let request = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(request.contains("sendRequest"));
        client
            .send(Message::text("ack:1:sendRequest"))
            .await
            .unwrap();

        // 以 mtaSendRequestSent 事件为界，确认状态机已进入等待对端状态循环
        let entered = tokio::time::timeout(Duration::from_secs(5), async {
            while let Some(event) = event_rx.recv().await {
                if matches!(event, BridgeEvent::MtaSendRequestSent { .. }) {
                    return true;
                }
            }
            false
        })
        .await
        .unwrap_or(false);
        assert!(entered, "状态机应进入等待对端状态阶段");

        ctx.mark_reject_pending();
        let cancel = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(cancel.contains("status"), "应回送取消状态: {cancel}");
        assert!(cancel.contains("user refuse"), "应携带拒绝原因: {cancel}");

        let finished = tokio::time::timeout(Duration::from_secs(5), task).await;
        assert!(finished.is_ok(), "回送取消状态后状态机应立即结束");
        assert_eq!(
            drain_reject_sent(&mut event_rx).as_deref(),
            Some("t-reject-status")
        );
    }

    /// 对端在 `sendRequest` 确认之前先回送拒绝状态（快速拒绝时确认与状态几乎同时到达、
    /// 先后不定）：状态机须立即以 `MtaSendRejected` 终结，不得丢弃状态后空等状态超时。
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn status_before_send_request_ack_terminates_with_rejection() {
        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(32);
        let ctx = test_context("t-reject", event_tx);
        // 保留一份 Arc，供任务结束后读取会话级报文计数
        let ctx_probe = Arc::clone(&ctx);

        let (server_io, client_io) = tokio::io::duplex(32 * 1024);
        let task = tokio::spawn(async move { run_ws(server_io, ctx).await });
        let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;

        // 版本协商 → 回 ack
        let negotiation = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(negotiation.contains("versionNegotiation"));
        client
            .send(Message::text("ack:0:versionNegotiation?{\"version\":1}"))
            .await
            .unwrap();
        // sendRequest → 不回确认，直接回拒绝状态（模拟状态先于确认到达）
        let request = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(request.contains("sendRequest"));
        client
            .send(Message::text(
                "action:99:status?{\"taskId\":\"t-reject\",\"type\":3,\"reason\":\"user refuse\"}",
            ))
            .await
            .unwrap();

        let finished = tokio::time::timeout(Duration::from_secs(5), task).await;
        assert!(finished.is_ok(), "确认前先收到拒绝状态时应立即结束状态机");

        // 收到对端状态后会话级报文计数应 ≥1：证明 status 确被本端读到（而非漏收）
        assert!(
            ctx_probe.peer_frames.load(Ordering::SeqCst) >= 1,
            "收到对端状态后会话报文计数应 ≥1"
        );

        let mut rejected_reason: Option<String> = None;
        while let Ok(event) = event_rx.try_recv() {
            if let BridgeEvent::MtaSendRejected { reason } = event {
                rejected_reason = Some(reason);
            }
        }
        assert_eq!(rejected_reason.as_deref(), Some("user refuse"));
    }

    /// 少数实现以二进制帧承载文本：`status` 以 Binary 帧到达时也应被识别并立即以拒绝终结。
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn binary_status_frame_terminates_with_rejection() {
        use bytes::Bytes;

        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(32);
        let ctx = test_context("t-bin", event_tx);

        let (server_io, client_io) = tokio::io::duplex(32 * 1024);
        let task = tokio::spawn(async move { run_ws(server_io, ctx).await });
        let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;

        // 版本协商 → 回 ack；sendRequest → 回空 ack
        let negotiation = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(negotiation.contains("versionNegotiation"));
        client
            .send(Message::text("ack:0:versionNegotiation?{\"version\":1}"))
            .await
            .unwrap();
        let request = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(request.contains("sendRequest"));
        client
            .send(Message::text("ack:1:sendRequest"))
            .await
            .unwrap();
        // 以二进制帧发送 status（载荷为文本，仅帧类型不同）
        client
            .send(Message::Binary(Bytes::from_static(
                b"action:99:status?{\"taskId\":\"t-bin\",\"type\":3,\"reason\":\"user refuse\"}",
            )))
            .await
            .unwrap();

        let finished = tokio::time::timeout(Duration::from_secs(5), task).await;
        assert!(
            finished.is_ok(),
            "二进制帧承载的拒绝状态应被识别并立即结束状态机"
        );

        let mut rejected_reason: Option<String> = None;
        while let Ok(event) = event_rx.try_recv() {
            if let BridgeEvent::MtaSendRejected { reason } = event {
                rejected_reason = Some(reason);
            }
        }
        assert_eq!(rejected_reason.as_deref(), Some("user refuse"));
    }

    // 版本协商 ack 校验：宽松兼容 + 不兼容版本拒绝
    #[test]
    fn check_version_ack_lenient() {
        assert_eq!(check_version_ack(None), None);
        assert_eq!(check_version_ack(Some("")), None);
        // 解析失败或无 version 字段视为兼容
        assert_eq!(check_version_ack(Some("not-json")), None);
        assert_eq!(check_version_ack(Some("{}")), None);
        assert_eq!(check_version_ack(Some("{\"threadLimit\":5}")), None);
    }

    #[test]
    fn check_version_ack_rejects_mismatch() {
        // 对端选定不同版本：拒绝
        assert!(check_version_ack(Some("{\"version\":2,\"threadLimit\":5}")).is_some());
        // 对端选定本端版本：通过
        assert_eq!(
            check_version_ack(Some("{\"version\":1,\"threadLimit\":5}")),
            None
        );
    }

    /// 对端回送「成功类型 + 部分接收原因」时，状态机须发部分完成事件，
    /// 不得发发送成功事件（此前该报文被误判为成功）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn partial_status_terminates_with_partial_event() {
        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(32);
        let ctx = test_context("t-partial", event_tx);

        let (server_io, client_io) = tokio::io::duplex(32 * 1024);
        let task = tokio::spawn(async move { run_ws(server_io, ctx).await });
        let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;

        // 版本协商 → 回 ack；sendRequest → 回空 ack
        let negotiation = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(negotiation.contains("versionNegotiation"));
        client
            .send(Message::text("ack:0:versionNegotiation?{\"version\":1}"))
            .await
            .unwrap();
        let request = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(request.contains("sendRequest"));
        client
            .send(Message::text("ack:1:sendRequest"))
            .await
            .unwrap();
        // 对端回送「成功类型 + 部分接收原因」
        client
            .send(Message::text(
                "action:99:status?{\"taskId\":\"t-partial\",\"type\":1,\"reason\":\"partial\"}",
            ))
            .await
            .unwrap();

        let finished = tokio::time::timeout(Duration::from_secs(5), task).await;
        assert!(finished.is_ok(), "收到部分完成状态后状态机应立即结束");

        let mut partial_reason: Option<String> = None;
        let mut completed = false;
        while let Ok(event) = event_rx.try_recv() {
            match event {
                BridgeEvent::MtaSendPartial { reason } => partial_reason = Some(reason),
                BridgeEvent::MtaSendCompleted { .. } => completed = true,
                _ => {}
            }
        }
        assert_eq!(partial_reason.as_deref(), Some("partial"));
        assert!(!completed, "部分接收不得发发送成功事件");
    }

    /// 对端回送「终止类型 + 超时原因」时，须以可读的超时原因发失败事件。
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn timeout_status_terminates_with_readable_failure() {
        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(32);
        let ctx = test_context("t-timeout", event_tx);

        let (server_io, client_io) = tokio::io::duplex(32 * 1024);
        let task = tokio::spawn(async move { run_ws(server_io, ctx).await });
        let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;

        let negotiation = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(negotiation.contains("versionNegotiation"));
        client
            .send(Message::text("ack:0:versionNegotiation?{\"version\":1}"))
            .await
            .unwrap();
        let request = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(request.contains("sendRequest"));
        client
            .send(Message::text(
                "action:99:status?{\"taskId\":\"t-timeout\",\"type\":3,\"reason\":\"timeout\"}",
            ))
            .await
            .unwrap();

        let finished = tokio::time::timeout(Duration::from_secs(5), task).await;
        assert!(finished.is_ok(), "收到超时状态后状态机应立即结束");

        let mut failed_reason: Option<String> = None;
        while let Ok(event) = event_rx.try_recv() {
            if let BridgeEvent::MtaSendFailed { reason } = event {
                failed_reason = Some(reason);
            }
        }
        let reason = failed_reason.expect("应发射 MtaSendFailed");
        assert!(
            reason.contains("超时"),
            "失败原因应可读且指明超时: {reason}"
        );
    }

    /// 成功终态收尾时序保护：先回送对状态的回执（结束类指示），随后才以连接终止结束会话
    /// （不发关闭帧）。以「先读到回执、后连接结束」锁定「终态之前不得以成功语义结束会话」
    /// 与「结束类指示不得因抢断连接而丢失」两条约束。
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn success_terminal_acks_then_terminates_without_close_frame() {
        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(32);
        let ctx = test_context("t-term-ok", event_tx);
        let (server_io, client_io) = tokio::io::duplex(32 * 1024);
        let task = tokio::spawn(async move { run_ws(server_io, ctx).await });
        let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;

        // 版本协商 → 回 ack；sendRequest → 回空 ack
        let negotiation = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(negotiation.contains("versionNegotiation"));
        client
            .send(Message::text("ack:0:versionNegotiation?{\"version\":1}"))
            .await
            .unwrap();
        let request = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(request.contains("sendRequest"));
        client
            .send(Message::text("ack:1:sendRequest"))
            .await
            .unwrap();

        // 对端回送成功终态
        client
            .send(Message::text(
                "action:99:status?{\"taskId\":\"t-term-ok\",\"type\":1,\"reason\":\"ok\"}",
            ))
            .await
            .unwrap();

        // 先读到对状态的回执，随后连接终止（无关闭帧）
        let mut saw_ack = false;
        loop {
            match tokio::time::timeout(Duration::from_secs(10), client.next()).await {
                Ok(Some(Ok(Message::Text(text)))) => {
                    if text.as_str().contains("ack:99:status") {
                        saw_ack = true;
                    }
                }
                Ok(Some(Ok(Message::Close(frame)))) => {
                    panic!("会话终止不得发送关闭帧: {frame:?}");
                }
                Ok(Some(Ok(_))) => {}
                Ok(Some(Err(_))) | Ok(None) => break,
                Err(_) => panic!("成功收尾应在有界时间内以连接终止结束"),
            }
        }
        assert!(saw_ack, "终止前应先回送对状态的回执");

        let finished = tokio::time::timeout(Duration::from_secs(5), task).await;
        assert!(finished.is_ok(), "成功收尾应结束会话");

        let mut completed = false;
        while let Ok(event) = event_rx.try_recv() {
            if matches!(event, BridgeEvent::MtaSendCompleted { .. }) {
                completed = true;
            }
        }
        assert!(completed, "成功收尾应发射 MtaSendCompleted");
    }
}
