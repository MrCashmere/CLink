// Minimal NAPI target for the current native build. Quick Share currently uses
// the ArkTS transport path; no native logic is required here.
#include "napi/native_api.h"

static napi_value DummyHello(napi_env env, napi_callback_info info)
{
    void *data = nullptr;
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, &data);
    napi_value result = nullptr;
    napi_create_string_utf8(env, "ok", NAPI_AUTO_LENGTH, &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "hello", nullptr, DummyHello, nullptr, nullptr, nullptr, napi_default, nullptr }
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "p2p_native",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterP2pNativeModule(void)
{
    napi_module_register(&demoModule);
}
