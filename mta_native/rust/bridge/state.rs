// 羊绒互传宿主仅保留 MTA 所需事件和取消状态。
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use tokio_util::sync::CancellationToken;
use super::event::BridgeEvent;
#[derive(Default)]
pub struct BridgeState {
    pub event_tx: Option<tokio::sync::mpsc::Sender<BridgeEvent>>,
    pub active_transfers: HashMap<String, CancellationToken>,
    pub cancel_tokens: HashMap<String, CancellationToken>,
}
impl BridgeState { pub fn new() -> Self { Self::default() } }
pub fn bridge() -> &'static Arc<Mutex<BridgeState>> {
    static STATE: OnceLock<Arc<Mutex<BridgeState>>> = OnceLock::new();
    STATE.get_or_init(|| Arc::new(Mutex::new(BridgeState::new())))
}
