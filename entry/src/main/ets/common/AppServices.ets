import { LogCapture as Lg } from '../common/LogCapture';
import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { fileUri } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import promptAction from '@ohos.promptAction';
import { CertificateStore } from './CertificateStore';
import { SettingsStore } from './SettingsStore';
import { PinDialogGuard } from './PinDialogGuard';
import { getLocalIpv4 } from './NetAddress';
import { HotspotAddressResolver } from '../service/HotspotAddressResolver';
import { HwColor } from '../utils/DesignTokens';
import { LocalSendDiscovery } from '../service/LocalSendDiscovery';
import { TransferManager } from '../service/TransferManager';
import { LocalSendServer, LocalSendPeerSignal } from '../protocol/localsend/LocalSendServer';
import { createGsFacade, GsFacade, GsReceiveHooks, GS_QUICKSHARE_PORT, WifiDirectUpgradeCredentials, GsTransportChange } from '../protocol/gs/GsFacade';
import { DynamicPhotoService, IncomingFileLike } from './DynamicPhotoService';
import { IncomingFile, SessionFileMeta } from '../model/TransferModels';
import { QuickShareEventEmitter, QuickShareServiceEvent, IncomingSessionHandler } from '../quickshare/utils/EventEmitter';
import { QuickShareTransferHistory } from '../quickshare/storage/TransferHistory';
import { NearbyBleMedium } from '../quickshare/discovery/NearbyBleMedium';
import { NearbyP2pDirect, P2pGroupCredentials } from '../quickshare/ble/NearbyP2pDirect';
import { SecurityUtils } from './SecurityUtils';
import { GsStreamConnection } from '../protocol/gs/GsFacade';
import { toastSystemMaterial, dialogSystemMaterial } from '../utils/SystemMaterial';
import { GalleryAutoSaveService } from '../quickshare/service/GalleryAutoSaveService';

export interface LocalsendWebLinkInfo {
  readonly address: string;
  readonly port: number;
  readonly scheme: string;
}

/** LocalSend 原生协议下「本机作为接收端」的地址：IP + 真实监听端口 + 是否走 HTTPS。 */
export interface LocalsendSelfEndpoint {
  readonly address: string;
  readonly port: number;
  readonly https: boolean;
}

export class AppServices {
  private static instance?: AppServices;
  readonly certs: CertificateStore;
  readonly localsend: LocalSendDiscovery;
  readonly transfer: TransferManager;
  /** App 级 Quick Share 接收事件总线：页面 open 时订阅，close 只退订不断开监听。 */
  readonly quickShareEvents: QuickShareEventEmitter<QuickShareServiceEvent> = new QuickShareEventEmitter<QuickShareServiceEvent>();
  private running = false;
  private receiveGeneration: number = 0;
  private startPromise?: Promise<void>;
  private gsQuickshare?: GsFacade;
  private gsQuickshareReady = false;
  /** Quick Share 接收端启动失败原因（空串 = 正常监听）：页面据此给出可见提示。 */
  private quickShareReceiveErrorText: string = '';
  private quickShareStartPromise?: Promise<void>;
  private incomingSessionHandler?: IncomingSessionHandler;
  private lastPeerName: string = '';
  /** 当前 Quick Share 接收的卡片任务 id（用于在聚合页卡片上展示接收进度）。 */
  private qsReceiveTaskId: string = '';
  /** 当前 Quick Share 接收已收到的文件（用于完成弹窗与卡片计数）。 */
  private qsReceiveFiles: IncomingFile[] = [];
  /** 当前 Quick Share 接收的文件总数。 */
  private qsReceiveTotal: number = 0;
  private nearbyBleMedium?: NearbyBleMedium;
  private nearbyP2p?: NearbyP2pDirect;
  private bleEndpointId: string = '';
  private keepAliveActive = false;
  /** 通知授权是否已请求过（避免每次启动都重复弹窗）。 */
  private notificationRequested = false;
  /** 预创建并缓存的保活 wantAgent，保证 onBackground 里能立即调用 startBackgroundRunning。 */
  private keepAliveAgent?: object;

  private readonly context: common.UIAbilityContext;

  private constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.certs = new CertificateStore(context);
    this.localsend = new LocalSendDiscovery(context);
    this.transfer = new TransferManager(context, this.certs);
  }

  static get(context: common.UIAbilityContext): AppServices {
    if (AppServices.instance === undefined) {
      AppServices.instance = new AppServices(context);
    }
    return AppServices.instance;
  }

  /** 首页只保证接收能力，不主动扫描附近设备。 */
  async startReceive(): Promise<void> {
    const generation = this.receiveGeneration;
    while (this.startPromise !== undefined) {
      await this.startPromise;
      if (generation !== this.receiveGeneration) { return; }
    }
    if (this.running && this.gsQuickshareReady) { return; }
    const promise = this.doStartReceive(generation);
    this.startPromise = promise;
    try {
      await promise;
    } finally {
      if (this.startPromise === promise) {
        this.startPromise = undefined;
      }
    }
  }

  private async doStartReceive(generation: number): Promise<void> {
    await SettingsStore.load(this.context);
    if (generation !== this.receiveGeneration) { return; }
    // 开着长时任务保活时，先确保本应用允许发布通知——连续任务的通知由系统自动发布，
    // 但若通知权限未开启会报 1600020/9800006 而不显示。这里在前台启动时申请一次。
    await this.ensureKeepAliveNotificationPermission();
    // 前台提前创建并缓存 wantAgent，退后台启动连续任务时无需再 await（避免应用被冻结后才调用而失败）。
    if (SettingsStore.current().keepAlive) {
      try {
        await this.buildKeepAliveAgent();
      } catch (error) {
        Lg.w('[KEEPALIVE] prebuild wantAgent failed: ' + JSON.stringify(error));
      }
    }
    if (generation !== this.receiveGeneration) { return; }
    if (!this.running) {
      await this.transfer.startServer();
      if (generation !== this.receiveGeneration) { return; }
      this.localsend.setHttps(LocalSendServer.lastHttpsActive);
      this.localsend.setPort(LocalSendServer.actualPort);
      await this.refreshAliasFingerprint();
      if (generation !== this.receiveGeneration) { return; }
      this.running = true;
      this.localsend.startReceiveOnly();
      // HTTP 层的对端身份信号（/register、/send-request）→ 发现链路兜底：
      // 热点模式下组播收包不可靠（中继依赖系统放行），这条 TCP 单播通道是
      // 「对端主动告诉本机我在这里」的最稳信号 —— 对端能 POST 进来就说明它发现了本机。
      LocalSendServer.onPeerSignal = (signal: LocalSendPeerSignal): void => {
        this.localsend.emitExternal({
          id: 'localsend:' + signal.address + ':' + signal.port,
          name: signal.alias,
          model: signal.deviceModel,
          protocol: 'localsend',
          address: signal.address,
          port: signal.port,
          https: signal.protocol.toLowerCase() !== 'http',
          fingerprint: signal.fingerprint,
          source: 'lan'
        });
      };
    }
    // 预热热点地址探测：开热点时系统枚举常看不到 SoftAP，只给蜂窝地址（10.x），
    // 那个地址连着热点的电脑访问不到。这里先探一次，UI 生成访问链接时才有正确地址可用。
    void HotspotAddressResolver.resolve(LocalSendServer.actualWebPort);
    // Quick Share 接收端与应用同生命周期：App 进程在前台/主页即监听，不随 QuickShare
    // 页面启停（对齐 LocalSend 的稳定可收），且不申请任何后台常驻任务/通知。
    await this.startQuickShareReceive();
  }

  /** 保活前置：确保本应用已获得通知发布权限。仅在开启「长时任务保活」时申请，且只申请一次。 */
  async ensureKeepAliveNotificationPermission(): Promise<void> {
    if (this.notificationRequested) {
      return;
    }
    if (!SettingsStore.current().keepAlive) {
      return;
    }
    this.notificationRequested = true;
    try {
      const enabled = await notificationManager.isNotificationEnabled();
      Lg.i('[KEEPALIVE] isNotificationEnabled=' + enabled + ' keepAlive=' + SettingsStore.current().keepAlive);
      if (!enabled) {
        await notificationManager.requestEnableNotification(this.context);
        Lg.i('[KEEPALIVE] notification permission requested/granted');
      } else {
        Lg.i('[KEEPALIVE] notification already enabled');
      }
    } catch (error) {
      Lg.w('[KEEPALIVE] requestEnableNotification failed: ' + JSON.stringify(error));
    }
  }

  /** 创建并缓存保活用的 wantAgent（点击通知回到 App）。 */
  private async buildKeepAliveAgent(): Promise<object> {
    const agent = await wantAgent.getWantAgent({
      wants: [
        {
          bundleName: 'com.cashmere.link',
          abilityName: 'EntryAbility'
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    this.keepAliveAgent = agent;
    return agent;
  }

  startLocalSendScanning(): void {
    this.localsend.startScan();
  }

  stopLocalSendScanning(): void {
    this.localsend.stopScan();
  }

  /** 局域网网页传输：本机网页端服务运行的地址与端口（始终明文 HTTP，供浏览器访问）。
   *  网页监听全部端口都启动失败时 actualWebPort 被置 0，这里返回空地址，
   *  避免 UI 拼出 `http://IP:0` 这种不可用地址（具体原因见 LocalSendServer 的错误日志）。 */
  localsendWebLink(): LocalsendWebLinkInfo {
    if (LocalSendServer.actualWebPort <= 0) {
      return { address: '', port: 0, scheme: 'http' };
    }
    // 热点场景优先用热点地址：系统枚举（localsend.getLocalAddress / getLocalIpv4）
    // 在开热点时通常只能看到蜂窝地址（如 192.0.2.10），而连接本热点的电脑在 192.168.43.0/24，
    // 拿蜂窝地址拼出来的链接电脑是访问不到的。
    // 取值分两级：探测确认过的地址 → 热点开着时的即时答案（不等探测）→ 普通 Wi-Fi 地址。
    void HotspotAddressResolver.resolve(LocalSendServer.actualWebPort);
    return {
      address: this.preferredAddress(),
      port: LocalSendServer.actualWebPort,
      scheme: 'http'
    };
  }

  /** 本机对外地址：热点地址（已确认 → 即时答案）优先，否则回落到系统枚举的局域网地址。 */
  private preferredAddress(): string {
    const hotspot: string = HotspotAddressResolver.bestAddress();
    if (hotspot.length > 0) {
      return hotspot;
    }
    return this.localsend.getLocalAddress().length > 0
      ? this.localsend.getLocalAddress()
      : getLocalIpv4();
  }

  /** 页面展示用的本机地址（首页副标题等），与网页传输链接取同一套热点优先逻辑。 */
  displayAddress(): string {
    return this.preferredAddress();
  }

  /** 订阅热点地址确认事件：探测命中后立刻回调，页面不必等 5 秒刷新周期。 */
  onHotspotAddressChange(listener: (address: string) => void): void {
    HotspotAddressResolver.onResolved(listener);
  }

  offHotspotAddressChange(listener: (address: string) => void): void {
    HotspotAddressResolver.offResolved(listener);
  }

  /** LocalSend 原生协议的本机接收端点（`IP:端口`）。
   *  用途：电脑端 LocalSend 用「手动发送 / 收藏设备」直连本机。热点、跨网段、组播被拦等
   *  发现机制失效的场景下，这是让对端主动发过来的唯一可靠入口 —— 不依赖 mDNS 或组播。
   *  端口取真实监听值（不是协议默认 53317），监听失败时为 0，UI 需按空处理。 */
  localsendSelfEndpoint(): LocalsendSelfEndpoint {
    const port: number = LocalSendServer.actualPort;
    if (port <= 0) {
      return { address: '', port: 0, https: false };
    }
    void HotspotAddressResolver.resolve(port);
    return { address: this.preferredAddress(), port: port, https: LocalSendServer.lastHttpsActive };
  }

  /** Quick Share 接收端启动失败原因；空串表示 53318 正在正常监听。
   *  历史上该端口曾被「局域网网页传输」的明文 HTTP 监听抢占，导致能发现却收不到文件。 */
  quickShareReceiveFault(): string {
    return this.quickShareReceiveErrorText;
  }

  /** 页面订阅接收确认回调（弹窗），页面未打开时回退为静默接收。 */
  setIncomingSessionHandler(handler: IncomingSessionHandler): void {
    this.incomingSessionHandler = handler;
  }

  clearIncomingSessionHandler(): void {
    this.incomingSessionHandler = undefined;
  }

  /** 开启 Quick Share BLE GATT socket 服务，让 TCP 不可达的 stock 对端也能 bootstrap。 */
  async startQuickShareBle(): Promise<void> {
    const generation = this.receiveGeneration;
    await this.startQuickShareReceive();
    if (generation !== this.receiveGeneration) { return; }
    if (this.gsQuickshare === undefined) {
      Lg.w('[QUICKSHARE] startQuickShareBle skipped: receiver not ready');
      return;
    }
    const medium: NearbyBleMedium = this.nearbyBleMedium ?? new NearbyBleMedium();
    medium.setOnConnection((conn: GsStreamConnection): void => {
      if (this.gsQuickshare !== undefined) {
        this.gsQuickshare.runReceiveStream(conn, this.buildQuickShareHooks())
          .catch((error: Error): void => {
            Lg.w('[QUICKSHARE] BLE stream receiver failed: ' + error.message);
          });
      }
      // BLE socket 建立说明对端未能走 WIFI_LAN（TCP 失败后降级）：除「仅局域网」模式外，
      // 随即建 Wi-Fi Direct 组供对端升级（auto/direct 都允许；direct 只是更早、更主动）。
      if (SettingsStore.current().quickshareTransport !== 'lan') {
        this.startQuickShareWlanDirect()
          .catch((error: Error): void => {
            Lg.w('[QUICKSHARE] WLAN Direct group after BLE bootstrap failed: ' + error.message);
          });
      }
    });
    this.nearbyBleMedium = medium;
    if (this.bleEndpointId.length === 0) {
      this.bleEndpointId = SecurityUtils.createToken().slice(0, 4);
    }
    const active: boolean = await medium.start(this.bleEndpointId, SettingsStore.current().alias);
    Lg.i('[QUICKSHARE] Quick Share BLE GATT socket ' + (active ? 'active' : 'waiting for Bluetooth')
      + ' endpointId=' + this.bleEndpointId);
  }

  stopQuickShareBle(): void {
    this.nearbyBleMedium?.stop();
    this.nearbyBleMedium = undefined;
  }

  /** 设置/降级触发：创建 Wi-Fi Direct 组（GO），返回凭据以交给对端升级。 */
  async startQuickShareWlanDirect(): Promise<P2pGroupCredentials | undefined> {
    if (this.nearbyP2p !== undefined && this.nearbyP2p.isActive()) {
      return this.nearbyP2p.currentCredentials();
    }
    if (this.nearbyP2p === undefined) {
      this.nearbyP2p = new NearbyP2pDirect();
    }
    return this.nearbyP2p.createGroup();
  }

  stopQuickShareWlanDirect(): void {
    if (this.nearbyP2p !== undefined) {
      this.nearbyP2p.removeGroup();
      this.nearbyP2p = undefined;
    }
  }

  wlanDirectActive(): boolean {
    return this.nearbyP2p !== undefined && this.nearbyP2p.isActive();
  }

  stop(): void {
    this.receiveGeneration += 1;
    this.running = false;
    this.stopContinuousTask().catch((): void => undefined);
    this.localsend.stop();
    this.transfer.stopServer();
    if (this.gsQuickshare !== undefined) {
      this.gsQuickshare.stopReceive();
      this.gsQuickshare = undefined;
    }
    this.nearbyBleMedium?.stop();
    this.nearbyBleMedium = undefined;
    this.nearbyP2p?.removeGroup();
    this.nearbyP2p = undefined;
    this.gsQuickshareReady = false;
    this.quickShareReceiveErrorText = '';
    this.incomingSessionHandler = undefined;
    this.quickShareEvents.clear();
  }

  /**
   * 重启接收侧：停掉 LocalSend 服务端 / Quick Share 接收 / Quick Share BLE，
   * 再按冷启动同一条路径（doStartReceive）重新拉起，等价于重新打开应用后的接收状态。
   *
   * 与 stop() 的区别：保留 quickShareEvents 订阅与 incomingSessionHandler，
   * 刷新过程中已打开的页面不会掉线、也不会丢失接收确认弹窗。
   */
  async restartReceive(): Promise<void> {
    Lg.i('[SERVICES] restartReceive: 停止接收侧并按冷启动路径重启');
    // 旧启动先结束；代次校验会丢弃它的结果，避免异步回调复活已关闭的监听。
    this.receiveGeneration += 1;
    this.running = false;
    this.gsQuickshareReady = false;
    try {
      this.localsend.stop();
    } catch (error) {
      Lg.w('[SERVICES] restartReceive localsend.stop failed: ' + JSON.stringify(error));
    }
    try {
      this.transfer.stopServer();
    } catch (error) {
      Lg.w('[SERVICES] restartReceive transfer.stopServer failed: ' + JSON.stringify(error));
    }
    if (this.gsQuickshare !== undefined) {
      try {
        this.gsQuickshare.stopReceive();
      } catch (error) {
        Lg.w('[SERVICES] restartReceive quickshare.stopReceive failed: ' + JSON.stringify(error));
      }
      this.gsQuickshare = undefined;
    }
    this.nearbyBleMedium?.stop();
    this.nearbyBleMedium = undefined;
    await this.startReceive();
    Lg.i('[SERVICES] restartReceive done');
  }

  /** 用当前监听协议的身份更新 LocalSend 广播指纹。 */
  async refreshAliasFingerprint(): Promise<void> {
    const fingerprint = await this.certs.discoveryFingerprint(LocalSendServer.lastHttpsActive);
    this.localsend.setFingerprint(fingerprint);
  }

  /** 是否已申请到持续后台运行的长时任务。 */
  continuousTaskActive(): boolean {
    return this.keepAliveActive;
  }

  /** 申请长时任务(Continuous Task)保活：接收服务已运行时进入后台仍能持续收文件。
   *  仅在设置里开启「长时任务保活」且接收服务已就绪时生效；重复调用无副作用。 */
  async startContinuousTask(): Promise<void> {
    if (this.keepAliveActive) {
      return;
    }
    const keepAliveOn = SettingsStore.current().keepAlive;
    Lg.i('[KEEPALIVE] startContinuousTask called running=' + this.running + ' keepAlive=' + keepAliveOn + ' active=' + this.keepAliveActive);
    if (!keepAliveOn) {
      return;
    }
    if (!this.running) {
      // 接收服务尚未启动（如首页未出现前就进入后台）：不申请，待服务就绪后由前台回调重试。
      return;
    }
    try {
      let agent = this.keepAliveAgent;
      if (agent === undefined) {
        agent = await this.buildKeepAliveAgent();
      }
      await backgroundTaskManager.startBackgroundRunning(this.context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      this.keepAliveActive = true;
      Lg.i('[KEEPALIVE] continuous task started (DATA_TRANSFER)');
    } catch (error) {
      Lg.w('[KEEPALIVE] startBackgroundRunning failed: ' + JSON.stringify(error));
    }
  }

  /** 结束长时任务保活：应用回到前台或用户关闭开关时调用。 */
  async stopContinuousTask(): Promise<void> {
    if (!this.keepAliveActive) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      this.keepAliveActive = false;
      Lg.i('[KEEPALIVE] continuous task stopped');
    } catch (error) {
      Lg.w('[KEEPALIVE] stopBackgroundRunning failed: ' + JSON.stringify(error));
    }
  }

  private async startQuickShareReceive(): Promise<void> {
    const generation = this.receiveGeneration;
    while (this.quickShareStartPromise !== undefined) {
      await this.quickShareStartPromise;
      if (generation !== this.receiveGeneration) { return; }
    }
    if (this.gsQuickshareReady) { return; }
    const promise = this.doStartQuickShareReceive(generation);
    this.quickShareStartPromise = promise;
    try {
      await promise;
    } finally {
      if (this.quickShareStartPromise === promise) {
        this.quickShareStartPromise = undefined;
      }
    }
  }

  private async doStartQuickShareReceive(generation: number): Promise<void> {
    if (this.gsQuickshareReady) {
      return;
    }
    try {
      const facade = createGsFacade('quickshare', this.context);
      await facade.startReceive(GS_QUICKSHARE_PORT, this.buildQuickShareHooks(), '0.0.0.0');
      if (generation !== this.receiveGeneration) {
        facade.stopReceive();
        return;
      }
      this.gsQuickshare = facade;
      this.gsQuickshareReady = true;
      this.quickShareReceiveErrorText = '';
      Lg.i('[QUICKSHARE] AppServices listen ok port=' + GS_QUICKSHARE_PORT + ' bind=0.0.0.0');
    } catch (error) {
      if (generation !== this.receiveGeneration) { return; }
      const detail: string = error instanceof Error ? error.message : JSON.stringify(error);
      // 不再静默失败：端口被占用时 mDNS 仍会按 53318 通告，对端能“看见”却连不上，
      // 这里把原因留给页面显示（QuickShare 页面 aboutToAppear 读取）。
      this.quickShareReceiveErrorText = 'Quick Share 接收启动失败：端口 ' + GS_QUICKSHARE_PORT
        + ' 可能已被其他服务占用（网页端传输应使用 23333）。' + detail;
      Lg.e('[QUICKSHARE] AppServices startReceive failed: ' + JSON.stringify(error));
    }
  }

  private buildQuickShareHooks(): GsReceiveHooks {
    return {
      onIncomingSession: (key: string, peerName: string, files: SessionFileMeta[], pin: string): Promise<boolean> => {
        this.lastPeerName = peerName;
        this.quickShareEvents.emit({
          kind: 'incoming',
          key: key,
          peerName: peerName,
          files: files,
          pin: pin
        });
        const handler = this.incomingSessionHandler;
        const accepted = handler !== undefined
          ? handler(peerName, files, pin)
          : this.promptIncomingConfirmation(peerName, files, pin);
        // 接受后登记一个仅用于聚合页传输卡片的接收任务（不重复弹窗/不影响接收）。
        return accepted.then((ok: boolean): boolean => {
          if (ok) {
            try {
              this.qsReceiveTotal = files.length;
              this.qsReceiveFiles = [];
              this.qsReceiveTaskId = this.transfer.trackIncoming('quickshare', key, peerName, files);
            } catch (error) {
              Lg.w('[QUICKSHARE] trackIncoming failed: ' + JSON.stringify(error));
            }
          }
          return ok;
        });
      },
      onFileReceived: async (file: IncomingFile): Promise<void> => {
        const taskId = this.qsReceiveTaskId;
        const peer = this.lastPeerName;
        const stagedPath: string = file.savedPath ?? '';
        let resolved: IncomingFile = file;

        // 先让动态照片链路决定归属，避免把动态照片的图片/视频半对拆成普通资产。
        const dynamicSelf: IncomingFileLike = {
          name: file.name,
          size: file.size,
          savedPath: stagedPath
        };
        const dynamicBatch: IncomingFileLike[] = this.qsReceiveFiles.map(
          (item: IncomingFile): IncomingFileLike => ({
            name: item.name,
            size: item.size,
            savedPath: item.savedPath ?? ''
          })
        );
        try {
          await DynamicPhotoService.settleReceivedFile(
            this.context, dynamicSelf, dynamicBatch.concat([dynamicSelf]), 'quickshare:' + taskId);
        } catch (error) {
          Lg.w('[DYNAMIC] settle (quickshare) failed: '
            + (error instanceof Error ? error.message : JSON.stringify(error)));
        }

        if (file.stagedForSave === true) {
          try {
            const processed = await GalleryAutoSaveService.processCompleted(
              this.context, stagedPath, file.name, file.size, true, file.mime ?? '');
            if (processed.finalPath.length > 0) {
              resolved = {
                name: file.name,
                size: file.size,
                savedPath: processed.finalPath,
                mime: file.mime,
                stagedForSave: true
              };
            }
            Lg.i('[GALLERY] quickshare handled=' + processed.handled
              + ' gallery=' + processed.savedToGallery
              + ' name=' + file.name
              + ' final=' + processed.finalPath
              + ' error=' + processed.error);
          } catch (error) {
            Lg.w('[GALLERY] quickshare save failed: '
              + (error instanceof Error ? error.message : JSON.stringify(error)));
          }
        }

        QuickShareTransferHistory.add(this.context, {
          id: 'rcv-' + Date.now() + '-' + resolved.name,
          name: resolved.name,
          size: resolved.size,
          direction: 'receive',
          peer: peer,
          completedAt: Date.now(),
          savedPath: resolved.savedPath ?? ''
        }).catch((): void => undefined);
        this.quickShareEvents.emit({
          kind: 'file',
          file: resolved,
          peer: peer
        });
        if (taskId.length > 0 && this.qsReceiveTaskId === taskId) {
          this.qsReceiveFiles = this.qsReceiveFiles.concat([resolved]);
          this.transfer.addReceivedFile(taskId, resolved);
        }
      },
      onProgress: (percent: number): void => {
        this.quickShareEvents.emit({
          kind: 'progress',
          percent: percent
        });
        if (this.qsReceiveTaskId.length > 0) {
          this.transfer.setTaskProgress(this.qsReceiveTaskId, percent);
          if (percent >= 100) {
            this.maybeCompleteQuickShareReceive();
          }
        }
      },
      onSessionFailed: (key: string, reason: string): void => {
        const task = this.transfer.getTask(this.qsReceiveTaskId);
        if (task !== undefined && task.gateKey === key) {
          this.qsReceiveTaskId = '';
          this.qsReceiveFiles = [];
          this.qsReceiveTotal = 0;
          this.transfer.finishTask(task.id, false, reason);
          this.quickShareEvents.emit({ kind: 'transport', detail: '接收失败：' + reason });
        }
      },
      onUpgradeAvailable: async (mediums: number[]): Promise<WifiDirectUpgradeCredentials | undefined> => {
        // 「仅局域网」模式：明确拒绝升级，且**不建组**（建了不用只会留残组）。
        if (SettingsStore.current().quickshareTransport === 'lan') {
          Lg.i('[QUICKSHARE] onUpgradeAvailable declined: transport mode=lan');
          return undefined;
        }
        const creds: P2pGroupCredentials | undefined = await this.startQuickShareWlanDirect();
        if (creds === undefined || creds.goIpAddress.length === 0) {
          Lg.i('[QUICKSHARE] onUpgradeAvailable declined: P2P group not ready');
          return undefined;
        }
        return {
          ssid: creds.groupName,
          password: creds.passphrase,
          port: GS_QUICKSHARE_PORT,
          gateway: creds.goIpAddress,
          frequency: creds.frequency
        };
      },
      // 介质变化（升级到 WLAN 直连成功/失败）——升级是静默的，透出到日志与页面状态栏。
      onTransportChange: (change: GsTransportChange): void => {
        Lg.i('[QUICKSHARE][P2P] transport=' + change.medium + ' upgraded=' + change.upgraded
          + ' detail=' + change.detail);
        this.quickShareEvents.emit({ kind: 'transport', detail: change.detail });
      }
    };
  }

  /** 全部文件接收完才完成卡片任务并弹「接收完成」弹窗，避免以空文件表提前完成。 */
  private maybeCompleteQuickShareReceive(): void {
    if (this.qsReceiveTaskId.length === 0 || this.qsReceiveTotal <= 0) {
      return;
    }
    if (this.qsReceiveFiles.length < this.qsReceiveTotal) {
      return;
    }
    const taskId = this.qsReceiveTaskId;
    const files = this.qsReceiveFiles;
    this.qsReceiveTaskId = '';
    this.transfer.finishTask(taskId, true);
    // 动态图片传输(Beta)：会话结束，给等待配对的动态图片最后一次机会。
    TransferManager.settleDynamicBatch(this.context, files, 'quickshare:' + taskId);
    this.showQuickShareReceiveCompletedDialog(files);
  }

  /** Quick Share 接收完成弹窗：单个文件提供「打开」，多文件仅「确认」。 */
  private showQuickShareReceiveCompletedDialog(files: IncomingFile[]): void {
    if (!PinDialogGuard.tryBegin()) {
      return;
    }
    const count = files.length;
    const names = files.map((f: IncomingFile): string => f.name).join('、');
    const message: Resource | string = count === 1
      ? $r('app.string.quick_share_receive_done_one', names)
      : count > 1
        ? $r('app.string.quick_share_receive_done_many', count, names)
        : $r('app.string.quick_share_receive_done_empty');
    const buttons: promptAction.Button[] = [];
    if (count === 1) {
      buttons.push({ text: '打开', color: HwColor.primary });
    }
    buttons.push({ text: '确认', color: HwColor.primary });
    promptAction.showDialog({
      systemMaterial: dialogSystemMaterial(),
      title: '接收完成',
      message: message,
      buttons: buttons
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      PinDialogGuard.end();
      const chosen = buttons[result.index]?.text ?? '';
      if (chosen === '打开') {
        const first: IncomingFile | undefined = files[0];
        if (first !== undefined && first.savedPath.length > 0) {
          this.openReceivedFile(first.savedPath);
        } else {
          promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '文件路径为空', duration: 2000 });
        }
      }
    }).catch((): void => {
      PinDialogGuard.end();
    });
  }

  /** 用系统查看器打开接收到的文件。 */
  private openReceivedFile(savedPath: string): void {
    try {
      const uri: string = savedPath.startsWith('file://') ? savedPath : fileUri.getUriFromPath(savedPath);
      this.context.startAbility({
        action: 'ohos.want.action.viewData',
        uri,
        flags: 1,
        parameters: { 'ohos.aafwk.param.bundleName': 'com.cashmere.link' }
      }).catch((error: BusinessError): void => {
        promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '无法打开：' + (error.message ?? ''), duration: 2000 });
      });
    } catch (error) {
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '无法打开文件', duration: 2000 });
    }
  }

  /** 页面未打开时的 Quick Share 接收确认弹窗，避免在任意位置接收时静默落盘。 */
  private promptIncomingConfirmation(peerName: string, files: SessionFileMeta[], pin: string): Promise<boolean> {
    if (!PinDialogGuard.tryBegin()) {
      return Promise.resolve(false);
    }
    const fileNames = files.map((file: SessionFileMeta): string => file.name).join('、');
    const pinPart = pin.length > 0 ? ' 双方 PIN：' + pin : '';
    const detail = fileNames.length > 0 ? '：' + fileNames : '';
    return promptAction.showDialog({
      systemMaterial: dialogSystemMaterial(),
      title: 'Quick Share 接收请求',
      message: `「${peerName}」想发送 ${files.length} 个文件${detail}。${pinPart}\n是否接收？`,
      buttons: [
        { text: '拒绝', color: HwColor.textSecondary },
        { text: '接收', color: HwColor.primary }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): boolean => {
      PinDialogGuard.end();
      return result.index === 1;
    }).catch((): boolean => {
      PinDialogGuard.end();
      return false;
    });
  }
}
