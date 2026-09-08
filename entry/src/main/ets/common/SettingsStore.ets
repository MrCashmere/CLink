import { LogCapture as Lg } from '../common/LogCapture';
import dataPreferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';

export interface LinkSettings {
  alias: string;
  requirePin: boolean;
  alwaysVisible: boolean;
  /** 开启后优先尝试 Wi-Fi Direct 建组（WLAN 直连优先模式），仅在 TCP 不可达时回退使用。 */
  quickshareWlanDirect: boolean;
  /** Windows Nearby 接收需要：本机蓝牙（BR/EDR）MAC 地址，用于 BLE 广播让 Windows 识别并走蓝牙 RFCOMM 连接。 */
  btMac: string;
  /** Windows Nearby 蓝牙发现后是否自动升级到 Wi-Fi(TCP 5040) 传输大文件。默认 false 走蓝牙。 */
  wifiUpgradeTcp: boolean;
  /** 以「聚合」页为首页：打开软件时默认进入「聚合」页。默认 true。 */
  aggregateAsHome?: boolean;
  /** 隐藏「传输」页：仅在「聚合」页为首页时生效。默认 false。 */
  hideTransferPage?: boolean;
  /** Quick Share 页进入时的一次性稳定性提示是否已展示过。 */
  quickShareHintShown?: boolean;
  /** LocalSend 页进入时的一次性 HTTPS 说明是否已展示过。 */
  localSendNoticeShown?: boolean;
  /** LocalSend 加密传输 (TLS) 开关：开启时接收方尝试提供 HTTPS（服务端接线属 Phase C）。 */
  encryptionEnabled?: boolean;
  /** LocalSend 接收 PIN：非空时对端发送方必须携带匹配的 ?pin= 才能建立会话（LocalSend 官方语义）。 */
  receivePin?: string;
  /** 用长时任务(Continuous Task)保活：传输期间申请系统保活，后台也能持续运行（默认开）。 */
  keepAlive?: boolean;
}

const STORE_NAME = 'cashmere_settings';

function defaultSettings(): LinkSettings {
  return {
    alias: '羊绒互传',
    requirePin: true,
    alwaysVisible: true,
    quickshareWlanDirect: false,
    btMac: '',
    wifiUpgradeTcp: true,
    aggregateAsHome: true,
    hideTransferPage: false,
    quickShareHintShown: false,
    localSendNoticeShown: false,
    encryptionEnabled: true,
    receivePin: '',
    keepAlive: true
  };
}

export class SettingsStore {
  private static cached?: LinkSettings;

  static async load(context: common.Context): Promise<LinkSettings> {
    if (SettingsStore.cached !== undefined) {
      return SettingsStore.cached;
    }
    try {
      const store = await dataPreferences.getPreferences(context, STORE_NAME);
      const storedAlias = await store.get('alias', '羊绒互传');
      const alias = storedAlias === 'CashmereLink' ? '羊绒互传' : storedAlias;
      const requirePin = await store.get('requirePin', true);
      const alwaysVisible = await store.get('alwaysVisible', true);
      const quickshareWlanDirect = await store.get('quickshareWlanDirect', false);
      const btMac = await store.get('btMac', '');
      const wifiUpgradeTcp = await store.get('wifiUpgradeTcp', true);
      const aggregateAsHome = await store.get('aggregateAsHome', true);
      const hideTransferPage = await store.get('hideTransferPage', false);
      const quickShareHintShown = await store.get('quickShareHintShown', false);
      const localSendNoticeShown = await store.get('localSendNoticeShown', false);
      const encryptionEnabled = await store.get('encryptionEnabled', true);
      const receivePin = await store.get('receivePin', '');
      const keepAlive = await store.get('keepAlive', true);
      SettingsStore.cached = {
        alias: typeof alias === 'string' && alias.length > 0 ? alias : '羊绒互传',
        requirePin: requirePin === true,
        alwaysVisible: alwaysVisible === true,
        quickshareWlanDirect: quickshareWlanDirect === true,
        btMac: typeof btMac === 'string' ? btMac : '',
        wifiUpgradeTcp: wifiUpgradeTcp === true,
        aggregateAsHome: aggregateAsHome === true,
        hideTransferPage: hideTransferPage === true,
        quickShareHintShown: quickShareHintShown === true,
        localSendNoticeShown: localSendNoticeShown === true,
        encryptionEnabled: encryptionEnabled !== false,
        receivePin: typeof receivePin === 'string' ? receivePin : '',
        keepAlive: keepAlive !== false
      };
    } catch (error) {
      Lg.w(`SettingsStore load failed: ${JSON.stringify(error)}`);
      SettingsStore.cached = defaultSettings();
    }
    return SettingsStore.cached;
  }

  static async save(context: common.Context, settings: LinkSettings): Promise<void> {
    const prev = SettingsStore.cached;
    // 设置页/主页持久化时不携带一次性提示标志，这里保留上次的值，避免其被清空。
    const merged: LinkSettings = {
      alias: settings.alias,
      requirePin: settings.requirePin,
      alwaysVisible: settings.alwaysVisible,
      quickshareWlanDirect: settings.quickshareWlanDirect,
      btMac: settings.btMac,
      wifiUpgradeTcp: settings.wifiUpgradeTcp,
      aggregateAsHome: settings.aggregateAsHome !== undefined ? settings.aggregateAsHome : (prev?.aggregateAsHome ?? true),
      hideTransferPage: settings.hideTransferPage !== undefined ? settings.hideTransferPage : (prev?.hideTransferPage ?? false),
      quickShareHintShown: settings.quickShareHintShown !== undefined ? settings.quickShareHintShown : (prev?.quickShareHintShown ?? false),
      localSendNoticeShown: settings.localSendNoticeShown !== undefined ? settings.localSendNoticeShown : (prev?.localSendNoticeShown ?? false),
      encryptionEnabled: settings.encryptionEnabled !== undefined ? settings.encryptionEnabled : (prev?.encryptionEnabled ?? true),
      receivePin: settings.receivePin !== undefined ? settings.receivePin : (prev?.receivePin ?? ''),
      keepAlive: settings.keepAlive !== undefined ? settings.keepAlive : (prev?.keepAlive ?? true)
    };
    SettingsStore.cached = merged;
    try {
      const store = await dataPreferences.getPreferences(context, STORE_NAME);
      await store.put('alias', settings.alias);
      await store.put('requirePin', settings.requirePin);
      await store.put('alwaysVisible', settings.alwaysVisible);
      await store.put('quickshareWlanDirect', settings.quickshareWlanDirect);
      await store.put('btMac', settings.btMac);
      await store.put('wifiUpgradeTcp', settings.wifiUpgradeTcp);
      await store.put('aggregateAsHome', merged.aggregateAsHome);
      await store.put('hideTransferPage', merged.hideTransferPage);
      await store.put('quickShareHintShown', merged.quickShareHintShown);
      await store.put('localSendNoticeShown', merged.localSendNoticeShown);
      await store.put('encryptionEnabled', merged.encryptionEnabled);
      await store.put('receivePin', merged.receivePin);
      await store.put('keepAlive', merged.keepAlive);
      await store.flush();
    } catch (error) {
      Lg.w(`SettingsStore save failed: ${JSON.stringify(error)}`);
    }
  }

  static current(): LinkSettings {
    return SettingsStore.cached ?? defaultSettings();
  }
}
