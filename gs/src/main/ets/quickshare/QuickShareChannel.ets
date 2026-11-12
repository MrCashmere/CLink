import fs from '@ohos.file.fs';
import { socket } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { GsBytes } from '../util/GsBytes';
import { GsCrypto } from '../util/GsCrypto';
import { GsTransport, GsTransports } from '../util/GsTransport';
import { GsDevice, GsIncomingFile, GsOutgoingFile, GsReceiveHooks, GsSendHooks, GsSessionFileMeta, GsStreamConnection, GsTransportChange, WifiDirectUpgradeCredentials } from '../model/GsTypes';
import { GS_QUICKSHARE_PORT } from '../model/GsConstants';
import { UKEY2Handshake } from './UKEY2Handshake';
import { BandwidthUpgrade, BandwidthUpgradeDecoded, BandwidthUpgradeEvent, BandwidthUpgradeMedium, WifiDirectCredentialOffer } from './BandwidthUpgrade';
import { NearDropWire, OfflineType, PayloadFile, SharingType, SharingDecoded, OfflineDecoded, PayloadTransferDecoded, PayloadDecoded, PayloadPacket } from './NearDropWire';
import { NearbyCapabilities, NearbyCapabilitySnapshot } from './NearbyCapabilities';
import { ProtoReader } from './ProtoReader';
import { ProtoWire } from './ProtoWire';
import { GsFrameInbox } from '../util/GsFrameInbox';

function ukey2Alert(frame: Uint8Array): string | undefined {
  const type: number | undefined = ProtoReader.firstVarint(frame, 1);
  if (type === undefined || type !== 1) return undefined;
  try {
    const inner: Uint8Array | undefined = ProtoReader.firstBytes(frame, 2);
    if (inner === undefined) return undefined;
    const alertBody: Uint8Array | undefined = ProtoReader.firstBytes(inner, 2);
    if (alertBody === undefined) return undefined;
    const alertType: number = ProtoReader.firstVarint(alertBody, 1) ?? 0;
    const alertMessage: string = GsBytes.decodeText(ProtoReader.firstBytes(alertBody, 2) ?? new Uint8Array(0));
    return 'UKEY2 alert type=' + alertType + ' message=' + alertMessage;
  } catch (error) {
    return undefined;
  }
}

const CHUNK_SIZE: number = 512 * 1024;
// 主动升级的两个有界等待：建组等太久会拖住会话，迁不过来也必须继续在旧通道上把文件收完。
const P2P_GROUP_WAIT_MS: number = 4000;
const P2P_UPGRADE_WAIT_MS: number = 10000;
const TIMEOUT: number = 150000;
interface WireFramePair { readonly key: number; readonly value: Uint8Array; }
export interface ReceiverConnection {
  sendBytes(data: Uint8Array): Promise<void>;
  onData(listener: (chunk: Uint8Array) => void): void;
  onClose?(listener: () => void): void;
  close(): void;
}
interface ReadFrameResult { readonly frame: Uint8Array; readonly raw: Uint8Array; }
class TcpReceiverConnection implements ReceiverConnection {
  private readonly conn: socket.TCPSocketConnection;
  private dataListener?: (chunk: Uint8Array) => void;
  private closeListener?: () => void;
  private closed: boolean = false;

  constructor(conn: socket.TCPSocketConnection) {
    this.conn = conn;
    conn.on('message', (info: socket.SocketMessageInfo): void => this.dataListener?.(new Uint8Array(info.message)));
    conn.on('close', (): void => this.markClosed());
    conn.on('error', (): void => this.close());
  }

  sendBytes(data: Uint8Array): Promise<void> { return this.conn.send({ data: GsBytes.toArrayBuffer(data) }); }
  onData(listener: (chunk: Uint8Array) => void): void { this.dataListener = listener; }
  onClose(listener: () => void): void {
    this.closeListener = listener;
    if (this.closed) { listener(); }
  }
  close(): void {
    if (this.closed) { return; }
    this.markClosed();
    this.conn.close().catch((): void => undefined);
  }
  private markClosed(): void {
    if (this.closed) { return; }
    this.closed = true;
    this.dataListener = undefined;
    this.closeListener?.();
  }
}
class StreamTransport implements GsTransport {
  private readonly conn: GsStreamConnection;
  constructor(conn: GsStreamConnection) { this.conn = conn; }
  send(data: Uint8Array): Promise<void> { return this.conn.sendBytes(data); }
  onData(listener: (chunk: Uint8Array) => void): void { this.conn.onData(listener); }
  onClose(listener: () => void): void { this.conn.onClose?.(listener); }
  close(): Promise<void> { this.conn.close(); return Promise.resolve(); }
}
class ReceiverSession {
  readonly inbox: WireInbox = new WireInbox();
  readonly handshake: UKEY2Handshake = new UKEY2Handshake('server');
  readonly hooks: GsReceiveHooks;
  activeConn: ReceiverConnection;
  peerEndpointId: string = '';
  consentKey: string = '';
  accepted: boolean = false;
  upgraded: boolean = false;
  upgradeResolve?: (migrated: boolean) => void;

  constructor(conn: ReceiverConnection, hooks: GsReceiveHooks) {
    this.activeConn = conn;
    this.hooks = hooks;
    this.bind(conn);
  }
  send(bytes: Uint8Array): Promise<void> { return this.activeConn.sendBytes(bytes); }
  private bind(conn: ReceiverConnection): void {
    conn.onData((chunk: Uint8Array): void => {
      if (this.activeConn === conn) { this.inbox.push(chunk); }
    });
    conn.onClose?.((): void => {
      if (this.activeConn === conn) { this.inbox.end(new Error('对端连接已断开')); }
    });
  }
  rewire(conn: ReceiverConnection): void {
    const old: ReceiverConnection = this.activeConn;
    this.activeConn = conn;
    this.upgraded = true;
    this.bind(conn);
    if (old !== conn) { old.close(); }
  }
}

class WireInbox {
  private readonly inbox: GsFrameInbox<Uint8Array> = new GsFrameInbox<Uint8Array>();
  private buffer: Uint8Array = new Uint8Array(0);
  private queuedBytes: number = 0;
  private failure?: Error;

  push(chunk: Uint8Array): void {
    if (this.failure !== undefined) { return; }
    if (this.queuedBytes + this.buffer.length + chunk.length > 32 * 1024 * 1024) {
      this.end(new Error('Quick Share 数据队列超过上限'), true);
      return;
    }
    try {
      this.buffer = GsBytes.concat([this.buffer, chunk]);
      while (this.buffer.length >= 4) {
        const len: number = GsBytes.readU32BE(this.buffer, 0);
        if (len === 0 || len > 16 * 1024 * 1024) { throw new Error('Quick Share 无效帧长度'); }
        if (this.buffer.length < len + 4) { return; }
        const body: Uint8Array = this.buffer.slice(4, len + 4);
        this.buffer = this.buffer.slice(len + 4);
        const key: number = WireInbox.key(body);
        this.queuedBytes += body.length + 4;
        this.inbox.deliver(key, body);
      }
    } catch (error) {
      this.end(error instanceof Error ? error : new Error(String(error)), true);
    }
  }

  end(error: Error, discard: boolean = false): void {
    if (this.failure !== undefined) { return; }
    this.failure = error;
    this.buffer = new Uint8Array(0);
    if (discard) {
      this.inbox.reset();
      this.queuedBytes = 0;
    } else {
      this.inbox.rejectWaiters(error);
    }
  }

  async next(key: number, timeoutMs: number = TIMEOUT): Promise<Uint8Array> {
    if (this.failure !== undefined && this.inbox.queuedCount(key) === 0) { throw this.failure; }
    const value: Uint8Array = await this.inbox.next(key, timeoutMs);
    this.queuedBytes = Math.max(0, this.queuedBytes - value.length - 4);
    return value;
  }

  queuedCount(key: number): number { return this.inbox.queuedCount(key); }
  async nextAny(keys: number[]): Promise<WireFramePair> {
    const deadline: number = Date.now() + TIMEOUT;
    while (Date.now() < deadline) {
      for (const key of keys) {
        if (this.inbox.queuedCount(key) > 0) { return { key, value: await this.next(key) }; }
      }
      if (this.failure !== undefined) { throw this.failure; }
      await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 50); });
    }
    throw new Error('timeout waiting for frame ' + keys.join(','));
  }

  static key(frame: Uint8Array): number {
    const type: number | undefined = ProtoReader.firstVarint(frame, 1);
    // UKEY2 messages (ClientInit=2, ServerInit=3, ClientFinish=4). An OfflineFrame
    // version is always 1, so 2..4 is unambiguous.
    if (type !== undefined && type >= 2 && type <= 4) return 100 + type;
    if (type === 1) {
      // Could be an OfflineFrame (version=1) or a UKEY2 Alert (message_type=1).
      const offline = NearDropWire.tryParseOfflineFrame(frame);
      if (offline !== undefined && offline.type > 0) return offline.type;
      // Not a parseable OfflineFrame; treat as a UKEY2 Alert when message_data exists.
      if (ProtoReader.firstBytes(frame, 2) !== undefined) return 101;
      console.warn('Quick Share unhandled frame inline type=1 len=' + frame.length);
      return 0;
    }
    // Encrypted SecureMessage(headerAndBody=1, signature=2) carries no leading
    // varint field 1; map it to the payload-transfer bucket used by the caller.
    if (type === undefined && ProtoReader.firstBytes(frame, 1) !== undefined && ProtoReader.firstBytes(frame, 2) !== undefined) return 3;
    const offline = NearDropWire.tryParseOfflineFrame(frame);
    if (offline !== undefined && offline.type > 0) return offline.type;
    console.warn('Quick Share unhandled frame fallback len=' + frame.length);
    return 0;
  }
}
export enum QuickShareReceiverState { initial = 'initial', receivedConnectionRequest = 'receivedConnectionRequest', sentUkeyServerInit = 'sentUkeyServerInit', receivedUkeyClientFinish = 'receivedUkeyClientFinish', sentConnectionResponse = 'sentConnectionResponse', sentPairedKeyResult = 'sentPairedKeyResult', receivedPairedKeyResult = 'receivedPairedKeyResult', waitingForUserConsent = 'waitingForUserConsent', receivingFiles = 'receivingFiles', disconnected = 'disconnected' }

export class QuickShareChannel {
  async send(device: GsDevice, files: GsOutgoingFile[], hooks: GsSendHooks, peerName: string): Promise<void> {
    const transport: GsTransport = await GsTransports.open(device.address, device.port > 0 ? device.port : GS_QUICKSHARE_PORT, false, hooks.sourceAddress);
    try {
      await this.runSend(transport, device, files, hooks, peerName);
    } finally {
      await transport.close();
    }
  }

  /**
   * Runs the Quick Share sender protocol over a transport-agnostic byte stream
   * (BLE GATT socket, Wi-Fi Direct socket, ...). The physical medium is owned by
   * the caller; the protocol only consumes/produces a stream.
   */
  async sendStream(conn: GsStreamConnection, files: GsOutgoingFile[], hooks: GsSendHooks, peerName: string): Promise<void> {
    const ble: GsDevice = { id: 'ble', name: peerName, model: '', protocol: 'quickshare', address: '', port: 0, https: false, fingerprint: '', source: 'ble' };
    try {
      await this.runSend(new StreamTransport(conn), ble, files, hooks, peerName);
    } finally {
      conn.close();
    }
  }

  private async runSend(transport: GsTransport, device: GsDevice, files: GsOutgoingFile[], hooks: GsSendHooks,
    peerName: string): Promise<void> {
    let t: GsTransport = transport;
    let inboxRef: WireInbox = new WireInbox();
    const initialInbox: WireInbox = inboxRef;
    t.onData((chunk: Uint8Array): void => initialInbox.push(chunk));
    t.onClose?.((): void => initialInbox.end(new Error('Quick Share 对端已断开')));
    const handshake: UKEY2Handshake = new UKEY2Handshake('client');
    const send: (bytes: Uint8Array) => Promise<void> = (bytes: Uint8Array): Promise<void> => t.send(bytes);
    const currentInbox: () => WireInbox = (): WireInbox => inboxRef;
    const localEndpointId: string = hooks.localEndpointId !== undefined && hooks.localEndpointId.length === 4
      ? hooks.localEndpointId : QuickShareChannel.peerEndpointId(device);
    const acceptUpgrade = async (creds: WifiDirectUpgradeCredentials): Promise<boolean> => {
      if (hooks.onWifiDirectTransport === undefined) { return false; }
      let candidate: GsTransport | undefined;
      try {
        const conn: GsStreamConnection | undefined = await hooks.onWifiDirectTransport(creds);
        if (conn === undefined) { throw new Error('未能加入 WLAN 直连组'); }
        candidate = new StreamTransport(conn);
        const newInbox: WireInbox = new WireInbox();
        candidate.onData((chunk: Uint8Array): void => newInbox.push(chunk));
        candidate.onClose?.((): void => newInbox.end(new Error('WLAN 直连连接已断开')));
        await candidate.send(ProtoWire.frame(BandwidthUpgrade.clientIntroduction(localEndpointId)));
        const ack: BandwidthUpgradeDecoded | undefined = BandwidthUpgrade.parse(
          await newInbox.next(OfflineType.BANDWIDTH_UPGRADE_NEGOTIATION, P2P_UPGRADE_WAIT_MS));
        if (ack?.eventType !== BandwidthUpgradeEvent.CLIENT_INTRODUCTION_ACK) {
          throw new Error('未收到 WLAN 直连确认');
        }
        const previous: GsTransport = t;
        t = candidate;
        inboxRef = newInbox;
        candidate = undefined;
        void previous.close();
        QuickShareChannel.reportTransport(hooks.onTransportChange, 'wifi-direct', true, '已升级 WLAN 直连');
        return true;
      } catch (error) {
        console.warn('Quick Share sender upgrade failed: ' + String(error));
        QuickShareChannel.reportTransport(hooks.onTransportChange, 'wifi-lan', false,
          'WLAN 直连升级失败，继续用当前通道');
        return false;
      } finally {
        if (candidate !== undefined) { await candidate.close(); }
      }
    };

    try {
      await handshake.prepare();
      const connectionRequest: Uint8Array = NearDropWire.connectionRequest(localEndpointId, peerName,
        NearDropWire.endpointInfo(peerName, await GsCrypto.randomBytes(16)), new Uint8Array(0));
      await t.send(ProtoWire.frame(connectionRequest));
      await t.send(ProtoWire.frame(await handshake.buildClientInit()));
      const serverInit: Uint8Array = await this.waitServerOrResponse(inboxRef);
      await t.send(ProtoWire.frame(await handshake.buildClientFinish(serverInit)));
      handshake.markVerified();
      const response: OfflineDecoded = NearDropWire.parseOfflineFrame(await inboxRef.next(OfflineType.CONNECTION_RESPONSE));
      if ((ProtoReader.firstVarint(response.body, 3) ?? 0) === 2) { throw new Error('connection rejected'); }
      await t.send(ProtoWire.frame(NearDropWire.connectionAccept()));

      if (hooks.onPin !== undefined && !(await hooks.onPin(handshake.pin))) {
        throw new Error('user cancelled pairing');
      }
      const pcPeer: boolean = hooks.pcPeer === true;
      const payloadFiles: PayloadFile[] = files.map((file: GsOutgoingFile, index: number): PayloadFile => ({
        name: file.name, size: file.size, mimeType: file.mime,
        payloadId: pcPeer ? -NearDropWire.attachmentId() : index + 1
      }));
      const signedData: Uint8Array = await GsCrypto.randomBytes(72);
      const secretIdHash: Uint8Array = await GsCrypto.randomBytes(6);
      await this.sendSharingFrame(send, handshake, NearDropWire.pairedKeyEncryption(signedData, secretIdHash));
      const peerEnc: SharingDecoded = await this.nextSharingFrame(currentInbox, handshake, acceptUpgrade);
      if (peerEnc.type !== SharingType.PAIRED_KEY_ENCRYPTION) { throw new Error('expected paired key encryption from peer'); }
      await this.sendSharingFrame(send, handshake, NearDropWire.pairedKeyResult());
      const peerResult: SharingDecoded = await this.nextSharingFrame(currentInbox, handshake, acceptUpgrade);
      if (peerResult.type !== SharingType.PAIRED_KEY_RESULT) { throw new Error('missing paired key result'); }

      if (hooks.forceWifiDirect === true && hooks.onWifiDirectTransport !== undefined && t === transport) {
        try {
          await send(ProtoWire.frame(await handshake.encrypt(
            BandwidthUpgrade.upgradePathRequest([BandwidthUpgradeMedium.WIFI_DIRECT]))));
          const offer: Uint8Array = await this.waitForUpgradeAvailable(inboxRef, handshake);
          const creds: WifiDirectUpgradeCredentials | undefined = BandwidthUpgrade.parseWifiDirectCredentials(offer);
          if (creds !== undefined) { await acceptUpgrade(creds); }
        } catch (error) {
          console.warn('Quick Share sender could not negotiate WLAN Direct: ' + String(error));
        }
      }
      await this.sendSharingFrame(send, handshake, NearDropWire.introduction(payloadFiles));
      const introResponse: SharingDecoded = await this.nextSharingFrame(currentInbox, handshake, acceptUpgrade);
      if (introResponse.type !== SharingType.RESPONSE) { throw new Error('missing sharing response'); }
      const introStatus: number = ProtoReader.firstVarint(introResponse.body, 1) ?? 0;
      if (introStatus !== 1) { throw new Error('transfer rejected status=' + introStatus); }
      let total: number = 0;
      for (const file of files) { total += file.size; }
      let done: number = 0;
      for (let index = 0; index < files.length; index++) {
        await this.sendFile(t, handshake, files[index], payloadFiles[index], (delta: number): void => {
          done += delta;
          hooks.onProgress?.(total === 0 ? 100 : done * 100 / total);
        });
      }
      const peerClosed: boolean = await this.waitForPeerDisconnect(inboxRef, handshake, 2000);
      if (!peerClosed) {
        try { await t.send(ProtoWire.frame(await handshake.encrypt(NearDropWire.disconnection(false)))); }
        catch (error) { console.debug('Quick Share sender disconnect: ' + String(error)); }
      }
    } finally {
      await t.close();
    }
  }
  /**
   * After streaming the file bytes the receiver (Windows/Android Quick Share)
   * persists the attachment and only then sends its own DISCONNECTION frame.
   * The old sender sent DISCONNECTION immediately after the payload, tearing
   * down the encrypted channel before the peer wrote the file -> the peer's
   * RECEIVE_ATTACHMENTS_END reports received_bytes=0 / FAILED. Wait (bounded)
   * for the peer's DISCONNECTION, consuming KEEP_ALIVE / PAYLOAD_ACK frames.
   * Returns true when the peer disconnected first (no need to send ours), false
   * on timeout (fall back to sending our own DISCONNECTION then closing).
   */
  private async waitForPeerDisconnect(inbox: WireInbox, handshake: UKEY2Handshake, timeoutMs: number): Promise<boolean> {
    const deadline: number = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (inbox.queuedCount(3) > 0) {
        const frame: Uint8Array = await inbox.next(3);
        try {
          const offline: OfflineDecoded = NearDropWire.parseOfflineFrame(await handshake.decrypt(frame));
          if (offline.type === OfflineType.DISCONNECTION) {
            console.info("[QUICKSHARE] sender: peer disconnected after transfer");
            return true;
          }
          // PAYLOAD_ACK (packet_type=3) / KEEP_ALIVE / other: consume, keep waiting.
        } catch (error) {
          // unparseable frame -> skip and keep waiting.
          console.debug('[QUICKSHARE] sender skip unparseable frame: ' + (error instanceof Error ? error.message : String(error)));
        }
      } else {
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 50); });
      }
    }
    console.warn("[QUICKSHARE] sender: peer did not disconnect, closing locally");
    return false;
  }
  // ---- Share-layer transport (Nearby Connections PAYLOAD_TRANSFER BYTES) ----
  // Negotiation/share frames are never sent directly as a DeviceToDeviceMessage
  // payload: Android multiplexes them through the payload layer, packed into an
  // OfflineFrame(PAYLOAD_TRANSFER) as a BYTES payload, split into a full-data
  // packet + a 0-byte LAST_CHUNK packet (rquickshare send_encrypted_frame).
  private async sendSharingFrame(send: (bytes: Uint8Array) => Promise<void>, handshake: UKEY2Handshake, sharingBytes: Uint8Array): Promise<void> {
    const payloadId: number = Math.floor(Math.random() * 0x7fffffff) + 1;
    console.info('[UKEY2] send sharing frame len=' + sharingBytes.length + ' payloadId=' + payloadId);
    await send(ProtoWire.frame(await handshake.encrypt(NearDropWire.payloadTransferEnvelope(sharingBytes, payloadId))));
    await send(ProtoWire.frame(await handshake.encrypt(NearDropWire.payloadTransferLastChunk(payloadId, sharingBytes.length))));
  }
  private async nextSharingFrame(inbox: () => WireInbox, handshake: UKEY2Handshake,
    acceptUpgrade?: (creds: WifiDirectUpgradeCredentials) => Promise<boolean>): Promise<SharingDecoded> {
    const buffers: Map<string, Uint8Array> = new Map<string, Uint8Array>();
    for (;;) {
      const offlineBytes: Uint8Array = await handshake.decrypt(await inbox().next(3));
      const offline: OfflineDecoded = NearDropWire.parseOfflineFrame(offlineBytes);
      // Keep-alive frames are also SecureMessages and share the same key=3
      // bucket; skip them rather than treating them as a malformed payload.
      if (offline.type === OfflineType.KEEP_ALIVE) continue;
      if (offline.type === OfflineType.DISCONNECTION) throw new Error('peer disconnected during share');
      // 对端可能**主动**下发升级（自从我们在 ConnectionRequest 里声明 mediums=[5,8] 后更容易发生）。
      // 请求过升级（forceWifiDirect）的情况已在握手后处理；这里处理「对端自己发起」的情况：
      // 接受则迁移会话，拒绝/失败都只是继续用当前通道，绝不中断本次传输。
      if (offline.type === OfflineType.BANDWIDTH_UPGRADE_NEGOTIATION) {
        const evt: BandwidthUpgradeDecoded | undefined = BandwidthUpgrade.parse(offlineBytes);
        const eventType: number = evt === undefined ? -1 : evt.eventType;
        let accepted: boolean = false;
        if (eventType === BandwidthUpgradeEvent.UPGRADE_PATH_AVAILABLE && acceptUpgrade !== undefined) {
          const creds: WifiDirectUpgradeCredentials | undefined =
            BandwidthUpgrade.parseWifiDirectCredentials(offlineBytes);
          if (creds !== undefined) {
            accepted = await acceptUpgrade(creds);
          } else {
            // 对端可能只给了 device_name/PIN(WPS) 形态——明确说明原因，别静默失败。
            const offer: WifiDirectCredentialOffer | undefined =
              BandwidthUpgrade.inspectWifiDirectOffer(offlineBytes);
            console.warn('[P2P] sender: peer upgrade offer unusable — '
              + (offer === undefined ? 'no credentials message' : offer.detail));
          }
        }
        console.info('[P2P] sender: peer bandwidth-upgrade event=' + eventType
          + (accepted ? ' accepted, session migrated' : ' not accepted, staying on current transport'));
        continue;
      }
      if (offline.type !== OfflineType.PAYLOAD_TRANSFER) throw new Error('expected PayloadTransfer frame');
      if (ProtoReader.firstVarint(offline.body, 1) !== PayloadPacket.DATA) { continue; }
      const pt: PayloadTransferDecoded = NearDropWire.parsePayloadTransfer(offline);
      if (pt.idKey.length === 0 || (!buffers.has(pt.idKey) && buffers.size >= 8)) {
        throw new Error('Quick Share 无效的控制消息 ID 或分片数');
      }
      if (pt.type !== 1) throw new Error('expected BYTES payload');
      let buf: Uint8Array = buffers.get(pt.idKey) ?? new Uint8Array(0);
      if (buf.length + pt.body.length > 1024 * 1024) { throw new Error('Quick Share 控制消息超过上限'); }
      if (pt.body.length > 0) buf = GsBytes.concat([buf, pt.body]);
      buffers.set(pt.idKey, buf);
      if ((pt.flags & 1) !== 0) {
        buffers.delete(pt.idKey);
        console.info('[UKEY2] assembled PayloadTransfer id=' + pt.id + ' len=' + buf.length);
        return NearDropWire.parseSharing(buf);
      }
    }
  }
  private static peerEndpointId(device: GsDevice): string {
    // The ConnectionRequest endpoint_id must be the SENDER's own id. It must NOT
    // echo the peer's advertised fingerprint (that is the value the remote server
    // broadcasts for itself and would be rejected as an invalid/incoming endpoint).
    // The page normally supplies hooks.localEndpointId; this is a last-resort
    // random value for callers that do not, so at least it is not the peer's id.
    return GsCrypto.createToken().slice(0, 4);
  }
  /**
   * 统一上报介质变化（发送侧与接收侧共用）。
   * 升级是**静默**发生的：不主动上报的话，用户看不出「这次走的是局域网还是 WLAN 直连」。
   * 回调可能不存在，也可能自己抛错——都不该影响协议流程。
   */
  static reportTransport(callback: ((change: GsTransportChange) => void) | undefined,
    medium: string, upgraded: boolean, detail: string): void {
    if (callback === undefined) {
      return;
    }
    try {
      callback({ medium: medium, upgraded: upgraded, detail: detail });
    } catch (error) {
      console.warn('[P2P] onTransportChange threw: ' + (error instanceof Error ? error.message : String(error)));
    }
  }
  private async waitServerOrResponse(inbox: WireInbox): Promise<Uint8Array> { for (let round = 0; round < 4; round++) { const frame: WireFramePair = await inbox.nextAny([103, 101, 2]); if (frame.key === 101) throw new Error('UKEY2 alert: ' + (ukey2Alert(frame.value) ?? 'unknown alert')); if (frame.key === 2) { const respBody: Uint8Array = NearDropWire.parseOfflineFrame(frame.value).body; const status: number = ProtoReader.firstVarint(respBody, 3) ?? 0; console.info('Quick Share sender got ConnectionResponse status=' + status); if (status === 2) throw new Error('connection rejected'); continue; } return frame.value; } throw new Error('did not receive ServerInit after connection response'); }
  private async waitForUpgradeAvailable(inbox: WireInbox, handshake: UKEY2Handshake): Promise<Uint8Array> {
    const deadline: number = Date.now() + P2P_UPGRADE_WAIT_MS;
    while (Date.now() < deadline) {
      const bytes: Uint8Array = await handshake.decrypt(await inbox.next(3, Math.max(1, deadline - Date.now())));
      const offline: OfflineDecoded = NearDropWire.parseOfflineFrame(bytes);
      if (offline.type === OfflineType.BANDWIDTH_UPGRADE_NEGOTIATION) {
        const event: BandwidthUpgradeDecoded | undefined = BandwidthUpgrade.parse(bytes);
        if (event?.eventType === BandwidthUpgradeEvent.UPGRADE_PATH_AVAILABLE
          || event?.eventType === BandwidthUpgradeEvent.UPGRADE_FAILURE) { return bytes; }
      }
      if (offline.type === OfflineType.DISCONNECTION) { throw new Error('peer disconnected during upgrade negotiation'); }
    }
    throw new Error('等待 WLAN 直连凭据超时');
  }
  private async sendFile(transport: GsTransport, handshake: UKEY2Handshake, file: GsOutgoingFile, meta: PayloadFile, onDelta: (delta: number) => void): Promise<void> {
    // Register the FILE payload once (nearby::connections "Payload::File"): build
    // the payload_header bytes up front and reuse them for every streaming frame,
    // so the peer can bind the incoming bytes to the FileMetadata payload_id.
    const header: Uint8Array = NearDropWire.payloadFileHeader(meta.payloadId, meta, false);
    console.info('[UKEY2] payload registered type=FILE id=' + meta.payloadId + ' size=' + meta.size + ' name=' + meta.name);
    const handle = fs.openSync(file.path, fs.OpenMode.READ_ONLY);
    try {
      let offset: number = 0;
      if (file.size === 0) {
        await transport.send(ProtoWire.frame(await handshake.encrypt(NearDropWire.payloadFileData(header, 0, new Uint8Array(0), false))));
        await transport.send(ProtoWire.frame(await handshake.encrypt(NearDropWire.payloadFileData(header, 0, new Uint8Array(0), true))));
        onDelta(0);
        return;
      }
      const buffer = new ArrayBuffer(CHUNK_SIZE);
      while (offset < file.size) {
        const length: number = Math.min(CHUNK_SIZE, file.size - offset);
        // ReadOptions.offset is the absolute file read position (filePointer + offset);
        // passing the running offset advances through the file, unlike offset:0 which
        // re-reads the file head on every chunk. This matches LocalSend's stream loop.
        const count: number = await fs.read(handle.fd, buffer, { offset, length });
        if (count <= 0) throw new Error('short file read');
        const chunkBody: Uint8Array = new Uint8Array(buffer.slice(0, count));
        const isLast: boolean = offset + count === file.size;
        // Official Connections / rquickshare stream each real chunk with flags=0
        // (offset = start of chunk), then a terminating empty frame with the
        // LAST_CHUNK flag and offset = total_size, so the peer finalizes only after
        // all bytes are written. Sending a body-bearing flags=1 frame would cause the
        // peer to drop those trailing bytes.
        await transport.send(ProtoWire.frame(await handshake.encrypt(NearDropWire.payloadFileData(header, offset, chunkBody, false))));
        if (isLast) {
          await transport.send(ProtoWire.frame(await handshake.encrypt(NearDropWire.payloadFileData(header, file.size, new Uint8Array(0), true))));
        }
        offset += count;
        onDelta(count);
      }
    } finally { fs.closeSync(handle); }
  }
  // Loop-back protocol self-test: validates the full OfflineFrame + UKEY2 +
  // framing chain end-to-end on this device (no peer required). Returns the
  // stage reached, or throws with the failing stage. Useful to confirm the
  // ConnectionRequest/ClientInit framing and UKEY2 bytes independently of the
  // unstable Android peer.
  static async selfTest(context: common.Context): Promise<string> {
    const dir = context.filesDir + '/incoming/quickshare';
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    const testData = new Uint8Array(64);
    for (let i = 0; i < testData.length; i++) {
      testData[i] = i & 0xff;
    }
    const testPath = context.filesDir + '/self_test.bin';
    const w = fs.openSync(testPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(w.fd, GsBytes.toArrayBuffer(testData));
    fs.closeSync(w);

    const server = socket.constructTCPSocketServerInstance();
    const testHooks: GsReceiveHooks = {
      onIncomingSession: (_key: string, _peerName: string, _files: GsSessionFileMeta[], _pin: string): Promise<boolean> => Promise.resolve(true),
      onFileReceived: async (_file: GsIncomingFile): Promise<void> => {
        return;
      },
      onProgress: (_percent: number): void => { return; }
    };
    server.on('connect', (conn: socket.TCPSocketConnection): void => {
      new QuickShareReceiver(context, 'app').run(new TcpReceiverConnection(conn), testHooks)
        .catch((error: Error): void => {
          console.error('[QUICKSHARE] self-test receiver: ' + error.message);
        });
    });
    const port = 53319;
    await server.listen({ address: '127.0.0.1', family: 1, port });
    const device: GsDevice = {
      id: 'quickshare:self-test', name: 'SelfTest', model: 'SelfTest', protocol: 'quickshare',
      address: '127.0.0.1', port, https: false, fingerprint: '', source: 'lan'
    };
    const file: GsOutgoingFile = { path: testPath, name: 'self_test.bin', size: testData.length, mime: 'application/octet-stream' };
      const hooks: GsSendHooks = { onPin: (_pin: string): Promise<boolean> => Promise.resolve(true), localEndpointId: 'test' };
    try {
      await new QuickShareChannel().send(device, [file], hooks, 'SelfTest');
    } finally {
      await server.close().catch((): void => undefined);
    }
    return 'OK: ConnectionRequest/ClientInit/ServerInit/ClientFinish/ConnectionResponse/PairedKey/Introduction transfer complete';
  }
}


export class QuickShareReceiver {
  // TCP and BLE share the same app-level receive callbacks. Admit one transfer
  // at a time until callbacks carry independent session identities.
  private static activeSession: boolean = false;
  private static pendingUpgrade: Map<string, ReceiverSession> = new Map();
  private tcpServer?: socket.TCPSocketServer;
  private readonly opening: Set<ReceiverConnection> = new Set<ReceiverConnection>();
  private activeReceive?: ReceiverSession;
  private state: QuickShareReceiverState = QuickShareReceiverState.initial;
  private readonly context: common.Context;
  private readonly saveMode: 'download' | 'app';

  constructor(context: common.Context, saveMode: 'download' | 'app' = 'download') {
    this.context = context;
    this.saveMode = saveMode;
  }

  async start(port: number, hooks: GsReceiveHooks, bindAddress?: string): Promise<void> {
    const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
    this.tcpServer = server;
    server.on('connect', (conn: socket.TCPSocketConnection): void => {
      const tcpConn: TcpReceiverConnection = new TcpReceiverConnection(conn);
      if (this.tcpServer !== server || this.opening.size >= 16) {
        tcpConn.close();
        return;
      }
      this.opening.add(tcpConn);
      this.acceptConnection(tcpConn, hooks).catch((error: Error): void => {
        console.warn('Quick Share receiver: ' + error.message);
        tcpConn.close();
      }).finally((): void => { this.opening.delete(tcpConn); });
    });
    server.on('error', (error: Object): void => { console.warn('Quick Share receiver server error: ' + JSON.stringify(error)); });
    try {
      await server.listen({ address: bindAddress !== undefined && bindAddress.length > 0 ? bindAddress : '0.0.0.0',
        family: 1, port });
      if (this.tcpServer !== server) { await server.close().catch((): void => undefined); }
    } catch (error) {
      if (this.tcpServer === server) { this.stop(); }
      throw error as Error;
    }
  }

  private async acceptConnection(conn: ReceiverConnection, hooks: GsReceiveHooks): Promise<void> {
    const result: ReadFrameResult | undefined = await QuickShareReceiver.readFirstFrame(conn);
    if (result === undefined || !this.opening.has(conn)) { conn.close(); return; }
    const event: BandwidthUpgradeDecoded | undefined = BandwidthUpgrade.parse(result.frame);
    if (event?.eventType === BandwidthUpgradeEvent.CLIENT_INTRODUCTION) {
      const session: ReceiverSession | undefined = QuickShareReceiver.pendingUpgrade.get(event.endpointId);
      if (session === undefined || session.upgradeResolve === undefined) { conn.close(); return; }
      // Only one candidate can claim the offer. Keep the original stream until the ACK is written.
      QuickShareReceiver.pendingUpgrade.delete(event.endpointId);
      await conn.sendBytes(ProtoWire.frame(BandwidthUpgrade.clientIntroductionAck()));
      if (!this.opening.has(conn) || session.upgradeResolve === undefined) { conn.close(); return; }
      const resolve: (migrated: boolean) => void = session.upgradeResolve;
      session.upgradeResolve = undefined;
      session.rewire(conn);
      session.inbox.push(result.raw.slice(4 + result.frame.length));
      resolve(true);
      return;
    }
    await this.run(conn, hooks, result.raw);
  }

  stop(): void {
    const server: socket.TCPSocketServer | undefined = this.tcpServer;
    this.tcpServer = undefined;
    if (server !== undefined) {
      server.off('connect');
      server.close().catch((): void => undefined);
    }
    this.opening.forEach((conn: ReceiverConnection): void => conn.close());
    this.opening.clear();
    this.activeReceive?.activeConn.close();
    this.activeReceive?.upgradeResolve?.(false);
  }

  async run(conn: ReceiverConnection, hooks: GsReceiveHooks, seed?: Uint8Array,
    proactiveUpgrade: boolean = false): Promise<void> {
    let initial: Uint8Array | undefined = seed;
    if (initial === undefined || initial.length === 0) {
      const result: ReadFrameResult | undefined = await QuickShareReceiver.readFirstFrame(conn);
      initial = result?.raw;
    }
    if (initial === undefined || initial.length < 5) { conn.close(); return; }
    const length: number = GsBytes.readU32BE(initial, 0);
    const first: OfflineDecoded | undefined = NearDropWire.tryParseOfflineFrame(initial.slice(4, length + 4));
    if (first?.type !== OfflineType.CONNECTION_REQUEST) { conn.close(); return; }
    if (QuickShareReceiver.activeSession) {
      conn.close();
      throw new Error('接收端正在处理另一个传输，请稍后重试');
    }
    QuickShareReceiver.activeSession = true;
    const session: ReceiverSession = new ReceiverSession(conn, hooks);
    this.activeReceive = session;
    try {
      session.inbox.push(initial);
      await this.runSession(session, hooks, proactiveUpgrade);
    } catch (error) {
      if (session.accepted && session.consentKey.length > 0) {
        hooks.onSessionFailed?.(session.consentKey, error instanceof Error ? error.message : String(error));
      }
      throw error as Error;
    } finally {
      if (QuickShareReceiver.pendingUpgrade.get(session.peerEndpointId) === session) {
        QuickShareReceiver.pendingUpgrade.delete(session.peerEndpointId);
      }
      session.upgradeResolve?.(false);
      this.activeReceive = undefined;
      session.activeConn.close();
      QuickShareReceiver.activeSession = false;
    }
  }

  async runSession(session: ReceiverSession, hooks: GsReceiveHooks, proactiveUpgrade: boolean = false): Promise<void> {
    const handshake: UKEY2Handshake = session.handshake;
    const inbox: WireInbox = session.inbox;
    await handshake.prepare();
    const request: Uint8Array = await inbox.next(OfflineType.CONNECTION_REQUEST);
    this.state = QuickShareReceiverState.receivedConnectionRequest;
    console.info("Quick Share receiver got ConnectionRequest");
    const requestBody: Uint8Array = NearDropWire.parseOfflineFrame(request).body;
    const peerEndpointB: Uint8Array = ProtoReader.firstBytes(requestBody, 1) ?? new Uint8Array(0);
    session.peerEndpointId = GsBytes.decodeText(peerEndpointB);
    // 对端能力位（mediums/auth types/角色）：官方据此决定要不要选 Wi-Fi Direct，
    // 我们据此决定要不要主动建组并下发 UPGRADE_PATH_AVAILABLE（docs/WIFI_DIRECT.md §2.4/§2.5）。
    const capability: NearbyCapabilitySnapshot = NearbyCapabilities.read(requestBody);
    console.info('[P2P] peer capability mediums=[' + capability.mediums.join(',') + '] authTypes=['
      + capability.authTypes.join(',') + '] go=' + capability.supportsGroupOwner
      + ' gc=' + capability.supportsGroupClient);
    // 服务端主动升级的资格判定：对端声明了 WIFI_DIRECT、双方 P2P 凭据类型有交集、且调用方给了建组钩子。
    // 满足就**现在开始在后台建组**（不阻塞握手与用户确认弹窗），凭据等确认通过后再发出去。
    let upgradeOffer: Promise<WifiDirectUpgradeCredentials | undefined> | undefined = undefined;
    const wantsProactive: boolean = proactiveUpgrade || hooks.proactiveWifiDirect === true;
    if (wantsProactive && hooks.onUpgradeAvailable !== undefined
      && NearbyCapabilities.supportsWifiDirect(capability) && NearbyCapabilities.hasCommonAuthType(capability)) {
      console.info('[P2P] proactive upgrade armed: creating the group while the user confirms');
      upgradeOffer = hooks.onUpgradeAvailable(capability.mediums)
        .catch((error: Error): WifiDirectUpgradeCredentials | undefined => {
          console.warn('[P2P] proactive group creation failed: ' + error.message);
          return undefined;
        });
    } else if (wantsProactive) {
      console.info('[P2P] proactive upgrade skipped: incompatible peer capabilities or missing hook'
        + ' (mediums=[' + capability.mediums.join(',') + '] authTypes=[' + capability.authTypes.join(',') + '])');
    }
    const peerNameBytes: Uint8Array = ProtoReader.firstBytes(requestBody, 2) ?? new Uint8Array(0);
    const endpointInfoBytes: Uint8Array = ProtoReader.firstBytes(requestBody, 6) ?? new Uint8Array(0);
    const infoName: string = GsBytes.cleanText(NearDropWire.endpointName(endpointInfoBytes));
    const peerName: string = infoName.length > 0 ? infoName : GsBytes.cleanText(GsBytes.decodeText(peerNameBytes));
    console.info("Quick Share receiver peerName decoded=[" + peerName + "] infoName=[" + infoName + "]");
    const clientInit: Uint8Array = await inbox.next(102);
    if (clientInit.length >= 4 && ukey2Alert(clientInit) !== undefined) throw new Error("receiver got UKEY2 alert: " + ukey2Alert(clientInit));
    console.info("Quick Share receiver got ClientInit message_type=" + (ProtoReader.firstVarint(clientInit, 1) ?? -1) + " len=" + clientInit.length);
    const serverInit: Uint8Array = await handshake.buildServerInit(clientInit);
    console.info("Quick Share receiver built ServerInit len=" + serverInit.length);
    await session.send(ProtoWire.frame(serverInit));
    this.state = QuickShareReceiverState.sentUkeyServerInit;
    console.info("Quick Share receiver state=" + this.state);
    const finish: Uint8Array = await inbox.next(104);
    await handshake.processClientFinish(finish);
    this.state = QuickShareReceiverState.receivedUkeyClientFinish;
    console.info("Quick Share receiver state=" + this.state);
    handshake.markVerified();
    await session.send(ProtoWire.frame(NearDropWire.connectionResponse(new Uint8Array(0), true)));
    this.state = QuickShareReceiverState.sentConnectionResponse;
    console.info("Quick Share receiver state=" + this.state);
    const sendSharing: (bytes: Uint8Array) => Promise<void> = (bytes: Uint8Array): Promise<void> => session.send(bytes);
    const signedData: Uint8Array = await GsCrypto.randomBytes(72);
    const secretIdHash: Uint8Array = await GsCrypto.randomBytes(6);
    await this.sendSharingFrame(sendSharing, handshake, NearDropWire.pairedKeyEncryption(signedData, secretIdHash));
    const peerEnc: SharingDecoded = await this.nextSharingFrame(inbox, handshake, sendSharing, session);
    if (peerEnc.type !== SharingType.PAIRED_KEY_ENCRYPTION) throw new Error("expected PairedKeyEncryption from client");
    await this.sendSharingFrame(sendSharing, handshake, NearDropWire.pairedKeyResult());
    this.state = QuickShareReceiverState.sentPairedKeyResult;
    console.info("Quick Share receiver state=" + this.state);
    const peerResult: SharingDecoded = await this.nextSharingFrame(inbox, handshake, sendSharing, session);
    if (peerResult.type !== SharingType.PAIRED_KEY_RESULT) throw new Error("expected PairedKeyResult from client");
    const introduction: SharingDecoded = await this.nextSharingFrame(inbox, handshake, sendSharing, session);
    if (introduction.type !== SharingType.INTRODUCTION) throw new Error("expected Introduction");
    this.state = QuickShareReceiverState.receivedPairedKeyResult;
    console.info("Quick Share receiver state=" + this.state);
    const metas: GsSessionFileMeta[] = [];
    const ids: Set<string> = new Set<string>();
    let total: number = 0;
    for (const raw of ProtoReader.allBytes(introduction.body, 1)) {
      const id: string = ProtoReader.firstVarintKey(raw, 3) ?? '';
      const name: string = GsBytes.cleanText(GsBytes.decodeText(ProtoReader.firstBytes(raw, 1) ?? new Uint8Array(0)));
      const size: number = ProtoReader.firstVarint(raw, 4) ?? -1;
      const mime: string = GsBytes.decodeText(ProtoReader.firstBytes(raw, 5) ?? new Uint8Array(0));
      if (id.length === 0 || ids.has(id) || name.length === 0 || size < 0
        || size >= Number.MAX_SAFE_INTEGER || !Number.isSafeInteger(total + size)) {
        throw new Error('Quick Share 无效或重复的文件元数据');
      }
      ids.add(id);
      total += size;
      metas.push({ id, name, size, mime });
    }
    if (metas.length === 0) { throw new Error('Quick Share 未收到文件元数据'); }
    const gate: string = GsCrypto.createToken();
    this.state = QuickShareReceiverState.waitingForUserConsent;
    session.consentKey = gate;
    session.accepted = await hooks.onIncomingSession(gate, peerName, metas, handshake.pin);
    if (!session.accepted) {
      await this.sendSharingFrame(sendSharing, handshake, NearDropWire.response(false));
      this.state = QuickShareReceiverState.disconnected;
      return;
    }
    // Offer before ACCEPT so the sender is still reading negotiation frames.
    if (!session.upgraded) { await this.offerWifiDirectUpgrade(session, handshake, sendSharing, upgradeOffer); }
    await this.sendSharingFrame(sendSharing, handshake, NearDropWire.response(true));
    this.state = QuickShareReceiverState.receivingFiles;
    const received: GsIncomingFile[] = [];
    let transferError: Error | undefined;
    let done: number = 0;
    try {
      for (const meta of metas) {
        const stageForSave: boolean = this.saveMode === 'download';
        const saved: GsIncomingFile = await this.receiveFile(inbox, handshake, meta,
          (delta: number): void => {
            done += delta;
            hooks.onProgress(total === 0 ? 99.9 : Math.min(99.9, done * 100 / total));
          }, sendSharing, session, stageForSave);
        received.push(saved);
      }
      try { await session.send(ProtoWire.frame(await handshake.encrypt(NearDropWire.disconnection(false)))); }
      catch (error) { console.warn('Quick Share receiver could not send disconnect: ' + String(error)); }
    } catch (error) {
      transferError = error instanceof Error ? error : new Error(String(error));
    }
    // Network delivery must not wait for a SaveButton or media conversion.
    session.activeConn.close();
    this.state = QuickShareReceiverState.disconnected;
    for (const file of received) { await hooks.onFileReceived(file); }
    if (transferError !== undefined) { throw transferError; }
    hooks.onProgress(100);
  }
  private async sendSharingFrame(send: (bytes: Uint8Array) => Promise<void>, handshake: UKEY2Handshake, sharingBytes: Uint8Array): Promise<void> {
    const payloadId: number = Math.floor(Math.random() * 0x7fffffff) + 1;
    await send(ProtoWire.frame(await handshake.encrypt(NearDropWire.payloadTransferEnvelope(sharingBytes, payloadId))));
    await send(ProtoWire.frame(await handshake.encrypt(NearDropWire.payloadTransferLastChunk(payloadId, sharingBytes.length))));
  }

  /**
   * 服务端主动发起 Wi-Fi Direct 升级（官方角色模型：BWU initiator 是服务端，
   * 见 `bwu_manager.cc::InitiateBwuForEndpoint()` —— 它直接发 UPGRADE_PATH_AVAILABLE，
   * 不需要先收到 UPGRADE_PATH_REQUEST）。
   *
   * 流程：注册 pendingUpgrade → 发 UPGRADE_PATH_AVAILABLE（凭据）→ 等对端在新 socket 上发
   * CLIENT_INTRODUCTION（由 `start()` 的 connect 处理器 rewire 本会话并 resolve）。
   * 任何一步超时都只是"没升级"，不影响本次接收继续在旧通道上跑完。
   */
  private async offerWifiDirectUpgrade(session: ReceiverSession, handshake: UKEY2Handshake,
    sendSharing: (bytes: Uint8Array) => Promise<void>,
    pending: Promise<WifiDirectUpgradeCredentials | undefined> | undefined): Promise<void> {
    if (pending === undefined) {
      return;
    }
    const creds: WifiDirectUpgradeCredentials | undefined =
      await QuickShareReceiver.withTimeout<WifiDirectUpgradeCredentials | undefined>(pending, P2P_GROUP_WAIT_MS);
    if (creds === undefined || creds.gateway.length === 0) {
      console.info('[P2P] proactive upgrade skipped: Wi-Fi Direct group not ready within '
        + P2P_GROUP_WAIT_MS + 'ms');
      return;
    }
    const migrated: boolean = await QuickShareReceiver.migrateReceiver(session, handshake, sendSharing, creds);
    QuickShareChannel.reportTransport(session.hooks.onTransportChange,
      migrated ? 'wifi-direct' : 'ble', migrated,
      migrated ? '接收端已把会话迁移到 WLAN 直连' : '对端未在限定时间内加入直连组，继续用当前通道');
  }

  private static async migrateReceiver(session: ReceiverSession, handshake: UKEY2Handshake,
    send: (bytes: Uint8Array) => Promise<void>, creds: WifiDirectUpgradeCredentials): Promise<boolean> {
    if (session.upgraded || session.peerEndpointId.length !== 4) { return false; }
    const waiter: Promise<boolean> = new Promise<boolean>((resolve: (migrated: boolean) => void): void => {
      session.upgradeResolve = resolve;
    });
    const timer: number = setTimeout((): void => { session.upgradeResolve?.(false); }, P2P_UPGRADE_WAIT_MS);
    QuickShareReceiver.pendingUpgrade.set(session.peerEndpointId, session);
    try {
      await send(ProtoWire.frame(await handshake.encrypt(BandwidthUpgrade.upgradePathAvailable(creds))));
      return await waiter;
    } finally {
      clearTimeout(timer);
      session.upgradeResolve = undefined;
      if (QuickShareReceiver.pendingUpgrade.get(session.peerEndpointId) === session) {
        QuickShareReceiver.pendingUpgrade.delete(session.peerEndpointId);
      }
    }
  }

  private static withTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T | undefined> {
    const timeout: Promise<T | undefined> = new Promise<T | undefined>((resolve: (value: T | undefined) => void): void => {
      setTimeout((): void => resolve(undefined), timeoutMs);
    });
    return Promise.race([promise, timeout]);
  }
  private async nextSharingFrame(inbox: WireInbox, handshake: UKEY2Handshake,
    sendSharing: (bytes: Uint8Array) => Promise<void>, session: ReceiverSession): Promise<SharingDecoded> {
    const buffers: Map<string, Uint8Array> = new Map<string, Uint8Array>();
    for (;;) {
      const offlineBytes: Uint8Array = await handshake.decrypt(await inbox.next(3));
      const offline: OfflineDecoded = NearDropWire.parseOfflineFrame(offlineBytes);
      if (offline.type === OfflineType.BANDWIDTH_UPGRADE_NEGOTIATION) {
        await this.handleUpgrade(sendSharing, session, offlineBytes);
        continue;
      }
      if (offline.type === OfflineType.KEEP_ALIVE) continue;
      if (offline.type === OfflineType.DISCONNECTION) throw new Error('peer disconnected during share');
      if (offline.type !== OfflineType.PAYLOAD_TRANSFER) throw new Error('expected PayloadTransfer frame');
      if (ProtoReader.firstVarint(offline.body, 1) !== PayloadPacket.DATA) { continue; }
      const pt: PayloadTransferDecoded = NearDropWire.parsePayloadTransfer(offline);
      if (pt.idKey.length === 0 || (!buffers.has(pt.idKey) && buffers.size >= 8)) {
        throw new Error('Quick Share 无效的控制消息 ID 或分片数');
      }
      if (pt.type !== 1) throw new Error('expected BYTES payload');
      let buf: Uint8Array = buffers.get(pt.idKey) ?? new Uint8Array(0);
      if (buf.length + pt.body.length > 1024 * 1024) { throw new Error('Quick Share 控制消息超过上限'); }
      if (pt.body.length > 0) buf = GsBytes.concat([buf, pt.body]);
      buffers.set(pt.idKey, buf);
      if ((pt.flags & 1) !== 0) {
        buffers.delete(pt.idKey);
        return NearDropWire.parseSharing(buf);
      }
    }
  }
  private async receiveFile(inbox: WireInbox, handshake: UKEY2Handshake, meta: GsSessionFileMeta,
    onDelta: (delta: number) => void, sendSharing: (bytes: Uint8Array) => Promise<void>,
    session: ReceiverSession, stageForSave: boolean): Promise<GsIncomingFile> {
    const cleaned = meta.name.replace(/[\\/:*?"<>|\x00-\x1f]/g, '_');
    const safe = cleaned.length === 0 || cleaned === '.' || cleaned === '..' ||
      GsBytes.encodeText(cleaned).length > 220 ? 'received-file' : cleaned;
    const dir = this.context.filesDir + (stageForSave ? '/incoming/quickshare' : '/Download');
    if (!fs.accessSync(dir)) { fs.mkdirSync(dir, true); }
    const target = QuickShareReceiver.uniqueTarget(dir, safe);
    const handle = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
    let offset: number = 0;
    let complete: boolean = false;
    try {
      for (;;) {
        const raw: Uint8Array = await handshake.decrypt(await inbox.next(3));
        const offline: OfflineDecoded = NearDropWire.parseOfflineFrame(raw);
        if (offline.type === OfflineType.BANDWIDTH_UPGRADE_NEGOTIATION) {
          await this.handleUpgrade(sendSharing, session, raw);
          continue;
        }
        if (offline.type === OfflineType.DISCONNECTION) { throw new Error('peer disconnected during transfer'); }
        if (offline.type !== OfflineType.PAYLOAD_TRANSFER
          || ProtoReader.firstVarint(offline.body, 1) !== PayloadPacket.DATA) { continue; }
        const decoded: PayloadDecoded = NearDropWire.parsePayload(raw);
        if (decoded.type !== 2) { continue; }
        if (decoded.idKey !== meta.id || decoded.totalSize !== meta.size
          || decoded.offset > offset || decoded.offset + decoded.body.length > meta.size
          || (decoded.offset < offset && !session.upgraded)) {
          throw new Error('Quick Share 文件标识、偏移或大小与接收请求不符');
        }
        const body: Uint8Array = decoded.body.slice(Math.min(decoded.body.length, offset - decoded.offset));
        let written: number = 0;
        while (written < body.length) {
          const count: number = await fs.write(handle.fd, GsBytes.toArrayBuffer(body.slice(written)));
          if (count <= 0 || count > body.length - written) { throw new Error('接收文件写入不完整'); }
          written += count;
          offset += count;
          onDelta(count);
        }
        if ((decoded.flags & 1) !== 0) {
          if (offset !== meta.size || decoded.offset + decoded.body.length !== meta.size) {
            throw new Error('payload ended before declared size');
          }
          break;
        }
      }
      complete = true;
    } finally {
      try { fs.closeSync(handle); }
      finally {
        if (!complete) {
          try { fs.unlinkSync(target); } catch (error) { console.warn('Quick Share partial file cleanup failed'); }
        }
      }
    }
    return {
      name: meta.name,
      size: offset,
      savedPath: target,
      mime: meta.mime,
      stagedForSave: stageForSave
    };
  }

  private static uniqueTarget(directory: string, name: string): string {
    const prefix: string = directory.endsWith('/') ? directory : directory + '/';
    const dot: number = name.lastIndexOf('.');
    const stem: string = dot > 0 ? name.substring(0, dot) : name;
    const extension: string = dot > 0 ? name.substring(dot) : '';
    for (let index: number = 0; index < 10000; index++) {
      const candidate: string = prefix + stem + (index === 0 ? '' : ' (' + index + ')') + extension;
      if (!fs.accessSync(candidate)) {
        return candidate;
      }
    }
    throw new Error('无法分配不重名的接收文件');
  }

  private async handleUpgrade(send: (bytes: Uint8Array) => Promise<void>,
    session: ReceiverSession, offlineBytes: Uint8Array): Promise<void> {
    const event: BandwidthUpgradeDecoded | undefined = BandwidthUpgrade.parse(offlineBytes);
    if (event?.eventType !== BandwidthUpgradeEvent.UPGRADE_PATH_REQUEST || session.upgraded) { return; }
    const hook: ((mediums: number[]) => Promise<WifiDirectUpgradeCredentials | undefined>) | undefined =
      session.hooks.onUpgradeAvailable;
    const credentials: WifiDirectUpgradeCredentials | undefined = hook === undefined ? undefined :
      await QuickShareReceiver.withTimeout(hook(event.mediums), P2P_GROUP_WAIT_MS);
    if (credentials === undefined) {
      await send(ProtoWire.frame(await session.handshake.encrypt(
        BandwidthUpgrade.upgradeFailure(BandwidthUpgradeMedium.WIFI_DIRECT))));
      return;
    }
    const migrated: boolean = await QuickShareReceiver.migrateReceiver(session, session.handshake, send, credentials);
    QuickShareChannel.reportTransport(session.hooks.onTransportChange, migrated ? 'wifi-direct' : 'wifi-lan', migrated,
      migrated ? '已按对端请求升级到 WLAN 直连' : '对端未在限定时间内加入直连组，继续用当前通道');
  }

  private static readFirstFrame(conn: ReceiverConnection): Promise<ReadFrameResult | undefined> {
    return new Promise<ReadFrameResult | undefined>((resolve) => {
      let buf: Uint8Array = new Uint8Array(0);
      let done: boolean = false;
      let timer: number = -1;
      const finish = (result: ReadFrameResult | undefined): void => {
        if (done) { return; }
        done = true;
        clearTimeout(timer);
        resolve(result);
      };
      timer = setTimeout((): void => finish(undefined), 3000);
      conn.onClose?.((): void => finish(undefined));
      conn.onData((chunk: Uint8Array): void => {
        if (done) { return; }
        // The first message is small: ConnectionRequest or CLIENT_INTRODUCTION.
        if (buf.length + chunk.length > 1024 * 1024) { finish(undefined); return; }
        buf = GsBytes.concat([buf, chunk]);
        if (buf.length < 4) { return; }
        const len: number = GsBytes.readU32BE(buf, 0);
        if (len === 0 || len > 64 * 1024) { finish(undefined); return; }
        if (buf.length >= len + 4) { finish({ frame: buf.slice(4, len + 4), raw: buf }); }
      });
    });
  }
}
