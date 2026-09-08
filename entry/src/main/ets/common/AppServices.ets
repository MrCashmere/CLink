import { LogCapture as Lg } from '../common/LogCapture';
import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { fileUri } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import promptAction from '@ohos.promptAction';
import { CertificateStore } from './CertificateStore';
import { SettingsStore } from './SettingsStore';
import { DeviceIdentity } from './DeviceIdentity';
import { PinDialogGuard } from './PinDialogGuard';
import { getLocalIpv4 } from './NetAddress';
import { HwColor } from '../utils/DesignTokens';
import { LocalSendDiscovery } from '../service/LocalSendDiscovery';
import { TransferManager } from '../service/TransferManager';
import { LocalSendServer } from '../protocol/localsend/LocalSendServer';
import { createGsFacade, GsFacade, GsReceiveHooks, GS_QUICKSHARE_PORT, WifiDirectUpgradeCredentials } from '../protocol/gs/GsFacade';
import { IncomingFile, SessionFileMeta } from '../model/TransferModels';
import { QuickShareEventEmitter, QuickShareServiceEvent, IncomingSessionHandler } from '../quickshare/utils/EventEmitter';
import { QuickShareTransferHistory } from '../quickshare/storage/TransferHistory';
import { NearbyBleMedium } from '../quickshare/discovery/NearbyBleMedium';
import { NearbyP2pDirect, P2pGroupCredentials } from '../quickshare/ble/NearbyP2pDirect';
import { SecurityUtils } from './SecurityUtils';
import { GsStreamConnection } from '../protocol/gs/GsFacade';

export interface LocalsendWebLinkInfo {
  readonly address: string;
  readonly port: number;
  readonly scheme: string;
}

export class AppServices {
  private static instance?: AppServices;
  readonly certs: CertificateStore;
  readonly localsend: LocalSendDiscovery;
  readonly transfer: TransferManager;
  /** App 级 Quick Share 接收事件总线：页面 open 时订阅，close 只退订不断开监听。 */
  readonly quickShareEvents: QuickShareEventEmitter<QuickShareServiceEvent> = new QuickShareEventEmitter<QuickShareServiceEvent>();
  private running = false;
  private startPromise?: Promise<void>;
  private gsQuickshare?: GsFacade;
  private gsQuickshareReady = false;
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
  private lastPeerBleMac: string = '';
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
    if (this.running && this.gsQuickshareReady) {
      return;
    }
    if (this.startPromise !== undefined) {
      await this.startPromise;
      return;
    }
    const promise = this.doStartReceive();
    this.startPromise = promise;
    try {
      await promise;
    } finally {
      this.startPromise = undefined;
    }
  }

  private async doStartReceive(): Promise<void> {
    await SettingsStore.load(this.context);
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
    await this.certs.ensure();
    await this.refreshAliasFingerprint();
    if (!this.running) {
      await this.transfer.startServer();
      this.localsend.setHttps(LocalSendServer.lastHttpsActive);
      this.localsend.setPort(LocalSendServer.actualPort);
      this.running = true;
      this.localsend.startReceiveOnly();
    }
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

  /** 局域网网页传输：本机网页端服务运行的地址与端口（始终明文 HTTP，供浏览器访问）。 */
  localsendWebLink(): LocalsendWebLinkInfo {
    const address = this.localsend.getLocalAddress().length > 0
      ? this.localsend.getLocalAddress()
      : getLocalIpv4();
    return {
      address: address,
      port: LocalSendServer.actualWebPort,
      scheme: 'http'
    };
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
    await this.startQuickShareReceive();
    if (this.nearbyBleMedium !== undefined) {
      return;
    }
    if (this.gsQuickshare === undefined) {
      Lg.w('[QUICKSHARE] startQuickShareBle skipped: receiver not ready');
      return;
    }
    const medium = new NearbyBleMedium();
    medium.setOnSessionStart((deviceId: string): void => {
      this.lastPeerBleMac = deviceId;
      Lg.i('[QUICKSHARE] BLE session accepted from ' + deviceId + ' (cached for send)');
    });
    medium.setOnConnection((conn: GsStreamConnection): void => {
      if (this.gsQuickshare !== undefined) {
        this.gsQuickshare.runReceiveStream(conn, this.buildQuickShareHooks())
          .catch((error: Error): void => {
            Lg.w('[QUICKSHARE] BLE stream receiver failed: ' + error.message);
          });
      }
      // BLE socket 建立说明对端未能走 WIFI_LAN（TCP 失败后降级）：
      // 若开启「WLAN 直连优先模式」，随即建 Wi-Fi Direct 组供对端升级。
      if (SettingsStore.current().quickshareWlanDirect) {
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
    await medium.start(this.bleEndpointId, SettingsStore.current().alias);
    Lg.i('[QUICKSHARE] Quick Share BLE GATT socket active endpointId=' + this.bleEndpointId);
  }

  stopQuickShareBle(): void {
    this.nearbyBleMedium?.stop();
    this.nearbyBleMedium = undefined;
  }

  /** 最近一次经 BLE GATT 连入的对端 MAC；若对端未被 BLE 扫描发现，可用于 BLE 发送。 */
  lastPeerBleMacValue(): string {
    return this.lastPeerBleMac;
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
    if (!this.running) {
      return;
    }
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
    // 清掉进行中的启动 promise，避免复用到旧的启动结果。
    this.startPromise = undefined;
    this.quickShareStartPromise = undefined;
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

  /** 初始化本机 LocalSend 指纹：使用打包证书的 SHA-256 指纹（与 HTTPS 证书一致），便于对端做指纹识别。 */
  async refreshAliasFingerprint(): Promise<void> {
    const certFingerprint = await this.certs.fingerprint();
    const fingerprint = certFingerprint.length > 0 ? certFingerprint : await DeviceIdentity.load(this.context);
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
    if (this.gsQuickshareReady) {
      return;
    }
    if (this.quickShareStartPromise !== undefined) {
      await this.quickShareStartPromise;
      return;
    }
    const promise = this.doStartQuickShareReceive();
    this.quickShareStartPromise = promise;
    try {
      await promise;
    } finally {
      this.quickShareStartPromise = undefined;
    }
  }

  private async doStartQuickShareReceive(): Promise<void> {
    if (this.gsQuickshareReady) {
      return;
    }
    try {
      const facade = createGsFacade('quickshare', this.context);
      await facade.startReceive(GS_QUICKSHARE_PORT, this.buildQuickShareHooks(), '0.0.0.0');
      this.gsQuickshare = facade;
      this.gsQuickshareReady = true;
      Lg.i('[QUICKSHARE] AppServices listen ok port=' + GS_QUICKSHARE_PORT + ' bind=0.0.0.0');
    } catch (error) {
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
      onFileReceived: (file: IncomingFile): void => {
        QuickShareTransferHistory.add(this.context, {
          id: 'rcv-' + Date.now() + '-' + file.name,
          name: file.name,
          size: file.size,
          direction: 'receive',
          peer: this.lastPeerName,
          completedAt: Date.now(),
          savedPath: file.savedPath ?? ''
        }).catch((): void => undefined);
        this.quickShareEvents.emit({
          kind: 'file',
          file: file,
          peer: this.lastPeerName
        });
        if (this.qsReceiveTaskId.length > 0) {
          this.qsReceiveFiles = this.qsReceiveFiles.concat([file]);
          this.transfer.addReceivedFile(this.qsReceiveTaskId, file);
          this.maybeCompleteQuickShareReceive();
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
      onUpgradeAvailable: async (mediums: number[]): Promise<WifiDirectUpgradeCredentials | undefined> => {
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
    this.showQuickShareReceiveCompletedDialog(files);
  }

  /** Quick Share 接收完成弹窗：单个文件提供「打开」，多文件仅「确认」。 */
  private showQuickShareReceiveCompletedDialog(files: IncomingFile[]): void {
    if (!PinDialogGuard.tryBegin()) {
      return;
    }
    const count = files.length;
    const names = files.map((f: IncomingFile): string => f.name).join('、');
    const message = count === 1
      ? `已接收 1 个文件：${names}，已保存到应用目录。`
      : count > 1
        ? `已接收 ${count} 个文件：${names}，已保存到应用目录。`
        : '接收完成。';
    const buttons: promptAction.Button[] = [];
    if (count === 1) {
      buttons.push({ text: '打开', color: HwColor.primary });
    }
    buttons.push({ text: '确认', color: HwColor.primary });
    promptAction.showDialog({
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
          promptAction.showToast({ message: '文件路径为空', duration: 2000 });
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
        promptAction.showToast({ message: '无法打开：' + (error.message ?? ''), duration: 2000 });
      });
    } catch (error) {
      promptAction.showToast({ message: '无法打开文件', duration: 2000 });
    }
  }

  /** 页面未打开时的 Quick Share 接收确认弹窗，避免在任意位置接收时静默落盘。 */
  private promptIncomingConfirmation(peerName: string, files: SessionFileMeta[], pin: string): Promise<boolean> {
    if (!PinDialogGuard.tryBegin()) {
      return Promise.resolve(true);
    }
    const fileNames = files.map((file: SessionFileMeta): string => file.name).join('、');
    const pinPart = pin.length > 0 ? ' 双方 PIN：' + pin : '';
    const detail = fileNames.length > 0 ? '：' + fileNames : '';
    return promptAction.showDialog({
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
