import { LogCapture as Lg } from '../common/LogCapture';
import { common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import promptAction from '@ohos.promptAction';
import { fileUri } from '@kit.CoreFileKit';
import { DeviceEndpoint, IncomingFile, SessionFileMeta } from '../model/TransferModels';
import { AppServices } from './AppServices';
import { PermissionHelper } from './PermissionHelper';
import { SettingsStore } from './SettingsStore';
import { PinDialogGuard } from './PinDialogGuard';
import { HwColor } from '../utils/DesignTokens';
import { getLocalIpv4 } from './NetAddress';
import { QuickShareBrowser, QuickSharePageEndpoint } from '../quickshare/controller/QuickShareBrowser';
import { createGsFacade, GsFacade } from '../protocol/gs/GsFacade';
import {
  WindowsNearbyBleController,
  WindowsNearbyDeviceListener,
  WindowsNearbyPeer
} from '../windowsnearby/WindowsNearbyBleController';
import {
  WindowsNearbyTransfer,
  WindowsNearbyTransferListener,
  WindowsNearbyIncomingFile
} from '../windowsnearby/WindowsNearbyTransfer';
import {
  WindowsNearbyHistory,
  WindowsNearbyHistoryEntry,
  WindowsNearbyLiveFile,
  WindowsNearbyLiveState,
  WINDOWS_NEARBY_LIVE_KEY
} from '../windowsnearby/WindowsNearbyHistory';
import {
  WindowsNearbySender,
  WindowsNearbySenderListener
} from '../windowsnearby/WindowsNearbySender';

// 蓝牙发现 / BLE 扫描所需用户授权权限，全局扫描启动时逐项申请。
const BLUETOOTH_AND_LOCATION_PERMISSIONS: Permissions[] = [
  'ohos.permission.ACCESS_BLUETOOTH',
  'ohos.permission.APPROXIMATELY_LOCATION',
  'ohos.permission.LOCATION'
];

type ChangeListener = () => void;

class HubWindowsListener extends WindowsNearbyDeviceListener {
  private readonly callback: (peer: WindowsNearbyPeer) => void;
  constructor(callback: (peer: WindowsNearbyPeer) => void) {
    super();
    this.callback = callback;
  }
  onPeerFound(peer: WindowsNearbyPeer): void {
    this.callback(peer);
  }
}

class HubWindowsSenderListener extends WindowsNearbySenderListener {
  private readonly onStatusCb: (text: string) => void;
  private readonly onCompleteCb: () => void;
  constructor(onStatusCb: (text: string) => void, onCompleteCb: () => void) {
    super();
    this.onStatusCb = onStatusCb;
    this.onCompleteCb = onCompleteCb;
  }
  onStatus(text: string): void {
    this.onStatusCb(text);
  }
  onCompleted(): void {
    this.onCompleteCb();
  }
}

class HubWindowsTransferListener extends WindowsNearbyTransferListener {
  private readonly onStatusCb: (text: string) => void;
  private readonly onConnectedCb: (peerName: string) => void;
  private readonly onDiscoveredCb: (peerName: string, ip: string) => void;
  private readonly onIncomingCb: (peerName: string, files: WindowsNearbyIncomingFile[]) => Promise<boolean>;
  private readonly onFileCb: (file: WindowsNearbyIncomingFile, savedPath: string) => void;
  private readonly onProgressCb: (percent: number) => void;
  private readonly onCompletedCb: () => void;

  constructor(
    onStatusCb: (text: string) => void,
    onConnectedCb: (peerName: string) => void,
    onDiscoveredCb: (peerName: string, ip: string) => void,
    onIncomingCb: (peerName: string, files: WindowsNearbyIncomingFile[]) => Promise<boolean>,
    onFileCb: (file: WindowsNearbyIncomingFile, savedPath: string) => void,
    onProgressCb: (percent: number) => void,
    onCompletedCb: () => void
  ) {
    super();
    this.onStatusCb = onStatusCb;
    this.onConnectedCb = onConnectedCb;
    this.onDiscoveredCb = onDiscoveredCb;
    this.onIncomingCb = onIncomingCb;
    this.onFileCb = onFileCb;
    this.onProgressCb = onProgressCb;
    this.onCompletedCb = onCompletedCb;
  }
  onStatus(text: string): void {
    this.onStatusCb(text);
  }
  onPeerConnected(peerName: string): void {
    this.onConnectedCb(peerName);
  }
  onPeerDiscovered(peerName: string, ip: string): void {
    this.onDiscoveredCb(peerName, ip);
  }
  onIncomingTransfer(peerName: string, files: WindowsNearbyIncomingFile[]): Promise<boolean> {
    return this.onIncomingCb(peerName, files);
  }
  onFileReceived(file: WindowsNearbyIncomingFile, savedPath: string): void {
    this.onFileCb(file, savedPath);
  }
  onProgress(percent: number): void {
    this.onProgressCb(percent);
  }
  onCompleted(): void {
    this.onCompletedCb();
  }
}

/**
 * 应用全局的「三协议仅接收扫描 + Windows 接收」枢纽。
 *
 * 聚合页此前只在「聚合」页签挂载时才启动扫描；本枢纽把该扫描（以及聚合页发送所需的
 * 浏览器 / 发送器实例）提升到应用进程生命周期，使 Quick Share、Windows Nearby、
 * LocalSend 三者的接收 / 可发现性在应用的任何位置都处于开启状态。Windows 的发现、接收、
 * 发送也由本枢纽独占，NearSharing 页改为消费枢纽状态而非自建扫描器 / 接收器（避免与全局
 * BLE 单例、TCP 5040 接收器重复绑定）。
 *
 * BLE 说明：HarmonyOS 的 BLE 扫描是全局单例（过滤器和 BLEDeviceFind 回调互相覆盖）。
 * 因此本枢纽只让 Windows Nearby 的 BLE 控制器独占 BLE 扫描，Quick Share 浏览器传
 * false 禁用其 BLE、改为纯 mDNS 发现（LAN TCP 发送），与聚合页原有策略一致。
 */
export class NearbyScanHub {
  private static instance?: NearbyScanHub;

  /** 供聚合页发送使用的 Quick Share 浏览器（含 mDNS 发现 + 广播）。 */
  browser?: QuickShareBrowser;
  /** 供聚合页发送使用的 Quick Share 会话门面。 */
  facade?: GsFacade;
  /** 供聚合页发送使用的 Windows Nearby 发送器。 */
  windowsSender?: WindowsNearbySender;
  /** 本机局域网 IPv4，用于 Quick Share 发送时的 sourceAddress。 */
  localIp: string = '';
  readonly appServices: AppServices;

  private readonly context: common.UIAbilityContext;
  private started = false;
  /** 是否已向系统申请过蓝牙/定位权限（仅申请一次，避免重复弹窗提示）。 */
  private permissionRequested = false;
  private readonly listeners: Set<ChangeListener> = new Set();
  private quickShareDevices: DeviceEndpoint[] = [];
  private windowsDevices: DeviceEndpoint[] = [];
  private localSendDevices: DeviceEndpoint[] = [];
  private windowsController?: WindowsNearbyBleController;
  private windowsTransfer?: WindowsNearbyTransfer;
  // Windows Nearby 接收状态：由全局枢纽独占，任何位置都能接收并展示。
  private windowsReceivePeer: string = '';
  private windowsReceiveProgress: number = 0;
  private windowsReceiveFiles: IncomingFile[] = [];
  private windowsReceiveCompleted: boolean = false;
  /** 当前 Windows Nearby 接收的卡片任务 id（用于聚合页卡片展示接收进度）。 */
  private windowsReceiveTaskId: string = '';
  private readonly windowsReceiveListeners: Set<ChangeListener> = new Set();

  private readonly localSendDeviceListener: (device: DeviceEndpoint) => void = (device: DeviceEndpoint): void => {
    if (device.protocol !== 'localsend') {
      return;
    }
    const index = this.localSendDevices.findIndex((item: DeviceEndpoint): boolean => item.id === device.id);
    if (index >= 0) {
      this.localSendDevices = this.localSendDevices.map((item: DeviceEndpoint, i: number): DeviceEndpoint => i === index ? device : item);
    } else {
      this.localSendDevices = this.localSendDevices.concat([device]);
    }
    this.notify();
  };

  private constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.appServices = AppServices.get(context);
  }

  static get(context: common.UIAbilityContext): NearbyScanHub {
    if (NearbyScanHub.instance === undefined) {
      NearbyScanHub.instance = new NearbyScanHub(context);
    }
    return NearbyScanHub.instance;
  }

  /** 返回新的（非引用）设备列表，供页面直接作为 @State 赋值。 */
  getQuickShareDevices(): DeviceEndpoint[] {
    return this.quickShareDevices.slice();
  }

  getWindowsDevices(): DeviceEndpoint[] {
    return this.windowsDevices.slice();
  }

  getLocalSendDevices(): DeviceEndpoint[] {
    return this.localSendDevices.slice();
  }

  setOnChange(listener: ChangeListener): void {
    this.listeners.add(listener);
  }

  removeOnChange(listener: ChangeListener): void {
    this.listeners.delete(listener);
  }

  getWindowsReceivePeer(): string {
    return this.windowsReceivePeer;
  }

  getWindowsReceiveProgress(): number {
    return this.windowsReceiveProgress;
  }

  getWindowsReceiveFiles(): IncomingFile[] {
    return this.windowsReceiveFiles.slice();
  }

  getWindowsReceiveCompleted(): boolean {
    return this.windowsReceiveCompleted;
  }

  setOnWindowsReceiveChange(listener: ChangeListener): void {
    this.windowsReceiveListeners.add(listener);
  }

  removeOnWindowsReceiveChange(listener: ChangeListener): void {
    this.windowsReceiveListeners.delete(listener);
  }

  /** 页面安全调用：已启动则什么都不做，否则启动全局扫描。 */
  ensureStarted(): void {
    this.start();
  }

  /**
   * 启动三协议接收扫描（应用进程生命周期常开）。非 BLE 部分（Quick Share mDNS、
   * Windows 发送器、LocalSend 扫描）立即启动；Windows BLE 扫描/广播 + Windows 接收器
   * 需要蓝牙 + 定位权限，留在 UI 就绪后由 ensureActive()（Index.onPageShow）申请权限并启动，
   * 避免冷启动时权限弹窗无法正常显示、广播失败。
   */
  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    // 启动期主线程减负：网络扫描/接收的初始化（同步枚举 IP、mDNS 构造与启动、注册监听）
    // 推迟到首帧之后执行，使应用一打开即可响应点击，而不是在首帧渲染与首次交互的关键
    // 窗口内被扫描初始化占用主线程。约一个事件循环后开始，设备只比原来晚一帧出现，无感知。
    setTimeout((): void => {
      this.doStart();
    }, 0);
  }

  private doStart(): void {
    // 防御：极少数情况下 stop() 可能发生在延迟启动触发前，若已停止则不再初始化。
    if (!this.started) {
      return;
    }
    this.localIp = getLocalIpv4();
    this.appServices.localsend.addListener(this.localSendDeviceListener);
    // 非 BLE 部分立即启动：Quick Share 浏览器（mDNS 发现 + 广播）、Windows 发送器、
    // LocalSend 扫描。各部分用 try/catch 隔离，避免一处失败拖垮其余。
    try {
      this.facade = createGsFacade('quickshare', this.context);
      this.browser = new QuickShareBrowser(this.context, false);
      this.browser.setOnChange((): void => this.syncQuickShare());
      this.browser.start();
    } catch (error) {
      Lg.w('[NEARBY-SCAN] Quick Share browser start failed: ' + JSON.stringify(error));
    }
    const senderListener = new HubWindowsSenderListener((text: string): void => {
      // 状态文本不再展示，忽略
    }, (): void => {
      // 发送完成，无需额外处理
    });
    WindowsNearbySender.create(this.context, senderListener).then((sender: WindowsNearbySender): void => {
      this.windowsSender = sender;
    }).catch((error: Error): void => {
      Lg.w('[NEARBY-SCAN] WindowsNearbySender.create failed: ' + error.message);
    });
    // LocalSend 扫描：等待首页接收/服务器就绪后开始。
    this.appServices.startReceive().then((): void => {
      this.appServices.startLocalSendScanning();
    }).catch((error: BusinessError): void => {
      Lg.w('[NEARBY-SCAN] LocalSend 扫描启动失败: ' + error.message);
    });
    // 不在此请求权限 / 启动 Windows BLE 与接收器：冷启动（onWindowStageCreate）时 UI 尚未
    // 就绪，权限弹窗可能无法正常显示。改由 Index.onPageShow → ensureActive() 在 UI 就绪后
    // 申请权限并启动 Windows BLE 扫描/广播 + Windows 接收器。
    Lg.i('[NEARBY-SCAN] global receive-only scan started (quickshare mDNS + windows BLE/receive + localsend)');
  }

  /** 启动 Windows Nearby 的 BLE 扫描/广播（需蓝牙 + 定位权限已就绪）。 */
  private startWindowsBle(): void {
    if (this.windowsController !== undefined) {
      return;
    }
    try {
      const windowsListener = new HubWindowsListener((peer: WindowsNearbyPeer): void => this.onWindowsPeer(peer));
      this.windowsController = new WindowsNearbyBleController(windowsListener);
      this.windowsController.start();
      Lg.i('[NEARBY-SCAN] Windows BLE scan/advertise started');
    } catch (error) {
      Lg.w('[NEARBY-SCAN] Windows BLE start failed: ' + JSON.stringify(error));
    }
  }

  /** 启动 Windows Nearby 接收器（TCP 5040 + UDP 发现/广播 + 蓝牙 RFCOMM 监听）。 */
  private startWindowsReceive(): void {
    if (this.windowsTransfer !== undefined) {
      return;
    }
    try {
      const listener = new HubWindowsTransferListener(
        (text: string): void => {
          Lg.i('[NEARBY-SCAN] Windows received status: ' + text);
        },
        (peerName: string): void => this.onWindowsConnected(peerName),
        (peerName: string, ip: string): void => this.onWindowsPeerIp(peerName, ip),
        (peerName: string, files: WindowsNearbyIncomingFile[]): Promise<boolean> => this.confirmWindowsIncoming(peerName, files),
        (file: WindowsNearbyIncomingFile, savedPath: string): void => this.onWindowsFileReceived(file, savedPath),
        (percent: number): void => this.onWindowsProgress(percent),
        (): void => this.onWindowsCompleted()
      );
      WindowsNearbyTransfer.create(this.context, listener).then((transfer: WindowsNearbyTransfer): void => {
        this.windowsTransfer = transfer;
        transfer.start().catch((error: Error): void => {
          Lg.w('[NEARBY-SCAN] WindowsNearbyTransfer.start failed: ' + error.message);
        });
      }).catch((error: Error): void => {
        Lg.w('[NEARBY-SCAN] WindowsNearbyTransfer.create failed: ' + error.message);
      });
    } catch (error) {
      Lg.w('[NEARBY-SCAN] Windows transfer start failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 重新断言全局扫描处于活动状态。
   *
   * 从独立的 QuickShare / NearSharing / LocalSend 页面返回时，这些页面会按自身逻辑启动并
   * 随后停止全局 BLE 扫描（BLE 是全局单例）或 LocalSend 扫描，导致本枢纽对应扫描被覆盖 /
   * 停止。本方法用 stop + start 重新注册 Windows BLE 扫描，并重启 LocalSend 扫描，恢复
   * 三协议仅接收扫描的「在任意位置常开」状态。
   */
  ensureActive(): void {
    if (!this.started) {
      return;
    }
    // 从独立的 QuickShare / NearSharing / LocalSend 页面返回时，这些页面会按自身逻辑停止
    // 全局 BLE 扫描（BLE 是全局单例）或 LocalSend 扫描，导致本枢纽对应扫描被覆盖 / 停止。
    // 这里 stop+start 重新注册 Windows BLE 扫描；若权限尚未授予、还没启动，则在此申请权限
    // 并启动（Index.onPageShow 时 UI 已就绪，权限弹窗能正常显示）。
    if (this.windowsController !== undefined) {
      this.windowsController.stop();
      this.windowsController.start();
      Lg.i('[NEARBY-SCAN] Windows BLE scan re-asserted');
    } else {
      this.requestPermissionAndStartWindows();
    }
    this.appServices.startLocalSendScanning();
    Lg.i('[NEARBY-SCAN] LocalSend scan re-asserted');
  }

  /** UI 就绪后申请蓝牙/定位权限（仅一次），再启动 Windows BLE 扫描/广播 + 接收器。 */
  private requestPermissionAndStartWindows(): void {
    if (!this.started) {
      return;
    }
    if (this.windowsController !== undefined && this.windowsTransfer !== undefined) {
      return;
    }
    if (!this.permissionRequested) {
      this.permissionRequested = true;
      PermissionHelper.ensure(this.context, BLUETOOTH_AND_LOCATION_PERMISSIONS).then((): void => {
        this.startWindowsComponents();
      }).catch((): void => {
        this.startWindowsComponents();
      });
    } else {
      // 已申请过（用户可能拒绝或仍未授权）：不重复弹窗，仅尝试启动（失败则静默）。
      this.startWindowsComponents();
    }
  }

  private async startWindowsComponents(): Promise<void> {
    // 冷启动竞态修复：SettingsStore.load() 是异步的，只有在 UI 加载完成后才把持久化的设置
    // 填入缓存。若在它完成之前就启动 BLE 广播，buildStableMac() 会读到空的 btMac 并伪造一个
    // 地址（如 48:55:41:57:45:49），Windows 只会“扫到”手机却无法按该地址走 RFCOMM 连入。
    // 这里先等设置加载完成，确保用真实蓝牙 MAC 广播。
    await SettingsStore.load(this.context);
    this.startWindowsBle();
    this.startWindowsReceive();
  }

  stop(): void {
    this.teardown(true);
  }

  /**
   * 重启三种协议的发现 / 广播 / 接收，效果对齐「杀掉应用重新打开」：
   *  1. 拆掉 Quick Share 浏览器（mDNS 发现 + 广播）、Windows BLE 扫描/广播与接收器、
   *     Windows 发送器、LocalSend 扫描；
   *  2. 重启接收侧（LocalSend HTTP(S) 服务端 + Quick Share 接收 + BLE medium）；
   *  3. 按冷启动顺序 start() → ensureActive() 重新拉起全部三协议。
   *
   * 与 stop() + start() 的区别：不清空页面注册的监听（设备变化 / Windows 接收状态），
   * 刷新期间无需重新挂载页面；也不会重复弹权限申请窗。
   */
  async restart(): Promise<void> {
    Lg.i('[NEARBY-SCAN] restart requested: 重启三协议广播（发现 + 广播 + 接收）');
    this.teardown(false);
    // 重启接收侧：端口与 BLE 资源释放后再重新绑定，避免刚 stop 就 bind 失败。
    await this.appServices.restartReceive();
    this.start();
    // start() 内部的 doStart 延后一拍执行，这里同样延后再断言 Windows BLE / 接收器，
    // 保持与冷启动（onWindowStageCreate → start，onPageShow → ensureActive）一致的顺序。
    setTimeout((): void => {
      this.ensureActive();
    }, 0);
    Lg.i('[NEARBY-SCAN] restart done');
  }

  /**
   * 拆除全部扫描/广播/接收器。
   * @param clearListeners 是否一并清空 Windows 接收状态监听（stop 为 true，restart 为 false）。
   */
  private teardown(clearListeners: boolean): void {
    if (!this.started) {
      return;
    }
    this.started = false;
    this.browser?.stop();
    this.browser = undefined;
    this.facade = undefined;
    this.windowsController?.stop();
    this.windowsController = undefined;
    this.windowsTransfer?.stop();
    this.windowsTransfer = undefined;
    this.windowsSender?.close().catch((): void => undefined);
    this.windowsSender = undefined;
    this.appServices.stopLocalSendScanning();
    this.appServices.localsend.removeListener(this.localSendDeviceListener);
    this.quickShareDevices = [];
    this.windowsDevices = [];
    this.localSendDevices = [];
    this.windowsReceivePeer = '';
    this.windowsReceiveProgress = 0;
    this.windowsReceiveFiles = [];
    this.windowsReceiveCompleted = false;
    if (clearListeners) {
      this.windowsReceiveListeners.clear();
    }
    this.notify();
    Lg.i('[NEARBY-SCAN] global receive-only scan stopped');
  }

  /** 设备发现变化的通知：用一个非拥塞的脏标记合并同一事件循环内的多次通知，避免扫描
   *  回调在短时间内密集触发时让页面反复重建设备卡片列表、持续占用主线程。合并用
   *  setTimeout(0)，最多回到下一事件循环触发一次；页面读取的是通知那一刻的最新状态，
   *  不会丢数据。 */
  private notifyScheduled: boolean = false;

  private notify(): void {
    if (this.notifyScheduled) {
      return;
    }
    this.notifyScheduled = true;
    setTimeout((): void => {
      this.notifyScheduled = false;
      this.flushNotify();
    }, 0);
  }

  private flushNotify(): void {
    this.listeners.forEach((listener: ChangeListener): void => listener());
  }

  private notifyWindowsReceive(): void {
    this.windowsReceiveListeners.forEach((listener: ChangeListener): void => listener());
  }

  private onWindowsConnected(peerName: string): void {
    this.windowsReceivePeer = peerName;
    this.publishWindowsLive();
    this.notifyWindowsReceive();
  }

  /** Windows 发送方发起会话：弹确认框，用户接受才继续接收并记录会话。 */
  private confirmWindowsIncoming(peerName: string, files: WindowsNearbyIncomingFile[]): Promise<boolean> {
    if (!PinDialogGuard.tryBegin()) {
      return Promise.resolve(false);
    }
    const fileNames = files.map((file: WindowsNearbyIncomingFile): string => file.name).join('、');
    const detail = fileNames.length > 0 ? '：' + fileNames : '';
    return promptAction.showDialog({
      title: 'Windows Nearby 接收请求',
      message: `「${peerName}」想发送 ${files.length} 个文件${detail}。\n是否接收？`,
      buttons: [
        { text: '拒绝', color: HwColor.textSecondary },
        { text: '接收', color: HwColor.primary }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): boolean => {
      PinDialogGuard.end();
      const accepted = result.index === 1;
      if (accepted) {
        this.windowsReceivePeer = peerName;
        this.windowsReceiveProgress = 0;
        this.windowsReceiveFiles = [];
        this.windowsReceiveCompleted = false;
        this.publishWindowsLive();
        this.notifyWindowsReceive();
        // 登记一个仅用于聚合页传输卡片的接收任务（不重复弹窗/不影响接收）。
        try {
          const metas: SessionFileMeta[] = files.map((f: WindowsNearbyIncomingFile): SessionFileMeta => ({
            id: f.name + ':' + f.size,
            name: f.name,
            size: f.size,
            mime: 'application/octet-stream'
          }));
          this.windowsReceiveTaskId = this.appServices.transfer.trackIncoming('windowsnearby',
            'win-' + Date.now(), peerName, metas);
        } catch (error) {
          Lg.w('[NEARBY-SCAN] trackIncoming failed: ' + JSON.stringify(error));
        }
      }
      return accepted;
    }).catch((): boolean => {
      PinDialogGuard.end();
      return false;
    });
  }

  private onWindowsFileReceived(file: WindowsNearbyIncomingFile, savedPath: string): void {
    const incoming: IncomingFile = {
      name: file.name,
      size: file.size,
      savedPath: savedPath
    };
    this.windowsReceiveFiles = this.windowsReceiveFiles.concat([incoming]);
    const entry: WindowsNearbyHistoryEntry = {
      id: savedPath + ':' + file.name + ':' + Date.now(),
      name: file.name,
      size: file.size,
      direction: 'receive',
      peer: this.windowsReceivePeer.length > 0 ? this.windowsReceivePeer : 'Windows',
      completedAt: Date.now(),
      savedPath: savedPath
    };
    WindowsNearbyHistory.add(this.context, entry).catch((): void => undefined);
    this.publishWindowsLive();
    this.notifyWindowsReceive();
    if (this.windowsReceiveTaskId.length > 0) {
      this.appServices.transfer.addReceivedFile(this.windowsReceiveTaskId, incoming);
    }
  }

  private onWindowsProgress(percent: number): void {
    this.windowsReceiveProgress = percent;
    this.publishWindowsLive();
    this.notifyWindowsReceive();
    if (this.windowsReceiveTaskId.length > 0) {
      this.appServices.transfer.setTaskProgress(this.windowsReceiveTaskId, percent);
    }
  }

  private onWindowsCompleted(): void {
    this.windowsReceiveProgress = 100;
    this.windowsReceiveCompleted = true;
    this.publishWindowsLive();
    this.notifyWindowsReceive();
    if (this.windowsReceiveTaskId.length > 0) {
      this.appServices.transfer.finishTask(this.windowsReceiveTaskId, true);
      this.windowsReceiveTaskId = '';
    }
    // 会话结束立即重发 BLE 广播，确保下一次 Windows 会话开始时手机可被发现
    // （避免「完成一次传输后第二次搜不到」——广播可能在会话/页面流转中被停掉）。
    this.windowsController?.reassertAdvertisement();
    this.showWindowsReceiveCompletedDialog();
  }

  /**
   * 所有文件接收完成后的提醒弹窗。
   *
   * - 只有一个文件：提供「打开」，直接调起系统查看器；「确认」仅关闭弹窗（不跳转，
   *   避免重复压入首页实例）。
   * - 多个文件：打开多个文件的行为不明确，按需求不显示「打开」按钮，仅「确认」关闭弹窗。
   */
  private showWindowsReceiveCompletedDialog(): void {
    if (!PinDialogGuard.tryBegin()) {
      return;
    }
    const files = this.windowsReceiveFiles;
    const count = files.length;
    const names = files.map((file: IncomingFile): string => file.name).join('、');
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
          this.openWindowsReceivedFile(first.savedPath);
        } else {
          promptAction.showToast({ message: '文件路径为空', duration: 2000 });
        }
      } else {
        // 确认：仅关闭弹窗，不做任何跳转。此前这里 pushUrl('pages/Index') 会在已有
        // 首页之上再压一个首页实例（日志里 page[2]/page[3] 重复压栈），还触发一轮
        // BLE stop/start 重断言。接收记录已写入历史，用户可随时自行查看。
      }
    }).catch((): void => {
      PinDialogGuard.end();
    });
  }

  /** 直接打开接收到的文件（复用现有「打开」逻辑，调起系统查看器）。 */
  private openWindowsReceivedFile(savedPath: string): void {
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

  /** 把当前 Windows 接收状态写入 AppStorage，供首页「Windows Nearby 传输」卡片展示。 */
  private publishWindowsLive(): void {
    const fileArr: WindowsNearbyLiveFile[] = this.windowsReceiveFiles.map((f: IncomingFile): WindowsNearbyLiveFile => ({
      name: f.name,
      size: f.size,
      savedPath: f.savedPath
    }));
    const live: WindowsNearbyLiveState = {
      peer: this.windowsReceivePeer,
      percent: this.windowsReceiveProgress,
      completed: this.windowsReceiveCompleted || this.windowsReceiveProgress >= 100,
      files: fileArr
    };
    AppStorage.setOrCreate(WINDOWS_NEARBY_LIVE_KEY, JSON.stringify(live));
  }

  private syncQuickShare(): void {
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
    const freshById: Map<string, DeviceEndpoint> = new Map();
    for (const endpoint of discovered) {
      freshById.set(endpoint.id, endpoint);
    }
    const merged: DeviceEndpoint[] = [];
    const seenIds: Set<string> = new Set();
    for (const existing of this.quickShareDevices) {
      const update: DeviceEndpoint | undefined = freshById.get(existing.id);
      if (update !== undefined) {
        merged.push(update);
        seenIds.add(update.id);
      }
    }
    for (const endpoint of discovered) {
      if (!seenIds.has(endpoint.id)) {
        merged.push(endpoint);
        seenIds.add(endpoint.id);
      }
    }
    this.quickShareDevices = merged;
    this.notify();
  }

  private onWindowsPeer(peer: WindowsNearbyPeer): void {
    // 仅发送模式：BLE 阶段只探测周边是否存在 Windows Nearby 设备，不在此创建展示项。
    // BLE 广播多携带占位名（"Windows 设备"）或空名，且与 UDP Presence 返回的真实名
    // 无法可靠对齐，若在此上屏会产生重复 / 占位卡片。改为等 UDP 握手（Presence）拿到
    // 真实名称与 IP 后再由 onWindowsPeerIp 创建展示项。
    Lg.i('[NEARBY-SCAN] Windows BLE 探测到近旁设备：' + peer.deviceId.substring(0, 6));
  }

  /** UDP Presence 握手成功：拿到对端真实名称与 IP，此时才上屏。 */
  private onWindowsPeerIp(peer: string, ip: string): void {
    const idx = this.windowsDevices.findIndex((item: DeviceEndpoint): boolean =>
      item.protocol === 'windowsnearby' && item.address === ip);
    const device: DeviceEndpoint = {
      id: 'windowsnearby:' + ip,
      name: peer,
      model: 'Windows Nearby',
      protocol: 'windowsnearby',
      address: ip,
      port: 5040,
      https: true,
      fingerprint: ip,
      source: 'lan',
      sessionHint: ''
    };
    if (idx >= 0) {
      // 同一 IP 已上屏（可能为历史空名）：名称为空才覆盖，避免覆盖已确认信息。
      const existing: DeviceEndpoint = this.windowsDevices[idx];
      if (existing.name.length === 0) {
        this.windowsDevices = this.windowsDevices.map((item: DeviceEndpoint, i: number): DeviceEndpoint =>
          i === idx ? device : item);
      }
    } else {
      this.windowsDevices = this.windowsDevices.concat([device]);
    }
    this.notify();
  }
}
