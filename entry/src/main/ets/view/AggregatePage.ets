import { LogCapture as Lg } from '../common/LogCapture';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
import { DeviceEndpoint, OutgoingFile, TransferEvent, TransferTask } from '../model/TransferModels';
import { FilePickerHelper } from '../common/FilePickerHelper';
import { IconCircleButton } from '../components/IconCircleButton';
import { DeviceList } from './DeviceList';
import { HwColor, HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwPrimary, hwGlassBorder, reloadAppTheme, resolvePrimaryColor } from '../utils/DesignTokens';
import { cardGlassEffect, toastSystemMaterial, dialogSystemMaterial, cardGlassBorderColor, cardGlassShadow } from '../utils/SystemMaterial';
import { AppServices } from '../common/AppServices';
import { NearbyScanHub } from '../common/NearbyScanHub';
import { SettingsStore } from '../common/SettingsStore';
import { sharedFilesFromParams } from '../common/ShareHandleUtil';
import { DynamicPhotoService } from '../common/DynamicPhotoService';
import { GsSendHooks, GsStreamConnection, GsTransportChange } from '../protocol/gs/GsFacade';
import { NearbyBleSocketClient } from '../quickshare/ble/NearbyBleSocketClient';
import { NearbyP2pDirect } from '../quickshare/ble/NearbyP2pDirect';
import { LanReachability, TransportDecision } from '../quickshare/utils/LanReachability';
import { QuickShareTransportMode } from '../quickshare/model/TransportPolicy';
import { QuickShareTransferHistory } from '../quickshare/storage/TransferHistory';
import { WindowsNearbyOutgoingFile } from '../windowsnearby/WindowsNearbySender';
import { CardSurface } from '../components/CardSurface';
import { PendingDynamicPhotoCard } from '../components/PendingDynamicPhotoCard';
import { AccentColorSentinel } from '../components/MaterialCard';

const TITLE_BAR_HEIGHT_FREE: number = 138; // 与 HdsNavigation FREE 模式标题栏高度一致

/** 传输卡片保留窗口：任务完成后仍在该窗口内展示（含快速完成的 LocalSend 发送），超过后从实时卡片移除。 */
const COMPLETED_CARD_KEEP_MS: number = 6000;
/** 聚合页定期刷新实时卡片，剔除已超出保留窗口的完成任务。 */
const SYNC_INTERVAL_MS: number = 1000;

@Component
export struct AggregatePage {
  /** 主题色变化时触发重建，让 HwColor.primary 与选中态取到新色值 */
  @StorageProp('accentColor') @Watch('onAccentColorChanged') accentColor: string = '';
  /** 页面底色（由 applyAppTheme 发布）。直接读 HwColor.background 登记不上依赖 */
  @StorageProp('pageBackground') pageBackground: string = '';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('immersiveLightEnabled') immersiveLightEnabled: boolean = true;
  @StorageLink('beautifulCards') beautifulCards: boolean = false;
  @StorageLink('classicCards') classicCards: boolean = false;
  @StorageLink('cardShadowBorder') cardShadowBorder: boolean = true;
  @StorageLink('experimentalCards') experimentalCards: boolean = false;
  @StorageLink('fontMode') fontMode: string = 'system';
  @StorageLink('fontFamilyEn') fontFamilyEn: string = 'system';
  @StorageLink('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageLink('fontWeightMode') fontWeightMode: string = 'system';
  @StorageLink('fontWeightValue') fontWeightValue: number = 400;
  /** 局域网网页传输的访问地址（http://IP:端口），来自 AppServices.localsendWebLink()。 */
  @State webLinkText: string = '';

  @State quickShareDevices: DeviceEndpoint[] = [];
  @State windowsDevices: DeviceEndpoint[] = [];
  @State localSendDevices: DeviceEndpoint[] = [];
  @State mtaDevices: DeviceEndpoint[] = [];
  @State selectedFiles: OutgoingFile[] = [];
  /** 聚合页实时进度：三种协议（LocalSend / Quick Share / Windows Nearby）进行中的传输。
   *  用三个独立 @State 数组直接驱动三张卡片，避免 `@Builder` 参数数组的 Reactivity 跟踪问题。 */
  @State localSendLive: TransferTask[] = [];
  @State quickShareLive: TransferTask[] = [];
  @State windowsLive: TransferTask[] = [];

  private services?: AppServices;
  private hub?: NearbyScanHub;
  private syncTimer: number = -1;
  private selectionVersion: number = 0;
  private sendPending: boolean = false;
  /** 定时器计数：每 5 次刷新一次局域网网页传输地址。 */
  private webLinkTicks: number = 0;
  private readonly onScanChanged: () => void = (): void => {
    this.syncFromHub();
  };
  private readonly onTransferChanged: (event: TransferEvent) => void = (event: TransferEvent): void => {
    this.syncTransfers();
  };
  /** 热点地址探测命中后立即刷新网页传输链接，不等 5 秒一轮的地址刷新。 */
  private readonly onHotspotAddress: (address: string) => void = (address: string): void => {
    this.refreshWebLink();
  };

  private appFontFamily(content: string): string {
    if (this.fontMode !== 'custom') {
      return 'HarmonyOS Sans';
    }
    const family = this.hasCjk(content) ? this.fontFamilyZh : this.fontFamilyEn;
    return family === 'system' || family.length === 0 ? 'HarmonyOS Sans' : family;
  }

  private hasCjk(content: string): boolean {
    for (let i = 0; i < content.length; i++) {
      const code = content.charCodeAt(i);
      if (code >= 0x4E00 && code <= 0x9FFF) {
        return true;
      }
    }
    return false;
  }

  private appFontWeight(): number {
    return this.fontWeightMode === 'custom' ? this.fontWeightValue : 400;
  }

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    // 预热系统文件选择器实例，让首次点击设备卡片不再耗费在构造选择器上，降低点击响应时延。
    FilePickerHelper.warmUp(context);
    this.services = AppServices.get(context);
    // 全局三协议接收扫描由应用进程生命周期（NearbyScanHub）常开；本页只消费其结果与
    // 发送所需实例，不再自建浏览器 / 扫描器，避免多扫描器重复启动。
    this.hub = NearbyScanHub.get(context);
    this.hub.setOnChange(this.onScanChanged);
    this.hub.ensureStarted();
    this.loadShareParams();
    this.syncFromHub();
    // 订阅传输进度，让聚合页顶部实时展示三种协议的进行中传输进度条。
    this.services.transfer.addListener(this.onTransferChanged);
    this.services.onHotspotAddressChange(this.onHotspotAddress);
    this.syncTransfers();
    // 周期性刷新实时卡片：剔除已超出「完成后保留窗口」的完成任务，避免卡片滞留。
    this.startSyncTimer();
  }

  aboutToDisappear(): void {
    // 仅退订本页对扫描结果的监听；全局扫描不随本页消失而停止。
    this.hub?.removeOnChange(this.onScanChanged);
    this.services?.transfer.removeListener(this.onTransferChanged);
    this.services?.offHotspotAddressChange(this.onHotspotAddress);
    this.stopSyncTimer();
    this.replaceSelection([]);
  }

  private startSyncTimer(): void {
    this.stopSyncTimer();
    this.webLinkTicks = 0;
    this.syncTimer = setInterval((): void => {
      this.syncTransfers();
      // 局域网地址可能因服务启动 / 网络切换而变化：每 5 秒刷新一次地址卡片。
      this.webLinkTicks += 1;
      if (this.webLinkTicks >= 5) {
        this.webLinkTicks = 0;
        this.refreshWebLink();
      }
    }, SYNC_INTERVAL_MS);
  }

  private stopSyncTimer(): void {
    if (this.syncTimer !== -1) {
      clearInterval(this.syncTimer);
      this.syncTimer = -1;
    }
  }

  private syncFromHub(): void {
    this.refreshWebLink();
    if (this.hub === undefined) {
      return;
    }
    // getXxx 返回新数组引用。为避免每次扫描回调都触发整段设备卡片重排版、占用主线程
    // （点击设备卡片时主线程越空闲，点击响应越快），仅在列表有实质变化时才重新赋值 @State。
    const quick = this.hub.getQuickShareDevices();
    const windows = this.hub.getWindowsDevices();
    const local = this.hub.getLocalSendDevices();
    const mta = this.hub.getMtaDevices();
    if (!this.listEquals(this.mtaDevices, mta)) { this.mtaDevices = mta; }
    if (!this.listEquals(this.quickShareDevices, quick)) {
      this.quickShareDevices = quick;
    }
    if (!this.listEquals(this.windowsDevices, windows)) {
      this.windowsDevices = windows;
    }
    if (!this.listEquals(this.localSendDevices, local)) {
      this.localSendDevices = local;
    }
  }

  private listEquals(a: DeviceEndpoint[], b: DeviceEndpoint[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (!this.deviceEquals(a[i], b[i])) {
        return false;
      }
    }
    return true;
  }

  private deviceEquals(a: DeviceEndpoint, b: DeviceEndpoint): boolean {
    return a.id === b.id && a.name === b.name && a.address === b.address &&
      a.port === b.port && a.https === b.https && a.model === b.model && a.protocol === b.protocol && a.source === b.source &&
      a.fingerprint === b.fingerprint;
  }

  private allDevices(): DeviceEndpoint[] {
    const all: DeviceEndpoint[] = [];
    for (const device of this.quickShareDevices) {
      all.push(device);
    }
    for (const device of this.windowsDevices) {
      all.push(device);
    }
    for (const device of this.localSendDevices) {
      all.push(device);
    }
    for (const device of this.mtaDevices) { all.push(device); }
    return all;
  }

  private totalDiscovered(): number {
    return this.quickShareDevices.length + this.windowsDevices.length + this.localSendDevices.length + this.mtaDevices.length;
  }

  /** 刷新「局域网网页传输」的访问地址（IP:端口），地址变化时才更新 @State。 */
  private refreshWebLink(): void {
    if (this.services === undefined) {
      return;
    }
    const link = this.services.localsendWebLink();
    const text = link.address.length === 0 ? '' : link.scheme + '://' + link.address + ':' + link.port;
    if (text !== this.webLinkText) {
      this.webLinkText = text;
    }
  }

  /** 同步正在进行的传输（三种协议），仅在有实质变化时更新对应 @State，避免频繁重排。 */
  private syncTransfers(): void {
    if (this.services === undefined) {
      if (this.localSendLive.length > 0 || this.quickShareLive.length > 0 || this.windowsLive.length > 0) {
        this.localSendLive = [];
        this.quickShareLive = [];
        this.windowsLive = [];
      }
      return;
    }
    const now = Date.now();
    const all = this.services.transfer.listTasks();
    const local: TransferTask[] = [];
    const qs: TransferTask[] = [];
    const wn: TransferTask[] = [];
    for (let i = 0; i < all.length; i++) {
      const task = all[i];
      // 仅展示：进行中，或刚完成/失败仍在保留窗口内（避免快速完成的 LocalSend 发送“看不到卡片”）。
      const active = task.state === 'pending' || task.state === 'awaiting-pin' || task.state === 'running' ||
        (task.completedAt > 0 && now - task.completedAt < COMPLETED_CARD_KEEP_MS);
      if (!active) {
        continue;
      }
      if (task.device.protocol === 'localsend') {
        local.push(task);
      } else if (task.device.protocol === 'quickshare') {
        qs.push(task);
      } else if (task.device.protocol === 'windowsnearby') {
        wn.push(task);
      }
    }
    // 诊断：确认任务是否进入 map、协议是否匹配（仅在有任务时输出，避免空转刷日志）。
    if (all.length > 0) {
      Lg.i('[AGG] syncTransfers all=' + all.length + ' local=' + local.length + ' qs=' + qs.length +
        ' wn=' + wn.length + ' | live local=' + this.localSendLive.length + ' qs=' + this.quickShareLive.length +
        ' wn=' + this.windowsLive.length);
    }
    if (!this.taskListEquals(this.localSendLive, local)) {
      this.localSendLive = local;
    }
    if (!this.taskListEquals(this.quickShareLive, qs)) {
      this.quickShareLive = qs;
    }
    if (!this.taskListEquals(this.windowsLive, wn)) {
      this.windowsLive = wn;
    }
  }

  private taskListEquals(a: TransferTask[], b: TransferTask[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i].id !== b[i].id || a[i].state !== b[i].state || a[i].progress !== b[i].progress) {
        return false;
      }
    }
    return true;
  }

  private protocolLabel(kind: string): string {
    if (kind === 'localsend') {
      return 'LocalSend';
    }
    if (kind === 'quickshare') {
      return 'Quick Share';
    }
    if (kind === 'windowsnearby') {
      return 'Windows Nearby';
    }
    return '传输';
  }

  /** 主题色变了：HwColor 是模块级对象，改属性不会触发刷新，靠这里重建页面 */
  onAccentColorChanged(): void {
    reloadAppTheme();
  }

  /** 当前主题色。读 accentColor 建立依赖；直接写 HwColor.primary 切色后不会重新求值 */
  private accentOrPrimary(): string {
    return this.accentColor.length > 0 ? this.accentColor : HwColor.primary;
  }

  build() {
    Column({ space: 12 }) {
      // 主题色依赖：切色时让本页重新求值（零尺寸，不参与布局）
      AccentColorSentinel()
      Blank().height(TITLE_BAR_HEIGHT_FREE + this.statusBarHeight)
      // 「动态照片待保存」放在最上面：接收到的动态图片需要用户点一次系统保存按钮才进图库，
      // 埋在页面中间会被直接划过去，导致「明明解析成功了却看不到动态照片」。
      PendingDynamicPhotoCard()
      // 三种协议各自的传输进程卡片（标题不含“进度”）。各卡 @Builder 直接读 @State 数组，
      // 保证 ArkUI 依赖跟踪到数组变化 → 卡片增删/状态切换都能重画。
      this.localSendCard()
      this.quickShareCard()
      this.windowsCard()
      this.lanWebCard()
      this.statusCard()
      this.selectFileCard()
      if (this.selectedFiles.length > 0) {
        Text('已选择 ' + this.selectedFiles.length + ' 个文件，点击下方设备即可发送')
          .fontSize(12).fontFamily(this.appFontFamily('已选择 个文件，点击下方设备即可发送')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).width('100%').padding({ left: 4, right: 4, bottom: 8 })
      }
      Text('附近设备（共 ' + this.totalDiscovered() + ' 台）').fontSize(14).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('附近设备')).fontColor(hwTextPrimary(this.isDarkMode)).width('100%').padding({ left: 4 })
      DeviceList({
        devices: this.allDevices(),
        onSelect: (device: DeviceEndpoint): void => {
          this.sendOrPick(device).catch((error: Error): void => {
            promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: error.message });
          });
        }
      })
      if (this.totalDiscovered() === 0) {
        Text('当前未发现附近设备。请确保对端已打开对应的分享功能，并与本机处于同一网络 / 蓝牙范围')
          .fontSize(14).fontFamily(this.appFontFamily('当前未发现附近设备')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
          .width('100%').textAlign(TextAlign.Center).padding({ top: 24 })
      }
    }
    .width('100%')
    .padding({ left: HwSpace.lg, right: HwSpace.lg, top: HwSpace.lg, bottom: 96 })
  }

  @Builder
  transferRow(task: TransferTask) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(task.direction === 'send' ? '↑' : '↓').fontSize(14)
          .fontFamily(this.appFontFamily(task.direction === 'send' ? '↑' : '↓')).fontWeight(this.appFontWeight())
          .fontColor(task.direction === 'send' ? resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()) : hwTextSecondary(this.isDarkMode))
        Text(this.protocolLabel(task.device.protocol)).fontSize(12)
          .fontFamily(this.appFontFamily(this.protocolLabel(task.device.protocol))).fontWeight(this.appFontWeight())
          .fontColor(hwTextSecondary(this.isDarkMode))
        Text(task.device.name).layoutWeight(1).fontSize(13)
          .fontFamily(this.appFontFamily(task.device.name)).fontWeight(this.appFontWeight()).fontColor(hwTextPrimary(this.isDarkMode))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      Text(this.transferStatusText(task))
        .fontSize(12)
        .fontFamily(this.appFontFamily(this.transferStatusText(task)))
        .fontWeight(this.appFontWeight())
        .fontColor(resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()))
        .width('100%')
    }
    .width('100%')
  }

  @Builder
  localSendCard() {
    // 条件必须写在 CardSurface **外面**：CardSurface 内层是 ToggleType.Button 承载层，
    // 而该类型有 28vp 的默认高度——内容为空时它仍会占出一段空档（表现为「间距莫名变大」）。
    if (this.localSendLive.length > 0) {
      CardSurface({ radius: HwRadius.card }) {
        Column({ space: 8 }) {
          Text('LocalSend')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily('LocalSend'))
            .fontColor(hwTextPrimary(this.isDarkMode))
            .width('100%')
          ForEach(this.localSendLive, (task: TransferTask): void => {
            this.transferRow(task);
          }, (task: TransferTask): string => task.id + ':' + task.state + ':' + this.accentColor)
        }
        .width('100%')
        .padding(HwSpace.lg)
        .borderRadius(HwRadius.card)
        .backgroundColor(Color.Transparent)
        .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
        .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
        .clip(true)
        .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
      }
    }
  }

  @Builder
  quickShareCard() {
    if (this.quickShareLive.length > 0) {
      CardSurface({ radius: HwRadius.card }) {
        Column({ space: 8 }) {
          Text('Quick Share')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily('Quick Share'))
            .fontColor(hwTextPrimary(this.isDarkMode))
            .width('100%')
          ForEach(this.quickShareLive, (task: TransferTask): void => {
            this.transferRow(task);
          }, (task: TransferTask): string => task.id + ':' + task.state + ':' + this.accentColor)
        }
        .width('100%')
        .padding(HwSpace.lg)
        .borderRadius(HwRadius.card)
        .backgroundColor(Color.Transparent)
        .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
        .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
        .clip(true)
        .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
      }
    }
  }

  @Builder
  windowsCard() {
    if (this.windowsLive.length > 0) {
      CardSurface({ radius: HwRadius.card }) {
        Column({ space: 8 }) {
          Text('Windows Nearby')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily('Windows Nearby'))
            .fontColor(hwTextPrimary(this.isDarkMode))
            .width('100%')
          ForEach(this.windowsLive, (task: TransferTask): void => {
            this.transferRow(task);
          }, (task: TransferTask): string => task.id + ':' + task.state + ':' + this.accentColor)
        }
        .width('100%')
        .padding(HwSpace.lg)
        .borderRadius(HwRadius.card)
        .backgroundColor(Color.Transparent)
        .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
        .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
        .clip(true)
        .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
      }
    }
  }

  /** 局域网网页传输：显示访问地址（IP:端口），点击进入页面。 */
  @Builder
  lanWebCard() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        IconCircleButton({ symbol: $r('sys.symbol.wifi'), buttonSize: 36, iconSize: 18 })
        Column({ space: 2 }) {
          Text('局域网网页传输')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily('局域网网页传输'))
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text(this.webLinkText.length > 0 ? this.webLinkText : '未获取到局域网地址，请确认已连接 Wi-Fi')
            .fontSize(12)
            .fontColor(this.webLinkText.length > 0 ? resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()) : hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily(this.webLinkText.length > 0 ? this.webLinkText : '未获取到局域网地址，请确认已连接 Wi-Fi'))
            .fontWeight(this.appFontWeight())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([hwTextSecondary(this.isDarkMode)])
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.card)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
      .onClick(() => {
        router.pushUrl({ url: 'pages/LanWebTransfer' }).catch((error: BusinessError): void => {
          Lg.w('LanWebTransfer route failed: ' + error.message);
        });
      })
    }
  }

  /** 卡片内状态文案：进行中显示「传输中...」，完成后短暂显示「已完成」，失败显示「失败」。 */
  private transferStatusText(task: TransferTask): string {
    if (task.state === 'completed') {
      return '已完成';
    }
    if (task.state === 'failed' || task.state === 'rejected') {
      return '失败';
    }
    return '传输中...';
  }

  @Builder
  statusCard() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 8 }) {
        Text('扫描状态').fontSize(16).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('扫描状态')).fontColor(hwTextPrimary(this.isDarkMode)).layoutWeight(1)
        Text('已发现 ' + this.totalDiscovered() + ' 台设备').fontSize(13).fontFamily(this.appFontFamily('已发现 台设备')).fontWeight(this.appFontWeight()).fontColor(resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()))
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.card)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
    }
  }

  @Builder
  selectFileCard() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Text('选择文件').fontSize(16).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('选择文件')).fontColor(resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary())).layoutWeight(1)
        Text(this.selectedFiles.length > 0 ? '已选择 ' + this.selectedFiles.length + ' 个文件' : '从系统中选择要发送的文件')
          .fontSize(12).fontFamily(this.appFontFamily('从系统中选择要发送的文件')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([hwTextSecondary(this.isDarkMode)])
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.card)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
      .onClick(() => this.pickFiles())
    }
  }

  private replaceSelection(files: OutgoingFile[]): void {
    this.selectionVersion += 1;
    this.selectedFiles = files;
  }

  private async sendOrPick(device: DeviceEndpoint): Promise<void> {
    if (this.sendPending) { throw new Error('正在发送，请等待本次发送结束'); }
    this.sendPending = true;
    try {
      if (this.selectedFiles.length === 0) {
        const picked = await this.pickFilesNow();
        if (picked.length === 0) { return; }
      }
      await this.send(device);
    } finally { this.sendPending = false; }
  }

  private async send(device: DeviceEndpoint): Promise<void> {
    const version = this.selectionVersion;
    const files: OutgoingFile[] = this.selectedFiles.slice();
    if (files.length === 0) { throw new Error('请先选择文件'); }
    if (device.protocol === 'quickshare') {
      await this.sendQuickShare(device, files);
    } else if (device.protocol === 'windowsnearby') {
      await this.sendWindows(device, files);
    } else if (device.protocol === 'localsend') {
      await this.sendLocalSend(device, files);
    } else if (device.protocol === 'mta' && this.hub?.mta !== undefined) {
      await this.hub.mta.send(device, files);
    } else {
      throw new Error('不支持的协议');
    }
    if (version === this.selectionVersion && device.protocol !== 'mta') { this.replaceSelection([]); }
  }

  private async sendQuickShare(device: DeviceEndpoint, original: OutgoingFile[]): Promise<void> {
    const facade = this.hub?.facade;
    const browser = this.hub?.browser;
    const localIp = this.hub?.localIp ?? '';
    if (facade === undefined) {
      throw new Error('Quick Share 会话尚未就绪');
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    // 动态图片传输(Beta)：按对端品牌把动态图片封装成对方认得的格式（Apple 实况 / Android 动态照片 /
    // 鸿蒙与电脑仍拆成「图片 + 视频」）再走原协议。
    const outgoing: OutgoingFile[] = await DynamicPhotoService.prepareOutgoing(ctx, original,
      DynamicPhotoService.resolveFormatFor(device));
    const task = this.services?.transfer.manualTask(device, outgoing, 'send', 'quickshare');
    try {
      // 介质决策：三态设置（auto 探测对端可达性 / lan 只走局域网 / direct 优先直连）。
      // 依据与失败链见 docs/WIFI_DIRECT.md §5.4。
      const mode: QuickShareTransportMode = SettingsStore.current().quickshareTransport ?? 'auto';
      const peerKey: string = device.fingerprint.length > 0 ? device.fingerprint : device.id;
      const peerIp: string = device.source === 'ble' ? '' : (device.address ?? '');
      const decision: TransportDecision =
        await LanReachability.choose(mode, peerKey, peerIp, device.port ?? 0);
      Lg.i('[QUICKSHARE] transport=' + decision.choice + ' mode=' + mode + ' reason=' + decision.reason
        + ' peer=' + device.name);
      const upgradeWanted: boolean = decision.choice === 'ble-p2p';
      const hooks: GsSendHooks = {
        onPin: (pin: string): Promise<boolean> => this.confirmQuickSharePin(pin),
        onProgress: (percent: number): void => {
          if (task !== undefined) {
            this.services?.transfer.setTaskProgress(task.id, percent);
          }
        },
        localEndpointId: browser?.localEndpointIdValue(),
        sourceAddress: localIp.length > 0 ? localIp : undefined,
        forceWifiDirect: upgradeWanted,
        pcPeer: device.deviceType === 3,
        onWifiDirectTransport: mode === 'lan' ? undefined : (creds): Promise<GsStreamConnection | undefined> => {
          return new NearbyP2pDirect().connectAsClient(creds);
        },
        onTransportChange: (change: GsTransportChange): void => {
          Lg.i('[QUICKSHARE][P2P] transport=' + change.medium + ' upgraded=' + change.upgraded
            + ' detail=' + change.detail);
        }
      };
      let bleMac: string = '';
      if (device.source === 'ble') {
        bleMac = device.address ?? '';
      }
      if (bleMac.length === 0 && browser !== undefined) {
        bleMac = browser.bleAddressFor(device.fingerprint);
      }
      // BLE 引导的两种情况：① 决定升级；② 完全没发现到局域网端点（此时也允许 BLE 兜底，不升级）。
      const useBleBootstrap: boolean = bleMac.length > 0 && (upgradeWanted || peerIp.length === 0);
      if (useBleBootstrap) {
        Lg.i('[QUICKSHARE] send via=ble mac=' + bleMac + ' peer=' + device.name
          + ' (bootstrap, upgrade=' + upgradeWanted + ')');
        const bleClient: NearbyBleSocketClient = new NearbyBleSocketClient();
        const conn: GsStreamConnection = await bleClient.connect(bleMac);
        try {
          await facade.sendStream(conn, outgoing, hooks);
        } finally {
          conn.close();
        }
      } else {
        // 记录实际拨号的目标与源地址：历史故障里「目标地址已失效」是 SYN 无应答的头号原因，
        // 而这条信息以前只存在于 hilog（gs 模块用 console），applog 里查不到。
        Lg.i('[QUICKSHARE] send via=tcp target=' + device.address + ':' + device.port
          + ' source=' + (localIp.length > 0 ? localIp : '0.0.0.0') + ' peer=' + device.name
          + ' sourceKind=' + device.source);
        await facade.send(device, outgoing, hooks);
      }
    } catch (error) {
      Lg.e('[QUICKSHARE] send failed target=' + device.address + ':' + device.port
        + ' peer=' + device.name + ': ' + (error as Error).message);
      this.services?.transfer.finishTask(task?.id ?? '', false, (error as Error).message);
      throw (error as Error);
    } finally { DynamicPhotoService.cleanupOutgoing(original, outgoing); }
    this.services?.transfer.finishTask(task?.id ?? '', true);
    const ctxDone = getContext(this) as common.UIAbilityContext;
    for (const f of outgoing) {
      QuickShareTransferHistory.add(ctxDone, { id: 'snd-' + Date.now() + '-' + f.name, name: f.name, size: f.size, direction: 'send', peer: device.name, completedAt: Date.now(), savedPath: '' }).catch((): void => undefined);
    }

    promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: 'Quick Share 传输已完成' });
  }

  private confirmQuickSharePin(pin: string): Promise<boolean> {
    return promptAction.showDialog({
      systemMaterial: dialogSystemMaterial(),
      title: 'Quick Share 发送确认',
      message: `正在发送给对端设备。请确认双方设备显示的 PIN 均为 ${pin}，确认后开始传输。`,
      buttons: [
        { text: '取消', color: HwColor.textSecondary },
        { text: '确认', color: HwColor.primary }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): boolean => result.index === 1).catch((): boolean => false);
  }

  private async sendWindows(device: DeviceEndpoint, original: OutgoingFile[]): Promise<void> {
    const sender = this.hub?.windowsSender;
    if (sender === undefined) {
      throw new Error('Windows Nearby 发送器尚未就绪');
    }
    if (device.address.length === 0) {
      throw new Error('等待 UDP 发现获取 Windows IP');
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    // 动态图片传输(Beta)：按对端品牌封装（Windows 对端固定走「图片 + 视频」拆分）。
    const outgoing: OutgoingFile[] = await DynamicPhotoService.prepareOutgoing(ctx, original,
      DynamicPhotoService.resolveFormatFor(device));
    const files: WindowsNearbyOutgoingFile[] = outgoing.map((file: OutgoingFile): WindowsNearbyOutgoingFile => ({
      path: file.path,
      name: file.name,
      size: file.size
    }));
    const task = this.services?.transfer.manualTask(device, outgoing, 'send', 'windowsnearby');
    try {
      await sender.send(device.address, device.port > 0 ? device.port : 5040, files);
    } catch (error) {
      this.services?.transfer.finishTask(task?.id ?? '', false, (error as Error).message);
      throw (error as Error);
    } finally { DynamicPhotoService.cleanupOutgoing(original, outgoing); }
    this.services?.transfer.finishTask(task?.id ?? '', true);

    promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: 'Windows Nearby 发送已完成' });
  }

  private async sendLocalSend(device: DeviceEndpoint, original: OutgoingFile[]): Promise<void> {
    if (this.services === undefined) {
      throw new Error('传输服务尚未就绪');
    }
    const task: TransferTask = await this.services.transfer.send(device, original);
    if (task.state !== 'completed') {
      throw new Error(task.error.length > 0 ? task.error : '发送未完成');
    }
    promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: 'LocalSend 传输已完成' });
  }

  private pickFiles(): void {
    this.pickFilesNow().catch((error: BusinessError): void => promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '选择文件失败：' + error.message }));
  }

  private pickFilesNow(): Promise<OutgoingFile[]> {
    const context = getContext(this) as common.UIAbilityContext;
    // 复用单例 DocumentViewPicker + 异步 fs.stat：不重复构造系统选择器、不阻塞主线程。
    const version = ++this.selectionVersion;
    return FilePickerHelper.pick(context).then((files: OutgoingFile[]): OutgoingFile[] => {
      if (version !== this.selectionVersion) { return []; }
      this.replaceSelection(files);
      return files;
    });
  }

  private loadShareParams(): void {
    const files = sharedFilesFromParams();
    if (files.length > 0) {
      this.replaceSelection(files);
    }
  }
}
