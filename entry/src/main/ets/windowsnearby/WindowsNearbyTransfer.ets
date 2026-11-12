import { LogCapture as Lg } from '../common/LogCapture';
/**
 * Real MS-CDP receiver for Windows Nearby Sharing.
 *
 * The phone acts as the CDP *host* on TCP 5040: it receives the Windows
 * sender's ConnectRequest, completes the Connection/DeviceAuth handshake with
 * ECDH + session encryption, opens the app channels and then drives the
 * NearShare pull-model (FetchDataRequest / FetchDataResponse) to write files.
 *
 * This is intentionally independent of the old gs JSON protocol and of the
 * Quick Share stack.
 */

import { socket } from '@kit.NetworkKit';
import bluetoothSocket from '@ohos.bluetooth.socket';
import netConnection from '@ohos.net.connection';
import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { ByteUtils } from '../common/ByteUtils';
import {
  CdpCommonHeader,
  CdpWriter,
  CdpReader,
  CDP_TCP_PORT,
  CDP_UDP_PORT,
  CDP_PARTITION_SIZE,
  CdpMessageType,
  CdpMessageFlags,
  CdpAdditionalHeaderType,
  CdpBinaryMsgHeader,
  CdpAdditionalHeader
} from '../protocol/windowsnearby/CdpCodec';
import { CdpCryptor } from '../protocol/windowsnearby/CdpCryptor';
import { CdpSecurity } from '../protocol/windowsnearby/CdpSecurity';
import {
  CdpConnectionHeader,
  CdpConnectionRequest,
  CdpConnectionResponse,
  CdpAuthenticationPayload,
  CdpResultPayload,
  CdpHResultPayload,
  CdpEmptyBody,
  CdpUpgradeResponsePayload,
  CdpUpgradeIdPayload,
  CdpStartChannelRequest,
  CdpStartChannelResponse,
  CdpDeviceInfoMessage,
  CdpConnectionType,
  CdpConnectionMode,
  CdpConnectionResult,
  CdpResult,
  CdpControlMessageType,
  CdpChannelResult,
  CdpConnectionBody
} from '../protocol/windowsnearby/CdpConnection';
import { CdpValueSet } from '../protocol/windowsnearby/CdpBond';
import { SettingsStore } from '../common/SettingsStore';
import { GalleryMediaClassifier } from '../quickshare/storage/GalleryMediaClassifier';

const LOG_TAG = '羊绒互传 WindowsNearbyTransfer';
const APP_HANDSHAKE_ID = '0d472c30-80b5-4722-a279-0f3b97f0dcf2';
const APP_PLATFORM_NAME = 'NearSharePlatform';
const SESSION_ID_HOST_FLAG = 0x80000000;

export interface WindowsNearbyIncomingFile {
  readonly name: string;
  readonly size: number;
  readonly contentId: number;
}

export class WindowsNearbyTransferListener {
  onStatus(text: string): void {
  }

  onPeerConnected(peerName: string): void {
  }

  onPeerDiscovered(peerName: string, ip: string): void {
  }

  /** Return true to accept the transfer; false to reject. */
  onIncomingTransfer(peerName: string, files: WindowsNearbyIncomingFile[]): Promise<boolean> {
    return Promise.resolve(false);
  }

  /**
   * 异步：入口层必须先完成动态照片/图库保存或 Download 回退，
   * 后续文件与 Completed 状态才不会抢在最终路径确定前发出。
   */
  onFileReceived(file: WindowsNearbyIncomingFile, savedPath: string): Promise<void> {
    return Promise.resolve();
  }

  onProgress(percent: number): void {
  }

  onCompleted(): void {
  }

  onFailed(reason: string): void {
  }
}

interface PendingFile {
  readonly contentId: number;
  readonly name: string;
  readonly size: number;
  readonly path: string;
  fd: number;
  complete: boolean;
}

interface FunctionalChannel {
  readonly id: number;
  readonly appId: string;
  readonly handleMessage: (header: CdpBinaryMsgHeader, payload: CdpValueSet) => Promise<void>;
}

class CdpFunctionalChannel implements FunctionalChannel {
  readonly id: number;
  readonly appId: string;
  readonly handleMessage: (header: CdpBinaryMsgHeader, payload: CdpValueSet) => Promise<void>;

  constructor(id: number, appId: string, handleMessage: (header: CdpBinaryMsgHeader, payload: CdpValueSet) => Promise<void>) {
    this.id = id;
    this.appId = appId;
    this.handleMessage = handleMessage;
  }
}

export class WindowsNearbyTransfer {
  private readonly context: common.Context;
  private readonly listener: WindowsNearbyTransferListener;
  private readonly security: CdpSecurity;
  private server?: socket.TCPSocketServer;
  private udp?: socket.UDPSocket;
  private udpTimer: number = 0;
  private udpRefreshTimer: number = 0;
  private broadcastTargets: string[] = [];
  private ownIp: string = '';
  private conn?: socket.TCPSocketConnection;
  private buffer: Uint8Array = new Uint8Array(0);
  private running = false;
  private deviceName: string = 'CashmereLink';
  private btServerSocket: number = -1;
  private btClientSocket: number = -1;
  private useBt: boolean = false;
  private upgradingToTcp: boolean = false;

  private cryptor?: CdpCryptor;
  private localNonce: Uint8Array = new Uint8Array(8);
  private remoteNonce: Uint8Array = new Uint8Array(8);
  private localSessionHi: number = 0;
  private localSessionLo: number = 0;
  private nextHostSessionId: number = 1;
  private nextChannelId: number = 1;
  private seq: number = 0;
  private activeChannelId: number = 0;
  private peerName: string = '';

  private channels: FunctionalChannel[] = [];
  private pendingFiles: PendingFile[] = [];
  private pendingIncoming: WindowsNearbyIncomingFile[] = [];
  private bytesToSend: number = 0;
  private bytesReceived: number = 0;
  private accepted = false;
  private currentMessageId: number = 0;
  private waitResponse?: (payload: CdpValueSet) => void;
  private responseReject?: (error: Error) => void;
  private responseTimer: number = -1;
  private finished = false;
  private networkDone = false;
  private deviceAuthenticated = false;
  /** 已完成/中止的会话计数，用于诊断「第二次搜不到」类问题。 */
  private sessionCount: number = 0;
  private sessionGeneration: number = 0;
  private lifecycleGeneration: number = 0;
  /** CDP-level fragment reassembly: key = header.sequenceNumber, value = fragmentIndex -> payload. */
  private readonly fragMap: Map<number, Map<number, Uint8Array>> = new Map<number, Map<number, Uint8Array>>();

  private constructor(context: common.Context, listener: WindowsNearbyTransferListener, security: CdpSecurity) {
    this.context = context;
    this.listener = listener;
    this.security = security;
  }

  static async create(context: common.Context, listener: WindowsNearbyTransferListener): Promise<WindowsNearbyTransfer> {
    const security = await CdpSecurity.load(context);
    return new WindowsNearbyTransfer(context, listener, security);
  }

  get isRunning(): boolean {
    return this.running;
  }

  captureSessionValidity(): () => boolean {
    const generation = this.sessionGeneration;
    return (): boolean => this.running && !this.finished && generation === this.sessionGeneration;
  }

  async start(): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    const generation = ++this.lifecycleGeneration;
    Lg.i(LOG_TAG + ': receiver start (TCP ' + CDP_TCP_PORT + ', UDP ' + CDP_UDP_PORT + ')');
    const server = socket.constructTCPSocketServerInstance();
    this.server = server;
    server.on('connect', (conn: socket.TCPSocketConnection): void => {
      if (!this.running || generation !== this.lifecycleGeneration) {
        conn.close().catch((): void => undefined);
        return;
      }
      if (this.upgradingToTcp) {
        // This is the RFCOMM -> TCP upgrade target. Attach it as the session
        // socket but keep routing on Bluetooth until TransportRequest finalises
        // the upgrade (the auth/upgrade finalisation messages still flow over BT).
        this.conn = conn;
        this.buffer = new Uint8Array(0);
        this.finished = false;
        this.fragMap.clear();
        Lg.i(LOG_TAG + ': upgrade TCP connected');
        conn.on('message', (info: socket.SocketMessageInfo): void => {
          if (this.conn !== conn) { return; }
          this.onData(new Uint8Array(info.message));
        });
        conn.on('close', (): void => {
          if (this.conn !== conn) { return; }
          Lg.i(LOG_TAG + ': upgrade TCP closed');
          // 升级连接在 TransportRequest 之前断开（升级失败/会话中止）：解除卡死的
          // upgradingToTcp，否则下一次 Windows 会话的 TCP 连接会被误判为升级目标，
          // 表现为「完成一次传输后第二次搜不到/连不上，重启 app 才好」。
          this.upgradingToTcp = false;
        });
        conn.on('error', (error: BusinessError): void => {
          if (this.conn !== conn) { return; }
          Lg.w(LOG_TAG + ': upgrade TCP error: ' + JSON.stringify(error));
          this.upgradingToTcp = false;
        });
        return;
      }
      if (!this.finished && (this.accepted || this.pendingIncoming.length > 0)) {
        conn.close().catch((): void => undefined);
        return;
      }
      Lg.i(LOG_TAG + ': TCP client connected');
      this.listener.onStatus('Windows 正尝试建立 CDP 连接');
      // 新会话：清空上一会话残留（cryptor/序号/频道/待收文件等），避免第二次传输错乱。
      this.resetSession();
      const previous = this.conn;
      this.conn = conn;
      previous?.close().catch((): void => undefined);
      this.buffer = new Uint8Array(0);
      this.useBt = false;
      this.upgradingToTcp = false;
      this.sessionCount++;
      Lg.i(LOG_TAG + ': session #' + this.sessionCount + ' start (transport=TCP)');
      conn.on('message', (info: socket.SocketMessageInfo): void => {
        if (this.conn !== conn) { return; }
        this.onData(new Uint8Array(info.message));
      });
      conn.on('close', (): void => {
        if (this.conn !== conn) { return; }
        this.listener.onStatus('Windows CDP 连接已关闭');
        if (!this.networkDone) { this.abortTransfer('Windows 对端连接已断开'); }
      });
      conn.on('error', (error: BusinessError): void => {
        if (this.conn !== conn) { return; }
        this.listener.onStatus('Windows CDP 连接错误：' + JSON.stringify(error));
        if (!this.networkDone) { this.abortTransfer('Windows 接收连接错误'); }
      });
    });
    try {
      await server.listen({ address: '0.0.0.0', family: 1, port: CDP_TCP_PORT });
      if (!this.running || generation !== this.lifecycleGeneration) {
        await server.close().catch((): void => undefined);
        return;
      }
      Lg.i(LOG_TAG + ': TCP ' + CDP_TCP_PORT + ' listening');
      this.listener.onStatus('已监听 Windows CDP TCP ' + CDP_TCP_PORT);
    } catch (error) {
      // TCP 5040 被占用时不再整体失败：UDP 5050 presence 与蓝牙 RFCOMM 仍能让 Windows
      // 发现并连入手机。若在这里抛错，startUdpDiscovery 不会启动，Windows 连手机的名字
      // 和 IP 都拿不到（「先开 app、后开 Windows 搜不到，重启 app 才好」的诱因之一）。
      // 降级为蓝牙接收：发现走 UDP presence / BLE，传输走 RFCOMM。
      Lg.w(LOG_TAG + ': TCP listen failed, degrade to UDP discovery + Bluetooth: ' + JSON.stringify(error));
      this.listener.onStatus('Windows CDP TCP ' + CDP_TCP_PORT + ' 监听失败，降级为蓝牙接收');
    }
    if (!this.running || generation !== this.lifecycleGeneration) {
      await server.close().catch((): void => undefined);
      return;
    }
    this.startUdpDiscovery();
    this.startBluetoothListener();
  }

  stop(): void {
    this.lifecycleGeneration += 1;
    this.abortTransfer('Windows 接收服务已停止');
    this.running = false;
    if (this.btServerSocket >= 0) {
      try {
        bluetoothSocket.sppCloseServerSocket(this.btServerSocket);
      } catch (error) {
        Lg.w(LOG_TAG + ': bt server close failed: ' + JSON.stringify(error));
      }
      this.btServerSocket = -1;
    }
    if (this.btClientSocket >= 0) {
      try {
        bluetoothSocket.sppCloseClientSocket(this.btClientSocket);
      } catch (error) {
        Lg.w(LOG_TAG + ': bt client close failed: ' + JSON.stringify(error));
      }
      this.btClientSocket = -1;
    }
    this.useBt = false;
    this.upgradingToTcp = false;
    this.fragMap.clear();
    for (const file of this.pendingFiles) {
      try {
        fs.closeSync(file.fd);
      } catch (error) {
        Lg.w(LOG_TAG + ': close file failed: ' + JSON.stringify(error));
      }
    }
    this.pendingFiles = [];
    const server = this.server;
    this.server = undefined;
    if (server !== undefined) {
      try {
        server.off('connect');
        server.close().catch((): void => undefined);
      } catch (error) {
        Lg.w(LOG_TAG + ': server close failed: ' + JSON.stringify(error));
      }
    }
    const udp = this.udp;
    this.udp = undefined;
    if (this.udpTimer > 0) {
      clearInterval(this.udpTimer);
      this.udpTimer = 0;
    }
    if (this.udpRefreshTimer > 0) {
      clearInterval(this.udpRefreshTimer);
      this.udpRefreshTimer = 0;
    }
    if (udp !== undefined) {
      try {
        udp.off('message');
        udp.close().catch((): void => undefined);
      } catch (error) {
        Lg.w(LOG_TAG + ': udp close failed: ' + JSON.stringify(error));
      }
    }
    const conn = this.conn;
    this.conn = undefined;
    conn?.close().catch((): void => undefined);
  }

  private startUdpDiscovery(): void {
    const generation = this.lifecycleGeneration;
    const udp = socket.constructUDPSocketInstance();
    this.udp = udp;
    udp.on('message', (value: socket.SocketMessageInfo): void => {
      if (!this.running || generation !== this.lifecycleGeneration || this.udp !== udp) { return; }
      const bytes = new Uint8Array(value.message);
      const discoveryType = bytes.length > 42 ? bytes[42] : -1;
      if (this.ownIp.length > 0 && value.remoteInfo.address === this.ownIp) {
        Lg.d(LOG_TAG + ': udp recv ignored (self) from ' + value.remoteInfo.address);
        return;
      }
      Lg.i(LOG_TAG + ': udp recv from ' + value.remoteInfo.address + ':' + value.remoteInfo.port + ' len=' + bytes.length + ' discType=' + discoveryType);
      try {
        const type = parseDiscoveryType(bytes);
        if (type === 0) {
          // Windows sent a PresenceRequest -> advertise our endpoint back so it
          // can derive the phone IP and connect to TCP 5040 (receive path).
          this.respondPresence(value.remoteInfo.address, udp).catch((error: BusinessError): void => {
            Lg.w(LOG_TAG + ': udp advertise response failed: ' + error.message);
          });
          return;
        }
        if (type === 1) {
          const name = parsePresenceResponseName(bytes);
          if (name.length > 0) {
            Lg.i(LOG_TAG + ': discovered peer "' + name + '" at ' + value.remoteInfo.address);
            this.listener.onPeerDiscovered(name, value.remoteInfo.address);
          } else {
            Lg.w(LOG_TAG + ': presence response parsed with empty device name');
          }
        }
      } catch (error) {
        Lg.w(LOG_TAG + ': udp presence parse failed: ' + JSON.stringify(error));
      }
    });
    udp.bind({ address: '0.0.0.0', port: CDP_UDP_PORT, family: 1 }).then(async (): Promise<void> => {
      if (!this.running || generation !== this.lifecycleGeneration || this.udp !== udp) {
        await udp.close().catch((): void => undefined);
        return;
      }
      Lg.i(LOG_TAG + ': UDP ' + CDP_UDP_PORT + ' bound (discover + advertise)');
      const extraOptions: socket.UDPExtraOptions = { broadcast: true, reuseAddress: true };
      await udp.setExtraOptions(extraOptions);
      if (!this.running || generation !== this.lifecycleGeneration || this.udp !== udp) {
        await udp.close().catch((): void => undefined);
        return;
      }
      const request = buildPresenceRequestFrame();
      const sentTargets: Set<string> = new Set<string>();
      this.refreshBroadcastTargets();
      this.udpTimer = setInterval((): void => {
        for (const target of this.broadcastTargets) {
          udp.send({
            data: ByteUtils.toArrayBuffer(request),
            address: { address: target, port: CDP_UDP_PORT, family: 1 }
          })
            .then((): void => {
              if (!sentTargets.has(target)) {
                sentTargets.add(target);
                Lg.i(LOG_TAG + ': udp presence request sent to ' + target + ' len=' + request.length);
              }
            })
            .catch((error: BusinessError): void => {
              Lg.w(LOG_TAG + ': udp presence send failed: ' + JSON.stringify(error));
            });
        }
      }, 500);
      // Re-resolve the subnet broadcast asynchronously so the sync network
      // lookup never blocks the ArkTS main thread (avoids AppFreeze).
      this.udpRefreshTimer = setInterval((): void => {
        this.refreshBroadcastTargets();
      }, 10000);
    }).catch((error: BusinessError): void => {
      Lg.w(LOG_TAG + ': udp bind failed: ' + JSON.stringify(error));
      udp.close().catch((): void => undefined);
      if (this.udp === udp) { this.udp = undefined; }
    });
  }

  /**
   * HarmonyOS rejects sending to the limited broadcast 255.255.255.255 with
   * EACCES (2301013) even after setExtraOptions({broadcast:true}). The known
   * workaround is to send to the *subnet-directed* broadcast (e.g. 192.168.1.255)
   * computed from the default network's IPv4 address + prefix length, which is
   * routable on the active interface.
   */
  private async refreshBroadcastTargets(): Promise<void> {
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
        if (this.ownIp.length === 0) {
          this.ownIp = addr;
          Lg.i(LOG_TAG + ': local ip ' + this.ownIp);
        }
        const prefix = link.prefixLength;
        const mask = prefix <= 0 ? 0 : ((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF) >>> 0;
        const broadcast = ((ipNum & mask) | (~mask & 0xFFFFFFFF)) >>> 0;
        const bAddr = ((broadcast >>> 24) & 0xFF) + '.' + ((broadcast >>> 16) & 0xFF) + '.' + ((broadcast >>> 8) & 0xFF) + '.' + (broadcast & 0xFF);
        if (targets.indexOf(bAddr) < 0) {
          targets.push(bAddr);
        }
      }
      if (targets.length > 0) {
        this.broadcastTargets = targets;
      }
    } catch (error) {
      Lg.w(LOG_TAG + ': get local broadcast failed: ' + JSON.stringify(error));
    }
    if (targets.length === 0) {
      this.broadcastTargets = ['255.255.255.255'];
    }
  }

  private async respondPresence(ip: string, udp: socket.UDPSocket): Promise<void> {
    const frame = await buildPresenceResponseFrame(this.deviceName);
    await udp.send({
      data: ByteUtils.toArrayBuffer(frame),
      address: { address: ip, port: CDP_UDP_PORT, family: 1 }
    });
    Lg.i(LOG_TAG + ': udp presence response sent to ' + ip + ' len=' + frame.length);
  }

  private onData(chunk: Uint8Array): void {
    const generation = this.sessionGeneration;
    this.buffer = ByteUtils.concat([this.buffer, chunk]);
    while (this.buffer.length >= 4) {
      const messageLength = CdpCommonHeader.readRawMessageLength(this.buffer);
      if (messageLength < 42 || messageLength > 32 * 1024 * 1024) {
        this.buffer = new Uint8Array(0);
        return;
      }
      if (this.buffer.length < messageLength) {
        return;
      }
      const frame = this.buffer.slice(0, messageLength);
      this.buffer = this.buffer.slice(messageLength);
      try {
        const header = parseCommonHeaderSafe(frame);
        this.processFrame(frame, header).catch((error: Error): void => {
          if (generation !== this.sessionGeneration) { return; }
          Lg.w(LOG_TAG + ': CDP process error: ' + error.message);
          this.listener.onStatus('CDP 处理失败：' + error.message);
          this.abortTransfer(error.message);
        });
      } catch (error) {
        const msg = error instanceof Error ? error.message : JSON.stringify(error);
        Lg.w(LOG_TAG + ': CDP frame parse error: ' + msg);
        this.listener.onStatus('CDP 帧解析失败：' + msg);
        this.abortTransfer(msg);
      }
    }
  }

  private async processFrame(frame: Uint8Array, header: CdpCommonHeader): Promise<void> {
    const generation = this.sessionGeneration;
    let payload: Uint8Array;
    if (header.hasFlag(CdpMessageFlags.SessionEncrypted) && this.cryptor !== undefined) {
      payload = await this.cryptor.decryptFrame(frame, header);
    } else {
      payload = frame.slice(header.calcSize());
    }
    this.assertSession(generation);

    // Normalise the session id before routing (CorrectClientSessionBit).
    header.correctClientSessionBit();

    if (header.type === CdpMessageType.Connect) {
      await this.handleConnect(header, payload);
      return;
    }
    if (this.cryptor === undefined || !this.deviceAuthenticated
      || !header.hasFlag(CdpMessageFlags.SessionEncrypted) || !header.hasFlag(CdpMessageFlags.HasHMAC)) {
      throw new Error('CDP 会话消息缺少认证或完整性校验');
    }
    if (header.type === CdpMessageType.Control) {
      await this.handleControl(header, payload);
      return;
    }
    if (header.type === CdpMessageType.Session) {
      const seq = header.sequenceNumber;
      const fragmentCount = header.fragmentCount;
      const fragmentIndex = header.fragmentIndex;
      if (fragmentCount <= 1) {
        await this.handleSession(header, payload);
        return;
      }
      let fragments = this.fragMap.get(seq);
      if (fragments === undefined) {
        fragments = new Map<number, Uint8Array>();
        this.fragMap.set(seq, fragments);
      }
      fragments.set(fragmentIndex, payload);
      if (fragments.size >= fragmentCount) {
        const parts: Uint8Array[] = [];
        for (let i = 0; i < fragmentCount; i++) {
          const part = fragments.get(i);
          if (part === undefined) {
            return;
          }
          parts.push(part);
        }
        this.fragMap.delete(seq);
        await this.handleSession(header, ByteUtils.concat(parts));
      }
      return;
    }
  }

  private async handleConnect(header: CdpCommonHeader, payload: Uint8Array): Promise<void> {
    const reader = new CdpReader(payload);
    const connHeader = CdpConnectionHeader.parse(reader);
    switch (connHeader.messageType) {
      case CdpConnectionType.ConnectRequest:
        await this.handleConnectRequest(header, reader);
        return;
      case CdpConnectionType.DeviceAuthRequest:
      case CdpConnectionType.UserDeviceAuthRequest:
        await this.handleDeviceAuth(header, reader, connHeader.messageType);
        return;
      case CdpConnectionType.AuthDoneRequest:
        this.handleAuthDone(header);
        return;
      case CdpConnectionType.DeviceInfoMessage:
        await this.handleDeviceInfo(header, reader);
        return;
      case CdpConnectionType.UpgradeRequest:
        await this.handleUpgradeRequest(header, reader);
        return;
      case CdpConnectionType.UpgradeFinalization:
        await this.handleUpgradeFinalization(header);
        return;
      case CdpConnectionType.TransportRequest:
        await this.handleTransportRequest(header, reader);
        return;
      default:
        return;
    }
  }

  private wifiUpgradeEnabled(): boolean {
    return SettingsStore.current().wifiUpgradeTcp === true;
  }

  /**
   * The sender (Windows or the Android reference) always offers an RFCOMM -> TCP
   * upgrade after the auth exchange. With the Wi-Fi toggle ON we accept it and
   * hand the (already-encrypted) session over to TCP 5040 for the file transfer.
   * With the toggle OFF we decline with UpgradeFailure so the sender keeps the
   * session on the current Bluetooth socket (avoids the sender hanging forever).
   */
  private async handleUpgradeRequest(header: CdpCommonHeader, reader: CdpReader): Promise<void> {
    if (this.upgradingToTcp) {
      return;
    }
    Lg.i(LOG_TAG + ': received UpgradeRequest, wifiUpgradeTcp=' + this.wifiUpgradeEnabled());
    if (!this.wifiUpgradeEnabled()) {
      Lg.w(LOG_TAG + ': decline upgrade to Wi-Fi, stay on Bluetooth');
      const failure = new CdpHResultPayload(0x80004001); // E_NOTIMPL
      await this.sendConnection(header, CdpConnectionType.UpgradeFailure, failure).catch((error: Error): void => {
        Lg.w(LOG_TAG + ': upgrade failure response error: ' + error.message);
      });
      return;
    }
    // Consume the UpgradeId (16 bytes) so the stream is aligned for any reader.
    // We do not need to echo it in UpgradeResponse; the client matches by id.
    reader.readBytes(16);
    if (this.ownIp.length === 0) {
      const failure = new CdpHResultPayload(0x80004001); // E_NOTIMPL
      await this.sendConnection(header, CdpConnectionType.UpgradeFailure, failure).catch((): void => undefined);
      return;
    }
    this.upgradingToTcp = true;
    const response = new CdpUpgradeResponsePayload(this.ownIp, CDP_TCP_PORT.toString());
    Lg.i(LOG_TAG + ': accept upgrade to Wi-Fi(TCP ' + CDP_TCP_PORT + ') at ' + this.ownIp);
    await this.sendConnection(header, CdpConnectionType.UpgradeResponse, response).catch((error: Error): void => {
      Lg.w(LOG_TAG + ': upgrade response error: ' + error.message);
    });
  }

  /** Client sends UpgradeFinalization over the old BT socket; finalise over BT. */
  private async handleUpgradeFinalization(header: CdpCommonHeader): Promise<void> {
    Lg.i(LOG_TAG + ': upgrade finalisation received (over BT)');
    await this.sendConnection(header, CdpConnectionType.UpgradeFinalizationResponse, new CdpEmptyBody());
  }

  /**
   * Client sends TransportRequest over the NEW TCP socket. Echo the UpgradeId and
   * switch session routing to TCP from here on.
   */
  private async handleTransportRequest(header: CdpCommonHeader, reader: CdpReader): Promise<void> {
    const upgradeId = reader.readBytes(16);
    // Route subsequent messages over TCP.
    this.useBt = false;
    this.upgradingToTcp = false;
    Lg.i(LOG_TAG + ': transport confirmed, session now on TCP');
    await this.sendConnection(header, CdpConnectionType.TransportConfirmation, new CdpUpgradeIdPayload(upgradeId));
  }

  private async handleConnectRequest(header: CdpCommonHeader, reader: CdpReader): Promise<void> {
    const generation = this.sessionGeneration;
    if (this.cryptor !== undefined) { throw new Error('CDP duplicate ConnectRequest'); }
    const request = CdpConnectionRequest.parse(reader);
    Lg.i(LOG_TAG + ': received ConnectRequest');
    this.remoteNonce = request.nonceBytes;

    // The client places its own local id in the LOW word of the session id.
    const clientLo = readU32BE(header.sessionId, 4) & ~SESSION_ID_HOST_FLAG;
    this.localSessionHi = this.nextHostSessionId++;
    this.localSessionLo = clientLo;

    const nonce = await randomBytes(8);
    this.assertSession(generation);
    this.localNonce = nonce;

    const security = this.security;
    const point = security.publicPoint;
    const response = new CdpConnectionResponse();
    response.result = CdpConnectionResult.Pending;
    response.hmacSize = request.hmacSize;
    response.messageFragmentSize = request.messageFragmentSize;
    response.nonceBytes = this.localNonce;
    response.publicKeyX = point.x;
    response.publicKeyY = point.y;
    await this.sendConnection(header, CdpConnectionType.ConnectResponse, response);
    this.assertSession(generation);

    const secret = await security.deriveSharedSecret(request.publicKeyX, request.publicKeyY);
    this.assertSession(generation);
    this.cryptor = CdpSecurity.createCryptor(secret);
    Lg.i(LOG_TAG + ': session cryptor established');
    this.listener.onStatus('CDP 握手：会话加密已建立');
  }

  private async handleDeviceAuth(header: CdpCommonHeader, reader: CdpReader, connectionType: number): Promise<void> {
    const generation = this.sessionGeneration;
    if (this.cryptor === undefined) {
      throw new Error('CDP auth before encryption');
    }
    const payload = CdpAuthenticationPayload.parse(reader);
    Lg.i(LOG_TAG + ': received DeviceAuth');
    const ok = await this.security.verifyThumbprint(payload.certificate, payload.signedThumbprint, this.localNonce, this.remoteNonce);
    this.assertSession(generation);
    Lg.i(LOG_TAG + ': DeviceAuth verify=' + ok);
    if (!ok) { throw new Error('CDP 认证失败：证书签名校验不通过'); }
    this.deviceAuthenticated = true;
    const responseType = connectionType === CdpConnectionType.DeviceAuthRequest
      ? CdpConnectionType.DeviceAuthResponse
      : CdpConnectionType.UserDeviceAuthResponse;
    try {
      const authResponse = new CdpAuthenticationPayload();
      authResponse.certificate = this.security.certificateDer;
      authResponse.signedThumbprint = await this.security.signThumbprint(this.localNonce, this.remoteNonce);
      this.assertSession(generation);
      await this.sendConnection(header, responseType, authResponse);
      this.listener.onStatus('CDP 认证：设备证书已完成交换');
      Lg.i(LOG_TAG + ': sent ' + (responseType === CdpConnectionType.DeviceAuthResponse ? 'DeviceAuthResponse' : 'UserDeviceAuthResponse'));
    } catch (error) {
      Lg.w(LOG_TAG + ': DeviceAuth response error: ' + (error instanceof Error ? (error.stack ?? error.message) : JSON.stringify(error)));
    }
  }

  private handleAuthDone(header: CdpCommonHeader): void {
    Lg.i(LOG_TAG + ': received AuthDoneRequest (over ' + (this.useBt ? 'BT' : 'TCP') + ')');
    if (!this.deviceAuthenticated) { throw new Error('CDP 设备尚未认证'); }
    const result = new CdpResultPayload(CdpResult.Success);
    this.sendConnection(header, CdpConnectionType.AuthDoneRespone, result).catch((error: Error): void => {
      this.listener.onStatus('AuthDone 响应失败：' + error.message);
    });
  }

  private async handleDeviceInfo(header: CdpCommonHeader, reader: CdpReader): Promise<void> {
    const msg = CdpDeviceInfoMessage.parse(reader);
    Lg.i(LOG_TAG + ': received DeviceInfoMessage (over ' + (this.useBt ? 'BT' : 'TCP') + ')');
    try {
      const parsed = JSON.parse(msg.deviceInfoJson) as CdpDeviceInfoJson;
      this.peerName = parsed.name ?? 'Windows';
      this.listener.onPeerConnected(this.peerName);
      this.listener.onStatus('已连接 Windows 设备：' + this.peerName);
    } catch (error) {
      this.peerName = 'Windows';
    }
    const ack = new CdpDeviceInfoMessage();
    ack.deviceInfoJson = buildDeviceInfoJson(this.ownIp, this.deviceName);
    await this.sendConnection(header, CdpConnectionType.DeviceInfoResponseMessage, ack);
  }

  private async handleControl(header: CdpCommonHeader, payload: Uint8Array): Promise<void> {
    const reader = new CdpReader(payload);
    const controlType = reader.readU8();
    if (controlType !== CdpControlMessageType.StartChannelRequest) {
      return;
    }
    const request = CdpStartChannelRequest.parse(reader);
    Lg.i(LOG_TAG + ': received StartChannelRequest app=' + request.id + ' name=' + request.name);
    const channel = this.createChannel(this.nextChannelId++, request.id, request.name);
    const response = new CdpStartChannelResponse();
    response.result = channel !== undefined ? CdpChannelResult.Success : CdpChannelResult.Failure_NotFound;
    response.channelId = channel !== undefined ? channel.id : 0;
    Lg.i(LOG_TAG + ': respond StartChannelResponse result=' + response.result + ' channelId=' + response.channelId);
    await this.sendControl(header, channel, response);
  }

  private async handleSession(header: CdpCommonHeader, payload: Uint8Array): Promise<void> {
    const reader = new CdpReader(payload);
    const binaryHeader = reader.readBinaryMsgHeader();
    const valueSet = CdpValueSet.parse(reader.readRemaining());
    this.currentMessageId = binaryHeader.messageId;
    const channelId = readU32BE(header.channelId, 4);
    for (const channel of this.channels) {
      if (channel.id === channelId) {
        this.activeChannelId = channelId;
        await channel.handleMessage(binaryHeader, valueSet);
        return;
      }
    }
  }

  private createChannel(id: number, appId: string, appName: string): FunctionalChannel | undefined {
    if (appId.toUpperCase() === APP_HANDSHAKE_ID.toUpperCase()) {
      const channel = new CdpFunctionalChannel(id, appId, (header: CdpBinaryMsgHeader, payload: CdpValueSet): Promise<void> =>
        this.handleHandshake(header, payload));
      this.channels.push(channel);
      return channel;
    }
    if (appName === APP_PLATFORM_NAME) {
      const channel = new CdpFunctionalChannel(id, appId, (header: CdpBinaryMsgHeader, payload: CdpValueSet): Promise<void> =>
        this.handleNearShare(header, payload));
      this.channels.push(channel);
      return channel;
    }
    return undefined;
  }

  private async handleHandshake(header: CdpBinaryMsgHeader, payload: CdpValueSet): Promise<void> {
    const control = payload.getUInt32('ControlMessage');
    if (control === 6) { // HandShakeRequest
      const operationId = payload.getGuid('OperationId');
      Lg.i(LOG_TAG + ': received HandShakeRequest operationId=' + operationId);
      const response = new CdpValueSet();
      response.addUInt32('SelectedPlatformVersion', 1);
      response.addUInt32('VersionHandShakeResult', 1);
      await this.sendValueSet(response, 0);
      this.listener.onStatus('CDP 握手应用：平台协商完成');
      Lg.i(LOG_TAG + ': sent HandShakeResponse result=1');
    }
  }

  private async handleNearShare(header: CdpBinaryMsgHeader, payload: CdpValueSet): Promise<void> {
    const control = payload.getUInt32('ControlMessage');
    if (control === 1) { // StartTransfer
      await this.handleStartTransfer(payload);
      return;
    }
    if (control === 4) { // FetchDataResponse
      this.resolveResponse(payload);
      return;
    }
    if (control === 5 && !this.networkDone) { // CancelTransfer
      this.abortTransfer('Windows 对端取消了传输');
    }
  }

  private async handleStartTransfer(payload: CdpValueSet): Promise<void> {
    if (this.pendingIncoming.length > 0 || this.accepted) { return; }
    const generation = this.sessionGeneration;
    const bytesToSend = payload.getUInt64('BytesToSend');
    const fileNames = payload.getStringArray('FileNames');
    const contentIds = payload.getUInt32Array('ContentIds');
    const contentSizes = payload.getUInt64Array('ContentSizes');
    Lg.i(LOG_TAG + ': received StartTransfer from "' + this.peerName + '" bytes=' + bytesToSend
      + ' files=' + fileNames.length + ' names=' + fileNames.join(','));
    if (fileNames.length === 0 || contentSizes.length !== fileNames.length) {
      throw new Error('Windows 传输请求缺少文件或大小');
    }
    const files: WindowsNearbyIncomingFile[] = [];
    const seenIds: Set<number> = new Set<number>();
    let total = 0;
    for (let i = 0; i < fileNames.length; i++) {
      const id = i < contentIds.length ? contentIds[i] : i;
      const size = contentSizes[i];
      if (seenIds.has(id) || !Number.isSafeInteger(size) || size < 0 || !Number.isSafeInteger(total + size)) {
        throw new Error('Windows 传输请求含有重复编号或无效大小');
      }
      seenIds.add(id);
      total += size;
      files.push({ name: fileNames[i], size, contentId: id });
    }
    this.pendingIncoming = files;
    this.bytesToSend = total;
    this.bytesReceived = 0;
    const accepted = await this.listener.onIncomingTransfer(this.peerName, files);
    this.assertSession(generation);
    this.accepted = accepted;
    Lg.i(LOG_TAG + ': onIncomingTransfer accepted=' + this.accepted);
    if (!this.accepted) {
      const cancel = new CdpValueSet();
      cancel.addUInt32('ControlMessage', 5);
      this.pendingIncoming = [];
      await this.sendValueSet(cancel, 11);
      return;
    }
    this.openFiles(files);
    this.assertSession(generation);
    this.listener.onStatus('已接收 ' + files.length + ' 个文件，开始拉取数据');
    await this.pullNextFile();
  }

  private openFiles(files: WindowsNearbyIncomingFile[]): void {
    const dir = this.context.filesDir + '/incoming/windowsnearby';
    if (!fs.accessSync(dir)) { fs.mkdirSync(dir, true); }
    const batchDir = fs.mkdtempSync(dir + '/batch-XXXXXX');
    for (let index = 0; index < files.length; index++) {
      const file = files[index];
      const path = batchDir + '/' + index + '-' + GalleryMediaClassifier.safeFileName(file.name);
      const fd = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE).fd;
      this.pendingFiles.push({ contentId: file.contentId, name: file.name, size: file.size, path, fd, complete: false });
    }
  }

  private async pullNextFile(): Promise<void> {
    const generation = this.sessionGeneration;
    for (const file of this.pendingFiles) {
      this.assertSession(generation);
      let position = 0;
      while (position < file.size) {
        const length = Math.min(CDP_PARTITION_SIZE, file.size - position);
        const request = new CdpValueSet();
        request.addUInt32('ControlMessage', 3); // FetchDataRequest
        request.addUInt64('BlobPosition', position);
        request.addUInt32('BlobSize', length);
        request.addUInt32('ContentId', file.contentId);
        // 先注册响应等待器，避免高速对端在 send 完成前返回数据而丢失唤醒。
        const pendingResponse = this.awaitResponse();
        this.sendValueSet(request, this.currentMessageId).catch((error: Error): void => {
          if (generation === this.sessionGeneration) { this.abortTransfer(error.message); }
        });
        const response = await pendingResponse;
        this.assertSession(generation);
        await this.writeResponse(file, response, position, length);
        this.assertSession(generation);
        if (this.finished) { throw new Error('Windows 接收会话已结束'); }
        position += length;
        this.bytesReceived += length;
        this.listener.onProgress(this.bytesToSend === 0 ? 99.9 : Math.min(99.9, this.bytesReceived * 100 / this.bytesToSend));
      }
      fs.closeSync(file.fd);
      file.fd = -1;
      file.complete = true;
    }
    await this.finishTransfer(generation);
  }

  private async writeResponse(file: PendingFile, response: CdpValueSet, expectedPosition: number,
    expectedLength: number): Promise<void> {
    const position = response.getUInt64('BlobPosition');
    const blob = response.getUInt8Array('DataBlob');
    if (response.getUInt32('ContentId') !== file.contentId || position !== expectedPosition
      || blob.length !== expectedLength || position + blob.length > file.size) {
      throw new Error('Windows 文件数据不完整或与请求不匹配');
    }
    fs.lseek(file.fd, position, fs.WhenceType.SEEK_SET);
    const written: number = await fs.write(file.fd, ByteUtils.toArrayBuffer(blob));
    if (written !== blob.length) {
      throw new Error('接收文件写入不完整');
    }
  }

  private async finishTransfer(generation: number): Promise<void> {
    this.assertSession(generation);
    if (!this.accepted || this.bytesReceived !== this.bytesToSend
      || this.pendingFiles.length !== this.pendingIncoming.length
      || this.pendingFiles.some((file: PendingFile): boolean => !file.complete)) {
      throw new Error('Windows 文件尚未完整接收');
    }
    this.networkDone = true;
    const complete = new CdpValueSet();
    complete.addUInt32('ControlMessage', 2); // CompleteTransfer
    try { await this.sendValueSet(complete, this.currentMessageId); }
    catch (error) { Lg.w(LOG_TAG + ': 完成回执无法发送：' + String(error)); }

    for (const file of this.pendingFiles) {
      this.assertSession(generation);
      await this.listener.onFileReceived({ name: file.name, size: file.size, contentId: file.contentId }, file.path);
    }
    this.assertSession(generation);
    this.finished = true;
    this.pendingFiles = [];
    this.pendingIncoming = [];
    this.releaseBtClient();
    this.listener.onStatus('Windows Nearby 已接收全部文件');
    this.listener.onCompleted();
  }

  /**
   * 新会话开始前清空上一会话的全部残留状态，避免第二次传输错乱：
   * cryptor / nonce / 会话与频道 id / 序号 / 频道表 / 待收文件 / 拉取游标等。
   * 调用方随后按需设置 useBt / upgradingToTcp。
   */
  private resetSession(): void {
    this.abortTransfer('Windows 接收会话已替换');
    if (this.responseTimer !== -1) {
      clearTimeout(this.responseTimer);
      this.responseTimer = -1;
    }
    this.responseReject = undefined;
    // 上一会话异常中止时可能残留未关闭的文件句柄。
    for (const file of this.pendingFiles) {
      try {
        fs.closeSync(file.fd);
      } catch (error) {
        Lg.w(LOG_TAG + ': resetSession close file failed: ' + JSON.stringify(error));
      }
    }
    this.cryptor = undefined;
    this.deviceAuthenticated = false;
    this.networkDone = false;
    this.localNonce = new Uint8Array(8);
    this.remoteNonce = new Uint8Array(8);
    this.localSessionHi = 0;
    this.localSessionLo = 0;
    this.nextHostSessionId = 1;
    this.nextChannelId = 1;
    this.seq = 0;
    this.activeChannelId = 0;
    this.peerName = '';
    this.channels = [];
    this.pendingFiles = [];
    this.pendingIncoming = [];
    this.bytesToSend = 0;
    this.bytesReceived = 0;
    this.accepted = false;
    this.currentMessageId = 0;
    this.waitResponse = undefined;
    this.finished = false;
    this.fragMap.clear();
  }

  /** 关闭并释放当前蓝牙客户端会话，使下一次 RFCOMM 连接能够被接受。 */
  private releaseBtClient(): void {
    if (this.btClientSocket >= 0) {
      try {
        bluetoothSocket.off('sppRead', this.btClientSocket);
      } catch (error) {
        Lg.w(LOG_TAG + ': bt sppRead off failed: ' + JSON.stringify(error));
      }
      try {
        bluetoothSocket.sppCloseClientSocket(this.btClientSocket);
      } catch (error) {
        Lg.w(LOG_TAG + ': bt client close failed: ' + JSON.stringify(error));
      }
      this.btClientSocket = -1;
    }
    this.useBt = false;
    this.upgradingToTcp = false;
    this.buffer = new Uint8Array(0);
    this.fragMap.clear();
  }

  private async sendConnection(header: CdpCommonHeader, connectionType: number, body: CdpConnectionBody): Promise<void> {
    const payloadWriter = new CdpWriter();
    new CdpConnectionHeader(connectionType, CdpConnectionMode.Proximal).write(payloadWriter);
    body.write(payloadWriter);
    const outHeader = this.newHeader(CdpMessageType.Connect);
    // The reference host echoes the client's capability headers back in the
    // ConnectResponse so the peer knows the exchange supports the transport
    // upgrade (PeerCapabilities=0x82, Header131=0x83). Without this echo Windows
    // treats the host as not-upgradeable and never sends an UpgradeRequest.
    for (const additional of header.additionalHeaders) {
      if (additional.type === CdpAdditionalHeaderType.None || additional.type === CdpAdditionalHeaderType.ReplyToId) {
        continue;
      }
      outHeader.additionalHeaders.push(new CdpAdditionalHeader(additional.type, additional.value.slice()));
    }
    await this.sendPayload(outHeader, payloadWriter.finish());
  }

  private async sendControl(header: CdpCommonHeader, channel: FunctionalChannel | undefined, response: CdpStartChannelResponse): Promise<void> {
    const payloadWriter = new CdpWriter();
    payloadWriter.writeU8(CdpControlMessageType.StartChannelResponse);
    response.write(payloadWriter);
    const outHeader = this.newHeader(CdpMessageType.Control);
    if (readU32BE(header.requestId, 4) > 0 || readU32BE(header.requestId, 0) > 0) {
      outHeader.setReplyToId(header.requestId.slice());
      outHeader.additionalHeaders.push(new CdpAdditionalHeader(129, ByteUtils.fromHex('30000001')));
    }
    await this.sendPayload(outHeader, payloadWriter.finish());
  }

  private async sendValueSet(valueSet: CdpValueSet, messageId: number): Promise<void> {
    const binaryHeader = new CdpBinaryMsgHeader(messageId);
    const payloadWriter = new CdpWriter();
    binaryHeader.fragmentCount = 1;
    binaryHeader.fragmentIndex = 0;
    payloadWriter.writeU32BE(binaryHeader.fragmentCount);
    payloadWriter.writeU32BE(binaryHeader.fragmentIndex);
    payloadWriter.writeU32BE(binaryHeader.messageId);
    payloadWriter.writeBytes(valueSet.serialize());
    const outHeader = this.newChannelHeader();
    const extra = new CdpAdditionalHeader(CdpAdditionalHeaderType.CorrelationVector, ByteUtils.encodeText('0000000000000000'));
    outHeader.additionalHeaders.push(extra);
    await this.sendPayload(outHeader, payloadWriter.finish());
  }

  private newHeader(type: number): CdpCommonHeader {
    const header = new CdpCommonHeader();
    header.type = type;
    if (type !== CdpMessageType.Connect) {
      header.sequenceNumber = ++this.seq;
    }
    header.sessionId = this.sessionIdBytes();
    return header;
  }

  private newChannelHeader(): CdpCommonHeader {
    const header = this.newHeader(CdpMessageType.Session);
    writeU32BE(header.channelId, 4, this.activeChannelId);
    return header;
  }

  private async sendPayload(header: CdpCommonHeader, payload: Uint8Array): Promise<void> {
    const generation = this.sessionGeneration;
    if (this.cryptor !== undefined) {
      const frame = await this.cryptor.encryptMessage(header, payload);
      this.assertSession(generation);
      await this.writeToPeer(frame);
    } else {
      const writer = new CdpWriter();
      header.setPayloadLength(payload.length);
      header.sessionId = header.sessionId.length === 8 ? header.sessionId : this.sessionIdBytes();
      writer.writeHeader(header);
      const frame = ByteUtils.concat([writer.finish(), payload]);
      await this.writeToPeer(frame);
    }
  }

  private async writeToPeer(frame: Uint8Array): Promise<void> {
    if (this.useBt && this.btClientSocket >= 0) {
      try {
        await bluetoothSocket.sppWriteAsync(this.btClientSocket, ByteUtils.toArrayBuffer(frame));
        return;
      } catch (error) {
        Lg.w(LOG_TAG + ': bt write failed: ' + JSON.stringify(error));
        throw new Error('CDP bt write failed: ' + (error instanceof Error ? error.message : JSON.stringify(error)));
      }
    }
    if (this.conn === undefined) {
      throw new Error('CDP no connection to write');
    }
    await this.conn.send({ data: ByteUtils.toArrayBuffer(frame) });
  }

  /** CDP Proximal Transport over Bluetooth RFCOMM (the transport Windows picks
   *  when it sees a Bluetooth-oriented BLE beacon). */
  private startBluetoothListener(): void {
    const generation = this.lifecycleGeneration;
    try {
      bluetoothSocket.sppListen(
        'CDP Proximal Transport',
        { uuid: 'c7f94713-891e-496a-a0e7-983a0946126e', type: bluetoothSocket.SppType.SPP_RFCOMM, secure: false },
        (error: BusinessError, serverSocket: number): void => {
          if (error) {
            Lg.w(LOG_TAG + ': bt sppListen failed code=' + error.code + ', message=' + error.message);
            return;
          }
          if (!this.running || generation !== this.lifecycleGeneration) {
            try { bluetoothSocket.sppCloseServerSocket(serverSocket); } catch (_) {}
            return;
          }
          this.btServerSocket = serverSocket;
          Lg.i(LOG_TAG + ': bt RFCOMM server listening (c7f94713...)');
          this.acceptBt();
        }
      );
    } catch (error) {
      Lg.w(LOG_TAG + ': bt listener start failed: ' + JSON.stringify(error));
    }
  }

  private acceptBt(): void {
    if (this.btServerSocket < 0) {
      return;
    }
    try {
      const serverSocket = this.btServerSocket;
      const generation = this.lifecycleGeneration;
      bluetoothSocket.sppAccept(serverSocket, (btError: BusinessError, clientSocket: number): void => {
        if (btError) {
          Lg.w(LOG_TAG + ': bt sppAccept failed code=' + btError.code + ', message=' + btError.message);
          return;
        }
        if (!this.running || generation !== this.lifecycleGeneration || this.btServerSocket !== serverSocket) {
          try { bluetoothSocket.sppCloseClientSocket(clientSocket); } catch (_) {}
          return;
        }
        this.acceptBt();
        this.handleBtClient(clientSocket);
      });
    } catch (error) {
      Lg.w(LOG_TAG + ': bt sppAccept call failed: ' + JSON.stringify(error));
    }
  }

  private handleBtClient(clientSocket: number): void {
    if (this.btClientSocket >= 0 || (!this.finished && (this.accepted || this.pendingIncoming.length > 0))) {
      try {
        bluetoothSocket.sppCloseClientSocket(clientSocket);
      } catch (error) {
        Lg.w(LOG_TAG + ': bt dup client close failed: ' + JSON.stringify(error));
      }
      return;
    }
    // 新会话：清空上一会话残留（cryptor/序号/频道/待收文件等），避免第二次传输错乱。
    this.resetSession();
    this.btClientSocket = clientSocket;
    this.useBt = true;
    this.buffer = new Uint8Array(0);
    this.upgradingToTcp = false;
    this.sessionCount++;
    Lg.i(LOG_TAG + ': session #' + this.sessionCount + ' start (transport=BT)');
    this.listener.onStatus('Windows 正尝试通过蓝牙建立 CDP 连接');
    Lg.i(LOG_TAG + ': bt client connected, routing CDP');
    bluetoothSocket.on('sppRead', clientSocket, (data: ArrayBuffer): void => {
      if (this.btClientSocket !== clientSocket) { return; }
      this.onData(new Uint8Array(data));
    });
  }

  private async awaitResponse(): Promise<CdpValueSet> {
    if (this.finished) { throw new Error('Windows 接收会话已结束'); }
    return new Promise<CdpValueSet>((resolve: (value: CdpValueSet) => void, reject: (error: Error) => void): void => {
      this.waitResponse = resolve;
      this.responseReject = reject;
      this.responseTimer = setTimeout((): void => {
        this.responseTimer = -1;
        this.abortTransfer('Windows 文件数据等待超时');
      }, 120000);
    });
  }

  private resolveResponse(valueSet: CdpValueSet): void {
    if (this.waitResponse !== undefined) {
      const resolve = this.waitResponse;
      this.waitResponse = undefined;
      this.responseReject = undefined;
      if (this.responseTimer !== -1) {
        clearTimeout(this.responseTimer);
        this.responseTimer = -1;
      }
      resolve(valueSet);
    }
  }

  private abortTransfer(reason: string): void {
    this.sessionGeneration += 1;
    if (this.finished) { return; }
    const hadTransfer = this.accepted || this.pendingFiles.length > 0 || this.pendingIncoming.length > 0;
    this.finished = true;
    this.accepted = false;
    if (this.responseTimer !== -1) {
      clearTimeout(this.responseTimer);
      this.responseTimer = -1;
    }
    const reject: ((error: Error) => void) | undefined = this.responseReject;
    this.responseReject = undefined;
    this.waitResponse = undefined;
    reject?.(new Error(reason));
    for (const file of this.pendingFiles) {
      if (file.fd >= 0) {
        try { fs.closeSync(file.fd); } catch (error) { Lg.w(LOG_TAG + ': failed transfer close: ' + String(error)); }
      }
      if (!file.complete) {
        try { fs.unlinkSync(file.path); } catch (error) { Lg.w(LOG_TAG + ': failed partial cleanup: ' + String(error)); }
      }
    }
    this.pendingFiles = [];
    this.pendingIncoming = [];
    this.releaseBtClient();
    if (hadTransfer) {
      this.listener.onFailed(reason);
      this.listener.onStatus('Windows Nearby 接收失败：' + reason);
    }
  }

  private assertSession(generation: number): void {
    if (generation !== this.sessionGeneration || this.finished || !this.running) {
      throw new Error('Windows 接收会话已结束');
    }
  }

  private sessionIdBytes(): Uint8Array {
    const bytes = new Uint8Array(8);
    // Host session id = (hostId << 32) | (clientId | HOST_FLAG): the host bit
    // lives in the LOW dword (SessionId.AsNumber), matching the reference.
    writeU32BE(bytes, 0, this.localSessionHi);
    writeU32BE(bytes, 4, this.localSessionLo | SESSION_ID_HOST_FLAG);
    return bytes;
  }
}

interface CdpDeviceInfoJson {
  readonly name?: string;
}

function buildDeviceInfoJson(ip: string, name: string): string {
  const endpoints = ip.length > 0
    ? '[{"endpointType":2,"host":"' + ip + '","service":"5040"}]'
    : '[]';
  return '{"DeduplicationHint":"","connectionModes":1,"deviceId":"","endpoints":' + endpoints
    + ',"name":"' + name + '","type":8}';
}

function readU32BE(bytes: Uint8Array, offset: number): number {
  return ((bytes[offset] * 0x1000000) + (bytes[offset + 1] << 16) + (bytes[offset + 2] << 8) + bytes[offset + 3]) >>> 0;
}

function writeU32BE(bytes: Uint8Array, offset: number, value: number): void {
  bytes[offset] = (value >>> 24) & 0xff;
  bytes[offset + 1] = (value >>> 16) & 0xff;
  bytes[offset + 2] = (value >>> 8) & 0xff;
  bytes[offset + 3] = value & 0xff;
}

async function randomBytes(length: number): Promise<Uint8Array> {
  const random = cryptoFramework.createRandom();
  const blob = await random.generateRandom(length);
  return new Uint8Array(blob.data);
}

function parseCommonHeaderSafe(frame: Uint8Array): CdpCommonHeader {
  const reader = new CdpReader(frame);
  const header = reader.readHeader();
  return header;
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

/** Build a CDP UDP PresenceResponse advertising the phone network endpoint. */
async function buildPresenceResponseFrame(name: string): Promise<Uint8Array> {
  const salt = Math.floor(Math.random() * 0x7fffffff);
  const saltLE = new Uint8Array(4);
  saltLE[0] = salt & 0xff;
  saltLE[1] = (salt >>> 8) & 0xff;
  saltLE[2] = (salt >>> 16) & 0xff;
  saltLE[3] = (salt >>> 24) & 0xff;
  const nameBytes = ByteUtils.encodeText(name);
  const md = cryptoFramework.createMd('SHA256');
  await md.update({ data: ByteUtils.concat([saltLE, nameBytes]) });
  const digest = await md.digest();
  const hashBytes = new Uint8Array(digest.data);

  const bodyWriter = new CdpWriter();
  bodyWriter.writeU8(1); // DiscoveryType.PresenceResponse
  bodyWriter.writeI16BE(1); // ConnectionMode.Proximal
  bodyWriter.writeI16BE(8); // DeviceType.Android
  bodyWriter.writeStringWithLength(name);
  bodyWriter.writeU32BE(salt);
  bodyWriter.writeBytes(hashBytes);
  const body = bodyWriter.finish();

  const header = new CdpCommonHeader();
  header.type = CdpMessageType.Discovery;
  header.setPayloadLength(body.length);
  const frameWriter = new CdpWriter();
  frameWriter.writeHeader(header);
  frameWriter.writeBytes(body);
  return frameWriter.finish();
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
