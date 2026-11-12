import { LogCapture as Lg } from '../common/LogCapture';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
import pasteboard from '@ohos.pasteboard';
import { fileUri } from '@kit.CoreFileKit';
import { AppServices, LocalsendSelfEndpoint } from '../common/AppServices';
import { FilePickerHelper } from '../common/FilePickerHelper';
import { DeviceEndpoint, IncomingFile, OutgoingFile, TransferEvent, TransferTask } from '../model/TransferModels';
import { DeviceList } from '../view/DeviceList';
import { IconCircleButton } from '../components/IconCircleButton';
import { AppBackground } from '../components/AppBackground';
import { HwColor, HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwPrimary, hwPrimaryButton, hwSurface, hwGlassBorder, reloadAppTheme, resolvePageBackground, onAccentColor, topBarGlassColor, resolvePrimaryColor, resolvePrimaryButtonColor } from '../utils/DesignTokens';
import { cardGlassEffect, toastSystemMaterial, dialogSystemMaterial, cardGlassBorderColor, cardGlassShadow } from '../utils/SystemMaterial';
import { PinDialogGuard } from '../common/PinDialogGuard';
import { SettingsStore } from '../common/SettingsStore';
import { sharedFilesFromParams } from '../common/ShareHandleUtil';
import { CardSurface } from '../components/CardSurface';
import { AccentColorSentinel } from '../components/MaterialCard';

@Entry
@Component
struct LocalSendPage {
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
  @State devices: DeviceEndpoint[] = [];
  @State selectedFiles: OutgoingFile[] = [];
  @State receivedFiles: IncomingFile[] = [];
  @State statusText: string = '正在扫描 LocalSend 设备';
  @State lastPeerName: string = '';
  @State pinEntryTaskId: string = '';
  @State pinEntryValue: string = '';
  /** 本机作为 LocalSend 接收端的 `IP:端口`，供电脑端手动直连。 */
  @State selfEndpointText: string = '';
  /** 手动发送：对端 IP（可写成 `IP:端口`）。 */
  @State manualIp: string = '';
  /** 手动发送时是否按加密(HTTPS)对端处理，需与对端设置一致。 */
  @State manualHttps: boolean = true;
  private services?: AppServices;
  /** 刷新状态文案的定时器（发现链路提示是异步出现的，列表为空时也要能看到原因）。 */
  private statusTimer: number = -1;
  private readonly deviceListener: (device: DeviceEndpoint) => void = (device: DeviceEndpoint): void => {
    if (device.protocol !== 'localsend') {
      return;
    }
    // 保持卡片顺序稳定：已存在的设备原地更新（不挪位置），新设备才追加到末尾。
    const index = this.devices.findIndex((item: DeviceEndpoint): boolean => item.id === device.id);
    if (index >= 0) {
      // 设备信息无实质变化时不再重建数组，避免每次扫描回调都触发整段设备卡片重排版。
      if (!this.deviceEquals(this.devices[index], device)) {
        this.devices = this.devices.map((item: DeviceEndpoint, i: number): DeviceEndpoint => i === index ? device : item);
      }
    } else {
      this.devices = this.devices.concat([device]);
    }
    this.statusText = this.discoveredText();
  };

  /**
   * 状态文案：设备数 + 发现链路的健康提示。
   *
   * 为什么要带提示：多播接收不可用（53317 被上一轮没关掉的残留 socket 占着）时，页面只会一直
   * 「正在扫描…」，用户完全不知道原因；这条提示直接告诉他要重启手机。
   */
  private discoveredText(): string {
    const hint = this.services?.localsend.statusHint() ?? '';
    const base = this.devices.length > 0 ? '已发现 ' + this.devices.length + ' 台 LocalSend 设备' : '正在扫描 LocalSend 设备';
    return hint.length > 0 ? base + '（' + hint + '）' : base;
  }

  private deviceEquals(a: DeviceEndpoint, b: DeviceEndpoint): boolean {
    return a.id === b.id && a.name === b.name && a.address === b.address &&
      a.port === b.port && a.https === b.https && a.model === b.model && a.protocol === b.protocol && a.source === b.source &&
      a.fingerprint === b.fingerprint;
  }

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
  private readonly transferListener: (event: TransferEvent) => void = (event: TransferEvent): void => {
    this.onTransferEvent(event);
    // 可能在本页未打开时（如主页）接收了文件：仅靠实时事件会漏掉，统一从
    // TransferManager 保留的 receive 任务里聚合（去重），保证页面总能显示已接收列表与数量。
    if (event.kind === 'incoming' || event.kind === 'completed') {
      this.lastPeerName = event.task.device.name;
      this.syncReceivedFiles();
    }
  };

  /** 热点地址一探到就改写「本机接收地址」，不等 3 秒一轮的状态刷新。 */
  private readonly hotspotAddressListener: (address: string) => void = (address: string): void => {
    this.refreshSelfEndpoint();
  };

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    // 预热系统文件选择器实例，让首次点击设备卡片不再耗费在构造选择器上，降低点击响应时延。
    FilePickerHelper.warmUp(context);
    this.services = AppServices.get(context);
    this.services.localsend.addListener(this.deviceListener);
    this.services.transfer.addListener(this.transferListener);
    this.services.onHotspotAddressChange(this.hotspotAddressListener);
    // 进入页面即回填历史接收（含在本页未打开时已完成接收的文件），避免列表/计数为空。
    this.syncReceivedFiles();
    this.loadShareParams();
    this.showHttpsNotice();
    // 先取一次地址：开热点时即时答案（192.168.43.1）此刻就有，不必等服务端拉起。
    this.refreshSelfEndpoint();
    // 等待首页的接收/服务端启动完成，确保 UDP/mDNS 使用真实端口后再扫描，
    // 避免 LocalSend 页抢在 startReceive 完成前开始扫描。
    this.services.startReceive().then((): void => {
      this.services?.startLocalSendScanning();
      // 服务端起来后才拿得到真实监听端口，此时再刷新「本机接收地址」。
      this.refreshSelfEndpoint();
      if (this.statusText.indexOf('已发现') < 0 && this.statusText.indexOf('已接收') < 0) {
        this.statusText = this.discoveredText();
      }
      // 发现链路的自检结果（多播是否可用）是异步出来的，列表为空时也要把原因显示出来。
      if (this.statusTimer === -1) {
        this.statusTimer = setInterval((): void => {
          // 网络切换（例如开热点）后本机地址会变，跟着刷新。
          this.refreshSelfEndpoint();
          if (this.devices.length === 0) {
            this.statusText = this.discoveredText();
          }
        }, 3000);
      }
    }).catch((error: BusinessError): void => {
      this.statusText = '启动失败: ' + error.message;
    });
  }

  private showHttpsNotice(): void {
    const context = getContext(this) as common.UIAbilityContext;
    SettingsStore.load(context).then((settings) => {
      if (settings.localSendNoticeShown) {
        return;
      }
      settings.localSendNoticeShown = true;
      SettingsStore.save(context, settings).catch((): void => undefined);
      this.promptHttpsNotice();
    }).catch((): void => undefined);
  }

  private promptHttpsNotice(): void {
    promptAction.showDialog({
      systemMaterial: dialogSystemMaterial(),
      title: 'LocalSend 传输说明',
      message: '发送到启用加密(HTTPS)的 LocalSend 对端已支持；本机接收暂用明文，接收加密将在后续支持。',
      buttons: [
        { text: '知道了', color: HwColor.primary }
      ]
    }).catch((): void => undefined);
  }

  onPageHide(): void {
    this.stopLocalSendScan();
  }

  aboutToDisappear(): void {
    this.cancelPinEntry();
    this.stopLocalSendScan();
    // 退出页面不保存本次接收记录（仅本页 @State，主页记录由 TransferManager 保留）。
    this.receivedFiles = [];
    this.services?.localsend.removeListener(this.deviceListener);
    this.services?.transfer.removeListener(this.transferListener);
    this.services?.offHotspotAddressChange(this.hotspotAddressListener);
  }

  private stopLocalSendScan(): void {
    if (this.statusTimer !== -1) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
    this.services?.stopLocalSendScanning();
  }

  /** 从 TransferManager 保留的 receive 任务中聚合已接收文件（去重），回填本页列表与计数。 */
  private syncReceivedFiles(): void {
    if (this.services === undefined) {
      return;
    }
    const seen = new Set<string>();
    const all: IncomingFile[] = [];
    const tasks = this.services.transfer.listTasks();
    for (let i = 0; i < tasks.length; i++) {
      const task = tasks[i];
      if (task.direction !== 'receive') {
        continue;
      }
      const files = task.receivedFiles;
      for (let j = 0; j < files.length; j++) {
        const file = files[j];
        const key = file.savedPath + ':' + file.name;
        if (!seen.has(key)) {
          seen.add(key);
          all.push(file);
        }
      }
    }
    if (all.length > 0) {
      this.receivedFiles = all.slice();
      this.statusText = '已接收：' + all.map((file: IncomingFile): string => file.name).join('、');
    }
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
    Stack({ alignContent: Alignment.TopStart }) {
      // 主题色依赖：切色时让整页重新求值（零尺寸，不参与布局）
      AccentColorSentinel()
      AppBackground()
      Column() {
        Scroll() {
          Column({ space: 12 }) {
            Blank().height(56 + this.statusBarHeight)
            this.statusCard()
            this.selfEndpointCard()
            this.selectFileCard()
            if (this.pinEntryTaskId.length > 0) {
              this.pinEntryCard()
            }
            if (this.selectedFiles.length > 0) {
              Text('已选择 ' + this.selectedFiles.length + ' 个文件，点击下方设备即可发送')
                .fontSize(12).fontFamily(this.appFontFamily('已选择 个文件，点击下方设备即可发送')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).width('100%').padding({ left: 4, right: 4, bottom: 8 })
            }
            Text('附近设备').fontSize(14).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('附近设备')).fontColor(hwTextPrimary(this.isDarkMode)).width('100%').padding({ left: 4 })
            this.manualSendCard()
            DeviceList({
              devices: this.devices,
              onSelect: (device: DeviceEndpoint): void => {
                this.sendOrPick(device).catch((error: Error): void => promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: error.message }));
              }
            })
            if (this.devices.length === 0) {
              Text('请打开对端 LocalSend，并保持双方在同一网络').fontSize(14).fontFamily(this.appFontFamily('请打开对端 LocalSend，并保持双方在同一网络')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
                .width('100%').textAlign(TextAlign.Center).padding({ top: 24 });
            }
            if (this.receivedFiles.length > 0) {
              this.receivedFilesCard()
            }
          }
          .width('100%')
          .padding({ left: HwSpace.lg, right: HwSpace.lg, top: HwSpace.lg, bottom: 96 })
        }
        .width('100%')
        .height('100%')
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)

      Row() {
        IconCircleButton({ symbol: $r('sys.symbol.chevron_left'), glass: true, buttonSize: 40, iconSize: 20, onAction: (): void => router.back() })
        Text('LocalSend').fontSize(20).fontWeight(FontWeight.Bold).fontFamily(this.appFontFamily('LocalSend')).fontColor(hwTextPrimary(this.isDarkMode)).margin({ left: HwSpace.md })
        Blank()
      }
      .width('100%')
      .height(56 + this.statusBarHeight)
      .padding({ left: 16, right: 16, top: this.statusBarHeight })
      .backgroundEffect({ radius: 12, color: topBarGlassColor(this.isDarkMode) })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(resolvePageBackground(this.isDarkMode, this.pageBackground))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  statusCard() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 4 }) {
        Text('状态').fontSize(12).fontFamily(this.appFontFamily('状态')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
        Text(this.statusText).fontSize(14).fontFamily(this.appFontFamily(this.statusText)).fontWeight(this.appFontWeight()).fontColor(hwTextPrimary(this.isDarkMode))
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

  /**
   * 本机作为 LocalSend 接收端的地址卡片。
   *
   * 为什么要有它：热点、跨网段、组播被系统拦掉时，mDNS/组播发现全都失效，设备列表会一直空着。
   * 但本机 53317 一直在 0.0.0.0 监听且对端可达 —— 把 `IP:端口` 直接亮出来，
   * 电脑端 LocalSend 用「手动发送 / 收藏设备」就能绕过全部发现机制直连过来。
   */
  @Builder
  selfEndpointCard() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 8 }) {
        Text('本机接收地址')
          .fontSize(12)
          .fontFamily(this.appFontFamily('本机接收地址'))
          .fontWeight(this.appFontWeight())
          .fontColor(hwTextSecondary(this.isDarkMode))
          .width('100%')
        Row({ space: 10 }) {
          Text(this.selfEndpointText.length > 0 ? this.selfEndpointText : '未获取到地址')
            .layoutWeight(1)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily(this.selfEndpointText.length > 0 ? this.selfEndpointText : '未获取到地址'))
            .fontColor(hwTextPrimary(this.isDarkMode))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Button('复制', { type: ButtonType.Capsule })
            .height(32)
            .fontSize(13)
            .fontFamily(this.appFontFamily('复制'))
            .backgroundColor(resolvePrimaryButtonColor(this.isDarkMode, this.accentOrPrimary()))
            .fontColor(onAccentColor(this.accentOrPrimary()))
            .onClick(() => this.copySelfEndpoint())
        }.width('100%')
        Text('电脑端 LocalSend 用「手动发送 / 收藏设备」直连这个地址；扫不到设备时用它。')
          .fontSize(11)
          .fontFamily(this.appFontFamily('电脑端 LocalSend 用「手动发送 / 收藏设备」直连这个地址；扫不到设备时用它。'))
          .fontWeight(this.appFontWeight())
          .fontColor(hwTextSecondary(this.isDarkMode))
          .width('100%')
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

  /** 手动指定对端 IP 发送（手机 → 电脑方向的兜底入口）。 */
  @Builder
  manualSendCard() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          TextInput({ placeholder: '对端 IP（如 192.168.43.17）', text: this.manualIp })
            .caretColor(this.accentOrPrimary())
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .fontColor(hwTextPrimary(this.isDarkMode))
            .backgroundColor(hwSurface(this.isDarkMode))
            .borderRadius(HwRadius.control)
            .onChange((value: string): void => {
              this.manualIp = value;
            })
          Button(this.manualHttps ? 'HTTPS' : 'HTTP')
            .height(40)
            .fontSize(12)
            .fontFamily(this.appFontFamily('HTTPS'))
            .backgroundColor(hwSurface(this.isDarkMode))
            .fontColor(hwTextSecondary(this.isDarkMode))
            .onClick((): void => {
              this.manualHttps = !this.manualHttps;
            })
        }.width('100%')
        Button('发送到该地址', { type: ButtonType.Capsule })
          .width('100%')
          .height(40)
          .fontSize(14)
          .fontFamily(this.appFontFamily('发送到该地址'))
          .backgroundColor(resolvePrimaryButtonColor(this.isDarkMode, this.accentOrPrimary()))
          .fontColor(onAccentColor(this.accentOrPrimary()))
          .onClick((): void => this.connectManualIp())
        Text('手动指定对端 IP 可跳过发现，用于热点、跨网段等扫不到设备的场景；端口默认 53317，也可写成 IP:端口。右侧按钮切换明文/加密，需与对端一致。')
          .fontSize(11)
          .fontFamily(this.appFontFamily('手动指定对端 IP 可跳过发现，用于热点、跨网段等扫不到设备的场景；端口默认 53317，也可写成 IP:端口。右侧按钮切换明文/加密，需与对端一致。'))
          .fontWeight(this.appFontWeight())
          .fontColor(hwTextSecondary(this.isDarkMode))
          .width('100%')
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

  /** 刷新本机接收地址：服务端启动完成、网络切换（开热点）后地址都会变。 */
  private refreshSelfEndpoint(): void {
    const endpoint: LocalsendSelfEndpoint | undefined = this.services?.localsendSelfEndpoint();
    if (endpoint === undefined || endpoint.address.length === 0 || endpoint.port <= 0) {
      this.selfEndpointText = '';
      return;
    }
    this.selfEndpointText = endpoint.address + ':' + endpoint.port;
  }

  private copySelfEndpoint(): void {
    if (this.selfEndpointText.length === 0) {
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '尚未获取到本机地址，请检查网络', duration: 2000 });
      return;
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.selfEndpointText);
      pasteboard.getSystemPasteboard().setData(data).then((): void => {
        promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '地址已复制', duration: 1500 });
      }).catch((error: BusinessError): void => {
        promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '复制失败：' + error.message, duration: 2000 });
      });
    } catch (error) {
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '复制失败，请重试', duration: 2000 });
    }
  }

  /** 手动指定对端 IP（可带端口）直接发送；校验口径与 NearSharing.connectManualIp 一致。 */
  private connectManualIp(): void {
    const raw: string = this.manualIp.trim();
    let host: string = raw;
    let port: number = 53317;
    const colon: number = raw.lastIndexOf(':');
    if (colon > 0) {
      host = raw.substring(0, colon);
      const parsed: number = Number(raw.substring(colon + 1));
      if (Number.isInteger(parsed) && parsed > 0 && parsed < 65536) {
        port = parsed;
      }
    }
    if (!this.isValidIpv4(host)) {
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '请输入合法的 IPv4 地址' });
      return;
    }
    const device: DeviceEndpoint = {
      id: 'localsend-manual-' + host + ':' + port,
      name: '手动指定（' + host + '）',
      model: 'LocalSend',
      protocol: 'localsend',
      address: host,
      port: port,
      https: this.manualHttps,
      fingerprint: host,
      source: 'manual'
    };
    this.sendOrPick(device).catch((error: Error): void => {
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: error.message });
    });
  }

  private isValidIpv4(ip: string): boolean {
    const parts: string[] = ip.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (const part of parts) {
      if (part.length === 0 || part.length > 3) {
        return false;
      }
      const value: number = Number(part);
      if (!Number.isInteger(value) || value < 0 || value > 255) {
        return false;
      }
    }
    return true;
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

  @Builder
  pinEntryCard() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 8 }) {
        Text('对端要求 PIN')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.appFontFamily('对端要求 PIN'))
          .fontColor(hwTextPrimary(this.isDarkMode))
          .width('100%')
        Text('请输入对端设置的接收 PIN 继续发送（LocalSend 官方语义）。')
          .fontSize(12)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('请输入对端设置的接收 PIN 继续发送（LocalSend 官方语义）。'))
          .fontWeight(this.appFontWeight())
          .width('100%')
        TextInput({ text: this.pinEntryValue, placeholder: '对端接收 PIN' })
          .caretColor(this.accentOrPrimary())
          .width('100%')
          .height(44)
          .fontSize(15)
          .fontColor(hwTextPrimary(this.isDarkMode))
          .backgroundColor(hwSurface(this.isDarkMode))
          .borderRadius(HwRadius.control)
          .onChange((value: string) => {
            this.pinEntryValue = value;
          })
        Row({ space: 12 }) {
          Button('取消', { type: ButtonType.Capsule })
            .layoutWeight(1)
            // 中性底：次级按钮不跟主题色，也不能直接读模块级 HwColor
            .backgroundColor(hwSurface(this.isDarkMode))
            .fontColor(hwTextSecondary(this.isDarkMode))
            .onClick(() => this.cancelPinEntry())
          Button('确认发送', { type: ButtonType.Capsule })
            .layoutWeight(1)
            .backgroundColor(resolvePrimaryButtonColor(this.isDarkMode, this.accentOrPrimary()))
            .fontColor(onAccentColor(this.accentOrPrimary()))
            .onClick(() => this.confirmPinEntry())
        }
        .width('100%')
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

  private confirmPinEntry(): void {
    const taskId = this.pinEntryTaskId;
    const value = this.pinEntryValue;
    this.pinEntryTaskId = '';
    this.pinEntryValue = '';
    this.services?.transfer.submitPinEntry(taskId, value.trim().length > 0 ? value.trim() : null);
  }

  private cancelPinEntry(): void {
    const taskId = this.pinEntryTaskId;
    this.pinEntryTaskId = '';
    this.pinEntryValue = '';
    this.services?.transfer.submitPinEntry(taskId, null);
  }

  @Builder
  receivedFilesCard() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 6 }) {
        Text('已接收 ' + this.receivedFiles.length + ' 个文件').fontSize(14).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('已接收 个文件')).fontColor(hwTextPrimary(this.isDarkMode))
        ForEach(this.receivedFiles, (file: IncomingFile): void => {
          Column({ space: 4 }) {
            Row({ space: 8 }) {
              Text(file.name).layoutWeight(1).fontSize(13).fontFamily(this.appFontFamily(file.name)).fontWeight(this.appFontWeight()).fontColor(hwTextPrimary(this.isDarkMode))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.fileSizeText(file.size)).fontSize(12).fontFamily(this.appFontFamily(this.fileSizeText(file.size))).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
              Button('打开', { type: ButtonType.Capsule }).height(26).fontSize(12).fontFamily(this.appFontFamily('打开'))
                .backgroundColor(resolvePrimaryButtonColor(this.isDarkMode, this.accentOrPrimary())).fontColor(onAccentColor(this.accentOrPrimary()))
                .onClick(() => this.openFile(file))
            }.width('100%')
            Text(file.savedPath).fontSize(11).fontFamily(this.appFontFamily(file.savedPath)).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          }.width('100%')
        }, (file: IncomingFile): string => file.savedPath + ':' + file.name + ':' + this.accentColor)
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

  private pickFiles(): void {
    this.pickFilesNow().catch((error: BusinessError): void => promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '选择文件失败：' + error.message }));
  }

  private pickFilesNow(): Promise<OutgoingFile[]> {
    const context = getContext(this) as common.UIAbilityContext;
    // 复用单例 DocumentViewPicker + 异步 fs.stat：不重复构造系统选择器、不阻塞主线程。
    return FilePickerHelper.pick(context).then((files: OutgoingFile[]): OutgoingFile[] => {
      this.selectedFiles = files;
      return files;
    });
  }

  private async sendOrPick(device: DeviceEndpoint): Promise<void> {
    if (this.selectedFiles.length === 0) {
      // 未选择文件时点击设备卡片：先弹出文件选择，选定后自动发送给该设备。
      const files: OutgoingFile[] = await this.pickFilesNow().catch((): OutgoingFile[] => []);
      if (files.length === 0) {
        return; // 用户取消了选择
      }
    }
    await this.send(device);
  }

  // 从系统分享选择页跳转过来时，路由参数里携带共享文件，直接载入为已选择文件。
  private loadShareParams(): void {
    const files = sharedFilesFromParams();
    if (files.length > 0) {
      this.selectedFiles = files;
    }
  }

  private async send(device: DeviceEndpoint): Promise<void> {
    if (this.selectedFiles.length === 0) {
      throw new Error('请先选择文件');
    }
    if (this.services === undefined) {
      throw new Error('传输服务尚未就绪');
    }
    const task: TransferTask = await this.services.transfer.send(device, this.selectedFiles);
    if (task.state !== 'completed') {
      return;
    }
    this.selectedFiles = [];
    promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: 'LocalSend 传输已完成' });
  }

  private onTransferEvent(event: TransferEvent): void {
    if (event.kind === 'pin-request') {
      this.showPinDialog(event.task);
    }
    if (event.kind === 'pin-entry') {
      this.pinEntryTaskId = event.task.id;
      this.pinEntryValue = '';
    }
    if (event.kind === 'failed' && event.task.direction === 'send') {
      this.selectedFiles = event.task.files;
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '发送失败：' + event.task.error });
    }
    // 接收完成的「接收完成」弹窗统一由 MainPage 处理（含“打开”），这里不再重复弹
    // toast/dialog，避免同一 completed 事件在主页与 LocalSend 页各弹一次。
  }

  private showPinDialog(task: TransferTask): void {
    if (!PinDialogGuard.tryBegin()) {
      return;
    }
    promptAction.showDialog({
      systemMaterial: dialogSystemMaterial(),
      title: task.direction === 'receive' ? '接收请求' : 'LocalSend 发送确认',
      message: task.direction === 'receive'
        ? (task.pin.length > 0
          ? `收到来自「${task.device.name}」的传输请求，共 ${task.files.length} 个文件。\n双方 PIN：${task.pin}\n请核对对端 PIN 一致后确认接收。`
          : `收到来自「${task.device.name}」的传输请求，共 ${task.files.length} 个文件。是否接收？`)
        : `正在发送给「${task.device.name}」。请确认双方设备显示的 PIN 均为 ${task.pin}，确认后开始传输。`,
      buttons: [
        { text: '取消', color: HwColor.textSecondary },
        { text: '确认', color: HwColor.primary }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      PinDialogGuard.end();
      this.services?.transfer.confirmPin(task.id, result.index === 1);
    }).catch((): void => {
      PinDialogGuard.end();
      this.services?.transfer.confirmPin(task.id, false);
    });
  }

  private fileSizeText(size: number): string {
    if (size >= 1024 * 1024) {
      return (size / (1024 * 1024)).toFixed(1) + ' MB';
    }
    if (size >= 1024) {
      return Math.floor(size / 1024) + ' KB';
    }
    return size + ' B';
  }

  private openFile(file: IncomingFile): void {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const uri: string = file.savedPath.startsWith('file://') ? file.savedPath : fileUri.getUriFromPath(file.savedPath);
      ctx.startAbility({
        action: 'ohos.want.action.viewData',
        uri,
        flags: 1,
        parameters: { 'ohos.aafwk.param.bundleName': 'com.cashmere.link' }
      }).catch((error: BusinessError): void => {
        Lg.e('LocalSend open file failed: ' + JSON.stringify(error));
        promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '无法打开：' + (error.message ?? ''), duration: 2000 });
      });
    } catch (error) {
      Lg.e('LocalSend open file error: ' + JSON.stringify(error));
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '无法打开文件', duration: 2000 });
    }
  }
}
