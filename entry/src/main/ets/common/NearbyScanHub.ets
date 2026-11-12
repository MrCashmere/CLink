import { LogCapture as Lg } from '../common/LogCapture';
import { common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import promptAction from '@ohos.promptAction';
import { fileUri } from '@kit.CoreFileKit';
import { DeviceEndpoint, IncomingFile, SessionFileMeta } from '../model/TransferModels';
import { AppServices } from './AppServices';
import { PermissionHelper } from './PermissionHelper';
import { SettingsStore } from './SettingsStore';
import { DynamicPhotoService } from './DynamicPhotoService';
import { IncomingFileLike } from './DynamicPhotoService';
import { TransferManager } from '../service/TransferManager';
import { PinDialogGuard } from './PinDialogGuard';
import { HwColor } from '../utils/DesignTokens';
import { getLocalIpv4 } from './NetAddress';
import { GalleryAutoSaveService } from '../quickshare/service/GalleryAutoSaveService';
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
import { toastSystemMaterial, dialogSystemMaterial } from '../utils/SystemMaterial';
import { MtaService } from '../mta/MtaService';

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
  private readonly onFileCb: (file: WindowsNearbyIncomingFile, savedPath: string) => Promise<void>;
  private readonly onProgressCb: (percent: number) => void;
  private readonly onCompletedCb: () => void;
  private readonly onFailedCb: (reason: string) => void;

  constructor(
    onStatusCb: (text: string) => void,
    onConnectedCb: (peerName: string) => void,
    onDiscoveredCb: (peerName: string, ip: string) => void,
    onIncomingCb: (peerName: string, files: WindowsNearbyIncomingFile[]) => Promise<boolean>,
    onFileCb: (file: WindowsNearbyIncomingFile, savedPath: string) => Promise<void>,
    onProgressCb: (percent: number) => void,
    onCompletedCb: () => void,
    onFailedCb: (reason: string) => void
  ) {
    super();
    this.onStatusCb = onStatusCb;
    this.onConnectedCb = onConnectedCb;
    this.onDiscoveredCb = onDiscoveredCb;
    this.onIncomingCb = onIncomingCb;
    this.onFileCb = onFileCb;
    this.onProgressCb = onProgressCb;
    this.onCompletedCb = onCompletedCb;
    this.onFailedCb = onFailedCb;
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
  onFailed(reason: string): void {
    this.onFailedCb(reason);
  }
  onFileReceived(file: WindowsNearbyIncomingFile, savedPath: string): Promise<void> {
    return this.onFileCb(file, savedPath);
  }
  onProgress(percent: number): void {
    this.onProgressCb(percent);
  }
  onCompleted(): void {
    this.onCompletedCb();
  }
}

/**
 * 应用全局的多协议扫描与接收枢纽，MTA 作为独立服务叠加。
 *
 * 聚合页此前只在「聚合」页签挂载时才启动扫描；本枢纽把该扫描（以及聚合页发送所需的
 * 浏览器 / 发送器实例）提升到应用进程生命周期，使 Quick Share、Windows Nearby、
 * LocalSend 三者的接收 / 可发现性在应用的任何位置都处于开启状态。Windows 的发现、接收、
 * 发送也由本枢纽独占，NearSharing 页改为消费枢纽状态而非自建扫描器 / 接收器（避免与全局
 * BLE 单例、TCP 5040 接收器重复绑定）。
 *
 * BLE 说明：HarmonyOS 的 BLE 扫描是共享资源，Windows/MTA 等扫描器由扫描租约合并调度。
 * Quick Share 浏览器继续保留聚合页原有的纯 mDNS 策略（false），独立页的 BLE 扫描也消费租约。
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
  mta?: MtaService;

  private readonly context: common.UIAbilityContext;
  private started = false;
  private generation: number = 0;
  private windowsReceiveStart?: Promise<void>;
  private windowsSenderStart?: Promise<void>;
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

  getMtaDevices(): DeviceEndpoint[] { return this.mta?.enabled() === true ? this.mta.devices() : []; }

  private startMta(): void {
    try {
      if (this.mta === undefined) {
        this.mta = MtaService.get(this.context);
        this.mta.addListener((): void => this.notify());
      }
      this.mta.start();
    } catch (error) { Lg.w('[MTA] 初始化失败：' + String(error)); }
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
    const generation = ++this.generation;
    // 启动期主线程减负：网络扫描/接收的初始化（同步枚举 IP、mDNS 构造与启动、注册监听）
    // 推迟到首帧之后执行，使应用一打开即可响应点击，而不是在首帧渲染与首次交互的关键
    // 窗口内被扫描初始化占用主线程。约一个事件循环后开始，设备只比原来晚一帧出现，无感知。
    setTimeout((): void => {
      if (this.isCurrent(generation)) { this.doStart(generation); }
    }, 0);
  }

  private isCurrent(generation: number): boolean {
    return this.started && generation === this.generation;
  }

  private doStart(generation: number): void {
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
      // 绝不能建第二个浏览器：start() 的延迟启动与 restart() 交叠时 doStart 会被调度两次，
      // 而旧实例既不会再被 stop()，它注册在系统 mdns 守护进程里的广播也不会被移除——
      // 本机设备列表于是堆出一大堆自己的「羊绒互传」（实测 20 次启动只有 4 次停止）。
      if (this.browser === undefined) {
        this.browser = new QuickShareBrowser(this.context, false);
        this.browser.setOnChange((): void => this.syncQuickShare());
        this.browser.start();
      } else {
        Lg.i('[NEARBY-SCAN] Quick Share browser already running, reusing it');
      }
    } catch (error) {
      Lg.w('[NEARBY-SCAN] Quick Share browser start failed: ' + JSON.stringify(error));
    }
    this.startWindowsSender();
    // LocalSend 扫描：等待首页接收/服务器就绪后开始。
    this.appServices.startReceive().then((): void => {
      if (this.isCurrent(generation)) { this.appServices.startLocalSendScanning(); }
    }).catch((error: BusinessError): void => {
      Lg.w('[NEARBY-SCAN] LocalSend 扫描启动失败: ' + error.message);
    });
    // 不在此请求权限 / 启动 Windows BLE 与接收器：冷启动（onWindowStageCreate）时 UI 尚未
    // 就绪，权限弹窗可能无法正常显示。改由 Index.onPageShow → ensureActive() 在 UI 就绪后
    // 申请权限并启动 Windows BLE 扫描/广播 + Windows 接收器。
    Lg.i('[NEARBY-SCAN] global receive-only scan started (quickshare mDNS + windows BLE/receive + localsend)');
  }

  private startWindowsSender(): void {
    if (!this.started || this.windowsSender !== undefined || this.windowsSenderStart !== undefined) { return; }
    const generation = this.generation;
    const listener = new HubWindowsSenderListener((): void => {}, (): void => {});
    this.windowsSenderStart = WindowsNearbySender.create(this.context, listener).then(async (sender: WindowsNearbySender): Promise<void> => {
      if (!this.isCurrent(generation)) { await sender.close(); return; }
      this.windowsSender = sender;
    }).catch((error: Error): void => {
      Lg.w('[NEARBY-SCAN] Windows sender start: ' + error.message);
    }).finally((): void => {
      this.windowsSenderStart = undefined;
      if (this.started && generation !== this.generation) { this.startWindowsSender(); }
    });
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
    if (!this.started || this.windowsTransfer !== undefined || this.windowsReceiveStart !== undefined) {
      return;
    }
    const generation = this.generation;
    let receiver: WindowsNearbyTransfer | undefined = undefined;
    const current = (): boolean => this.isCurrent(generation) && receiver !== undefined && this.windowsTransfer === receiver;
    try {
      const listener = new HubWindowsTransferListener(
        (text: string): void => {
          Lg.i('[NEARBY-SCAN] Windows received status: ' + text);
        },
        (peerName: string): void => { if (current()) { this.onWindowsConnected(peerName); } },
        (peerName: string, ip: string): void => { if (current()) { this.onWindowsPeerIp(peerName, ip); } },
        (peerName: string, files: WindowsNearbyIncomingFile[]): Promise<boolean> => {
          if (!current() || receiver === undefined) { return Promise.resolve(false); }
          const sessionValid = receiver.captureSessionValidity();
          return this.confirmWindowsIncoming(peerName, files, (): boolean => current() && sessionValid());
        },
        (file: WindowsNearbyIncomingFile, savedPath: string): Promise<void> => {
          if (!current() || receiver === undefined) { return Promise.resolve(); }
          const sessionValid = receiver.captureSessionValidity();
          return this.onWindowsFileReceived(file, savedPath, (): boolean => current() && sessionValid());
        },
        (percent: number): void => { if (current()) { this.onWindowsProgress(percent); } },
        (): void => { if (current()) { this.onWindowsCompleted(); } },
        (reason: string): void => {
          if (!current()) { return; }
          if (this.windowsReceiveTaskId.length > 0) {
            this.appServices.transfer.finishTask(this.windowsReceiveTaskId, false, reason);
            this.windowsReceiveTaskId = '';
            this.publishWindowsLive();
            this.notifyWindowsReceive();
          }
        }
      );
      this.windowsReceiveStart = WindowsNearbyTransfer.create(this.context, listener).then(async (transfer: WindowsNearbyTransfer): Promise<void> => {
        receiver = transfer;
        if (!this.isCurrent(generation)) { transfer.stop(); return; }
        this.windowsTransfer = transfer;
        try {
          await transfer.start();
          if (!current()) { transfer.stop(); }
        } catch (error) {
          transfer.stop();
          if (this.windowsTransfer === transfer) { this.windowsTransfer = undefined; }
          throw error as Error;
        }
      }).catch((error: Error): void => {
        Lg.w('[NEARBY-SCAN] Windows receiver start: ' + error.message);
      }).finally((): void => {
        this.windowsReceiveStart = undefined;
        if (this.started && generation !== this.generation) { this.startWindowsReceive(); }
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
    this.startWindowsSender();
    if (this.windowsController !== undefined) { this.startWindowsReceive(); }
    this.appServices.startLocalSendScanning();
    Lg.i('[NEARBY-SCAN] LocalSend scan re-asserted');
    this.startMta();
  }

  /** UI 就绪后申请蓝牙/定位权限（仅一次），再启动 Windows BLE 扫描/广播 + 接收器。 */
  private requestPermissionAndStartWindows(): void {
    const generation = this.generation;
    if (!this.started) {
      return;
    }
    if (this.windowsController !== undefined && this.windowsTransfer !== undefined) {
      return;
    }
    if (!this.permissionRequested) {
      this.permissionRequested = true;
      PermissionHelper.ensure(this.context, BLUETOOTH_AND_LOCATION_PERMISSIONS).then((): void => {
        this.startWindowsComponents(generation).catch((error: Error): void => Lg.w('[NEARBY-SCAN] start components: ' + error.message));
      }).catch((): void => {
        this.startWindowsComponents(generation).catch((error: Error): void => Lg.w('[NEARBY-SCAN] start components: ' + error.message));
      });
    } else {
      // 已申请过（用户可能拒绝或仍未授权）：不重复弹窗，仅尝试启动（失败则静默）。
      this.startWindowsComponents(generation).catch((error: Error): void => Lg.w('[NEARBY-SCAN] start components: ' + error.message));
    }
  }

  private async startWindowsComponents(generation: number): Promise<void> {
    // 冷启动竞态修复：SettingsStore.load() 是异步的，只有在 UI 加载完成后才把持久化的设置
    // 填入缓存。若在它完成之前就启动 BLE 广播，buildStableMac() 会读到空的 btMac 并伪造一个
    // 占位地址，Windows 只会“扫到”手机却无法按该地址走 RFCOMM 连入。
    // 这里先等设置加载完成，确保用真实蓝牙 MAC 广播。
    await SettingsStore.load(this.context);
    if (!this.isCurrent(generation)) { return; }
    this.startWindowsBle();
    this.startWindowsReceive();
    this.startMta();
  }

  stop(): void {
    this.teardown(true);
  }

  /** 只重启发现与广播；收发连接、接收监听和待确认会话保持原生命周期。 */
  async restart(): Promise<void> {
    if (!this.started) { this.start(); this.ensureActive(); return; }
    this.browser?.stop();
    this.browser?.start();
    this.windowsController?.stop();
    this.windowsController?.start();
    this.appServices.stopLocalSendScanning();
    this.appServices.startLocalSendScanning();
    this.mta?.refreshDiscovery();
    this.startWindowsSender();
    this.requestPermissionAndStartWindows();
    Lg.i('[NEARBY-SCAN] discovery/advertising restarted; transfers retained');
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
    this.generation += 1;
    if (this.windowsReceiveTaskId.length > 0) {
      this.appServices.transfer.finishTask(this.windowsReceiveTaskId, false, 'Windows 接收服务已停止');
      this.windowsReceiveTaskId = '';
    }
    this.mta?.stop().catch((error: Error): void => Lg.w('[MTA] stop: ' + error.message));
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
  private confirmWindowsIncoming(peerName: string, files: WindowsNearbyIncomingFile[], isCurrent: () => boolean): Promise<boolean> {
    if (!isCurrent() || !PinDialogGuard.tryBegin()) {
      return Promise.resolve(false);
    }
    const fileNames = files.map((file: WindowsNearbyIncomingFile): string => file.name).join('、');
    const detail = fileNames.length > 0 ? '：' + fileNames : '';
    return promptAction.showDialog({
      systemMaterial: dialogSystemMaterial(),
      title: 'Windows Nearby 接收请求',
      message: `「${peerName}」想发送 ${files.length} 个文件${detail}。\n是否接收？`,
      buttons: [
        { text: '拒绝', color: HwColor.textSecondary },
        { text: '接收', color: HwColor.primary }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): boolean => {
      PinDialogGuard.end();
      if (!isCurrent()) { return false; }
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

  private async onWindowsFileReceived(file: WindowsNearbyIncomingFile,
    savedPath: string, isCurrent: () => boolean): Promise<void> {
    if (!isCurrent()) { return; }
    const taskId = this.windowsReceiveTaskId;
    const peer = this.windowsReceivePeer;
    const incoming: IncomingFile = {
      name: file.name,
      size: file.size,
      savedPath: savedPath
    };
    let resolved: IncomingFile = incoming;

    // 先跑动态照片归属判断；动态照片占用时普通图库管线必须让路。
    const dynamicSelf: IncomingFileLike = {
      name: incoming.name,
      size: incoming.size,
      savedPath: incoming.savedPath ?? ''
    };
    const dynamicBatch: IncomingFileLike[] =
      this.windowsReceiveFiles.concat([incoming]).map(
        (item: IncomingFile): IncomingFileLike => ({
          name: item.name,
          size: item.size,
          savedPath: item.savedPath ?? ''
        })
      );
    try {
      await DynamicPhotoService.settleReceivedFile(this.context, dynamicSelf, dynamicBatch, 'windowsnearby:' + taskId);
    } catch (error) {
      Lg.w('[DYNAMIC] settle (windowsnearby) failed: '
        + (error instanceof Error ? error.message : JSON.stringify(error)));
    }

    if (!isCurrent()) { return; }
    if (GalleryAutoSaveService.isSandboxPath(this.context, savedPath)) {
      try {
        const processed = await GalleryAutoSaveService.processCompleted(
          this.context, savedPath, file.name, file.size, true);
        if (processed.finalPath.length > 0) {
          resolved = {
            name: file.name,
            size: file.size,
            savedPath: processed.finalPath
          };
        }
        Lg.i('[GALLERY] windowsnearby handled=' + processed.handled
          + ' gallery=' + processed.savedToGallery
          + ' name=' + file.name
          + ' final=' + processed.finalPath
          + ' error=' + processed.error);
      } catch (error) {
        Lg.w('[GALLERY] windowsnearby save failed: '
          + (error instanceof Error ? error.message : JSON.stringify(error)));
      }
    }

    if (!isCurrent() || this.windowsReceiveTaskId !== taskId) { return; }
    this.windowsReceiveFiles = this.windowsReceiveFiles.concat([resolved]);
    const entry: WindowsNearbyHistoryEntry = {
      id: resolved.savedPath + ':' + resolved.name + ':' + Date.now(),
      name: resolved.name,
      size: resolved.size,
      direction: 'receive',
      peer: peer.length > 0 ? peer : 'Windows',
      completedAt: Date.now(),
      savedPath: resolved.savedPath
    };
    WindowsNearbyHistory.add(this.context, entry).catch((): void => undefined);
    this.publishWindowsLive();
    this.notifyWindowsReceive();
    if (taskId.length > 0) {
      this.appServices.transfer.addReceivedFile(taskId, resolved);
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
    const taskId = this.windowsReceiveTaskId;
    this.windowsReceiveProgress = 100;
    this.windowsReceiveCompleted = true;
    this.publishWindowsLive();
    this.notifyWindowsReceive();
    if (this.windowsReceiveTaskId.length > 0) {
      this.appServices.transfer.finishTask(this.windowsReceiveTaskId, true);
      this.windowsReceiveTaskId = '';
    }
    // 动态图片传输(Beta)：会话结束，给等待配对的动态图片最后一次机会。
    TransferManager.settleDynamicBatch(this.context, this.windowsReceiveFiles, 'windowsnearby:' + taskId);
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
          this.openWindowsReceivedFile(first.savedPath);
        } else {
          promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '文件路径为空', duration: 2000 });
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
        promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '无法打开：' + (error.message ?? ''), duration: 2000 });
      });
    } catch (error) {
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '无法打开文件', duration: 2000 });
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
