import { common } from '@kit.AbilityKit';
import { DeviceEndpoint, IncomingFile, OutgoingFile, SessionFileMeta } from '../../model/TransferModels';
import { CertificateStore } from '../../common/CertificateStore';
import { SettingsStore } from '../../common/SettingsStore';
import {
  GsFacadeImpl,
  GS_CDP_DEVICE_TYPE,
  GS_CDP_MANUFACTURER_ID,
  GS_CDP_SERVICE_UUID,
  GS_NEARSHARE_PORT,
  GS_NEARSHARE_SCENARIO,
  GS_QUICKSHARE_PORT,
  GsDevice,
  GsOutgoingFile,
  GsIncomingFile,
  GsSessionFileMeta,
  GsStreamConnection,
  WifiDirectUpgradeCredentials,
  GsTransportChange,
  GsTlsMaterial,
  GsTlsProvider,
  GsDeps,
  GsSendHooks as GsProtoSendHooks,
  GsReceiveHooks as GsProtoReceiveHooks
} from 'gsproto';

/**
 * GPL facade contract (frozen). The MIT "entry" shell only talks to the GPL
 * `gsproto` module through this interface and the `createGsFacade` factory;
 * it must never import gs module internals directly.
 */
export type GsProtocolKind = 'quickshare' | 'windowsnearby';

export interface GsSendHooks {
  onPin?: (pin: string) => Promise<boolean>;
  onProgress?: (percent: number) => void;
  readonly localEndpointId?: string;
  readonly sourceAddress?: string;
  forceWifiDirect?: boolean;
  pcPeer?: boolean;
  onWifiDirectTransport?: (creds: WifiDirectUpgradeCredentials) => Promise<GsStreamConnection | undefined>;
  /** 介质变化通知（升级成功/失败/留在原通道），用于日志与页面提示。 */
  onTransportChange?: (change: GsTransportChange) => void;
}

export interface GsReceiveHooks {
  onIncomingSession: (key: string, peerName: string, files: SessionFileMeta[], pin: string) => Promise<boolean>;
  onFileReceived: (file: IncomingFile) => Promise<void>;
  onProgress: (percent: number) => void;
  onSessionFailed?: (key: string, reason: string) => void;
  onUpgradeAvailable?: (mediums: number[]) => Promise<WifiDirectUpgradeCredentials | undefined>;
  /** 局域网会话上是否也要求接收端**主动**发起 Wi-Fi Direct 升级（BLE 引导会话默认主动）。 */
  proactiveWifiDirect?: boolean;
  /** 介质变化通知（升级成功/失败/留在原通道），用于日志与页面提示。 */
  onTransportChange?: (change: GsTransportChange) => void;
}

/** 命名类型（ArkTS 禁止在类型位置上使用内联对象字面量类型）。 */
export interface GsCdpName {
  readonly deviceName: string;
  readonly deviceId: string;
  readonly deviceType: number;
  readonly deviceStatus: number;
  readonly capabilities: string[];
  readonly sessionHint: string;
}

export interface GsFacade {
  readonly protocol: GsProtocolKind;

  send(device: DeviceEndpoint, files: OutgoingFile[], hooks: GsSendHooks): Promise<void>;

  /**
   * Runs the Quick Share sender protocol over a transport-agnostic byte stream
   * supplied by the caller (BLE GATT socket, Wi-Fi Direct socket, ...). Used by
   * the entry-side BLE socket client when the peer cannot be reached over LAN TCP.
   */
  sendStream(conn: GsStreamConnection, files: OutgoingFile[], hooks: GsSendHooks): Promise<void>;

  startReceive(port: number, hooks: GsReceiveHooks, bindAddress?: string): Promise<void>;

  /**
   * Runs the Quick Share receiver over a transport-agnostic byte stream supplied by
   * the caller (BLE GATT socket, Wi-Fi Direct socket, ...). Used by the entry-side
   * BLE socket / Wi-Fi Direct bootstrap path when the peer cannot be reached over the
   * LAN TCP receiver.
   */
  runReceiveStream(conn: GsStreamConnection, hooks: GsReceiveHooks): Promise<void>;

  selfTest(): Promise<string>;

  stopReceive(): void;

  parseCdp(payload: Uint8Array): GsCdpName | undefined;
}

// Protocol constants re-exported from the GPL module for the shell's discovery
// and server-start code (DiscoveryManager BLE filters / advertisement, and
// TransferManager startServer). Single source of truth lives in gsproto.
export {
  GS_CDP_DEVICE_TYPE,
  GS_CDP_MANUFACTURER_ID,
  GS_CDP_SERVICE_UUID,
  GS_NEARSHARE_PORT,
  GS_NEARSHARE_SCENARIO,
  GS_QUICKSHARE_PORT
};

export type { GsStreamConnection };
export type { WifiDirectUpgradeCredentials };
export type { GsTransportChange };

function toGsDevice(device: DeviceEndpoint): GsDevice {
  return {
    id: device.id,
    name: device.name,
    model: device.model,
    protocol: device.protocol,
    address: device.address,
    port: device.port,
    https: device.https,
    fingerprint: device.fingerprint,
    source: device.source,
    supports5Ghz: device.supports5Ghz
  };
}

function toGsFile(file: OutgoingFile): GsOutgoingFile {
  return { path: file.path, name: file.name, size: file.size, mime: file.mime };
}

class TlsProviderAdapter implements GsTlsProvider {
  private readonly certs: CertificateStore;

  constructor(certs: CertificateStore) {
    this.certs = certs;
  }

  async ensure(): Promise<GsTlsMaterial | undefined> {
    const material = await this.certs.ensure();
    if (material === undefined) {
      return undefined;
    }
    return { certPath: material.certPath, keyPath: material.keyPath };
  }
}

function buildDeps(certs: CertificateStore, kind: GsProtocolKind): GsDeps {
  const deps: GsDeps = {
    deviceName: (): string => SettingsStore.current().alias
  };
  // Google Nearby/Quick Share starts with a plaintext length-prefixed
  // OfflineFrame and establishes encryption through UKEY2. Wrapping this port
  // in TLS makes official peers disconnect before the protocol handshake.
  if (kind !== 'quickshare') {
    deps.tlsProvider = new TlsProviderAdapter(certs);
  }
  return deps;
}

function buildProtoSendHooks(hooks: GsSendHooks): GsProtoSendHooks {
  return {
    onPin: hooks.onPin,
    onProgress: hooks.onProgress,
    localEndpointId: hooks.localEndpointId,
    sourceAddress: hooks.sourceAddress,
    forceWifiDirect: hooks.forceWifiDirect,
    pcPeer: hooks.pcPeer,
    onWifiDirectTransport: hooks.onWifiDirectTransport,
    onTransportChange: hooks.onTransportChange
  };
}

function buildProtoReceiveHooks(hooks: GsReceiveHooks): GsProtoReceiveHooks {
  return {
    onIncomingSession: (key: string, peerName: string, files: GsSessionFileMeta[], pin: string): Promise<boolean> => {
      const meta: SessionFileMeta[] = files.map((m: GsSessionFileMeta): SessionFileMeta => ({
        id: m.id,
        name: m.name,
        size: m.size,
        mime: m.mime
      }));
      return hooks.onIncomingSession(key, peerName, meta, pin);
    },
    onFileReceived: async (file: GsIncomingFile): Promise<void> => {
      const incoming: IncomingFile = {
        name: file.name,
        size: file.size,
        savedPath: file.savedPath,
        mime: file.mime,
        stagedForSave: file.stagedForSave === true
      };
      await hooks.onFileReceived(incoming);
    },
    onSessionFailed: hooks.onSessionFailed,
    onProgress: (percent: number): void => hooks.onProgress(percent),
    onUpgradeAvailable: hooks.onUpgradeAvailable,
    proactiveWifiDirect: hooks.proactiveWifiDirect,
    onTransportChange: hooks.onTransportChange
  };
}

/** 具体 GPL 实现的门面适配器：用类避免 arkts-no-untyped-obj-literals。 */
class GsFacadeAdapter implements GsFacade {
  readonly protocol: GsProtocolKind;
  private readonly impl: GsFacadeImpl;

  constructor(kind: GsProtocolKind, context: common.Context) {
    this.protocol = kind;
    const certs = new CertificateStore(context);
    this.impl = new GsFacadeImpl(kind, context, buildDeps(certs, kind));
  }

  send(device: DeviceEndpoint, files: OutgoingFile[], hooks: GsSendHooks): Promise<void> {
    return this.impl.send(toGsDevice(device), files.map(toGsFile), buildProtoSendHooks(hooks));
  }

  sendStream(conn: GsStreamConnection, files: OutgoingFile[], hooks: GsSendHooks): Promise<void> {
    return this.impl.sendStream(conn, files.map(toGsFile), buildProtoSendHooks(hooks));
  }

  startReceive(port: number, hooks: GsReceiveHooks, bindAddress?: string): Promise<void> {
    return this.impl.startReceive(port, buildProtoReceiveHooks(hooks), bindAddress);
  }

  runReceiveStream(conn: GsStreamConnection, hooks: GsReceiveHooks): Promise<void> {
    return this.impl.runReceiveStream(conn, buildProtoReceiveHooks(hooks));
  }

  selfTest(): Promise<string> {
    return this.impl.selfTest();
  }

  stopReceive(): void {
    this.impl.stopReceive();
  }

  parseCdp(payload: Uint8Array): GsCdpName | undefined {
    const cdp = this.impl.parseCdp(payload);
    if (cdp === undefined) {
      return undefined;
    }
    const name: GsCdpName = {
      deviceName: cdp.deviceName,
      deviceId: cdp.deviceId,
      deviceType: cdp.deviceType,
      deviceStatus: cdp.deviceStatus,
      capabilities: cdp.capabilities,
      sessionHint: cdp.sessionHint
    };
    return name;
  }
}

/**
 * Facade factory: instantiates the concrete GPL implementation and adapts the
 * entry model types (DeviceEndpoint / OutgoingFile / IncomingFile / ...) to the
 * gsproto structural types, keeping the GPL boundary clean.
 */
export function createGsFacade(kind: GsProtocolKind, context: common.Context): GsFacade {
  return new GsFacadeAdapter(kind, context);
}
