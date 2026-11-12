// ── 枚举类型 ──

import { image } from '@kit.ImageKit';

export enum AutoConfirmMode {
  off = 'off',
  paired = 'paired',
  on = 'on'
}

export enum SendSessionStatus {
  waiting = 'waiting',
  sending = 'sending',
  finished = 'finished',
  finishedWithErrors = 'finishedWithErrors',
  declined = 'declined',
  cancelled = 'cancelled',
  tooManyAttempts = 'tooManyAttempts',
  recipientBusy = 'recipientBusy',
  timeout = 'timeout',
  pinRequired = 'pinRequired'
}

// ── 数据类型 ──

export interface DeviceChannel {
  host: string
  port: number
  protocol: string
}

export interface DiscoveredDevice {
  alias: string
  ip: string
  port: number
  fingerprint: string
  version: string
  deviceModel: string
  deviceType: string
  protocol: string
  lastSeen: number
  channels: Array<DeviceChannel>
  // ── MTA（互传联盟）来源可选字段（仅 protocol === 'mta' 时有效） ──
  // MTA 设备以 BLE 设备标识为唯一键（同时用作 fingerprint），与 LocalSend 指纹互不干扰。
  mtaBleAddress?: string
  mtaSenderIdHex?: string
  mtaBrandId?: number
  mtaBrandName?: string
  mtaIs5Ghz?: boolean
  mtaRssi?: number
}

// ── 网络接口类型 ──

export enum NetworkType {
  wifi = 'wifi',
  cellular = 'cellular',
  ethernet = 'ethernet',
  // 隧道与虚拟组网接口（tun/tap、WireGuard、EasyTier、ZeroTier 等），跨网传输的主要通道
  vpn = 'vpn',
  // 容器网桥接口（anco、docker、veth、br- 等），本机处于网关侧
  bridge = 'bridge',
  unknown = 'unknown'
}

export interface NetworkInterface {
  ip: string
  prefixLength: number
  type: NetworkType
  isDefault: boolean // 是否为默认网络
  name: string // 接口名（如 "wlan0"、"eth0"）
}

export interface LocalDeviceInfo {
  alias: string
  fingerprint: string
  ip: string // 默认 IP
  interfaces: Array<NetworkInterface> // 所有网卡
}

export interface PendingRequestFile {
  fileId: string
  fileName: string
  size: number
  fileType: string
  preview?: string
  sha256?: string
}

export interface PendingRequest {
  sessionId: string
  senderAlias: string
  senderFingerprint: string
  senderProtocol: string
  // 原生 prepare_upload 事件携带的发送方网络身份。
  // 在轮询回退路径上为空（该路径缺少这些字段）；调用方
  // 然后回退到基于发现的查找。
  senderIp: string
  senderDeviceType: string
  senderDeviceModel: string
  // 事件层已自动确认并接收请求时为 true。
  // 传输页仍会路由并自动确认，使用户看到
  // 进度/完成而非静默后台保存。
  autoConfirmed: boolean
  files: Array<PendingRequestFile>
}

export interface TransferProgress {
  sessionId: string
  fileId: string
  bytesSent: number
  totalBytes: number
  filePath: string
}

// ── 传输页展示层类型 ──

// 传输页文件元数据，供渲染文件清单（无需重复查询仓库）。
export interface TransferFileDescriptor {
  fileId: string
  fileName: string
  size: number
  fileType: string
}

export interface SendFileItem {
  fileId: string
  filePath: string
  fileName: string
  fileType: string
  size: number
  preview?: string
  hash?: string
  // 源文件修改时间（Unix 毫秒，可缺省）；用于接收端还原文件时间
  lastModified?: number
}

export interface LogEntry {
  timestamp: number
  level: string
  message: string
}

export interface StagedFile {
  uri: string
  fileName: string
  fileType: string
  isImage: boolean
  isManualText?: boolean
  // 手输文本是否已随某次发送发起（已发起 = 其持久文件不再随暂存列表清理删除）
  persisted?: boolean
  // 源文件修改时间（Unix 毫秒，可缺省）：在暂存副本生成前捕获，
  // 随发送文件 JSON 传递，供接收端还原文件时间
  lastModified?: number
  // 视频缩略图（异步懒加载生成）；未生成/失败时为 undefined（显示类型图标）
  previewPixelMap?: image.PixelMap
}

// ── 相册保存相关类型 ──

export interface MediaFileInfo {
  filePath: string
  fileName: string
  fileType: string
  isImage: boolean
}

export interface GallerySaveResult {
  successCount: number
  failCount: number
  errors: Array<string>
}

// ── 设备收藏与媒体保存类型 ──

export interface FavoriteDevice {
  id: string
  fingerprint: string
  ip: string
  port: number
  alias: string
  customAlias: boolean
  lastProtocol?: string // 上次成功连接的协议 ('http'|'https')；在线被发现同步时刷新并随收藏记录持久化
  // 最近一次从发现同步得到的广播别名：用于「恢复默认别名」。
  // 非空才覆盖；历史收藏记录无该字段时「恢复默认别名」暂不可用，设备上线同步一次后补齐。
  broadcastAlias?: string
  // 以下三项均来自收藏时的发现快照（DiscoveredDevice），随收藏记录持久化，
  // 并在设备在线被发现同步时刷新（非空才覆盖）；用于设备离线后的信息展示。
  deviceModel?: string // 设备型号——离线渲染条目型号徽标与详情页型号的来源
  deviceType?: string // 设备类型——离线渲染设备类型图标的映射来源
  version?: string // LocalSend 协议版本——详情页协议版本号的来源
}

export interface ReceiveHistoryEntry {
  id: string
  fileName: string
  fileType: string
  path: string
  savedToGallery: boolean
  isMessage: boolean
  fileSize: number
  senderAlias: string
  timestamp: number
  textContent?: string
}

export interface SendSessionState {
  sessionId: string
  // 统一会话标识（注册表标识）：本发送会话的进度与终态一律经它归属，
  // 不再按逻辑会话标识做首匹配查找
  unifiedSessionId: string
  targetIp: string
  targetAlias: string
  status: SendSessionStatus
  files: Array<SendFileItem>
  totalFiles: number
  // 接收方返回的会话 id（UUID），用于按接收方会话清除/归属该会话的进度条目。
  // 单目标/多目标发送完成时记录；重新发送到同一设备时据此清除旧会话残留进度。
  receiverSessionId?: string
  // 终态错误消息（finishedWithErrors/其他失败状态），供 UI 显示具体原因而非笼统"错误"。
  errorMessage?: string
}

// ── Web 下载请求确认相关类型 ──
export interface PendingWebDownload {
  sessionId: string
  ip: string
  userAgent?: string
  timestamp: number
}

// ── 路由参数类型（Navigation pushPathByName 参数契约） ──

// VerifyPage 验证参数：本地与远端指纹（经 VerifyPageBuilder 传入）。
export interface VerifyPageParams {
  localFingerprint: string
  remoteFingerprint: string
}
