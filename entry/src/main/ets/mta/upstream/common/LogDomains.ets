/**
 * LogDomains.ets — 业务域常量定义
 *
 * 用于 hilog 的 domain 参数，支持 `hdc hilog -t <domain>` 按业务域过滤日志。
 * 每个域对应一组相关的业务模块。
 */

export class LogDomains {
  /** 通用/应用生命周期：EntryAbility、EntryBackupAbility、AppService、DialogService、ReceiveHistoryService */
  static readonly GENERAL: number = 0x0000;
  /** 设备发现、注册、扫描：DiscoveryRepository、DeviceRepository、MainTabViewModel */
  static readonly DISCOVERY: number = 0x0001;
  /** 文件发送/接收/传输进度：SendRepository、ReceiveRepository、ReceiveTargets、SendViewModel、SendContent、WebShareRepository、ChecksumRepository、GallerySaveService、VideoThumbnailUtil、service/transfer/*（会话引擎与协议适配器）、TransferCenterViewModel、SessionDetailViewModel、SessionDetailPage、BackgroundTransferService、PendingRequestNotifier */
  static readonly TRANSFER: number = 0x0002;
  /** 网络接口、WiFi 状态：AppCore、NetworkSettingsSection */
  static readonly NETWORK: number = 0x0003;
  /** HTTP 服务器、端口监听：ServerRepository */
  static readonly SERVER: number = 0x0004;
  /** 设置、偏好、收藏：SettingsRepository、PreferencesUtil、FavoritesService、SettingsViewModel */
  static readonly SETTINGS: number = 0x0005;
  /** MTA（互传联盟）协议全链路：service/mta、MtaRepository、Mta*ViewModel */
  static readonly MTA: number = 0x0006;
}
