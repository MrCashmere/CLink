import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:NativeTypes', 'Native 类型');

export interface NativeFileToSend {
  fileId: string
  filePath: string
  fileName: string
  fileType: string
  size: number
  // 文件内容源描述符；-1 或缺省表示无 fd，回退按 filePath 指向的沙箱路径读取。
  // 所有权随调用场景：sendToDevice 返回后 fd 归 Rust 消费并关闭；
  // createShareLink 后原始 fd 归 ArkTS 持有并关闭，Rust 每次下载仅 dup 副本
  fd?: number
  preview?: string
  sha256?: string
  // 发送方源文件修改时间（Unix 毫秒，可缺省）；Rust 桥接层据其填充上传 DTO 的
  // metadata.modified（RFC 3339），接收端落盘后应用。
  lastModified?: number
}

export interface NativeHttpError {
  kind: string
  status?: number
  message?: string
}

export interface NativeSendResult {
  sessionId: string
  success: boolean
  failedFiles: Array<string>
  error?: NativeHttpError
}

export interface NativeServerConfig {
  alias: string
  deviceModel: string
  deviceType: string
  port: number
  saveDir: string
  useHttps: boolean
  verifyChecksums?: boolean
  pin?: string
  maxConcurrent?: number
  showToken?: string
}

export interface NativeServerHandle {
  fingerprint: string
  port: number
}

export interface NativeServerStatus {
  running: boolean
  activeSession?: string
  fingerprint?: string
}

export interface NativeTargetDevice {
  ip: string
  port: number
  fingerprint: string
  protocol: string
  // 接收方要求 PIN 验证时携带（发送 prepare-upload 时作为 query 参数）
  pin?: string
}

export interface NativeTransferFileInfo {
  fileId: string
  fileName: string
  size: number
  fileType: string
  preview?: string
  sha256?: string
}

export interface NativeTransferRequest {
  sessionId: string
  senderAlias: string
  senderFingerprint: string
  senderProtocol: string
  files: Array<NativeTransferFileInfo>
}

export interface NativeShareLinkInfo {
  url: string
  port: number
  sessionId: string
}

export interface NativeCancelTarget {
  ip: string
  port: number
  fingerprint: string
  protocol: string
}

// ── MTA 发送端服务器配置 ──

/** MTA 待发送文件条目 */
export interface NativeMtaFileEntry {
  /** 读取回退路径（fdSend 缺省或 -1 时使用；文本条目等无 fd 场景必须提供） */
  path: string
  /** ZIP 条目名（"{序号}/{显示文件名}"） */
  entryName: string
  /** 源文件修改时间（Unix 毫秒，可选）；用于写入 ZIP 条目时间 */
  lastModifiedMs?: number
  /** 源文件大小（字节，取自源 URI statSync）；供进度分母、条目大小一致性校验与 ZIP64 判定 */
  sizeBytes: number
  /** 下载发送读取源 fd；缺省 -1 = 不使用 fd、按 path 回退读取 */
  fdSend?: number
}

/** MTA 服务器启动配置 */
export interface NativeMtaServerConfig {
  /** 绑定地址（失败回退 0.0.0.0） */
  bindIp: string
  /** 端口（0 = 系统随机分配） */
  port: number
  /** 任务 ID */
  taskId: string
  /** 发送方 ID */
  senderId: string
  /** 发送方名称 */
  senderName: string
  /** 待发送文件清单 */
  files: Array<NativeMtaFileEntry>
  /** sendRequest 顶层 MIME（可选；三档口径聚合结果，缺省回退 application/zip） */
  mimeType?: string
  /** 发送侧预览缩略图源路径（可选；Rust 起服时读取一次） */
  thumbnailPath?: string
  /** 缩略图宽度（可选，与 thumbnailPath 同时提供） */
  thumbnailWidth?: number
  /** 缩略图高度（可选，与 thumbnailPath 同时提供） */
  thumbnailHeight?: number
  /** MTA 原生文本内容（可选） */
  textContent?: string
  /** 模拟品牌标识（可选） */
  senderBrandId?: number
  /** 模拟品牌名称（可选） */
  senderBrand?: string
}

// ── 安全上下文（TLS 证书身份） ──

export interface NativeSecurityContext {
  privateKey: string
  publicKey: string
  certificate: string
  certificateHash: string
}

// ── 发现类型 ──

export interface NativeDiscoveryConfig {
  port: number
  protocol: string
  multicastGroup: string
  networkWhitelist?: Array<string>
  networkBlacklist?: Array<string>
  discoveryTimeoutMs: number
  download: boolean
}

export interface NativeDiscoveredDevice {
  alias: string
  fingerprint: string
  version: string
  // Rust DeviceDto 的 device_model/device_type 为 Option<String>（对端广播
  // 不带型号/类型时为 None，serde 序列化为 JSON null），解析时归一为 undefined
  deviceModel?: string
  deviceType?: string
  download: boolean
  host: string
  port: number
  protocol: string
  channels: Array<NativeDeviceChannel>
}

export interface NativeDeviceChannel {
  host: string
  port: number
  protocol: string
}

// ── 发送方信息（Register/PrepareUpload 事件） ──

export interface NativeRegisterInfo {
  alias: string
  version: string
  deviceModel?: string
  deviceType?: string
  fingerprint: string
  download: boolean
  port: number
  protocol: string
}

// ── 桥接层事件类型（匹配 Rust BridgeEvent，camelCase type） ──
// NativeBridge 解析 Rust 事件 JSON（{"type": "...", "payload": {...}}）后
// 将 payload 展平到顶层，按 type 分发给订阅者。

export interface NativeServerStartedEvent {
  type: 'serverStarted'
  port: number
}

export interface NativeServerStoppedEvent {
  type: 'serverStopped'
}

export interface NativeRegisterEvent {
  type: 'register'
  ip: string
  info: NativeRegisterInfo
}

export interface NativePrepareUploadEvent {
  type: 'prepareUpload'
  sessionId: string
  senderIp: string
  senderAlias: string
  senderFingerprint: string
  senderDeviceType: string
  senderDeviceModel: string
  certFingerprint: string
  files: Array<NativeTransferFileInfo>
}

export interface NativePrepareUploadAbortedEvent {
  type: 'prepareUploadAborted'
  sessionId: string
}

export interface NativeCancelReceivedEvent {
  type: 'cancelReceived'
  ip: string
  sessionId: string
}

export interface NativeProgressEvent {
  type: 'uploadProgress'
  sessionId: string
  fileId: string
  direction: string
  progress: number
  speed: number
}

export interface NativeSessionEndEvent {
  type: 'sessionEnd'
  sessionId: string
  reason: string
}

export interface NativeFileUploadEvent {
  type: 'fileUpload'
  sessionId: string
  fileId: string
  fileName: string
  size: number
}

// 校验和计算进度：携带取消令牌 id 与该文件累计已哈希字节（分母由文件大小提供）
export interface NativeChecksumProgressEvent {
  type: 'checksumProgress'
  cancelId: string
  hashedBytes: number
}

export interface NativeDeviceFoundEvent {
  type: 'deviceFound'
  device: NativeDiscoveredDevice
}

export interface NativeDeviceLostEvent {
  type: 'deviceLost'
  fingerprint: string
}

export interface NativeWebSendPrepareDownloadEvent {
  type: 'webSendPrepareDownload'
  sessionId: string
  ip: string
  userAgent?: string
}

export interface NativeWebSendFileDownloadEvent {
  type: 'webSendFileDownload'
  sessionId: string
  fileId: string
  fileName: string
  size: number
}

// Web 下载进度：由 Rust 桥接层在 fd 流式读取处按节流发射
export interface NativeWebSendProgressEvent {
  type: 'webSendProgress'
  sessionId: string
  fileId: string
  sentBytes: number
  totalBytes: number
}

export interface NativeWebSendSessionEndEvent {
  type: 'webSendSessionEnd'
  sessionId: string
}

export interface NativeErrorEvent {
  type: 'error'
  context: string
  message: string
}

// ── MTA 发送端服务器事件（匹配 Rust BridgeEvent Mta*） ──

export interface NativeMtaServerStartedEvent {
  type: 'mtaServerStarted'
  port: number
}

export interface NativeMtaWsConnectedEvent {
  type: 'mtaWsConnected'
}

export interface NativeMtaVersionNegotiatedEvent {
  type: 'mtaVersionNegotiated'
  version: number
}

export interface NativeMtaSendRequestSentEvent {
  type: 'mtaSendRequestSent'
  taskId: string
}

/** 本地取消时已向对端回送取消状态（视为「已通知对端」） */
export interface NativeMtaRejectSentEvent {
  type: 'mtaRejectSent'
  taskId: string
}

export interface NativeMtaDownloadStartedEvent {
  type: 'mtaDownloadStarted'
  taskId: string
}

export interface NativeMtaSendProgressEvent {
  type: 'mtaSendProgress'
  sentBytes: number
  totalBytes: number
  percent: number
  /** 出网字节累计（网络口径，用于速率） */
  networkBytes: number
}

export interface NativeMtaSendCompletedEvent {
  type: 'mtaSendCompleted'
  taskId: string
}

export interface NativeMtaSendPartialEvent {
  type: 'mtaSendPartial'
  reason: string
}

export interface NativeMtaSendRejectedEvent {
  type: 'mtaSendRejected'
  reason: string
}

export interface NativeMtaSendFailedEvent {
  type: 'mtaSendFailed'
  reason: string
}

export interface NativeMtaReceiveProgressEvent {
  type: 'mtaReceiveProgress'
  taskId: string
  receivedBytes: number
  totalBytes: number
  percent: number
  /** 网络读入字节累计（网络口径，用于速率） */
  networkBytes: number
  /** 网络数据是否已全部读入（true 表示仍在解压/落盘） */
  networkDone: boolean
}

// ── 所有桥接层事件的联合 ──

export type NativeEvent =
  NativeServerStartedEvent |
  NativeServerStoppedEvent |
  NativeRegisterEvent |
  NativePrepareUploadEvent |
  NativePrepareUploadAbortedEvent |
  NativeCancelReceivedEvent |
  NativeProgressEvent |
  NativeSessionEndEvent |
  NativeFileUploadEvent |
  NativeChecksumProgressEvent |
  NativeDeviceFoundEvent |
  NativeDeviceLostEvent |
  NativeWebSendPrepareDownloadEvent |
  NativeWebSendFileDownloadEvent |
  NativeWebSendProgressEvent |
  NativeWebSendSessionEndEvent |
  NativeMtaServerStartedEvent |
  NativeMtaWsConnectedEvent |
  NativeMtaVersionNegotiatedEvent |
  NativeMtaSendRequestSentEvent |
  NativeMtaRejectSentEvent |
  NativeMtaDownloadStartedEvent |
  NativeMtaSendProgressEvent |
  NativeMtaSendCompletedEvent |
  NativeMtaSendPartialEvent |
  NativeMtaSendRejectedEvent |
  NativeMtaSendFailedEvent |
  NativeMtaReceiveProgressEvent |
  NativeErrorEvent;

/**
 * 各事件类型的必需字段表。payload 来自 Rust 桥接层序列化，正常情况字段必然存在；
 * 缺失说明两侧结构漂移（如 Rust 端改名/漏字段），此时丢弃事件并记日志，
 * 避免 undefined 字段静默注入下游（会话匹配失败、进度 NaN 等）且无从排查。
 */
const REQUIRED_EVENT_FIELDS: Record<string, Array<string>> = {
  'serverStarted': ['port'],
  'register': ['ip'],
  'prepareUpload': ['sessionId', 'senderIp', 'senderAlias', 'senderFingerprint', 'files'],
  'prepareUploadAborted': ['sessionId'],
  'cancelReceived': ['ip', 'sessionId'],
  'uploadProgress': ['sessionId', 'fileId', 'direction', 'progress', 'speed'],
  'sessionEnd': ['sessionId', 'reason'],
  'fileUpload': ['sessionId', 'fileId', 'fileName', 'size'],
  'checksumProgress': ['cancelId', 'hashedBytes'],
  'deviceFound': ['device'],
  'deviceLost': ['fingerprint'],
  'webSendPrepareDownload': ['sessionId', 'ip'],
  'webSendFileDownload': ['sessionId', 'fileId', 'fileName', 'size'],
  'webSendProgress': ['sessionId', 'fileId', 'sentBytes', 'totalBytes'],
  'webSendSessionEnd': ['sessionId'],
  'mtaServerStarted': ['port'],
  'mtaVersionNegotiated': ['version'],
  'mtaSendRequestSent': ['taskId'],
  'mtaRejectSent': ['taskId'],
  'mtaDownloadStarted': ['taskId'],
  'mtaSendProgress': ['sentBytes', 'totalBytes', 'percent', 'networkBytes'],
  'mtaSendCompleted': ['taskId'],
  'mtaSendPartial': ['reason'],
  'mtaSendRejected': ['reason'],
  'mtaSendFailed': ['reason'],
  'mtaReceiveProgress': ['taskId', 'receivedBytes', 'totalBytes', 'percent', 'networkBytes', 'networkDone'],
  'error': ['context', 'message']
};

/**
 * 解析 Rust 桥接层事件 JSON（{"type":"...","payload":{...}}）。
 * 将 payload 展平到顶层，返回类型化事件；解析失败或必需字段缺失返回 undefined。
 */
export function parseNativeEvent(json: string): NativeEvent | undefined {
  let obj: Record<string, Object> = {};
  try {
    obj = JSON.parse(json) as Record<string, Object>;
  } catch (_e) {
    return undefined;
  }
  let t: string = '';
  if (obj['type'] !== undefined) {
    t = obj['type'] as string;
  }
  let payload: Record<string, Object> = {};
  if (obj['payload'] !== undefined && obj['payload'] !== null) {
    payload = obj['payload'] as Record<string, Object>;
  }
  let required: Array<string> | undefined = REQUIRED_EVENT_FIELDS[t];
  if (required !== undefined) {
    for (let i = 0; i < required.length; i++) {
      let v: Object | undefined = payload[required[i]];
      if (v === undefined || v === null) {
        logger.warn('事件 ' + t + ' 缺少必需字段 "' + required[i] + '"，已丢弃');
        return undefined;
      }
    }
  }
  switch (t) {
    case 'serverStarted':
      return { type: 'serverStarted', port: payload['port'] as number } as NativeServerStartedEvent;
    case 'serverStopped':
      return { type: 'serverStopped' } as NativeServerStoppedEvent;
    case 'register':
      return {
        type: 'register',
        ip: payload['ip'] as string,
        info: parseRegisterInfo(payload['info'] as Record<string, Object> | undefined)
      } as NativeRegisterEvent;
    case 'prepareUpload':
      return parsePrepareUploadEvent(payload);
    case 'prepareUploadAborted':
      return { type: 'prepareUploadAborted', sessionId: payload['sessionId'] as string } as
        NativePrepareUploadAbortedEvent;
    case 'cancelReceived':
      return { type: 'cancelReceived', ip: payload['ip'] as string, sessionId: payload['sessionId'] as string } as
        NativeCancelReceivedEvent;
    case 'uploadProgress':
      return {
        type: 'uploadProgress',
        sessionId: payload['sessionId'] as string,
        fileId: payload['fileId'] as string,
        direction: payload['direction'] as string,
        progress: payload['progress'] as number,
        speed: payload['speed'] as number
      } as NativeProgressEvent;
    case 'sessionEnd':
      return { type: 'sessionEnd', sessionId: payload['sessionId'] as string, reason: payload['reason'] as string } as
        NativeSessionEndEvent;
    case 'fileUpload':
      // Rust 序列化 fileName/size 在 payload 顶层（与 webSendFileDownload 一致）
      return {
        type: 'fileUpload',
        sessionId: payload['sessionId'] as string,
        fileId: payload['fileId'] as string,
        fileName: payload['fileName'] as string,
        size: payload['size'] as number
      } as NativeFileUploadEvent;
    case 'checksumProgress':
      return {
        type: 'checksumProgress',
        cancelId: payload['cancelId'] as string,
        hashedBytes: payload['hashedBytes'] as number
      } as NativeChecksumProgressEvent;
    case 'deviceFound':
      return {
        type: 'deviceFound',
        device: parseDiscoveredDevice(payload['device'] as Record<string, Object> | undefined)
      } as NativeDeviceFoundEvent;
    case 'deviceLost':
      return { type: 'deviceLost', fingerprint: payload['fingerprint'] as string } as NativeDeviceLostEvent;
    case 'webSendPrepareDownload':
      return {
        type: 'webSendPrepareDownload',
        sessionId: payload['sessionId'] as string,
        ip: payload['ip'] as string,
        userAgent: payload['userAgent'] as string | undefined
      } as NativeWebSendPrepareDownloadEvent;
    case 'webSendFileDownload':
      return {
        type: 'webSendFileDownload',
        sessionId: payload['sessionId'] as string,
        fileId: payload['fileId'] as string,
        fileName: payload['fileName'] as string,
        size: payload['size'] as number
      } as NativeWebSendFileDownloadEvent;
    case 'webSendProgress':
      return {
        type: 'webSendProgress',
        sessionId: payload['sessionId'] as string,
        fileId: payload['fileId'] as string,
        sentBytes: payload['sentBytes'] as number,
        totalBytes: payload['totalBytes'] as number
      } as NativeWebSendProgressEvent;
    case 'webSendSessionEnd':
      return { type: 'webSendSessionEnd', sessionId: payload['sessionId'] as string } as NativeWebSendSessionEndEvent;
    case 'mtaServerStarted':
      return { type: 'mtaServerStarted', port: payload['port'] as number } as NativeMtaServerStartedEvent;
    case 'mtaWsConnected':
      return { type: 'mtaWsConnected' } as NativeMtaWsConnectedEvent;
    case 'mtaVersionNegotiated':
      return { type: 'mtaVersionNegotiated', version: payload['version'] as number } as NativeMtaVersionNegotiatedEvent;
    case 'mtaSendRequestSent':
      return { type: 'mtaSendRequestSent', taskId: payload['taskId'] as string } as NativeMtaSendRequestSentEvent;
    case 'mtaRejectSent':
      return { type: 'mtaRejectSent', taskId: payload['taskId'] as string } as NativeMtaRejectSentEvent;
    case 'mtaDownloadStarted':
      return { type: 'mtaDownloadStarted', taskId: payload['taskId'] as string } as NativeMtaDownloadStartedEvent;
    case 'mtaSendProgress':
      return {
        type: 'mtaSendProgress',
        sentBytes: payload['sentBytes'] as number,
        totalBytes: payload['totalBytes'] as number,
        percent: payload['percent'] as number,
        networkBytes: payload['networkBytes'] as number
      } as NativeMtaSendProgressEvent;
    case 'mtaSendCompleted':
      return { type: 'mtaSendCompleted', taskId: payload['taskId'] as string } as NativeMtaSendCompletedEvent;
    case 'mtaSendPartial':
      return { type: 'mtaSendPartial', reason: payload['reason'] as string } as NativeMtaSendPartialEvent;
    case 'mtaSendRejected':
      return { type: 'mtaSendRejected', reason: payload['reason'] as string } as NativeMtaSendRejectedEvent;
    case 'mtaSendFailed':
      return { type: 'mtaSendFailed', reason: payload['reason'] as string } as NativeMtaSendFailedEvent;
    case 'mtaReceiveProgress':
      return {
        type: 'mtaReceiveProgress',
        taskId: payload['taskId'] as string,
        receivedBytes: payload['receivedBytes'] as number,
        totalBytes: payload['totalBytes'] as number,
        percent: payload['percent'] as number,
        networkBytes: payload['networkBytes'] as number,
        networkDone: payload['networkDone'] as boolean
      } as NativeMtaReceiveProgressEvent;
    case 'error':
      return {
        type: 'error',
        context: payload['context'] as string,
        message: payload['message'] as string
      } as NativeErrorEvent;
    default:
      return undefined;
  }
}

// 解析 deviceFound 事件 / 发现快照查询中的设备对象。
// deviceModel/deviceType 的 JSON null 归一为 undefined（与 parseRegisterInfo 一致），
// 防止下游「!== undefined && .length」判断被 null 穿透。
export function parseDiscoveredDevice(obj: Record<string, Object> | undefined): NativeDiscoveredDevice {
  if (obj === undefined || obj === null) {
    return {
      alias: '',
      fingerprint: '',
      version: '',
      download: false,
      host: '',
      port: 0,
      protocol: '',
      channels: []
    } as NativeDiscoveredDevice;
  }
  return {
    alias: obj['alias'] as string,
    fingerprint: obj['fingerprint'] as string,
    version: obj['version'] as string,
    deviceModel: (obj['deviceModel'] !== undefined && obj['deviceModel'] !== null) ? obj['deviceModel'] as string :
      undefined,
    deviceType: (obj['deviceType'] !== undefined && obj['deviceType'] !== null) ? obj['deviceType'] as string :
      undefined,
    download: (obj['download'] !== undefined && obj['download'] !== null) ? obj['download'] as boolean : false,
    host: obj['host'] as string,
    port: (obj['port'] !== undefined && obj['port'] !== null) ? obj['port'] as number : 0,
    protocol: obj['protocol'] as string,
    channels: (obj['channels'] !== undefined && obj['channels'] !== null) ?
      obj['channels'] as Array<NativeDeviceChannel> : []
  } as NativeDiscoveredDevice;
}

function parseRegisterInfo(obj: Record<string, Object> | undefined): NativeRegisterInfo {
  if (obj === undefined || obj === null) {
    return {
      alias: '',
      version: '',
      fingerprint: '',
      download: false,
      port: 0,
      protocol: 'https'
    } as NativeRegisterInfo;
  }
  return {
    alias: (obj['alias'] !== undefined && obj['alias'] !== null) ? obj['alias'] as string : '',
    version: (obj['version'] !== undefined && obj['version'] !== null) ? obj['version'] as string : '',
    deviceModel: (obj['deviceModel'] !== undefined && obj['deviceModel'] !== null) ? obj['deviceModel'] as string :
      undefined,
    deviceType: (obj['deviceType'] !== undefined && obj['deviceType'] !== null) ? obj['deviceType'] as string :
      undefined,
    fingerprint: (obj['fingerprint'] !== undefined && obj['fingerprint'] !== null) ? obj['fingerprint'] as string : '',
    download: (obj['download'] !== undefined && obj['download'] !== null) ? obj['download'] as boolean : false,
    port: (obj['port'] !== undefined && obj['port'] !== null) ? obj['port'] as number : 0,
    protocol: (obj['protocol'] !== undefined && obj['protocol'] !== null) ? obj['protocol'] as string : 'https',
  } as NativeRegisterInfo;
}

function parseTransferFileInfo(obj: Record<string, Object> | undefined): NativeTransferFileInfo {
  if (obj === undefined) {
    return {
      fileId: '',
      fileName: '',
      size: 0,
      fileType: ''
    } as NativeTransferFileInfo;
  }
  return {
    fileId: obj['id'] as string,
    fileName: obj['fileName'] as string,
    size: obj['size'] as number,
    fileType: obj['fileType'] as string,
    // Rust Option::None 经 serde 序列化为 JSON null，须归一为 undefined：
    // 下游判断普遍为「!== undefined && .length > 0」，null 会穿透并触发
    // 「Cannot read property length of null」（文件选择器选取的 txt 不带 preview）
    preview: (obj['preview'] !== undefined && obj['preview'] !== null) ? obj['preview'] as string : undefined,
    sha256: (obj['sha256'] !== undefined && obj['sha256'] !== null) ? obj['sha256'] as string : undefined,
  } as NativeTransferFileInfo;
}

function parsePrepareUploadEvent(payload: Record<string, Object>): NativePrepareUploadEvent {
  let filesRaw: Object | undefined = payload['files'];
  let files: Array<NativeTransferFileInfo> = [];
  if (filesRaw !== undefined && Array.isArray(filesRaw)) {
    let arr = filesRaw as Array<Record<string, Object>>;
    for (let i = 0; i < arr.length; i++) {
      files.push(parseTransferFileInfo(arr[i]));
    }
  }
  return {
    type: 'prepareUpload',
    sessionId: payload['sessionId'] as string,
    senderIp: payload['senderIp'] as string,
    senderAlias: payload['senderAlias'] as string,
    senderFingerprint: payload['senderFingerprint'] as string,
    senderDeviceType: payload['senderDeviceType'] !== undefined ? payload['senderDeviceType'] as string : '',
    senderDeviceModel: payload['senderDeviceModel'] !== undefined ? payload['senderDeviceModel'] as string : '',
    certFingerprint: payload['certFingerprint'] !== undefined && payload['certFingerprint'] !== null ?
      payload['certFingerprint'] as string : '',
    files: files,
  } as NativePrepareUploadEvent;
}

// ── CancellationToken ──

export interface NativeCancellationToken {
  id: string
}
