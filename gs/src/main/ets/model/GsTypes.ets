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
  }

export interface GsReceiveHooks {
  onIncomingSession: (key: string, peerName: string, files: GsSessionFileMeta[], pin: string) => Promise<boolean>;
  onFileReceived: (file: GsIncomingFile) => void;
  onProgress: (percent: number) => void;
  // Wi-Fi Direct / bandwidth upgrade: return credentials to OFFER when the peer
  // requests an upgrade medium (Nearby BANDWIDTH_UPGRADE_NEGOTIATION). Return
  // undefined to decline and stay on the current transport.
  onUpgradeAvailable?: (mediums: number[]) => Promise<WifiDirectUpgradeCredentials | undefined>;
}

export interface WifiDirectUpgradeCredentials {
  readonly ssid: string;
  readonly password: string;
  readonly port: number;
  readonly gateway: string;
  readonly frequency: number;
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
