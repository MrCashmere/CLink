import { LogCapture as Lg } from '../common/LogCapture';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
import { DeviceEndpoint, OutgoingFile, TransferEvent, TransferTask } from '../model/TransferModels';
import { FilePickerHelper } from '../common/FilePickerHelper';
import { IconCircleButton } from '../components/IconCircleButton';
import { DeviceList } from './DeviceList';
import { HwColor, HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwPrimary, hwGlassSurface, hwGlassBorder } from '../utils/DesignTokens';
import { isApi26OrAbove, immersiveMaterialModifier, legacyMaterialModifier } from '../utils/SystemMaterial';
import { AppServices } from '../common/AppServices';
import { NearbyScanHub } from '../common/NearbyScanHub';
import { SettingsStore } from '../common/SettingsStore';
import { sharedFilesFromParams } from '../common/ShareHandleUtil';
import { GsSendHooks, GsStreamConnection } from '../protocol/gs/GsFacade';
import { NearbyBleSocketClient } from '../quickshare/ble/NearbyBleSocketClient';
import { NearbyP2pDirect } from '../quickshare/ble/NearbyP2pDirect';
import { QuickShareTransferHistory } from '../quickshare/storage/TransferHistory';
import { WindowsNearbyOutgoingFile } from '../windowsnearby/WindowsNearbySender';

const TITLE_BAR_HEIGHT_FREE: number = 138; // 与 HdsNavigation FREE 模式标题栏高度一致

/** 传输卡片保留窗口：任务完成后仍在该窗口内展示（含快速完成的 LocalSend 发送），超过后从实时卡片移除。 */
const COMPLETED_CARD_KEEP_MS: number = 6000;
/** 聚合页定期刷新实时卡片，剔除已超出保留窗口的完成任务。 */
const SYNC_INTERVAL_MS: number = 1000;

@Component
export struct AggregatePage {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('immersiveLightEnabled') immersiveLightEnabled: boolean = true;
  @StorageLink('fontMode') fontMode: string = 'system';
  @StorageLink('fontFamilyEn') fontFamilyEn: string = 'system';
  @StorageLink('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageLink('fontWeightMode') fontWeightMode: string = 'system';
  @StorageLink('fontWeightValue') fontWeightValue: number = 400;
  /** 「隐藏传输页」开启时，把「局域网网页传输」入口展示在聚合页扫描状态上方。 */
  @Prop showWebEntry: boolean = false;

  @State quickShareDevices: DeviceEndpoint[] = [];
  @State windowsDevices: DeviceEndpoint[] = [];
  @State localSendDevices: DeviceEndpoint[] = [];
  @State selectedFiles: OutgoingFile[] = [];
  /** 聚合页实时进度：三种协议（LocalSend / Quick Share / Windows Nearby）进行中的传输。
   *  用三个独立 @State 数组直接驱动三张卡片，避免 `@Builder` 参数数组的 Reactivity 跟踪问题。 */
  @State localSendLive: TransferTask[] = [];
  @State quickShareLive: TransferTask[] = [];
  @State windowsLive: TransferTask[] = [];

  private services?: AppServices;
  private hub?: NearbyScanHub;
  private syncTimer: number = -1;
  private readonly onScanChanged: () => void = (): void => {
    this.syncFromHub();
  };
  private readonly onTransferChanged: (event: TransferEvent) => void = (event: TransferEvent): void => {
    this.syncTransfers();
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
    this.syncTransfers();
    // 周期性刷新实时卡片：剔除已超出「完成后保留窗口」的完成任务，避免卡片滞留。
    this.startSyncTimer();
  }

  aboutToDisappear(): void {
    // 仅退订本页对扫描结果的监听；全局扫描不随本页消失而停止。
    this.hub?.removeOnChange(this.onScanChanged);
    this.services?.transfer.removeListener(this.onTransferChanged);
    this.stopSyncTimer();
    this.selectedFiles = [];
  }

  private startSyncTimer(): void {
    this.stopSyncTimer();
    this.syncTimer = setInterval((): void => {
      this.syncTransfers();
    }, SYNC_INTERVAL_MS);
  }

  private stopSyncTimer(): void {
    if (this.syncTimer !== -1) {
      clearInterval(this.syncTimer);
      this.syncTimer = -1;
    }
  }

  private syncFromHub(): void {
    if (this.hub === undefined) {
      return;
    }
    // getXxx 返回新数组引用。为避免每次扫描回调都触发整段设备卡片重排版、占用主线程
    // （点击设备卡片时主线程越空闲，点击响应越快），仅在列表有实质变化时才重新赋值 @State。
    const quick = this.hub.getQuickShareDevices();
    const windows = this.hub.getWindowsDevices();
    const local = this.hub.getLocalSendDevices();
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
      a.port === b.port && a.protocol === b.protocol && a.source === b.source &&
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
    return all;
  }

  private totalDiscovered(): number {
    return this.quickShareDevices.length + this.windowsDevices.length + this.localSendDevices.length;
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

  build() {
    Column({ space: 12 }) {
      Blank().height(TITLE_BAR_HEIGHT_FREE + this.statusBarHeight)
      // 三种协议各自的传输进程卡片（标题不含“进度”）。各卡 @Builder 直接读 @State 数组，
      // 保证 ArkUI 依赖跟踪到数组变化 → 卡片增删/状态切换都能重画。
      this.localSendCard()
      this.quickShareCard()
      this.windowsCard()
      if (this.showWebEntry) {
        this.webEntryCard()
      }
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
            promptAction.showToast({ message: error.message });
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
          .fontColor(task.direction === 'send' ? hwPrimary(this.isDarkMode) : hwTextSecondary(this.isDarkMode))
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
        .fontColor(hwPrimary(this.isDarkMode))
        .width('100%')
    }
    .width('100%')
  }

  @Builder
  localSendCard() {
    if (this.localSendLive.length > 0) {
      Column({ space: 8 }) {
        Text('LocalSend')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.appFontFamily('LocalSend'))
          .fontColor(hwTextPrimary(this.isDarkMode))
          .width('100%')
        ForEach(this.localSendLive, (task: TransferTask): void => {
          this.transferRow(task);
        }, (task: TransferTask): string => task.id + ':' + task.state)
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.card)
      .backgroundColor(hwGlassSurface(this.isDarkMode))
      .attributeModifier(this.immersiveLightEnabled && isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
      .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
      .clip(true)
    }
  }

  @Builder
  quickShareCard() {
    if (this.quickShareLive.length > 0) {
      Column({ space: 8 }) {
        Text('Quick Share')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.appFontFamily('Quick Share'))
          .fontColor(hwTextPrimary(this.isDarkMode))
          .width('100%')
        ForEach(this.quickShareLive, (task: TransferTask): void => {
          this.transferRow(task);
        }, (task: TransferTask): string => task.id + ':' + task.state)
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.card)
      .backgroundColor(hwGlassSurface(this.isDarkMode))
      .attributeModifier(this.immersiveLightEnabled && isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
      .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
      .clip(true)
    }
  }

  @Builder
  windowsCard() {
    if (this.windowsLive.length > 0) {
      Column({ space: 8 }) {
        Text('Windows Nearby')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.appFontFamily('Windows Nearby'))
          .fontColor(hwTextPrimary(this.isDarkMode))
          .width('100%')
        ForEach(this.windowsLive, (task: TransferTask): void => {
          this.transferRow(task);
        }, (task: TransferTask): string => task.id + ':' + task.state)
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.card)
      .backgroundColor(hwGlassSurface(this.isDarkMode))
      .attributeModifier(this.immersiveLightEnabled && isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
      .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
      .clip(true)
    }
  }

  @Builder
  webEntryCard() {
    Row({ space: 12 }) {
      IconCircleButton({ symbol: $r('sys.symbol.wifi'), buttonSize: 36, iconSize: 18 })
      Column({ space: 2 }) {
        Text('局域网网页传输')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.appFontFamily('局域网网页传输'))
          .fontColor(hwTextPrimary(this.isDarkMode))
        Text('生成链接，对端在浏览器发送、接收文件')
          .fontSize(12)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('生成链接，对端在浏览器发送、接收文件'))
          .fontWeight(this.appFontWeight())
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([hwTextSecondary(this.isDarkMode)])
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.control)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(this.immersiveLightEnabled && isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
    .onClick(() => {
      router.pushUrl({ url: 'pages/LanWebTransfer' }).catch((error: BusinessError): void => {
        Lg.w('LanWebTransfer route failed: ' + error.message);
      });
    })
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
    Row({ space: 8 }) {
      Text('扫描状态').fontSize(16).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('扫描状态')).fontColor(hwTextPrimary(this.isDarkMode)).layoutWeight(1)
      Text('已发现 ' + this.totalDiscovered() + ' 台设备').fontSize(13).fontFamily(this.appFontFamily('已发现 台设备')).fontWeight(this.appFontWeight()).fontColor(hwPrimary(this.isDarkMode))
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(this.immersiveLightEnabled && isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  selectFileCard() {
    Row({ space: 12 }) {
      Text('选择文件').fontSize(16).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('选择文件')).fontColor(hwPrimary(this.isDarkMode)).layoutWeight(1)
      Text(this.selectedFiles.length > 0 ? '已选择 ' + this.selectedFiles.length + ' 个文件' : '从系统中选择要发送的文件')
        .fontSize(12).fontFamily(this.appFontFamily('从系统中选择要发送的文件')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([hwTextSecondary(this.isDarkMode)])
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(this.immersiveLightEnabled && isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
    .onClick(() => this.pickFiles())
  }

  private async sendOrPick(device: DeviceEndpoint): Promise<void> {
    if (this.selectedFiles.length === 0) {
      let files: OutgoingFile[] = [];
      try {
        files = await this.pickFilesNow();
      } catch (error) {
        // 选择器抛错不静默吞掉：给用户明确反馈，避免"点了没反应"。
        promptAction.showToast({ message: '选择文件失败：' + ((error as BusinessError).message ?? JSON.stringify(error)) });
        return;
      }
      if (files.length === 0) {
        return; // 用户取消了选择
      }
    }
    await this.send(device);
  }

  private async send(device: DeviceEndpoint): Promise<void> {
    if (this.selectedFiles.length === 0) {
      throw new Error('请先选择文件');
    }
    if (device.protocol === 'quickshare') {
      await this.sendQuickShare(device);
    } else if (device.protocol === 'windowsnearby') {
      await this.sendWindows(device);
    } else if (device.protocol === 'localsend') {
      await this.sendLocalSend(device);
    } else {
      throw new Error('不支持的协议');
    }
  }

  private async sendQuickShare(device: DeviceEndpoint): Promise<void> {
    const facade = this.hub?.facade;
    const browser = this.hub?.browser;
    const localIp = this.hub?.localIp ?? '';
    if (facade === undefined) {
      throw new Error('Quick Share 会话尚未就绪');
    }
    const task = this.services?.transfer.manualTask(device, this.selectedFiles, 'send', 'quickshare');
    const hooks: GsSendHooks = {
      onPin: (pin: string): Promise<boolean> => this.confirmQuickSharePin(pin),
      onProgress: (percent: number): void => {
        if (task !== undefined) {
          this.services?.transfer.setTaskProgress(task.id, percent);
        }
      },
      localEndpointId: browser?.localEndpointIdValue(),
      sourceAddress: localIp.length > 0 ? localIp : undefined,
      forceWifiDirect: SettingsStore.current().quickshareWlanDirect,
      pcPeer: device.deviceType === 3,
      onWifiDirectTransport: (creds): Promise<GsStreamConnection | undefined> => {
        return new NearbyP2pDirect().connectAsClient(creds);
      }
    };
    let bleMac: string = '';
    if (device.source === 'ble') {
      bleMac = device.address ?? '';
    }
    if (bleMac.length === 0 && browser !== undefined) {
      bleMac = browser.bleAddressFor(device.fingerprint);
    }
    if (bleMac.length === 0) {
      bleMac = this.services?.lastPeerBleMacValue() ?? '';
    }
    try {
      if (bleMac.length > 0) {
        const bleClient: NearbyBleSocketClient = new NearbyBleSocketClient();
        const conn: GsStreamConnection = await bleClient.connect(bleMac);
        try {
          await facade.sendStream(conn, this.selectedFiles, hooks);
        } finally {
          conn.close();
        }
      } else {
        await facade.send(device, this.selectedFiles, hooks);
      }
    } catch (error) {
      this.services?.transfer.finishTask(task?.id ?? '', false, (error as Error).message);
      throw (error as Error);
    }
    this.services?.transfer.finishTask(task?.id ?? '', true);
    const ctx = getContext(this) as common.UIAbilityContext;
    for (const f of this.selectedFiles) {
      QuickShareTransferHistory.add(ctx, { id: 'snd-' + Date.now() + '-' + f.name, name: f.name, size: f.size, direction: 'send', peer: device.name, completedAt: Date.now(), savedPath: '' }).catch((): void => undefined);
    }
    this.selectedFiles = [];
    promptAction.showToast({ message: 'Quick Share 传输已完成' });
  }

  private confirmQuickSharePin(pin: string): Promise<boolean> {
    return promptAction.showDialog({
      title: 'Quick Share 发送确认',
      message: `正在发送给对端设备。请确认双方设备显示的 PIN 均为 ${pin}，确认后开始传输。`,
      buttons: [
        { text: '取消', color: HwColor.textSecondary },
        { text: '确认', color: HwColor.primary }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): boolean => result.index === 1).catch((): boolean => false);
  }

  private async sendWindows(device: DeviceEndpoint): Promise<void> {
    const sender = this.hub?.windowsSender;
    if (sender === undefined) {
      throw new Error('Windows Nearby 发送器尚未就绪');
    }
    if (device.address.length === 0) {
      throw new Error('等待 UDP 发现获取 Windows IP');
    }
    const task = this.services?.transfer.manualTask(device, this.selectedFiles, 'send', 'windowsnearby');
    const files: WindowsNearbyOutgoingFile[] = this.selectedFiles.map((file: OutgoingFile): WindowsNearbyOutgoingFile => ({
      path: file.path,
      name: file.name,
      size: file.size
    }));
    try {
      await sender.send(device.address, device.port > 0 ? device.port : 5040, files);
    } catch (error) {
      this.services?.transfer.finishTask(task?.id ?? '', false, (error as Error).message);
      throw (error as Error);
    }
    this.services?.transfer.finishTask(task?.id ?? '', true);
    this.selectedFiles = [];
    promptAction.showToast({ message: 'Windows Nearby 发送已完成' });
  }

  private async sendLocalSend(device: DeviceEndpoint): Promise<void> {
    if (this.services === undefined) {
      throw new Error('传输服务尚未就绪');
    }
    await this.services.transfer.send(device, this.selectedFiles);
    this.selectedFiles = [];
    promptAction.showToast({ message: 'LocalSend 传输已完成' });
  }

  private pickFiles(): void {
    this.pickFilesNow().catch((error: BusinessError): void => promptAction.showToast({ message: '选择文件失败：' + error.message }));
  }

  private pickFilesNow(): Promise<OutgoingFile[]> {
    const context = getContext(this) as common.UIAbilityContext;
    // 复用单例 DocumentViewPicker + 异步 fs.stat：不重复构造系统选择器、不阻塞主线程。
    return FilePickerHelper.pick(context).then((files: OutgoingFile[]): OutgoingFile[] => {
      this.selectedFiles = files;
      return files;
    });
  }

  private loadShareParams(): void {
    const files = sharedFilesFromParams();
    if (files.length > 0) {
      this.selectedFiles = files;
    }
  }
}