#[cfg(feature = "napi")]
fn main() { napi_build_ohos::setup(); }
#[cfg(not(feature = "napi"))]
fn main() {}
