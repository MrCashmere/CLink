import fs from '@ohos.file.fs';
import { picker, fileUri } from '@kit.CoreFileKit';
import { socket } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { GsBytes } from '../util/GsBytes';
import { GsCrypto } from '../util/GsCrypto';
import { GsTransport, GsTransports } from '../util/GsTransport';
import { GsDevice, GsIncomingFile, GsOutgoingFile, GsReceiveHooks, GsSendHooks, GsSessionFileMeta, GsStreamConnection, WifiDirectUpgradeCredentials } from '../model/GsTypes';
import { GS_QUICKSHARE_PORT } from '../model/GsConstants';
import { UKEY2Handshake } from './UKEY2Handshake';
import { BandwidthUpgrade, BandwidthUpgradeDecoded, BandwidthUpgradeEvent, BandwidthUpgradeMedium } from './BandwidthUpgrade';
import { NearDropWire, OfflineType, PayloadFile, SharingType, SharingDecoded, OfflineDecoded, PayloadTransferDecoded, PayloadDecoded } from './NearDropWire';
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
const TIMEOUT: number = 150000;
interface WireFramePair { readonly key: number; readonly value: Uint8Array; }
export interface ReceiverConnection { sendBytes(data: Uint8Array): Promise<void>; onData(listener: (chunk: Uint8Array) => void): void; close(): void; }
interface ReadFrameResult { readonly frame: Uint8Array; readonly raw: Uint8Array; }
class TcpReceiverConnection implements ReceiverConnection { private readonly conn: socket.TCPSocketConnection; constructor(conn: socket.TCPSocketConnection) { this.conn = conn; } sendBytes(data: Uint8Array): Promise<void> { return this.conn.send({ data: GsBytes.toArrayBuffer(data) }); } onData(listener: (chunk: Uint8Array) => void): void { this.conn.on('message', (info: socket.SocketMessageInfo): void => listener(new Uint8Array(info.message))); } close(): void { this.conn.close().catch((): void => undefined); } }
class StreamTransport implements GsTransport { private readonly conn: GsStreamConnection; constructor(conn: GsStreamConnection) { this.conn = conn; } send(data: Uint8Array): Promise<void> { return this.conn.sendBytes(data); } onData(listener: (chunk: Uint8Array) => void): void { this.conn.onData(listener); } close(): Promise<void> { this.conn.close(); return Promise.resolve(); } }
class ReceiverSession {
  readonly inbox: WireInbox = new WireInbox();
  readonly handshake: UKEY2Handshake = new UKEY2Handshake('server');
  readonly hooks: GsReceiveHooks;
  activeConn: ReceiverConnection;
  peerEndpointId: string = '';
  upgradeResolve?: () => void;
  constructor(conn: ReceiverConnection, hooks: GsReceiveHooks) {
    this.activeConn = conn;
    this.hooks = hooks;
    conn.onData((chunk: Uint8Array): void => this.inbox.push(chunk));
  }
  send(bytes: Uint8Array): Promise<void> { return this.activeConn.sendBytes(bytes); }
  rewire(conn: ReceiverConnection): void {
    const old: ReceiverConnection = this.activeConn;
    this.activeConn = conn;
    conn.onData((chunk: Uint8Array): void => this.inbox.push(chunk));
    if (old !== conn) {
      old.close();
    }
  }
}
class WireInbox { private readonly inbox: GsFrameInbox<Uint8Array> = new GsFrameInbox<Uint8Array>(); private buffer: Uint8Array = new Uint8Array(0); push(chunk: Uint8Array): void { this.buffer = GsBytes.concat([this.buffer, chunk]); while (this.buffer.length >= 4) { const len: number = ((this.buffer[0] * 0x1000000) + (this.buffer[1] << 16) + (this.buffer[2] << 8) + this.buffer[3]) >>> 0; if (len > 16 * 1024 * 1024) throw new Error('frame too large'); if (this.buffer.length < len + 4) return; const body: Uint8Array = this.buffer.slice(4, len + 4); this.buffer = this.buffer.slice(len + 4); const key: number = WireInbox.key(body); console.info('[UKEY2] recv frame key=' + key + ' len=' + body.length); this.inbox.deliver(key, body); } } next(key: number): Promise<Uint8Array> { return this.inbox.next(key, TIMEOUT); } queuedCount(key: number): number { return this.inbox.queuedCount(key); } nextAny(keys: number[]): Promise<WireFramePair> { return this.waitAny(keys, TIMEOUT); } private async waitAny(keys: number[], timeoutMs: number): Promise<WireFramePair> { const deadline: number = Date.now() + timeoutMs; while (Date.now() < deadline) { for (const key of keys) { if (this.inbox.queuedCount(key) > 0) { return { key, value: await this.inbox.next(key, timeoutMs) }; } } await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 50); }); } throw new Error('timeout waiting for frame ' + keys.join(',')); } static key(frame: Uint8Array): number {
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

  private async runSend(transport: GsTransport, device: GsDevice, files: GsOutgoingFile[], hooks: GsSendHooks, peerName: string): Promise<void> {
    let t: GsTransport = transport;
    const inbox = new WireInbox(); console.info("Quick Share sender TCP/stream ready, sending connection request"); t.onData((chunk: Uint8Array): void => inbox.push(chunk)); const handshake = new UKEY2Handshake("client"); await handshake.prepare();
    let inboxRef: WireInbox = inbox;
    const sendSharing: (bytes: Uint8Array) => Promise<void> = (bytes: Uint8Array): Promise<void> => t.send(bytes);
    try { const localEndpointId: string = (hooks.localEndpointId !== undefined && hooks.localEndpointId.length === 4) ? hooks.localEndpointId : QuickShareChannel.peerEndpointId(device); console.info("Quick Share sender localEndpointId=" + localEndpointId + " " + device.name); const connectionRequest: Uint8Array = NearDropWire.connectionRequest(localEndpointId, peerName, NearDropWire.endpointInfo(peerName, await GsCrypto.randomBytes(16)), new Uint8Array(0)); console.info("Quick Share sender ConnectionRequest len=" + connectionRequest.length); await t.send(ProtoWire.frame(connectionRequest)); console.info("Quick Share sender sent ConnectionRequest"); const clientInit: Uint8Array = await handshake.buildClientInit(); await t.send(ProtoWire.frame(clientInit)); console.info("Quick Share sender sent ClientInit message_type=" + (ProtoReader.firstVarint(clientInit, 1) ?? -1) + " len=" + clientInit.length); console.info("Quick Share sender waiting ServerInit(103)/Alert(101)/ConnectionResponse(2)"); let serverInit: Uint8Array = await this.waitServerOrResponse(inboxRef); console.info("Quick Share sender got ServerInit len=" + serverInit.length); const finish: Uint8Array = await handshake.buildClientFinish(serverInit); await t.send(ProtoWire.frame(finish)); handshake.markVerified(); console.info("Quick Share sender sent ClientFinish, waiting ConnectionResponse"); const response: Uint8Array = await inboxRef.next(OfflineType.CONNECTION_RESPONSE); if ((ProtoReader.firstVarint(response, 3) ?? 0) === 2) throw new Error("connection rejected"); await t.send(ProtoWire.frame(NearDropWire.connectionAccept())); console.info("Quick Share sender sent ConnectionResponse (accept)");
    if (hooks.forceWifiDirect === true && hooks.onWifiDirectTransport !== undefined) {
      try {
        console.info("Quick Share sender forcing Wi-Fi Direct upgrade");
        await this.sendSharingFrame(sendSharing, handshake, BandwidthUpgrade.upgradePathRequest([BandwidthUpgradeMedium.WIFI_DIRECT]));
        const avail: Uint8Array = await this.waitForUpgradeAvailable(inboxRef, handshake);
        const creds: WifiDirectUpgradeCredentials | undefined = BandwidthUpgrade.parseWifiDirectCredentials(avail);
        if (creds === undefined) throw new Error("peer did not offer Wi-Fi Direct credentials");
        console.info("Quick Share sender got Wi-Fi Direct creds ssid=" + creds.ssid + " gateway=" + creds.gateway + " port=" + creds.port);
        const newConn: GsStreamConnection | undefined = await hooks.onWifiDirectTransport(creds);
        if (newConn === undefined) throw new Error("failed to join Wi-Fi Direct group");
        const newTransport: GsTransport = new StreamTransport(newConn);
        const newInbox: WireInbox = new WireInbox();
        newTransport.onData((chunk: Uint8Array): void => newInbox.push(chunk));
        await newTransport.send(BandwidthUpgrade.clientIntroduction(localEndpointId));
        await newInbox.next(OfflineType.BANDWIDTH_UPGRADE_NEGOTIATION); // CLIENT_INTRO_ACK
        t = newTransport;
        inboxRef = newInbox;
        void transport.close();
        console.info("Quick Share sender migrated session to Wi-Fi Direct");
      } catch (error) {
        console.warn("Quick Share sender Wi-Fi Direct upgrade failed, staying on current transport: " + (error instanceof Error ? error.message : String(error)));
      }
    }
    const pinAccepted: boolean = hooks.onPin === undefined ? true : await hooks.onPin(handshake.pin); if (!pinAccepted) throw new Error("user cancelled pairing"); const pcPeer: boolean = hooks.pcPeer === true; const payloadFiles: PayloadFile[] = files.map((file: GsOutgoingFile, index: number): PayloadFile => ({ name: file.name, size: file.size, payloadId: pcPeer ? (-(Math.floor(Math.random() * 9007199254740991) + 1)) : index + 1, mimeType: file.mime })); console.info("Quick Share sender pcPeer=" + pcPeer + " payloadIds=" + payloadFiles.map((f: PayloadFile): string => String(f.payloadId)).join(',')); const signedData: Uint8Array = await GsCrypto.randomBytes(72); const secretIdHash: Uint8Array = await GsCrypto.randomBytes(6); await this.sendSharingFrame(sendSharing, handshake, NearDropWire.pairedKeyEncryption(signedData, secretIdHash)); const peerEnc: SharingDecoded = await this.nextSharingFrame(inboxRef, handshake); if (peerEnc.type !== SharingType.PAIRED_KEY_ENCRYPTION) throw new Error("expected paired key encryption from peer"); await this.sendSharingFrame(sendSharing, handshake, NearDropWire.pairedKeyResult()); const peerResult: SharingDecoded = await this.nextSharingFrame(inboxRef, handshake); if (peerResult.type !== SharingType.PAIRED_KEY_RESULT) throw new Error("missing paired key result"); await this.sendSharingFrame(sendSharing, handshake, NearDropWire.introduction(payloadFiles)); const introResponse: SharingDecoded = await this.nextSharingFrame(inboxRef, handshake); if (introResponse.type !== SharingType.RESPONSE) throw new Error("missing sharing response"); const introStatus: number = ProtoReader.firstVarint(introResponse.body, 1) ?? 0; if (introStatus !== 1) throw new Error("transfer rejected status=" + introStatus); let total: number = 0; for (const file of files) total += file.size; let done: number = 0; for (let index = 0; index < files.length; index++) { await this.sendFile(t, handshake, files[index], payloadFiles[index], (delta: number): void => { done += delta; if (hooks.onProgress !== undefined) hooks.onProgress(total === 0 ? 100 : done * 100 / total); }); } const peerClosed: boolean = await this.waitForPeerDisconnect(inboxRef, handshake, 2000); if (!peerClosed) { try { await t.send(ProtoWire.frame(await handshake.encrypt(NearDropWire.disconnection(false)))); } catch (closeErr) { console.debug("[QUICKSHARE] sender: best-effort disconnect ignored: " + (closeErr instanceof Error ? closeErr.message : String(closeErr))); } } } catch (error) { const message: string = error instanceof Error ? error.message : String(error); console.error("Quick Share sender: " + message); throw new Error(message); } finally { await t.close(); }
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
  private async nextSharingFrame(inbox: WireInbox, handshake: UKEY2Handshake): Promise<SharingDecoded> {
    const buffers: Map<number, Uint8Array> = new Map<number, Uint8Array>();
    for (;;) {
      const offlineBytes: Uint8Array = await handshake.decrypt(await inbox.next(3));
      const offline: OfflineDecoded = NearDropWire.parseOfflineFrame(offlineBytes);
      // Keep-alive frames are also SecureMessages and share the same key=3
      // bucket; skip them rather than treating them as a malformed payload.
      if (offline.type === OfflineType.KEEP_ALIVE) continue;
      if (offline.type === OfflineType.DISCONNECTION) throw new Error('peer disconnected during share');
      if (offline.type !== OfflineType.PAYLOAD_TRANSFER) throw new Error('expected PayloadTransfer frame');
      const pt: PayloadTransferDecoded = NearDropWire.parsePayloadTransfer(offline);
      if (pt.type !== 1) throw new Error('expected BYTES payload');
      let buf: Uint8Array = buffers.get(pt.id) ?? new Uint8Array(0);
      if (pt.body.length > 0) buf = GsBytes.concat([buf, pt.body]);
      buffers.set(pt.id, buf);
      if ((pt.flags & 1) !== 0) {
        buffers.delete(pt.id);
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
  private async waitServerOrResponse(inbox: WireInbox): Promise<Uint8Array> { for (let round = 0; round < 4; round++) { const frame: WireFramePair = await inbox.nextAny([103, 101, 2]); if (frame.key === 101) throw new Error('UKEY2 alert: ' + (ukey2Alert(frame.value) ?? 'unknown alert')); if (frame.key === 2) { const respBody: Uint8Array = NearDropWire.parseOfflineFrame(frame.value).body; const status: number = ProtoReader.firstVarint(respBody, 3) ?? 0; console.info('Quick Share sender got ConnectionResponse status=' + status); if (status === 2) throw new Error('connection rejected'); continue; } return frame.value; } throw new Error('did not receive ServerInit after connection response'); }
  private async waitForUpgradeAvailable(inbox: WireInbox, handshake: UKEY2Handshake): Promise<Uint8Array> {
    for (;;) {
      const offlineBytes: Uint8Array = await handshake.decrypt(await inbox.next(3));
      const offline: OfflineDecoded = NearDropWire.parseOfflineFrame(offlineBytes);
      if (offline.type === OfflineType.BANDWIDTH_UPGRADE_NEGOTIATION) {
        return offlineBytes;
      }
      if (offline.type === OfflineType.KEEP_ALIVE) continue;
      if (offline.type === OfflineType.DISCONNECTION) throw new Error('peer disconnected during upgrade negotiation');
    }
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
        onFileReceived: (_file: GsIncomingFile): void => { return; },
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
  private static pendingUpgrade: Map<string, ReceiverSession> = new Map();
  private tcpServer?: socket.TCPSocketServer; private readonly context: common.Context; private readonly saveMode: 'download' | 'app'; private state: QuickShareReceiverState = QuickShareReceiverState.initial; constructor(context: common.Context, saveMode: 'download' | 'app' = 'download') { this.context = context; this.saveMode = saveMode; }
  async start(port: number, hooks: GsReceiveHooks, bindAddress?: string): Promise<void> {
    console.info("Quick Share receiver listen begin port=" + port);
    const server = socket.constructTCPSocketServerInstance();
    server.on("connect", (conn: socket.TCPSocketConnection): void => {
      console.info("Quick Share receiver accepted TCP connection");
      const tcpConn: TcpReceiverConnection = new TcpReceiverConnection(conn);
      conn.getRemoteAddress().then((peer: socket.NetAddress): void => {
        console.info("Quick Share receiver remote=" + peer.address + ":" + peer.port);
      }).catch((): void => undefined);
      QuickShareReceiver.readFirstFrame(tcpConn).then((result: ReadFrameResult | undefined): void => {
        if (result !== undefined && result.frame !== undefined) {
          const evt = BandwidthUpgrade.parse(result.frame);
          if (evt !== undefined && evt.eventType === BandwidthUpgradeEvent.CLIENT_INTRODUCTION) {
            const session: ReceiverSession | undefined = QuickShareReceiver.pendingUpgrade.get(evt.endpointId);
            if (session !== undefined) {
              session.rewire(tcpConn);
              session.inbox.push(result.raw.slice(4 + result.frame.length));
              tcpConn.sendBytes(BandwidthUpgrade.clientIntroductionAck());
              const r: (() => void) | undefined = session.upgradeResolve;
              session.upgradeResolve = undefined;
              if (r !== undefined) { r(); }
              return;
            }
            console.warn("Quick Share receiver upgrade socket for unknown endpoint " + evt.endpointId);
          }
          this.run(tcpConn, hooks, result.raw).catch((error: Error): void => {
            console.warn("Quick Share receiver: " + error.message);
            conn.close().catch((): void => undefined);
          });
          return;
        }
        this.run(tcpConn, hooks).catch((error: Error): void => {
          console.warn("Quick Share receiver: " + error.message);
          conn.close().catch((): void => undefined);
        });
      }).catch((): void => {
        this.run(tcpConn, hooks).catch((error: Error): void => console.warn("Quick Share receiver: " + error.message));
      });
    });
    server.on("error", (error: Object): void => { console.warn("Quick Share receiver server error: " + JSON.stringify(error)); });
    await server.listen({ address: bindAddress !== undefined && bindAddress.length > 0 ? bindAddress : "0.0.0.0", family: 1, port });
    this.tcpServer = server;
    console.info("Quick Share receiver listen ok port=" + port + " bind=" + (bindAddress !== undefined && bindAddress.length > 0 ? bindAddress : "0.0.0.0"));
  }

  stop(): void { if (this.tcpServer !== undefined) { this.tcpServer.off('connect'); this.tcpServer.close().catch((): void => undefined); this.tcpServer = undefined; } }
  async run(conn: ReceiverConnection, hooks: GsReceiveHooks, seed?: Uint8Array): Promise<void> {
    const session: ReceiverSession = new ReceiverSession(conn, hooks);
    if (seed !== undefined && seed.length > 0) {
      session.inbox.push(seed);
    }
    await this.runSession(session, hooks);
  }

  async runSession(session: ReceiverSession, hooks: GsReceiveHooks): Promise<void> {
    const handshake: UKEY2Handshake = session.handshake;
    const inbox: WireInbox = session.inbox;
    await handshake.prepare();
    const request: Uint8Array = await inbox.next(OfflineType.CONNECTION_REQUEST);
    this.state = QuickShareReceiverState.receivedConnectionRequest;
    console.info("Quick Share receiver got ConnectionRequest");
    const requestBody: Uint8Array = NearDropWire.parseOfflineFrame(request).body;
    const peerEndpointB: Uint8Array = ProtoReader.firstBytes(requestBody, 1) ?? new Uint8Array(0);
    session.peerEndpointId = GsBytes.decodeText(peerEndpointB);
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
    for (const raw of ProtoReader.allBytes(introduction.body, 1)) {
      const nameBytes: Uint8Array = ProtoReader.firstBytes(raw, 1) ?? new Uint8Array(0);
      const name: string = GsBytes.cleanText(GsBytes.decodeText(nameBytes));
      console.info("Quick Share receiver file name decoded=[" + name + "]");
      metas.push({ id: String(ProtoReader.firstVarint(raw, 3) ?? 0), name, size: ProtoReader.firstVarint(raw, 4) ?? 0 });
    }
    const gate: string = GsCrypto.createToken();
    this.state = QuickShareReceiverState.waitingForUserConsent;
    console.info("Quick Share receiver state=" + this.state);
    const accepted: boolean = await hooks.onIncomingSession(gate, peerName, metas, handshake.pin);
    await this.sendSharingFrame(sendSharing, handshake, NearDropWire.response(accepted));
    if (!accepted) { this.state = QuickShareReceiverState.disconnected; return; }
    this.state = QuickShareReceiverState.receivingFiles;
    console.info("Quick Share receiver state=" + this.state);
    let total: number = 0;
    for (const item of metas) total += item.size;
    let done: number = 0;
    for (const meta of metas) {
      const saved: GsIncomingFile = await this.receiveFile(inbox, handshake, meta, (delta: number): void => { done += delta; hooks.onProgress(total === 0 ? 100 : done * 100 / total); }, sendSharing, session);
      hooks.onFileReceived(saved);
    }
    await session.send(ProtoWire.frame(await handshake.encrypt(NearDropWire.disconnection(false))));
    this.state = QuickShareReceiverState.disconnected;
    session.activeConn.close();
  }
  private async sendSharingFrame(send: (bytes: Uint8Array) => Promise<void>, handshake: UKEY2Handshake, sharingBytes: Uint8Array): Promise<void> {
    const payloadId: number = Math.floor(Math.random() * 0x7fffffff) + 1;
    await send(ProtoWire.frame(await handshake.encrypt(NearDropWire.payloadTransferEnvelope(sharingBytes, payloadId))));
    await send(ProtoWire.frame(await handshake.encrypt(NearDropWire.payloadTransferLastChunk(payloadId, sharingBytes.length))));
  }
  private async nextSharingFrame(inbox: WireInbox, handshake: UKEY2Handshake,
    sendSharing: (bytes: Uint8Array) => Promise<void>, session: ReceiverSession): Promise<SharingDecoded> {
    const buffers: Map<number, Uint8Array> = new Map<number, Uint8Array>();
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
      const pt: PayloadTransferDecoded = NearDropWire.parsePayloadTransfer(offline);
      if (pt.type !== 1) throw new Error('expected BYTES payload');
      let buf: Uint8Array = buffers.get(pt.id) ?? new Uint8Array(0);
      if (pt.body.length > 0) buf = GsBytes.concat([buf, pt.body]);
      buffers.set(pt.id, buf);
      if ((pt.flags & 1) !== 0) {
        buffers.delete(pt.id);
        return NearDropWire.parseSharing(buf);
      }
    }
  }
  private async receiveFile(inbox: WireInbox, handshake: UKEY2Handshake, meta: GsSessionFileMeta,
    onDelta: (delta: number) => void, sendSharing: (bytes: Uint8Array) => Promise<void>,
    session: ReceiverSession): Promise<GsIncomingFile> {
    const safe: string = meta.name.replace(/[\\/:*?"<>|]/g, '_');
    let target: string;
    let handle: fs.File;
    // Save via DocumentViewPicker DOWNLOAD mode: it returns the Download/<bundle>
    // DIRECTORY uri; convert it to a real path with fileUri.FileUri().path and
    // create the file inside. The picker grants access to the public Download
    // directory for the chosen file, so no WRITE_MEDIA permission is required.
    // Fall back to app storage when the picker is unavailable (self-test / headless).
    if (this.saveMode === 'download') {
      try {
        const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
        options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
        options.newFileNames = [safe];
        const documentViewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
        const uris: string[] = await documentViewPicker.save(options);
        const basePath: string = new fileUri.FileUri(uris[0]).path;
        target = basePath.endsWith('/') ? basePath + safe : basePath + '/' + safe;
        console.info('Quick Share receiver writing to Download dir: ' + (target.lastIndexOf('/') >= 0 ? target.substring(0, target.lastIndexOf('/')) : target));
        handle = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      } catch (error) {
        console.warn('Quick Share receiver DocumentViewPicker save failed, falling back to app storage: ' + (error instanceof Error ? error.message : JSON.stringify(error)));
        const dir: string = this.context.filesDir + '/Download';
        if (!fs.accessSync(dir)) fs.mkdirSync(dir, true);
        target = dir + '/' + Date.now() + '-' + safe;
        handle = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      }
    } else {
      const dir: string = this.context.filesDir + '/Download';
      if (!fs.accessSync(dir)) fs.mkdirSync(dir, true);
      target = dir + '/' + Date.now() + '-' + safe;
      handle = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    }
    let offset: number = 0;
    try {
      // Read until the LAST_CHUNK flag, not until a declared size: if the peer's
      // Introduction size were smaller than the bytes actually sent, exiting on
      // offset>=meta.size would silently truncate the file. size is only an upper
      // bound / final verification.
      while (true) {
        const raw: Uint8Array = await handshake.decrypt(await inbox.next(3));
        let decoded: PayloadDecoded | undefined = undefined;
        try {
          const offline: OfflineDecoded = NearDropWire.parseOfflineFrame(raw);
          if (offline.type === OfflineType.BANDWIDTH_UPGRADE_NEGOTIATION) {
            await this.handleUpgrade(sendSharing, session, raw);
            continue;
          }
          if (offline.type === OfflineType.KEEP_ALIVE) continue;
          if (offline.type === OfflineType.DISCONNECTION) throw new Error('peer disconnected during transfer');
          if (offline.type !== OfflineType.PAYLOAD_TRANSFER) {
            console.info('Quick Share receiver skipping non-PAYLOAD frame type=' + offline.type);
            continue;
          }
          decoded = NearDropWire.parsePayload(raw);
        } catch (error) {
          console.info('Quick Share receiver skipped unparseable frame: ' + (error instanceof Error ? error.message : String(error)));
          continue;
        }
        // Only FILE payloads carry file bytes; BYTES payloads / CertificateInfo /
        // keep-alives during the file phase must be skipped, not written to disk.
        if (decoded.type !== 2) {
          console.info('Quick Share receiver skipped BYTES payload id=' + decoded.id + ' total=' + decoded.totalSize + ' len=' + decoded.body.length);
          continue;
        }
        if (decoded.offset !== offset || offset + decoded.body.length > meta.size) {
          console.error('Quick Share receiver mismatch offset=' + decoded.offset + '/exp=' + offset + ' total=' + decoded.totalSize + '/metaSize=' + meta.size + ' len=' + decoded.body.length + ' id=' + decoded.id + '/metaId=' + meta.id);
          throw new Error('payload offset/size mismatch');
        }
        if (decoded.body.length > 0) { await fs.write(handle.fd, GsBytes.toArrayBuffer(decoded.body)); offset += decoded.body.length; onDelta(decoded.body.length); }
        if ((decoded.flags & 1) !== 0) break;
        if (meta.size === 0) break;
      }
      if (offset !== meta.size) throw new Error('payload ended before declared size');
    } finally { fs.closeSync(handle); }
    return { name: meta.name, size: offset, savedPath: target };
  }

  private async handleUpgrade(sendSharing: (bytes: Uint8Array) => Promise<void>,
    session: ReceiverSession, offlineBytes: Uint8Array): Promise<void> {
    const evt: BandwidthUpgradeDecoded | undefined = BandwidthUpgrade.parse(offlineBytes);
    if (evt === undefined || evt.eventType !== BandwidthUpgradeEvent.UPGRADE_PATH_REQUEST) {
      return;
    }
    const hook: ((mediums: number[]) => Promise<WifiDirectUpgradeCredentials | undefined>) | undefined =
      session.hooks.onUpgradeAvailable;
    const creds: WifiDirectUpgradeCredentials | undefined = hook === undefined ? undefined : await hook(evt.mediums);
    if (creds === undefined) {
      await this.sendSharingFrame(sendSharing, session.handshake,
        BandwidthUpgrade.upgradeFailure(BandwidthUpgradeMedium.WIFI_DIRECT));
      return;
    }
    QuickShareReceiver.pendingUpgrade.set(session.peerEndpointId, session);
    await this.sendSharingFrame(sendSharing, session.handshake,
      BandwidthUpgrade.upgradePathAvailable(creds));
    // Wait for the peer to open the Wi-Fi Direct socket; the server's connect
    // handler rewires this session and resolves upgradeResolve.
    if (session.upgradeResolve === undefined) {
      const waiter: Promise<void> = new Promise<void>((resolve: () => void): void => {
        session.upgradeResolve = resolve;
      });
      const timeout: Promise<void> = new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 15000);
      });
      await Promise.race([waiter, timeout]);
    }
  }

  private static async readFirstFrame(conn: ReceiverConnection): Promise<ReadFrameResult | undefined> {
    return new Promise<ReadFrameResult | undefined>((resolve) => {
      let buf: Uint8Array = new Uint8Array(0);
      let done: boolean = false;
      const finish = (value: ReadFrameResult | undefined): void => {
        if (!done) {
          done = true;
          resolve(value);
        }
      };
      conn.onData((chunk: Uint8Array): void => {
        buf = GsBytes.concat([buf, chunk]);
        if (buf.length >= 4) {
          const len: number = ((buf[0] * 0x1000000) + (buf[1] << 16) + (buf[2] << 8) + buf[3]) >>> 0;
          if (len > 16 * 1024 * 1024 || buf.length >= len + 4) {
            const frame: Uint8Array = buf.slice(4, Math.min(len + 4, buf.length));
            const result: ReadFrameResult = { frame: frame, raw: buf };
            finish(result);
          }
        }
      });
      setTimeout((): void => finish(undefined), 3000);
    });
  }
}
