// 宿主 NAPI 装配，不注册或启停 LocalSend 服务。
pub mod env;
pub mod event_forwarder;
pub mod mta;
pub mod log_buffer;
use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::*;
use crate::bridge::lock;

/// Generate a persistent per-installation LocalSend identity without blocking ArkTS.
#[napi]
pub async fn native_generate_tls_identity() -> Result<String> {
    let identity = tokio::task::spawn_blocking(localsend::crypto::cert::generate_self_signed)
        .await
        .map_err(|error| Error::from_reason(error.to_string()))?
        .map_err(|error| Error::from_reason(error.to_string()))?;
    Ok(serde_json::json!({
        "certificatePem": identity.certificate_pem,
        "privateKeyPem": identity.private_key_pem
    }).to_string())
}
/// Generate an ECDSA identity instead of shipping a reusable Windows Nearby key.
#[napi]
pub async fn native_generate_cdp_identity() -> Result<String> {
    let identity = tokio::task::spawn_blocking(localsend::cdp_identity::generate)
        .await
        .map_err(|error| Error::from_reason(error.to_string()))?
        .map_err(|error| Error::from_reason(error.to_string()))?;
    fn der_hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }
    Ok(serde_json::json!({
        "certificateHex": der_hex(&identity.certificate_der),
        "privateKeyHex": der_hex(&identity.private_key_der),
        "publicKeyHex": der_hex(&identity.public_key_der)
    }).to_string())
}

/// Read a seekable LIVP descriptor without handing ownership of the caller's fd to Rust.
#[napi]
pub async fn native_extract_livp(fd: i32, target_dir: String) -> Result<String> {
    tokio::task::spawn_blocking(move || {
        use std::os::fd::FromRawFd;
        let owned_fd = unsafe { libc::dup(fd) };
        if owned_fd < 0 {
            return Err(Error::from_reason(std::io::Error::last_os_error().to_string()));
        }
        let source = unsafe { std::fs::File::from_raw_fd(owned_fd) };
        let result = crate::bridge::livp::extract(source, std::path::Path::new(&target_dir))
            .map_err(|error| Error::from_reason(error.to_string()))?;
        serde_json::to_string(&result).map_err(|error| Error::from_reason(error.to_string()))
    })
    .await
    .map_err(|error| Error::from_reason(error.to_string()))?
}

#[napi]
pub fn register_event_listener(callback: napi_ohos::threadsafe_function::ThreadsafeFunction<String>) -> Result<()> {
    log_buffer::init();
    let _ = rustls::crypto::ring::default_provider().install_default();
    let env = env::NapiEnv::global();
    env.ensure_event_channel();
    event_forwarder::register_event_callback(callback);
    Ok(())
}
#[napi]
pub fn cancel_transfer(task_id: String) {
    if let Some(token) = lock(env::NapiEnv::global().state).active_transfers.get(&task_id) { token.cancel(); }
}
#[napi]
pub fn poll_debug_log() -> Vec<String> { log_buffer::drain() }
