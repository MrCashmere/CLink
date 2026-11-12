//! NapiEnv——NAPI 层运行环境。
//!
//! 通过 `OnceLock` 全局持有 tokio Runtime + BridgeState 引用 + 事件流接收端。
//! 桥接层函数不感知 runtime。
//!
//! - `runtime`：全局 tokio Runtime，同步 napi 导出的后台异步任务经 `runtime.spawn` 调度
//! - `register_event_callback`：启动消费事件流的异步 task（仅一次），
//!   事件推送走 napi_threadsafe_function（不阻塞 NAPI 调用线程）

use std::sync::{Arc, Mutex as StdMutex, OnceLock};

use tokio::sync::mpsc;

use crate::bridge::event::BridgeEvent;
use crate::bridge::lock;
use crate::bridge::state::bridge;

pub struct NapiEnv {
    /// 桥接层使用的 tokio Runtime（multi_thread, 4 workers）。
    pub runtime: tokio::runtime::Runtime,
    /// 全局 BridgeState 引用（与桥接层共享单例）。
    pub state: &'static Arc<StdMutex<crate::bridge::state::BridgeState>>,
    /// 事件流接收端（init 时设置，事件转发任务启动时消费）。
    pub event_rx: StdMutex<Option<mpsc::Receiver<BridgeEvent>>>,
    /// 当前事件回调 tsfn（Ability 重启后由新注册覆盖，转发任务每次投递时取最新）。
    pub event_tsfn:
        StdMutex<Option<Arc<napi_ohos::threadsafe_function::ThreadsafeFunction<String>>>>,
    /// 事件转发任务是否已启动（启动一次后持续消费，重注册仅更新 tsfn）。
    pub event_forwarder_started: StdMutex<bool>,
}

impl NapiEnv {
    /// 返回全局 NapiEnv 单例。
    pub fn global() -> &'static NapiEnv {
        static ENV: OnceLock<NapiEnv> = OnceLock::new();
        ENV.get_or_init(|| NapiEnv {
            runtime: tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .worker_threads(4)
                .thread_name("handysend")
                .build()
                .expect("创建 tokio runtime 失败"),
            state: bridge(),
            event_rx: StdMutex::new(None),
            event_tsfn: StdMutex::new(None),
            event_forwarder_started: StdMutex::new(false),
        })
    }

    /// 确保事件通道存在（幂等）。
    ///
    /// 事件流是桥接层的核心不变量——`state.event_tx` 必须存在，否则
    /// `send_event` 会静默丢弃所有 BridgeEvent。本函数在任何事件入口
    /// （init / create_server / start_server / start_discovery / send_files /
    /// register_event_listener）调用，保证不依赖调用顺序。
    ///
    /// 幂等性：`state.event_tx` 已存在（init 或先前入口已创建）时直接返回，
    /// 不重建通道（否则会丢失已启动的 forwarder 持有的旧 receiver）。
    pub fn ensure_event_channel(&self) {
        let mut s = lock(self.state);
        if s.event_tx.is_some() {
            return;
        }
        let (event_tx, event_rx) = mpsc::channel::<BridgeEvent>(128);
        s.event_tx = Some(event_tx);
        let mut rx_slot = lock(&self.event_rx);
        *rx_slot = Some(event_rx);
    }
}
