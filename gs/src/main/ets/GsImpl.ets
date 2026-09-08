import { common } from '@kit.AbilityKit';
import {
  GsCdpDevice,
  GsDeps,
  GsDevice,
  GsOutgoingFile,
  GsProtocolKind,
  GsReceiveHooks,
  GsSendHooks,
  GsStreamConnection,
  GsTlsProvider
} from './model/GsTypes';
import { GS_NEARSHARE_PORT, GS_QUICKSHARE_PORT } from './model/GsConstants';
import { QuickShareChannel, QuickShareReceiver, ReceiverConnection } from './quickshare/QuickShareChannel';
import { NearShareProtocol, NearShareReceiver } from './windowsnearby/NearShareProtocol';
import { MsCdpHandler } from './windowsnearby/MsCdpHandler';

const DEFAULT_ALIAS = 'CashmereLink';

/** Adapts a transport-agnostic byte stream into the receiver's connection shape. */
class StreamReceiverAdapter implements ReceiverConnection {
  private readonly conn: GsStreamConnection;

  constructor(conn: GsStreamConnection) {
    this.conn = conn;
  }

  sendBytes(data: Uint8Array): Promise<void> {
    return this.conn.sendBytes(data);
  }

  onData(listener: (chunk: Uint8Array) => void): void {
    this.conn.onData(listener);
  }

  close(): void {
    this.conn.close();
  }
}

/**
 * Concrete Quick Share / Windows Nearby protocol facade (lives entirely inside
 * the GPL gs module). One instance manages a single protocol: it either sends
 * files, or owns the network receiver for one listen port.
 */
export class GsFacadeImpl {
  readonly protocol: GsProtocolKind;

  private readonly context: common.Context;
  private readonly deviceName: () => string;
  private readonly tlsProvider?: GsTlsProvider;

  private quickshareReceiver?: QuickShareReceiver;
  private nearshareReceiver?: NearShareReceiver;

  constructor(protocol: GsProtocolKind, context: common.Context, deps?: GsDeps) {
    this.protocol = protocol;
    this.context = context;
    this.deviceName = deps !== undefined && deps.deviceName !== undefined ? deps.deviceName : (): string => DEFAULT_ALIAS;
    this.tlsProvider = deps !== undefined ? deps.tlsProvider : undefined;
  }

  async send(device: GsDevice, files: GsOutgoingFile[], hooks: GsSendHooks): Promise<void> {
    // Defensive guard: facade.send is a direct TCP/IPv4 connect. BLE-discovered
    // peers carry only a BLE MAC (no IP), which would otherwise surface as a
    // misleading "Network unreachable". The real Quick Share / Nearby
    // BLE GATT -> Wi-Fi Direct -> IP negotiation is out of the gs scope.
    if (!GsFacadeImpl.isIpv4(device.address)) {
      throw new Error('对端地址不是 IPv4（可能经 BLE 发现、仅有 MAC）：Quick Share/Windows Nearby 的 BLE GATT→Wi-Fi Direct→IP 协商未实现，暂不支持经该地址发送');
    }
    const peerName = this.deviceName();
    if (this.protocol === 'quickshare') {
      console.info('Quick Share send target=' + device.address + ':' + device.port + ' source=' + device.source);
      try {
        await new QuickShareChannel().send(device, files, hooks, peerName);
      } catch (error) {
        const message: string = error instanceof Error ? error.message : JSON.stringify(error);
        // Only retry the standard port when the mDNS-advertised port was not
        // reachable at the TCP layer. A UKEY2 handshake timeout means the peer
        // IS listening (it got our ConnectionRequest/ClientInit) but rejected or
        // ignored the handshake, so falling back to 53318 would just reconnect
        // and time out again.
        const isConnectFailure: boolean = message.indexOf('waiting for frame') < 0
          && (message.indexOf('connect failed') >= 0
            || message.indexOf('EINPROGRESS') >= 0
            || message.indexOf('socket') >= 0
            || message.indexOf('close before connect') >= 0);
        if (isConnectFailure && device.port > 0 && device.port !== GS_QUICKSHARE_PORT) {
          console.warn('Quick Share advertised port ' + device.port + ' 无响应，仅作启发式再试探标准端口 '
            + GS_QUICKSHARE_PORT + '（对 Android 官方 Quick Share 通常无效）：' + message);
          const fallback: GsDevice = {
            id: device.id,
            name: device.name,
            model: device.model,
            protocol: device.protocol,
            address: device.address,
            port: GS_QUICKSHARE_PORT,
            https: device.https,
            fingerprint: device.fingerprint,
            source: device.source,
            supports5Ghz: device.supports5Ghz
          };
          await new QuickShareChannel().send(fallback, files, hooks, peerName);
        } else {
          const base: string = error instanceof Error ? error.message : message;
          throw new Error(base.indexOf('SYN 无应答') >= 0
            ? base + '。请确认对端处于「接收/可见」状态、两端在同一可路由网络，且无线 AP 未开启客户端隔离（设备间单播被拦）。'
            : base);
        }
      }
    } else {
      await new NearShareProtocol().send(device, files, hooks, peerName);
    }
  }

  /**
   * Runs the Quick Share sender protocol over a transport-agnostic byte stream
   * (BLE GATT socket, Wi-Fi Direct socket, ...). Used by the entry-side BLE
   * socket client when the peer cannot be reached over the LAN TCP path.
   */
  async sendStream(conn: GsStreamConnection, files: GsOutgoingFile[], hooks: GsSendHooks): Promise<void> {
    if (this.protocol !== 'quickshare') {
      throw new Error('sendStream 仅支持 quickshare');
    }
    const peerName: string = this.deviceName();
    await new QuickShareChannel().sendStream(conn, files, hooks, peerName);
  }

  async startReceive(port: number, hooks: GsReceiveHooks, bindAddress?: string): Promise<void> {
    this.stopReceive();
    if (this.protocol === 'quickshare') {
      const receiver = new QuickShareReceiver(this.context);
      await receiver.start(port > 0 ? port : GS_QUICKSHARE_PORT, hooks, bindAddress);
      this.quickshareReceiver = receiver;
    } else {
      const receiver = new NearShareReceiver(this.context);
      await receiver.start(port > 0 ? port : GS_NEARSHARE_PORT, hooks, bindAddress);
      this.nearshareReceiver = receiver;
    }
  }

  /**
   * Runs the Quick Share receiver over a transport-agnostic byte stream (BLE GATT
   * socket, Wi-Fi Direct socket, ...). This is how a peer that cannot be reached
   * over the LAN TCP receiver still completes the protocol: the physical medium is
   * owned by the caller, the protocol only consumes/produces a stream.
   */
  async runReceiveStream(conn: GsStreamConnection, hooks: GsReceiveHooks): Promise<void> {
    if (this.protocol !== 'quickshare') {
      throw new Error('runReceiveStream 仅支持 quickshare');
    }
    const adapter: ReceiverConnection = new StreamReceiverAdapter(conn);
    await new QuickShareReceiver(this.context).run(adapter, hooks);
  }

  async selfTest(): Promise<string> {
    if (this.protocol !== 'quickshare') {
      throw new Error('selfTest is only available for quickshare');
    }
    return QuickShareChannel.selfTest(this.context);
  }

  stopReceive(): void {
    if (this.quickshareReceiver !== undefined) {
      this.quickshareReceiver.stop();
      this.quickshareReceiver = undefined;
    }
    if (this.nearshareReceiver !== undefined) {
      this.nearshareReceiver.stop();
      this.nearshareReceiver = undefined;
    }
  }

  parseCdp(payload: Uint8Array): GsCdpDevice | undefined {
    const advertisement = MsCdpHandler.parseServiceData(payload);
    if (advertisement === undefined) {
      return undefined;
    }
    return {
      deviceName: advertisement.deviceName,
      deviceId: advertisement.deviceId,
      deviceType: advertisement.deviceType,
      deviceStatus: advertisement.deviceStatus,
      capabilities: advertisement.capabilities,
      sessionHint: advertisement.sessionHint
    };
  }

  private static isIpv4(address: string): boolean {
    if (address.length === 0) {
      return false;
    }
    const parts = address.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (const part of parts) {
      if (part.length === 0 || part.length > 3) {
        return false;
      }
      for (let i = 0; i < part.length; i++) {
        const ch = part.charCodeAt(i);
        if (ch < 48 || ch > 57) {
          return false;
        }
      }
    }
    return true;
  }
}
