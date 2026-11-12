// 宿主事件面抽离自 HandySend；MTA 序列化契约与投递策略保持原样。
use serde::Serialize;
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", content = "payload", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum BridgeEvent {
    // ── MTA 发送端服务器（关键事件，MtaSendProgress 可丢弃）──
    /// MTA 服务器已启动（携带实际绑定端口）。
    MtaServerStarted { port: u16 },
    /// 对端已建立 MTA WebSocket 连接。
    MtaWsConnected,
    /// MTA 版本协商完成。
    MtaVersionNegotiated { version: i64 },
    /// 已发送 sendRequest 并收到对端确认。
    MtaSendRequestSent { task_id: String },
    /// 本地取消时已向对端回送取消状态（视为「已通知对端」）。
    MtaRejectSent { task_id: String },
    /// 对端开始下载 ZIP。
    MtaDownloadStarted { task_id: String },
    /// ZIP 发送进度（高频瞬态事件，channel 满时丢弃）。
    /// `sent_bytes` 为已读源字节（有效数据口径，用于进度）；`network_bytes` 为出网字节累计
    /// （网络口径，用于速率）。
    MtaSendProgress {
        sent_bytes: u64,
        total_bytes: u64,
        percent: f64,
        network_bytes: u64,
    },
    /// ZIP 接收进度（高频瞬态事件，channel 满时丢弃）。
    /// `received_bytes` 为已解压字节（有效数据口径，用于进度），`total_bytes` 为接收请求
    /// 声明的原始总大小；`network_bytes` 为网络读入字节累计（网络口径，用于速率）；
    /// `network_done` 为网络数据是否已全部读入（true 表示仍在解压/落盘）。
    MtaReceiveProgress {
        task_id: String,
        received_bytes: u64,
        total_bytes: u64,
        percent: f64,
        network_bytes: u64,
        network_done: bool,
    },
    /// 本次 MTA 发送完成（对端回送成功状态）。
    MtaSendCompleted { task_id: String },
    /// 本次 MTA 发送仅部分完成（对端回送成功类型 + 部分接收原因，即只收了部分文件）。
    MtaSendPartial { reason: String },
    /// 本次 MTA 发送被对端拒绝。
    MtaSendRejected { reason: String },
    /// 本次 MTA 发送失败（超时/连接中断等）。
    MtaSendFailed { reason: String },

}
impl BridgeEvent {
    pub fn is_droppable(&self) -> bool {
        matches!(self, Self::MtaSendProgress { .. } | Self::MtaReceiveProgress { .. })
    }
    pub fn is_terminal_progress(&self) -> bool {
        match self {
            Self::MtaSendProgress { sent_bytes, total_bytes, .. } => *total_bytes > 0 && *sent_bytes >= *total_bytes,
            Self::MtaReceiveProgress { received_bytes, total_bytes, .. } => *total_bytes > 0 && *received_bytes >= *total_bytes,
            _ => false,
        }
    }
}
pub async fn send_event(
    event_tx: &Option<tokio::sync::mpsc::Sender<BridgeEvent>>,
    event: BridgeEvent,
) {
    let Some(tx) = event_tx else {
        return;
    };
    if event.is_droppable() && !event.is_terminal_progress() {
        let _ = tx.try_send(event);
    } else {
        // 关键事件加超时防护：无消费者时避免永久阻塞事件循环
        let result = tokio::time::timeout(std::time::Duration::from_secs(1), tx.send(event)).await;
        if result.is_err() {
            log::warn!("关键事件发送超时，可能无消费者或通道满");
        }
    }
}
