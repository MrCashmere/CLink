# CLink · 羊绒互传

CLink 是一款 HarmonyOS NEXT 附近文件传输应用。可以在同一局域网内通过 LocalSend 或浏览器收发文件，也可以尝试使用 Quick Share、Windows Nearby 和互传联盟（MTA）连接支持这些协议的设备。

- **局域网传输**：支持 LocalSend 的 HTTP 和 HTTPS 模式；网页传输可以直接在另一台设备的浏览器中打开。
- **附近互传**：提供 Quick Share、Windows Nearby 和 MTA 入口。BLE、WLAN 直连和跨品牌兼容性会因系统版本与对端实现而异。
- **照片与视频**：可选择保存到系统图库。支持识别部分动态照片和 HDR 格式；可用的转换和保存方式取决于原始格式及系统权限。

## 构建

需要 DevEco Studio、HarmonyOS SDK 26.0.0（含 Native SDK）、ohpm 和 Rust 工具链。用 DevEco Studio 打开仓库根目录并同步依赖，或在配置好工具路径的终端运行：

```sh
ohpm install --all
rustup target add aarch64-unknown-linux-ohos x86_64-unknown-linux-ohos
hvigorw assembleHap --mode module -p module=entry@default -p product=default -p buildMode=debug --no-daemon
```

Hvigor 会在构建时编译 Rust 原生库。若工具找不到 SDK，请将 `DEVECO_SDK_HOME` 指向本机 SDK 根目录。本仓库不包含发布签名；要安装到设备，请在 DevEco Studio 配置自己的调试签名。LocalSend HTTPS 和 Windows Nearby 所用的本机身份在应用运行时生成并保存在应用沙箱中。

## 开发与测试

- `entry/`：应用界面、设备发现、会话管理和文件保存。
- `gs/`：Quick Share 协议与兼容传输模块。
- `mta_native/`：MTA 的网络与 ZIP 处理，以及证书和 LIVP 处理的原生组件。

将 `TS_LIB` 设为 DevEco Studio 随附的 `typescript/lib/typescript.js` 的绝对路径，然后运行：

```sh
node --test tests/*.test.cjs
node tests/http/tests.mjs
node tests/p2p/tests.mjs
node tests/dp-format/tests.mjs
cargo test --manifest-path mta_native/Cargo.toml --no-default-features --lib --locked
```

这些检查覆盖协议帧、传输中断、文件完整性和媒体保存流程。BLE、WLAN 直连、系统图库授权和跨品牌互传需要在实际设备上验证。

## 许可

CLink 应用代码沿用原开源版本的 GPL v3 或更新版本许可。`gs` 模块为 GPL-3.0-only，许可正文见 [GNU GPL v3](gs/LICENSE)。第三方代码和资源保留各自的许可和版权声明，详见 [项目归属声明](NOTICE)、[`gs` 归属声明](gs/NOTICE)及 [第三方许可证](licenses/)。
