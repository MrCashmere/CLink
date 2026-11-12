/**
 * MtaSendModels.ets — MTA 发送端数据类型与纯函数
 *
 * 本文件仅包含发送端数据视图类型、事件回调集合与可单测的纯函数（无系统 API 依赖），
 * 供 MtaBleClient / MtaP2pGroup / MtaSendService 共用。
 * 协议类型（DeviceInfoJson/P2pInfoJson/WsMessage 等）复用 MtaProtocolModels，避免双份定义。
 */

import { DeviceInfoJson, bytesToHex } from './MtaProtocolModels';
import { MtaConstants } from '../../service/mta/MtaConstants';
import { LogLevels } from '../../common/LogLevels';
import { resolveMtaBrandName } from './MtaBrandRegistry';

// ── 发送阶段状态机 ──

/** 发送端阶段（连接 → 建组 → 启动服务器 → 写凭据 → WS 协商 → 传输 → 终态） */
export enum MtaSenderStage {
  /** 未启动 */
  IDLE = 'idle',
  /** 连接对端 GATT Server */
  GATT_CONNECTING = 'gatt_connecting',
  /** 对端忙（非就绪），有界等待其恢复就绪 */
  WAITING_PEER_READY = 'waiting_peer_ready',
  /** 创建 WiFi Direct 群组 */
  GROUP_CREATING = 'group_creating',
  /** 启动本机 TLS 服务器 */
  SERVER_STARTING = 'server_starting',
  /** 已写回 P2pInfo */
  P2P_INFO_WRITTEN = 'p2p_info_written',
  /** 等待对端建立 WS 连接 */
  WAITING_WS = 'waiting_ws',
  /** 版本协商完成 */
  NEGOTIATED = 'negotiated',
  /** 已发送 sendRequest、等待对端确认（对端开始下载前的有界等待阶段） */
  WAITING_PEER_CONFIRM = 'waiting_peer_confirm',
  /** 传输中 */
  TRANSFERRING = 'transferring',
  /** 本次发送完成 */
  COMPLETED = 'completed',
  /** 本次发送仅部分完成（对端回送成功类型 + 部分接收原因，只收了部分文件） */
  PARTIAL = 'partial',
  /** 对端拒绝接收（终态，与 FAILED 并列） */
  REJECTED = 'rejected',
  /** 本次发送失败 */
  FAILED = 'failed',
  /** 用户已取消，正在通知对端取消（非终态：终态仍为 CANCELLED） */
  CANCEL_NOTIFYING = 'cancel_notifying',
  /** 用户取消 */
  CANCELLED = 'cancelled'
}

/** 对端拒绝接收（含未在确认窗口内开始接收）时面向用户的结果文案 */
export const MTA_PEER_REJECTED_TEXT: string = '对方拒绝接收';

/**
 * 等待确认阶段对端已放弃接收时面向用户的结果文案：
 * 覆盖对端关闭连接 / 读取失败 / 状态等待超时 / 退出本次 P2P 组四类「对端放弃」信号，
 * 原始失败原因仍完整保留在日志中以便定位。
 */
export const MTA_PEER_ABANDONED_TEXT: string = '对方已放弃接收';

/** 对端仅接收部分文件（成功类型 + 部分接收原因）时面向用户的结果文案 */
export const MTA_PARTIAL_COMPLETED_TEXT: string = '部分完成（仅接收部分文件）';

/** 用户取消且已通知对端时面向用户的结果文案 */
export const MTA_CANCELLED_TEXT: string = '已取消';

/** 用户取消但未能通知对端（等待上限到期或用户直接返回）时面向用户的结果文案 */
export const MTA_CANCEL_NOTIFY_FAILED_TEXT: string = '已取消（未能通知对方）';

/** 对端忙（DeviceInfo.state 非就绪值）时面向用户的结果文案 */
export const MTA_PEER_BUSY_TEXT: string = '对端设备正忙，请稍后重试';

/**
 * 对端拒绝状态的原因文本 → 面向用户的可读文案。
 * `user refuse` / `timeout` 为协议约定原因；未知原因保留原文，空原因回退默认文案。
 */
export function mtaRejectReasonText(reason: string): string {
  if (reason === 'user refuse') {
    return MTA_PEER_REJECTED_TEXT;
  }
  if (reason === 'timeout') {
    return '对方未在时限内响应';
  }
  return reason.length > 0 ? `对方拒绝：${reason}` : MTA_PEER_REJECTED_TEXT;
}

/**
 * 判定对端是否处于「忙」状态（纯函数，无副作用、可单测）。
 * 严格「非就绪即忙」：对端 DeviceInfo.state 为就绪值（MtaConstants.DEVICE_INFO_STATE）
 * 以外任何值即视为忙；就绪值不触发任何短路，保证既有发送流程零回归。
 */
export function isMtaPeerBusy(state: number): boolean {
  return state !== MtaConstants.DEVICE_INFO_STATE;
}

/**
 * 对端忙原因码 → 诊断日志可读原因（纯函数，无副作用、可单测）：
 * 1 镜像占用、2 热点占用，其余（含缺省 0）为通用未知原因。
 * 仅用于日志归因，面向用户统一使用 MTA_PEER_BUSY_TEXT。
 */
export function mtaPeerBusyReasonText(reason: number): string {
  if (reason === MtaConstants.PEER_BUSY_REASON_MIRROR) {
    return '镜像占用';
  }
  if (reason === MtaConstants.PEER_BUSY_REASON_HOTSPOT) {
    return '热点占用';
  }
  return '未知原因';
}

/**
 * 对端忙是否值得短时复读（纯函数）：非忙一律不复读；原因码为「镜像占用/热点占用」等明确
 * 冲突时复读无益，直接收束；其余（含缺省 0 = 未知原因）按上一会话收尾期残留处理，允许复读。
 */
export function shouldRetryPeerBusy(state: number, reason: number): boolean {
  if (!isMtaPeerBusy(state)) {
    return false;
  }
  if (reason === MtaConstants.PEER_BUSY_REASON_MIRROR || reason === MtaConstants.PEER_BUSY_REASON_HOTSPOT) {
    return false;
  }
  return true;
}

// ── 写回后复读对端公开信息的比对（纯函数：无副作用、不依赖系统 API，可导出单测） ──

/** 「写回 P2pInfo 后复读对端公开信息」的比对结论（纯数据契约） */
export class MtaPeerInfoRecheckResult {
  /** 复读是否成功 */
  success: boolean = false;
  /** 复读失败原因（成功时为空串） */
  failureReason: string = '';
  /** 复读原文相对首次读取是否发生变化（整体文本比对） */
  contentChanged: boolean = false;
  /** 对端 state 是否发生变化 */
  stateChanged: boolean = false;
  /** 首次读取的 state 原始值（-1 表示未取得） */
  firstState: number = -1;
  /** 复读得到的 state 原始值（-1 表示未取得或解析失败） */
  recheckState: number = -1;
  /** 判定结论文本（供日志汇总） */
  conclusion: string = '';
}

/**
 * 依据「首次读取」与「写回后复读」的对端公开信息判定写回是否被对端处理（纯函数）。
 * 对端服务端「读正常、写无响应」时，本地写成功不代表对端已处理，故以复读结果为判定依据：
 * state 变化 → 写回已被处理；仅其他字段变化 → 写回已被处理（非 state 字段变化）；
 * 内容无变化 → 写回可能未被对端处理。
 */
export function evaluatePeerInfoRecheck(firstState: number, firstRaw: string,
  recheckState: number, recheckRaw: string): MtaPeerInfoRecheckResult {
  let result = new MtaPeerInfoRecheckResult();
  result.success = true;
  result.firstState = firstState;
  result.recheckState = recheckState;
  result.contentChanged = firstRaw !== recheckRaw;
  result.stateChanged = firstState !== recheckState;
  if (result.stateChanged) {
    result.conclusion = `对端公开信息已变化（state ${firstState}→${recheckState}），判定写回已被对端处理`;
  } else if (result.contentChanged) {
    result.conclusion = `对端公开信息有变化但 state 未变（state=${firstState}），判定写回已被对端处理（非 state 字段变化）`;
  } else {
    result.conclusion = `对端公开信息无变化（state=${firstState}），判定写回可能未被对端处理`;
  }
  return result;
}

/** 构造复读失败结论：写回后链路已不可用（复读不成功即无法证明写回被处理） */
export function buildPeerInfoRecheckFailure(reason: string): MtaPeerInfoRecheckResult {
  let result = new MtaPeerInfoRecheckResult();
  result.success = false;
  result.failureReason = reason;
  result.conclusion = `复读失败（${reason}），判定写回后链路已不可用`;
  return result;
}

// ── 写回 P2pInfo 的写方式与写诊断（纯函数：无副作用、不依赖系统 API，可导出单测） ──

/** 带响应写（ATT Write Request）方式文案：等待对端写回调 */
export const MTA_P2P_WRITE_MODE_WRITE_TEXT: string = '带响应写(WRITE)';

/** 无响应写（ATT Write Command）方式文案：对端不回回调，本地返回即视为已发出 */
export const MTA_P2P_WRITE_MODE_NO_RESPONSE_TEXT: string = '无响应写(WRITE_NO_RESPONSE)';

/**
 * 按对端写特征能力选择写回 P2pInfo 的写方式文案（纯函数）。
 * 对端写特征声明支持无响应写即用无响应写，否则用带响应写：中兴 GATT Server 对写请求不回
 * `sendResponse`，对其用带响应写会一直等到超时，必须用无响应写；小米等会回写响应，用带响应写
 * 并等待写结果。写回执不作为成功判据（无响应写无回调，是否被处理由端到端信号判定）。
 */
export function resolveMtaP2pWriteModeText(useNoResponseWrite: boolean): string {
  return useNoResponseWrite ? MTA_P2P_WRITE_MODE_NO_RESPONSE_TEXT : MTA_P2P_WRITE_MODE_WRITE_TEXT;
}

/**
 * 格式化写回 P2pInfo 的细粒度写诊断文本（纯函数）。
 * 覆盖写方式、写目标特征 UUID、协商 MTU、写内容长度、写发起到结束的耗时、写结果与失败原因，
 * 供写入发起/结束日志与失败归因使用。无响应写无对端回调，其「成功」仅代表本地已发出，
 * 不代表对端已处理；带响应写的「成功」代表已收到对端写回调。
 */
export function formatMtaP2pWriteDiagnostic(useNoResponseWrite: boolean, targetCharUuid: string,
  mtu: number, bytesLength: number, costMs: number, success: boolean, failureReason: string): string {
  let resultText = '';
  if (!success) {
    resultText = `失败（${failureReason.length > 0 ? failureReason : '未知原因'}）`;
  } else if (useNoResponseWrite) {
    resultText = '成功（本地已发出，无写回调）';
  } else {
    resultText = '成功（收到写回调）';
  }
  return `写方式=${resolveMtaP2pWriteModeText(useNoResponseWrite)} 目标特征=${targetCharUuid} MTU=${mtu}` +
    ` 长度=${bytesLength} 耗时=${costMs}ms 写结果=${resultText}`;
}

// ── 对外发送的本机 P2P 地址归一（纯函数：无副作用、不依赖系统 API，可导出单测） ──

/** 冒号分隔的 MAC 地址形态（6 组两位十六进制），用于区分明文地址与加密分支的 Base64 密文 */
const MTA_MAC_ADDRESS_PATTERN: RegExp = new RegExp('^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$');

/**
 * 把本机 P2P 设备地址规范化为小写形式（纯函数）。
 * 中兴接收端用大小写敏感的 `equals` 与其发现阶段看到的（小写）地址比对，而本机 Native 以大写
 * `{:02X}` 生成，导致中兴匹配不到本机 `mac` 而退化为地址驱动连接并失败；小米用
 * `equalsIgnoreCase` 不受大小写影响。统一小写可同时满足两类接收端，无需按厂商分支。
 * 仅对 MAC 地址形态归一：非该形态的输入（如 P2pInfo 加密分支的 Base64 密文，Base64 大小写敏感）
 * 原样返回，避免破坏密文；空串与不含字母的纯数字占位地址经归一后保持不变，不改变「地址不可得」的既有语义。
 */
export function normalizeMtaP2pMac(mac: string): string {
  if (!MTA_MAC_ADDRESS_PATTERN.test(mac)) {
    return mac;
  }
  return mac.toLowerCase();
}

// ── 发送伴随外设的对端行为记录（纯函数：无副作用、不依赖系统 API，可导出单测） ──

/**
 * 发送伴随外设上的对端行为累计。
 * 发送期间本机保持一个最小 BLE 外设（广播 + GATT Server）供对端反连；本结构仅汇总对端
 * 在该外设上的连接/断开/读/写行为，用于判定对端是否依赖发送方外设（不接入接收会话）。
 */
export class MtaCompanionPeerBehavior {
  /** GATT 连接次数 */
  connectCount: number = 0;
  /** GATT 断开次数 */
  disconnectCount: number = 0;
  /** 读请求次数（对端读取本外设的 DeviceInfo） */
  readCount: number = 0;
  /** 写请求次数（分片累积与提交均计入） */
  writeCount: number = 0;
  /** 是否收到过完整的 P2pInfo 写入 */
  p2pInfoReceived: boolean = false;
}

/**
 * 汇总发送伴随外设上的对端行为（纯函数）。
 * 在发送收束（外设停止）时输出，作为「对端是否反连本机外设」及其读写行为的判定依据。
 */
export function formatCompanionPeerBehaviorSummary(behavior: MtaCompanionPeerBehavior): string {
  return `对端行为汇总：连接=${behavior.connectCount} 断开=${behavior.disconnectCount}` +
    ` 读=${behavior.readCount} 写=${behavior.writeCount}` +
    ` 收到P2pInfo=${behavior.p2pInfoReceived ? '是' : '否'}`;
}

/**
 * 格式化发送伴随外设上的对端写请求记录文本（纯函数）。
 * 覆盖写目标特征 UUID、分片偏移、累计长度与是否为分片写（prepared write）。
 */
export function formatCompanionWriteRequest(targetCharUuid: string, offset: number,
  totalLength: number, isPrepared: boolean): string {
  return `目标特征=${targetCharUuid} offset=${offset} 累计长度=${totalLength}` +
    ` prepared=${isPrepared ? '是' : '否'}`;
}

// ── 发送端数据视图 ──

/** 扫描发现的 MTA 接收端设备 */
export class MtaDiscoveredDevice {
  /** BLE 设备标识（GATT 连接用） */
  bleAddress: string = '';
  /** 设备名 */
  deviceName: string = '';
  /** 设备 ID 十六进制（主广播前 6 字节 + 扫描响应尾段 10 字节拼接，完整时 32 hex 字符） */
  senderIdHex: string = '';
  /** 品牌名 */
  brandName: string = '未知';
  /** 品牌 ID（主广播 serviceData UUID 中的品牌字节，-1 表示未知） */
  brandId: number = -1;
  /** 是否支持 5GHz */
  is5Ghz: boolean = false;
  /** 信号强度（dBm） */
  rssi: number = 0;
  /** 最近发现的毫秒时间戳（用于扫描收尾的陈旧条目剔除） */
  lastSeen: number = 0;
}

/** 待发送文件 */
export class MtaSendFile {
  /** 选择器返回的原始 URI（fd 直读的数据源） */
  uri: string = '';
  /** 显示文件名 */
  displayName: string = '';
  /** 文件大小（字节，取自已打开句柄 statSync(file.fd)，与将发送字节同源） */
  sizeBytes: number = 0;
  /** ZIP 条目名（"{序号}/{显示文件名}"） */
  entryName: string = '';
  /** 源文件修改时间（Unix 毫秒，可缺省）；取自已打开句柄 statSync，用于写入 ZIP 条目时间 */
  lastModified: number | undefined = undefined;
  /** 下载发送读取 fd（-1 表示未打开） */
  fdSend: number = -1;
}

/** 发送进度 */
export class MtaSendProgress {
  /** 已读源字节（有效数据口径，进度分子） */
  sentBytes: number = 0;
  /** 总字节（进度分母，声明源总大小） */
  totalBytes: number = 0;
  /** 百分比（0-100） */
  percent: number = 0;
  /** 出网字节累计（网络口径，速率分子；压缩生效时与 sentBytes 不同） */
  networkBytes: number = 0;
}

/** 加密后的 P2P 凭据（Base64 字段） */
export class EncryptedCredentials {
  /** AES-256-CTR 加密后的 SSID（Base64） */
  ssid: string = '';
  /** AES-256-CTR 加密后的 PSK（Base64） */
  psk: string = '';
  /** AES-256-CTR 加密后的 MAC（Base64） */
  mac: string = '';
}

/** WiFi Direct 群组信息视图 */
export class MtaGroupInfo {
  /** 群组 SSID */
  ssid: string = '';
  /** 群组口令 */
  psk: string = '';
  /** 本机 GO 网关地址 */
  goIp: string = '';
  /** 群主设备地址（本机 p2p0 MAC） */
  ownerMac: string = '';
  /** 已接入客户端数 */
  clientCount: number = 0;
  /** 频段 */
  frequency: number = 0;
}

/** 一次发送的完整会话上下文 */
export class MtaSendSession {
  /** 选中文件清单 */
  files: Array<MtaSendFile> = [];
  /** 任务 ID（同时用作下载 query 参数） */
  taskId: string = '';
  /** 发送者 ID 十六进制 */
  senderIdHex: string = '';
  /** 发送者显示名（由发送服务按设备昵称填充） */
  senderName: string = '';
  /** WiFi Direct 群组 SSID */
  groupSsid: string = '';
  /** WiFi Direct 群组口令 */
  groupPsk: string = '';
  /** WiFi Direct 群组频点（MHz，写入 P2pInfo.freq） */
  groupFrequency: number = 0;
  /** 对端可访问的 GO 网关地址 */
  goIp: string = '';
  /** 本机 p2p0 MAC */
  localMac: string = '';
  /** 本机 TLS 服务器端口 */
  port: number = 0;
  /** 本机 ECDH 公钥（Base64 SPKI DER） */
  localPublicKey: string = '';
  /** 总字节 */
  totalBytes: number = 0;
}

/** 发送端完整状态（服务持有，向 VM 推送快照） */
export class SenderState {
  /** 当前阶段 */
  stage: MtaSenderStage = MtaSenderStage.IDLE;
  /** 是否扫描中 */
  scanning: boolean = false;
  /** 已发现设备列表 */
  devices: Array<MtaDiscoveredDevice> = [];
  /** 已选中设备 */
  selected: MtaDiscoveredDevice | undefined = undefined;
  /** 当前发送会话 */
  session: MtaSendSession | undefined = undefined;
  /** 发送进度 */
  progress: MtaSendProgress = new MtaSendProgress();
  /** 最近一次错误原因 */
  lastError: string = '';
  /** Rust 服务器是否运行 */
  serverRunning: boolean = false;
  /** 是否已建组 */
  groupCreated: boolean = false;

  /** 复制当前状态为独立快照（V2 @Trace 需整体替换才触发刷新） */
  snapshot(): SenderState {
    let copy = new SenderState();
    copy.stage = this.stage;
    copy.scanning = this.scanning;
    copy.devices = this.devices.slice();
    copy.selected = this.selected;
    copy.session = this.session;
    copy.progress = this.progress;
    copy.lastError = this.lastError;
    copy.serverRunning = this.serverRunning;
    copy.groupCreated = this.groupCreated;
    return copy;
  }
}

// ── 事件回调集合 ──

/** MtaBleClient → 服务 事件回调 */
export class MtaBleClientEventHandlers {
  /** 发现/更新设备（按 bleAddress 去重后） */
  onDeviceFound: (device: MtaDiscoveredDevice) => void = (device: MtaDiscoveredDevice): void => {
  };
  /** 扫描状态变化 */
  onScanStateChange: (scanning: boolean, detail: string) => void = (scanning: boolean, detail: string): void => {
  };
  /** 蓝牙开关状态变化 */
  onBluetoothStateChange: (stateText: string) => void = (stateText: string): void => {
  };
  /** GATT Client 连接状态变化 */
  onGattConnectionChange: (stateText: string) => void = (stateText: string): void => {
  };
  /** MTU 协商结果回填 */
  onMtuChange: (mtu: number) => void = (mtu: number): void => {
  };
  /** 读回对端 DeviceInfo */
  onRemoteDeviceInfo: (info: DeviceInfoJson) => void = (info: DeviceInfoJson): void => {
  };
  /** 错误上报 */
  onError: (source: string, message: string) => void = (source: string, message: string): void => {
  };
}

/** MtaP2pGroup → 服务 事件回调 */
export class MtaP2pGroupEventHandlers {
  /** p2pConnectionChange 状态摘要 */
  onConnectionChange: (summary: string) => void = (summary: string): void => {
  };
  /** 取得 GO IP */
  onGoIp: (goIp: string) => void = (goIp: string): void => {
  };
  /** 错误上报 */
  onError: (source: string, message: string) => void = (source: string, message: string): void => {
  };
}

/** MtaSendService → ViewModel 事件回调 */
export class MtaSendEventHandlers {
  /** 状态快照变化 */
  onStateChange: (state: SenderState) => void = (state: SenderState): void => {
  };
}

// ── 纯函数 ──

/** 构造 ZIP 条目名："{序号}/{显示文件名}"（序号从 1 开始） */
export function buildEntryName(index: number, displayName: string): string {
  return `${index + 1}/${displayName}`;
}

/** 生成随机群组口令（数字 + 小写字母，长度见 GROUP_PASSPHRASE_LENGTH） */
export function randomPassphrase(): string {
  let chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  let out = '';
  for (let i = 0; i < MtaConstants.GROUP_PASSPHRASE_LENGTH; i++) {
    let idx = Math.floor(Math.random() * chars.length);
    out += chars.charAt(idx);
  }
  return out;
}

/** 生成随机任务 ID（时间戳 + 随机后缀） */
export function randomTaskId(): string {
  let suffix = Math.floor(Math.random() * 0x1000000).toString(16);
  while (suffix.length < 6) {
    suffix = '0' + suffix;
  }
  return `mta-${Date.now().toString(16)}-${suffix}`;
}

/** 生成随机群组名（前缀 + 8 位十六进制，前缀见 GROUP_NAME_PREFIX） */
export function randomGroupName(): string {
  let suffix = Math.floor(Math.random() * 0x100000000).toString(16);
  while (suffix.length < 8) {
    suffix = '0' + suffix;
  }
  return `${MtaConstants.GROUP_NAME_PREFIX}${suffix}`;
}

/** 从选中文件清单计算总字节数 */
export function totalFileBytes(files: Array<MtaSendFile>): number {
  let total = 0;
  for (let i = 0; i < files.length; i++) {
    total += files[i].sizeBytes;
  }
  return total;
}

/** 品牌 ID 是否属于 Samsung 区间 [70, 75] */
export function isSamsungBrandId(brandId: number): boolean {
  return brandId >= 70 && brandId <= 75;
}

/** 建组候选：群主频段 + 限定频点（按优先级排列；5GHz 候选同时携带频段与频点） */
export class MtaGroupBandCandidate {
  /** 群主频段（对齐 GroupOwnerBand） */
  band: number = 0;
  /** 限定频点（MHz，0 表示不设 goFreq，仅按频段请求） */
  freqMhz: number = 0;
}

/**
 * 按目标品牌与 5GHz 支持能力给出建组候选（按优先级排列）。
 * Samsung 的 WiFi Direct 在 5GHz 下与三方建组存在兼容问题，只用 2.4GHz；
 * 非 Samsung 且对端声明支持 5GHz 时显式优先请求 5GHz（频段 + 非 DFS 限定频点），
 * 失败/超时再快速回退 2.4GHz；其余情况只用 2.4GHz。品牌未知（-1）视为非 Samsung。
 */
export function resolvePreferredGroupBands(brandId: number, is5Ghz: boolean): MtaGroupBandCandidate[] {
  let band2ghz = new MtaGroupBandCandidate();
  band2ghz.band = MtaConstants.GROUP_OWNER_BAND_2GHZ;
  band2ghz.freqMhz = 0;
  if (isSamsungBrandId(brandId) || !is5Ghz) {
    return [band2ghz];
  }
  let band5ghz = new MtaGroupBandCandidate();
  band5ghz.band = MtaConstants.GROUP_OWNER_BAND_5GHZ;
  band5ghz.freqMhz = MtaConstants.GROUP_5GHZ_FREQUENCY_MHZ;
  return [band5ghz, band2ghz];
}

/** 群组实际频点（MHz）→ 频段标签；0 或落在已知区间外返回 `未知` */
export function bandLabelFromFrequency(freqMhz: number): string {
  if (freqMhz >= MtaConstants.FREQUENCY_2GHZ_MIN && freqMhz <= MtaConstants.FREQUENCY_2GHZ_MAX) {
    return '2.4GHz';
  }
  if (freqMhz >= MtaConstants.FREQUENCY_5GHZ_MIN && freqMhz <= MtaConstants.FREQUENCY_5GHZ_MAX) {
    return '5GHz';
  }
  return '未知';
}

/** 群组实际频点（MHz）是否落在 2.4GHz 受限区间（吞吐上限较低） */
export function isWeakBand(freqMhz: number): boolean {
  return freqMhz >= MtaConstants.FREQUENCY_2GHZ_MIN && freqMhz <= MtaConstants.FREQUENCY_2GHZ_MAX;
}

/**
 * 品牌 ID → 品牌名（委托 MtaBrandRegistry 这一单一事实源查询）。
 * 无法匹配返回 `未知(id)`，展示层由 mtaBrandBadgeText 回退为固定文案。
 */
export function mtaBrandNameOf(brandId: number): string {
  return resolveMtaBrandName(brandId);
}

/**
 * MTA 设备身份键：`senderIdHex` 非空时优先取其小写（去空白），否则回退 `bleAddress` 小写（去空白）。
 * 用于发现合并去重，使同一设备跨 BLE 地址变化时仍被识别为同一条目。
 */
export function mtaDeviceIdentityKey(device: MtaDiscoveredDevice): string {
  let senderId = device.senderIdHex.trim().toLowerCase();
  if (senderId.length > 0) {
    return senderId;
  }
  return device.bleAddress.trim().toLowerCase();
}

/** MTA 广播 serviceData 的解析产物：设备 ID 由主广播与扫描响应两段拼接，扫描响应另提供设备名字节，主广播提供品牌与 5GHz 标识 */
export class MtaAdvParseResult {
  /** 设备 ID 十六进制（主广播值前 6 字节 + 扫描响应 [0..10) 尾段拼接，完整时 32 hex 字符；两段均缺失时为空串） */
  senderIdHex: string = '';
  /** 设备 ID 前段十六进制（主广播 6 字节值；本次缺失时为空串） */
  idHeadHex: string = '';
  /** 设备 ID 尾段十六进制（扫描响应 [0..10)；本次缺失时为空串） */
  idTailHex: string = '';
  /** 设备名字段原始字节（扫描响应第 10~25 字节；无则空数组） */
  nameBytes: Uint8Array = new Uint8Array(0);
  /** 品牌 ID（主广播 UUID 字节解析；无则 -1） */
  brandId: number = -1;
  /** 品牌名（品牌 ID 无法匹配时为 `未知(id)`） */
  brandName: string = '未知';
  /** 是否支持 5GHz */
  is5Ghz: boolean = false;
  /** 5GHz 标记原始字节值（主广播 serviceData UUID 第 3 字节；未解析到时为 -1） */
  is5GhzFlagByte: number = -1;
  /** 支持 5GHz 的判定依据（按标记字节最低有效位 bit0 判定；未解析到标记时为固定文案） */
  is5GhzBasis: string = '未解析到标记字节';
  /** 原始 serviceData 描述（`UUID=字节hex`，多个以逗号连接） */
  rawServiceData: string = '';
  /** 解析异常描述 */
  anomalies: Array<string> = [];
}

/**
 * 解析 MTA 广播的 serviceData（`Map<UUID, 字节>`）。
 *
 * **按值的字节长度分类而非 UUID**：27 字节为扫描响应（[0..10) 设备 ID 尾段、
 * 第 10~25 字节设备名），6 字节为主广播（设备 ID 前 6 字节；5GHz 标识与品牌 ID
 * 编码在 serviceData UUID 的第 3、4 字节），其余长度忽略。设备 ID 由两段在遍历后
 * 拼接还原（与厂商扫描端按合并记录固定偏移 25..31 + 35..45 的拼接口径一致）；
 * 仅收到一段时以该段为指纹，两段均缺失时为空串。
 * 不按 UUID 判断是必要的：部分厂商（如荣耀）扫描响应的 serviceData
 * UUID 并非约定的 `0000ffff`，仅按 UUID 匹配会漏掉设备名。
 */
export function parseMtaAdvServiceData(serviceData: Map<string, Uint8Array>): MtaAdvParseResult {
  let result = new MtaAdvParseResult();
  let rawParts: Array<string> = [];
  // 设备 ID 两段：主广播值承载前 6 字节，扫描响应 [0..10) 承载尾段
  let idHead: Uint8Array = new Uint8Array(0);
  let idTail: Uint8Array = new Uint8Array(0);
  serviceData.forEach((value: Uint8Array, uuid: string): void => {
    rawParts.push(`${uuid}=${bytesToHex(value)}`);
    if (value.length === MtaConstants.SCAN_RSP_LENGTH) {
      idTail = value.slice(MtaConstants.SCAN_RSP_ID_TAIL_OFFSET,
        MtaConstants.SCAN_RSP_ID_TAIL_OFFSET + MtaConstants.SCAN_RSP_ID_TAIL_LENGTH);
      result.nameBytes = value.slice(MtaConstants.SCAN_RSP_NAME_OFFSET,
        MtaConstants.SCAN_RSP_NAME_OFFSET + MtaConstants.SCAN_RSP_NAME_LENGTH);
    } else if (value.length === MtaConstants.ADV_DATA_LENGTH) {
      idHead = value.slice(0, MtaConstants.ADV_DATA_LENGTH);
      let compact = uuid.split('-').join('').toLowerCase();
      let flag = parseInt(compact.substring(4, 6), 16);
      let brandId = parseInt(compact.substring(6, 8), 16);
      if (!isNaN(flag)) {
        // 保留标记原始字节值用于诊断；按标记字节最低有效位 bit0 判定「支持 5GHz」
        //（协议语义为 bit0=1 表示支持，其余位可能承载其他信息，不得按整字节相等判定，
        // 否则会漏判同时置其他位的对端，如中兴标记字节 0x03）
        result.is5GhzFlagByte = flag;
        result.is5Ghz = (flag & 0x01) === 0x01;
        result.is5GhzBasis = result.is5Ghz ? 'bit0=1 判定支持5GHz' : 'bit0=0 判定不支持5GHz';
      } else {
        result.is5GhzBasis = `5GHz 标记字节解析失败 uuid=${uuid}`;
      }
      if (!isNaN(brandId)) {
        result.brandId = brandId;
        result.brandName = mtaBrandNameOf(brandId);
      } else {
        result.anomalies.push(`品牌字节解析失败 uuid=${uuid}`);
      }
    } else {
      result.anomalies.push(`serviceData 长度未知 uuid=${uuid} len=${value.length}`);
    }
  });
  // 拼接设备 ID 两段（主广播前 6 字节在前、扫描响应尾段在后）；
  // 对端为旧布局（2 字节 ID + 零填充）时拼接产物仍为稳定指纹，不影响去重与重扫匹配
  result.idHeadHex = bytesToHex(idHead);
  result.idTailHex = bytesToHex(idTail);
  if (idHead.length > 0 || idTail.length > 0) {
    let merged = new Uint8Array(idHead.length + idTail.length);
    merged.set(idHead, 0);
    merged.set(idTail, idHead.length);
    result.senderIdHex = bytesToHex(merged);
  }
  result.rawServiceData = rawParts.length > 0 ? rawParts.join(', ') : '无';
  return result;
}

/**
 * 每地址的设备身份记忆：跨扫描回调累积同一设备已见的最完整身份与能力字段。
 * 主广播段与扫描响应段可能分次到达；若身份字段随本次回调缺失而回退，上层会把同一设备
 * 当作新设备，表现为列表出现多个条目、徽标在两个条目间跳变。故按地址保留已见值。
 */
export class MtaDeviceIdentityMemo {
  /** 已见设备 ID 前段（主广播 6 字节值；空串表示尚未见过） */
  headHex: string = '';
  /** 已见设备 ID 尾段（扫描响应 [0..10)；空串表示尚未见过） */
  tailHex: string = '';
  /** 已见品牌 ID（-1 表示未见过） */
  brandId: number = -1;
  /** 已见品牌名 */
  brandName: string = '';
  /** 是否已见过 5GHz 标记字节 */
  is5GhzKnown: boolean = false;
  /** 已见 5GHz 标记原始字节值 */
  is5GhzFlagByte: number = -1;
  /** 已见 5GHz 判定依据 */
  is5GhzBasis: string = '';
  /** 已见 5GHz 能力 */
  is5Ghz: boolean = false;
  /** 已见设备名字节（长度 0 表示未见过） */
  nameBytes: Uint8Array = new Uint8Array(0);
}

/**
 * 用记忆稳定本次解析结果（纯函数，就地更新 memo 与 adv）：
 * 两段设备 ID 按段累积（跨回调也能拼接出完整 16 字节 ID）；品牌 / 5GHz 标记 / 设备名
 * 本次解析到即更新，本次缺失则回退已见值。使同一设备跨扫描回调的身份与能力保持一致，
 * 消除列表条目与徽标抖动。
 */
export function stabilizeMtaAdvIdentity(memo: MtaDeviceIdentityMemo, adv: MtaAdvParseResult): void {
  if (adv.idHeadHex.length > 0) {
    memo.headHex = adv.idHeadHex;
  }
  if (adv.idTailHex.length > 0) {
    memo.tailHex = adv.idTailHex;
  }
  adv.senderIdHex = memo.headHex + memo.tailHex;
  if (adv.brandId >= 0) {
    memo.brandId = adv.brandId;
    memo.brandName = adv.brandName;
  } else if (memo.brandId >= 0) {
    adv.brandId = memo.brandId;
    adv.brandName = memo.brandName;
  }
  if (adv.is5GhzFlagByte >= 0) {
    memo.is5GhzKnown = true;
    memo.is5GhzFlagByte = adv.is5GhzFlagByte;
    memo.is5GhzBasis = adv.is5GhzBasis;
    memo.is5Ghz = adv.is5Ghz;
  } else if (memo.is5GhzKnown) {
    adv.is5GhzFlagByte = memo.is5GhzFlagByte;
    adv.is5GhzBasis = memo.is5GhzBasis;
    adv.is5Ghz = memo.is5Ghz;
  }
  if (adv.nameBytes.length > 0) {
    memo.nameBytes = adv.nameBytes;
  } else if (memo.nameBytes.length > 0) {
    adv.nameBytes = memo.nameBytes;
  }
}

/** Rust 日志桥接行的解析结果（级别 token + 正文） */
export class RustLogLine {
  /** 级别 token（Rust 原始 token，由调用方归一到规范五级） */
  level: string = LogLevels.INFO;
  /** 日志正文 */
  message: string = '';
}

/**
 * 解析 Rust 日志桥接行 `level|message`：
 * 按首个 `|` 分割，左为级别右为正文；无分隔符时级别按 info 兜底、整串为正文。
 */
export function parseRustLogLine(line: string): RustLogLine {
  let parsed = new RustLogLine();
  let sep = line.indexOf('|');
  if (sep >= 0) {
    parsed.level = line.substring(0, sep);
    parsed.message = line.substring(sep + 1);
  } else {
    parsed.level = LogLevels.INFO;
    parsed.message = line;
  }
  return parsed;
}

// ── 发送建链本地准备与关键路径就绪判定（纯函数：无副作用、不依赖系统 API，可导出单测） ──

/**
 * 发送侧「与对端无关的本地准备」进度快照。
 * 建组、启动本地传输服务、生成预览、打开直读 fd 均可在点击后立即并行推进；
 * 其中「写回凭据」只依赖「组就绪 + 对端信息可写 + 端口已知」三项前置。
 */
export class MtaSendPreparation {
  /** 本地随机群组名（不依赖对端） */
  groupName: string = '';
  /** 本地随机群组口令（不依赖对端） */
  passphrase: string = '';
  /** 组网是否就绪（已取得群组信息） */
  groupReady: boolean = false;
  /** 本地传输服务端口（-1 表示尚未就绪） */
  serverPort: number = -1;
  /** 发送直读 fd 是否已打开 */
  fdsOpened: boolean = false;
  /** 预览缩略图是否已就绪 */
  thumbnailReady: boolean = false;
  /** 对端当前广播地址（点击时记录，供「先用后扫」） */
  peerAddress: string = '';
  /** 本地准备失败原因（空串表示未失败） */
  serverError: string = '';
}

/** 并行建组任务的结果：群组信息 + 本机 P2P 设备地址 */
export class MtaGroupCreationResult {
  /** 群组信息（null 表示建组失败或会话已终止） */
  info: MtaGroupInfo | null = null;
  /** 本机 P2P 设备地址（Native 读取；空串表示不可得） */
  localMac: string = '';
}

/**
 * 会话群组身份：本次请求创建的群组名、就绪判定时实际观测到的群组名，及二者是否一致。
 * 建组就绪必须以它为准——就绪组名不等于本次请求创建的组名（如上一会话尚未拆除的残留组）时，
 * 一律视为未就绪，绝不下发其无线凭据。
 */
export class SessionGroupIdentity {
  /** 本次会话请求创建（randomGroupName 生成）的群组名 */
  requestedName: string = '';
  /** 就绪判定时实际观测到的群组名（不可得时为空串） */
  observedName: string = '';
  /** 观测组名是否等于请求组名 */
  matched: boolean = false;
}

/**
 * 判定「已就绪的群组即本次请求创建的群组」（纯函数）：
 * 请求组名与观测组名均非空且完全相等时判为匹配；观测组不可得或为上一会话残留组时一律不匹配。
 * `randomGroupName` 生成的是完整 SSID，`getCurrentGroup().groupName` 返回的也是完整 SSID，二者直接可比。
 */
export function matchMtaGroupIdentity(requestedName: string, observedName: string): SessionGroupIdentity {
  let identity = new SessionGroupIdentity();
  identity.requestedName = requestedName;
  identity.observedName = observedName;
  identity.matched = requestedName.length > 0 && observedName === requestedName;
  return identity;
}

/**
 * 写回凭据的关键路径就绪判定（纯函数）：
 * 仅当「组就绪 + 对端信息可写 + 本地端口已知」三者同时满足才允许写回；
 * 预览生成、句柄打开等其余本地准备不构成写回前置。
 */
export function resolveSendWritebackReady(groupReady: boolean, peerInfoWritable: boolean,
  serverPort: number): boolean {
  return groupReady && peerInfoWritable && serverPort > 0;
}

/** 发送建链有序阶段序列（用于阶段单调性判定；终态与取消相关阶段不在序列内） */
const MTA_SENDER_STAGE_ORDER: Array<MtaSenderStage> = [
  MtaSenderStage.GATT_CONNECTING,
  MtaSenderStage.WAITING_PEER_READY,
  MtaSenderStage.GROUP_CREATING,
  MtaSenderStage.SERVER_STARTING,
  MtaSenderStage.P2P_INFO_WRITTEN,
  MtaSenderStage.WAITING_WS,
  MtaSenderStage.NEGOTIATED,
  MtaSenderStage.WAITING_PEER_CONFIRM,
  MtaSenderStage.TRANSFERRING
];

/** 取有序阶段在序列内的序号（不在序列内返回 -1） */
export function mtaSenderStageOrder(stage: MtaSenderStage): number {
  for (let i = 0; i < MTA_SENDER_STAGE_ORDER.length; i++) {
    if (MTA_SENDER_STAGE_ORDER[i] === stage) {
      return i;
    }
  }
  return -1;
}

/**
 * 判断一次发送阶段切换是否为「向前推进」（纯函数）：
 * 双方都在有序序列内时要求序号不减小；任一方不在序列内（IDLE / 终态 / 取消相关阶段）
 * 视为可自由切换，保证新会话起始与终态收束不受限。
 */
export function isMtaSenderStageForward(current: MtaSenderStage, next: MtaSenderStage): boolean {
  let currentOrder = mtaSenderStageOrder(current);
  let nextOrder = mtaSenderStageOrder(next);
  if (currentOrder < 0 || nextOrder < 0) {
    return true;
  }
  return nextOrder >= currentOrder;
}
