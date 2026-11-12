//! 事件转发——从事件流消费 BridgeEvent，通过 napi_threadsafe_function
//! 按事件类型分发到 ArkTS 主线程。
//!
//! 事件序列化为 `{"type":"...","payload":{...}}` JSON 字符串，
//! ArkTS 侧 NativeBridge 解析 type 后分发给对应订阅者。
//!
//! 转发任务仅启动一次并持续消费事件流；每次注册把最新 tsfn 存入
//! NapiEnv，投递时取当前 tsfn——Ability 重启后 ArkTS 重新注册即可
//! 恢复事件投递，旧 tsfn 被覆盖丢弃。

use std::sync::Arc;

use napi_ohos::threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode};

use crate::bridge::event::BridgeEvent;
use crate::bridge::lock;

/// 转发失败计数（投递失败累积，仅用于诊断）。
static FORWARD_FAILURES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// 注册事件回调：更新 NapiEnv 中的 tsfn 并确保转发任务已在运行。
///
/// 必须在 ensure_event_channel 之后调用（register_event_listener 已保证）。
pub fn register_event_callback(tsfn: ThreadsafeFunction<String>) {
    let env = crate::napi::env::NapiEnv::global();
    *lock(&env.event_tsfn) = Some(Arc::new(tsfn));

    // 转发任务已在运行：仅更新 tsfn 即可恢复投递（Ability 重启场景）
    if *lock(&env.event_forwarder_started) {
        log::debug!("事件转发任务已在运行，已更新事件回调");
        return;
    }
    let rx = lock(&env.event_rx).take();
    let Some(mut rx) = rx else {
        log::warn!("事件流接收端未设置——ensure_event_channel 未调用");
        return;
    };
    *lock(&env.event_forwarder_started) = true;

    env.runtime.spawn(async move {
        while let Some(event) = rx.recv().await {
            // 序列化失败时记日志并丢弃：转发空字符串只会被 ArkTS 侧
            // 静默吞掉，两端均无诊断线索
            let json = match serde_json::to_string(&event) {
                Ok(json) => json,
                Err(e) => {
                    log::error!("事件序列化失败，丢弃事件: {e:?}");
                    continue;
                }
            };
            let tsfn = lock(&env.event_tsfn).clone();
            match tsfn {
                Some(tsfn) => {
                    let status = tsfn.call(Ok(json), ThreadsafeFunctionCallMode::NonBlocking);
                    if status != napi_ohos::Status::Ok {
                        let n =
                            FORWARD_FAILURES.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
                        log::warn!("事件转发失败: status={:?} 累计={}", status, n);
                    }
                }
                None => {
                    log::warn!("事件回调未注册，丢弃事件: {}", event_to_json(&event));
                }
            }
        }
        log::debug!("事件转发任务结束");
    });
}

/// 将 BridgeEvent 序列化为 JSON 字符串（供调试/测试）。
pub fn event_to_json(event: &BridgeEvent) -> String {
    serde_json::to_string(event).unwrap_or_else(|_| "{}".to_string())
}
