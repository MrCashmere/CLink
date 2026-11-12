/**
 * MtaProtocolModels.ets — MTA 共享协议层数据类型与纯函数
 *
 * 本文件仅包含数据视图类型、事件回调集合与可单测的纯函数（无系统 API 依赖），
 * 供 MTA 接收端与发送端各服务共用。
 * WS 消息与 P2pInfo/DeviceInfo 的解析函数放在此处，便于设备端测试直接覆盖。
 */

import { MediaFileInfo } from '../Types';
import { readJsonString, readJsonNumber, readJsonField } from '../../utils/JsonGuard';

// ── 接收阶段状态机 ──

/** 接收端阶段（与 MTA 协议状态机对齐，任意阶段失败进入 FAILED 后回到 SERVICE_RUNNING） */
export enum ReceiverStage {
  /** 未启动 */
  IDLE = 'idle',
  /** 广播 + GATT Server 就绪，等待互传设备连接 */
  SERVICE_RUNNING = 'service_running',
  /** 已收到并解密 P2pInfo */
  P2P_INFO_RECEIVED = 'p2p_info_received',
  /** 正在经 p2pConnect 加入发送方群组 */
  P2P_CONNECTING = 'p2p_connecting',
  /** 已加入群组并取得 GO IP */
  P2P_CONNECTED = 'p2p_connected',
  /** 正在建立 WS 连接 */
  WS_CONNECTING = 'ws_connecting',
  /** 版本协商完成 */
  NEGOTIATED = 'negotiated',
  /** 收到 sendRequest，等待用户确认 */
  REQUEST_RECEIVED = 'request_received',
  /** 下载中 */
  DOWNLOADING = 'downloading',
  /** 本次接收完成 */
  COMPLETED = 'completed',
  /** 本次接收失败 */
  FAILED = 'failed'
}

/**
 * 阶段是否为「接收任务进行中」（建链/下载/落盘）。
 * 不含等待用户确认（REQUEST_RECEIVED）与空闲/服务待命/终态阶段——
 * 后台长时任务的申请与保持仅以数据可能流动的阶段为依据。
 */
export function isMtaReceivingStage(stage: ReceiverStage): boolean {
  return stage === ReceiverStage.P2P_INFO_RECEIVED ||
    stage === ReceiverStage.P2P_CONNECTING ||
    stage === ReceiverStage.P2P_CONNECTED ||
    stage === ReceiverStage.WS_CONNECTING ||
    stage === ReceiverStage.NEGOTIATED ||
    stage === ReceiverStage.DOWNLOADING;
}

// ── 接收对外服务复用判定（纯函数：无副作用、不依赖系统 API，可导出单测） ──

/**
 * 接收对外服务的可复用状态快照：一次接收会话收尾时据此判定
 *「复用既有广播/GATT 服务与密钥」还是「完整重建」，避免连续接收的固定重建开销。
 */
export class ReceiveServiceWarmState {
  /** 接收服务是否运行中 */
  running: boolean = false;
  /** 广播是否在运行 */
  advertising: boolean = false;
  /** GATT Server 是否在运行 */
  gattRunning: boolean = false;
  /** 对外身份令牌（昵称 + 模拟品牌，用于判定对外身份是否变化） */
  identityToken: string = '';
}

/** 由设备昵称与模拟品牌标识构造对外身份令牌（纯函数） */
export function buildMtaReceiveIdentityToken(deviceName: string, brandId: number): string {
  return `${deviceName}#${brandId}`;
}

/**
 * 判定接收对外服务是否可直接复用（纯函数）：
 * 服务在运行、广播与 GATT 均在运行、且对外身份令牌与会话开始时一致时才可复用；
 * 任一条件不满足（身份变化、服务已停、子服务缺失）都必须走完整重建。
 */
export function isReceiveServiceReusable(warm: ReceiveServiceWarmState,
  expectedIdentityToken: string): boolean {
  if (!warm.running || !warm.advertising || !warm.gattRunning) {
    return false;
  }
  if (expectedIdentityToken.length === 0 || warm.identityToken.length === 0) {
    return false;
  }
  return warm.identityToken === expectedIdentityToken;
}

// ── 建链阶段耗时诊断（纯函数：无副作用、不依赖系统 API，可导出单测） ──

/** 建链阶段耗时采样：阶段名 + 相对计时起点的毫秒偏移 */
export class MtaLinkTimingSample {
  /** 阶段名 */
  stage: string = '';
  /** 相对计时起点的毫秒偏移 */
  elapsedMs: number = 0;
}

/**
 * 建链阶段耗时记录器（纯数据，无副作用）。
 * 发送侧与接收侧共用同一口径：以用户可感知的起点（发送点击 / 收到对端凭据）为 0，
 * 逐阶段记录相对耗时，供阶段汇总输出与优化前后 A/B 对比。阶段名幂等：同名只记首次，
 * 保证阶段单调、不被迟到的异步事件覆盖。
 */
export class MtaLinkTiming {
  /** 计时起点（毫秒时间戳；0 表示尚未开始） */
  private startMs: number = 0;
  /** 已记录的阶段采样（按记录顺序） */
  private samples: Array<MtaLinkTimingSample> = [];

  /** 开始计时（重置已有采样）；atMs 为用户可感知的起点时刻 */
  begin(atMs: number): void {
    this.startMs = atMs;
    this.samples = [];
  }

  /** 是否已开始计时 */
  isRunning(): boolean {
    return this.startMs > 0;
  }

  /** 记录一个阶段：同名阶段只记首次（幂等），返回本次是否记录 */
  mark(stage: string, atMs: number): boolean {
    if (this.startMs <= 0) {
      return false;
    }
    for (let i = 0; i < this.samples.length; i++) {
      if (this.samples[i].stage === stage) {
        return false;
      }
    }
    let sample = new MtaLinkTimingSample();
    sample.stage = stage;
    sample.elapsedMs = atMs - this.startMs;
    this.samples.push(sample);
    return true;
  }

  /** 起点至 atMs 的总耗时（未开始计时返回 0） */
  totalMs(atMs: number): number {
    return this.startMs > 0 ? atMs - this.startMs : 0;
  }

  /** 汇总为 `阶段=耗时ms` 的稳定文本（按记录顺序；无采样返回空串） */
  summary(): string {
    let parts: Array<string> = [];
    for (let i = 0; i < this.samples.length; i++) {
      parts.push(`${this.samples[i].stage}=${this.samples[i].elapsedMs}ms`);
    }
    return parts.join(' ');
  }
}

// ── WS 握手诊断 ──

/** WS 握手结果 */
export class WsHandshakeResult {
  /** 目标地址（wss://IP:端口/路径） */
  targetUrl: string = '';
  /** 是否握手成功 */
  success: boolean = false;
  /** 总耗时（毫秒） */
  totalMs: number = 0;
  /** 尝试轮数 */
  attemptCount: number = 0;
  /** 结果摘要文本 */
  summary: string = '';
}

/** 由握手结果生成摘要文本（成功与否、总耗时、尝试轮数） */
export function buildWsHandshakeSummary(result: WsHandshakeResult): string {
  let resultText = result.success ? '成功' : '失败';
  return `目标 ${result.targetUrl}：${resultText}，共 ${result.attemptCount} 轮，总耗时 ${result.totalMs}ms`;
}

// ── 协议数据类型 ──

/** DeviceInfo（CHAR_STATUS 读返回） */
export class DeviceInfoJson {
  /** 对端状态：就绪值见 MtaConstants.DEVICE_INFO_STATE，非就绪值表示对端忙 */
  state: number = 0;
  /** 蓝牙 MAC（兜底值） */
  mac: string = '';
  /** Base64(X.509 SPKI DER) ECDH P-256 公钥 */
  key: string = '';
  /** CatShare 版本标识 */
  catShare: number = 0;
  /** 对端忙原因码（0 表示未提供；语义见 MtaConstants.PEER_BUSY_REASON_*） */
  reason: number = 0;
}

/** P2pInfo（CHAR_P2P 写入值） */
export class P2pInfoJson {
  /** 发送者 ID */
  id: string = '';
  /** 加密后 Base64（key 存在时） */
  ssid: string = '';
  /** 加密后 Base64（key 存在时） */
  psk: string = '';
  /** 加密后 Base64（key 存在时） */
  mac: string = '';
  /** 发送方 HTTPS/WS 端口 */
  port: number = 0;
  /** 群组频点（MHz，仅发送侧序列化写入；接收侧不解析该字段） */
  freq: number = 0;
  /** 发送端公钥 Base64（存在即触发解密） */
  key: string = '';
  /** CatShare 版本标识（可选） */
  catShare: number = 0;
  /** 引导网络（1=GATT，2=BLE 直连广播；0 表示不序列化输出） */
  G: number = 0;
  /** 主网络（1=WiFi P2P，2=WiFi AP；0 表示不序列化输出） */
  M: number = 0;
  /** 协议类型（2=MIOV HTTP，3=PC HTTP；0 表示不序列化输出） */
  P: number = 0;

  /**
   * 序列化为 P2pInfo JSON 文本。
   * 连接配置字段（引导网络/主网络/协议类型，G/M/P）仅在非 0 时输出，对齐参考实现
   *（小米互传）发送方的做法；其余既有字段的字段名与输出顺序保持不变，保证对端解析零回归。
   */
  toJsonText(): string {
    let obj: Record<string, Object> = {};
    obj['id'] = this.id;
    obj['ssid'] = this.ssid;
    obj['psk'] = this.psk;
    obj['mac'] = this.mac;
    obj['port'] = this.port;
    obj['freq'] = this.freq;
    obj['key'] = this.key;
    obj['catShare'] = this.catShare;
    if (this.G !== 0) {
      obj['G'] = this.G;
    }
    if (this.M !== 0) {
      obj['M'] = this.M;
    }
    if (this.P !== 0) {
      obj['P'] = this.P;
    }
    return JSON.stringify(obj);
  }
}

/** 解密后的 P2P 凭据 */
export class DecryptedCredentials {
  /** WiFi Direct 组 SSID（注入 p2pConnect 的 groupName） */
  ssid: string = '';
  /** 组密码（注入 p2pConnect 的 passphrase） */
  psk: string = '';
  /** 发送端 p2p0 MAC（仅日志诊断，连接路线不消费） */
  mac: string = '';
}

/** 接收请求（来自 sendRequest） */
export class ReceiveRequest {
  /** 任务 ID（同时用作下载 query 参数） */
  taskId: string = '';
  /** 发送方 ID */
  senderId: string = '';
  /** 发送方名称 */
  senderName: string = '';
  /** 主文件名（展示用） */
  fileName: string = '';
  /** 文件数 */
  fileCount: number = 0;
  /** 总字节数 */
  totalSize: number = 0;
  /** MTA 原生文本内容（来自 sendRequest 的 catShareText，缺省为空串） */
  textContent: string = '';
  /**
   * 发送端提供的缩略图标识（来自 sendRequest 的 `thumbnail`，非空表示可拉取）：
   * 接收端据此经 `/thumbnail?taskId=` 取回预览图。
   */
  thumbnail: string = '';
  /** 缩略图宽（来自 sendRequest 的 `thumbnail_width`，0 表示未提供） */
  thumbnailWidth: number = 0;
  /** 缩略图高（来自 sendRequest 的 `thumbnail_height`，0 表示未提供） */
  thumbnailHeight: number = 0;
}

/**
 * 是否允许把已取回的对端缩略图路径写回当前接收状态。
 *
 * 仅当接收会话仍活跃、且当前状态持有的接收请求正是发起本次拉取的请求时允许写回；
 * 否则（用户已接受/拒绝、会话已复位、或请求已被取代）拒绝，避免过期预览污染会话。
 * 纯函数：无副作用、无外部依赖。
 *
 * @param sessionActive 接收会话是否仍活跃（复位后为否）
 * @param heldRequest 当前状态持有的接收请求（尚未持有为 undefined）
 * @param incoming 发起本次缩略图拉取的接收请求
 */
export function mayWriteRequestThumbnail(sessionActive: boolean,
  heldRequest: ReceiveRequest | undefined, incoming: ReceiveRequest): boolean {
  return sessionActive && heldRequest === incoming;
}

/** 已接收文件条目（展示用：文件名 + 大小） */
export class ReceivedFileEntry {
  /** 文件显示名（不含目录） */
  name: string = '';
  /** 文件字节大小 */
  size: number = 0;
  /** 真实文件类型（按扩展名解析的 MIME；空串表示未解析） */
  fileType: string = '';
}

/** 下载进度 */
export class DownloadProgress {
  /** 已解压字节（有效数据口径，进度分子） */
  receivedBytes: number = 0;
  /** 总字节（未知时为 0；进度分母为接收请求声明的原始总大小） */
  totalBytes: number = 0;
  /** 百分比（0-100，总字节未知时为 0） */
  percent: number = 0;
  /** 网络读入字节累计（网络口径，速率分子；压缩生效时与 receivedBytes 不同） */
  netBytes: number = 0;
  /** 网络数据是否已全部读入（true 表示仍在解压/落盘） */
  networkDone: boolean = false;
}

/** 接收端完整状态（服务持有，向 VM 推送快照） */
export class ReceiverState {
  /** 当前阶段 */
  stage: ReceiverStage = ReceiverStage.IDLE;
  /** 接收服务（广播 + GATT）是否运行 */
  serviceRunning: boolean = false;
  /** 广播子状态 */
  advertisingRunning: boolean = false;
  /** GATT Server 子状态 */
  gattRunning: boolean = false;
  /** 本会话 ECDH 公钥（Base64 SPKI DER） */
  ecdhPublicKey: string = '';
  /** 已连接 GATT 客户端标识 */
  connectedPeerId: string = '';
  /** 解密后的 P2P 凭据 */
  credentials: DecryptedCredentials | undefined = undefined;
  /** GO 网关地址 */
  goIpAddress: string = '';
  /** 发送方服务端口 */
  transferPort: number = 0;
  /** 对端群组实际频点（MHz，0 表示未知/读取失败） */
  groupFrequency: number = 0;
  /** 收到的接收请求 */
  receiveRequest: ReceiveRequest | undefined = undefined;
  /** 本会话已拉取到的发送端缩略图路径（空串表示未提供或未取到），供确认界面预览 */
  requestThumbnailPath: string = '';
  /** 下载进度 */
  progress: DownloadProgress = new DownloadProgress();
  /** 已保存文件完整路径 */
  savedFiles: Array<string> = [];
  /** 本次接收已落盘的文件条目（文件名 + 大小 + 真实类型），保存完成后填充 */
  receivedFiles: Array<ReceivedFileEntry> = [];
  /** 待保存到相册的媒体文件（"保存到相册"开启且有图片/视频时填充） */
  pendingMediaFiles: Array<MediaFileInfo> = [];
  /** 最近一次错误原因 */
  lastError: string = '';

  /** 复制当前状态为独立快照（V2 @Trace 需整体替换才触发刷新） */
  snapshot(): ReceiverState {
    let copy = new ReceiverState();
    copy.stage = this.stage;
    copy.serviceRunning = this.serviceRunning;
    copy.advertisingRunning = this.advertisingRunning;
    copy.gattRunning = this.gattRunning;
    copy.ecdhPublicKey = this.ecdhPublicKey;
    copy.connectedPeerId = this.connectedPeerId;
    copy.credentials = this.credentials;
    copy.goIpAddress = this.goIpAddress;
    copy.transferPort = this.transferPort;
    copy.groupFrequency = this.groupFrequency;
    copy.receiveRequest = this.receiveRequest;
    copy.requestThumbnailPath = this.requestThumbnailPath;
    copy.progress = this.progress;
    copy.savedFiles = this.savedFiles.slice();
    copy.receivedFiles = this.receivedFiles.slice();
    copy.pendingMediaFiles = this.pendingMediaFiles.slice();
    copy.lastError = this.lastError;
    return copy;
  }
}

// ── 事件回调集合 ──

/** MtaBleReceiver → 服务 事件回调 */
export class MtaBleEventHandlers {
  /** 蓝牙开关状态变化 */
  onBluetoothStateChange: (stateText: string) => void = (stateText: string): void => {
  };
  /** 广播状态变化 */
  onAdvertiseStateChange: (running: boolean, detail: string) => void = (running: boolean, detail: string): void => {
  };
  /** GATT 客户端连接状态变化 */
  onGattConnectionChange: (clientDeviceId: string, stateText: string) => void =
    (clientDeviceId: string, stateText: string): void => {
    };
  /** 收到读请求 */
  onGattReadRequest: (clientDeviceId: string, offset: number) => void =
    (clientDeviceId: string, offset: number): void => {
    };
  /** 写分片进度 */
  onGattWriteProgress: (deviceId: string, offset: number, totalLength: number, isPrepared: boolean) => void =
    (deviceId: string, offset: number, totalLength: number, isPrepared: boolean): void => {
    };
  /** 完整收到 P2pInfo 原始 JSON 文本 */
  onP2pInfoReceived: (deviceId: string, payloadText: string) => void =
    (deviceId: string, payloadText: string): void => {
    };
}

/** MtaP2pConnector → 服务 事件回调 */
export class MtaP2pEventHandlers {
  /** P2P 连接状态变化摘要（p2pConnectionChange，连接成功的主确认信号） */
  onP2pConnectionChange: (summary: string) => void = (summary: string): void => {
  };
  /** P2P 总开关状态变化（p2pStateChange） */
  onP2pStateChange: (stateText: string) => void = (stateText: string): void => {
  };
  /** 取得 GO IP */
  onGoIp: (goIp: string) => void = (goIp: string): void => {
  };
  /** 读取到对端群组实际频点（MHz，0 表示未知/读取失败） */
  onGroupFrequency: (freqMhz: number) => void = (freqMhz: number): void => {
  };
}

/** MtaTransferClient → 服务 事件回调 */
export class MtaTransferEventHandlers {
  /** WS 打开 */
  onWsOpen: () => void = (): void => {
  };
  /** 版本协商完成 */
  onVersionNegotiated: (version: number) => void = (version: number): void => {
  };
  /** 收到接收请求 */
  onReceiveRequest: (request: ReceiveRequest) => void = (request: ReceiveRequest): void => {
  };
  /** WS 关闭 */
  onWsClosed: (reason: string) => void = (reason: string): void => {
  };
  /** 下载进度 */
  onProgress: (progress: DownloadProgress) => void = (progress: DownloadProgress): void => {
  };
  /** 错误上报 */
  onError: (source: string, message: string) => void = (source: string, message: string): void => {
  };
}

/** MtaReceiveService → ViewModel 事件回调 */
export class MtaReceiveEventHandlers {
  /** 状态快照变化 */
  onStateChange: (state: ReceiverState) => void = (state: ReceiverState): void => {
  };
}

// JSON 动态取值统一走 JsonGuard（本文件不再保留私守卫）
/** 按协议容错规则从原始文本提取 JSON：首个 `{` 到最后一个 `}`，无匹配则原样返回 */
export function extractJsonText(raw: string): string {
  let start = raw.indexOf('{');
  let end = raw.lastIndexOf('}');
  if (start >= 0 && end > start) {
    return raw.substring(start, end + 1);
  }
  return raw;
}

/** 解析 DeviceInfo JSON，失败返回 undefined */
export function parseDeviceInfo(raw: string): DeviceInfoJson | undefined {
  try {
    let obj: Object = JSON.parse(raw);
    let info = new DeviceInfoJson();
    info.state = readJsonNumber(obj, 'state', 0);
    info.mac = readJsonString(obj, 'mac', '');
    info.key = readJsonString(obj, 'key', '');
    info.catShare = readJsonNumber(obj, 'catShare', 0);
    // 对端忙原因码：缺失或类型不符取默认 0，与其余字段同等容错
    info.reason = readJsonNumber(obj, 'reason', 0);
    return info;
  } catch (e) {
    return undefined;
  }
}

/** 解析 P2pInfo JSON（容错提取 `{}`），失败返回 undefined */
export function parseP2pInfo(raw: string): P2pInfoJson | undefined {
  try {
    let text = extractJsonText(raw);
    let obj: Object = JSON.parse(text);
    let info = new P2pInfoJson();
    info.id = readJsonString(obj, 'id', '');
    info.ssid = readJsonString(obj, 'ssid', '');
    info.psk = readJsonString(obj, 'psk', '');
    info.mac = readJsonString(obj, 'mac', '');
    info.port = readJsonNumber(obj, 'port', 0);
    info.key = readJsonString(obj, 'key', '');
    info.catShare = readJsonNumber(obj, 'catShare', 0);
    return info;
  } catch (e) {
    return undefined;
  }
}

/**
 * 按 UTF-8 字节上限截断文本，超限时在边界字符前截断（不切断代理对）。
 * 未超限返回原文本。
 */
export function truncateUtf8Text(text: string, maxBytes: number): string {
  let bytes = 0;
  let i = 0;
  while (i < text.length) {
    let code = text.charCodeAt(i);
    let size = 1;
    // 本次消耗的字符数：代理对占 2，其余占 1
    let chars = 1;
    if (code < 0x80) {
      size = 1;
    } else if (code < 0x800) {
      size = 2;
    } else if (code >= 0xd800 && code <= 0xdbff) {
      // 高代理项：与其低代理项合占 4 字节，整体计费并一并跨过两个字符，
      // 避免代理对被拆开计费或在中间截断
      size = 4;
      chars = 2;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      // 孤立低代理项按 3 字节计（正常文本不会出现）
      size = 3;
    } else {
      size = 3;
    }
    // 必须先判超限、通过后再前进索引：超限时 i 仍指向本字符（含代理对的高位）之前，
    // 据此截断不会切出半对代理；若在判定前就前进索引，超限返回时会把高位代理项切出来，
    // 产出孤立代理项（非法字符）
    if (bytes + size > maxBytes) {
      return text.substring(0, i);
    }
    bytes += size;
    i += chars;
  }
  return text;
}

/**
 * 校验版本协商 payload 是否包含本机支持的协议版本。
 * 宽松策略：payload 为空、解析失败或未携带版本字段均视为支持；
 * 携带 versions 数组时检查是否含 supported，否则检查 version 是否等于 supported。
 */
export function isVersionNegotiationSupported(payload: string, supported: number): boolean {
  if (payload.length === 0) {
    return true;
  }
  let obj: Record<string, Object>;
  try {
    obj = JSON.parse(payload);
  } catch (e) {
    return true;
  }
  let versionsVal: Object | undefined = readJsonField(obj, 'versions');
  if (Array.isArray(versionsVal)) {
    let versions = versionsVal as Object[];
    for (let i = 0; i < versions.length; i++) {
      if (versions[i] === supported) {
        return true;
      }
    }
    return false;
  }
  let versionVal: Object | undefined = readJsonField(obj, 'version');
  if (typeof versionVal === 'number') {
    return versionVal === supported;
  }
  return true;
}

/** 解析 sendRequest payload，失败返回 undefined */
export function parseSendRequestPayload(payloadJson: string): ReceiveRequest | undefined {
  try {
    let obj: Object = JSON.parse(payloadJson);
    let request = new ReceiveRequest();
    // MTA 约定任务 ID 同时写入 taskId/id：优先取 taskId，缺失时回退 id（部分实现仅写 id）
    request.taskId = readJsonString(obj, 'taskId', '');
    if (request.taskId.length === 0) {
      request.taskId = readJsonString(obj, 'id', '');
    }
    request.senderId = readJsonString(obj, 'senderId', '');
    request.senderName = readJsonString(obj, 'senderName', '');
    request.fileName = readJsonString(obj, 'fileName', '');
    request.fileCount = readJsonNumber(obj, 'fileCount', 0);
    request.totalSize = readJsonNumber(obj, 'totalSize', 0);
    // MTA 原生文本：catShareText 缺省时为空串
    request.textContent = readJsonString(obj, 'catShareText', '');
    // 缩略图（可选字段，命名与对端实现一致）：非空表示发送端提供预览图
    request.thumbnail = readJsonString(obj, 'thumbnail', '');
    request.thumbnailWidth = readJsonNumber(obj, 'thumbnail_width', 0);
    request.thumbnailHeight = readJsonNumber(obj, 'thumbnail_height', 0);
    return request;
  } catch (e) {
    return undefined;
  }
}

// ── WS 应用层消息 ──

/** WS 消息（type:id:name?json_payload） */
export class WsMessage {
  /** 消息类型：action / ack */
  type: string = '';
  /** 消息 ID */
  id: number = 0;
  /** 消息名：versionNegotiation / sendRequest / status */
  name: string = '';
  /** 可选 JSON payload */
  payload: string = '';
}

/** 解析 `type:id:name?json_payload`，格式非法返回 undefined */
export function parseWsMessage(raw: string): WsMessage | undefined {
  let pattern = new RegExp('^(\\w+):(\\d+):(\\w+)(\\?(.*))?$');
  let match = pattern.exec(raw);
  if (match === null) {
    return undefined;
  }
  let message = new WsMessage();
  message.type = match[1];
  message.id = parseInt(match[2], 10);
  message.name = match[3];
  message.payload = match[5] !== undefined ? match[5] : '';
  return message;
}

/** 构造 `type:id:name?json_payload` 消息文本（payload 为空时省略 `?`） */
export function buildWsMessage(type: string, id: number, name: string, payloadJson: string): string {
  if (payloadJson.length > 0) {
    return `${type}:${id}:${name}?${payloadJson}`;
  }
  return `${type}:${id}:${name}`;
}

/** 接收端 status 回执的 JSON 形状（MTA 约定携带 taskId/type/reason） */
interface MtaStatusPayload {
  /** 任务 ID */
  taskId: string;

  /** 状态类型：1 成功 / 3 拒绝 */
  type: number;

  /** 状态原因 */
  reason: string;

  /** 任务 ID（与 taskId 同值；部分厂商（如小米）按 id 关联任务，缺失会直接判本次接收失败） */
  id: string;
}

/**
 * 构造接收端 status 回执 payload（对 taskId/reason 做 JSON 转义，避免特殊字符破坏报文）。
 * 同时携带 `taskId` 与 `id`（同值）：参考实现（CatShare/EasyShare）两者都写，
 * 部分厂商（如小米）按 `id` 关联任务，缺失会直接判本次接收失败。
 */
export function buildStatusPayload(taskId: string, type: number, reason: string): string {
  let payload: MtaStatusPayload = { taskId: taskId, id: taskId, type: type, reason: reason };
  return JSON.stringify(payload);
}

// ── 字节辅助 ──

/** 字节数组转小写十六进制字符串 */
export function bytesToHex(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    let h = bytes[i].toString(16);
    out += h.length === 1 ? '0' + h : h;
  }
  return out;
}
