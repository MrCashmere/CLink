/**
 * Quick Share 传输方式（设置项 `quickshareTransport`）。
 *
 * - `auto`   自动（默认）：发送前探测**对端单播是否可达**，可达走局域网 TCP；
 *            不可达 / 只在 BLE 发现到 / 跨网段 → BLE 引导会话 + 升级 Wi-Fi Direct。
 * - `lan`    仅局域网：不做 WLAN 直连升级，也不广播/建 P2P 组；只在完全没有局域网端点时
 *            退回 BLE 传输（慢，但不升级）。
 * - `direct` WLAN 直连优先：跳过探测，直接走 BLE 引导 + Wi-Fi Direct；同时**不再广播 mDNS**
 *            WIFI_LAN 端点（让官方端只看到 BLE 端点，从而选择 BLE 引导再升级）。
 *
 * 依据与失败链见 docs/WIFI_DIRECT.md §2.4（角色模型）与 §5.4（探测式决策）。
 */
export type QuickShareTransportMode = 'auto' | 'lan' | 'direct';

export const QUICKSHARE_TRANSPORT_DEFAULT: QuickShareTransportMode = 'auto';

/** 把持久化读到的字符串收敛成合法取值（旧值/脏值一律回落 auto）。 */
export function parseTransportMode(value: string): QuickShareTransportMode {
  if (value === 'lan' || value === 'direct') {
    return value;
  }
  return QUICKSHARE_TRANSPORT_DEFAULT;
}

/** 旧布尔开关 `quickshareWlanDirect` 的迁移：true→direct，false→auto。 */
export function migrateLegacyWlanDirect(legacy: boolean): QuickShareTransportMode {
  return legacy ? 'direct' : QUICKSHARE_TRANSPORT_DEFAULT;
}
