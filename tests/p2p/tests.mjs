/**
 * Wi-Fi Direct 升级相关线格式的回归用例（纯协议，不需要真机）。
 *
 * 覆盖 2026-09-19 QS_A 分支新增/修改的编码：
 *   1. `ConnectionRequestFrame.mediums`(5) 是否声明了 WIFI_DIRECT(8)（此前只声明 WIFI_LAN(5)，
 *      官方端因此没有理由给 P2P 通道）；
 *   2. `medium_metadata`(7) 的 `medium_role`(12) 与 `supported_wifi_direct_auth_types`(13)
 *      （无交集官方就不会选 Wi-Fi Direct）；
 *   3. `UPGRADE_PATH_REQUEST`(7) / `UPGRADE_PATH_AVAILABLE`(1) 的字段号与凭据往返；
 *   4. 客户端介绍/ACK、失败帧的事件号；
 *   5. 服务类型 `_FC9F5ED42C8A._tcp.` 的推导（`_` + SHA-256("NearbySharing") 前 6 字节 + `._tcp.`）。
 *
 * 字段依据：google/nearby `connections/implementation/proto/offline_wire_formats.proto`。
 * 用法：node tests/p2p/tests.mjs
 */
import crypto from 'node:crypto';
import { build } from './build.mjs';

build();
const { ProtoReader } = await import('./build/quickshare/ProtoReader.mjs');
const { ProtoWire } = await import('./build/quickshare/ProtoWire.mjs');
const { NearDropWire, OfflineType } = await import('./build/quickshare/NearDropWire.mjs');
const {
  BandwidthUpgrade,
  BandwidthUpgradeEvent,
  BandwidthUpgradeMedium
} = await import('./build/quickshare/BandwidthUpgrade.mjs');
const { NearbyCapabilities, NearbyMedium, WifiDirectAuthType } = await import('./build/quickshare/NearbyCapabilities.mjs');

let passed = 0;
let failed = 0;
function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) {
    passed += 1;
    console.log(`  ok   ${name}`);
  } else {
    failed += 1;
    console.log(`  FAIL ${name}\n       实际: ${a}\n       期望: ${e}`);
  }
}
function checkTrue(name, value) {
  check(name, value === true, true);
}

/** 读某个 repeated 数值字段的全部取值。 */
function allVarints(bytes, field) {
  return new ProtoReader(bytes).readAll()
    .filter((f) => f.field === field && f.wireType === 0)
    .map((f) => f.value);
}

console.log('NearbyMedium / WifiDirectAuthType 常量');
check('WIFI_LAN = 5', NearbyMedium.WIFI_LAN, 5);
check('WIFI_DIRECT = 8', NearbyMedium.WIFI_DIRECT, 8);
check('WITH_PASSWORD = 1', WifiDirectAuthType.WIFI_DIRECT_WITH_PASSWORD, 1);
check('WITH_DEVICE_NAME = 3', WifiDirectAuthType.WIFI_DIRECT_WITH_DEVICE_NAME, 3);

console.log('mDNS 服务类型推导');
const serviceHash = crypto.createHash('sha256').update('NearbySharing').digest('hex').toUpperCase();
check('SHA-256("NearbySharing") 前 6 字节', serviceHash.slice(0, 12), 'FC9F5ED42C8A');
check('mDNS 服务类型', `_${serviceHash.slice(0, 12)}._tcp.`, '_FC9F5ED42C8A._tcp.');
check('实例名里的 service_id_hash 前 3 字节', serviceHash.slice(0, 6).toLowerCase(), 'fc9f5e');

console.log('ConnectionRequest 能力声明');
const endpointInfo = new Uint8Array([0x22, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 3, 0x41, 0x42, 0x43]);
const requestFrame = NearDropWire.connectionRequest('ab12', 'Phone', endpointInfo, new Uint8Array(0));
const offline = NearDropWire.parseOfflineFrame(requestFrame);
check('外层是 CONNECTION_REQUEST', offline.type, OfflineType.CONNECTION_REQUEST);
const body = offline.body;
check('endpoint_id 原样', Buffer.from(ProtoReader.firstBytes(body, 1)).toString('utf8'), 'ab12');
check('endpoint_name 原样', Buffer.from(ProtoReader.firstBytes(body, 2)).toString('utf8'), 'Phone');
check('mediums 含 WIFI_LAN(5) 与 WIFI_DIRECT(8)', allVarints(body, 5), [5, 8]);
check('endpoint_info(field 6) 原样', Array.from(ProtoReader.firstBytes(body, 6)), Array.from(endpointInfo));
checkTrue('medium_metadata(field 7) 存在', ProtoReader.firstBytes(body, 7) !== undefined);

const capability = NearbyCapabilities.read(body);
check('解析出的 mediums', capability.mediums, [5, 8]);
check('解析出的 authTypes', capability.authTypes, [1]);
checkTrue('声明可当 GO', capability.supportsGroupOwner);
checkTrue('声明可当 GC', capability.supportsGroupClient);
checkTrue('支持 Wi-Fi Direct', NearbyCapabilities.supportsWifiDirect(capability));
checkTrue('与对端有公共凭据类型（未声明时视为兼容）', NearbyCapabilities.hasCommonAuthType(capability));
check('对端只声明 device_name/PIN 时无交集', NearbyCapabilities.hasCommonAuthType({
  mediums: [8], authTypes: [3], supportsGroupOwner: false, supportsGroupClient: false
}), false);
check('对端未声明 authTypes 时视为兼容', NearbyCapabilities.hasCommonAuthType({
  mediums: [8], authTypes: [], supportsGroupOwner: false, supportsGroupClient: false
}), true);

console.log('UPGRADE_PATH_REQUEST(7)');
const requestUpgrade = BandwidthUpgrade.upgradePathRequest([BandwidthUpgradeMedium.WIFI_DIRECT]);
const requestDecoded = BandwidthUpgrade.parse(requestUpgrade);
check('事件号 = 7', requestDecoded.eventType, BandwidthUpgradeEvent.UPGRADE_PATH_REQUEST);
check('请求的 mediums = [8]', requestDecoded.mediums, [8]);
const requestOfflineBody = NearDropWire.parseOfflineFrame(requestUpgrade).body;
const pathInfo = ProtoReader.firstBytes(requestOfflineBody, 2);
check('upgrade_path_info.medium = 8', ProtoReader.firstVarint(pathInfo, 1), 8);
const upgradeRequest = ProtoReader.firstBytes(pathInfo, 10);
check('UpgradePathRequest.mediums(field 1, packed) = [8]', Array.from(ProtoReader.firstBytes(upgradeRequest, 1)), [8]);

console.log('UPGRADE_PATH_AVAILABLE(1) 与凭据往返');
const credentials = { ssid: 'DIRECT-ab-123456', password: 'P@ssw0rd-16chars', port: 53318, gateway: '192.168.49.1', frequency: 2437 };
const available = BandwidthUpgrade.upgradePathAvailable(credentials);
const availableDecoded = BandwidthUpgrade.parse(available);
check('事件号 = 1', availableDecoded.eventType, BandwidthUpgradeEvent.UPGRADE_PATH_AVAILABLE);
const availableBody = NearDropWire.parseOfflineFrame(available).body;
const availableInfo = ProtoReader.firstBytes(availableBody, 2);
check('medium = 8', ProtoReader.firstVarint(availableInfo, 1), 8);
checkTrue('supports_client_introduction_ack(field 9) = true', ProtoReader.firstVarint(availableInfo, 9) === 1);
const roundTrip = BandwidthUpgrade.parseWifiDirectCredentials(available);
check('ssid 往返', roundTrip.ssid, credentials.ssid);
check('password 往返', roundTrip.password, credentials.password);
check('port 往返', roundTrip.port, credentials.port);
check('frequency 往返', roundTrip.frequency, credentials.frequency);
check('gateway 往返', roundTrip.gateway, credentials.gateway);
const rawCredentials = ProtoReader.firstBytes(availableInfo, 6);
check('凭据字段号 ssid=1/password=2/port=3/frequency=4/gateway=5',
  [1, 2, 3, 4, 5].map((f) => ProtoReader.firstVarint(rawCredentials, f) !== undefined
    || ProtoReader.firstBytes(rawCredentials, f) !== undefined),
  [true, true, true, true, true]);

console.log('CLIENT_INTRODUCTION(4) / ACK(6) / UPGRADE_FAILURE(5)');
check('CLIENT_INTRODUCTION = 4', BandwidthUpgrade.parse(BandwidthUpgrade.clientIntroduction('ab12')).eventType,
  BandwidthUpgradeEvent.CLIENT_INTRODUCTION);
check('CLIENT_INTRODUCTION_ACK = 6', BandwidthUpgrade.parse(BandwidthUpgrade.clientIntroductionAck()).eventType,
  BandwidthUpgradeEvent.CLIENT_INTRODUCTION_ACK);
check('UPGRADE_FAILURE = 5', BandwidthUpgrade.parse(BandwidthUpgrade.upgradeFailure(8)).eventType,
  BandwidthUpgradeEvent.UPGRADE_FAILURE);

console.log('其它帧不受影响');
const accept = NearDropWire.connectionAccept();
check('ConnectionResponse 仍是 OfflineFrame type 2',
  NearDropWire.parseOfflineFrame(accept).type, OfflineType.CONNECTION_RESPONSE);

console.log('mDNS 实例名 / TXT n 的 base64 形态（互操作关键：URL-safe 且不填充）');
const { ByteUtils } = await import('./build/entry/common/ByteUtils.mjs');
/** 与 QuickShareBrowser.toUrlSafeBase64 完全相同的两步变换。 */
function urlSafeUnpadded(bytes) {
  return ByteUtils.toBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}
const instanceNameBytes = new Uint8Array([0x23, 0x61, 0x62, 0x31, 0x32, 0xfc, 0x9f, 0x5e, 0x00, 0x00]);
const instanceName = urlSafeUnpadded(instanceNameBytes);
check('实例名长度 14（10 字节 → 14 字符，无填充）', instanceName.length, 14);
check('实例名不含 "="', instanceName.indexOf('=') >= 0, false);
check('实例名与官方 base64url(去填充) 一致', instanceName,
  Buffer.from(instanceNameBytes).toString('base64url').replace(/=+$/g, ''));
check('实例名首字符来自 0x23（version1|pcp3）', instanceName.startsWith('I2'), true);

const txtInfo = new Uint8Array(21);
txtInfo[0] = 0x22;
txtInfo[17] = 3;
txtInfo[18] = 0x41;
txtInfo[19] = 0x42;
txtInfo[20] = 0x43;
const txtN = urlSafeUnpadded(txtInfo);
check('TXT n 不含 "="', txtN.indexOf('=') >= 0, false);
check('TXT n 可解回原字节（解码端两种都能吃）', Array.from(ByteUtils.fromBase64(
  txtN.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(txtN.length / 4) * 4, '='))),
  Array.from(txtInfo));
// 反向保护：第三方报告称带填充会让 Windows 的严格解析器丢弃整条服务；
// 10 字节的标准 base64 会带 "=="，这里断言我们发出去的确实是无填充形态。
const paddedInstanceName = Buffer.from(instanceNameBytes).toString('base64').replace(/\+/g, '-').replace(/\//g, '_');
check('标准 base64 带填充（前提成立）', paddedInstanceName.endsWith('=='), true);
check('我们发出的实例名 ≠ 带填充形态', instanceName === paddedInstanceName, false);

console.log('凭据形态识别（password vs device_name/PIN）');
// 构造一个「device_name/PIN(WPS) 形态」的 UPGRADE_PATH_AVAILABLE：
// 只带 port=3 / gateway=5 / pin=8 / device_name=9，不带 ssid/password。
const wpsCredentials = (() => {
  const direct = ProtoWire.message([
    ProtoWire.fieldInt32(3, 8988),
    ProtoWire.fieldString(5, '192.168.49.1'),
    ProtoWire.fieldString(8, '12345678'),
    ProtoWire.fieldString(9, 'DIRECT-wps-phone')
  ]);
  const info = ProtoWire.message([
    ProtoWire.fieldEnum(1, 8),
    ProtoWire.nested(6, direct),
    ProtoWire.fieldBool(9, true)
  ]);
  const negotiation = ProtoWire.message([
    ProtoWire.fieldEnum(1, 1),
    ProtoWire.nested(2, info)
  ]);
  return NearDropWire.offline(OfflineType.BANDWIDTH_UPGRADE_NEGOTIATION, negotiation);
})();
const wpsOffer = BandwidthUpgrade.inspectWifiDirectOffer(wpsCredentials);
check('识别为不可用（无 ssid/口令）', wpsOffer.usableWithPassword, false);
check('解析出 device_name(field 9)', wpsOffer.deviceName, 'DIRECT-wps-phone');
check('解析出 pin(field 8)', wpsOffer.pin, '12345678');
check('给出可读原因', wpsOffer.detail.includes('device_name/PIN'), true);
check('parseWifiDirectCredentials 不会把它当成可用凭据',
  BandwidthUpgrade.parseWifiDirectCredentials(wpsCredentials), undefined);
const passwordOffer = BandwidthUpgrade.inspectWifiDirectOffer(available);
check('口令形态识别为可用', passwordOffer.usableWithPassword, true);
check('口令形态 detail 说明齐全', passwordOffer.detail.includes('可入组'), true);

console.log(`\n结果：${passed} 通过 / ${failed} 失败`);
if (failed > 0) {
  process.exit(1);
}
