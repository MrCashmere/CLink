import { LogCapture as Lg } from '../common/LogCapture';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
import { fileUri } from '@kit.CoreFileKit';
import { socket } from '@kit.NetworkKit';
import { DeviceEndpoint, IncomingFile, OutgoingFile, SessionFileMeta } from '../model/TransferModels';
import { DeviceList } from '../view/DeviceList';
import { IconCircleButton } from '../components/IconCircleButton';
import { AppBackground } from '../components/AppBackground';
import { HwColor, HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwPrimary, hwPrimaryButton, hwGlassSurface, hwGlassBorder } from '../utils/DesignTokens';
import { isApi26OrAbove, immersiveMaterialModifier, legacyMaterialModifier } from '../utils/SystemMaterial';
import { QuickShareBrowser, QuickSharePageEndpoint } from '../quickshare/controller/QuickShareBrowser';
import { createGsFacade, GsFacade, GsSendHooks, GS_QUICKSHARE_PORT } from '../protocol/gs/GsFacade';
import { getLocalIpv4 } from '../common/NetAddress';
import { AppServices } from '../common/AppServices';
import { QuickShareServiceEvent } from '../quickshare/utils/EventEmitter';
import { QuickShareTransferHistory } from '../quickshare/storage/TransferHistory';
import { SettingsStore } from '../common/SettingsStore';
import { sharedFilesFromParams } from '../common/ShareHandleUtil';
import { FilePickerHelper } from '../common/FilePickerHelper';
import { NearbyBleSocketClient } from '../quickshare/ble/NearbyBleSocketClient';
import { NearbyP2pDirect } from '../quickshare/ble/NearbyP2pDirect';
import { GsStreamConnection } from '../protocol/gs/GsFacade';

@Entry
@Component
struct QuickSharePage {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('immersiveLightEnabled') immersiveLightEnabled: boolean = true;
  @StorageLink('fontMode') fontMode: string = 'system';
  @StorageLink('fontFamilyEn') fontFamilyEn: string = 'system';
  @StorageLink('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageLink('fontWeightMode') fontWeightMode: string = 'system';
  @StorageLink('fontWeightValue') fontWeightValue: number = 400;
  @State devices: DeviceEndpoint[] = [];
  @State manualDevices: DeviceEndpoint[] = [];
  @State manualAddress: string = '';
  @State manualPortText: string = '';
  @State selectedFiles: OutgoingFile[] = [];
  @State receivedFiles: IncomingFile[] = [];
  @State statusText: string = '正在发现附近设备';
  private services?: AppServices;
  private browser?: QuickShareBrowser;
  private facade?: GsFacade;
  private localIp: string = '';
  private readonly eventListener: (event: QuickShareServiceEvent) => void = (event: QuickShareServiceEvent): void => {
    this.onQuickShareEvent(event);
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
    const services = AppServices.get(context);
    this.services = services;
    this.facade = createGsFacade('quickshare', context);
    this.browser = new QuickShareBrowser(context);
    this.browser.setOnChange((): void => this.syncEndpoints());
    this.localIp = getLocalIpv4();
    Lg.i('[QUICKSHARE] localIp=' + this.localIp);
    this.loadShareParams();
    // 接收端由 AppServices 常驻监听（0.0.0.0），页面仅订阅事件；确保就绪后再广播，
    // 避免对端连接过早。
    services.quickShareEvents.on(this.eventListener);
    services.setIncomingSessionHandler((peerName: string, files: SessionFileMeta[], pin: string): Promise<boolean> => {
      return this.onIncomingSession(peerName, files, pin);
    });
    services.startReceive().then((): void => {
      this.browser?.start();
      this.syncEndpoints();
      if (SettingsStore.current().quickshareWlanDirect) {
        this.statusText = 'WLAN 直连优先：仅 BLE 发现 + Wi-Fi Direct 传输';
      }
      // 接收（BLE GATT socket）常开：让 stock Android 在无 LAN 可达时能 bootstrap。
      services.startQuickShareBle().catch((): void => undefined);
      if (SettingsStore.current().quickshareWlanDirect) {
        services.startQuickShareWlanDirect().then((credentials) => {
          if (credentials !== undefined && credentials.goIpAddress.length > 0) {
            this.statusText = 'WLAN 直连组已就绪 ' + credentials.goIpAddress + ':' + GS_QUICKSHARE_PORT;
          }
        }).catch((error: Error) => {
          Lg.w('[QUICKSHARE] startQuickShareWlanDirect failed: ' + error.message);
        });
      }
      // 用回环临时服务器验证 socket.TCPSocket.connect 在本机是否可靠：
      // 自连 OK 但对端连不上 => 网络/AP 隔离；自连也 FAIL => HarmonyOS
      // socket.connect 的 EINPROGRESS 问题。
      this.selfTcpTest().catch((): void => undefined);
    }).catch((error: BusinessError): void => {
      this.statusText = '接收启动失败：' + error.message;
    });
    this.showStabilityHint();
  }

  // 当前 Quick Share 可用但不稳定：进入页面仅弹出一次可手动关闭的提示，
  // 引导在传输报错时参考「设置 -> 关于 -> 解决方案」。已展示过则不再弹出。
  private showStabilityHint(): void {
    const context = getContext(this) as common.UIAbilityContext;
    SettingsStore.load(context).then((settings) => {
      if (settings.quickShareHintShown) {
        return;
      }
      settings.quickShareHintShown = true;
      SettingsStore.save(context, settings).catch((): void => undefined);
      this.promptStabilityHint();
    }).catch((): void => undefined);
  }

  private promptStabilityHint(): void {
    promptAction.showDialog({
      title: 'Quick Share 提示',
      message: '目前 Quick Share 可用但不稳定，若您出现点击传输后报错，请参考「设置 -> 关于 -> 解决方案」。',
      buttons: [
        { text: '知道了', color: HwColor.primary }
      ]
    }).catch((error: BusinessError): void => {
      Lg.w('[QUICKSHARE] stability hint dismissed: ' + error.message);
    });
  }

  aboutToDisappear(): void {
    const services = this.services;
    if (services !== undefined) {
      services.stopQuickShareBle();
      services.stopQuickShareWlanDirect();
      services.quickShareEvents.off(this.eventListener);
      services.clearIncomingSessionHandler();
    }
    this.browser?.stop();
    this.browser = undefined;
    this.facade = undefined;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      AppBackground()
      Column() {
        Scroll() {
          Column({ space: 12 }) {
            Blank().height(56 + this.statusBarHeight)
            this.statusCard()
            this.selectFileCard()
            if (this.selectedFiles.length > 0) {
              Text('已选择 ' + this.selectedFiles.length + ' 个文件，点击下方设备即可发送').fontSize(12).fontFamily(this.appFontFamily('已选择 个文件，点击下方设备即可发送')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).width('100%').padding({ left: 4, right: 4, bottom: 8 })
            }
            Text('附近设备').fontSize(14).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('附近设备')).fontColor(hwTextPrimary(this.isDarkMode)).width('100%').padding({ left: 4 })
            DeviceList({
              devices: this.devices,
              onSelect: (device: DeviceEndpoint): void => {
                this.sendOrPick(device).catch((error: Error): void => promptAction.showToast({ message: error.message }));
              }
            })
            this.manualAddCard()
            if (this.devices.length === 0 && this.manualDevices.length === 0) {
              Text('请打开对端 Quick Share，并保持蓝牙与 Wi-Fi 开启').fontSize(14).fontFamily(this.appFontFamily('请打开对端 Quick Share，并保持蓝牙与 Wi-Fi 开启')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
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
        IconCircleButton({ symbol: $r('sys.symbol.chevron_left'), buttonSize: 40, iconSize: 20, onAction: (): void => router.back() })
        Text('Quick Share').fontSize(20).fontWeight(FontWeight.Bold).fontFamily(this.appFontFamily('Quick Share')).fontColor(hwTextPrimary(this.isDarkMode)).margin({ left: HwSpace.md })
        Blank()
      }
      .width('100%')
      .height(56 + this.statusBarHeight)
      .padding({ left: 16, right: 16, top: this.statusBarHeight })
      .backgroundEffect({ radius: 12, color: '#66FFFFFF' })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDarkMode ? HwColor.backgroundDark : HwColor.background)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  statusCard() {
    Column({ space: 4 }) {
      Text('状态').fontSize(12).fontFamily(this.appFontFamily('状态')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
      Text(this.statusText).fontSize(14).fontFamily(this.appFontFamily(this.statusText)).fontWeight(this.appFontWeight()).fontColor(hwTextPrimary(this.isDarkMode))
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
      Text(this.selectedFiles.length > 0 ? '已选择 ' + this.selectedFiles.length + ' 个文件' : '从系统中选择要发送的文件').fontSize(12).fontFamily(this.appFontFamily('从系统中选择要发送的文件')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
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

  @Builder
  manualAddCard() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        TextInput({ placeholder: '对端 IP (如 192.168.0.113)', text: this.manualAddress })
          .layoutWeight(1).height(40)
          .onChange((v: string): void => { this.manualAddress = v; });
        TextInput({ placeholder: '动态端口', text: this.manualPortText })
          .width(90).height(40)
          .onChange((v: string): void => { this.manualPortText = v; });
        Button('添加').height(40).fontSize(13).backgroundColor(hwPrimaryButton(this.isDarkMode))
          .fontColor(Color.White).onClick((): void => this.addManualDevice());
      }.width('100%')
      Text('手动添加对端（绕开发现，直接指定地址）。对端端口为动态分配非固定，请以对端实际广播端口为准').fontSize(12).fontFamily(this.appFontFamily('手动添加对端（绕开发现，直接指定地址）。对端端口为动态分配非固定，请以对端实际广播端口为准')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).width('100%')
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
  receivedFilesCard() {
    Column({ space: 6 }) {
      Text('已接收 ' + this.receivedFiles.length + ' 个文件').fontSize(14).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('已接收 个文件')).fontColor(hwTextPrimary(this.isDarkMode))
      ForEach(this.receivedFiles, (file: IncomingFile): void => {
        Column({ space: 4 }) {
          Row({ space: 8 }) {
            Text(file.name).layoutWeight(1).fontSize(13).fontFamily(this.appFontFamily(file.name)).fontWeight(this.appFontWeight()).fontColor(hwTextPrimary(this.isDarkMode))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.fileSizeText(file.size)).fontSize(12).fontFamily(this.appFontFamily(this.fileSizeText(file.size))).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
            Button('打开', { type: ButtonType.Capsule }).height(26).fontSize(12).fontFamily(this.appFontFamily('打开'))
              .backgroundColor(hwPrimaryButton(this.isDarkMode)).fontColor(Color.White)
              .onClick(() => this.openFile(file))
          }.width('100%')
          Text(file.savedPath).fontSize(11).fontFamily(this.appFontFamily(file.savedPath)).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }.width('100%')
      }, (file: IncomingFile): string => file.savedPath + ':' + file.name)
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(this.immersiveLightEnabled && isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  private onQuickShareEvent(event: QuickShareServiceEvent): void {
    if (event.kind === 'incoming') {
      this.statusText = '收到来自 ' + (event.peerName ?? '') + ' 的接收请求';
    } else if (event.kind === 'file') {
      if (event.file !== undefined) {
        this.receivedFiles = this.receivedFiles.concat([event.file]);
        this.statusText = '已接收：' + event.file.name;
      }
    } else if (event.kind === 'progress') {
      const pct = event.percent ?? 0;
      this.statusText = '接收中 ' + Math.floor(pct) + '%';
      if (pct >= 100) {
        this.statusText = '接收完成';
      }
    }
  }

  private async selfTcpTest(): Promise<void> {
    let server: socket.TCPSocketServer | undefined = undefined;
    let client: socket.TCPSocket | undefined = undefined;
    const TIMEOUT_MS = 2000;
    try {
      server = socket.constructTCPSocketServerInstance();
      await server.listen({ address: '127.0.0.1', family: 1, port: 0 });
      const local = await server.getLocalAddress();
      const portRaw = local.port;
      if (portRaw === undefined || portRaw === 0) {
        throw new Error('self-test server bound to an invalid port');
      }
      const port: number = portRaw;
      client = socket.constructTCPSocketInstance();
      await client.bind({ address: '0.0.0.0', family: 1, port: 0 });
      const ok = await this.tcpProbe(client, '127.0.0.1', port, TIMEOUT_MS);
      Lg.i('[QUICKSHARE] TCP self-test ' + (ok ? 'OK' : 'FAIL') + ' 127.0.0.1:' + port);
    } catch (error) {
      Lg.w('[QUICKSHARE] TCP self-test exception: ' + JSON.stringify(error));
    } finally {
      if (client !== undefined) {
        await client.close().catch((): void => undefined);
      }
      if (server !== undefined) {
        await server.close().catch((): void => undefined);
      }
    }
  }

  // 容忍 EINPROGRESS(2301115)：connect() 返回该错误码不意味失败，需等 connect
  // 事件或 getState().isConnected 定论（与 LocalSendSubnetScanner.connectChecked 一致）。
  private async tcpProbe(tcp: socket.TCPSocket, host: string, port: number, timeoutMs: number): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      let done = false;
      let timer = -1;
      const finish = (ok: boolean): void => {
        if (done) {
          return;
        }
        done = true;
        if (timer !== -1) {
          clearTimeout(timer);
        }
        resolve(ok);
      };
      tcp.on('connect', (): void => finish(true));
      tcp.on('close', (): void => finish(false));
      tcp.on('error', (error: Object): void => {
        if (this.socketCode(error) !== 2301115) {
          finish(false);
        }
      });
      timer = setTimeout((): void => {
        tcp.getState().then((state: socket.SocketStateBase): void => finish(state.isConnected))
          .catch((): void => finish(false));
      }, timeoutMs);
      try {
        tcp.connect({ address: { address: host, family: 1, port } })
          .then((): void => finish(true))
          .catch((error: Object): void => {
            if (this.socketCode(error) !== 2301115) {
              finish(false);
            }
          });
      } catch (error) {
        finish(false);
      }
    });
  }

  private socketCode(error: Object): number {
    const text = JSON.stringify(error);
    const match = /"code"\s*:\s*(\d+)/.exec(text);
    if (match !== null) {
      const value = parseInt(match[1], 10);
      if (!Number.isNaN(value)) {
        return value;
      }
    }
    return text.indexOf('2301115') >= 0 ? 2301115 : 0;
  }

  private syncEndpoints(): void {
    let discovered: DeviceEndpoint[] = [];
    if (this.browser !== undefined) {
      const endpoints: QuickSharePageEndpoint[] = this.browser.endpoints();
      discovered = endpoints.map((endpoint: QuickSharePageEndpoint): DeviceEndpoint => ({
        id: endpoint.id,
        name: endpoint.name,
        model: 'Quick Share',
        protocol: 'quickshare',
        address: endpoint.address,
        port: endpoint.port,
        https: false,
        fingerprint: endpoint.endpointId,
        source: endpoint.source,
        deviceType: endpoint.deviceType
      }));
    }
    // 稳定合并：保持已出现设备卡片的相对位置不变，仅更新其元数据；新发现的设备追加到列表末尾。
    // 这样后续扫描到新的设备时，不会打乱已有设备卡片的排序。
    const freshById: Map<string, DeviceEndpoint> = new Map();
    for (const endpoint of discovered) {
      freshById.set(endpoint.id, endpoint);
    }
    const mergedDiscovered: DeviceEndpoint[] = [];
    const seenIds: Set<string> = new Set();
    for (const existing of this.devices) {
      if (existing.source === 'manual') {
        continue;
      }
      const update: DeviceEndpoint | undefined = freshById.get(existing.id);
      if (update !== undefined) {
        mergedDiscovered.push(update);
        seenIds.add(update.id);
      }
    }
    for (const endpoint of discovered) {
      if (!seenIds.has(endpoint.id)) {
        mergedDiscovered.push(endpoint);
        seenIds.add(endpoint.id);
      }
    }
    const mergedManual: DeviceEndpoint[] = this.manualDevices.slice();
    // 仅在列表有实质变化时才重建 @State，避免每次发现回调都触发整段设备卡片重排版、占用主线程。
    if (!this.listEquals(this.devices, mergedDiscovered.concat(mergedManual))) {
      this.devices = mergedDiscovered.concat(mergedManual);
    }
    this.statusText = '已发现 ' + discovered.length + ' 台 Quick Share 设备';
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

  private addManualDevice(): void {
    const ip = this.manualAddress.trim();
    if (this.isIpv4(ip) === false) {
      promptAction.showToast({ message: '请输入合法 IPv4 地址' });
      return;
    }
    const parsed = Number(this.manualPortText.trim());
    const port = Number.isInteger(parsed) && parsed > 0 ? parsed : GS_QUICKSHARE_PORT;
    this.manualDevices = this.manualDevices.concat([{
      id: 'manual:' + ip + ':' + port,
      name: ip,
      model: 'Manual',
      protocol: 'quickshare',
      address: ip,
      port: port,
      https: false,
      fingerprint: ip,
      source: 'manual'
    }]);
    this.syncEndpoints();
  }

  private isIpv4(value: string): boolean {
    if (value.length === 0) {
      return false;
    }
    const parts = value.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (const part of parts) {
      const n = Number(part);
      if (!Number.isInteger(n) || n < 0 || n > 255) {
        return false;
      }
      if (part.length > 1 && part[0] === '0') {
        return false;
      }
    }
    return true;
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
    if (this.facade === undefined) {
      throw new Error('Quick Share 会话尚未就绪');
    }
    // 每次发送前都跑一次回环自测并打印结果，方便判定是「socket.connect 本机就不稳」
    // 还是「对端不可达/网络隔离」。
    this.selfTcpTest().catch((): void => undefined);
    const hooks: GsSendHooks = {
      onPin: (pin: string): Promise<boolean> => this.confirmPin(pin),
      onProgress: (percent: number): void => {
        this.statusText = '发送中 ' + Math.floor(percent) + '%';
      },
        localEndpointId: this.browser?.localEndpointIdValue(),
        sourceAddress: this.localIp.length > 0 ? this.localIp : undefined,
        forceWifiDirect: SettingsStore.current().quickshareWlanDirect,
        pcPeer: device.deviceType === 3,
        onWifiDirectTransport: (creds): Promise<GsStreamConnection | undefined> => {
          return new NearbyP2pDirect().connectAsClient(creds);
        }
    };
    // 优先使用 BLE：按优先级选择
    //  1) 对端条目本身就是 BLE 扫描发现 -> 用它的广告 MAC（承载 Weave socket）
    //  2) 同一 endpointId 当前有 BLE 广告 -> 用扫描到的广告 MAC（即使列表里因
    //     mDNS 优先级被顶掉，也以此为准，避免误连“接收时缓存的客户端 MAC”）
    //  3) 最后才回退到接收会话缓存的对端 MAC（该 MAC 是对方作为发起方/中心
    //     的地址，往往不暴露 socket 服务，仅作兜底）
    let bleMac: string = '';
    if (device.source === 'ble') {
      bleMac = device.address ?? '';
    }
    if (bleMac.length === 0 && this.browser !== undefined) {
      bleMac = this.browser.bleAddressFor(device.fingerprint);
    }
    if (bleMac.length === 0) {
      bleMac = this.services?.lastPeerBleMacValue() ?? '';
    }
    if (bleMac.length > 0) {
      const bleClient: NearbyBleSocketClient = new NearbyBleSocketClient();
      const conn: GsStreamConnection = await bleClient.connect(bleMac);
      try {
        await this.facade.sendStream(conn, this.selectedFiles, hooks);
      } finally {
        conn.close();
      }
    } else {
      await this.facade.send(device, this.selectedFiles, hooks);
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    for (const f of this.selectedFiles) {
      QuickShareTransferHistory.add(ctx, { id: 'snd-' + Date.now() + '-' + f.name, name: f.name, size: f.size, direction: 'send', peer: device.name, completedAt: Date.now(), savedPath: '' }).catch((): void => undefined);
    }
    this.selectedFiles = [];
    promptAction.showToast({ message: 'Quick Share 传输已完成' });
  }

  private confirmPin(pin: string): Promise<boolean> {
    return promptAction.showDialog({
      title: 'Quick Share 发送确认',
      message: `正在发送给对端设备。请确认双方设备显示的 PIN 均为 ${pin}，确认后开始传输。`,
      buttons: [
        { text: '取消', color: HwColor.textSecondary },
        { text: '确认', color: HwColor.primary }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): boolean => result.index === 1).catch((): boolean => false);
  }

  private onIncomingSession(peerName: string, files: SessionFileMeta[], pin: string): Promise<boolean> {
    return promptAction.showDialog({
      title: 'Quick Share 接收请求',
      message: `「${peerName}」想发送 ${files.length} 个文件。双方 PIN：${pin}\n是否接收？`,
      buttons: [
        { text: '拒绝', color: HwColor.textSecondary },
        { text: '接收', color: HwColor.primary }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): boolean => result.index === 1).catch((): boolean => false);
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
        Lg.e('Quick Share open file failed: ' + JSON.stringify(error));
        promptAction.showToast({ message: '无法打开：' + (error.message ?? ''), duration: 2000 });
      });
    } catch (error) {
      Lg.e('Quick Share open file error: ' + JSON.stringify(error));
      promptAction.showToast({ message: '无法打开文件', duration: 2000 });
    }
  }
}
