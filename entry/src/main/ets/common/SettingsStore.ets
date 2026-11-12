import { LogCapture as Lg } from '../common/LogCapture';
import dataPreferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { QuickShareTransportMode, QUICKSHARE_TRANSPORT_DEFAULT, parseTransportMode, migrateLegacyWlanDirect } from '../quickshare/model/TransportPolicy';

export interface LinkSettings {
  alias: string;
  requirePin: boolean;
  alwaysVisible: boolean;
  /**
   * Quick Share 传输方式（三态，推荐用这个）：
   * - `'auto'`   自动：探测对端单播是否可达，不可达才走 BLE 引导 + Wi-Fi Direct（默认）；
   * - `'lan'`    仅局域网：不做 WLAN 直连升级，也不广播/建 P2P 组；
   * - `'direct'` WLAN 直连优先：跳过探测直接走 BLE 引导 + Wi-Fi Direct，且不再广播 mDNS。
   * 取值与语义见 `quickshare/model/TransportPolicy.ets`。
   */
  quickshareTransport?: QuickShareTransportMode;
  /**
   * @deprecated 旧的布尔开关，只用于**读取旧配置迁移**（true→'direct'，false→'auto'）。
   * 新代码请读 `quickshareTransport`；保存时会写一份镜像值以便回退到旧版本。
   */
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
  /**
   * 动态图片传输(Beta)：开启后发送时自动识别动态图片（鸿蒙动态照片 / Google Motion Photo /
   * Apple Live Photo / 华为 livp / 三星·小米·OPPO·vivo·荣耀等实况照片），并按对端品牌
   * 自动封装成对方相册认得的格式（Apple 实况照片 / Android 动态照片并叠加该品牌私有字段；
   * 鸿蒙与电脑仍拆成「图片 + 视频」）；接收时若判定为非鸿蒙格式动态图片，则解析并还原为
   * 鸿蒙动态照片（默认关，Beta 功能；默认值见 defaultSettings）。
   */
  dynamicPhotoEnabled?: boolean;
  /**
   * 「默认通用动态图片格式」：认不出对端品牌时，动态图片按哪种格式发送。
   * `'apple'` = Apple 实况照片（同名 JPEG + MOV），`'android'` = Android 标准动态照片
   * （JPEG 尾部追加 MP4 + XMP 声明）。仅「动态图片传输(Beta)」打开时生效。
   */
  defaultLivePhotoFormat?: string;
  /**
   * 「HDR照片转换为HDR Vivid格式」：开启后发送带增益图的 HDR 照片时，按 HDR Vivid /
   * ISO 21496-1 的**双 JPEG（基础 SDR 图 + 增益图）**形态重排，并重建 MPF 索引；
   * 不支持 HDR 的对端只会看到基础 SDR 图（不会发暗发灰）。**默认关**（策略见 docs/HDR_IMAGE.md）。
   */
  hdrVividEnabled?: boolean;
  /**
   * 「照片EXIF信息保留」：关闭后 HDR 改写会**删掉 EXIF**（拍摄时间 / GPS / 机型等隐私字段），
   * 只保留 ICC 等显示必需段。注意 EXIF 里的厂商 MakerNote 同时承载 Apple 实况照片配对
   * （tag 0x0011）等能力，关掉即放弃这些元数据。**默认开**。
   */
  photoExifKeep?: boolean;
  /**
   * UI 标签「HDR转换优先重编码」（仅「HDR照片转换为HDR Vivid格式」打开时显示，**默认关**）。
   *
   * 行为（按产品确认）：**打开后不走系统 API 重编码**，直接走无损换壳（APP2 ISO 21496-1 URN +
   * MPF attribute 0x50000、像素字节原样）；关闭时先尝试系统 API（`packToFile` + AUTO + 带增益图
   * 的 Picture），产物若丢了增益图会被丢弃并自动退回无损换壳（真机实测系统 API 会把 JPEG 增益图拍平）。
   * 键名按**真实行为**取（skipSystemReencode），避免后来人把标签字面意思当行为。
   */
  hdrSkipSystemReencode?: boolean;
  /**
   * 「动态图片/HDR图片不保存至下载文件夹」（默认关）：开启后，**已经存进相册（或已登记待保存）
   * 的动态照片**不再往「下载」文件夹里放一份副本；其它文件照旧。普通 HDR 静态图仍会保存到下载文件夹。
   */
  skipDownloadCopyForGalleryPhotos?: boolean;
  /**
   * 「照片/视频保存至图库」。
   *
   * 开关只记录保存偏好；收到媒体后才按需通过系统 SaveButton 授权，
   * 不代表当前进程已经持有图库临时授权。
   */
  saveReceivedMediaToGallery?: boolean;
}

const STORE_NAME = 'cashmere_settings';

function defaultSettings(): LinkSettings {
  return {
    alias: '羊绒互传',
    requirePin: true,
    alwaysVisible: true,
    quickshareWlanDirect: false,
    quickshareTransport: QUICKSHARE_TRANSPORT_DEFAULT,
    btMac: '',
    wifiUpgradeTcp: true,
    aggregateAsHome: true,
    hideTransferPage: false,
    quickShareHintShown: false,
    localSendNoticeShown: false,
    encryptionEnabled: true,
    receivePin: '',
    keepAlive: true,
    dynamicPhotoEnabled: false,
    defaultLivePhotoFormat: 'android',
    hdrVividEnabled: false,
    photoExifKeep: true,
    hdrSkipSystemReencode: false,
    skipDownloadCopyForGalleryPhotos: false,
    saveReceivedMediaToGallery: false
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
      // 三态传输方式：新键缺失（''）时按旧布尔迁移，保证老用户升级后行为不变（true→direct）。
      const storedTransport = await store.get('quickshareTransport', '');
      const quickshareTransport: QuickShareTransportMode = typeof storedTransport === 'string' && storedTransport.length > 0
        ? parseTransportMode(storedTransport)
        : migrateLegacyWlanDirect(quickshareWlanDirect === true);
      const btMac = await store.get('btMac', '');
      const wifiUpgradeTcp = await store.get('wifiUpgradeTcp', true);
      const aggregateAsHome = await store.get('aggregateAsHome', true);
      const hideTransferPage = await store.get('hideTransferPage', false);
      const quickShareHintShown = await store.get('quickShareHintShown', false);
      const localSendNoticeShown = await store.get('localSendNoticeShown', false);
      const encryptionEnabled = await store.get('encryptionEnabled', true);
      const receivePin = await store.get('receivePin', '');
      const keepAlive = await store.get('keepAlive', true);
      const dynamicPhotoEnabled = await store.get('dynamicPhotoEnabled', false);
      const defaultLivePhotoFormat = await store.get('defaultLivePhotoFormat', 'android');
      const hdrVividEnabled = await store.get('hdrVividEnabled', false);
      const photoExifKeep = await store.get('photoExifKeep', true);
      const hdrSkipSystemReencode = await store.get('hdrSkipSystemReencode', false);
      const skipDownloadCopyForGalleryPhotos = await store.get('skipDownloadCopyForGalleryPhotos', false);
      const saveReceivedMediaToGallery = await store.get('saveReceivedMediaToGallery', false);
      SettingsStore.cached = {
        alias: typeof alias === 'string' && alias.length > 0 ? alias : '羊绒互传',
        requirePin: requirePin === true,
        alwaysVisible: alwaysVisible === true,
        quickshareWlanDirect: quickshareWlanDirect === true,
        quickshareTransport: quickshareTransport,
        btMac: typeof btMac === 'string' ? btMac : '',
        wifiUpgradeTcp: wifiUpgradeTcp === true,
        aggregateAsHome: aggregateAsHome === true,
        hideTransferPage: hideTransferPage === true,
        quickShareHintShown: quickShareHintShown === true,
        localSendNoticeShown: localSendNoticeShown === true,
        encryptionEnabled: encryptionEnabled !== false,
        receivePin: typeof receivePin === 'string' ? receivePin : '',
        keepAlive: keepAlive !== false,
        dynamicPhotoEnabled: dynamicPhotoEnabled === true,
        defaultLivePhotoFormat: typeof defaultLivePhotoFormat === 'string' && defaultLivePhotoFormat.length > 0
          ? defaultLivePhotoFormat
          : 'android',
        hdrVividEnabled: hdrVividEnabled === true,
        photoExifKeep: photoExifKeep !== false,
        hdrSkipSystemReencode: hdrSkipSystemReencode === true,
        skipDownloadCopyForGalleryPhotos: skipDownloadCopyForGalleryPhotos === true,
        saveReceivedMediaToGallery: saveReceivedMediaToGallery === true
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
      quickshareTransport: settings.quickshareTransport !== undefined
        ? settings.quickshareTransport
        : (prev?.quickshareTransport ?? QUICKSHARE_TRANSPORT_DEFAULT),
      btMac: settings.btMac,
      wifiUpgradeTcp: settings.wifiUpgradeTcp,
      aggregateAsHome: settings.aggregateAsHome !== undefined ? settings.aggregateAsHome : (prev?.aggregateAsHome ?? true),
      hideTransferPage: settings.hideTransferPage !== undefined ? settings.hideTransferPage : (prev?.hideTransferPage ?? false),
      quickShareHintShown: settings.quickShareHintShown !== undefined ? settings.quickShareHintShown : (prev?.quickShareHintShown ?? false),
      localSendNoticeShown: settings.localSendNoticeShown !== undefined ? settings.localSendNoticeShown : (prev?.localSendNoticeShown ?? false),
      encryptionEnabled: settings.encryptionEnabled !== undefined ? settings.encryptionEnabled : (prev?.encryptionEnabled ?? true),
      receivePin: settings.receivePin !== undefined ? settings.receivePin : (prev?.receivePin ?? ''),
      keepAlive: settings.keepAlive !== undefined ? settings.keepAlive : (prev?.keepAlive ?? true),
      dynamicPhotoEnabled: settings.dynamicPhotoEnabled !== undefined
        ? settings.dynamicPhotoEnabled
        : (prev?.dynamicPhotoEnabled ?? false),
      defaultLivePhotoFormat: settings.defaultLivePhotoFormat !== undefined
        && settings.defaultLivePhotoFormat.length > 0
        ? settings.defaultLivePhotoFormat
        : (prev?.defaultLivePhotoFormat ?? 'android'),
      hdrVividEnabled: settings.hdrVividEnabled !== undefined
        ? settings.hdrVividEnabled
        : (prev?.hdrVividEnabled ?? false),
      photoExifKeep: settings.photoExifKeep !== undefined
        ? settings.photoExifKeep
        : (prev?.photoExifKeep ?? true),
      hdrSkipSystemReencode: settings.hdrSkipSystemReencode !== undefined
        ? settings.hdrSkipSystemReencode
        : (prev?.hdrSkipSystemReencode ?? false),
      skipDownloadCopyForGalleryPhotos: settings.skipDownloadCopyForGalleryPhotos !== undefined
        ? settings.skipDownloadCopyForGalleryPhotos
        : (prev?.skipDownloadCopyForGalleryPhotos ?? false),
      saveReceivedMediaToGallery: settings.saveReceivedMediaToGallery !== undefined
        ? settings.saveReceivedMediaToGallery
        : (prev?.saveReceivedMediaToGallery ?? false)
    };
    SettingsStore.cached = merged;
    try {
      const store = await dataPreferences.getPreferences(context, STORE_NAME);
      await store.put('alias', settings.alias);
      await store.put('requirePin', settings.requirePin);
      await store.put('alwaysVisible', settings.alwaysVisible);
      await store.put('quickshareWlanDirect', merged.quickshareWlanDirect);
      await store.put('quickshareTransport', merged.quickshareTransport ?? QUICKSHARE_TRANSPORT_DEFAULT);
      await store.put('btMac', settings.btMac);
      await store.put('wifiUpgradeTcp', settings.wifiUpgradeTcp);
      await store.put('aggregateAsHome', merged.aggregateAsHome);
      await store.put('hideTransferPage', merged.hideTransferPage);
      await store.put('quickShareHintShown', merged.quickShareHintShown);
      await store.put('localSendNoticeShown', merged.localSendNoticeShown);
      await store.put('encryptionEnabled', merged.encryptionEnabled);
      await store.put('receivePin', merged.receivePin);
      await store.put('keepAlive', merged.keepAlive);
      await store.put('dynamicPhotoEnabled', merged.dynamicPhotoEnabled === true);
      await store.put('defaultLivePhotoFormat', merged.defaultLivePhotoFormat ?? 'android');
      await store.put('hdrVividEnabled', merged.hdrVividEnabled === true);
      await store.put('photoExifKeep', merged.photoExifKeep !== false);
      await store.put('hdrSkipSystemReencode', merged.hdrSkipSystemReencode === true);
      await store.put('skipDownloadCopyForGalleryPhotos', merged.skipDownloadCopyForGalleryPhotos === true);
      await store.put('saveReceivedMediaToGallery', merged.saveReceivedMediaToGallery === true);
      await store.flush();
    } catch (error) {
      Lg.w(`SettingsStore save failed: ${JSON.stringify(error)}`);
    }
  }

  static current(): LinkSettings {
    return SettingsStore.cached ?? defaultSettings();
  }

  /**
   * 只更新“接收媒体自动入图库”开关。
   *
   * 设置行只改这一项时，不应构造一个缺字段的 LinkSettings 再依赖通用 save 的必填字段；
   * 这里复用已加载对象并只持久化该键。
   */
  static async setSaveReceivedMediaToGallery(context: common.Context, enabled: boolean): Promise<void> {
    const current: LinkSettings = await SettingsStore.load(context);
    current.saveReceivedMediaToGallery = enabled;
    SettingsStore.cached = current;
    AppStorage.setOrCreate('saveReceivedMediaToGallery', enabled);
    try {
      const store = await dataPreferences.getPreferences(context, STORE_NAME);
      await store.put('saveReceivedMediaToGallery', enabled);
      await store.flush();
      Lg.i('[GALLERY] setting persisted enabled=' + enabled);
    } catch (error) {
      Lg.w('[GALLERY] setting persist failed: ' + JSON.stringify(error));
    }
  }
}
