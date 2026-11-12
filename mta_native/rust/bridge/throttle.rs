//! 传输进度推送节流器——发送 / 接收 / 下载方向共用的最小推送间隔控制。

use std::time::{Duration, Instant};

/// 进度事件节流器：距上次推送不足 [`MIN_INTERVAL`] 的事件被抑制。
///
/// 语义约定（各传输方向统一）：
/// - **首条必达**：尚未推送过时放行，保证 UI 能尽早看到进度启动；
/// - **终态不由节流器负责**：100% 完成事件由调用方结果路径保证送达
///   （满量直发或独立完成事件），不经过节流器。
pub struct ProgressThrottle {
    /// 上次实际推送事件的时刻；None 表示尚未推送过（首条必达）。
    last_sent: Option<Instant>,
}

impl ProgressThrottle {
    /// 最小推送间隔（20ms ≈ 50fps，进度 UI 足够平滑且不淹没事件通道）。
    pub const MIN_INTERVAL: Duration = Duration::from_millis(20);

    pub fn new() -> Self {
        Self { last_sent: None }
    }

    /// 判断给定时刻是否允许推送；允许时记录该时刻为上次推送时刻。
    pub fn allow(&mut self, now: Instant) -> bool {
        if let Some(last) = self.last_sent {
            if now.duration_since(last) < Self::MIN_INTERVAL {
                return false;
            }
        }
        self.last_sent = Some(now);
        true
    }
}

impl Default for ProgressThrottle {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 高频消息序列（间隔 5ms）应只有首条与间隔恢复后的消息送达。
    #[test]
    fn test_throttle_suppresses_high_frequency() {
        let mut throttle = ProgressThrottle::new();
        let base = Instant::now();
        let passed = [0, 5, 10, 15, 20, 25, 30, 35]
            .iter()
            .filter(|i| throttle.allow(base + Duration::from_millis(**i)))
            .count();
        assert_eq!(passed, 2); // 0ms 与 20ms
    }

    /// 低频消息序列（间隔 >= 20ms）应全部送达，含首条。
    #[test]
    fn test_throttle_allows_low_frequency() {
        let mut throttle = ProgressThrottle::new();
        let base = Instant::now();
        let all = (0..5).all(|i| throttle.allow(base + Duration::from_millis(i * 20)));
        assert!(all);
    }
}
