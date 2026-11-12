pub mod livp;
pub mod mta;
pub mod event;
pub mod state;
pub mod throttle;
pub fn lock<T>(mutex: &std::sync::Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}
