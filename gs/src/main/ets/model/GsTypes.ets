export type GsProtocolKind = 'quickshare' | 'windowsnearby';

export interface GsDevice {
  readonly id: string;
  readonly name: string;
  readonly model: string;
  readonly protocol: string;
  readonly address: string;
  readonly port: number;
  readonly https: boolean;
  readonly fingerprint: string;
  readonly source: string;
  readonly supports5Ghz?: boolean;
  readonly endpointId?: string;
}

export interface GsOutgoingFile {
  readonly path: string;
  readonly name: string;
  readonly size: number;
  readonly mime: string;
}

export interface GsIncomingFile {
  readonly name: string;
  readonly size: number;
  readonly savedPath: string;
  readonly mime?: string;
  /** 完整接收后由宿主把沙箱文件送往图库或下载目录。 */
  readonly stagedForSave?: boolean;
}

export interface GsSessionFileMeta {
  readonly id: string;
  readonly name: string;
  readonly size: number;
  readonly mime?: string;
}

export interface GsCdpEndpoint {
  readonly host: string;
  readonly port: number;
  readonly deviceId: string;
}

export interface GsCdpCapability {
  readonly name: string;
  readonly version: number;
  readonly enabled: boolean;
}

export interface GsSendHooks {
  onPin?: (pin: string) => Promise<boolean>;
  onProgress?: (percent: number) => void;
  // Our own stable Nearby endpoint id, advertised over BLE/mDNS. The
  // ConnectionRequest.frame.endpoint_id MUST be the sender's (client's) id, not
  // the peer's. It also has to match what this device broadcasts so the remote
    // server can correlate the socket with a discovered endpoint.
    readonly localEndpointId?: string;
    // Local interface IP to bind outgoing TCP sockets to (e.g. the Wi-Fi NIC).
    // Avoids the OS routing the connect through a virtual/vendor network.
    readonly sourceAddress?: string;
    // Force a Wi-Fi Direct medium upgrade: after UKEY2/ConnectionResponse the sender
    // issues a BANDWIDTH_UPGRADE_NEGOTIATION UPGRADE_PATH_REQUEST and, when the peer
    // offers WIFI_DIRECT credentials, joins its group and migrates the session.
    forceWifiDirect?: boolean;
    // Peer is the official Windows Quick Share (laptop/PC). When true the sender
    // uses a positive random 64-bit payload_id for files (the Windows client
    // correlates by that id; sequential index+1 ids are reported as untracked),
    // instead of the index+1 id used for phones/tablets. Android peers keep the
    // original sequential ids, so the working phone path is untouched.
    pcPeer?: boolean;
    onWifiDirectTransport?: (creds: WifiDirectUpgradeCredentials) => Promise<GsStreamConnection | undefined>;
    /** 介质变化通知（升级成功/失败/留在原通道），用于日志与页面提示。 */
    onTransportChange?: (change: GsTransportChange) => void;
  }

export interface GsReceiveHooks {
  onIncomingSession: (key: string, peerName: string, files: GsSessionFileMeta[], pin: string) => Promise<boolean>;
  /**
   * 接收端处理完一个完整文件后回调。
   *
   * 改为异步：入口层需要在返回前完成动态照片/图库保存或下载回退，
   * 这样进度与完成状态不会早于真实最终路径。
   */
  onFileReceived: (file: GsIncomingFile) => Promise<void>;
  onProgress: (percent: number) => void;
  onSessionFailed?: (key: string, reason: string) => void;
  // Wi-Fi Direct / bandwidth upgrade: return credentials to OFFER when the peer
  // requests an upgrade medium (Nearby BANDWIDTH_UPGRADE_NEGOTIATION). Return
  // undefined to decline and stay on the current transport.
  onUpgradeAvailable?: (mediums: number[]) => Promise<WifiDirectUpgradeCredentials | undefined>;
  // Nearby 的角色模型里，升级由**服务端主动**发起（bwu_manager.cc::InitiateBwuForEndpoint）：
  // 服务端直接发 UPGRADE_PATH_AVAILABLE，不需要先收 UPGRADE_PATH_REQUEST（后者只在动态角色切换时才用）。
  // 本字段让调用方在**局域网会话**上也要求接收端主动发起升级；BLE 引导会话已默认主动（带宽低，正需要升级）。
  // 见 docs/WIFI_DIRECT.md §2.4。
  proactiveWifiDirect?: boolean;
  /** 介质变化通知（升级成功/失败/留在原通道），用于日志与页面提示。 */
  onTransportChange?: (change: GsTransportChange) => void;
}

export interface WifiDirectUpgradeCredentials {
  readonly ssid: string;
  readonly password: string;
  readonly port: number;
  readonly gateway: string;
  readonly frequency: number;
}

/**
 * 会话实际使用的介质变化（Wi-Fi Direct 升级成功/失败、留在原通道）。
 * 供调用方落日志与更新页面提示——升级是**静默**发生的，没有这个回调用户看不出区别。
 */
export interface GsTransportChange {
  /** 当前介质：`wifi-direct` / `wifi-lan` / `ble`。 */
  readonly medium: string;
  /** true 表示这次变化是**升级到 Wi-Fi Direct 成功**。 */
  readonly upgraded: boolean;
  /** 人类可读的一行说明（直接用于日志与页面状态栏）。 */
  readonly detail: string;
}

/**
 * A bidirectional byte stream that the Quick Share receiver can run over, without
 * binding to a specific transport (TCP, BLE GATT socket, Wi-Fi Direct, ...). The
 * BLE GATT socket server and the Wi-Fi Direct upgrader feed/produce this shape so
 * the protocol layer never touches the physical medium.
 */
export interface GsStreamConnection {
  sendBytes(data: Uint8Array): Promise<void>;
  onData(listener: (chunk: Uint8Array) => void): void;
  onClose?(listener: () => void): void;
  close(): void;
}

export interface GsTlsMaterial {
  readonly certPath: string;
  readonly keyPath: string;
}

export interface GsTlsProvider {
  ensure(): Promise<GsTlsMaterial | undefined>;
}

export interface GsDeps {
  tlsProvider?: GsTlsProvider;
  deviceName?: () => string;
}

export interface GsCdpDevice {
  readonly deviceName: string;
  readonly deviceId: string;
  readonly deviceType: number;
  readonly deviceStatus: number;
  readonly capabilities: string[];
  readonly sessionHint: string;
}
