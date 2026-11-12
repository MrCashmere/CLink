/**
 * MtaDiscoveryModels.ets — 互传(MTA)发现纯逻辑模型
 *
 * 仅包含无设备、无系统 API 依赖的纯数据类型与判定函数：
 * 蓝牙开关三态映射、互传分组整组清空的原因分类与诊断事件、发现意图解析、
 * 发现扫描健康度与停顿判定、条目存活期判定。
 * 供 MtaRepository 等运行时模块复用，并可被设备端 Instrument Test 直接覆盖。
 */

// ── 蓝牙开关三态 ──

/** 蓝牙开关状态三态 */
export enum MtaBluetoothStatus {
  /** 已开启（明确开启态） */
  ENABLED = 'enabled',
  /** 已关闭（明确关闭态） */
  DISABLED = 'disabled',
  /** 不可确定（查询异常、中间态、未知态） */
  UNKNOWN = 'unknown'
}

/** 蓝牙开关状态的归一化观测值（把系统原始状态收敛为可判定类别） */
export enum MtaBluetoothObservation {
  /** 明确开启 */
  ON = 'on',
  /** 明确关闭 */
  OFF = 'off',
  /** 中间态（正在开启/正在关闭） */
  TRANSITIONAL = 'transitional',
  /** 查询失败/状态不可得 */
  UNAVAILABLE = 'unavailable'
}

/**
 * 蓝牙观测值 → 三态（纯函数）。
 * 仅「明确开启」映射为已开启、「明确关闭」映射为已关闭；中间态与查询失败一律映射为不可确定，
 * 不得把「不可确定」折叠为「已关闭」，否则状态查询异常会被误判为关闭并触发误清空。
 */
export function mapMtaBluetoothObservation(observation: MtaBluetoothObservation): MtaBluetoothStatus {
  switch (observation) {
    case MtaBluetoothObservation.ON:
      return MtaBluetoothStatus.ENABLED;
    case MtaBluetoothObservation.OFF:
      return MtaBluetoothStatus.DISABLED;
    default:
      return MtaBluetoothStatus.UNKNOWN;
  }
}

/** 三态是否为「不可确定」 */
export function isMtaBluetoothUnknown(status: MtaBluetoothStatus): boolean {
  return status === MtaBluetoothStatus.UNKNOWN;
}

/** 三态是否为「确认关闭」（唯一允许清空/隐藏互传分组的条件） */
export function isMtaBluetoothConfirmedOff(status: MtaBluetoothStatus): boolean {
  return status === MtaBluetoothStatus.DISABLED;
}

/** 是否应由蓝牙状态触发互传分组清空（纯函数）：仅「确认关闭」为真，不可确定与已开启均不得清空 */
export function shouldClearMtaOnBluetoothStatus(status: MtaBluetoothStatus): boolean {
  return status === MtaBluetoothStatus.DISABLED;
}

// ── 发现意图（可见性期望 与 发送暂停） ──

/** 互传发现意图快照：可见性期望与发送暂停为两个相互独立的意图 */
export class MtaDiscoveryIntent {
  /** 页面可见性期望（用户在该页且互传总开关开启时为真） */
  visibilityDesired: boolean = false;
  /** 发送期间的临时暂停（仅挂起，不抹除可见性期望） */
  sendSuspended: boolean = false;
}

/**
 * 依据两个独立意图解析「是否应处于发现扫描状态」（纯函数）：
 * 发送暂停只临时挂起扫描，不抹除可见性期望；发送结束后按可见性期望即可恢复。
 */
export function resolveMtaShouldScan(intent: MtaDiscoveryIntent): boolean {
  return intent.visibilityDesired && !intent.sendSuspended;
}

/** 更新可见性期望（纯函数，返回新快照；不改动发送暂停意图） */
export function withMtaVisibilityDesired(intent: MtaDiscoveryIntent, visible: boolean): MtaDiscoveryIntent {
  let next = new MtaDiscoveryIntent();
  next.visibilityDesired = visible;
  next.sendSuspended = intent.sendSuspended;
  return next;
}

/** 更新发送暂停意图（纯函数，返回新快照；不改动可见性期望） */
export function withMtaSendSuspended(intent: MtaDiscoveryIntent, suspended: boolean): MtaDiscoveryIntent {
  let next = new MtaDiscoveryIntent();
  next.visibilityDesired = intent.visibilityDesired;
  next.sendSuspended = suspended;
  return next;
}

// ── 整组清空原因分类与诊断事件 ──

/** 互传分组整组清空的原因分类（互斥且可区分） */
export enum MtaDeviceListClearReason {
  /** 蓝牙真实关闭 */
  BLUETOOTH_DISABLED = 'bluetooth_disabled',
  /** 蓝牙状态误判（不可确定被当作已关闭） */
  BLUETOOTH_STATE_MISJUDGED = 'bluetooth_state_misjudged',
  /** 超时剔除（扫描健康时把陈旧条目剔除至空） */
  STALE_PRUNE = 'stale_prune',
  /** 发现扫描静默停顿 */
  SCAN_STALL = 'scan_stall',
  /** 其它/未知原因 */
  UNKNOWN = 'unknown'
}

/** 整组清空的触发场景标签 */
export enum MtaDeviceListClearScene {
  /** 蓝牙开关事件 */
  BLUETOOTH_EVENT = 'bluetooth_event',
  /** 发送前暂停发现 */
  SEND_PAUSE = 'send_pause',
  /** 扫描停止/页面离开 */
  SCAN_STOP = 'scan_stop',
  /** 用户主动刷新 */
  RESCAN = 'rescan',
  /** 周期性陈旧剔除 */
  PRUNE_TIMER = 'prune_timer',
  /** 扫描停顿检测 */
  SCAN_STALL = 'scan_stall',
  /** 扫描启动前清理 */
  SCAN_START = 'scan_start',
  /** 其它/未知场景 */
  UNKNOWN = 'unknown'
}

/** 清空诊断事件：一次「非空→空」跃迁的可诊断记录 */
export class MtaDeviceListClearedEvent {
  /** 清空原因分类 */
  reason: MtaDeviceListClearReason = MtaDeviceListClearReason.UNKNOWN;
  /** 清空前的条目数 */
  countBefore: number = 0;
  /** 发生时刻（毫秒时间戳） */
  occurredAtMs: number = 0;
  /** 触发场景标签 */
  scene: MtaDeviceListClearScene = MtaDeviceListClearScene.UNKNOWN;
}

/** 构造清空诊断事件（纯函数）：条目数归一到非负整数 */
export function buildMtaDeviceListClearedEvent(reason: MtaDeviceListClearReason, countBefore: number,
  occurredAtMs: number, scene: MtaDeviceListClearScene): MtaDeviceListClearedEvent {
  let event = new MtaDeviceListClearedEvent();
  event.reason = reason;
  event.countBefore = Math.max(0, Math.floor(countBefore));
  event.occurredAtMs = occurredAtMs;
  event.scene = scene;
  return event;
}

/** 清空原因 → 可读文本（诊断日志用） */
export function mtaClearReasonText(reason: MtaDeviceListClearReason): string {
  switch (reason) {
    case MtaDeviceListClearReason.BLUETOOTH_DISABLED:
      return '蓝牙真实关闭';
    case MtaDeviceListClearReason.BLUETOOTH_STATE_MISJUDGED:
      return '蓝牙状态误判';
    case MtaDeviceListClearReason.STALE_PRUNE:
      return '超时剔除';
    case MtaDeviceListClearReason.SCAN_STALL:
      return '发现扫描停顿';
    default:
      return '未知原因';
  }
}

/** 触发场景 → 可读文本（诊断日志用） */
export function mtaClearSceneText(scene: MtaDeviceListClearScene): string {
  switch (scene) {
    case MtaDeviceListClearScene.BLUETOOTH_EVENT:
      return '蓝牙开关事件';
    case MtaDeviceListClearScene.SEND_PAUSE:
      return '发送暂停发现';
    case MtaDeviceListClearScene.SCAN_STOP:
      return '扫描停止';
    case MtaDeviceListClearScene.RESCAN:
      return '主动刷新';
    case MtaDeviceListClearScene.PRUNE_TIMER:
      return '周期剔除';
    case MtaDeviceListClearScene.SCAN_STALL:
      return '扫描停顿检测';
    case MtaDeviceListClearScene.SCAN_START:
      return '扫描启动清理';
    default:
      return '未知场景';
  }
}

/** 格式化清空诊断文本（纯函数）：原因 + 清空前条目数 + 场景 + 时刻 */
export function formatMtaDeviceListClearedLog(event: MtaDeviceListClearedEvent): string {
  return `互传分组整组清空：原因=${mtaClearReasonText(event.reason)}` +
    ` 清空前条目数=${event.countBefore} 场景=${mtaClearSceneText(event.scene)}` +
    ` 时刻=${event.occurredAtMs}`;
}

/** 两个清空原因是否为可区分的不同原因（分类互斥） */
export function isMtaClearReasonDistinct(a: MtaDeviceListClearReason, b: MtaDeviceListClearReason): boolean {
  return a !== b;
}

// ── 发现扫描健康度与停顿 ──

/** 发现扫描健康度快照 */
export class MtaScanHealth {
  /** 是否处于扫描中 */
  scanning: boolean = false;
  /** 最近一次有新发现结果的时刻（0 表示本次扫描会话尚无发现） */
  lastResultMs: number = 0;
  /** 本次扫描会话起始时刻 */
  sessionStartMs: number = 0;
  /** 是否疑似静默停顿 */
  suspectedStall: boolean = false;
}

/**
 * 构建扫描健康度快照（纯函数）。
 * 健康判定基准取「最近一次有新发现结果的时刻」；本次会话尚无发现时以会话起始时刻为基准，
 * 避免刚起扫即被判为停顿。处于扫描中且基准时刻距当前达到停顿阈值即疑似静默停顿。
 */
export function buildMtaScanHealth(scanning: boolean, lastResultMs: number, sessionStartMs: number,
  nowMs: number, stallThresholdMs: number): MtaScanHealth {
  let health = new MtaScanHealth();
  health.scanning = scanning;
  health.lastResultMs = lastResultMs;
  health.sessionStartMs = sessionStartMs;
  let reference = lastResultMs > 0 ? lastResultMs : sessionStartMs;
  health.suspectedStall = scanning && reference > 0 && stallThresholdMs > 0 &&
    nowMs - reference >= stallThresholdMs;
  return health;
}

/** 扫描是否健康（扫描中且未疑似停顿） */
export function isMtaScanHealthy(health: MtaScanHealth): boolean {
  return health.scanning && !health.suspectedStall;
}

/** 是否允许执行超时剔除（仅扫描健康时允许；扫描不健康一律跳过，不改变列表） */
export function shouldPruneStaleDevices(health: MtaScanHealth): boolean {
  return isMtaScanHealthy(health);
}

/**
 * 自愈重试是否可尝试起扫（纯函数）：蓝牙非「确认关闭」（确认关闭时起扫必然失败，
 * 交由蓝牙状态事件在开启后恢复），且已过上次失败冷却。
 * 调用方另行判定「是否仍期望扫描」「是否已在扫描」两个前置。
 */
export function shouldAttemptMtaScanRearm(bluetooth: MtaBluetoothStatus, nowMs: number,
  blockedUntilMs: number): boolean {
  return bluetooth !== MtaBluetoothStatus.DISABLED && nowMs >= blockedUntilMs;
}

/** 是否允许触发停顿恢复（疑似停顿且已超出恢复冷却窗口） */
export function shouldTriggerScanRecovery(health: MtaScanHealth, nowMs: number, lastRecoveryMs: number,
  recoveryCooldownMs: number): boolean {
  if (!health.suspectedStall) {
    return false;
  }
  return nowMs - lastRecoveryMs >= recoveryCooldownMs;
}

/** 条目是否已超过存活时长（纯函数）：以最近一次被发现时刻为基准 */
export function isStaleByTtl(lastSeenMs: number, nowMs: number, ttlMs: number): boolean {
  return lastSeenMs < nowMs - ttlMs;
}

/**
 * 主动刷新确认：条目是否在刷新基准时刻之后未再上报（即刷新后未再被扫描到，视为离线）。
 * 以严格早于基准判定——基准为 0（未布置刷新确认）时一律不判为缺失，刷新同一毫秒的上报按保留处理。
 */
export function isMissingSinceRescan(lastSeenMs: number, rescanEpochMs: number): boolean {
  return rescanEpochMs > 0 && lastSeenMs < rescanEpochMs;
}
