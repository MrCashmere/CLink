//! MTA 桥接 NAPI 入口。
//!
//! 发送端：`nativeMtaStartServer` / `nativeMtaStopServer` / `nativeMtaRejectPeer`。
//! 接收端：Rust 主导下载 `nativeMtaReceiveDownload`（reqwest + 流式解压 + 直接写目标目录）。
//! 服务器事件（`mta*`）与接收进度（`mtaReceiveProgress`）经统一的 event_forwarder
//! 推送到 ArkTS。

use std::sync::{Arc, Mutex};
use std::time::Duration;

use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::*;
use tokio_util::sync::CancellationToken;

use crate::bridge::lock;
use crate::bridge::mta::unzip_stream::ZipParseOptions;
use crate::bridge::mta::{self, receive};
use crate::bridge::state::BridgeState;
use crate::napi::env::NapiEnv;

/// 启动 MTA 发送端服务器（流式 ZIP，无预打包），返回 `{"port":<实际绑定端口>}` JSON 文本。
#[napi]
pub async fn native_mta_start_server(config_json: String) -> Result<String> {
    let env = NapiEnv::global();
    // 确保事件通道存在（Mta* 事件依赖 state.event_tx）
    env.ensure_event_channel();
    let port = mta::start_server(env.state, &config_json)
        .await
        .map_err(|e| Error::from_reason(format!("启动 MTA 服务器失败: {e:#}")))?;
    Ok(format!("{{\"port\":{port}}}"))
}

/// 停止 MTA 发送端服务器（幂等；不删除暂存文件）。
#[napi]
pub fn native_mta_stop_server() -> Result<()> {
    mta::stop_server();
    Ok(())
}

/// 登记「向对端回送取消」意图（不停止服务器）。
///
/// 服务器不存在时为空操作（更早的发送阶段对端尚无凭据、无法接入）。
/// 取消状态由 WS 状态机在对端接入或等待阶段回送，回送成功后经 `mtaRejectSent`
/// 事件通知 ArkTS；服务器与 P2P 群组保持可接入，等待对端被通知或由上层结束会话。
#[napi]
pub fn native_mta_reject_peer() -> Result<()> {
    mta::reject_peer();
    Ok(())
}

/// 拉取 MTA 发送端提供的缩略图（接收确认阶段的图片预览）：`GET /thumbnail?taskId=<任务 ID>`，
/// 与下载同一 TLS 通道（自签名证书跳过校验），按魔数识别格式后写入 `target_dir`（缓存目录），
/// 成功返回落盘路径（含识别出的扩展名）；失败返回空串（属可选增强，不抛错、不阻断接收主流程）。
#[napi]
pub async fn native_mta_fetch_thumbnail(
    go_ip: String,
    port: u16,
    task_id: String,
    target_dir: String,
    connect_timeout_ms: Option<f64>,
    max_bytes: f64,
) -> Result<String> {
    let connect_timeout = duration_from_ms(connect_timeout_ms, receive::DEFAULT_CONNECT_TIMEOUT);
    let max_bytes = normalized_u64(max_bytes);
    match mta::receive::fetch_thumbnail(
        &go_ip,
        port,
        &task_id,
        &target_dir,
        connect_timeout,
        max_bytes,
    )
    .await
    {
        Ok(path) => Ok(path),
        Err(error) => {
            log::debug!("MTA 缩略图拉取失败: {error:#}");
            Ok(String::new())
        }
    }
}

/// 读取指定网络接口的硬件地址（MAC，形如 `AA:BB:CC:DD:EE:FF`）；接口不存在或读取失败返回空串。
///
/// 用途：MTA 发送端需把本机 P2P 设备地址写入 `P2pInfo.mac`（对端以该地址识别群主，
/// 不一致时小米端会报 unrecognized network owner）。HarmonyOS 对三方应用屏蔽了
/// `getCurrentGroup().ownerInfo.deviceAddress`（随机值）与 `getP2pLocalDevice()`（全零），
/// 故改由 Native 直接读取网卡硬件地址。
#[napi]
pub fn native_get_interface_mac(interface_name: String) -> String {
    let name = match std::ffi::CString::new(interface_name) {
        Ok(v) => v,
        Err(_) => return String::new(),
    };
    unsafe {
        let mut ifap: *mut libc::ifaddrs = std::ptr::null_mut();
        if libc::getifaddrs(&mut ifap) != 0 {
            return String::new();
        }
        let mut found = String::new();
        let mut cur = ifap;
        while !cur.is_null() && found.is_empty() {
            let ifa = &*cur;
            if !ifa.ifa_name.is_null()
                && !ifa.ifa_addr.is_null()
                && std::ffi::CStr::from_ptr(ifa.ifa_name).to_bytes() == name.to_bytes()
            {
                let sa = ifa.ifa_addr;
                if (*sa).sa_family as i32 == libc::AF_PACKET {
                    let sll = sa as *const libc::sockaddr_ll;
                    if (*sll).sll_halen as usize >= 6 {
                        let addr = &(*sll).sll_addr;
                        found = format!(
                            "{:02X}:{:02X}:{:02X}:{:02X}:{:02X}:{:02X}",
                            addr[0], addr[1], addr[2], addr[3], addr[4], addr[5]
                        );
                    }
                }
            }
            cur = ifa.ifa_next;
        }
        libc::freeifaddrs(ifap);
        found
    }
}

/// 接收端 Rust 主导下载：请求 `/download`、流式解压并直接写入 `target_dir`。
///
/// 成功返回落盘元数据 JSON `[{name,size,modifiedUnixMs,savedPath}]`；失败返回可读原因
/// （响应码异常/停滞/取消/解压或写盘失败），且本次已写入的目标文件已清理。
///
/// `cancelTokenId` 为可选取消令牌 id（登记在 BridgeState.cancel_tokens）；亦可经
/// `nativeCancelTransferLocal(taskId)` 取消本次下载。
/// `maxEntryBytes` 为单条目解压上限（0 表示不限制）；`maxTotalBytes` 为解压总量上限。
/// `connectTimeoutMs` / `stallTimeoutMs` / `headerTimeoutMs` 覆盖连接、下载停滞与
/// 等待响应头超时，缺省用 Rust 侧默认值。
#[napi]
#[allow(clippy::too_many_arguments)]
pub async fn native_mta_receive_download(
    go_ip: String,
    port: u16,
    task_id: String,
    target_dir: String,
    total_bytes: f64,
    max_entries: u32,
    max_total_bytes: f64,
    max_entry_bytes: f64,
    cancel_token_id: Option<String>,
    connect_timeout_ms: Option<f64>,
    stall_timeout_ms: Option<f64>,
    header_timeout_ms: Option<f64>,
) -> Result<String> {
    let env = NapiEnv::global();
    env.ensure_event_channel();
    let state = env.state;

    let declared_total = normalized_u64(total_bytes);
    let max_bytes = normalized_u64(max_total_bytes);
    let max_entry = normalized_u64(max_entry_bytes);
    let cancel = resolve_cancel_token(state, cancel_token_id.as_deref(), &task_id)?;
    let options = ZipParseOptions::new(max_entries as u64, max_bytes, max_entry, {
        let token = cancel.clone();
        Arc::new(move || token.is_cancelled())
    });
    let timeouts = receive::ReceiveTimeouts {
        connect: duration_from_ms(connect_timeout_ms, receive::DEFAULT_CONNECT_TIMEOUT),
        stall: duration_from_ms(stall_timeout_ms, receive::DEFAULT_STALL_TIMEOUT),
        header: duration_from_ms(header_timeout_ms, receive::DEFAULT_HEADER_TIMEOUT),
    };

    let result = mta::receive::receive_download(
        state,
        &go_ip,
        port,
        &task_id,
        &target_dir,
        declared_total,
        options,
        cancel,
        timeouts,
    )
    .await;

    // 清理本次登记（成功/失败/取消均执行）
    {
        let mut s = lock(state);
        s.active_transfers.remove(&task_id);
        if let Some(id) = cancel_token_id.as_deref() {
            if !id.is_empty() {
                s.cancel_tokens.remove(id);
            }
        }
    }

    match result {
        Ok(entries) => serde_json::to_string(&entries)
            .map_err(|e| Error::from_reason(format!("序列化接收元数据失败: {e}"))),
        Err(e) => Err(Error::from_reason(format!("MTA 接收下载失败: {e:#}"))),
    }
}

/// 归一化 f64 为非负 u64（非有限值或负值视为 0）。
fn normalized_u64(value: f64) -> u64 {
    if value.is_finite() && value > 0.0 {
        value as u64
    } else {
        0
    }
}

/// 毫秒参数转 Duration；缺省或非法时用默认值。
fn duration_from_ms(value: Option<f64>, fallback: Duration) -> Duration {
    match value {
        Some(ms) if ms.is_finite() && ms > 0.0 => Duration::from_millis(ms as u64),
        _ => fallback,
    }
}

/// 解析（或创建）取消令牌，并登记到 `active_transfers[taskId]` 供按 taskId 取消。
fn resolve_cancel_token(
    state: &Mutex<BridgeState>,
    cancel_token_id: Option<&str>,
    task_id: &str,
) -> Result<CancellationToken> {
    let mut state = lock(state);
    if task_id.is_empty() || state.active_transfers.contains_key(task_id) {
        return Err(Error::from_reason("MTA 接收任务已存在或 ID 无效"));
    }
    let token = match cancel_token_id {
        Some(id) if !id.is_empty() => state.cancel_tokens.entry(id.to_string()).or_default().clone(),
        _ => CancellationToken::new(),
    };
    state.active_transfers.insert(task_id.to_string(), token.clone());
    Ok(token)
}
