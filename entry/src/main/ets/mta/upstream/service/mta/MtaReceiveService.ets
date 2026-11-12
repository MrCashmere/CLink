/**
 * MtaReceiveService.ets — MTA 接收端编排门面
 *
 * 串联 BLE 凭据通道、P2P 连接（p2pConnect）、WS 协商与 HTTPS 下载解压，维护接收端状态机
 * （ReceiverState），并以事件回调方式向 ViewModel 推送状态快照。
 * 所有系统调用失败均转为可读文本写入日志，不向页面抛出异常。
 */

import { common, bundleManager } from '@kit.AbilityKit';
import { fileIo as fs, fileUri, statfs } from '@kit.CoreFileKit';
import {
  DecryptedCredentials,
  DeviceInfoJson,
  DownloadProgress,
  MtaBleEventHandlers,
  MtaLinkTiming,
  MtaP2pEventHandlers,
  MtaReceiveEventHandlers,
  MtaTransferEventHandlers,
  P2pInfoJson,
  ReceiveServiceWarmState,
  ReceiverStage,
  ReceiverState,
  ReceiveRequest,
  WsHandshakeResult,
  buildMtaReceiveIdentityToken,
  buildWsHandshakeSummary,
  isReceiveServiceReusable,
  mayWriteRequestThumbnail,
  parseP2pInfo
} from '../../model/mta/MtaProtocolModels';
import { MtaConstants } from './MtaConstants';
import { bandLabelFromFrequency, isWeakBand } from '../../model/mta/MtaSendModels';
import { MtaCrypto } from './MtaCrypto';
import { MtaBleReceiver } from './MtaBleReceiver';
import {
  drainRustLog,
  enableBluetoothSystem,
  ensureBluetoothPermission,
  isBluetoothEnabled,
  queryBluetoothStateText,
  sleepMs,
  utf8ByteLength
} from './MtaBleCommon';
import { MtaP2pConnector, P2pConnectResult } from './MtaP2pConnector';
import { MtaTransferClient, DownloadResult } from './MtaTransferClient';
import { nativeMtaFetchThumbnail } from '../NativeBridge';
import { getLogger } from '../../utils/Logger';
import { getMimeForFileName, isImage, isMediaMime } from '../../utils/MimeUtils';
import { formatSizeDetailed } from '../../utils/FormatUtil';
import {
  StorageCheckVerdict, decideStorageCheck
} from '../../utils/StorageCheck';
import { LogDomains } from '../../common/LogDomains';
import { LogLevels } from '../../common/LogLevels';
import { MediaFileInfo, ReceiveHistoryEntry } from '../../model/Types';
import { MTA_SHARED_TEXT_FILE_NAME } from '../../model/mta/MtaMainModels';
import { MTA_BRAND_ID_THIRD_PARTY, resolveMtaBrandName } from '../../model/mta/MtaBrandRegistry';
import { isSaveToGallery, getMtaSimulatedBrand } from '../repository/SettingsRepository';
import { addEntries } from '../repository/ReceiveHistoryService';
import { uniquePath, recvTextDir } from '../repository/ReceiveTargets';
import { mtaReceiveDirectory, finalizeMtaReceivedFiles } from '../transfer/adapters/MtaReceiveAdapter';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaReceive', '互传接收');

// 文本落盘完成通知（由协议仓库注入）：把文本文件的真实保存路径上抛，
// 供统一会话回填逐文件路径（详情页据路径读取内容预览）。不参与协议行为。
let textSavedNotifier: ((savedPath: string) => void) | undefined = undefined;

/** 注册「文本已落盘（带路径）」通知入口；由协议仓库在装配阶段调用。 */
export function setMtaReceiveTextSavedNotifier(notifier: (savedPath: string) => void): void {
  textSavedNotifier = notifier;
}

/** 接收端服务编排门面 */
export class MtaReceiveService {
  /** 当前状态（对外仅暴露快照） */
  private state: ReceiverState = new ReceiverState();
  /** 事件回调（ViewModel 注入） */
  private handlers: MtaReceiveEventHandlers | null = null;
  /** 应用上下文（权限申请用） */
  private context: common.Context | undefined = undefined;
  /** 加解密模块 */
  private crypto: MtaCrypto = new MtaCrypto();
  /** BLE 接收模块（广播 + GATT Server） */
  private ble: MtaBleReceiver = new MtaBleReceiver();
  /** BLE 事件回调 */
  private bleHandlers: MtaBleEventHandlers = new MtaBleEventHandlers();
  /** P2P 连接模块 */
  private p2p: MtaP2pConnector = new MtaP2pConnector();
  /** P2P 事件回调 */
  private p2pHandlers: MtaP2pEventHandlers = new MtaP2pEventHandlers();
  /** 传输客户端（WS + 下载解压） */
  private transfer: MtaTransferClient = new MtaTransferClient();
  /** 传输客户端事件回调 */
  private transferHandlers: MtaTransferEventHandlers = new MtaTransferEventHandlers();
  /** 当前广播设备名（自动恢复时复用；取自设备昵称） */
  private deviceName: string = '';
  /** 当前广播使用的模拟品牌标识（默认第三方；用于身份变更判定与重播） */
  private mtaBrandId: number = MTA_BRAND_ID_THIRD_PARTY;
  /** 是否有会话正在处理（防止重复触发连接） */
  private sessionActive: boolean = false;
  private sessionGeneration: number = 0;
  private decisionTaken: boolean = false;
  /** 版本协商后等待接收请求的超时定时器（WS 无心跳，对端静默失联时兜底退出） */
  private requestWaitTimerId: number = -1;
  /** 等待用户确认接收的超时定时器（到期自动拒绝，避免被发送端单方拆链） */
  private decisionTimerId: number = -1;
  /** Rust 日志轮询定时器（-1 表示未运行；仅在接收会话生命周期内运行） */
  private rustLogTimerId: number = -1;
  /** 是否正在启动（并发闸门：避免同一异步窗口内重复触发启动） */
  private startingUp: boolean = false;
  /** 接收文件落盘目录（Download/<bundleName>/） */
  private downloadDir: string = '';
  /** 建链计时起点（收到完整 P2pInfo 时刻） */
  private linkStartMs: number = 0;
  /** 建链阶段耗时记录（接收侧口径：收到对端凭据起，覆盖「收凭据→本机弹窗」） */
  private linkTiming: MtaLinkTiming = new MtaLinkTiming();
  /**
   * 预热/复用是否被显式抑制：应用退后台、互传开关关闭或显式停止接收服务时置真，
   * 使会话收尾不再复用对外服务（不后台常驻）；服务重新启动时复位。
   */
  private warmReuseSuppressed: boolean = false;
  /** 用户接受接收请求时刻（用于计算接受→下载启动耗时） */
  private acceptMs: number = 0;
  /** 本次下载对应的发送方任务 ID（用于下载体收完后提前回送状态） */
  /** 本次下载是否已回送成功状态（避免提前回送与收尾兜底重复） */
  /** 提前回送的结算 promise：收尾路径先等其结算再判定，兼顾不漏送与不重复 */
  /** 本次下载是否由用户主动取消（取消时回送 user refuse 而非仅断连） */
  private userCancelledThisDownload: boolean = false;

  // ── 生命周期与订阅 ──

  /** 注入事件回调 */
  setEventHandlers(handlers: MtaReceiveEventHandlers): void {
    this.handlers = handlers;
  }

  /** 注入应用上下文（启动服务前调用） */
  init(context: common.Context): void {
    this.context = context;
    this.downloadDir = this.resolveDownloadDir(context);
    this.bindBleHandlers();
    this.bindP2pHandlers();
    this.bindTransferHandlers();
    this.ble.registerEvents(this.bleHandlers);
    this.p2p.registerEvents(this.p2pHandlers);
    this.appendLog('服务', `MTA 接收页就绪，保存目录=${this.downloadDir}`, LogLevels.INFO);
  }

  /**
   * 解析接收文件落盘目录：DOWNLOAD 模式 Download/<bundleName>/。
   * 通过 DOWNLOAD 模式 URI 取沙箱路径，失败时回退应用 filesDir。
   */
  private resolveDownloadDir(context: common.Context): string {
    try {
      let bundleFlags = bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION;
      let info = bundleManager.getBundleInfoForSelfSync(bundleFlags);
      let uri = `file://docs/storage/Users/currentUser/Download/${info.name}`;
      return new fileUri.FileUri(uri).path;
    } catch (e) {
      logger.warn('解析 DOWNLOAD 目录失败，回退应用目录: ' + String(e));
      return `${context.filesDir}/mta_received`;
    }
  }

  /** 当前状态快照 */
  getState(): ReceiverState {
    return this.state.snapshot();
  }

  /** 对外身份令牌（设备昵称 + 模拟品牌），用于会话收尾的复用判定 */
  private currentIdentityToken(): string {
    return buildMtaReceiveIdentityToken(this.deviceName, this.mtaBrandId);
  }

  /**
   * 接收对外服务当前可复用状态快照（供仓储与会话收尾判定「复用」还是「重建」）：
   * 运行态取服务标志，广播/GATT 取子服务实时状态，身份令牌取当前对外身份。
   */
  getWarmState(): ReceiveServiceWarmState {
    let warm = new ReceiveServiceWarmState();
    warm.running = this.state.serviceRunning;
    warm.advertising = this.ble.isAdvertising();
    warm.gattRunning = this.ble.isGattRunning();
    warm.identityToken = this.currentIdentityToken();
    return warm;
  }

  /**
   * 使预热/复用失效：应用退后台或互传开关关闭时由仓储调用，
   * 保证随后不因复用策略继续保留对外服务，也不在后台常驻。
   */
  suppressWarmReuse(): void {
    this.warmReuseSuppressed = true;
  }

  /**
   * 校验落盘目录可用空间是否满足「声明总大小 + 存储预留量」。
   * 查询失败时回退查询应用沙箱目录所在卷并记录日志；
   * 返回空串表示通过，否则返回可直接展示的失败原因。
   */
  private async checkStorageReserve(request: ReceiveRequest): Promise<string> {
    return await this.checkStorageFor(request.totalSize, this.downloadDir);
  }

  /**
   * 按字节总量与目标目录执行存储预留检查（文件接收与文本接收共用）。
   * 两次查询均失败时不因查询能力缺失阻断合法接收，记录后放行。
   */
  private async checkStorageFor(totalBytes: number, dir: string): Promise<string> {
    let required: number = totalBytes + MtaConstants.STORAGE_RESERVE_BYTES;
    let free: number = await this.queryFreeBytes(dir);
    if (free < 0) {
      let fallbackDir = this.context !== undefined ? this.context.filesDir : '';
      this.appendLog('下载', `落盘目录可用空间查询失败，回退查询应用沙箱目录所在卷: ${fallbackDir}`, LogLevels.WARN);
      free = await this.queryFreeBytes(fallbackDir);
    }
    if (free < 0) {
      // 两次查询均失败：不因查询能力缺失阻断合法接收，记录后放行
      this.appendLog('下载', '可用空间查询失败，跳过存储预留检查', LogLevels.WARN);
      return '';
    }
    if (decideStorageCheck(free, totalBytes, MtaConstants.STORAGE_RESERVE_BYTES) ===
      StorageCheckVerdict.insufficient) {
      return this.storageInsufficientMessage(free, required);
    }
    this.appendLog('下载',
      `存储预留检查通过，可用=${free} 字节，需要=${required} 字节（含预留）`, LogLevels.DEBUG);
    return '';
  }

  /** 存储不足提示文案（本地化；资源读取失败时回退中文文案）。 */
  private storageInsufficientMessage(freeBytes: number, requiredBytes: number): string {
    let template: string = '存储空间不足：可用 %s，需要 %s（含预留）';
    try {
      if (this.context !== undefined) {
        template = this.context.resourceManager.getStringSync(
          $r('app.string.storage_insufficient_message').id);
      }
    } catch (_e) {
    }
    return template.replace('%s', formatSizeDetailed(freeBytes))
      .replace('%s', formatSizeDetailed(requiredBytes));
  }

  /** 查询路径所在文件系统的可用字节数；路径为空或查询失败返回 -1 */
  private async queryFreeBytes(path: string): Promise<number> {
    if (path.length === 0) {
      return -1;
    }
    try {
      return await statfs.getFreeSize(path);
    } catch (e) {
      this.appendLog('下载', `查询可用空间失败 path=${path}: ${String(e)}`, LogLevels.DEBUG);
      return -1;
    }
  }

  /** 本机接收广播的发送者 ID 十六进制（供扫描侧过滤本机自身广播） */
  getLocalSenderIdHex(): string {
    return this.ble.getSenderIdHex();
  }

  /**
   * 以新昵称重广播并重建 GATT（供重启流程调用，使昵称变更经重启生效）。
   * 仅在接收服务运行中且无进行中会话时执行；否则保守跳过，待下次前台或重启再生效。
   */
  async refreshIdentity(deviceName: string): Promise<void> {
    if (!this.state.serviceRunning) {
      this.appendLog('服务', '接收服务未运行，跳过对外身份刷新', LogLevels.DEBUG);
      return;
    }
    if (this.sessionActive || this.startingUp) {
      this.appendLog('服务', '存在进行中会话或正在启动，跳过对外身份刷新', LogLevels.DEBUG);
      return;
    }
    // 昵称与模拟品牌任一变化都需以新身份重广播
    let brandId = getMtaSimulatedBrand();
    if (this.deviceName === deviceName && this.mtaBrandId === brandId) {
      return;
    }
    this.deviceName = deviceName;
    this.appendLog('服务', `对外身份刷新为 ${deviceName}，品牌=${resolveMtaBrandName(brandId)}，重新广播并重建 GATT`,
      LogLevels.INFO);
    await this.restartBleService();
  }

  // ── 状态与日志辅助 ──

  /** 切换阶段并推送状态快照 */
  private setStage(stage: ReceiverStage): void {
    this.state.stage = stage;
    this.notifyState();
  }

  /** 推送当前状态快照给 ViewModel */
  private notifyState(): void {
    if (this.handlers !== null) {
      this.handlers.onStateChange(this.state.snapshot());
    }
  }

  /** 记录最近一次错误 */
  private setError(message: string): void {
    this.state.lastError = message;
    this.notifyState();
  }

  /** 追加一条 MTA 日志：正文前置子系统（`子系统: 内容`），经统一分级出口输出到 hilog */
  private appendLog(source: string, content: string, level: string): void {
    logger.log(level, `${source}: ${content}`);
  }

  /** 群组口令等敏感文本的打码形式：保留首尾各 2 字符，其余以 * 代替；长度不足 5 时全部打码 */
  private maskSecret(text: string): string {
    if (text.length === 0) {
      return '';
    }
    if (text.length <= 4) {
      return '*'.repeat(text.length);
    }
    return `${text.substring(0, 2)}${'*'.repeat(text.length - 4)}${text.substring(text.length - 2)}`;
  }

  /** 清空本次会话的传输相关状态（保留服务运行与已保存文件） */
  private resetSessionState(): void {
    this.sessionActive = false;
    this.sessionGeneration += 1;
    this.decisionTaken = false;
    this.stopRustLogPolling();
    this.cancelRequestWaitTimeout();
    this.cancelDecisionTimeout();
    this.state.credentials = undefined;
    this.state.goIpAddress = '';
    this.state.transferPort = 0;
    this.state.groupFrequency = 0;
    this.state.receiveRequest = undefined;
    this.state.requestThumbnailPath = '';
    this.state.progress = new DownloadProgress();
    this.state.pendingMediaFiles = [];
    this.state.lastError = '';
    this.notifyState();
  }

  /**
   * 版本协商完成后启动等待接收请求的超时。WS 层无心跳，对端协商后
   * 崩溃/网络静默断开时收不到 close 事件，接收端会无限期停在
   * NEGOTIATED；超时兜底复位到等待状态。
   */
  private scheduleRequestWaitTimeout(): void {
    this.cancelRequestWaitTimeout();
    this.requestWaitTimerId = setTimeout(() => {
      this.requestWaitTimerId = -1;
      if (this.state.stage === ReceiverStage.NEGOTIATED) {
        this.setError('等待接收请求超时');
        this.failAndReset('等待接收请求超时');
      }
    }, MtaConstants.REQUEST_WAIT_TIMEOUT_MS);
  }

  /** 取消等待接收请求的超时定时器 */
  private cancelRequestWaitTimeout(): void {
    if (this.requestWaitTimerId !== -1) {
      clearTimeout(this.requestWaitTimerId);
      this.requestWaitTimerId = -1;
    }
  }

  /**
   * 武装"等待用户确认接收"的超时：到期仍未决策即自动拒绝并回送拒绝状态。
   * 发送端发出 sendRequest 后 35s 内未见任何结果即单方拆组停服，本端超时略短于该窗口，
   * 使双方得到一致且可归因的结果（对方拒绝），而不是被单方拆链后再失败。
   */
  private scheduleDecisionTimeout(): void {
    this.cancelDecisionTimeout();
    this.decisionTimerId = setTimeout(() => {
      this.decisionTimerId = -1;
      if (this.state.stage === ReceiverStage.REQUEST_RECEIVED) {
        this.onDecisionTimeout().catch((e: Object): void => {
          this.appendLog('服务', '等待确认超时收尾异常: ' + String(e), LogLevels.ERROR);
        });
      }
    }, MtaConstants.PEER_DECISION_TIMEOUT_MS);
  }

  /** 取消等待用户确认的超时定时器 */
  private cancelDecisionTimeout(): void {
    if (this.decisionTimerId !== -1) {
      clearTimeout(this.decisionTimerId);
      this.decisionTimerId = -1;
    }
  }

  /**
   * 处理收到的接收请求：先同步持有该请求，再有界预取发送端缩略图（最多等待
   * `THUMBNAIL_PREFETCH_BUDGET_MS`），随后进入待确认阶段。
   * 请求必须在预取开始前写入状态：预取写回缩略图路径的守卫以「状态已持有该请求」
   * 为判据，若预取先于写入，则快路径（预算内取回）下守卫恒为假、路径被丢弃；
   * 命中预览的提示弹窗会直接带缩略图，未命中也不拖延展示（后台拉取仍继续，命中后经会话回填）。
   */
  private async handleReceiveRequest(request: ReceiveRequest): Promise<void> {
    if (!this.sessionActive || this.state.receiveRequest !== undefined) { return; }
    this.cancelRequestWaitTimeout();
    this.scheduleDecisionTimeout();
    // 先持有请求：预取期间即以本请求作为写回缩略图路径的持有判据
    this.state.receiveRequest = request;
    if (request.thumbnail.length > 0) {
      await this.fetchThumbnailBounded(request);
    }
    if (!this.sessionActive || this.state.receiveRequest !== request) { return; }
    this.setStage(ReceiverStage.REQUEST_RECEIVED);
    this.notifyState();
    this.appendLog('WS', `收到接收请求：发送方=${request.senderName} 文件=${request.fileName} ` +
      `数量=${request.fileCount} 大小=${request.totalSize} 任务=${request.taskId}`, LogLevels.INFO);
    if (this.linkTiming.isRunning()) {
      this.linkTiming.mark('本机弹窗', Date.now());
      this.appendLog('计时',
        `接收建链总耗时=${this.linkTiming.totalMs(Date.now())}ms（收到 P2pInfo→弹出确认）` +
          ` 阶段=[${this.linkTiming.summary()}]`, LogLevels.DEBUG);
    }
  }

  /** 有界预取缩略图：与固定预算赛跑，超预算即放行（后台拉取继续，命中后再回填会话） */
  private async fetchThumbnailBounded(request: ReceiveRequest): Promise<void> {
    let budget = new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, MtaConstants.THUMBNAIL_PREFETCH_BUDGET_MS);
    });
    await Promise.race([this.fetchRequestThumbnail(request), budget]);
  }

  /**
   * 拉取发送端提供的缩略图（图片/视频预览）：经 Rust 请求 `/thumbnail?taskId=`，
   * 结果落到应用缓存目录并把路径写入状态，供确认界面展示。
   * 属可选增强：任何失败只记日志，不影响接收流程。
   */
  private async fetchRequestThumbnail(request: ReceiveRequest): Promise<void> {
    let context = this.context;
    let goIp = this.state.goIpAddress;
    let port = this.state.transferPort;
    if (context === undefined || goIp.length === 0 || port <= 0) {
      return;
    }
    let targetDir = context.cacheDir;
    this.appendLog('预览', `开始拉取发送端缩略图 任务=${request.taskId}`, LogLevels.DEBUG);
    let path = await nativeMtaFetchThumbnail(goIp, port, request.taskId, targetDir,
      MtaConstants.MAX_THUMBNAIL_BYTES);
    if (path.length === 0) {
      this.appendLog('预览', '未取到发送端缩略图，按无预览处理', LogLevels.DEBUG);
      return;
    }
    // 会话仍持有该请求时才写入状态，避免已被接受/拒绝后回填过期预览
    if (mayWriteRequestThumbnail(this.sessionActive, this.state.receiveRequest, request)) {
      this.state.requestThumbnailPath = path;
      this.notifyState();
    }
    this.appendLog('预览', `缩略图已就绪 路径=${path}`, LogLevels.DEBUG);
  }

  /**
   * 等待用户确认超时：回送拒绝状态让发送端得到明确结果，留出收尾窗口后复位等待
   */
  private async onDecisionTimeout(): Promise<void> {
    this.appendLog('服务',
      `等待用户确认超过 ${MtaConstants.PEER_DECISION_TIMEOUT_MS}ms，自动拒绝本次接收`, LogLevels.WARN);
    this.setError('等待用户确认超时，已自动拒绝');
    let request = this.state.receiveRequest;
    let taskId = request !== undefined ? request.taskId : '';
    try {
      await this.transfer.rejectRequest(taskId);
      this.appendLog('WS', '已回送拒绝状态（等待用户确认超时）', LogLevels.INFO);
      await this.sleep(MtaConstants.STATUS_SETTLE_DELAY_MS);
    } catch (e) {
      this.appendLog('WS', '回送拒绝状态失败: ' + String(e), LogLevels.ERROR);
    }
    await this.resetToWaiting();
  }

  // ── Rust 日志轮询（接收侧三速率/块大小/汇总诊断） ──

  /**
   * 启动 Rust 日志轮询：接收会话期间排空 Rust 日志缓冲并追加 MTA 相关诊断行。
   * 仅在会话生命周期内运行，随会话结束停止，避免常驻定时器。
   */
  private startRustLogPolling(): void {
    if (this.rustLogTimerId >= 0) {
      return;
    }
    this.rustLogTimerId = setInterval(() => {
      this.drainRustLog();
    }, MtaConstants.RUST_LOG_POLL_MS);
  }

  /** 停止 Rust 日志轮询：轮询曾运行时做最后一次排空，避免漏掉接收汇总等收尾行 */
  private stopRustLogPolling(): void {
    if (this.rustLogTimerId >= 0) {
      clearInterval(this.rustLogTimerId);
      this.rustLogTimerId = -1;
      this.drainRustLog();
    }
  }

  /** 排空 Rust 日志缓冲并追加 MTA 相关行（共用实现见 MtaBleCommon） */
  private drainRustLog(): void {
    drainRustLog((source: string, message: string, level: string): void => {
      this.appendLog(source, message, level);
    }, (message: string): void => {
      logger.warn(message);
    });
  }

  // ── BLE 事件绑定 ──

  /** 绑定 BLE 事件回调：全部转日志并同步广播/GATT/连接子状态 */
  private bindBleHandlers(): void {
    this.bleHandlers.onBluetoothStateChange = (stateText: string): void => {
      this.appendLog('蓝牙', `开关状态变化: ${stateText}`, LogLevels.DEBUG);
    };
    this.bleHandlers.onAdvertiseStateChange = (running: boolean, detail: string): void => {
      this.state.advertisingRunning = running;
      this.notifyState();
      // 广播启停为生命周期里程碑记 info；停止后的状态明细属诊断，记 debug
      this.appendLog('广播', detail, running ? LogLevels.INFO : LogLevels.DEBUG);
    };
    this.bleHandlers.onGattConnectionChange = (deviceId: string, stateText: string): void => {
      this.state.connectedPeerId = this.ble.getConnectedClientId();
      this.notifyState();
      this.appendLog('GATT', `客户端 ${deviceId} ${stateText}`, LogLevels.DEBUG);
    };
    this.bleHandlers.onGattReadRequest = (deviceId: string, offset: number): void => {
      this.appendLog('GATT', `读请求来自 ${deviceId} offset=${offset}`, LogLevels.DEBUG);
    };
    this.bleHandlers.onGattWriteProgress =
      (deviceId: string, offset: number, totalLength: number, isPrepared: boolean): void => {
        this.appendLog('GATT', `写入分片 offset=${offset} len=${totalLength} prepared=${isPrepared}`, LogLevels.DEBUG);
      };
    this.bleHandlers.onP2pInfoReceived = (deviceId: string, payloadText: string): void => {
      this.handleP2pInfoReceived(deviceId, payloadText);
    };
  }

  /** 绑定 P2P 事件回调 */
  private bindP2pHandlers(): void {
    this.p2pHandlers.onP2pConnectionChange = (summary: string): void => {
      this.appendLog('P2P', summary, LogLevels.DEBUG);
    };
    this.p2pHandlers.onP2pStateChange = (stateText: string): void => {
      this.appendLog('P2P', `p2pStateChange: ${stateText}`, LogLevels.DEBUG);
    };
    this.p2pHandlers.onGoIp = (goIp: string): void => {
      this.state.goIpAddress = goIp;
      this.notifyState();
    };
    this.p2pHandlers.onGroupFrequency = (freqMhz: number): void => {
      this.handleGroupFrequency(freqMhz);
    };
  }

  /** 记录对端群组实际频点并写入日志；落在 2.4GHz 时提示速度可能受限 */
  private handleGroupFrequency(freqMhz: number): void {
    this.state.groupFrequency = freqMhz;
    this.notifyState();
    if (freqMhz <= 0) {
      this.appendLog('P2P', '对端群组频点未知，无法判定频段', LogLevels.WARN);
      return;
    }
    let bandLabel = bandLabelFromFrequency(freqMhz);
    if (isWeakBand(freqMhz)) {
      this.appendLog('P2P',
        `对端群组频点=${freqMhz}MHz（${bandLabel}），速度可能受 2.4GHz 限制`, LogLevels.WARN);
    } else {
      this.appendLog('P2P', `对端群组频点=${freqMhz}MHz（${bandLabel}）`, LogLevels.INFO);
    }
  }

  /** 绑定传输客户端事件回调 */
  private bindTransferHandlers(): void {
    this.transfer.setEventHandlers(this.transferHandlers);
    this.transferHandlers.onWsOpen = (): void => {
      this.appendLog('WS', '连接已建立，等待版本协商', LogLevels.INFO);
    };
    this.transferHandlers.onVersionNegotiated = (version: number): void => {
      this.setStage(ReceiverStage.NEGOTIATED);
      this.linkTiming.mark('版本协商', Date.now());
      this.scheduleRequestWaitTimeout();
      this.appendLog('WS', `版本协商完成 version=${version} threadLimit=${MtaConstants.THREAD_LIMIT}`, LogLevels.INFO);
    };
    this.transferHandlers.onReceiveRequest = (request: ReceiveRequest): void => {
      this.handleReceiveRequest(request).catch((e: Object): void => {
        this.appendLog('服务', '处理接收请求异常: ' + String(e), LogLevels.ERROR);
      });
    };
    this.transferHandlers.onWsClosed = (reason: string): void => {
      this.appendLog('WS', `连接关闭: ${reason}`, LogLevels.INFO);
      this.handleWsClosed();
    };
    this.transferHandlers.onProgress = (progress: DownloadProgress): void => {
      this.state.progress = progress;
      this.notifyState();
    };
    this.transferHandlers.onError = (source: string, message: string): void => {
      this.appendLog(source, message, LogLevels.ERROR);
    };
  }

  /** 确认前控制连接断开时复位；已开始的 HTTP 下载有独立的校验和超时。 */
  private handleWsClosed(): void {
    if (!this.sessionActive) {
      return;
    }
    let stage = this.state.stage;
    if (stage === ReceiverStage.WS_CONNECTING || stage === ReceiverStage.NEGOTIATED ||
      stage === ReceiverStage.REQUEST_RECEIVED) {
      this.setError('WS 连接被对方关闭');
      this.failAndReset('WS 连接被对方关闭');
      return;
    }
    // HTTP body and ZIP validation have their own cancellation and timeouts.
    // A WS close alone must not discard an otherwise valid download.
    if (stage === ReceiverStage.DOWNLOADING) {
      this.appendLog('WS', '控制连接关闭，继续校验当前下载', LogLevels.INFO);
    }
  }

  /**
   * 建立 WS 连接并等待版本协商，同时逐轮记录握手诊断（轮次/结果/耗时/错误码）。
   * P2P 数据面在链路建立后需数百毫秒至数秒才可路由，故不做固定等待：立即以短超时
   * 开始探测，失败即快速重试（超时随轮次递增至上限），在总窗口内持续尝试，
   * 一旦路径就绪即可命中；只有超窗未成功才判定失败。
   */
  private async connectWs(generation: number): Promise<void> {
    const isCurrent = (): boolean => this.sessionActive && this.sessionGeneration === generation;
    if (!isCurrent()) { return; }
    let goIp = this.state.goIpAddress;
    let port = this.state.transferPort;
    if (goIp.length === 0 || port <= 0) {
      this.setError('GO IP 或端口缺失，无法建立 WS');
      this.failAndReset('GO IP 或端口缺失');
      return;
    }
    let url = `wss://${goIp}:${port}${MtaConstants.WS_PATH}`;
    this.setStage(ReceiverStage.WS_CONNECTING);
    // 网络汇总类查询仅作诊断，移出关键路径：与首次连接探测并行，不阻塞建连
    this.refreshNetworkSummary().catch((_e: Object): void => {
    });
    this.appendLog('WS', `STA SSID=${this.p2p.getLinkedSsidText()} P2P 目标=${goIp}:${port}`, LogLevels.DEBUG);

    let handshake = new WsHandshakeResult();
    handshake.targetUrl = url;
    let startMs = Date.now();
    let success = false;
    let attempt = 0;
    // 总窗口内持续重试：不做固定等待，也不限制固定尝试次数
    while (isCurrent() && !success && Date.now() - startMs < MtaConstants.WS_CONNECT_DEADLINE_MS) {
      attempt++;
      // 早期用短超时快速失败重试，随后逐步放宽至上限，兼顾探测密度与较慢握手
      let probeTimeoutMs = Math.min(
        MtaConstants.WS_PROBE_TIMEOUT_MS + (attempt - 1) * MtaConstants.WS_PROBE_TIMEOUT_STEP_MS,
        MtaConstants.WS_CONNECT_TIMEOUT_MS);
      this.appendLog('WS',
        `连接 ${url}（第 ${attempt} 次，超时 ${probeTimeoutMs}ms）网络状态: ${this.p2p.getNetworkInfoText()}`,
        LogLevels.DEBUG);
      try {
        await this.transfer.connect(url, probeTimeoutMs);
        success = true;
      } catch (e) {
        if (!isCurrent()) { return; }
        this.appendLog('WS', `连接失败: ${String(e)}`, LogLevels.ERROR);
        try {
          await this.transfer.close();
        } catch (e2) {
          this.appendLog('WS', '复位 WS 失败: ' + String(e2), LogLevels.ERROR);
        }
      }
      if (success) {
        break;
      }
      await this.sleep(MtaConstants.WS_RETRY_DELAY_MS);
    }
    if (!isCurrent()) { return; }
    handshake.success = success;
    handshake.totalMs = Date.now() - startMs;
    handshake.attemptCount = attempt;
    handshake.summary = buildWsHandshakeSummary(handshake);
    this.appendLog('WS', `WS 握手结果: ${handshake.summary}`, success ? LogLevels.INFO : LogLevels.ERROR);
    if (success) {
      this.linkTiming.mark('WS建连', Date.now());
    }
    if (!success) {
      this.setError('WS 连接失败');
      this.failAndReset('WS 连接失败');
    }
  }

  /** 查询网络并存汇总并记录耗时（异常文本化，不抛出） */
  private async refreshNetworkSummary(): Promise<void> {
    let summaryStartMs = Date.now();
    try {
      await this.p2p.getNetworkSummary();
    } catch (e) {
      this.appendLog('网络', '网络汇总查询失败: ' + String(e), LogLevels.WARN);
    }
    this.appendLog('计时', `网络汇总查询耗时=${Date.now() - summaryStartMs}ms`, LogLevels.DEBUG);
  }

  /** 延时辅助（共用实现见 MtaBleCommon） */
  private sleep(ms: number): Promise<void> {
    return sleepMs(ms);
  }

  /** 收到完整 P2pInfo：解析 → 解密凭据 → p2pConnect 加入群组 → 取得 GO IP */
  private handleP2pInfoReceived(deviceId: string, payloadText: string): void {
    this.appendLog('GATT', `完整接收 P2pInfo 来自 ${deviceId}: ${payloadText}`, LogLevels.DEBUG);
    if (this.sessionActive) {
      this.appendLog('GATT', '已有会话在处理，忽略重复 P2pInfo', LogLevels.WARN);
      return;
    }
    let info = parseP2pInfo(payloadText);
    if (info === undefined) {
      this.appendLog('GATT', 'P2pInfo JSON 解析失败', LogLevels.ERROR);
      this.setError('P2pInfo 解析失败');
      return;
    }
    this.sessionActive = true;
    this.decisionTaken = false;
    const generation = ++this.sessionGeneration;
    this.linkStartMs = Date.now();
    // 接收侧建链计时起点：收到对端完整凭据（P2pInfo）时刻
    this.linkTiming.begin(this.linkStartMs);
    this.linkTiming.mark('收到对端凭据', this.linkStartMs);
    // 接收会话开始：启动 Rust 日志轮询，使接收三速率/块大小/汇总诊断可见
    this.startRustLogPolling();
    this.state.transferPort = info.port > 0 ? info.port : MtaConstants.DEFAULT_TRANSFER_PORT;
    this.setStage(ReceiverStage.P2P_INFO_RECEIVED);
    this.decryptAndConnect(info, generation).catch((e: Object): void => {
      if (!this.sessionActive || this.sessionGeneration !== generation) { return; }
      this.appendLog('服务', '解密/连接编排异常: ' + String(e), LogLevels.ERROR);
      this.failAndReset('解密/连接编排异常');
    });
  }

  /** 解密凭据并经 p2pConnect 加入发送方群组，成功后建立 WS 并完成版本协商 */
  private async decryptAndConnect(info: P2pInfoJson, generation: number): Promise<void> {
    const isCurrent = (): boolean => this.sessionActive && this.sessionGeneration === generation;
    // 1) 解密凭据（key 存在走 ECDH+AES-CTR，缺失按明文）
    let credentials: DecryptedCredentials;
    if (info.key.length > 0) {
      this.appendLog('P2P', `收到发送端公钥（${info.key.length} 字符），开始 ECDH 协商 + AES-CTR 解密`, LogLevels.INFO);
    } else {
      this.appendLog('P2P', 'P2pInfo 未携带 key，按明文处理凭据', LogLevels.INFO);
    }
    try {
      let decryptStartMs = Date.now();
      credentials = await this.crypto.decryptCredentials(info);
      this.appendLog('计时', `凭据解密耗时=${Date.now() - decryptStartMs}ms`, LogLevels.DEBUG);
    } catch (e) {
      if (!isCurrent()) { return; }
      this.appendLog('P2P', '凭据解密失败: ' + String(e), LogLevels.ERROR);
      this.setError('凭据解密失败: ' + String(e));
      this.failAndReset('凭据解密失败');
      return;
    }
    if (!isCurrent()) { return; }
    this.state.credentials = credentials;
    this.notifyState();
    this.linkTiming.mark('凭据解密', Date.now());
    // 群组口令属临时凭据：正文按打码输出并降为 debug，避免明文口令进入常规日志
    this.appendLog('P2P',
      `凭据解密成功 ssid=${credentials.ssid} psk=${this.maskSecret(credentials.psk)} mac=${credentials.mac}`,
      LogLevels.DEBUG);

    // 2) p2pConnect 加入发送方 WiFi Direct 组（不影响已连 WiFi）
    this.setStage(ReceiverStage.P2P_CONNECTING);
    let result: P2pConnectResult = await this.connectP2p(credentials);
    if (!isCurrent()) { return; }
    this.state.goIpAddress = result.goIp;
    this.notifyState();
    if (!result.connected) {
      this.setError(result.detail);
      this.failAndReset(result.detail);
      return;
    }
    this.setStage(ReceiverStage.P2P_CONNECTED);
    this.linkTiming.mark('入组完成', Date.now());
    this.appendLog('P2P', `连接完成，GO IP=${result.goIp} 端口=${this.state.transferPort}`, LogLevels.INFO);

    // 3) 建立 WS 并完成版本协商
    await this.connectWs(generation);
  }

  /**
   * 经 p2pConnect 加入发送方 WiFi Direct 组：注入解密出的 SSID/PSK，
   * 以 p2pConnectionChange 事件确认连接。
   */
  private async connectP2p(credentials: DecryptedCredentials): Promise<P2pConnectResult> {
    this.appendLog('P2P', `开始 p2pConnect groupName=${credentials.ssid}`, LogLevels.DEBUG);
    let p2pStartMs = Date.now();
    let result: P2pConnectResult =
      await this.p2p.connectAndWait(credentials.ssid, credentials.psk, MtaConstants.P2P_CONNECT_TIMEOUT_MS);
    this.appendLog('P2P', result.detail, result.connected ? LogLevels.INFO : LogLevels.ERROR);
    this.appendLog('计时',
      `p2pConnect 入组耗时=${Date.now() - p2pStartMs}ms 结果=${result.connected ? '已确认连接' : '超时兜底'}`,
      LogLevels.DEBUG);
    return result;
  }

  /** 本次会话失败：记录阶段并复位到等待状态 */
  private failAndReset(reason: string): void {
    this.setStage(ReceiverStage.FAILED);
    this.appendLog('服务', `本次接收失败：${reason}，正在复位到等待状态`, LogLevels.ERROR);
    this.resetToWaiting().catch((e: Object): void => {
      this.appendLog('服务', '复位异常: ' + String(e), LogLevels.ERROR);
    });
  }

  /**
   * 会话收尾公共骨架：关 WS、断开 P2P、复位会话状态，再按当前服务态恢复 BLE。
   * @param restore 恢复 BLE 的方式（等待态用 ensureBleRunning、完成后用 restartBleService）
   * @param restoredLog 恢复成功时的日志正文
   */
  private async closeSessionAndRestoreBle(restore: () => Promise<boolean>,
    restoredLog: string): Promise<void> {
    this.sessionActive = false;
    try {
      await this.transfer.close();
    } catch (e) {
      this.appendLog('WS', '关闭 WS 失败: ' + String(e), LogLevels.ERROR);
    }
    try {
      let detail = await this.p2p.disconnect();
      this.appendLog('P2P', detail, LogLevels.INFO);
    } catch (e) {
      this.appendLog('P2P', '断开 P2P 失败: ' + String(e), LogLevels.ERROR);
    }
    this.resetSessionState();
    if (this.state.serviceRunning) {
      let recovered = await restore();
      if (recovered) {
        this.setStage(ReceiverStage.SERVICE_RUNNING);
        this.appendLog('服务', restoredLog, LogLevels.INFO);
      } else {
        // 广播/GATT 恢复失败：如实标记失败，避免假就绪状态误导用户
        this.setStage(ReceiverStage.FAILED);
      }
    } else {
      this.setStage(ReceiverStage.IDLE);
    }
  }

  /** 复位到可再次接收的等待状态（关 WS、断开 P2P、确保 BLE 服务在运行） */
  private async resetToWaiting(): Promise<void> {
    await this.closeSessionAndRestoreBle(() => this.ensureBleRunning(), '已回到等待连接状态');
  }

  /** 一次接收完成后清理会话资源并恢复对外服务，支持连续接收 */
  private async completeAndRestart(): Promise<void> {
    await this.closeSessionAndRestoreBle(() => this.restoreReceiveServiceReuseFirst(),
      '接收服务已恢复，可继续接收');
  }

  /**
   * 会话收尾的接收对外服务恢复（复用优先）：
   * 对外身份（昵称/模拟品牌）未变且广播/GATT 仍完整时复用既有服务与密钥，避免连续接收固定重建开销；
   * 身份变化、服务缺失或复用失败则回退既有完整重建路径，保证功能不劣化。
   */
  private async restoreReceiveServiceReuseFirst(): Promise<boolean> {
    let expectedToken = this.currentIdentityToken();
    let warm = this.getWarmState();
    if (!this.warmReuseSuppressed && isReceiveServiceReusable(warm, expectedToken)) {
      let reused = await this.ensureBleRunning();
      if (reused) {
        this.appendLog('服务', '收尾复用既有广播/GATT 服务与密钥（对外身份未变）', LogLevels.INFO);
        return true;
      }
      this.appendLog('服务', '复用既有接收服务失败，回退完整重建', LogLevels.WARN);
    }
    return await this.restartBleService();
  }

  /** 确保广播与 GATT Server 在运行（缺密钥时补生成，已运行则复用），返回是否恢复成功 */
  private async ensureBleRunning(): Promise<boolean> {
    try {
      if (!this.crypto.hasKeyPair()) {
        let publicKey = await this.crypto.generateKeyPair();
        this.state.ecdhPublicKey = publicKey;
      }
      let deviceInfoJson = this.buildDeviceInfoJson(this.crypto.getPublicKeyBase64());
      if (!this.ble.isAdvertising()) {
        await this.startAdvertisingWithCurrentBrand();
      }
      if (!this.ble.isGattRunning()) {
        await this.ble.startGattServer(deviceInfoJson);
      }
      this.state.advertisingRunning = this.ble.isAdvertising();
      this.state.gattRunning = this.ble.isGattRunning();
      this.notifyState();
      return true;
    } catch (e) {
      this.appendLog('服务', '恢复 BLE 服务失败: ' + String(e), LogLevels.ERROR);
      this.setError('恢复 BLE 服务失败: ' + String(e));
      return false;
    }
  }

  /** 按当前设置启动广播：读取模拟品牌并同步到本地记录，返回广播字节预览 */
  private async startAdvertisingWithCurrentBrand(): Promise<string> {
    this.mtaBrandId = getMtaSimulatedBrand();
    return await this.ble.startAdvertising(this.deviceName, this.mtaBrandId);
  }

  /** 强制重启广播与 GATT Server（生成新的会话密钥对），返回是否重启成功 */
  private async restartBleService(): Promise<boolean> {
    try {
      await this.ble.stopGattServer();
      await this.ble.stopAdvertising();
      let publicKey = await this.crypto.generateKeyPair();
      this.state.ecdhPublicKey = publicKey;
      await this.startAdvertisingWithCurrentBrand();
      await this.ble.startGattServer(this.buildDeviceInfoJson(publicKey));
      this.state.advertisingRunning = this.ble.isAdvertising();
      this.state.gattRunning = this.ble.isGattRunning();
      this.notifyState();
      this.appendLog('服务', '已重新启动广播与 GATT Server，可继续接收', LogLevels.INFO);
      return true;
    } catch (e) {
      this.appendLog('服务', '自动恢复失败: ' + String(e), LogLevels.ERROR);
      this.setError('自动恢复失败: ' + String(e));
      return false;
    }
  }

  /** 构造本会话 DeviceInfo（CHAR_STATUS 读返回值） */
  private buildDeviceInfoJson(publicKey: string): string {
    let info = new DeviceInfoJson();
    info.state = MtaConstants.DEVICE_INFO_STATE;
    info.mac = MtaConstants.FALLBACK_MAC;
    info.key = publicKey;
    info.catShare = MtaConstants.CATSHARE_VERSION;
    return JSON.stringify(info);
  }

  // ── 服务启停 ──

  /** 启动接收服务：经「启动中」并发闸门后委派给实现体 */
  async startService(deviceName: string): Promise<void> {
    if (this.state.serviceRunning) {
      this.appendLog('服务', '接收服务已在运行', LogLevels.DEBUG);
      return;
    }
    if (this.startingUp) {
      this.appendLog('服务', '接收服务正在启动，忽略重复请求', LogLevels.DEBUG);
      return;
    }
    this.startingUp = true;
    try {
      await this.startServiceInternal(deviceName);
    } finally {
      this.startingUp = false;
    }
  }

  /** 启动接收服务实现体：权限/蓝牙检查 → 生成密钥对 → 广播 + GATT Server */
  private async startServiceInternal(deviceName: string): Promise<void> {
    this.deviceName = deviceName;
    // 新一次启动即解除复用抑制：本服务经完整启动后重新具备复用条件
    this.warmReuseSuppressed = false;
    this.appendLog('服务', `启动接收服务，设备名=${this.deviceName}`, LogLevels.INFO);

    // 1) 权限检查
    let context = this.context;
    if (context === undefined) {
      this.appendLog('权限', '缺少应用上下文，无法申请蓝牙权限', LogLevels.ERROR);
      this.setError('缺少应用上下文');
      return;
    }
    let granted = false;
    try {
      granted = await ensureBluetoothPermission(context);
    } catch (e) {
      this.appendLog('权限', '申请 ACCESS_BLUETOOTH 失败: ' + String(e), LogLevels.ERROR);
    }
    if (!granted) {
      this.appendLog('权限', 'ACCESS_BLUETOOTH 被拒绝，无法启动接收服务', LogLevels.ERROR);
      this.setError('蓝牙权限被拒绝');
      return;
    }

    // 2) 蓝牙开关检查（未开启时请求系统开启并终止本次启动）
    if (!isBluetoothEnabled()) {
      this.appendLog('蓝牙', `蓝牙未开启（当前 ${queryBluetoothStateText()}），请先开启后重试`, LogLevels.WARN);
      this.setError('蓝牙未开启');
      try {
        enableBluetoothSystem();
        this.appendLog('蓝牙', '已请求系统开启蓝牙', LogLevels.INFO);
      } catch (e) {
        this.appendLog('蓝牙', '请求开启蓝牙失败: ' + String(e), LogLevels.ERROR);
      }
      return;
    }

    // 3) 重新订阅事件（stopService 已退订）后生成密钥对并启动广播 + GATT Server
    this.ble.registerEvents(this.bleHandlers);
    this.p2p.registerEvents(this.p2pHandlers);
    try {
      let publicKey = await this.crypto.generateKeyPair();
      this.state.ecdhPublicKey = publicKey;
      let deviceInfoJson = this.buildDeviceInfoJson(publicKey);
      let preview = await this.startAdvertisingWithCurrentBrand();
      // 广播预览本身含换行，先折叠为单行，保证一条日志一事件
      this.appendLog('广播', `广播已启动；${preview.split('\n').join('；')}`, LogLevels.INFO);
      await this.ble.startGattServer(deviceInfoJson);
      this.appendLog('GATT', `GATT Server 已启动，DeviceInfo=${deviceInfoJson}`, LogLevels.INFO);
      this.state.serviceRunning = true;
      this.state.advertisingRunning = this.ble.isAdvertising();
      this.state.gattRunning = this.ble.isGattRunning();
      this.state.lastError = '';
      this.setStage(ReceiverStage.SERVICE_RUNNING);
      this.appendLog('服务', '接收服务已启动，等待互传设备连接', LogLevels.INFO);
    } catch (e) {
      this.appendLog('服务', '启动接收服务失败: ' + String(e), LogLevels.ERROR);
      this.setError('启动失败: ' + String(e));
      await this.stopService();
    }
  }

  /** 停止接收服务并释放会话资源 */
  async stopService(): Promise<void> {
    this.appendLog('服务', '停止接收服务', LogLevels.INFO);
    this.sessionActive = false;
    // 显式停止即抑制复用：退后台/开关关闭后不保留对外服务，也不后台常驻
    this.warmReuseSuppressed = true;
    // 停止对外服务即退订事件：避免发送期间仍收到本地 P2P/蓝牙事件，造成日志串台与误判
    this.ble.unregisterEvents();
    this.p2p.unregisterEvents();
    try {
      await this.ble.stopAdvertising();
    } catch (e) {
      this.appendLog('广播', '停止广播失败: ' + String(e), LogLevels.ERROR);
    }
    try {
      await this.ble.stopGattServer();
    } catch (e) {
      this.appendLog('GATT', '停止 GATT Server 失败: ' + String(e), LogLevels.ERROR);
    }
    try {
      await this.transfer.close();
    } catch (e) {
      this.appendLog('WS', '关闭 WS 失败: ' + String(e), LogLevels.ERROR);
    }
    try {
      let detail = await this.p2p.disconnect();
      this.appendLog('P2P', detail, LogLevels.DEBUG);
    } catch (e) {
      this.appendLog('P2P', '断开 P2P 失败: ' + String(e), LogLevels.ERROR);
    }
    this.resetSessionState();
    this.state.serviceRunning = false;
    this.state.advertisingRunning = false;
    this.state.gattRunning = false;
    this.state.connectedPeerId = '';
    this.setStage(ReceiverStage.IDLE);
  }

  /** 用户接受接收请求：回 ack 并进入下载流程 */
  async acceptRequest(): Promise<void> {
    if (!this.sessionActive || this.decisionTaken || this.state.stage !== ReceiverStage.REQUEST_RECEIVED
      || this.state.receiveRequest === undefined) {
      this.appendLog('服务', '当前无待确认的接收请求', LogLevels.WARN);
      return;
    }
    // 用户已决策：撤销等待确认超时，避免确认后又被自动拒绝
    this.cancelDecisionTimeout();
    let request = this.state.receiveRequest;
    this.decisionTaken = true;
    this.appendLog('服务', `用户已接受接收请求，开始下载任务 ${request.taskId}`, LogLevels.INFO);
    this.acceptMs = Date.now();
    try {
      await this.transfer.acceptRequest();
    } catch (e) {
      if (!this.sessionActive || this.state.receiveRequest !== request) { return; }
      // 接受 ack 发送失败（WS 已断）：不进入下载，按失败复位，
      // 避免接收端独自从已判失败的发送方拉取数据
      this.appendLog('WS', '发送接受 ack 失败: ' + String(e), LogLevels.ERROR);
      this.setError('发送接受确认失败');
      this.failAndReset('发送接受确认失败');
      return;
    }
    if (!this.sessionActive || this.state.receiveRequest !== request) { return; }
    this.downloadAndSave(request).catch((e: Object): void => {
      if (!this.sessionActive || this.state.receiveRequest !== request) { return; }
      this.appendLog('下载', '下载编排异常: ' + String(e), LogLevels.ERROR);
      this.failAndReset('下载编排异常');
    });
  }

  /**
   * 用户接受文本消息：不进入下载流程，回接受 ack 与成功 status 完成协议收尾
   * （发送方显示发送成功）。剪贴板是否写入由 UI 侧独立决定，与本收尾正交。
   * ack/status 发送失败（WS 已断）仅记日志、不中断收尾——文本已在本机可见，
   * 用户侧不可逆，发送方将按超时收尾。
   */
  async acceptTextRequest(): Promise<void> {
    if (!this.sessionActive || this.decisionTaken || this.state.stage !== ReceiverStage.REQUEST_RECEIVED) {
      this.appendLog('服务', '当前无待确认的接收请求', LogLevels.WARN);
      return;
    }
    let request = this.state.receiveRequest;
    if (request === undefined || request.textContent.length === 0) {
      this.appendLog('服务', '当前接收请求非文本消息，忽略文本接受收尾', LogLevels.WARN);
      return;
    }
    this.decisionTaken = true;
    // 用户已决策：撤销等待确认超时
    this.cancelDecisionTimeout();
    // 文本即文件：接受时先把文本落盘到应用私有接收文本目录（filesDir/text_recv/），成功后再回执；
    // 落盘前同样执行存储预留检查，不足时按既有失败语义处理，不得谎报接收成功
    let textDir = this.recvTextSaveDir();
    if (textDir.length === 0) {
      this.appendLog('服务', '接收文本目录不可得', LogLevels.ERROR);
      this.setError('文本落盘失败');
      this.failAndReset('文本落盘失败');
      return;
    }
    let storageError = await this.checkStorageFor(utf8ByteLength(request.textContent), textDir);
    if (!this.sessionActive || this.state.receiveRequest !== request) { return; }
    if (storageError.length > 0) {
      this.appendLog('服务', storageError, LogLevels.ERROR);
      this.setError(storageError);
      this.failAndReset(storageError);
      return;
    }
    let textPath: string = '';
    try {
      textPath = this.saveTextToDisk(request, textDir);
    } catch (e) {
      this.appendLog('服务', '文本落盘失败: ' + String(e), LogLevels.ERROR);
      this.setError('文本落盘失败');
      this.failAndReset('文本落盘失败');
      return;
    }
    this.appendLog('服务',
      `用户已接受文本消息，已落盘至 ${textPath}，按成功收尾任务 ${request.taskId}`, LogLevels.INFO);
    // 上抛真实保存路径（供统一会话回填逐文件路径）：不影响协议报文与对端可见内容
    if (textSavedNotifier !== undefined) {
      textSavedNotifier(textPath);
    }
    try {
      await this.transfer.acceptRequest();
    } catch (e) {
      this.appendLog('WS', '发送接受 ack 失败: ' + String(e), LogLevels.ERROR);
    }
    // 以文本消息条目写接收历史（记真实路径，不写正文；遵循历史开关）
    this.recordTextHistory(request, textPath);
    try {
      await this.transfer.sendStatus(MtaConstants.STATUS_TYPE_OK, MtaConstants.STATUS_REASON_OK, request.taskId);
      this.appendLog('WS', '已回送成功状态，本次文本接收完成', LogLevels.INFO);
    } catch (e) {
      this.appendLog('WS', '回送成功状态失败: ' + String(e), LogLevels.ERROR);
    }
    // 等待发送方收到回执并完成收尾，避免过早断开导致发送方判定为中断
    await this.sleep(MtaConstants.STATUS_SETTLE_DELAY_MS);
    // 断开 P2P、关闭 WS 并自动重启广播，支持连续接收
    await this.completeAndRestart();
  }

  /** 接收文本的落盘目录：与 LocalSend 接收文本共用同一路径来源，避免口径分叉。 */
  private recvTextSaveDir(): string {
    return recvTextDir();
  }

  /** 把文本消息写入接收文本目录（重名自动加序号、不覆盖），返回真实路径。 */
  private saveTextToDisk(request: ReceiveRequest, dir: string): string {
    try {
      fs.mkdirSync(dir, true);
    } catch (_e) {
    }
    let name = uniquePath(dir, MTA_SHARED_TEXT_FILE_NAME);
    let path = `${dir}/${name}`;
    let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, request.textContent);
    } finally {
      fs.closeSync(file);
    }
    return path;
  }

  /** Rust 主导接收：下载/解压/落盘一体完成，再写接收历史并按设置收集相册项 */
  /**
   * 下载体收完（仍在解压/落盘）时提前回送成功状态。
   * 发送方（如小米）在发完文件后等待回执的窗口很短，等到解压落盘结束再回送会赶不上；
   * 仅在写入成功时置"已回送"标记，失败保持未置，由收尾路径兜底再回送一次。
   */
  private async downloadAndSave(request: ReceiveRequest): Promise<void> {
    const isCurrent = (): boolean => this.sessionActive && this.state.receiveRequest === request;
    this.userCancelledThisDownload = false;
    this.setStage(ReceiverStage.DOWNLOADING);
    let storageError = await this.checkStorageReserve(request);
    if (!isCurrent()) { return; }
    if (storageError.length > 0) {
      this.setError(storageError);
      this.failAndReset(storageError);
      return;
    }
    let goIp = this.state.goIpAddress;
    let port = this.state.transferPort;
    try {
      if (this.userCancelledThisDownload) { throw new Error('用户取消下载'); }
      let result = await this.transfer.receiveToTarget(goIp, port, request.taskId,
        mtaReceiveDirectory(this.downloadDir), request.totalSize);
      if (!isCurrent()) { return; }
      if (result.entryCount === 0 || (request.fileCount > 0 && result.entryCount !== request.fileCount)
        || (request.totalSize > 0 && result.totalBytes !== request.totalSize)) {
        for (const path of result.savedFiles) {
          try { fs.unlinkSync(path); } catch (error) { this.appendLog('下载', '清理失败：' + String(error), LogLevels.WARN); }
        }
        throw new Error('收到的文件数量或大小与传输请求不符');
      }
      try {
        await this.transfer.sendStatus(MtaConstants.STATUS_TYPE_OK, MtaConstants.STATUS_REASON_OK, request.taskId);
      } catch (error) {
        this.appendLog('WS', '文件已校验并保存，回执发送失败：' + String(error), LogLevels.WARN);
      }
      if (!isCurrent()) { return; }
      result.savedFiles = await finalizeMtaReceivedFiles(result.savedFiles, result.files);
      if (!isCurrent()) { return; }
      this.state.savedFiles = result.savedFiles;
      // 透传逐文件展示元数据（文件名 + 大小 + 真实类型），供页面完成后渲染文件列表
      this.state.receivedFiles = result.files;
      if (result.restoredTimeCount > 0) {
        // restoredTimeCount 为"带有效条目时间"的文件数（个别文件还原失败仅在 Rust 侧告警）
        this.appendLog('下载',
          `${result.restoredTimeCount} 个文件带有效 ZIP 条目时间，已用于还原修改时间`, LogLevels.INFO);
      }
      // 落盘完成后按设置写入接收历史（文本消息以单一 text/plain 条目记录）
      this.recordReceiveHistory(request, result);
      // 按「保存到相册」设置收集媒体文件（仅图片/视频），供页面完成后的保存弹窗消费
      this.state.pendingMediaFiles = this.collectMediaFiles(result);
      if (this.state.pendingMediaFiles.length > 0) {
        this.appendLog('下载', `检测到 ${this.state.pendingMediaFiles.length} 个媒体文件待保存到相册`, LogLevels.INFO);
      }
      // 完成态：分母为接收请求声明的原始总大小，固定为 100%
      let done = new DownloadProgress();
      done.receivedBytes = request.totalSize;
      done.totalBytes = request.totalSize;
      done.percent = 100;
      this.state.progress = done;
      this.notifyState();
      this.appendLog('下载', `保存完成，共 ${result.entryCount} 个文件，合计 ${result.totalBytes} 字节`, LogLevels.INFO);
      this.setStage(ReceiverStage.COMPLETED);
      await this.sleep(MtaConstants.STATUS_SETTLE_DELAY_MS);
      if (!isCurrent()) { return; }
      await this.completeAndRestart();
    } catch (e) {
      if (!isCurrent()) { return; }
      // Rust 侧已在失败/取消时回滚本次已写入的目标文件，此处仅复位会话
      this.appendLog('下载', '下载/保存失败: ' + String(e), LogLevels.ERROR);
      this.setError('下载/保存失败: ' + String(e));
      // 用户主动取消时回送 user refuse：让发送端得到明确结果，而非仅凭连接关闭推断
      if (this.userCancelledThisDownload) {
        await this.sendUserCancelStatus(request.taskId);
      }
      this.failAndReset('下载/保存失败');
    }
  }

  /**
   * 用户取消时 best-effort 回送 user refuse：协议"终止类型 + 用户拒绝"即该场景语义，
   * 对端据此判为"对方拒绝"而非连接异常。发送失败仅记日志，随后仍走既有复位路径。
   * 其余失败（停滞/落盘错误）保持断连语义：协议 reason 词表无"本地错误"项，
   * 硬套 timeout 会让对端显示错误原因。
   */
  private async sendUserCancelStatus(taskId: string): Promise<void> {
    try {
      await this.transfer.sendStatus(MtaConstants.STATUS_TYPE_REFUSE, MtaConstants.STATUS_REASON_REFUSE, taskId);
      this.appendLog('WS', '已回送取消状态（user refuse）', LogLevels.INFO);
    } catch (e) {
      this.appendLog('WS', '回送取消状态失败: ' + String(e), LogLevels.DEBUG);
    }
  }

  /** 落盘完成后写入接收历史（仅文件条目；文本消息历史由 acceptTextRequest 写入） */
  private recordReceiveHistory(request: ReceiveRequest, result: DownloadResult): void {
    let timestamp = Date.now();
    // 文件条目：每个落盘文件记录一条历史（类型取落盘时按扩展名解析的真实 MIME）
    // （文本消息在适配器层已路由到 acceptTextRequest，不进入本下载完成路径）
    // 先构建全部条目再一次性落盘：逐条写入会让每次追加都全量序列化整个历史
    let entries: ReceiveHistoryEntry[] = [];
    for (let i = 0; i < result.savedFiles.length; i++) {
      let savedPath = result.savedFiles[i];
      let fileName = result.files[i]?.name ?? this.baseNameOf(savedPath);
      let fileType = i < result.files.length ? result.files[i].fileType : '';
      if (fileType.length === 0) {
        fileType = getMimeForFileName(fileName);
      }
      let entry: ReceiveHistoryEntry = {
        id: `${request.taskId}_${i}`,
        fileName: fileName,
        fileType: fileType,
        path: savedPath,
        savedToGallery: savedPath.startsWith('file://media/'),
        isMessage: false,
        fileSize: result.files[i]?.size ?? this.fileSizeOf(savedPath),
        senderAlias: request.senderName,
        timestamp: timestamp + i
      };
      entries.push(entry);
    }
    addEntries(entries);
  }

  /** 以文本消息条目写入接收历史（记真实文件路径，不写正文） */
  private recordTextHistory(request: ReceiveRequest, path: string): void {
    let name = this.baseNameOf(path);
    let textEntry: ReceiveHistoryEntry = {
      id: `${request.taskId}_0`,
      fileName: name.length > 0 ? name : MTA_SHARED_TEXT_FILE_NAME,
      fileType: 'text/plain',
      path: path,
      savedToGallery: false,
      isMessage: true,
      fileSize: this.fileSizeOf(path),
      senderAlias: request.senderName,
      timestamp: Date.now()
    };
    addEntries([textEntry]);
  }

  /**
   * 按真实类型收集可保存到相册的媒体文件（图片/视频）。
   * 「保存到相册」关闭时返回空表；类型取落盘时解析的真实 MIME。
   */
  private collectMediaFiles(result: DownloadResult): Array<MediaFileInfo> {
    let mediaFiles: Array<MediaFileInfo> = [];
    if (!isSaveToGallery()) {
      return mediaFiles;
    }
    for (let i = 0; i < result.savedFiles.length; i++) {
      let savedPath = result.savedFiles[i];
      if (savedPath.length === 0) {
        continue;
      }
      let fileName = this.baseNameOf(savedPath);
      let fileType = i < result.files.length ? result.files[i].fileType : '';
      if (fileType.length === 0) {
        fileType = getMimeForFileName(fileName);
      }
      if (isMediaMime(fileType)) {
        let info: MediaFileInfo = {
          filePath: savedPath,
          fileName: fileName,
          fileType: fileType,
          isImage: isImage(fileType)
        };
        mediaFiles.push(info);
      }
    }
    return mediaFiles;
  }

  /** 取路径末段文件名 */
  private baseNameOf(path: string): string {
    let index = path.lastIndexOf('/');
    return index >= 0 ? path.substring(index + 1) : path;
  }

  /** 读取文件大小（失败返回 0） */
  private fileSizeOf(path: string): number {
    try {
      return fs.statSync(path).size;
    } catch (e) {
      return 0;
    }
  }

  /** 用户拒绝接收请求：回送拒绝状态 → 有界收尾等待 → 复位 */
  async rejectRequest(): Promise<void> {
    if (!this.sessionActive || this.decisionTaken || this.state.stage !== ReceiverStage.REQUEST_RECEIVED) {
      this.appendLog('服务', '当前无待确认的接收请求', LogLevels.WARN);
      return;
    }
    // 用户已决策：撤销等待确认超时
    this.cancelDecisionTimeout();
    this.decisionTaken = true;
    this.appendLog('服务', '用户已拒绝接收请求，回送拒绝状态', LogLevels.INFO);
    let request = this.state.receiveRequest;
    let taskId = request !== undefined ? request.taskId : '';
    try {
      await this.transfer.rejectRequest(taskId);
      // 回送后等待对端收尾，确保在途拒绝帧送达后再关闭连接（与成功路径一致）
      await this.sleep(MtaConstants.STATUS_SETTLE_DELAY_MS);
    } catch (e) {
      this.appendLog('WS', '回送拒绝状态异常: ' + String(e), LogLevels.ERROR);
    }
    if (this.sessionActive && this.state.receiveRequest === request) { await this.resetToWaiting(); }
  }

  /** 取消当前下载 */
  cancelDownload(): void {
    if (this.state.stage !== ReceiverStage.DOWNLOADING) {
      this.appendLog('下载', '当前无进行中的下载', LogLevels.INFO);
      return;
    }
    this.appendLog('下载', '用户取消下载', LogLevels.INFO);
    this.userCancelledThisDownload = true;
    this.transfer.cancelDownload();
  }
}
