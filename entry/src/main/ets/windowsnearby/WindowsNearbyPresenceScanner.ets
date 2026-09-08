import { LogCapture as Lg } from '../common/LogCapture';
/**
 * Lightweight, send-only UDP Presence scanner for Windows Nearby Sharing.
 *
 * Aggregate page needs to learn the peer *IP* (from Windows' CDP PresenceResponse)
 * so it can send to the Windows host on TCP 5040. The full WindowsNearbyTransfer
 * couples UDP discovery with a TCP-5040 receiver + Bluetooth RFCOMM listener; in
 * the aggregate (multi-scanner) context that receiver's bind can fail, which would
 * abort the whole transfer start() and leave the peer with an empty IP forever.
 *
 * This scanner is independent: it only binds the CDP UDP port, actively sends
 * PresenceRequest to the subnet broadcast, parses PresenceResponse, and reports
 * (name, ip). It never listens on TCP, so it cannot conflict with anything and is
 * exactly what a "send-only" page needs.
 */
import { socket } from '@kit.NetworkKit';
import netConnection from '@ohos.net.connection';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ByteUtils } from '../common/ByteUtils';
import { CdpCommonHeader, CdpWriter, CdpReader, CdpMessageType, CDP_UDP_PORT } from '../protocol/windowsnearby/CdpCodec';

const LOG_TAG = '羊绒互传 WindowsNearbyPresenceScanner';

export type WindowsPresenceListener = (name: string, ip: string) => void;

export class WindowsNearbyPresenceScanner {
  private readonly listener: WindowsPresenceListener;
  private readonly context: common.Context;
  private active = false;
  private udp?: socket.UDPSocket;
  private timer: number = 0;
  private refreshTimer: number = 0;
  private targets: string[] = [];

  constructor(context: common.Context, listener: WindowsPresenceListener) {
    this.context = context;
    this.listener = listener;
  }

  start(): void {
    if (this.active) {
      return;
    }
    this.active = true;
    const udp = socket.constructUDPSocketInstance();
    udp.on('message', (value: socket.SocketMessageInfo): void => {
      this.onMessage(value);
    });
    udp.bind({ address: '0.0.0.0', port: CDP_UDP_PORT, family: 1 }).then(async (): Promise<void> => {
      this.udp = udp;
      Lg.i(LOG_TAG + ': UDP ' + CDP_UDP_PORT + ' bound (presence scan)');
      try {
        await udp.setExtraOptions({ broadcast: true, reuseAddress: true });
      } catch (error) {
        Lg.w(LOG_TAG + ': setExtraOptions failed: ' + JSON.stringify(error));
      }
      this.refreshTargets();
      this.refreshTimer = setInterval((): void => {
        this.refreshTargets();
      }, 10000);
      // 立即先发一轮，再每 500ms 持续广播（与原 WindowsNearbyTransfer 一致）。
      // Windows 需要周期性收到 PresenceRequest 才会回应 PresenceResponse 提供 IP。
      this.sendPresenceRequests();
      this.timer = setInterval((): void => {
        this.sendPresenceRequests();
      }, 500);
    }).catch((error: BusinessError): void => {
      Lg.w(LOG_TAG + ': udp bind failed: ' + JSON.stringify(error));
      this.udp = undefined;
    });
  }

  stop(): void {
    if (!this.active) {
      return;
    }
    this.active = false;
    if (this.timer > 0) {
      clearInterval(this.timer);
      this.timer = 0;
    }
    if (this.refreshTimer > 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = 0;
    }
    const udp = this.udp;
    this.udp = undefined;
    if (udp !== undefined) {
      try {
        udp.off('message');
        udp.close().catch((): void => undefined);
      } catch (error) {
        Lg.w(LOG_TAG + ': udp close failed: ' + JSON.stringify(error));
      }
    }
    this.targets = [];
  }

  private onMessage(value: socket.SocketMessageInfo): void {
    const bytes = new Uint8Array(value.message);
    let type = -1;
    try {
      type = parseDiscoveryType(bytes);
    } catch (error) {
      Lg.w(LOG_TAG + ': parse discovery type failed: ' + JSON.stringify(error));
      return;
    }
    if (type === 1) {
      const name = parsePresenceResponseName(bytes);
      if (name.length > 0) {
        Lg.i(LOG_TAG + ': discovered peer "' + name + '" at ' + value.remoteInfo.address);
        this.listener(name, value.remoteInfo.address);
      }
    }
    // type === 0 是对端发来的 PresenceRequest（它想连我们做接收），仅发送模式下忽略。
  }

  /** 每轮都向所有子网目标广播 PresenceRequest（禁止只发一次）。 */
  private sendPresenceRequests(): void {
    if (this.targets.length === 0) {
      return;
    }
    const request = buildPresenceRequestFrame();
    for (const target of this.targets) {
      this.udp?.send({
        data: ByteUtils.toArrayBuffer(request),
        address: { address: target, port: CDP_UDP_PORT, family: 1 }
      }).catch((error: BusinessError): void => {
        Lg.w(LOG_TAG + ': presence send failed: ' + JSON.stringify(error));
      });
    }
  }

  /** 计算子网定向广播地址（发 255.255.255.255 会被系统 EACCES 拒绝）。 */
  private async refreshTargets(): Promise<void> {
    const targets: string[] = [];
    try {
      const netHandle = await netConnection.getDefaultNet();
      const properties = await netConnection.getConnectionProperties(netHandle);
      for (const link of properties.linkAddresses) {
        const addr = link.address.address;
        if (addr.indexOf('.') < 0) {
          continue;
        }
        const parts = addr.split('.');
        if (parts.length !== 4) {
          continue;
        }
        const ipNum = ((parseInt(parts[0], 10) << 24) | (parseInt(parts[1], 10) << 16) | (parseInt(parts[2], 10) << 8) | parseInt(parts[3], 10)) >>> 0;
        const prefix = link.prefixLength;
        const mask = prefix <= 0 ? 0 : ((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF) >>> 0;
        const broadcast = ((ipNum & mask) | (~mask & 0xFFFFFFFF)) >>> 0;
        const bAddr = ((broadcast >>> 24) & 0xFF) + '.' + ((broadcast >>> 16) & 0xFF) + '.' + ((broadcast >>> 8) & 0xFF) + '.' + (broadcast & 0xFF);
        if (targets.indexOf(bAddr) < 0) {
          targets.push(bAddr);
        }
      }
    } catch (error) {
      Lg.w(LOG_TAG + ': refresh targets failed: ' + JSON.stringify(error));
    }
    if (targets.length > 0) {
      this.targets = targets;
    } else if (this.targets.length === 0) {
      this.targets = ['255.255.255.255'];
    }
  }
}

/** Build a CDP UDP PresenceRequest (DiscoveryHeader type = PresenceRequest). */
function buildPresenceRequestFrame(): Uint8Array {
  const header = new CdpCommonHeader();
  header.type = CdpMessageType.Discovery;
  const writer = new CdpWriter();
  header.setPayloadLength(1);
  writer.writeHeader(header);
  writer.writeU8(0); // DiscoveryType.PresenceRequest
  return writer.finish();
}

/** Read the DiscoveryHeader type (0 = PresenceRequest, 1 = PresenceResponse). */
function parseDiscoveryType(bytes: Uint8Array): number {
  const reader = new CdpReader(bytes);
  reader.readHeader();
  return reader.readU8();
}

/** Parse a UDP PresenceResponse name (source IP is returned by the caller). */
function parsePresenceResponseName(bytes: Uint8Array): string {
  const reader = new CdpReader(bytes);
  const header = reader.readHeader();
  if (header.type !== CdpMessageType.Discovery) {
    return '';
  }
  const discoveryType = reader.readU8();
  if (discoveryType !== 1) { // PresenceResponse
    return '';
  }
  reader.readI16BE(); // connection mode
  reader.readI16BE(); // device type
  return reader.readStringWithLength();
}
