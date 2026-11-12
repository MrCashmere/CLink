/**
 * MtaSendService.ets — MTA 发送端编排门面
 *
 * 串联 BLE 扫描/连接、WiFi Direct 建组、Rust TLS/WS 服务器与文件传输，维护发送端状态机
 * （SenderState），并以事件回调方式向 ViewModel 推送状态快照。
 * 所有系统调用失败均转为可读文本写入日志，不向页面抛出异常。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import {
  DecryptedCredentials,
  DeviceInfoJson,
  MtaBleEventHandlers,
  MtaLinkTiming,
  P2pInfoJson,
  parseDeviceInfo,
  truncateUtf8Text
} from '../../model/mta/MtaProtocolModels';
import {
  EncryptedCredentials,
  MTA_CANCEL_NOTIFY_FAILED_TEXT,
  MTA_CANCELLED_TEXT,
  MTA_PARTIAL_COMPLETED_TEXT,
  MTA_PEER_ABANDONED_TEXT,
  MTA_PEER_BUSY_TEXT,
  MTA_PEER_REJECTED_TEXT,
  MtaBleClientEventHandlers,
  MtaCompanionPeerBehavior,
  MtaDiscoveredDevice,
  MtaGroupBandCandidate,
  MtaGroupCreationResult,
  MtaGroupInfo,
  MtaP2pGroupEventHandlers,
  MtaPeerInfoRecheckResult,
  MtaSendEventHandlers,
  MtaSendFile,
  MtaSendPreparation,
  MtaSendProgress,
  MtaSendSession,
  MtaSenderStage,
  SessionGroupIdentity,
  SenderState,
  bandLabelFromFrequency,
  buildEntryName,
  buildPeerInfoRecheckFailure,
  evaluatePeerInfoRecheck,
  formatCompanionPeerBehaviorSummary,
  formatCompanionWriteRequest,
  isMtaPeerBusy,
  isMtaSenderStageForward,
  matchMtaGroupIdentity,
  mtaDeviceIdentityKey,
  mtaPeerBusyReasonText,
  mtaRejectReasonText,
  normalizeMtaP2pMac,
  randomGroupName,
  randomPassphrase,
  randomTaskId,
  resolveMtaP2pWriteModeText,
  resolvePreferredGroupBands,
  resolveSendWritebackReady,
  shouldRetryPeerBusy,
  totalFileBytes
} from '../../model/mta/MtaSendModels';
import { NativeEvent, NativeMtaFileEntry, NativeMtaServerConfig } from '../../model/NativeTypes';
import { MTA_SHARED_TEXT_FILE_NAME } from '../../model/mta/MtaMainModels';
import {
  nativeMtaRejectPeer,
  nativeMtaStartServer,
  nativeMtaStopServer,
  offBridgeEvent,
  onBridgeEvent
} from '../NativeBridge';
import { MtaConstants } from './MtaConstants';
import { MtaBleClient, shouldRescanPeerAddress } from './MtaBleClient';
import { MtaBleReceiver } from './MtaBleReceiver';
import {
  drainRustLog, loadOrCreateMtaDeviceIdHex, sleepMs, utf8ByteLength
} from './MtaBleCommon';
import { MtaCrypto } from './MtaCrypto';
import { MtaP2pGroup } from './MtaP2pGroup';
import { MTA_BRAND_ID_THIRD_PARTY, resolveMtaBrandName } from '../../model/mta/MtaBrandRegistry';
import { getDeviceAlias } from '../repository/DeviceRepository';
import { getMtaSimulatedBrand } from '../repository/SettingsRepository';
import { sendTextDir, sendThumbnailDir } from '../repository/SendRepository';
import { getLogger } from '../../utils/Logger';
import { formatSpeed } from '../../utils/FormatUtil';
import { isLargeTransfer } from '../../utils/LargeTransferUtil';
import { resolveSendCompletedProgress } from '../../utils/MtaProgressUtil';
import { aggregateMtaMimeType, getMimeForFileName, isMediaMime, isVideo } from '../../utils/MimeUtils';
import { ThumbnailSize, writeSendThumbnail } from '../../utils/ImageThumbnailUtil';
import { LogDomains } from '../../common/LogDomains';
import { LogLevels } from '../../common/LogLevels';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaSend', '互传发送');

// ── 对端退出 P2P 组判定（纯函数：无副作用、不依赖系统 API，可导出单测） ──

/** 「对端是否已退出本次 P2P 组」的判定结果（纯数据契约）。 */
export class MtaPeerGroupAbandonDecision {
  /** 新的连续归零次数（0 表示客户端数正常，或当前不在等待确认阶段） */
  zeroStreak: number = 0;
  /** 是否判定对端已放弃（连续归零次数达到阈值） */
  abandoned: boolean = false;
}

/**
 * 判定「对端是否已退出本次 P2P 组」（纯函数，无副作用、不依赖系统 API）。
 *
 * 仅在等待确认阶段生效：该阶段对端本应稳定留在组内，客户端数归零是最早可观测的
 * 「对端已放弃」信号。客户端数用 `-1` 表示群组信息不可得，同样计入归零。
 * 连续归零次数达到 `GROUP_CLIENT_ZERO_STREAK_LIMIT` 才判放弃，避免瞬时重连/读数抖动误判；
 * 非等待确认阶段、以及客户端数回升时计数清零。
 */
export function decidePeerGroupAbandon(stage: MtaSenderStage, lastClientCount: number,
  clientCount: number, zeroStreak: number): MtaPeerGroupAbandonDecision {
  let decision = new MtaPeerGroupAbandonDecision();
  // 仅等待确认阶段生效：其余阶段对端是否在组内不构成「放弃」信号
  if (stage !== MtaSenderStage.WAITING_PEER_CONFIRM) {
    return decision;
  }
  // 客户端数回升（>=1）：对端仍在组内，计数清零
  if (clientCount >= 1) {
    return decision;
  }
  // 累计归零的触发条件：上次已观测到对端在组内（由 >=1 降为 0）、已在防抖累计中（上次已归零），
  // 或本次群组信息不可得（-1，视为对端已离组的强信号）
  let startCounting = lastClientCount >= 1 || zeroStreak > 0 || clientCount < 0;
  if (!startCounting) {
    return decision;
  }
  decision.zeroStreak = zeroStreak + 1;
  decision.abandoned = decision.zeroStreak >= MtaConstants.GROUP_CLIENT_ZERO_STREAK_LIMIT;
  return decision;
}

/** 取一批待发送文件的最大单文件字节数（纯函数；空批返回 0）。 */
export function maxSingleFileBytes(files: Array<MtaSendFile>): number {
  let maxBytes: number = 0;
  for (let i = 0; i < files.length; i++) {
    if (files[i].sizeBytes > maxBytes) {
      maxBytes = files[i].sizeBytes;
    }
  }
  return maxBytes;
}

/** 发送端服务编排门面 */
export class MtaSendService {
  /** 当前状态（对外仅暴露快照） */
  private state: SenderState = new SenderState();
  /** 事件回调（ViewModel 注入） */
  private handlers: MtaSendEventHandlers | null = null;
  /** 应用上下文（权限申请用） */
  private context: common.Context | undefined = undefined;
  /** BLE 客户端（扫描 + GATT Client） */
  private ble: MtaBleClient = new MtaBleClient();
  /** BLE 事件回调 */
  private bleHandlers: MtaBleClientEventHandlers = new MtaBleClientEventHandlers();
  /** 发送伴随 BLE 外设（广播 + GATT Server，与发送会话隔离；仅供对端反连并记录其行为） */
  private companionBle: MtaBleReceiver | null = null;
  /** 伴随外设事件回调（仅记录对端行为，不接入接收会话流程） */
  private companionHandlers: MtaBleEventHandlers = new MtaBleEventHandlers();
  /** 伴随外设上的对端行为累计 */
  private companionBehavior: MtaCompanionPeerBehavior = new MtaCompanionPeerBehavior();
  /** WiFi Direct 群组管理器 */
  private p2p: MtaP2pGroup = new MtaP2pGroup();
  /** P2P 事件回调 */
  private p2pHandlers: MtaP2pGroupEventHandlers = new MtaP2pGroupEventHandlers();
  /** 加解密模块（本会话 ECDH 密钥对） */
  private crypto: MtaCrypto = new MtaCrypto();
  /** 发送者显示名（取自设备昵称，无内容时以空串发送） */
  private senderName: string = '';
  /** 本机 2 字节发送者 ID 十六进制 */
  private senderIdHex: string = '';
  /** 是否有发送会话正在处理 */
  private sessionActive: boolean = false;
  /** 当前会话是否已被用户取消（阻止取消后的旧异步链路把 CANCELLED 覆盖为 FAILED） */
  private cancelledThisSession: boolean = false;
  /** 会话终态监听（完成/失败/取消时回调，供仓储恢复接收服务） */
  private sessionEndListener: (() => void) | null = null;
  /** 是否已订阅 Rust Mta* 事件 */
  private nativeSubscribed: boolean = false;
  /** Mta* 事件统一处理回调（订阅/退订需同一引用） */
  private nativeEventHandler: (event: NativeEvent) => void = (event: NativeEvent): void => {
    this.handleNativeEvent(event);
  };
  /** Rust 日志轮询定时器（-1 表示未运行） */
  private rustLogTimerId: number = -1;
  /** 群组客户端数轮询定时器（-1 表示未运行） */
  private groupClientTimerId: number = -1;
  /** 等待对端 WS 连接的超时定时器（-1 表示未运行） */
  private waitingWsTimerId: number = -1;
  /** 等待对端开始接收的超时定时器（-1 表示未运行） */
  private peerAcceptTimerId: number = -1;
  /** 传输阶段无进展看门狗定时器（-1 表示未运行） */
  private transferStallTimerId: number = -1;
  /** 上次群组客户端数（-1 表示未知） */
  private lastClientCount: number = -1;
  /** 本次会话是否曾观测到对端加入直连组（客户端数 ≥1），用于区分「从未入组」与「入组后离开」 */
  private peerJoinedGroupSeen: boolean = false;
  /** 本次会话观测到的最大群组客户端数（0 表示从未观测到客户端） */
  private maxGroupClientCount: number = 0;
  /** 本次会话群组信息读取不可得（getCurrentGroup 返回 null）的轮询次数 */
  private groupClientReadFailCount: number = 0;
  /** 写回 P2pInfo 后对端蓝牙链路是否出现过断开（对端取走凭据的佐证之一） */
  private peerLinkDroppedAfterWrite: boolean = false;
  /** 写回 P2pInfo 后对端蓝牙链路断开后是否又重连 */
  private peerLinkReconnectedAfterWrite: boolean = false;
  /** 写回 P2pInfo 后观测到的对端蓝牙链路事件序列（含相对写回的毫秒偏移） */
  private peerLinkEventsAfterWrite: Array<string> = [];
  /** 当前对端蓝牙链路连接基线（识别断/连跃迁，false 表示未连接或已断开） */
  private peerLinkConnected: boolean = false;
  /** 写回 P2pInfo 后复读对端公开信息的比对结论（null 表示未执行复读） */
  private peerInfoRecheck: MtaPeerInfoRecheckResult | null = null;
  /** 本次会话是否已成功发起写回 P2pInfo（供收束汇总写方式与判据，false 表示未写回） */
  private p2pWriteDone: boolean = false;
  /** 本次会话写回 P2pInfo 是否使用无响应写（无写回执，是否被处理由端到端信号判定） */
  private p2pWriteUsedNoResponse: boolean = false;
  /** 等待确认阶段连续观测到「群组客户端数归零 / 群组不可得」的次数（用于退组防抖判定） */
  private groupClientZeroStreak: number = 0;
  /**
   * 本次会话是否已观测到对端接入 WS：写回 P2pInfo 可能耗时较长（服务发现重试、写等待），
   * 期间对端可能已抢先接入并把阶段推进到更后阶段，据此避免阶段回退与重臂等待超时。
   */
  private wsConnectedSeen: boolean = false;
  /** 建链计时起点（sendToDevice 进入时刻） */
  private linkStartMs: number = 0;
  /** 建链阶段耗时记录（发送侧口径：用户点击发送起，覆盖「点击→各阶段」） */
  private linkTiming: MtaLinkTiming = new MtaLinkTiming();
  /** 用户点击发送的时刻（毫秒；0 表示未记录），由发送适配器注入 */
  private userClickMs: number = 0;
  /** 会话序号（单调递增）：非阻塞诊断据此丢弃上一会话的迟到结果 */
  private sessionSeq: number = 0;
  /**
   * 接收对外服务释放门（收发互斥解耦）：发起发送后不等待接收服务完全停用，
   * 本地准备（建组/起服）与其并行；仅在该门结算后启动发送伴随外设，避免争用广播/GATT 句柄。
   */
  private peripheralReleaseGate: Promise<void> = Promise.resolve();
  /** P2pInfo 写回完成时刻（用于计算等待对端 WS 连接耗时） */
  private p2pInfoWrittenMs: number = 0;
  /** sendRequest 发出时刻（用于计算请求→开始下载耗时） */
  private requestSentMs: number = 0;
  /** 本次会话是否已输出过「请求→结果」耗时日志（保证每会话至多一条） */
  private peerResultLogged: boolean = false;
  /** 对端开始下载时刻（用于计算传输阶段耗时；0 表示尚未开始下载） */
  private downloadStartedMs: number = 0;
  /** 已打开、尚未移交 Rust 的发送直读 fd（移交点见 startServer；移交前失败/取消由 closePendingSendFds 关闭） */
  private pendingSendFileHandles: Array<fs.File> = [];
  /** 本次会话生成的发送侧预览缩略图暂存路径（空串表示未生成；随资源释放删除） */
  private thumbnailTempPath: string = '';
  /** 资源释放一次性守卫：同一会话只真正释放一次（随会话起始复位） */
  private resourcesReleased: boolean = false;
  /** 取消通知等待的结算器（非 null 表示正在等待对端被通知） */
  private cancelWaitResolve: ((notified: boolean) => void) | null = null;
  /** 取消通知等待上限定时器（-1 表示未运行） */
  private cancelWaitTimerId: number = -1;
  /** 取消通知等待起始时刻（毫秒，用于输出等待耗时） */
  private cancelWaitStartMs: number = 0;

  // ── 生命周期与订阅 ──

  /** 注入事件回调 */
  setEventHandlers(handlers: MtaSendEventHandlers): void {
    this.handlers = handlers;
  }

  /** 注入应用上下文并初始化子模块 */
  init(context: common.Context): void {
    this.context = context;
    // 本机 MTA 设备 ID 持久化（跨会话稳定，与接收侧同一取值），对齐厂商行为；
    // 不再每次会话随机，使对端把我们在各会话间视为同一台设备
    this.senderIdHex = loadOrCreateMtaDeviceIdHex();
    // 发送方名称统一取自设备昵称（未设置时由 DeviceRepository 生成默认昵称）
    this.senderName = getDeviceAlias();
    this.bindBleHandlers();
    this.bindP2pHandlers();
    this.bindCompanionHandlers();
    this.ble.registerEvents(this.bleHandlers);
    this.p2p.registerEvents(this.p2pHandlers);
    this.subscribeNativeEvents();
    this.startRustLogPolling();
    this.appendLog('服务', `MTA 发送页就绪，发送者 ID=${this.senderIdHex} 发送者名称=${this.senderName}`,
      LogLevels.INFO);
  }

  /** 注入会话终态监听（完成/失败/取消时触发一次）；传 null 清除 */
  setSessionEndListener(listener: (() => void) | null): void {
    this.sessionEndListener = listener;
  }

  /** 注入用户点击发送的时刻（发送适配器在发起发送前调用），用于统一「点击→各阶段」耗时口径 */
  setUserClickMs(ms: number): void {
    this.userClickMs = ms;
  }

  /**
   * 注入接收对外服务释放门：发送本地准备与该门所代表的接收外设收尾并行推进，
   * 仅在启动发送伴随外设前等待其结算，实现收发互斥的「并行切换」。
   */
  setPeripheralReleaseGate(gate: Promise<void>): void {
    this.peripheralReleaseGate = gate;
  }

  /**
   * 结束当前会话（幂等）：先停止发送伴随外设，再通知一次终态。
   * 终态监听会恢复接收服务（重新广播 + 建 GATT Server），故必须在外设完全停止后再通知，
   * 避免两者争用系统广播/GATT 句柄（也覆盖完成/失败/取消各条收束路径）。
   */
  private endSession(): void {
    if (!this.sessionActive) {
      return;
    }
    this.sessionActive = false;
    // 会话终结即撤销"等待对端开始接收"窗口，避免终态后再次触发
    this.clearPeerAcceptTimeout();
    // 会话终结（完成/失败/取消）时清零下载开始时刻，避免跨会话残留
    this.downloadStartedMs = 0;
    this.stopCompanionPeripheral().then((): void => {
      this.notifySessionEnd();
    }, (e: Object): void => {
      // 兜底：停止流程自身已吞异常，正常不会走到这里；仍保证终态监听被通知一次
      logger.warn('停止发送伴随外设异常: ' + String(e));
      this.notifySessionEnd();
    });
  }

  /** 通知会话终态（供 endSession 在外设停止后调用一次） */
  private notifySessionEnd(): void {
    if (this.sessionEndListener !== null) {
      this.sessionEndListener();
    }
  }

  /**
   * 异步步骤间的取消检查点：会话已被取消或终止时幂等释放资源并返回 true。
   * 每个跨 await 的步骤之后调用，防止取消/终止后的旧异步链路继续推进
   * （覆盖 CANCELLED 终态、复活已停止的定时器、二次拉起已释放的资源）。
   */
  private async checkSessionAborted(): Promise<boolean> {
    if (this.sessionActive) {
      return false;
    }
    await this.releaseSendResources();
    return true;
  }

  // ── 状态与日志辅助 ──

  /** 切换阶段并推送状态快照 */
  private setStage(stage: MtaSenderStage): void {
    // 取消流程已启动：仅允许取消阶段/终态，避免迟到的链路阶段推进覆盖取消呈现
    if (this.cancelledThisSession && stage !== MtaSenderStage.CANCEL_NOTIFYING &&
      stage !== MtaSenderStage.CANCELLED) {
      return;
    }
    // 阶段单调：仅允许向前推进（新会话起始与终态/取消阶段不受限），
    // 避免迟到的异步事件把已推进的阶段拉回，保证阶段推进单调
    if (!isMtaSenderStageForward(this.state.stage, stage)) {
      this.appendLog('服务',
        `忽略回退的阶段切换：${this.state.stage} → ${stage}`, LogLevels.DEBUG);
      return;
    }
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

  // ── BLE 事件绑定 ──

  /** 绑定 BLE 事件回调：设备发现去重合并，状态事件转日志 */
  private bindBleHandlers(): void {
    this.bleHandlers.onDeviceFound = (device: MtaDiscoveredDevice): void => {
      this.mergeDevice(device);
    };
    this.bleHandlers.onScanStateChange = (scanning: boolean, detail: string): void => {
      this.state.scanning = scanning;
      this.notifyState();
      this.appendLog('扫描', detail, LogLevels.DEBUG);
    };
    this.bleHandlers.onBluetoothStateChange = (stateText: string): void => {
      this.appendLog('蓝牙', `开关状态变化: ${stateText}`, LogLevels.DEBUG);
    };
    this.bleHandlers.onGattConnectionChange = (stateText: string): void => {
      this.appendLog('GATT', `连接状态: ${stateText}`, LogLevels.DEBUG);
      this.recordPeerLinkChange(stateText);
    };
    this.bleHandlers.onMtuChange = (mtu: number): void => {
      this.appendLog('GATT', `MTU 协商完成: ${mtu}`, LogLevels.DEBUG);
    };
    this.bleHandlers.onRemoteDeviceInfo = (info: DeviceInfoJson): void => {
      this.appendLog('GATT', `读回对端 DeviceInfo：key=${info.key.length} 字符 mac=${info.mac}`, LogLevels.DEBUG);
    };
  }

  /** 按「设备身份键」去重合并设备：已存在则更新，否则追加 */
  private mergeDevice(device: MtaDiscoveredDevice): void {
    let key = mtaDeviceIdentityKey(device);
    let devices = this.state.devices.slice();
    let found = false;
    for (let i = 0; i < devices.length; i++) {
      if (mtaDeviceIdentityKey(devices[i]) === key) {
        devices[i] = device;
        found = true;
        break;
      }
    }
    if (!found) {
      devices.push(device);
    }
    this.state.devices = devices;
    this.notifyState();
  }

  /** 绑定 P2P 事件回调：连接摘要与 GO IP 转日志/状态 */
  private bindP2pHandlers(): void {
    this.p2pHandlers.onConnectionChange = (summary: string): void => {
      this.appendLog('P2P', summary, LogLevels.DEBUG);
    };
    this.p2pHandlers.onGoIp = (goIp: string): void => {
      if (this.state.session !== undefined) {
        this.state.session.goIp = goIp;
        this.notifyState();
      }
      this.appendLog('P2P', `取得 GO IP=${goIp}`, LogLevels.DEBUG);
    };
  }

  // ── 发送伴随 BLE 外设（隔离于发送会话） ──

  /**
   * 绑定发送伴随外设事件回调：**仅记录**对端行为，绝不接入接收会话流程
   *（不调用、不复刻 MtaReceiveService 的 P2pInfo 接收处理），保证该外设与发送会话隔离。
   */
  private bindCompanionHandlers(): void {
    this.companionHandlers.onAdvertiseStateChange = (running: boolean, detail: string): void => {
      this.appendLog('伴随外设', running ? `广播已启动（${detail}）` : `广播已停止（${detail}）`, LogLevels.DEBUG);
    };
    this.companionHandlers.onGattConnectionChange = (clientDeviceId: string, stateText: string): void => {
      if (stateText === '已连接') {
        this.companionBehavior.connectCount++;
      } else if (stateText === '已断开') {
        this.companionBehavior.disconnectCount++;
      }
      this.appendLog('伴随外设', `对端连接状态=${stateText} 客户端=${clientDeviceId}`,
        stateText === '已连接' ? LogLevels.INFO : LogLevels.DEBUG);
    };
    this.companionHandlers.onGattReadRequest = (clientDeviceId: string, offset: number): void => {
      this.companionBehavior.readCount++;
      this.appendLog('伴随外设', `对端读请求 客户端=${clientDeviceId} offset=${offset}`, LogLevels.DEBUG);
    };
    this.companionHandlers.onGattWriteProgress =
      (deviceId: string, offset: number, totalLength: number, isPrepared: boolean): void => {
        this.companionBehavior.writeCount++;
        let target = this.companionBle !== null ? this.companionBle.getLastWriteTargetUuid() : '';
        this.appendLog('伴随外设',
          `对端写请求 ${formatCompanionWriteRequest(target, offset, totalLength, isPrepared)} 客户端=${deviceId}`,
          LogLevels.DEBUG);
      };
    this.companionHandlers.onP2pInfoReceived = (deviceId: string, payloadText: string): void => {
      // 仅记录：不得触发接收会话流程（该外设与发送会话隔离）
      this.companionBehavior.p2pInfoReceived = true;
      this.appendLog('伴随外设',
        `对端写入 P2pInfo（仅记录，不接入接收会话）客户端=${deviceId} 长度=${payloadText.length}`,
        LogLevels.INFO);
    };
  }

  /**
   * 启动发送伴随 BLE 外设：复用 MtaBleReceiver 启动广播与 GATT Server，供对端反连。
   * 该外设与发送会话隔离——对端读写仅记录并回响应（MtaBleReceiver 已对读写回 sendResponse），
   * 不接入接收会话。启动失败不阻断发送（外设仅用于对端反连与记录），但会清理残余句柄。
   * 启动过程中若会话已终结则立即停止，避免与随后恢复的接收服务争用广播/GATT 句柄。
   */
  private async startCompanionPeripheral(localPublicKey: string): Promise<void> {
    if (this.companionBle !== null || !this.sessionActive) {
      return;
    }
    let peripheral = new MtaBleReceiver();
    this.companionBle = peripheral;
    peripheral.registerEvents(this.companionHandlers);
    let deviceInfoJson = this.buildCompanionDeviceInfo(localPublicKey);
    try {
      let preview = await peripheral.startAdvertising(this.senderName, getMtaSimulatedBrand());
      if (!this.sessionActive) {
        await this.stopCompanionPeripheral();
        return;
      }
      await peripheral.startGattServer(deviceInfoJson);
      if (!this.sessionActive) {
        await this.stopCompanionPeripheral();
        return;
      }
      this.appendLog('伴随外设',
        `发送伴随外设已启动（广播 + GATT Server），供对端反连；外设 senderId=${peripheral.getSenderIdHex()}` +
          ` DeviceInfo=${deviceInfoJson}`,
        LogLevels.INFO);
      this.appendLog('伴随外设', `广播预览：${preview.split('\n').join('；')}`, LogLevels.DEBUG);
    } catch (e) {
      this.appendLog('伴随外设', '启动发送伴随外设失败（不影响发送）: ' + String(e), LogLevels.WARN);
      await this.stopCompanionPeripheral();
    }
  }

  /**
   * 构造发送伴随外设对外提供的 DeviceInfo（CHAR_STATUS 读返回值）。
   * key 使用发送会话公钥（与写回对端的 P2pInfo.key 同源，保持一致身份）；公钥缺失时以合法占位兜底。
   * state/mac/catShare 与接收服务口径一致，保证对端读到可解析内容。
   */
  private buildCompanionDeviceInfo(localPublicKey: string): string {
    let info = new DeviceInfoJson();
    info.state = MtaConstants.DEVICE_INFO_STATE;
    info.mac = MtaConstants.FALLBACK_MAC;
    info.key = localPublicKey.length > 0 ? localPublicKey : MtaConstants.COMPANION_DEVICE_INFO_PUBLIC_KEY;
    info.catShare = MtaConstants.CATSHARE_VERSION;
    return JSON.stringify(info);
  }

  /**
   * 停止发送伴随外设（幂等）：停广播、停 GATT Server 并退订事件。
   * 入口即置空实例引用，保证并发/重入时只真正停止一次；确保与随后恢复的接收服务
   * 不争用广播/GATT 句柄，且无残留事件监听或句柄泄漏。
   */
  private stopCompanionPeripheral(): Promise<void> {
    let peripheral = this.companionBle;
    if (peripheral === null) {
      return Promise.resolve();
    }
    this.companionBle = null;
    return this.teardownCompanionPeripheral(peripheral);
  }

  /** 停止单个伴随外设实例并汇总其上的对端行为（供 stopCompanionPeripheral 调用一次） */
  private async teardownCompanionPeripheral(peripheral: MtaBleReceiver): Promise<void> {
    try {
      await peripheral.stopAdvertising();
    } catch (e) {
      this.appendLog('伴随外设', '停止伴随外设广播失败: ' + String(e), LogLevels.ERROR);
    }
    try {
      await peripheral.stopGattServer();
    } catch (e) {
      this.appendLog('伴随外设', '停止伴随外设 GATT Server 失败: ' + String(e), LogLevels.ERROR);
    }
    peripheral.unregisterEvents();
    this.logCompanionPeerBehaviorSummary();
  }

  /** 汇总输出发送伴随外设上的对端行为（连接/断开/读/写/是否收到 P2pInfo） */
  private logCompanionPeerBehaviorSummary(): void {
    this.appendLog('伴随外设', formatCompanionPeerBehaviorSummary(this.companionBehavior), LogLevels.INFO);
  }

  // ── 发送流程 ──

  /**
   * 建立发送链路并启动传输：GATT 连接 → 读对端 DeviceInfo（含公钥）→ 建 WiFi Direct 组
   * → 打开直读 fd（文件直读源 URI，不复制；文本条目走落盘文本文件）→ 启动 Rust TLS
   * 服务器取真实端口 → 加密凭据并写回 P2pInfo → 等待对端协商/下载。
   */
  async sendToDevice(device: MtaDiscoveredDevice, files: Array<MtaSendFile>,
    text?: string): Promise<void> {
    if (this.sessionActive) {
      this.appendLog('服务', '已有发送会话进行中，忽略新的发送请求', LogLevels.WARN);
      return;
    }
    let textValue = text !== undefined ? text : '';
    if (files.length === 0 && textValue.length === 0) {
      this.appendLog('服务', '未选择文件且无文本内容，无法发送', LogLevels.WARN);
      this.setError('无可发送内容');
      return;
    }
    this.linkStartMs = Date.now();
    // 建链阶段耗时口径：起点取用户点击时刻（适配器注入），缺失时退回进入时刻
    this.linkTiming.begin(this.userClickMs > 0 ? this.userClickMs : this.linkStartMs);
    this.sessionSeq++;
    this.p2pInfoWrittenMs = 0;
    this.requestSentMs = 0;
    this.peerResultLogged = false;
    this.downloadStartedMs = 0;
    this.sessionActive = true;
    this.cancelledThisSession = false;
    this.resourcesReleased = false;
    this.groupClientZeroStreak = 0;
    this.wsConnectedSeen = false;
    this.peerJoinedGroupSeen = false;
    this.maxGroupClientCount = 0;
    this.groupClientReadFailCount = 0;
    this.peerLinkDroppedAfterWrite = false;
    this.peerLinkReconnectedAfterWrite = false;
    this.peerLinkEventsAfterWrite = [];
    this.peerLinkConnected = false;
    this.peerInfoRecheck = null;
    this.p2pWriteDone = false;
    this.p2pWriteUsedNoResponse = false;
    this.state.selected = device;
    let session = new MtaSendSession();
    session.taskId = randomTaskId();
    session.senderIdHex = this.senderIdHex;
    session.senderName = this.senderName;
    this.state.session = session;
    this.state.lastError = '';
    this.state.groupCreated = false;
    this.state.serverRunning = false;
    this.state.progress = new MtaSendProgress();
    // 文本发送：把文本写入发送文本目录（filesDir/text_send/）的 sharedText.txt，作为唯一 ZIP 条目（1/sharedText.txt）
    let effectiveFiles = files;
    if (textValue.length > 0) {
      try {
        effectiveFiles = [this.writeSharedTextFile(session.taskId, textValue)];
      } catch (e) {
        await this.failSend('写入文本文件失败: ' + String(e));
        return;
      }
    }
    session.totalBytes = totalFileBytes(effectiveFiles);
    // 条目数仍为格式守卫（超限快速失败，避免构造对端无法解析的传输）；
    // 总大小与单文件不再设功能上限：达到大文件阈值时仅提示风险，由发送前 UI 二次确认，此处留痕后继续。
    if (effectiveFiles.length > MtaConstants.MAX_SEND_ENTRY_COUNT) {
      await this.failSend(`文件数超过上限 ${MtaConstants.MAX_SEND_ENTRY_COUNT}`);
      return;
    }
    if (isLargeTransfer(session.totalBytes, maxSingleFileBytes(effectiveFiles))) {
      this.appendLog('服务',
        `大文件传输（总大小=${session.totalBytes}字节），可能因超时/断连/对端拒收而失败`, LogLevels.WARN);
    }
    this.appendLog('服务', `开始发送到 ${device.deviceName} (${device.bleAddress})，任务=${session.taskId}`,
      LogLevels.INFO);

    if (await this.checkSessionAborted()) {
      return;
    }

    // 1) 生成会话 ECDH 密钥对
    try {
      session.localPublicKey = await this.crypto.generateKeyPair();
    } catch (e) {
      await this.failSend('生成 ECDH 密钥对失败: ' + String(e));
      return;
    }

    // 1.5) 并行启动与对端无关的本地准备：本地传输服务（含直读 fd 与预览生成）不占用无线资源，
    //      点击后即可推进，并与接收对外服务收尾、后续 BLE 凭据交换并行。
    let preparation = new MtaSendPreparation();
    preparation.groupName = randomGroupName();
    preparation.passphrase = randomPassphrase();
    preparation.peerAddress = device.bleAddress;
    let serverPromise = this.runServerPreparation(preparation, session, effectiveFiles, textValue);

    // 1.6) 收发互斥并行切换：等待接收对外服务释放门（该门与上述本地服务准备并行推进），
    //      结算后即可启动建组与发送伴随外设，避免两者争用 P2P 状态机与广播/GATT 句柄。
    await this.peripheralReleaseGate;
    if (await this.checkSessionAborted()) {
      return;
    }

    // 1.7) 接收外设已释放：启动并行建组（清理旧组→建组→等待就绪），与后续 BLE 凭据交换
    //      （地址获取/连接/读取/写回）并行推进，缩短到「写回凭据」的总时间。
    let groupPromise = this.runGroupCreation(preparation, device);

    // 2) 启动发送伴随 BLE 外设（广播 + GATT Server）：对端（如中兴）会反连发送方的外设，
    //      该反连是其处理本机 P2pInfo 写回的前置；本外设与发送会话隔离——对端的读写仅记录并
    //      回响应、不接入接收会话。须在对端 GATT 连接之前启动（越早越利于对端反连），
    //      且此时接收服务已释放，不会与外设争用广播/GATT 句柄。DeviceInfo.key 用本会话公钥。
    await this.startCompanionPeripheral(session.localPublicKey);
    if (await this.checkSessionAborted()) {
      return;
    }
    this.linkTiming.mark('伴随外设就绪', Date.now());

    // 3) GATT 连接：优先使用点击时记录的广播地址直连；仅在实际连接失败后才按 senderId 重扫回退
    this.setStage(MtaSenderStage.GATT_CONNECTING);
    let gattConnectStartMs = Date.now();
    let connected = false;
    for (let attempt = 1; attempt <= MtaConstants.GATT_CONNECT_MAX_ATTEMPTS; attempt++) {
      if (await this.checkSessionAborted()) {
        return;
      }
      let address = device.bleAddress;
      let rescanned = false;
      let rescanAttempted = shouldRescanPeerAddress(device.bleAddress, attempt);
      if (rescanAttempted) {
        let fresh = await this.ble.resolveFreshAddress(device.senderIdHex,
          MtaConstants.GATT_ADDRESS_RESCAN_TIMEOUT_MS);
        if (fresh !== null) {
          address = fresh;
          rescanned = true;
        }
      }
      let addressSource = rescanned ? '重扫命中' :
        (rescanAttempted ? '重扫未命中，沿用记录地址' : '先用记录地址');
      this.appendLog('GATT',
        `第 ${attempt}/${MtaConstants.GATT_CONNECT_MAX_ATTEMPTS} 次连接 地址=${address}（${addressSource}）`,
        LogLevels.DEBUG);
      try {
        await this.ble.connectGattClient(address);
      } catch (e) {
        this.appendLog('GATT', `第 ${attempt} 次连接发起失败: ${String(e)}`, LogLevels.WARN);
        continue;
      }
      connected = await this.ble.waitGattConnected(MtaConstants.GATT_CONNECT_TIMEOUT_MS);
      if (await this.checkSessionAborted()) {
        return;
      }
      if (connected) {
        break;
      }
      // 释放本次未连上的 client，避免残留句柄阻断下一次连接
      try {
        await this.ble.disconnectGattClient();
      } catch (e) {
        this.appendLog('GATT', '重连前释放 GATT 失败: ' + String(e), LogLevels.DEBUG);
      }
    }
    if (!connected) {
      await this.failSend('GATT 连接超时');
      return;
    }
    this.appendLog('GATT', '已连接对端 GATT Server', LogLevels.INFO);
    this.appendLog('计时', `GATT 连接耗时=${Date.now() - gattConnectStartMs}ms`, LogLevels.DEBUG);
    this.linkTiming.mark('GATT连接', Date.now());

    // 4) 读对端 DeviceInfo（含公钥）
    let remoteInfo: DeviceInfoJson;
    let firstDeviceInfoRaw = '';
    let readInfoStartMs = Date.now();
    try {
      remoteInfo = await this.ble.readRemoteDeviceInfo();
      // 留存首次读取原文，供写回后复读比对（判定写回是否被对端处理）
      firstDeviceInfoRaw = this.ble.getLastDeviceInfoRawText();
    } catch (e) {
      await this.failSend('读取对端 DeviceInfo 失败: ' + String(e));
      return;
    }
    if (await this.checkSessionAborted()) {
      return;
    }
    this.appendLog('计时',
      `读取对端 DeviceInfo 耗时=${Date.now() - readInfoStartMs}ms（含 MTU 协商与服务发现）`, LogLevels.DEBUG);
    this.linkTiming.mark('对端信息读取', Date.now());

    // 4.5) 对端忙判定：对端（如小米互传）在上一会话结束后的收尾期内仍处于忙状态，
    //      其 DeviceInfo.state 会变为非就绪值且不再返回 mac；此时对端不会加入新的 WiFi Direct
    //      组，后续写回的 P2pInfo 也会被其静默丢弃，只能干等到超时。故在建组前提前收束，
    //      不建组、不起服、不写凭据。判定为严格「非就绪即忙」，就绪值不改变任何既有流程。
    //      本机在对端弹出确认前取消时，对端已持有凭据并进入忙态，收尾期内会短暂残留；
    //      故对「明确冲突」以外（含未知原因）的忙按间隔复读，就绪即继续，窗口用尽才收束。
    let busyAttempts = 0;
    while (shouldRetryPeerBusy(remoteInfo.state, remoteInfo.reason) &&
      busyAttempts < MtaConstants.PEER_BUSY_RETRY_MAX_ATTEMPTS) {
      busyAttempts++;
      // 对端收尾期残留：进入「等待对端就绪」阶段，让用户看到进度而非无反馈等待
      this.setStage(MtaSenderStage.WAITING_PEER_READY);
      this.appendLog('GATT',
        `对端忙（state=${remoteInfo.state} reason=${remoteInfo.reason}` +
          `（${mtaPeerBusyReasonText(remoteInfo.reason)}）），${MtaConstants.PEER_BUSY_RETRY_INTERVAL_MS}ms 后` +
          `复读 DeviceInfo（第 ${busyAttempts}/${MtaConstants.PEER_BUSY_RETRY_MAX_ATTEMPTS} 次）`,
        LogLevels.DEBUG);
      await sleepMs(MtaConstants.PEER_BUSY_RETRY_INTERVAL_MS);
      if (await this.checkSessionAborted()) {
        return;
      }
      try {
        remoteInfo = await this.ble.readRemoteDeviceInfo();
      } catch (e) {
        await this.failSend('读取对端 DeviceInfo 失败: ' + String(e));
        return;
      }
    }
    if (isMtaPeerBusy(remoteInfo.state)) {
      this.appendLog('GATT',
        `对端忙，提前收束本次发送：state=${remoteInfo.state}（就绪值=${MtaConstants.DEVICE_INFO_STATE}）` +
          ` reason=${remoteInfo.reason}（${mtaPeerBusyReasonText(remoteInfo.reason)}）` +
          ` 对端=${device.deviceName}(${device.bleAddress}) 任务=${session.taskId}`,
        LogLevels.WARN);
      await this.failSend(MTA_PEER_BUSY_TEXT);
      return;
    }

    // 5) 取并行建组结果：非 Samsung 且对端支持 5GHz 时显式优先请求 5GHz（有界就绪探测），
    //    超时/请求抛错即快速回退 2.4GHz；就绪后以实际群点为准，请求 5GHz 而实际落 2.4GHz 时按实际接受
    this.setStage(MtaSenderStage.GROUP_CREATING);
    let groupResult: MtaGroupCreationResult = await groupPromise;
    if (await this.checkSessionAborted()) {
      return;
    }
    let groupInfo = groupResult.info;
    if (groupInfo === null) {
      await this.failSend('建组失败，未取得群组信息');
      return;
    }
    session.groupSsid = groupInfo.ssid;
    session.groupPsk = groupInfo.psk.length > 0 ? groupInfo.psk : preparation.passphrase;
    // P2pInfo.mac 须等于对端可见的群主设备地址（小米端校验 owner.deviceAddress.equalsIgnoreCase(mac)，
    // 不符即 unrecognized network owner 中止入组，并可能滞留忙态）。群主地址只能取 Native 读到的
    // P2P 网卡硬件地址：ownerInfo.deviceAddress 对三方应用是随机值，下发随机地址必被对端拒收，
    // 故读取失败一律按建组失败收束，不做随机地址降级。
    if (groupResult.localMac.length === 0) {
      this.appendLog('P2P',
        `本机 P2P 设备地址不可得（ownerInfo=${groupInfo.ownerMac} 为随机值，不可下发）`,
        LogLevels.ERROR);
      await this.failSend('本机 P2P 设备地址不可得，无法向对端声明群主身份');
      return;
    }
    // 对外发送的本机 P2P 地址统一归一为小写：接收端比对地址的大小写策略不同（中兴严格相等、
    // 小米不敏感），小写可同时满足；并保证后续加密分支携带的明文也为小写
    //（加密分支的 Base64 密文大小写敏感，不能在下游再改）
    session.localMac = normalizeMtaP2pMac(groupResult.localMac);
    this.appendLog('P2P',
      `P2pInfo.mac 采用=${session.localMac}（ownerInfo=${groupInfo.ownerMac} 仅诊断）`,
      LogLevels.DEBUG);
    session.groupFrequency = groupInfo.frequency;
    session.goIp = groupInfo.goIp.length > 0 ? groupInfo.goIp : this.p2p.getGoIp();
    this.state.groupCreated = true;
    this.notifyState();
    this.appendLog('P2P',
      `建组完成 ssid=${session.groupSsid} mac=${session.localMac} goIp=${session.goIp} ` +
        `频点=${session.groupFrequency}MHz(${bandLabelFromFrequency(session.groupFrequency)})`, LogLevels.INFO);
    this.linkTiming.mark('组网就绪', Date.now());

    // 6) 取并行启动的本地传输服务端口（直读 fd 与预览生成已在并行任务内完成）
    this.setStage(MtaSenderStage.SERVER_STARTING);
    let serverPort: number = await serverPromise;
    if (await this.checkSessionAborted()) {
      return;
    }
    // 写回凭据的关键路径就绪判定：仅当「组就绪 + 对端信息可写 + 端口已知」全部满足才继续
    if (serverPort <= 0 || !resolveSendWritebackReady(preparation.groupReady, true, serverPort)) {
      let reason = preparation.serverError.length > 0 ? preparation.serverError : '本地传输服务未就绪';
      await this.failSend(reason);
      return;
    }
    session.port = serverPort;
    this.state.serverRunning = true;
    this.notifyState();
    this.appendLog('服务器',
      `TLS 服务器已启动 bindIp=${MtaConstants.DEFAULT_BIND_IP} port=${session.port}`, LogLevels.INFO);
    this.linkTiming.mark('本地服务就绪', Date.now());

    // 7) 写回 P2pInfo（对端提供公钥则加密，否则明文；携带群组频点 freq）
    let credentials = new DecryptedCredentials();
    credentials.ssid = session.groupSsid;
    credentials.psk = session.groupPsk;
    credentials.mac = session.localMac;
    let p2pInfo: P2pInfoJson;
    if (remoteInfo.key.length > 0) {
      let encrypted: EncryptedCredentials;
      try {
        encrypted = await this.crypto.encryptCredentials(remoteInfo, credentials);
      } catch (e) {
        await this.failSend('加密凭据失败: ' + String(e));
        return;
      }
      if (await this.checkSessionAborted()) {
        return;
      }
      p2pInfo = this.buildP2pInfoJson(session, encrypted.ssid, encrypted.psk, encrypted.mac,
        session.localPublicKey, session.port);
    } else {
      p2pInfo = this.buildP2pInfoJson(session, credentials.ssid, credentials.psk, credentials.mac,
        '', session.port);
    }
    let p2pInfoText = p2pInfo.toJsonText();
    let writeStartMs = Date.now();
    let usedNoResponseWrite = false;
    try {
      usedNoResponseWrite = await this.ble.writeRemoteP2pInfo(p2pInfoText);
    } catch (e) {
      // 写回失败：记录结果、耗时与原因（与 MtaBleClient 的细粒度写诊断口径一致）
      this.appendLog('GATT',
        `写回 P2pInfo 结果=失败 耗时=${Date.now() - writeStartMs}ms 原因=${String(e)}`, LogLevels.WARN);
      await this.failSend('写入 P2pInfo 失败: ' + String(e));
      return;
    }
    if (await this.checkSessionAborted()) {
      return;
    }
    this.p2pWriteDone = true;
    this.p2pWriteUsedNoResponse = usedNoResponseWrite;
    this.appendLog('GATT', `已写回 P2pInfo: ${p2pInfoText}`, LogLevels.DEBUG);
    this.p2pInfoWrittenMs = Date.now();
    this.linkTiming.mark('写回凭据', Date.now());
    // 写回结果语义：带响应写以收到对端写回调为「成功」；无响应写无回调，本地返回即「已发出」，
    // 不以写回执判定成功/失败，是否被对端处理交由端到端信号与收束汇总判定（见 logP2pWriteSummary）
    if (usedNoResponseWrite) {
      this.appendLog('GATT',
        '写回 P2pInfo 结果=已发出（无响应写，无对端写回调；是否被处理由端到端信号判定）', LogLevels.DEBUG);
    } else {
      this.appendLog('GATT', '写回 P2pInfo 结果=成功（收到带响应写回调）', LogLevels.DEBUG);
    }
    this.appendLog('计时', `写回 P2pInfo 耗时=${Date.now() - writeStartMs}ms`, LogLevels.DEBUG);
    // 阶段耗时口径：点击→写回凭据（对端可在此后开始处理并弹出确认）
    let clickBaseMs = this.userClickMs > 0 ? this.userClickMs : this.linkStartMs;
    this.appendLog('计时',
      `点击→写回凭据耗时=${Date.now() - clickBaseMs}ms 发送建链阶段=[${this.linkTiming.summary()}]`,
      LogLevels.DEBUG);
    // 写回后主动复读对端公开信息（D-probe）改为非阻塞诊断：与「等待对端入组」并行采集，
    // 结果仅用于收束归因，不阻断阶段推进（对端「读正常、写无响应」时，本地写返回成功不能证明
    // 对端已处理；复读成败与内容变化是「写回是否被对端处理」的直接判定依据）。
    this.startPeerInfoRecheckInBackground(firstDeviceInfoRaw, remoteInfo.state, this.sessionSeq);
    // 写回期间对端可能已抢先接入（写路径含服务发现重试与写等待，最长数十秒）：阶段已被迟到
    // 事件推进到更后阶段，此时不得回退阶段、也不得再武装等待 WS 超时（否则传输中会误判超时）
    if (this.wsConnectedSeen) {
      this.appendLog('服务', '写回 P2pInfo 期间对端已建立 WS 连接，沿用当前阶段', LogLevels.DEBUG);
    } else {
      this.setStage(MtaSenderStage.P2P_INFO_WRITTEN);
      this.setStage(MtaSenderStage.WAITING_WS);
      this.appendLog('服务', '等待对端建立 WS 连接...', LogLevels.DEBUG);
      this.startWaitingWsTimeout();
    }
    // 轮询群组客户端数，判定对端是否已加入 WiFi Direct 组
    this.startGroupClientPolling();
  }

  /**
   * 与对端无关的本地建组（并行任务）：点击后立即「有界清理旧组 → 建组 → 以群组身份校验就绪」，
   * 与 BLE 地址获取/连接/读取并行推进；就绪组名须等于本次请求创建的组名，不匹配即视为未就绪
   * 并在候选预算内重试，绝不采用上一会话残留群组的凭据；会话终止时提前返回，建组结果交由资源释放路径删除。
   */
  private async runGroupCreation(prep: MtaSendPreparation,
    device: MtaDiscoveredDevice): Promise<MtaGroupCreationResult> {
    let result = new MtaGroupCreationResult();
    let candidateBands = resolvePreferredGroupBands(device.brandId, device.is5Ghz);
    // 建组前记录本机并发 STA 频段快照：用于区分“并发 STA 频段约束”与“建组参数问题”
    this.appendLog('P2P', `本机 STA 频段快照：${this.p2p.getStaBandText()}`, LogLevels.DEBUG);
    let groupTotalStartMs = Date.now();
    for (let i = 0; i < candidateBands.length; i++) {
      if (!this.sessionActive) {
        return result;
      }
      let candidate: MtaGroupBandCandidate = candidateBands[i];
      let goBand = candidate.band;
      let goFreq = candidate.freqMhz;
      let is5Ghz = goBand === MtaConstants.GROUP_OWNER_BAND_5GHZ;
      let bandText = is5Ghz ? '5GHz' : '2.4GHz';
      let freqText = goFreq > 0 ? `${goFreq}MHz` : '未限定';
      // 5GHz 候选施加受限的短就绪探测；2.4GHz 候选使用较宽超时
      let readyTimeoutMs =
        is5Ghz ? MtaConstants.GROUP_READY_TIMEOUT_5GHZ_MS : MtaConstants.GROUP_READY_TIMEOUT_MS;
      // 候选总预算：身份不匹配时的重试用同一个预算，避免多次尝试叠加成可感知的长等待
      let candidateDeadlineMs = Date.now() + readyTimeoutMs;
      let identity: SessionGroupIdentity = matchMtaGroupIdentity(prep.groupName, '');
      let adopted = false;
      for (let attempt = 1;
        attempt <= MtaConstants.GROUP_CREATE_IDENTITY_MAX_ATTEMPTS && this.sessionActive;
        attempt++) {
        if (Date.now() >= candidateDeadlineMs) {
          break;
        }
        // 建组前有界处置上一会话残留群组：确认其消失，避免平台因旧组仍在而忽略本次建组；
        // 超时未消失不阻断建组，改由下述建组身份校验兜底
        try {
          await this.p2p.removeGroup();
        } catch (e) {
          this.appendLog('P2P', '建组前清理旧组失败: ' + String(e), LogLevels.DEBUG);
        }
        let residualCleared = await this.p2p.waitGroupAbsent(
          Math.min(MtaConstants.GROUP_RESIDUAL_CLEAR_TIMEOUT_MS, candidateDeadlineMs - Date.now()));
        if (!this.sessionActive) {
          return result;
        }
        if (!residualCleared) {
          this.appendLog('P2P',
            `建组前旧组未在有界时间内消失，仍按本次请求组名建组并交由身份校验兜底` +
              `（候选 ${i + 1}/${candidateBands.length} 尝试 ${attempt}/` +
              `${MtaConstants.GROUP_CREATE_IDENTITY_MAX_ATTEMPTS}）`,
            LogLevels.WARN);
        }
        try {
          await this.p2p.createGroup(prep.groupName, prep.passphrase, goBand, goFreq);
          this.appendLog('P2P',
            `建组请求已发送 groupName=${prep.groupName} goBand=${goBand}(${bandText}) goFreq=${freqText}` +
              `（候选 ${i + 1}/${candidateBands.length} 尝试 ${attempt}/` +
              `${MtaConstants.GROUP_CREATE_IDENTITY_MAX_ATTEMPTS}）`,
            LogLevels.DEBUG);
        } catch (e) {
          this.appendLog('P2P',
            `建组请求失败 goBand=${goBand}(${bandText}) goFreq=${freqText}` +
              `（候选 ${i + 1}/${candidateBands.length}）: ${String(e)}`,
            LogLevels.WARN);
          break;
        }
        // 会话在建组期间终止：主动删除可能已建立的组，避免残留（资源释放路径可能已先删过一次）
        if (!this.sessionActive) {
          try {
            await this.p2p.removeGroup();
          } catch (e) {
            this.appendLog('P2P', '会话终止后清理并行建组失败: ' + String(e), LogLevels.DEBUG);
          }
          return result;
        }
        let remainingMs = candidateDeadlineMs - Date.now();
        if (remainingMs <= 0) {
          break;
        }
        let readyStartMs = Date.now();
        let info = await this.p2p.waitGroupReady(remainingMs, prep.groupName);
        let readyCostMs = Date.now() - readyStartMs;
        if (!this.sessionActive) {
          return result;
        }
        // 就绪判定以群组身份为准：只有观测组名等于本次请求组名才可采用其凭据
        identity = matchMtaGroupIdentity(prep.groupName, info === null ? '' : info.ssid);
        if (info !== null && identity.matched) {
          // waitGroupReady 返回的 info 即 getCurrentGroup() 的当前结果，其 frequency 为实际群点；
          // 请求 5GHz 而平台实际落在 2.4GHz 时按实际频段接受，不重复建组
          this.appendLog('P2P',
            `候选建组就绪 groupName=${prep.groupName} goBand=${goBand}(${bandText}) goFreq=${freqText}` +
              `（候选 ${i + 1}/${candidateBands.length} 尝试 ${attempt}/` +
              `${MtaConstants.GROUP_CREATE_IDENTITY_MAX_ATTEMPTS} 身份匹配=是）` +
              ` 耗时=${readyCostMs}ms 实际群点=${info.frequency}MHz(${bandLabelFromFrequency(info.frequency)})`,
            LogLevels.DEBUG);
          result.info = info;
          adopted = true;
          break;
        }
        if (info === null) {
          this.appendLog('P2P',
            `建组超时，未取得群组信息 goBand=${goBand}(${bandText}) goFreq=${freqText}` +
              `（候选 ${i + 1}/${candidateBands.length} 尝试 ${attempt}/` +
              `${MtaConstants.GROUP_CREATE_IDENTITY_MAX_ATTEMPTS}）耗时=${readyCostMs}ms`,
            LogLevels.WARN);
        } else {
          this.appendLog('P2P',
            `建组身份不匹配（就绪组非本次请求创建的组，不采用其凭据）` +
              ` 请求组名=${identity.requestedName} 观测组名=${identity.observedName}` +
              ` goBand=${goBand}(${bandText}) goFreq=${freqText}` +
              `（候选 ${i + 1}/${candidateBands.length} 尝试 ${attempt}/` +
              `${MtaConstants.GROUP_CREATE_IDENTITY_MAX_ATTEMPTS}）耗时=${readyCostMs}ms`,
            LogLevels.WARN);
        }
      }
      if (adopted) {
        break;
      }
      if (!this.sessionActive) {
        return result;
      }
      this.appendLog('P2P',
        `建组候选失败，未取得身份匹配的群组 goBand=${goBand}(${bandText}) goFreq=${freqText}` +
          `（候选 ${i + 1}/${candidateBands.length}）`,
        LogLevels.WARN);
    }
    if (result.info === null) {
      return result;
    }
    result.localMac = await this.p2p.resolveP2pInterfaceMac();
    if (!this.sessionActive) {
      // 会话在就绪/地址解析期间终止：删除已建立的组，避免残留
      try {
        await this.p2p.removeGroup();
      } catch (e) {
        this.appendLog('P2P', '会话终止后清理并行建组失败: ' + String(e), LogLevels.DEBUG);
      }
      result.info = null;
      result.localMac = '';
      return result;
    }
    prep.groupReady = true;
    this.appendLog('计时',
      `P2P 建组总耗时=${Date.now() - groupTotalStartMs}ms（候选数=${candidateBands.length}）`, LogLevels.DEBUG);
    return result;
  }

  /**
   * 与对端无关的本地传输服务准备（并行任务）：打开直读 fd → 生成预览 → 启动 Rust TLS 服务器取端口。
   * 绑定 0.0.0.0（由系统分配端口），不依赖 P2P 接口先就绪即可起服；会话终止或失败时回收迟到资源并返回 -1。
   */
  private async runServerPreparation(prep: MtaSendPreparation, session: MtaSendSession,
    effectiveFiles: Array<MtaSendFile>, textValue: string): Promise<number> {
    if (!this.sessionActive) {
      return -1;
    }
    let sendFiles: Array<MtaSendFile>;
    let stageStartMs = Date.now();
    try {
      sendFiles = this.openSendFds(effectiveFiles);
      // 实际大小/修改时间取自已打开句柄（与将发送字节同源），重算会话总字节（进度分母与 Rust 一致）
      session.totalBytes = totalFileBytes(sendFiles);
      session.files = sendFiles;
      prep.fdsOpened = true;
      this.appendLog('直读', `已打开 ${sendFiles.length} 个文件的直读 fd（源 URI 直读，无暂存复制）`, LogLevels.DEBUG);
      this.appendLog('计时',
        `打开直读 fd 耗时=${Date.now() - stageStartMs}ms 文件数=${sendFiles.length} 总字节=${session.totalBytes}`,
        LogLevels.DEBUG);
    } catch (e) {
      prep.serverError = '打开发送直读 fd 失败: ' + String(e);
      this.appendLog('直读', prep.serverError, LogLevels.WARN);
      if (this.sessionActive) {
        await this.stopInFlightServerResources();
      }
      return -1;
    }
    // 移交点检查：fd 尚未移交 Rust，会话若已终止则在此统一关闭全部已开 fd（不再启动服务器）
    if (!this.sessionActive) {
      this.closePendingSendFds();
      return -1;
    }
    let serverStartMs = Date.now();
    try {
      let port = await this.startServer(session, sendFiles, textValue);
      if (!this.sessionActive) {
        // 会话在起服期间终结：回收迟到启动的服务器资源（避免残留无人回收的服务器与暂存文件）
        await this.stopInFlightServerResources();
        return -1;
      }
      prep.serverPort = port;
      prep.thumbnailReady = this.thumbnailTempPath.length > 0;
      this.appendLog('服务器',
        `TLS 服务器已启动 bindIp=${MtaConstants.DEFAULT_BIND_IP} port=${port}（本地准备与凭据交换并行）`,
        LogLevels.INFO);
      this.appendLog('计时', `启动本地服务器耗时=${Date.now() - serverStartMs}ms（含预览生成）`, LogLevels.DEBUG);
      return port;
    } catch (e) {
      prep.serverError = '启动服务器失败: ' + String(e);
      if (this.sessionActive) {
        await this.stopInFlightServerResources();
      }
      return -1;
    }
  }

  /** 回收并行准备中迟到启动的本地服务器资源（停止服务器、关闭未移交 fd、删除暂存预览） */
  private async stopInFlightServerResources(): Promise<void> {
    this.closePendingSendFds();
    this.removeThumbnailTempFile();
    try {
      await nativeMtaStopServer();
    } catch (e) {
      this.appendLog('服务器', '回收迟到启动的服务器失败: ' + String(e), LogLevels.DEBUG);
    }
    this.state.serverRunning = false;
  }

  /** 提交启动服务器请求并取回实际端口 */
  private async startServer(session: MtaSendSession, files: Array<MtaSendFile>,
    text: string): Promise<number> {
    let entries: Array<NativeMtaFileEntry> = [];
    for (let i = 0; i < files.length; i++) {
      let entry: NativeMtaFileEntry = {
        // 文件条目透传下载直读 fd（fdSend >= 0 时 Rust 直读源文件，path 仅作容错回退）；
        // 文本条目 fd 缺省 -1，走 path 指向的落盘文本文件
        path: files[i].uri,
        entryName: files[i].entryName,
        lastModifiedMs: files[i].lastModified,
        sizeBytes: files[i].sizeBytes,
        fdSend: files[i].fdSend
      };
      entries.push(entry);
    }
    // 逐文件 MIME（按显示文件名推导）：既用于顶层三档聚合，也用于「是否全是媒体」判定
    let sendMimeTypes: Array<string> = [];
    for (let i = 0; i < files.length; i++) {
      sendMimeTypes.push(getMimeForFileName(files[i].displayName));
    }
    let config: NativeMtaServerConfig = {
      bindIp: session.goIp.length > 0 ? session.goIp : MtaConstants.DEFAULT_BIND_IP,
      port: MtaConstants.DEFAULT_SEND_PORT,
      taskId: session.taskId,
      senderId: session.senderIdHex,
      senderName: session.senderName,
      files: entries,
      // 顶层 MIME 按三档口径聚合（单文件真实 / 同类大类 / 跨类 `*/*`）：
      // 对端以该字段判定预览能力，固定值会让其判定失真
      mimeType: aggregateMtaMimeType(sendMimeTypes)
    };
    // 预览缩略图：仅当全部文件都是媒体时生成（可选能力，失败按「不提供」降级）
    await this.attachSendThumbnail(config, files, sendMimeTypes);
    // 文本发送：随 sendRequest 携带 catShareText（Rust 侧透传为 textContent）；
    // 走 WS 单帧传输，超限截断，完整文本仍经 sharedText.txt ZIP 条目送达
    if (text.length > 0) {
      config.textContent = truncateUtf8Text(text, MtaConstants.MAX_SHARE_TEXT_BYTES);
    }
    // 模拟品牌：默认第三方时不携带品牌字段，保证载荷与现状逐字节一致
    let brandId = getMtaSimulatedBrand();
    if (brandId !== MTA_BRAND_ID_THIRD_PARTY) {
      config.senderBrandId = brandId;
      config.senderBrand = resolveMtaBrandName(brandId);
    }
    // 超时兜底：服务器启动仅覆盖端口绑定与 TLS 初始化，正常为快操作；
    // 超时后底层 promise 可能迟到 resolve/reject，挂空 catch 防 unhandled rejection，
    // 迟到成功的服务器由 failSend → releaseSendResources 统一回收
    // 移交点：config 移交即 fd 所有权移交——无论启动成败，全部 fd 均由 Rust 收尾。
    // 自此之后的任何失败/取消路径 ArkTS 不再关闭这些 fd，避免与 Rust 侧重复关闭
    // （双关会触发进程 abort）。
    // 会话已终止：不向 Rust 移交 fd（所有权仍属 ArkTS 侧，由释放路径统一关闭），
    // 避免启动无人回收的服务器
    if (!this.sessionActive) {
      throw new Error('会话已终止，放弃启动服务器');
    }
    let startPromise = nativeMtaStartServer(config);
    this.pendingSendFileHandles = [];
    startPromise.catch((_e: Object): void => {
    });
    let timeoutPromise = new Promise<number>((_resolve, reject) => {
      setTimeout(() => {
        reject(new Error(`启动服务器超时（${MtaConstants.SERVER_START_TIMEOUT_MS}ms）`));
      }, MtaConstants.SERVER_START_TIMEOUT_MS);
    });
    return await Promise.race([startPromise, timeoutPromise]);
  }

  /**
   * 生成并挂载发送侧预览缩略图（可选能力：任何失败都按「不提供」降级，不中断发送）。
   *
   * 仅在**全部文件都是媒体**（图片/视频）时提供——混类型不提供预览，与参考实现一致；
   * 取首个文件生成，等比缩放至目标框内（不放大）后以 JPEG 落盘，路径随配置移交 Rust，
   * 由 `removeThumbnailTempFile` 在资源释放时回收。
   */
  private async attachSendThumbnail(config: NativeMtaServerConfig, files: Array<MtaSendFile>,
    mimeTypes: Array<string>): Promise<void> {
    if (files.length === 0) {
      return;
    }
    for (let i = 0; i < mimeTypes.length; i++) {
      if (!isMediaMime(mimeTypes[i])) {
        this.appendLog('缩略图', '存在非媒体文件，本次不提供预览缩略图', LogLevels.DEBUG);
        return;
      }
    }
    let dir = sendThumbnailDir();
    if (dir.length === 0) {
      this.appendLog('缩略图', '应用上下文缺失，跳过预览缩略图', LogLevels.WARN);
      return;
    }
    let targetPath = `${dir}thumb_${config.taskId}.jpg`;
    try {
      this.ensureStageDir(dir);
      let startMs = Date.now();
      let size: ThumbnailSize | undefined = await writeSendThumbnail(files[0].uri, isVideo(mimeTypes[0]),
        targetPath, MtaConstants.SEND_THUMBNAIL_MAX_WIDTH, MtaConstants.SEND_THUMBNAIL_MAX_HEIGHT);
      if (size === undefined) {
        this.appendLog('缩略图', '生成失败，本次不提供预览缩略图', LogLevels.WARN);
        return;
      }
      config.thumbnailPath = targetPath;
      config.thumbnailWidth = size.width;
      config.thumbnailHeight = size.height;
      this.thumbnailTempPath = targetPath;
      this.appendLog('缩略图',
        `已生成 ${size.width}x${size.height} 预览缩略图 耗时=${Date.now() - startMs}ms`, LogLevels.INFO);
    } catch (e) {
      this.appendLog('缩略图', '生成异常，本次不提供预览缩略图: ' + String(e), LogLevels.WARN);
    }
  }

  /** 删除本次会话的预览缩略图暂存文件（幂等；Rust 起服时已读入内存，此后不再需要） */
  private removeThumbnailTempFile(): void {
    if (this.thumbnailTempPath.length === 0) {
      return;
    }
    try {
      fs.unlinkSync(this.thumbnailTempPath);
    } catch (e) {
      logger.warn('删除发送缩略图暂存文件失败: ' + String(e));
    }
    this.thumbnailTempPath = '';
  }

  /** 文本发送：把文本内容写入落盘目录的文本文件，返回待暂存条目 */
  private writeSharedTextFile(taskId: string, text: string): MtaSendFile {
    // 文本即文件：写入应用私有持久目录下的发送文本目录（filesDir/text_send/），
    // 由「清空任务历史」统一清理；对端可见的条目名保持 MTA_SHARED_TEXT_FILE_NAME 不变（协议行为不变）
    let dir = this.textSendDir();
    this.ensureStageDir(dir);
    let path = `${dir}sharedText_${taskId}.txt`;
    let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
    let out = new MtaSendFile();
    out.uri = path;
    out.displayName = MTA_SHARED_TEXT_FILE_NAME;
    out.sizeBytes = utf8ByteLength(text);
    return out;
  }

  /** 发送文本的落盘目录：应用私有持久目录下的发送文本目录（写入与清空共用同一路径来源） */
  private textSendDir(): string {
    return sendTextDir();
  }

  /** 组装 P2pInfo（明文端口/凭据 + 群组频点 + 本机 ID；key 非空时凭据为密文） */
  private buildP2pInfoJson(session: MtaSendSession, ssid: string, psk: string, mac: string,
    key: string, port: number): P2pInfoJson {
    let info = new P2pInfoJson();
    // `P2pInfo.id` 承载本机设备 ID（持久化值，与中兴 `getDeviceId()` 同义）；WS `sendRequest` 的
    // `taskId`/`id` 才是任务 ID——两个同名字段语义不同，此处写设备身份
    info.id = session.senderIdHex;
    info.ssid = ssid;
    info.psk = psk;
    // 兜底归一：本机 P2P 地址统一为小写后再写入 P2pInfo（正常路径已在读取处归一，
    // 此处防御后续来源变化）。接收端比对地址的大小写策略不同（中兴严格相等、小米不敏感），
    // 统一小写可同时满足两者。
    info.mac = normalizeMtaP2pMac(mac);
    info.port = port;
    info.freq = session.groupFrequency;
    info.key = key;
    // catShare 为 CatShare 版本号（非品牌值），与接收端/P2pInfo 协议一致
    info.catShare = MtaConstants.CATSHARE_VERSION;
    // 连接配置字段对齐参考实现（小米互传）发送方：手机对手机为 GATT / WiFi P2P / MIOV HTTP；
    // 序列化时仅在非 0 时输出，对既有对端为附加字段（其解析方忽略或按缺省处理）
    info.G = MtaConstants.P2P_BOOT_NETWORK_GATT;
    info.M = MtaConstants.P2P_MAIN_NETWORK_WIFI_P2P;
    info.P = MtaConstants.P2P_PROTOCOL_MIOV_HTTP;
    return info;
  }

  // ── 文本发送持久目录辅助 ──

  /**
   * 确保目录存在。
   * HarmonyOS 的 mkdirSync 递归模式对已存在目录仍会抛 EEXIST，故先判断再创建，
   * 避免同一任务内多次准备目录时产生误报告警。
   */
  private ensureStageDir(dir: string): void {
    if (!fs.accessSync(dir, fs.AccessModeType.EXIST)) {
      fs.mkdirSync(dir, true);
    }
  }

  /**
   * 打开发送直读 fd：逐文件以 `fs.openSync(uri, READ_ONLY)` 打开读取入口（fdSend），
   * 并以 `fs.statSync(fd)` 取**该已打开句柄**的实际大小与修改时间——使对外声明的尺寸
   * 与将要实际发送的字节同源（来源 URI 的属性可能与句柄内容不一致，会导致对端声明
   * 尺寸与实际载荷不符、载荷被截断）。任一文件任一步骤失败都会关闭本次已打开的全部 fd
   * 并抛可读错误；成功时 fd 暂存于 `pendingSendFileHandles`，由 `startServer` 在移交点转交 Rust。
   * 不向 cacheDir 复制所选文件（文本会话的临时文件由 writeSharedTextFile 单独处理）。
   */
  private openSendFds(files: Array<MtaSendFile>): Array<MtaSendFile> {
    let opened: Array<fs.File> = [];
    let out: Array<MtaSendFile> = [];
    try {
      for (let i = 0; i < files.length; i++) {
        let source = files[i];
        let fdSendFile = fs.openSync(source.uri, fs.OpenMode.READ_ONLY);
        opened.push(fdSendFile);
        // 尺寸与修改时间取自刚打开的句柄属性：与后续实际读取的字节同源
        let stat = fs.statSync(fdSendFile.fd);
        let item = new MtaSendFile();
        item.uri = source.uri;
        item.displayName = source.displayName;
        item.sizeBytes = stat.size;
        item.entryName = buildEntryName(i, source.displayName);
        // fs.Stat.mtime 为距 1970 的秒数，统一转为 Unix 毫秒
        item.lastModified = Math.floor(stat.mtime * 1000);
        item.fdSend = fdSendFile.fd;
        out.push(item);
      }
    } catch (e) {
      // 任一步骤失败：关闭本次已打开的全部 fd（含当前文件已打开的部分），上抛时不泄漏
      this.closeOpenedFiles(opened);
      let failedName = out.length < files.length ? files[out.length].displayName : '';
      throw new Error(`打开文件直读 fd 失败 ${failedName}: ${String(e)}`);
    }
    this.pendingSendFileHandles = opened;
    return out;
  }

  /** 关闭一批已打开的发送直读 fd（幂等；供 openSendFds 局部失败与移交前收尾使用） */
  private closeOpenedFiles(files: Array<fs.File>): void {
    for (let i = 0; i < files.length; i++) {
      try {
        fs.closeSync(files[i]);
      } catch (e) {
        logger.warn('关闭发送直读 fd 失败: ' + String(e));
      }
    }
  }

  /**
   * 关闭尚未移交 Rust 的发送直读 fd（幂等）。仅在 fd 所有权仍属 ArkTS 侧时调用
   * （即 `startServer` 中 `nativeMtaStartServer` 调用之前）；该调用点已把
   * `pendingSendFileHandles` 清空，移交后的收尾由 Rust 负责，本方法不触碰任何 fd。
   */
  private closePendingSendFds(): void {
    this.closeOpenedFiles(this.pendingSendFileHandles);
    this.pendingSendFileHandles = [];
  }

  // ── Rust Mta* 事件订阅与状态推进 ──

  /** 订阅全部 Mta* 桥接事件（同一回调便于退订） */
  private subscribeNativeEvents(): void {
    if (this.nativeSubscribed) {
      return;
    }
    let types: Array<string> = [
      'mtaServerStarted', 'mtaWsConnected', 'mtaVersionNegotiated', 'mtaSendRequestSent',
      'mtaRejectSent', 'mtaDownloadStarted', 'mtaSendProgress', 'mtaSendCompleted',
      'mtaSendPartial', 'mtaSendRejected', 'mtaSendFailed'
    ];
    for (let i = 0; i < types.length; i++) {
      onBridgeEvent(types[i], this.nativeEventHandler);
    }
    this.nativeSubscribed = true;
  }

  /** 退订全部 Mta* 桥接事件 */
  private unsubscribeNativeEvents(): void {
    if (!this.nativeSubscribed) {
      return;
    }
    let types: Array<string> = [
      'mtaServerStarted', 'mtaWsConnected', 'mtaVersionNegotiated', 'mtaSendRequestSent',
      'mtaRejectSent', 'mtaDownloadStarted', 'mtaSendProgress', 'mtaSendCompleted',
      'mtaSendPartial', 'mtaSendRejected', 'mtaSendFailed'
    ];
    for (let i = 0; i < types.length; i++) {
      offBridgeEvent(types[i], this.nativeEventHandler);
    }
    this.nativeSubscribed = false;
  }

  /** 处理 Rust Mta* 事件并推进阶段/进度 */
  private handleNativeEvent(event: NativeEvent): void {
    if (!this.sessionActive && event.type !== 'mtaServerStarted') {
      return;
    }
    // 取消流程已启动：等待期内只有"取消状态已回送"可结算等待，其余迟到事件
    // 一律不推进状态机，保证已取消终态不被迟到的完成/失败信号覆盖
    if (this.cancelledThisSession && event.type !== 'mtaRejectSent') {
      return;
    }
    switch (event.type) {
      case 'mtaServerStarted':
        this.appendLog('服务器', `服务器已启动 port=${event.port}`, LogLevels.INFO);
        break;
      case 'mtaWsConnected':
        this.wsConnectedSeen = true;
        this.clearWaitingWsTimeout();
        this.setStage(MtaSenderStage.WAITING_WS);
        this.appendLog('WS', '对端已建立 WS 连接', LogLevels.INFO);
        this.linkTiming.mark('对端接入', Date.now());
        // 建链阶段耗时口径：点击→对端接入（对端此时已取得凭据并建立传输通道）
        let wsClickBaseMs = this.userClickMs > 0 ? this.userClickMs : this.linkStartMs;
        this.appendLog('计时',
          `点击→对端接入耗时=${Date.now() - wsClickBaseMs}ms 发送建链阶段=[${this.linkTiming.summary()}]`,
          LogLevels.DEBUG);
        if (this.p2pInfoWrittenMs > 0) {
          this.appendLog('计时',
            `等待对端 WS 连接耗时=${Date.now() - this.p2pInfoWrittenMs}ms（写回 P2pInfo→WS 建连）`, LogLevels.DEBUG);
        }
        break;
      case 'mtaVersionNegotiated':
        this.setStage(MtaSenderStage.NEGOTIATED);
        this.linkTiming.mark('版本协商', Date.now());
        this.appendLog('WS', `版本协商完成 version=${event.version}`, LogLevels.INFO);
        break;
      case 'mtaSendRequestSent':
        this.setStage(MtaSenderStage.WAITING_PEER_CONFIRM);
        this.requestSentMs = Date.now();
        // 请求已送达：武装"等待对端开始接收"的有界窗口，对端既未开始下载也未回送状态时给出可读结果
        this.startPeerAcceptTimeout();
        this.appendLog('WS', `已发送 sendRequest（任务=${event.taskId}）`, LogLevels.INFO);
        break;
      case 'mtaRejectSent':
        // 取消状态已写入对端连接：结算取消通知等待（记为已通知对端）
        this.settleCancelWait(true, '已回送取消状态');
        break;
      case 'mtaDownloadStarted':
        // 对端已开始下载即视为接受，撤销"等待对端开始接收"窗口，避免误伤后续传输
        this.clearPeerAcceptTimeout();
        this.setStage(MtaSenderStage.TRANSFERRING);
        this.linkTiming.mark('对端开始下载', Date.now());
        // 进入传输阶段即武装无进展看门狗，覆盖对端静默消失（不关连接也不发状态）的情形
        this.resetTransferStallWatchdog();
        // 记录下载开始时刻，供发送完成时输出传输阶段耗时
        this.downloadStartedMs = Date.now();
        this.appendLog('下载', `对端开始下载 ZIP（任务=${event.taskId}）`, LogLevels.INFO);
        if (this.requestSentMs > 0) {
          this.appendLog('计时',
            `sendRequest→对端开始下载耗时=${Date.now() - this.requestSentMs}ms`, LogLevels.DEBUG);
        }
        if (this.linkStartMs > 0) {
          this.appendLog('计时',
            `发送建链总耗时=${Date.now() - this.linkStartMs}ms（开始发送→对端开始下载）`, LogLevels.DEBUG);
        }
        break;
      case 'mtaSendProgress':
        let progress = new MtaSendProgress();
        progress.sentBytes = event.sentBytes;
        progress.totalBytes = event.totalBytes;
        progress.percent = Math.max(0, Math.min(100, Math.floor(event.percent)));
        // 网络字节口径：压缩生效时出网字节少于已读源字节，速率以此为准
        progress.networkBytes = event.networkBytes;
        this.state.progress = progress;
        // 每次进度到达即刷新看门狗：正常传输不会触发，只有真正停滞才判失败
        this.resetTransferStallWatchdog();
        this.notifyState();
        break;
      case 'mtaSendCompleted':
        this.onSendCompleted(event.taskId);
        break;
      case 'mtaSendPartial':
        this.onSendPartial(event.reason);
        break;
      case 'mtaSendRejected':
        this.rejectSend(mtaRejectReasonText(event.reason));
        break;
      case 'mtaSendFailed':
        // 对端关闭 WS / 关闭下载连接 / 服务端下载被中止，均由 Rust 归一为发送失败事件，
        // 此处以可读原因结束本次发送并释放资源。
        // 等待确认阶段的「对端关闭连接 / 读取失败 / 状态等待超时」统一呈现为「对方已放弃接收」，
        // 原始原因完整保留在日志中；更早链路阶段与传输阶段保持既有文案
        if (this.state.stage === MtaSenderStage.WAITING_PEER_CONFIRM) {
          this.appendLog('服务', `等待确认阶段收到失败：${event.reason}`, LogLevels.WARN);
          this.failSend(MTA_PEER_ABANDONED_TEXT);
        } else {
          this.failSend(event.reason);
        }
        break;
      default:
        break;
    }
  }

  /** 本次发送完成：保留传输中的源总字节并置 100%，随后标记完成并立即释放资源 */
  private onSendCompleted(taskId: string): void {
    let declaredTotal = this.state.session !== undefined ? this.state.session.totalBytes : 0;
    this.state.progress = resolveSendCompletedProgress(this.state.progress, declaredTotal);
    // 终态已达成：清除传输看门狗，已完成结果不被迟到的失败/取消信号覆盖
    this.clearTransferStallWatchdog();
    this.setStage(MtaSenderStage.COMPLETED);
    this.appendLog('服务', `发送完成（任务=${taskId}）`, LogLevels.INFO);
    this.logPeerResultOnce('完成');
    this.logTransferDuration();
    this.endSession();
    // 终态即断连：立即停止发送服务器（断开 WS 连接）并释放无线资源，使对端尽快清忙，
    // 连续发送不再被「对端忙」拦下；释放为一次性幂等，重复触发安全
    this.releaseSendResources().catch((e: Object): void => {
      this.appendLog('服务', '完成后清理异常: ' + String(e), LogLevels.ERROR);
    });
  }

  /**
   * 本次发送仅部分完成：对端回送成功类型 + 部分接收原因（只收了部分文件）。
   * 不得走发送成功路径（不置 COMPLETED、不按成功收敛进度），结果与资源收尾语义
   * 与失败路径一致：记录原因、进入部分完成阶段、结束会话并释放资源。
   */
  private async onSendPartial(reason: string): Promise<void> {
    // 已被用户取消的会话保持 CANCELLED 终态，不再被旧链路的迟到状态覆盖
    if (this.cancelledThisSession) {
      return;
    }
    this.clearTransferStallWatchdog();
    this.setError(MTA_PARTIAL_COMPLETED_TEXT);
    this.setStage(MtaSenderStage.PARTIAL);
    this.appendLog('服务',
      `本次发送仅部分完成（对端未收全）原因=${reason.length > 0 ? reason : '未提供'}`, LogLevels.WARN);
    this.logPeerResultOnce('部分完成');
    this.endSession();
    await this.releaseSendResources();
  }

  /** 输出传输阶段耗时日志：下载开始→发送完成的耗时、源总字节与平均速率 */
  private logTransferDuration(): void {
    if (this.downloadStartedMs <= 0) {
      return;
    }
    let transferCostMs = Date.now() - this.downloadStartedMs;
    let totalBytes = this.state.progress.totalBytes;
    let seconds = transferCostMs / 1000;
    let avgSpeed = seconds > 0 ? totalBytes / seconds : 0;
    this.appendLog('计时',
      `传输耗时=${transferCostMs}ms（下载开始→发送完成） 总字节=${totalBytes} 平均速率=${formatSpeed(avgSpeed)}`,
      LogLevels.DEBUG);
  }

  /**
   * 输出一次「请求→结果」耗时日志：仅在已记录 sendRequest 发出时刻且本会话尚未输出过时生效，
   * 保证每会话至多一条，用于核对对端响应是否符合其确认窗口预期。
   */
  private logPeerResultOnce(outcome: string): void {
    if (this.requestSentMs <= 0 || this.peerResultLogged) {
      return;
    }
    this.peerResultLogged = true;
    this.appendLog('计时',
      `请求→结果耗时=${Date.now() - this.requestSentMs}ms（结果=${outcome}）`, LogLevels.DEBUG);
  }

  /** 本次发送失败：记录原因、进入失败阶段并释放全部传输资源 */
  private async failSend(reason: string): Promise<void> {
    // 已被用户取消的会话保持 CANCELLED 终态，不再被旧链路的失败回调覆盖
    if (this.cancelledThisSession) {
      return;
    }
    this.setError(reason);
    this.setStage(MtaSenderStage.FAILED);
    this.appendLog('服务', `本次发送失败：${reason}`, LogLevels.ERROR);
    this.logPeerJoinSummary();
    this.logPeerLinkSummary();
    this.logPeerInfoRecheckSummary();
    this.logP2pWriteSummary();
    this.logPeerResultOnce('失败');
    this.endSession();
    await this.releaseSendResources();
  }

  /** 本次发送被对端拒绝：记录原因、进入拒绝阶段并释放全部传输资源（终态展示为拒收而非失败） */
  private async rejectSend(reason: string): Promise<void> {
    // 已被用户取消的会话保持 CANCELLED 终态，不再被旧链路的迟到状态覆盖
    if (this.cancelledThisSession) {
      return;
    }
    this.setError(reason);
    this.setStage(MtaSenderStage.REJECTED);
    this.appendLog('服务', `对方拒绝接收：${reason}`, LogLevels.WARN);
    this.logPeerJoinSummary();
    this.logPeerLinkSummary();
    this.logPeerInfoRecheckSummary();
    this.logP2pWriteSummary();
    this.logPeerResultOnce('拒绝');
    this.endSession();
    await this.releaseSendResources();
  }

  /** 释放一次发送占用的全部资源（服务器/GATT/群组/暂存文件/未移交直读 fd） */
  private async releaseSendResources(): Promise<void> {
    // 一次性守卫：等待结算与页面销毁两条路径并发时只真正释放一次
    //（`ble.destroy()` 与 `disconnectGattClient()` 叠加调用存在风险）
    if (this.resourcesReleased) {
      return;
    }
    this.resourcesReleased = true;
    this.clearWaitingWsTimeout();
    this.clearPeerAcceptTimeout();
    this.clearTransferStallWatchdog();
    this.stopGroupClientPolling();
    // 停止发送伴随外设（幂等）：覆盖经 checkSessionAborted 直接释放资源的路径，
    // 确保任何收束路径下外设都不残留，也不与随后恢复的接收服务争用广播/GATT 句柄
    await this.stopCompanionPeripheral();
    // 尚未移交 Rust 的发送直读 fd 在此关闭；已移交的（pendingSendFileHandles 已清空）
    // 由 Rust 侧负责收尾，本处不会重复关闭
    this.closePendingSendFds();
    // 预览缩略图暂存文件：Rust 起服时已读入内存，此后不再需要，随会话释放删除
    this.removeThumbnailTempFile();
    try {
      await nativeMtaStopServer();
    } catch (e) {
      this.appendLog('服务器', '停止服务器失败: ' + String(e), LogLevels.ERROR);
    }
    this.state.serverRunning = false;
    try {
      await this.ble.disconnectGattClient();
    } catch (e) {
      this.appendLog('GATT', '断开 GATT 失败: ' + String(e), LogLevels.ERROR);
    }
    try {
      await this.p2p.removeGroup();
    } catch (e) {
      this.appendLog('P2P', '删除群组失败: ' + String(e), LogLevels.ERROR);
    }
    this.state.groupCreated = false;
    this.notifyState();
  }

  // ── 取消与清理 ──

  /**
   * 取消进行中的发送：登记"向对端回送取消"意图，在有界窗口内等待对端被通知
   * （对端回送取消状态 / 等待上限到期 / 用户直接返回，先到者结算），
   * 随后结束会话、置取消终态并释放资源。
   *
   * 等待期内不结束会话：接收服务保持暂停、收发互斥保持占用，与"会话终态才恢复接收"
   * 的既有语义一致；等待有界（不超过取消通知等待上限），资源占用可预期。
   */
  async cancelSend(): Promise<void> {
    // 会话进行中才可取消：已终结的会话（完成/部分成功/失败）保持原终态，
    // 不得把 FAILED 等终态覆盖为「已取消」
    if (!this.sessionActive) {
      this.appendLog('服务', '当前无进行中的发送，无需取消', LogLevels.INFO);
      return;
    }
    if (this.cancelWaitResolve !== null) {
      this.appendLog('服务', '已在等待通知对方取消，忽略重复取消', LogLevels.INFO);
      return;
    }
    let cancelStartMs = Date.now();
    this.appendLog('服务', '用户取消发送', LogLevels.INFO);
    this.cancelledThisSession = true;
    this.setStage(MtaSenderStage.CANCEL_NOTIFYING);
    // 服务器运行中即对端仍可能接入（已写回 P2pInfo）：保留链路并等待对端被通知；
    // 更早阶段（GATT/建组/起服前）对端尚未取得凭据、无法接入，按未通知直接收尾
    let notified = false;
    if (this.state.serverRunning) {
      let registered = true;
      try {
        nativeMtaRejectPeer();
      } catch (e) {
        // 登记意图失败即无法回送取消状态：按未通知直接收尾，不进入等待
        registered = false;
        this.appendLog('服务', '登记回送取消意图失败: ' + String(e), LogLevels.ERROR);
      }
      if (registered) {
        notified = await this.waitCancelNotify();
      }
    } else {
      this.appendLog('服务', '对端尚未取得连接凭据，无法通知取消，直接收尾', LogLevels.WARN);
    }
    this.logPeerJoinSummary();
    this.logPeerLinkSummary();
    this.logPeerInfoRecheckSummary();
    this.logP2pWriteSummary();
    this.endSession();
    this.setError(notified ? MTA_CANCELLED_TEXT : MTA_CANCEL_NOTIFY_FAILED_TEXT);
    this.setStage(MtaSenderStage.CANCELLED);
    await this.releaseSendResources();
    this.appendLog('服务', `已取消本次发送并释放资源 耗时=${Date.now() - cancelStartMs}ms`, LogLevels.INFO);
  }

  /**
   * 等待对端被通知取消：由"已回送取消状态"事件、等待上限定时器、用户直接返回
   * 三者中先到者结算，返回是否已通知到对端。
   */
  private waitCancelNotify(): Promise<boolean> {
    return new Promise<boolean>((resolve: (notified: boolean) => void): void => {
      this.cancelWaitStartMs = Date.now();
      this.cancelWaitResolve = resolve;
      this.cancelWaitTimerId = setTimeout((): void => {
        this.cancelWaitTimerId = -1;
        this.settleCancelWait(false, '等待上限到期');
      }, MtaConstants.CANCEL_NOTIFY_WAIT_TIMEOUT_MS);
    });
  }

  /**
   * 一次性结算取消通知等待：记录"已通知/未能通知"与等待耗时，并唤醒等待方。
   * 重复调用或非等待期调用为空操作。
   */
  private settleCancelWait(notified: boolean, source: string): void {
    let resolve = this.cancelWaitResolve;
    if (resolve === null) {
      return;
    }
    this.cancelWaitResolve = null;
    if (this.cancelWaitTimerId >= 0) {
      clearTimeout(this.cancelWaitTimerId);
      this.cancelWaitTimerId = -1;
    }
    let costMs = this.cancelWaitStartMs > 0 ? Date.now() - this.cancelWaitStartMs : 0;
    let outcome = notified ? '已通知对端取消' : '未能通知对端取消';
    this.appendLog('服务', `${outcome}（${source}，等待=${costMs}ms）`, notified ? LogLevels.INFO : LogLevels.WARN);
    resolve(notified);
  }

  // ── Rust 日志轮询（服务器/TLS/WS 侧诊断） ──

  /** 启动 Rust 日志轮询：排空日志缓冲并追加到发送页日志 */
  private startRustLogPolling(): void {
    if (this.rustLogTimerId >= 0) {
      return;
    }
    this.rustLogTimerId = setInterval(() => {
      this.drainRustLog();
    }, MtaConstants.RUST_LOG_POLL_MS);
  }

  /** 停止 Rust 日志轮询 */
  private stopRustLogPolling(): void {
    if (this.rustLogTimerId >= 0) {
      clearInterval(this.rustLogTimerId);
      this.rustLogTimerId = -1;
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

  // ── 群组客户端轮询（诊断对端是否加入 WiFi Direct 组） ──

  /** 启动群组客户端数轮询 */
  private startGroupClientPolling(): void {
    if (this.groupClientTimerId >= 0) {
      return;
    }
    this.lastClientCount = -1;
    this.groupClientZeroStreak = 0;
    this.groupClientTimerId = setInterval(() => {
      this.pollGroupClient();
    }, MtaConstants.GROUP_CLIENT_POLL_MS);
  }

  /** 停止群组客户端数轮询 */
  private stopGroupClientPolling(): void {
    if (this.groupClientTimerId >= 0) {
      clearInterval(this.groupClientTimerId);
      this.groupClientTimerId = -1;
    }
  }

  /** 启动等待对端 WS 连接的超时定时器（超时仍未回连则判定发送失败） */
  private startWaitingWsTimeout(): void {
    this.clearWaitingWsTimeout();
    this.waitingWsTimerId = setTimeout(() => {
      this.waitingWsTimerId = -1;
      // 仅在会话仍停留在等待 WS 阶段时判定失败（对端解密凭据失败/P2P 连接失败/异常退出）
      if (this.sessionActive && this.state.stage === MtaSenderStage.WAITING_WS) {
        this.failSend(`等待对端连接超时（${MtaConstants.WAITING_WS_TIMEOUT_MS}ms）`);
      }
    }, MtaConstants.WAITING_WS_TIMEOUT_MS);
  }

  /** 清除等待对端 WS 连接的超时定时器 */
  private clearWaitingWsTimeout(): void {
    if (this.waitingWsTimerId >= 0) {
      clearTimeout(this.waitingWsTimerId);
      this.waitingWsTimerId = -1;
    }
  }

  // ── 等待对端开始接收窗口（对端拒绝但静默时兜底） ──

  /**
   * 武装"等待对端开始接收"窗口：在已发出 sendRequest 且对端尚未开始下载时生效。
   * 对端既未开始下载、也未回送状态、也未断开时，窗口到期即判定对方未接收并结束本次发送，
   * 避免一直停留在「等待对方确认」干等到 Rust 侧 180s 状态等待超时（届时用户毫无反馈）。
   */
  private startPeerAcceptTimeout(): void {
    this.clearPeerAcceptTimeout();
    this.peerAcceptTimerId = setTimeout(() => {
      this.peerAcceptTimerId = -1;
      // 仅在仍停留在"已发请求、对端尚未开始下载"阶段时判定未被接收
      if (this.sessionActive && this.state.stage === MtaSenderStage.WAITING_PEER_CONFIRM) {
        // 可归因判定：有界窗口内未收到对端任何结果（无 status、未开始下载），
        // 与 Rust 侧会话收尾统计（收到对端报文数）配对，即可区分「对端未发送」与「本端漏收」
        this.appendLog('服务',
          `等待对端开始接收窗口到期（${MtaConstants.PEER_ACCEPT_TIMEOUT_MS}ms）：窗口期内未收到对端任何结果，判定对方未接收`,
          LogLevels.WARN);
        this.failSend(MTA_PEER_REJECTED_TEXT);
      }
    }, MtaConstants.PEER_ACCEPT_TIMEOUT_MS);
  }

  /** 清除"等待对端开始接收"窗口定时器 */
  private clearPeerAcceptTimeout(): void {
    if (this.peerAcceptTimerId >= 0) {
      clearTimeout(this.peerAcceptTimerId);
      this.peerAcceptTimerId = -1;
    }
  }

  // ── 传输阶段看门狗（对端静默消失兜底） ──

  /**
   * 武装/重置传输阶段看门狗：进入传输后持续无进展超过阈值即判定对端静默中止。
   * 正常传输会持续上报进度（每次进度都会重置），故不会误伤慢速大文件；
   * 仅作为下载连接断开（Rust 立即终止）之外的静默情形兜底，不缩短全局状态等待超时。
   */
  private resetTransferStallWatchdog(): void {
    this.clearTransferStallWatchdog();
    this.transferStallTimerId = setTimeout(() => {
      this.transferStallTimerId = -1;
      // 仅在仍处于传输中且会话未终结时判定失败（已完成/已取消不被迟到信号覆盖）
      if (this.sessionActive && this.state.stage === MtaSenderStage.TRANSFERRING) {
        this.failSend(`传输长时间无进展（${MtaConstants.TRANSFER_STALL_TIMEOUT_MS}ms），判定对端已中止`);
      }
    }, MtaConstants.TRANSFER_STALL_TIMEOUT_MS);
  }

  /** 清除传输阶段看门狗 */
  private clearTransferStallWatchdog(): void {
    if (this.transferStallTimerId >= 0) {
      clearTimeout(this.transferStallTimerId);
      this.transferStallTimerId = -1;
    }
  }

  /** 查询群组客户端数：变化时记录（判断对端是否已加入组），并在等待确认阶段判定对端是否已退组 */
  private pollGroupClient(): void {
    this.p2p.getCurrentGroup().then((info: MtaGroupInfo | null): void => {
      // 群组信息不可得以 -1 参与判定：等待确认阶段该信号同样表示对端可能已离组
      let clientCount = info !== null ? info.clientCount : -1;
      // 入组观测：无论客户端数是否变化都累计，覆盖「无客户端 / 读取不可得」情形，
      // 使会话收束时能区分「从未入组」与「入组后离开」
      if (info === null) {
        this.groupClientReadFailCount++;
      } else {
        if (info.clientCount > this.maxGroupClientCount) {
          this.maxGroupClientCount = info.clientCount;
        }
        if (info.clientCount >= 1) {
          this.peerJoinedGroupSeen = true;
        }
      }
      let decision = decidePeerGroupAbandon(this.state.stage, this.lastClientCount, clientCount,
        this.groupClientZeroStreak);
      this.groupClientZeroStreak = decision.zeroStreak;
      if (info !== null && info.clientCount !== this.lastClientCount) {
        this.lastClientCount = info.clientCount;
        let detail = info.clientCount > 0 ? '对端已加入组' : '对端尚未加入组';
        this.appendLog('P2P', `群组客户端数=${info.clientCount}（${detail}）`, LogLevels.DEBUG);
      }
      if (decision.abandoned) {
        // 等待确认阶段对端已退出本次 P2P 组：立即以「对方已放弃接收」终结，不空等窗口到期
        this.appendLog('服务',
          `等待确认阶段对端已退出本次 P2P 组（连续 ${decision.zeroStreak} 次观测客户端数归零/群组不可得）`,
          LogLevels.WARN);
        this.failSend(MTA_PEER_ABANDONED_TEXT);
      }
    }).catch((e: Object): void => {
      logger.warn('查询群组客户端数失败: ' + String(e));
    });
  }

  /**
   * 汇总输出本次会话的对端入组观测：是否曾观测到对端加入直连组、观测到的最大客户端数、
   * 以及群组信息读取不可得的次数。现有轮询仅在客户端数变化时逐条记录，无法据此区分
   * 「从未入组」与「入组后离开」；本汇总在失败/取消收束时给出明确结论。
   */
  private logPeerJoinSummary(): void {
    this.appendLog('P2P',
      `对端入组观测汇总：曾观测到对端入组=${this.peerJoinedGroupSeen ? '是' : '否'}` +
        ` 最大客户端数=${this.maxGroupClientCount} 群组信息不可得次数=${this.groupClientReadFailCount}`,
      LogLevels.INFO);
  }

  /**
   * 记录对端蓝牙链路状态跃迁（仅在写回 P2pInfo 之后采集）：
   * 对端取走连接凭据后常随即断开蓝牙，故「写回后链路断开 / 断开后重连」可作为写回已被对端处理的
   * 佐证；全程保持则提示写回可能未被处理。写回前只维护连接基线，不产生「写回后变化」记录。
   */
  private recordPeerLinkChange(stateText: string): void {
    // 仅在发送会话进行中采集：会话终结后对端收尾性的断开不参与本会话归因
    if (!this.sessionActive) {
      return;
    }
    let connected = stateText === '已连接';
    if (this.p2pInfoWrittenMs <= 0) {
      this.peerLinkConnected = connected;
      return;
    }
    // 仅在稳定的「已断开」状态上判定一次断开，忽略「断开中」等中间态，避免重复计数
    if (stateText === '已断开' && this.peerLinkConnected) {
      this.peerLinkConnected = false;
      this.peerLinkDroppedAfterWrite = true;
      this.peerLinkEventsAfterWrite.push(`断开(+${Date.now() - this.p2pInfoWrittenMs}ms)`);
      this.appendLog('GATT', '写回 P2pInfo 后对端蓝牙链路断开', LogLevels.INFO);
      return;
    }
    if (connected && !this.peerLinkConnected) {
      this.peerLinkConnected = true;
      if (this.peerLinkDroppedAfterWrite) {
        this.peerLinkReconnectedAfterWrite = true;
        this.peerLinkEventsAfterWrite.push(`重连(+${Date.now() - this.p2pInfoWrittenMs}ms)`);
        this.appendLog('GATT', '写回 P2pInfo 后对端蓝牙链路重连', LogLevels.INFO);
      }
    }
  }

  /**
   * 汇总输出写回 P2pInfo 后对端蓝牙链路的变化：保持 / 断开 / 断开后重连，
   * 用于判断写回是否被对端处理（对端取走凭据后常随即断开蓝牙）。
   */
  private logPeerLinkSummary(): void {
    if (this.p2pInfoWrittenMs <= 0) {
      return;
    }
    let changeText = '保持';
    if (this.peerLinkReconnectedAfterWrite) {
      changeText = '断开后重连';
    } else if (this.peerLinkDroppedAfterWrite) {
      changeText = '断开';
    }
    let eventsText = this.peerLinkEventsAfterWrite.length > 0 ?
      this.peerLinkEventsAfterWrite.join('、') : '无';
    this.appendLog('GATT',
      `写回 P2pInfo 后对端蓝牙链路变化=${changeText}（事件=${eventsText}）`, LogLevels.INFO);
  }

  /**
   * 非阻塞诊断入口：写回后复读对端公开信息，与「等待对端入组」并行采集。
   * 结果仅用于收束归因，不阻断阶段推进；异常仅记日志。
   */
  private startPeerInfoRecheckInBackground(firstRaw: string, firstState: number, seq: number): void {
    this.recheckPeerInfoAfterWrite(firstRaw, firstState, seq).catch((e: Object): void => {
      logger.warn('写回后复读诊断异常: ' + String(e));
    });
  }

  /**
   * 写回 P2pInfo 后主动复读对端公开信息（D-probe，非阻塞诊断）。
   * 对端服务端「读正常、写无响应」时，本地写返回成功不代表对端已处理；本方法以复读的成败与
   * 内容变化（重点 state）判定「写回未被对端处理」还是「写回后链路已不可用」。
   * 复读失败不改变发送流程，仅记录结论供收束汇总；采集受诊断窗口约束，且会话已切换时丢弃结果。
   */
  private async recheckPeerInfoAfterWrite(firstRaw: string, firstState: number,
    seq: number): Promise<void> {
    let recheckStartMs = Date.now();
    let recheckRaw = '';
    try {
      recheckRaw = await this.withPeerRecheckWindow(this.ble.readRemoteDeviceInfoText());
    } catch (e) {
      if (this.sessionSeq !== seq) {
        return;
      }
      this.peerInfoRecheck = buildPeerInfoRecheckFailure(String(e));
      this.appendLog('GATT',
        `写回后复读对端公开信息：失败（${String(e)}）→ 判定写回后链路已不可用`, LogLevels.WARN);
      return;
    }
    // 会话已切换（新发送已开始/本会话已终止）时丢弃迟到结果，避免污染下一会话的收束汇总
    if (this.sessionSeq !== seq) {
      return;
    }
    let recheckInfo = parseDeviceInfo(recheckRaw);
    let recheckState = recheckInfo !== undefined ? recheckInfo.state : -1;
    let result = evaluatePeerInfoRecheck(firstState, firstRaw, recheckState, recheckRaw);
    this.peerInfoRecheck = result;
    this.appendLog('GATT',
      `写回后复读对端公开信息：成功 内容变化=${result.contentChanged ? '是' : '否'}` +
        ` state=${firstState}→${recheckState} → ${result.conclusion}` +
        `（耗时=${Date.now() - recheckStartMs}ms）`,
      result.stateChanged || result.contentChanged ? LogLevels.INFO : LogLevels.WARN);
  }

  /** 为写回后复读诊断加窗口上限：超窗即放弃采集，不长期占用 GATT 客户端 */
  private withPeerRecheckWindow(operation: Promise<string>): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void, reject: (reason: Object) => void): void => {
      let settled = false;
      let timerId = setTimeout((): void => {
        if (settled) {
          return;
        }
        settled = true;
        reject(new Error(`复读诊断超窗（${MtaConstants.PEER_INFO_RECHECK_WINDOW_MS}ms）`));
      }, MtaConstants.PEER_INFO_RECHECK_WINDOW_MS);
      operation.then((value: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timerId);
        resolve(value);
      }).catch((e: Object): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timerId);
        reject(e);
      });
    });
  }

  /**
   * 汇总输出写回 P2pInfo 后复读对端公开信息的结论：复读成败、内容与 state 是否变化，
   * 作为「写回是否被对端处理」的判定依据；与本会话其它收束汇总同点输出。
   */
  private logPeerInfoRecheckSummary(): void {
    let result = this.peerInfoRecheck;
    if (result === null) {
      return;
    }
    if (!result.success) {
      this.appendLog('GATT',
        `写回后复读对端公开信息汇总：失败（${result.failureReason}）→ ${result.conclusion}`,
        LogLevels.INFO);
      return;
    }
    this.appendLog('GATT',
      `写回后复读对端公开信息汇总：成功 内容变化=${result.contentChanged ? '是' : '否'}` +
        ` state=${result.firstState}→${result.recheckState} → ${result.conclusion}`,
      LogLevels.INFO);
  }

  /**
   * 汇总输出写回 P2pInfo 的写方式与成功判据：带响应写以收到对端写回调判定；无响应写无写回执，
   * 是否被对端处理由端到端信号（对端反连本机外设 / 入组 / 回连传输通道）与其它收束汇总判定。
   */
  private logP2pWriteSummary(): void {
    if (!this.p2pWriteDone) {
      return;
    }
    let modeText = resolveMtaP2pWriteModeText(this.p2pWriteUsedNoResponse);
    let judgeText = this.p2pWriteUsedNoResponse ?
      '无写回执，是否被处理由端到端信号（对端反连本机外设/入组/回连传输通道）判定' :
      '已收到对端写回调';
    this.appendLog('GATT', `写回 P2pInfo 汇总：写方式=${modeText} ${judgeText}`, LogLevels.INFO);
  }

  // ── 资源释放 ──

  /** 页面退出时释放资源 */
  destroy(): void {
    // 释放入口置空事件回调：实例被释放后不再向适配器投递任何状态事件
    // （在途的异步收尾仍会执行到 notifyState，此时因回调已置空而静默）
    this.handlers = null;
    // 页面销毁（系统返回/标题返回）等价于"直接返回"：先结算取消通知等待，避免取消流程悬挂；
    // 随后由本方法完成释放并置一次性守卫，使取消流程不再重复释放
    this.settleCancelWait(false, '页面销毁');
    this.endSession();
    this.resourcesReleased = true;
    this.clearWaitingWsTimeout();
    this.clearPeerAcceptTimeout();
    this.clearTransferStallWatchdog();
    this.stopRustLogPolling();
    this.stopGroupClientPolling();
    this.unsubscribeNativeEvents();
    // 页面退出兜底：关闭尚未移交 Rust 的发送直读 fd（已移交的由 Rust 收尾）
    this.closePendingSendFds();
    nativeMtaStopServer().catch((): void => {
    });
    this.ble.destroy();
    this.p2p.destroy();
    this.crypto.reset();
  }
}
