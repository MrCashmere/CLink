/**
 * MtaRepository.ets — 应用级 MTA 运行时仓储
 *
 * 汇聚主流程所需的 MTA 关注点：
 * - 发现扫描：持有一个仅用于扫描的 MtaBleClient 实例（每轮一次性、非常驻），
 *   把发现的 MTA 设备按 BLE 标识去重合并，供发送页并入统一设备列表；
 * - 接收服务单例：持有 MtaReceiveService，按「允许接收」设置与应用前后台
 *   生命周期启停（前台自动运行，后台停止）；
 * - 事件总线：把接收请求到达与状态快照转成订阅通知，供页面导航与渲染；
 * - 命令门面：accept/reject/cancel 转发给接收服务；
 * - 收发互斥：维护全局「发送进行中」标志，发送期间暂停接收服务，发送结束后恢复。
 *
 * UI 侧变化统一经 AppCore.notifyChange() 通知（与其它仓储一致）。
 */

import { common } from '@kit.AbilityKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { DiscoveredDevice, MediaFileInfo } from '../../model/Types';
import { MtaBleClient } from '../mta/MtaBleClient';
import { isBluetoothEnabled, loadOrCreateMtaDeviceIdHex, queryMtaBluetoothStatus } from '../mta/MtaBleCommon';
import { MtaBleClientEventHandlers, MtaDiscoveredDevice, mtaDeviceIdentityKey } from '../../model/mta/MtaSendModels';
import {
  MtaBluetoothStatus,
  MtaDeviceListClearedEvent,
  MtaDeviceListClearReason,
  MtaDeviceListClearScene,
  MtaScanHealth,
  buildMtaDeviceListClearedEvent,
  buildMtaScanHealth,
  formatMtaDeviceListClearedLog,
  isMissingSinceRescan,
  isStaleByTtl,
  mtaClearSceneText,
  shouldAttemptMtaScanRearm,
  shouldPruneStaleDevices,
  shouldTriggerScanRecovery
} from '../../model/mta/MtaDiscoveryModels';
import { MtaReceiveService, setMtaReceiveTextSavedNotifier } from '../mta/MtaReceiveService';
import {
  MtaReceiveEventHandlers,
  ReceiveServiceWarmState,
  ReceiverStage,
  ReceiverState,
  buildMtaReceiveIdentityToken,
  isMtaReceivingStage,
  isReceiveServiceReusable
} from '../../model/mta/MtaProtocolModels';
import { mtaDeviceToDiscoveredDevice } from '../../model/mta/MtaMainModels';
import { notifyChange } from './AppCore';
import { getMtaEnabled, getMtaReceiveEnabled, getMtaSimulatedBrand } from './SettingsRepository';
import { getDeviceAlias } from './DeviceRepository';
import {
  handleMtaReceiveState,
  notifyMtaTextSaved,
  setMtaReceiveInvokers
} from '../transfer/adapters/MtaReceiveAdapter';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { isBluetoothPermissionGranted } from '../PermissionService';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaRepository', '互传');

/** 扫描期间陈旧条目剔除检查间隔（毫秒）：定时剔除超时未再广播的设备 */
const MTA_STALE_PRUNE_INTERVAL_MS: number = 15000;

/** 设备存活时长（毫秒）：超过该时长未再收到广播即视为离线并从列表剔除 */
const MTA_DEVICE_TTL_MS: number = 30000;

/**
 * 主动刷新确认窗口（毫秒）：用户点击刷新后，仍在广播的设备因上报去重被重置会在窗口内重新上报，
 * 窗口结束时仍未被再次发现的条目按离线即时剔除（无需等满存活期 TTL）。
 */
const MTA_RESCAN_SETTLE_MS: number = 3000;

/** 扫描失败后的最小重试冷却（毫秒）：冷却期内被动触发的刷新一律不起扫，切断失败自激紧循环 */
const MTA_SCAN_RETRY_COOLDOWN_MS: number = 10000;

/**
 * 发现扫描自愈重试间隔（毫秒）：页面期望扫描却未在扫描时（起扫失败进入冷却、蓝牙/权限瞬时
 * 不可用、可见性事件时序未触发等），按此间隔重试起扫，直至起扫成功或不再期望扫描，
 * 避免设备列表长期不刷新、只能靠用户手动刷新或切页才恢复。
 */
const MTA_SCAN_REARM_INTERVAL_MS: number = 5000;

/**
 * 扫描静默停顿判定阈值（毫秒）：不小于设备存活期 TTL。
 * 取值与 TTL 相同，确保「暂停前先剔光」不会发生——一旦距最近发现结果达到该阈值即判为疑似停顿，
 * 转而触发恢复并跳过剔除，而不是让既有条目先被 TTL 剔除至空。
 */
const MTA_SCAN_STALL_THRESHOLD_MS: number = MTA_DEVICE_TTL_MS;

/** 整组清空诊断同类事件节流窗口（毫秒）：窗口内同类原因的事件去重，避免刷屏 */
const MTA_CLEAR_DIAG_THROTTLE_MS: number = 5000;

/** 蓝牙关闭去抖确认窗口（毫秒）：关闭判定在该窗口内稳定后才生效，避免状态抖动导致误清空 */
const MTA_BLUETOOTH_DISABLE_DEBOUNCE_MS: number = 1500;

// ── 发现扫描状态 ──

let scanClient: MtaBleClient | undefined = undefined;
let scannedDevices: Array<MtaDiscoveredDevice> = [];
let scanning: boolean = false;
// 发现意图拆分：可见性期望（用户在该页且总开关开启）与发送暂停两个独立意图。
// 发送暂停只临时挂起扫描，不抹除可见性期望；发送结束后按可见性期望显式恢复发现。
// 显式停止（用户离开页面 / 总开关关闭）仍清除两者。
let scanVisibilityDesired: boolean = false;
let scanSendSuspended: boolean = false;
// 扫描失败的冷却截止时间戳：当前时间早于该值时，被动触发的刷新不起扫
let scanRetryBlockedUntil: number = 0;
// 陈旧条目剔除定时器 id（扫描期间运行，停止扫描时清理）
let stalePruneTimer: number = -1;
// 发现扫描自愈重试定时器 id（-1 表示未安排）
let scanRearmTimer: number = -1;
// 主动刷新确认定时器 id（-1 表示未安排）与刷新基准时刻（0 表示未布置确认）
let rescanSettleTimer: number = -1;
let rescanEpochMs: number = 0;
// 最近一次有新发现结果的时刻（0 表示本次扫描会话尚无发现）：扫描健康度判定基准
let lastScanResultMs: number = 0;
// 本次扫描会话起始时刻：会话尚无发现时作为健康度判定的基准
let scanSessionStartMs: number = 0;
// 最近一次触发扫描停顿恢复的时刻（恢复节流）：避免疑似停顿反复重启扫描
let lastScanStallRecoveryMs: number = 0;
// 清空诊断节流状态：记录上次输出原因与时刻，并对同类事件计数抑制次数
let clearDiagLastMs: number = 0;
let clearDiagLastReason: MtaDeviceListClearReason = MtaDeviceListClearReason.UNKNOWN;
let clearDiagSuppressedCount: number = 0;
// 上一次已知的蓝牙开关状态（上一稳定态）：过滤「开启中/关闭中」等中间态的重复事件
let bluetoothOn: boolean = false;
// 蓝牙关闭去抖确认定时器 id（-1 表示未安排）
let bluetoothDisableConfirmTimer: number = -1;

// ── 接收服务状态 ──

let receiveService: MtaReceiveService | undefined = undefined;
let receiveState: ReceiverState = new ReceiverState();
let receiveRunning: boolean = false;
// 接收服务启停在途操作串行链：start/stop 依提交顺序排队执行，避免标志竞态
let receiveOpChain: Promise<void> = Promise.resolve();
// 是否希望接收服务运行（前台且开关开启）：蓝牙临时不可用时保留意图，蓝牙恢复后自动重启
let receiveDesired: boolean = false;
let lastReceiveStage: ReceiverStage = ReceiverStage.IDLE;
let appContext: common.Context | undefined = undefined;

// ── 收发互斥状态 ──

// 并发发送逐次 suspend/resume 配对计数：单布尔标志在并发发送时
// 互相覆盖，先结束的发送会把后结束发送的恢复需求清掉，接收服务停摆
let sendActiveCount: number = 0;
// 任一次发送暂停时接收服务在运行，则最后一次 resume 后需要恢复
let resumeReceiveAfterSend: boolean = false;
// 最近一次点击 MTA 设备发起发送的时刻（0 表示未记录）；用于建链耗时端到端计时
let mtaSendClickedMs: number = 0;

// ── 发现扫描 ──

/** 惰性创建发现扫描客户端并绑定事件 */
function ensureScanClient(): MtaBleClient {
  if (scanClient !== undefined) {
    return scanClient;
  }
  let client = new MtaBleClient();
  let handlers = new MtaBleClientEventHandlers();
  handlers.onDeviceFound = (device: MtaDiscoveredDevice): void => {
    mergeScannedDevice(device);
  };
  handlers.onScanStateChange = (value: boolean, detail: string): void => {
    scanning = value;
    logger.debug(detail);
    notifyChange();
  };
  handlers.onBluetoothStateChange = (_stateText: string): void => {
    handleBluetoothStateChange();
  };
  handlers.onError = (source: string, message: string): void => {
    logger.error('发现错误 [' + source + ']: ' + message);
  };
  client.registerEvents(handlers);
  // 记录初始蓝牙状态（三态：不可确定按「非确认关闭」处理，避免启动即误清空），供状态跃迁判定使用
  bluetoothOn = queryMtaBluetoothStatus() !== MtaBluetoothStatus.DISABLED;
  scanClient = client;
  return client;
}

/** 本机接收广播的发送者 ID 十六进制（小写；接收服务未运行时为空串，不参与自身过滤） */
function getLocalReceiveSenderIdHex(): string {
  let service = receiveService;
  if (service === undefined || !receiveRunning) {
    return '';
  }
  return service.getLocalSenderIdHex().trim().toLowerCase();
}

/** 本机 MTA 发送者 ID（16 字节的十六进制文本）：与广播、发送共用同一持久化值，不依赖接收服务是否运行 */
export function getLocalMtaDeviceIdHex(): string {
  return loadOrCreateMtaDeviceIdHex().trim().toLowerCase();
}

/**
 * 按「设备身份键」去重合并扫描到的 MTA 设备（更新 lastSeen），并通知 UI。
 * 合并前丢弃与本机接收广播身份相同的条目，避免本机出现在自身列表中。
 */
function mergeScannedDevice(device: MtaDiscoveredDevice): void {
  let localSenderId = getLocalReceiveSenderIdHex();
  if (localSenderId.length > 0 && device.senderIdHex.trim().toLowerCase() === localSenderId) {
    logger.debug('发现过滤本机广播: ' + device.bleAddress);
    return;
  }
  device.lastSeen = Date.now();
  // 扫描健康度跟踪：记录最近一次有新发现结果的时刻（停顿判定的单一基准）
  lastScanResultMs = device.lastSeen;
  let key = mtaDeviceIdentityKey(device);
  let updated: Array<MtaDiscoveredDevice> = [];
  let found = false;
  for (let i = 0; i < scannedDevices.length; i++) {
    if (mtaDeviceIdentityKey(scannedDevices[i]) === key) {
      updated.push(device);
      found = true;
    } else {
      updated.push(scannedDevices[i]);
    }
  }
  if (!found) {
    updated.push(device);
  }
  scannedDevices = updated;
  notifyChange();
}

/** 是否应处于发现扫描状态：可见性期望为真且未被发送暂停 */
function shouldScanDesired(): boolean {
  return scanVisibilityDesired && !scanSendSuspended;
}

/**
 * 统一「整组清空」诊断出口：按原因分类输出诊断，附带清空前条目数、触发场景与时刻。
 * 同类原因在节流窗口内去重，被抑制的次数在下一次输出时汇总，避免刷屏又不丢失事实。
 */
function emitMtaClearDiagnostic(reason: MtaDeviceListClearReason, countBefore: number,
  scene: MtaDeviceListClearScene): void {
  let now = Date.now();
  if (reason === clearDiagLastReason && now - clearDiagLastMs < MTA_CLEAR_DIAG_THROTTLE_MS) {
    clearDiagSuppressedCount++;
    return;
  }
  let event: MtaDeviceListClearedEvent = buildMtaDeviceListClearedEvent(reason, countBefore, now, scene);
  let suffix: string = clearDiagSuppressedCount > 0 ?
    ('（期间同类事件抑制 ' + clearDiagSuppressedCount + ' 次）') : '';
  clearDiagLastMs = now;
  clearDiagLastReason = reason;
  clearDiagSuppressedCount = 0;
  logger.warn(formatMtaDeviceListClearedLog(event) + suffix);
}

/** 清空互传设备列表：仅在确有「非空→空」跃迁时经统一诊断出口记录 */
function clearScannedDevices(reason: MtaDeviceListClearReason, scene: MtaDeviceListClearScene): void {
  let countBefore = scannedDevices.length;
  scannedDevices = [];
  if (countBefore > 0) {
    emitMtaClearDiagnostic(reason, countBefore, scene);
  }
}

/**
 * 剔除超时未再收到广播的陈旧 MTA 条目；返回被剔除的条目数。
 *
 * 前置条件为「扫描健康」（扫描中且未疑似停顿）：扫描不健康一律跳过剔除、不改变列表，
 * 避免扫描实际停摆时既有条目被逐步剔光。剔除动作按触发场景分级记录日志；
 * 若本次剔除使列表由非空变空，则经统一诊断出口记录超时剔除原因。
 */
function pruneStaleDevices(scene: MtaDeviceListClearScene): number {
  if (scannedDevices.length === 0) {
    return 0;
  }
  let now = Date.now();
  let health: MtaScanHealth = buildMtaScanHealth(scanning, lastScanResultMs, scanSessionStartMs, now,
    MTA_SCAN_STALL_THRESHOLD_MS);
  if (!shouldPruneStaleDevices(health)) {
    logger.debug('跳过陈旧条目剔除：扫描不健康 扫描中=' + (health.scanning ? '是' : '否') +
      ' 疑似停顿=' + (health.suspectedStall ? '是' : '否') + ' 条目数=' + scannedDevices.length);
    return 0;
  }
  let countBefore = scannedDevices.length;
  let kept: Array<MtaDiscoveredDevice> = [];
  let removed = 0;
  for (let i = 0; i < scannedDevices.length; i++) {
    if (!isStaleByTtl(scannedDevices[i].lastSeen, now, MTA_DEVICE_TTL_MS)) {
      kept.push(scannedDevices[i]);
    } else {
      removed++;
    }
  }
  if (removed > 0) {
    scannedDevices = kept;
    logger.debug('发现列表剔除超时设备 ' + removed + ' 台：触发原因=' + mtaClearSceneText(scene) +
      ' 剔除前=' + countBefore + ' 剔除后=' + kept.length +
      ' 扫描健康=是 距最近发现结果=' + Math.max(0, now - lastScanResultMs) + 'ms');
    if (kept.length === 0) {
      emitMtaClearDiagnostic(MtaDeviceListClearReason.STALE_PRUNE, countBefore, scene);
    }
  }
  return removed;
}

/**
 * 周期性扫描健康检查：疑似静默停顿时记录诊断并按节流触发一次扫描恢复，
 * 且「恢复确认（收到新的发现结果）前」跳过陈旧剔除；扫描健康时才执行超时剔除。
 */
function runScanHealthCheck(): void {
  let now = Date.now();
  let health: MtaScanHealth = buildMtaScanHealth(scanning, lastScanResultMs, scanSessionStartMs, now,
    MTA_SCAN_STALL_THRESHOLD_MS);
  if (health.suspectedStall) {
    if (scannedDevices.length > 0) {
      // 列表非空时，疑似停顿可能演变为整组清空：经统一诊断出口按「扫描停顿」原因记录
      emitMtaClearDiagnostic(MtaDeviceListClearReason.SCAN_STALL, scannedDevices.length,
        MtaDeviceListClearScene.SCAN_STALL);
    } else {
      logger.debug('互传发现扫描疑似静默停顿（当前无条目）：跳过剔除并尝试恢复');
    }
    if (shouldTriggerScanRecovery(health, now, lastScanStallRecoveryMs, MTA_SCAN_STALL_THRESHOLD_MS)) {
      lastScanStallRecoveryMs = now;
      triggerScanRecovery();
    }
    return;
  }
  let removed = pruneStaleDevices(MtaDeviceListClearScene.PRUNE_TIMER);
  if (removed > 0) {
    notifyChange();
  }
}

/**
 * 触发发现扫描恢复：先停后起 BLE 扫描以重置底层扫描状态。
 * 不重置最近发现结果时刻，使恢复确认（收到新的发现结果）前继续跳过陈旧剔除。
 */
function triggerScanRecovery(): void {
  const client = scanClient;
  if (client === undefined) {
    return;
  }
  logger.warn('互传发现扫描疑似静默停顿：触发扫描恢复并跳过陈旧条目剔除');
  clearStalePruneTimer();
  clearRescanSettleTimer();
  client.resetReportDedupe();
  client.stopScan().then((): Promise<void> => {
    return client.startScan();
  }).then((): void => {
    scanRetryBlockedUntil = 0;
    logger.debug('发现扫描恢复已启动');
  }).catch((e: Object): void => {
    scanRetryBlockedUntil = Date.now() + MTA_SCAN_RETRY_COOLDOWN_MS;
    logger.error('发现扫描恢复失败: ' + String(e));
  });
  scheduleStalePrune();
}

/**
 * 启动发现扫描（幂等）：更新可见性期望意图；MTA 总开关关闭或存在进行中的发送时仅记录期望、不启动。
 * 扫描中或处于失败冷却期时为空操作。
 */
export function startMtaDiscoveryScan(): void {
  if (!getMtaEnabled()) {
    logger.debug('MTA 总开关已关闭，不启动发现扫描');
    return;
  }
  scanVisibilityDesired = true;
  if (isMtaSendActive()) {
    // 发送期间：仅记录可见性期望，发送结束后由其按期望恢复发现
    scanSendSuspended = true;
    logger.debug('存在进行中的 MTA 发送，仅记录可见性期望，暂不启动发现扫描');
    return;
  }
  if (!shouldScanDesired()) {
    return;
  }
  if (scanning) {
    return;
  }
  if (Date.now() < scanRetryBlockedUntil) {
    // 失败冷却中：安排自愈重试，冷却结束后无需用户手动刷新/切页即可自动起扫
    logger.debug('发现扫描处于失败冷却，安排自愈重试');
    scheduleScanRearm();
    return;
  }
  beginScan();
}

/** 清除主动刷新确认定时器并撤销刷新基准（扫描会话结束/重启恢复时调用） */
function clearRescanSettleTimer(): void {
  if (rescanSettleTimer >= 0) {
    clearTimeout(rescanSettleTimer);
    rescanSettleTimer = -1;
  }
  rescanEpochMs = 0;
}

/**
 * 布置主动刷新确认：记录刷新基准时刻并安排一次确认剔除。
 * 仍在广播的设备因上报去重被重置会在窗口内重新上报（lastSeen 前移），
 * 离线设备保持旧的上报时刻，窗口结束时即被判为缺失并剔除。
 */
function armRescanSettle(): void {
  if (rescanSettleTimer >= 0) {
    clearTimeout(rescanSettleTimer);
    rescanSettleTimer = -1;
  }
  rescanEpochMs = Date.now();
  rescanSettleTimer = setTimeout((): void => {
    settleRescanPrune();
  }, MTA_RESCAN_SETTLE_MS);
}

/**
 * 主动刷新确认剔除：移除刷新基准时刻之后未再上报的条目（离线设备），
 * 在线设备已在确认窗口内重新上报故保留。前置条件同为「扫描健康」——
 * 扫描未运行或疑似停顿时跳过，避免扫描停摆把在线设备误剔。
 */
function settleRescanPrune(): void {
  rescanSettleTimer = -1;
  let epoch = rescanEpochMs;
  rescanEpochMs = 0;
  if (epoch <= 0 || scannedDevices.length === 0) {
    return;
  }
  let now = Date.now();
  let health: MtaScanHealth = buildMtaScanHealth(scanning, lastScanResultMs, scanSessionStartMs, now,
    MTA_SCAN_STALL_THRESHOLD_MS);
  if (!shouldPruneStaleDevices(health)) {
    logger.debug('跳过主动刷新确认剔除：扫描不健康 扫描中=' + (health.scanning ? '是' : '否') +
      ' 疑似停顿=' + (health.suspectedStall ? '是' : '否') + ' 条目数=' + scannedDevices.length);
    return;
  }
  let countBefore = scannedDevices.length;
  let kept: Array<MtaDiscoveredDevice> = [];
  let removed = 0;
  for (let i = 0; i < scannedDevices.length; i++) {
    if (isMissingSinceRescan(scannedDevices[i].lastSeen, epoch)) {
      removed++;
    } else {
      kept.push(scannedDevices[i]);
    }
  }
  if (removed > 0) {
    scannedDevices = kept;
    logger.debug('主动刷新确认剔除离线设备 ' + removed + ' 台：剔除前=' + countBefore +
      ' 剔除后=' + kept.length + ' 确认窗口=' + MTA_RESCAN_SETTLE_MS + 'ms');
    if (kept.length === 0) {
      emitMtaClearDiagnostic(MtaDeviceListClearReason.STALE_PRUNE, countBefore,
        MtaDeviceListClearScene.RESCAN);
    }
    notifyChange();
  }
}

/** 用户主动刷新：重置失败冷却并重新收集；在线设备保留、离线设备经确认窗口即时剔除（无需等满 TTL） */
export function rescanMtaDiscovery(): void {
  if (!getMtaEnabled()) {
    logger.debug('MTA 总开关已关闭，跳过主动刷新扫描');
    return;
  }
  scanVisibilityDesired = true;
  if (!shouldScanDesired()) {
    logger.debug('发送暂停中，主动刷新仅记录可见性期望');
    return;
  }
  scanRetryBlockedUntil = 0;
  if (scanning) {
    // 已在扫描：不清空列表（清空会让既有设备"先消失"）；先重置扫描上报去重使在线设备在
    // 下一轮结果中重新上报，再布置确认窗口剔除窗口内未再上报的离线设备
    let client = scanClient;
    if (client !== undefined) {
      client.resetReportDedupe();
    }
    pruneStaleDevices(MtaDeviceListClearScene.RESCAN);
    armRescanSettle();
    notifyChange();
    return;
  }
  beginScan();
  armRescanSettle();
}

/** 安排「发现扫描自愈重试」（幂等）：期望扫描却未在扫描时按间隔重试起扫 */
function scheduleScanRearm(): void {
  if (scanRearmTimer >= 0) {
    return;
  }
  scanRearmTimer = setInterval((): void => {
    runScanRearm();
  }, MTA_SCAN_REARM_INTERVAL_MS);
}

/** 自愈重试一次：不再期望扫描/已扫描中即停表；蓝牙确认关闭也停表（交蓝牙状态事件恢复） */
function runScanRearm(): void {
  if (!shouldScanDesired() || scanning) {
    clearScanRearm();
    return;
  }
  let bluetooth = queryMtaBluetoothStatus();
  if (bluetooth === MtaBluetoothStatus.DISABLED) {
    clearScanRearm();
    return;
  }
  if (!shouldAttemptMtaScanRearm(bluetooth, Date.now(), scanRetryBlockedUntil)) {
    return;
  }
  logger.debug('互传发现扫描未运行：按自愈间隔重试起扫');
  beginScan();
}

/** 清除发现扫描自愈重试定时器 */
function clearScanRearm(): void {
  if (scanRearmTimer >= 0) {
    clearInterval(scanRearmTimer);
    scanRearmTimer = -1;
  }
}

/** 真正起扫：蓝牙三态预检 → 重置扫描会话基准 → 启动 BLE 扫描 → 启动周期性健康检查 */
function beginScan(): void {
  let client = ensureScanClient();
  // 仅「确认关闭」时才跳过起扫；「不可确定」不视为关闭，仍尝试起扫（起扫失败有既有兜底）
  if (queryMtaBluetoothStatus() === MtaBluetoothStatus.DISABLED) {
    scanRetryBlockedUntil = Date.now() + MTA_SCAN_RETRY_COOLDOWN_MS;
    scanning = false;
    logger.debug('发现扫描跳过：蓝牙已确认关闭（' + (MTA_SCAN_RETRY_COOLDOWN_MS / 1000) + 's 内不再重试）');
    notifyChange();
    return;
  }
  // 蓝牙权限未授予时不发起注定失败的起扫（BLE 扫描会直接返回 201），也不进入失败冷却：
  // 直接安排自愈重试，授权一到（≤ 一个重试间隔）即起扫。启动阶段「EntryAbility 的权限申请
  // 串行链」排在本 UI 首帧扫描之后（且蓝牙申请还排在通知权限之后），二者存在竞态。
  if (!isBluetoothPermissionGranted()) {
    scanRetryBlockedUntil = 0;
    scanning = false;
    logger.debug('发现扫描跳过：蓝牙权限未授予，安排自愈重试');
    scheduleScanRearm();
    notifyChange();
    return;
  }
  // 重置本次扫描会话基准：健康度判定从会话起始时刻起算，避免沿用上一会话的陈旧发现时刻
  scanSessionStartMs = Date.now();
  lastScanResultMs = 0;
  scanning = true;
  notifyChange();
  client.startScan().then((): void => {
    // 扫描成功：清除失败冷却与自愈重试，恢复正常即时行为
    scanRetryBlockedUntil = 0;
    clearScanRearm();
    logger.debug('发现扫描已启动');
  }).catch((e: Object): void => {
    scanning = false;
    clearStalePruneTimer();
    // 失败后进入冷却，通知引发的刷新不会立即再次起扫；同时安排自愈重试，
    // 使冷却结束（如蓝牙权限随后授予）后能自动起扫，无需用户手动刷新或切页
    scanRetryBlockedUntil = Date.now() + MTA_SCAN_RETRY_COOLDOWN_MS;
    scheduleScanRearm();
    logger.error('发现扫描启动失败: ' + String(e));
    notifyChange();
  });
  scheduleStalePrune();
}

/** 安排扫描期间的周期性扫描健康检查（健康时剔除陈旧条目，疑似停顿时触发恢复） */
function scheduleStalePrune(): void {
  clearStalePruneTimer();
  stalePruneTimer = setInterval((): void => {
    runScanHealthCheck();
  }, MTA_STALE_PRUNE_INTERVAL_MS);
}

/** 清除陈旧条目剔除定时器 */
function clearStalePruneTimer(): void {
  if (stalePruneTimer >= 0) {
    clearInterval(stalePruneTimer);
    stalePruneTimer = -1;
  }
}

/** 停止发现扫描（幂等） */
function stopMtaDiscoveryScanInternal(): void {
  clearStalePruneTimer();
  clearRescanSettleTimer();
  clearScanRearm();
  // 先清状态再停扫描：stopScan 的同步回调链（状态通知 → UI 刷新）会读取 scanning，
  // 若后置将观察到停止前的旧状态，扫描可能被重新拉起
  scanning = false;
  let client = scanClient;
  if (client !== undefined) {
    client.stopScan().catch((e: Object): void => {
      logger.error('停止扫描失败: ' + String(e));
    });
  }
  // 停止收尾：扫描已停（健康判定为不健康），此处不会剔除任何条目，保持既有列表不被清空
  pruneStaleDevices(MtaDeviceListClearScene.SCAN_STOP);
  notifyChange();
}

/** 显式停止发现扫描（用户离开页面 / 总开关关闭）：同时清除可见性期望与发送暂停两个意图 */
export function stopMtaDiscoveryScan(): void {
  scanVisibilityDesired = false;
  scanSendSuspended = false;
  stopMtaDiscoveryScanInternal();
}

/**
 * 发送前暂停发现扫描：只临时挂起（置发送暂停意图），不抹除可见性期望；
 * 发送结束后经 resumeMtaDiscoveryAfterSend 按可见性期望恢复。
 */
export function pauseMtaDiscoveryForSend(): void {
  scanSendSuspended = true;
  stopMtaDiscoveryScanInternal();
}

/** 发送结束（成功/失败/取消）后按当前可见性期望显式恢复发现扫描（幂等） */
export function resumeMtaDiscoveryAfterSend(): void {
  scanSendSuspended = false;
  if (!scanVisibilityDesired) {
    logger.debug('发送结束：页面可见性期望为假，不恢复发现扫描');
    return;
  }
  if (scanning || Date.now() < scanRetryBlockedUntil) {
    return;
  }
  logger.debug('发送结束：按可见性期望恢复互传发现扫描');
  beginScan();
}

/**
 * 蓝牙开关状态变化处理（三态）：仅在状态真正跃迁时动作。
 * - 不可确定：保持上一稳定态，既不清空也不隐藏；
 * - 已开启：取消防抖并恢复；
 * - 已关闭：进入去抖确认，窗口内状态稳定为关闭才真正清空（避免状态抖动误清空）。
 */
function handleBluetoothStateChange(): void {
  let status = queryMtaBluetoothStatus();
  if (status === MtaBluetoothStatus.UNKNOWN) {
    logger.debug('蓝牙状态不可确定，保持上一稳定态（不清空互传分组）');
    return;
  }
  if (status === MtaBluetoothStatus.ENABLED) {
    cancelBluetoothDisableConfirm();
    if (!bluetoothOn) {
      bluetoothOn = true;
      handleBluetoothEnabled();
    }
    return;
  }
  // 确认关闭：已处于关闭态时无需重复处理
  if (!bluetoothOn) {
    return;
  }
  scheduleBluetoothDisableConfirm();
}

/** 安排蓝牙关闭去抖确认：窗口结束后复核，仍为确认关闭才生效 */
function scheduleBluetoothDisableConfirm(): void {
  if (bluetoothDisableConfirmTimer >= 0) {
    return;
  }
  bluetoothDisableConfirmTimer = setTimeout((): void => {
    bluetoothDisableConfirmTimer = -1;
    let status = queryMtaBluetoothStatus();
    if (status === MtaBluetoothStatus.DISABLED) {
      bluetoothOn = false;
      handleBluetoothDisabled();
    } else if (status === MtaBluetoothStatus.UNKNOWN) {
      logger.debug('蓝牙关闭去抖确认未通过：状态不可确定，保持上一稳定态');
    }
  }, MTA_BLUETOOTH_DISABLE_DEBOUNCE_MS);
}

/** 取消蓝牙关闭去抖确认（状态恢复为已开启或已确认处理时调用） */
function cancelBluetoothDisableConfirm(): void {
  if (bluetoothDisableConfirmTimer >= 0) {
    clearTimeout(bluetoothDisableConfirmTimer);
    bluetoothDisableConfirmTimer = -1;
  }
}

/** 蓝牙关闭：停止扫描并清空设备列表、复位接收服务，避免残留离线设备与不可重启的死状态 */
function handleBluetoothDisabled(): void {
  // 清空列表与停止扫描置于同一同步块，避免中间被广播事件重新填充；
  // 清空经统一诊断出口记录（原因=蓝牙真实关闭），确保整组清空可被定位
  clearScannedDevices(MtaDeviceListClearReason.BLUETOOTH_DISABLED, MtaDeviceListClearScene.BLUETOOTH_EVENT);
  if (scanning) {
    // 停止扫描内部会通知 UI（此时列表已清空）
    stopMtaDiscoveryScanInternal();
  } else {
    notifyChange();
  }
  if (receiveRunning) {
    stopReceiveServiceInternal().catch((e: Object): void => {
      logger.error('蓝牙关闭后停止 MTA 接收服务异常: ' + String(e));
    });
  }
  logger.debug('蓝牙已关闭：停止互传发现扫描并清空设备列表，接收服务复位');
}

/** 蓝牙开启：清除失败冷却后按需恢复发现扫描与接收服务 */
function handleBluetoothEnabled(): void {
  let scanStarted = false;
  if (shouldScanDesired() && !scanning) {
    scanRetryBlockedUntil = 0;
    lastScanStallRecoveryMs = 0;
    logger.debug('蓝牙已开启：恢复互传发现扫描');
    // beginScan 内部已通知 UI
    beginScan();
    scanStarted = true;
  }
  if (receiveDesired && !receiveRunning) {
    logger.debug('蓝牙已开启：重启 MTA 接收服务');
    startReceiveServiceInternal();
  }
  if (!scanStarted) {
    // 未起扫时补一次通知，确保蓝牙警告横幅即时收起
    notifyChange();
  }
}

/** 本机蓝牙是否已开启（保留二值语义，供不区分「不可得」的旧调用方使用） */
export function isMtaBluetoothOn(): boolean {
  // 惰性创建扫描客户端并注册蓝牙开关监听，保证后续开关变化能推送刷新
  ensureScanClient();
  return isBluetoothEnabled();
}

/**
 * 本机蓝牙开关三态（已开启 / 已关闭 / 不可确定）。
 * 供发送页互传分组 gate 与空态文案使用：不可确定不得按「已关闭」处理。
 */
export function getMtaBluetoothStatus(): MtaBluetoothStatus {
  // 惰性创建扫描客户端并注册蓝牙开关监听，保证后续开关变化能推送刷新
  ensureScanClient();
  return queryMtaBluetoothStatus();
}

/**
 * 本机 WLAN 开关是否已开启。
 * 互传 P2P 传输依赖 WLAN（有线局域网不算），未开启时设备可被蓝牙发现但无法传输。
 */
export function isMtaWifiOn(): boolean {
  try {
    return wifiManager.isWifiActive();
  } catch (e) {
    // 查询失败时不误报：按已开启处理
    logger.warn('查询 WLAN 开关状态失败: ' + String(e));
    return true;
  }
}

/** 当前发现的 MTA 设备（映射为统一设备形状） */
export function getMtaDiscoveredDevices(): Array<DiscoveredDevice> {
  let now = Date.now();
  let result: Array<DiscoveredDevice> = [];
  for (let i = 0; i < scannedDevices.length; i++) {
    result.push(mtaDeviceToDiscoveredDevice(scannedDevices[i], now));
  }
  return result;
}

// ── 接收服务 ──

/** 惰性创建接收服务并绑定事件 */
function ensureReceiveService(): MtaReceiveService {
  if (receiveService !== undefined) {
    return receiveService;
  }
  let service = new MtaReceiveService();
  let handlers = new MtaReceiveEventHandlers();
  handlers.onStateChange = (state: ReceiverState): void => {
    receiveState = state;
    receiveRunning = state.serviceRunning;
    lastReceiveStage = state.stage;
    // 统一会话事实源：把接收阶段翻译为统一会话操作
    handleMtaReceiveState(state);
    notifyChange();
  };
  service.setEventHandlers(handlers);
  receiveService = service;
  return service;
}

/**
 * 应用进入前台时按开关启动接收服务。
 * 开关关闭时不启动；已运行时幂等返回。
 */
export function startMtaReceiveIfEnabled(context: common.Context): void {
  appContext = context;
  if (!getMtaEnabled()) {
    receiveDesired = false;
    logger.debug('MTA 总开关已关闭，不启动接收服务');
    return;
  }
  if (!getMtaReceiveEnabled()) {
    receiveDesired = false;
    logger.debug('接收开关已关闭，不启动接收服务');
    return;
  }
  receiveDesired = true;
  startReceiveServiceInternal();
}

/** MTA 总开关变化后生效：关闭=停止接收与发现扫描，开启=按接收子开关恢复接收 */
export function applyMtaEnabled(): void {
  if (getMtaEnabled()) {
    // 扫描由发送页可见性驱动（含总开关检查），此处仅恢复接收
    logger.info('MTA 总开关已开启，按接收开关恢复接收');
    applyMtaReceiveEnabled();
  } else {
    logger.info('MTA 总开关已关闭，停止接收服务与发现扫描');
    stopMtaReceive();
    stopMtaDiscoveryScan();
  }
}

/** 接收子开关变化后重新按设置启停接收服务（使用已保存的应用上下文） */
export function applyMtaReceiveEnabled(): void {
  if (getMtaEnabled() && getMtaReceiveEnabled()) {
    receiveDesired = true;
    startReceiveServiceInternal();
  } else {
    receiveDesired = false;
    stopReceiveServiceInternal();
  }
}

/**
 * 启动接收服务（幂等）：提交到启停串行链按顺序执行。
 * 链式排队消除标志竞态——start 在途时提交 stop 会等启动完成后停止，
 * stop 在途时提交 start 会等停止完成后启动，最终收敛到最新期望态。
 */
function startReceiveServiceInternal(): void {
  receiveOpChain = receiveOpChain.then((): Promise<void> => performStartReceive());
}

/** 启动动作（仅经启停串行链执行） */
async function performStartReceive(): Promise<void> {
  if (receiveRunning) {
    return;
  }
  let context = appContext;
  if (context === undefined) {
    logger.error('缺少应用上下文，无法启动 MTA 接收服务');
    return;
  }
  let alias = getDeviceAlias();
  if (alias.length === 0) {
    logger.debug('设备昵称尚未就绪，暂不启动 MTA 接收服务');
    return;
  }
  let service = ensureReceiveService();
  service.init(context);
  try {
    await service.startService(alias);
    receiveRunning = service.getState().serviceRunning;
    notifyChange();
  } catch (e) {
    logger.error('启动 MTA 接收服务异常: ' + String(e));
  }
}

/**
 * 重启流程中刷新 MTA 接收对外身份：以当前昵称重广播并重建 GATT，使昵称变更经「重启」生效。
 * 接收服务未运行时为空操作；失败仅记日志，不影响重启结果。
 */
export function refreshMtaReceiveIdentity(): void {
  let service = receiveService;
  if (service === undefined || !receiveRunning) {
    return;
  }
  service.refreshIdentity(getDeviceAlias()).catch((e: Object): void => {
    logger.error('刷新 MTA 接收对外身份异常: ' + String(e));
  });
}

/**
 * 模拟品牌变更后刷新接收广播身份：复用身份刷新通道触发重广播。
 * 接收服务未运行时为空操作，不影响下一次启动广播。
 */
export function applyMtaSimulatedBrand(): void {
  refreshMtaReceiveIdentity();
}

/**
 * 停止接收服务并释放会话资源（幂等）：提交到启停串行链按顺序执行，
 * 返回的 Promise 在本次停止动作真正完成后结算（供收发互斥暂停等待）。
 */
function stopReceiveServiceInternal(): Promise<void> {
  let pending: Promise<void> = receiveOpChain.then((): Promise<void> => performStopReceive());
  // 停止失败不得阻断链上后续操作，捕获后继续
  receiveOpChain = pending.catch((e: Object): void => {
    logger.error('停止 MTA 接收服务异常: ' + String(e));
  });
  return pending;
}

/** 停止动作（仅经启停串行链执行） */
async function performStopReceive(): Promise<void> {
  let service = receiveService;
  if (service === undefined || !receiveRunning) {
    return;
  }
  try {
    await service.stopService();
  } catch (e) {
    // 停止失败也复位运行标志：服务可能已部分停止，
    // 保持「运行中」会使后续启动被幂等守卫拒绝而永远无法再启动
    logger.error('停止 MTA 接收服务异常: ' + String(e));
  }
  receiveRunning = false;
  notifyChange();
}

/** 停止接收服务（应用进入后台或开关关闭时调用）；同时清除接收意图，避免蓝牙状态变化时被重新拉起 */
export function stopMtaReceive(): void {
  receiveDesired = false;
  // 显式停止即让预热/复用失效：应用退后台或开关关闭后不得保留对外服务或复用状态
  let service = receiveService;
  if (service !== undefined) {
    service.suppressWarmReuse();
  }
  stopReceiveServiceInternal().catch((e: Object): void => {
    logger.error('停止 MTA 接收服务异常: ' + String(e));
  });
}

// ── 收发互斥 ──

/** 是否存在进行中的 MTA 发送 */
export function isMtaSendActive(): boolean {
  return sendActiveCount > 0;
}

/** 记录点击 MTA 设备发起发送的时刻（发送页点击入口调用） */
export function markMtaSendClicked(): void {
  mtaSendClickedMs = Date.now();
}

/** 取点击 MTA 设备的时刻（未记录时为 0） */
export function getMtaSendClickedMs(): number {
  return mtaSendClickedMs;
}

/**
 * 发起 MTA 发送前暂停接收服务（记录是否需要恢复）。
 *
 * 收发互斥解耦：本函数立即启动接收服务的暂停，并返回「接收对外服务已释放」的凭据（Promise）；
 * 调用方无需等待其结算即可推进与对端无关的发送本地准备（建组、起本地服务器），
 * 仅在启动发送伴随外设前等待该凭据，实现「并行切换、可复用即复用」。
 * 返回的 Promise 保证不 reject（停止异常已被吞掉并按已释放处理），避免门失败阻断发送。
 */
export async function suspendMtaReceiveForSend(): Promise<void> {
  sendActiveCount++;
  let wasRunning = receiveRunning;
  let suspendStartMs = Date.now();
  if (receiveRunning) {
    resumeReceiveAfterSend = true;
    // 停止失败不阻断发送：按已释放处理，发送侧外设启动失败也只会降级而不阻断发送
    await stopReceiveServiceInternal().catch((e: Object): void => {
      logger.error('暂停 MTA 接收服务异常: ' + String(e));
    });
  }
  // 点击设备后的第一段隐藏耗时：暂停接收服务（停广播/GATT/WS/P2P）本身也占时
  logger.debug(`发送前暂停接收服务耗时=${Date.now() - suspendStartMs}ms 接收服务原状态=${wasRunning}`);
  notifyChange();
}

/** MTA 发送结束（完成/失败/取消）后按开关恢复接收服务 */
export async function resumeMtaReceiveAfterSend(): Promise<void> {
  sendActiveCount = Math.max(0, sendActiveCount - 1);
  // 全部发送结束后才恢复，避免先结束的发送提前拉起接收
  if (sendActiveCount === 0) {
    let shouldResume = resumeReceiveAfterSend;
    resumeReceiveAfterSend = false;
    if (shouldResume && getMtaEnabled() && getMtaReceiveEnabled()) {
      // 复用优先：对外服务仍完整且身份未变时无需重建（start 内部亦为幂等，此处仅作诊断判定）
      logReceiveReuseDecision();
      startReceiveServiceInternal();
    } else if (shouldResume) {
      logger.debug('发送结束后不恢复接收：总开关或接收开关已关闭');
    }
  }
  notifyChange();
}

/** 输出发送结束后接收服务「复用/重建」的判定结论（诊断用，不影响启停行为） */
function logReceiveReuseDecision(): void {
  let service = receiveService;
  if (service === undefined) {
    return;
  }
  let warm: ReceiveServiceWarmState = service.getWarmState();
  let expected = buildMtaReceiveIdentityToken(getDeviceAlias(), getMtaSimulatedBrand());
  if (isReceiveServiceReusable(warm, expected)) {
    logger.debug('发送结束后接收对外服务仍可复用，不触发重建');
  } else {
    logger.debug('发送结束后接收对外服务需重建（服务已停或对外身份变化）');
  }
}

// ── 接收命令门面 ──

/** 接受当前接收请求 */
export function acceptMtaReceiveRequest(): void {
  let service = receiveService;
  if (service === undefined) {
    return;
  }
  service.acceptRequest().catch((e: Object): void => {
    logger.error('接受 MTA 接收请求异常: ' + String(e));
  });
}

/** 接受当前文本接收请求（回接受 ack 与成功 status，不进入下载流程；剪贴板写入由界面独立完成） */
export function acceptMtaReceiveText(): void {
  let service = receiveService;
  if (service === undefined) {
    return;
  }
  service.acceptTextRequest().catch((e: Object): void => {
    logger.error('接受 MTA 文本接收请求异常: ' + String(e));
  });
}

/** 拒绝当前接收请求 */
export function rejectMtaReceiveRequest(): void {
  let service = receiveService;
  if (service === undefined) {
    return;
  }
  service.rejectRequest().catch((e: Object): void => {
    logger.error('拒绝 MTA 接收请求异常: ' + String(e));
  });
}

/** 取消当前 MTA 接收下载 */
export function cancelMtaReceive(): void {
  let service = receiveService;
  if (service === undefined) {
    return;
  }
  service.cancelDownload();
}

// ── 接收状态快照 ──

/** 当前接收状态快照 */
export function getMtaReceiveSnapshot(): ReceiverState {
  return receiveState;
}

/** MTA 接收任务是否进行中（建链/下载/落盘；不含等待用户确认阶段） */
export function isMtaReceivingActive(): boolean {
  return isMtaReceivingStage(receiveState.stage);
}

// 注册 MTA 接收确认/拒绝/取消/接受文本入口与媒体提供器：
// 统一会话命令经适配器回调本仓库门面（含文本消息的接受文本收尾与相册保存媒体来源）
setMtaReceiveInvokers(
  (): void => {
    acceptMtaReceiveRequest();
  },
  (): void => {
    rejectMtaReceiveRequest();
  },
  (): void => {
    cancelMtaReceive();
  },
  (): void => {
    acceptMtaReceiveText();
  },
  (): Array<MediaFileInfo> => {
    return receiveState.pendingMediaFiles.slice();
  }
);

// 「文本已落盘（带路径）」通知入口：接收服务落盘成功后上抛真实路径，由本仓库转发给
// MTA 接收适配器回填当前活跃统一会话的逐文件路径（仓库负责转发，服务不反向依赖适配器）
setMtaReceiveTextSavedNotifier((savedPath: string): void => {
  notifyMtaTextSaved(savedPath);
});
