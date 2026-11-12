// 羊绒互传宿主日志缓冲：原始 MTA log 调用经 NativeBridge 进入统一诊断日志。
use std::collections::VecDeque;
use std::sync::{Mutex, Once};
static LINES: Mutex<VecDeque<String>> = Mutex::new(VecDeque::new());
static INIT: Once = Once::new();
struct MtaLogger;
static LOGGER: MtaLogger = MtaLogger;
impl log::Log for MtaLogger {
    fn enabled(&self, _: &log::Metadata<'_>) -> bool { true }
    fn log(&self, record: &log::Record<'_>) {
        let mut lines = LINES.lock().unwrap_or_else(|e| e.into_inner());
        if lines.len() >= 2048 { lines.pop_front(); }
        lines.push_back(format!("{}|{}", record.level().as_str().to_lowercase(), record.args()));
    }
    fn flush(&self) {}
}
pub fn init() {
    INIT.call_once(|| {
        if log::set_logger(&LOGGER).is_ok() { log::set_max_level(log::LevelFilter::Debug); }
    });
}
pub fn drain() -> Vec<String> {
    LINES.lock().unwrap_or_else(|e| e.into_inner()).drain(..).collect()
}
