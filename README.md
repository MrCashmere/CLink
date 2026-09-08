# 羊绒互传 (Cashmere Link)

HarmonyOS NEXT 原生局域网互传应用。它把 **LocalSend**、**Quick Share（Android 快速分享）** 与 **Windows Nearby Sharing（附近共享）** 三种协议整合到同一个应用里，提供局域网 HTTPS、BLE 发现与 PIN 配对加密传输。

- 多协议收发：LocalSend / Quick Share / Windows Nearby Sharing 发送与接收。
- 局域网发现：mDNS + BLE（含 Windows Nearby 的 MS-CDP 广播、Quick Share 的 FE2C/FC9F 服务）。
- 加密传输：PIN 配对、UKEY2 / AES-GCM、TLS（原生 mbedTLS）。
- 聚合页与系统分享面板接入，桌面端网页接收（Web Receive）。
- 后台接收：`backgroundModes=dataTransfer` 长时任务保活。

## 目录结构

```
AppScope/          应用级配置与资源
entry/             主应用模块（ArkTS UI + 各协议实现 + 原生加速）
  src/main/ets/quickshare/         Quick Share 协议
  src/main/ets/protocol/localsend/ LocalSend
  src/main/ets/protocol/windowsnearby/  Windows Nearby (CDP)
  src/main/ets/windowsnearby/      Windows Nearby 传输服务
  src/main/ets/view/               聚合页与设置页
  src/main/cpp/                    原生代码（mbedTLS、libarchive、TLS/P2P 封装）
gs/                GPL v3 协议模块：Quick Share + Windows Nearby (MS-CDP 对齐)
tests/             协议编解码单元测试
scripts/           辅助脚本
```

## 环境要求

- DevEco Studio NEXT（当前工程按 `compileSdkVersion 6.1.1(24)`、`compatibleSdkVersion 6.0.0(20)` 构建）。
- HarmonyOS NEXT 真机或模拟器（phone / tablet / 2in1）。
- 签名：仓库已移除默认签名配置，请自行在 DevEco Studio 中配置（File → Project Structure → Signing Configs），或使用真机自动签名。

## 导入与构建

1. 用 DevEco Studio 打开本目录。
2. 首次同步会自动执行 `ohpm install`；如未执行，可手动运行：

   ```shell
   ohpm install
   ```

3. 命令行构建：

   ```shell
   hvigorw assembleHap --no-daemon
   ```

   产物：`entry/build/default/outputs/default/entry-default-signed.hap`（在配置好签名后为已签名包）。

4. 安装到设备：

   ```shell
   hdc install -r entry-default-signed.hap
   ```

## 证书说明

仓库不再内置开发用证书/私钥（已移除，避免公开展布私钥）。需要自备并放入以下位置：

- 传输层 TLS：`entry/src/main/resources/rawfile/cashmere_cert.pem` 与 `cashmere_key.pem`
- Windows Nearby 设备身份：`entry/src/main/resources/rawfile/windowsnearby/cdp_ec_cert.{der,pem}`、`cdp_ec_key.{der,pem}`、`cdp_ec_pub.der`

若这些证书缺失，对应的 TLS / Windows Nearby 设备身份功能不可用（TLS 会自动降级，Windows Nearby 加载身份证书时会失败，属预期行为）。

## 调试相关

- 应用内自采集日志：所有 `console` 日志同时写入应用沙箱 `<filesDir>/applog/applog.txt`（上限 8MB，超限自动轮转）。可在设置页“保存诊断日志”导出。收集器位于 `entry/src/main/ets/common/LogCapture.ets`。
- 接收目录：`<filesDir>/incoming`，按协议分别写入子目录 `quickshare`、`nearshare`、`windowsnearby`（LocalSend 直接写入 `incoming` 根目录）。
- 端口：LocalSend 53317、Quick Share 53318、Windows Nearby 5050 / 5040。

## 单元测试

在 DevEco Studio 中选择 `ohosTest` 配置运行，或命令行：

```shell
hvigorw --mode module -p module=entry@ohosTest assembleHap
```

用例覆盖：帧编解码分片重组、UKEY2 双端 PIN/会话令牌一致性、AES-GCM 加解密、MS-CDP Advertisement 编解码、PIN 生成。

## 许可证 / License

本项目基于 **GNU General Public License version 3.0 (GPL v3)** 发布。

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.

完整版协议文本见 <https://www.gnu.org/licenses/gpl-3.0.txt>（或 <https://www.gnu.org/licenses/gpl-3.0.html>）。

### 第三方组件

仓库中包含的第三方库以它们各自的许可证分发，保留其原始版权与许可声明：

- **mbedTLS** —— Apache-2.0 OR GPL-2.0-or-later（见 `entry/src/main/cpp/mbedtls/LICENSE`）。
- **libarchive** —— BSD-3-Clause（见 `entry/src/main/cpp/libarchive` 相关许可说明）。
