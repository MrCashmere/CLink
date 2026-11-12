import fs from '@ohos.file.fs';
import { socket } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { GsBytes, encodeFrame, FrameStream } from '../util/GsBytes';
import { GsCrypto } from '../util/GsCrypto';
import { GsFrameInbox } from '../util/GsFrameInbox';
import { GsTransport, GsTransports } from '../util/GsTransport';
import { GS_NEARSHARE_PORT } from '../model/GsConstants';
import {
  GsDevice,
  GsCdpCapability,
  GsCdpEndpoint,
  GsIncomingFile,
  GsOutgoingFile,
  GsReceiveHooks,
  GsSendHooks,
  GsSessionFileMeta
} from '../model/GsTypes';

enum NearShareFrameType {
  OFFER = 2,
  ACCEPT = 3,
  DATA = 4,
  FILE_ACK = 5,
  DONE = 6,
  ERROR = 7
}

interface OfferJson {
  deviceName: string;
  sessionId: string;
  pin: string;
  files: GsSessionFileMeta[];
  endpoint: GsCdpEndpoint;
  capabilities: GsCdpCapability[];
}

interface AcceptJson {
  ok: boolean;
  sessionId: string;
  endpoint: GsCdpEndpoint;
  capabilities: GsCdpCapability[];
}

interface FileAckJson {
  ok: boolean;
  index: number;
}

const CHUNK_SIZE = 256 * 1024;
const HANDSHAKE_TIMEOUT_MS = 30000;
const ACCEPT_TIMEOUT_MS = 150000;
const FILE_ACK_TIMEOUT_MS = 120000;
const MAX_OFFER_FILES = 100;
const MAX_FILE_BYTES = 2 * 1024 * 1024 * 1024;
const MAX_TOTAL_BYTES = 4 * 1024 * 1024 * 1024;
const MAX_FILE_NAME_BYTES = 240;
const MAX_PENDING_BYTES = 32 * 1024 * 1024;

/**
 * NearShare OFFER -> ACCEPT -> DATA -> DONE exchange (Windows Nearby aligned).
 * The CDP advertisement lives on the BLE discovery layer (see parseCdp); this
 * class only carries the transport-layer session. Acknowledgement is batched
 * per file (one FILE_ACK covers a whole file of 256 KiB chunks), and response
 * frames are routed by type via GsFrameInbox so a timed-out waiter is removed
 * and cannot consume a later frame.
 *
 * ALIGNMENT NOTE (verified against nearby-sharing/android, C# port): the real
 * Windows Nearby stack runs this exchange over the Microsoft Connected
 * Devices (CDP) binary session protocol — BinaryMsgHeader + ValueSet
 * serialization, app registration ("NearSharePlatform"), control messages
 * (StartTransfer=1 / CompleteTransfer=2 / FetchDataRequest=3 /
 * FetchDataResponse=4 / CancelTransfer=5 / HandShakeRequest=6 /
 * HandShakeResult=7), pull-based FetchDataRequest with 100 KiB partitions
 * (PartitionSize = 102400), CDP session encryption (CdpCryptor), and
 * RFCOMM/TCP-5040/UDP-5050 transports. The JSON-frame flow below is a
 * self-consistent, simplified variant kept compatible with the facade
 * contract; byte-exact interop with stock Windows requires porting the full
 * CDP stack.
 */
export class NearShareProtocol {
  async send(device: GsDevice, files: GsOutgoingFile[], hooks: GsSendHooks, peerName: string): Promise<void> {
    if (files.length === 0 || files.length > MAX_OFFER_FILES) {
      throw new Error('NearShare send file count is out of range');
    }
    const transport = await GsTransports.open(device.address, device.port > 0 ? device.port : GS_NEARSHARE_PORT, device.https);
    const stream = new FrameStream();
    const inbox = new GsFrameInbox<Uint8Array>();
    transport.onClose?.((): void => inbox.end(new Error('NearShare 对端已断开')));
    transport.onData((chunk: Uint8Array): void => {
      try {
        for (const frame of stream.push(chunk)) {
          if (frame.type === NearShareFrameType.ERROR) {
            inbox.end(new Error(GsBytes.decodeText(frame.payload)));
            return;
          }
          if (inbox.queuedCount(frame.type) >= MAX_OFFER_FILES) { throw new Error('NearShare 帧队列超限'); }
          inbox.deliver(frame.type, frame.payload);
        }
      } catch (error) {
        inbox.end(error instanceof Error ? error : new Error(String(error)));
      }
    });
    try {
      const sessionId = GsCrypto.createToken();
      const pin = GsCrypto.createPin();
      const offer: OfferJson = {
        deviceName: peerName,
        sessionId,
        pin,
        files: files.map((file: GsOutgoingFile, index: number): GsSessionFileMeta => ({
          id: index.toString(),
          name: file.name,
          size: file.size,
          mime: file.mime
        })),
        endpoint: {
          host: device.address,
          port: device.port,
          deviceId: device.id
        },
        capabilities: NearShareProtocol.capabilities()
      };
      await transport.send(encodeFrame(NearShareFrameType.OFFER, GsBytes.encodeText(JSON.stringify(offer))));
      if (hooks.onPin !== undefined) {
        const confirmed = await hooks.onPin(pin);
        if (!confirmed) {
          throw new Error('user cancelled pairing');
        }
      }
      const acceptPayload = await inbox.next(NearShareFrameType.ACCEPT, ACCEPT_TIMEOUT_MS);
      const accept = JSON.parse(GsBytes.decodeText(acceptPayload)) as AcceptJson;
      if (accept.sessionId !== sessionId) {
        throw new Error('NearShare ACCEPT session mismatch');
      }
      if (!accept.ok) {
        throw new Error('peer rejected the offer');
      }
      let totalBytes = 0;
      for (const file of files) {
        totalBytes += file.size;
      }
      let transferred = 0;
      for (let index = 0; index < files.length; index++) {
        await this.sendFile(transport, index, files[index], (delta: number): void => {
          transferred += delta;
          if (hooks.onProgress !== undefined) {
            hooks.onProgress(totalBytes > 0 ? transferred / totalBytes * 100 : 100);
          }
        });
        const ackPayload = await inbox.next(NearShareFrameType.FILE_ACK, FILE_ACK_TIMEOUT_MS);
        const ack = JSON.parse(GsBytes.decodeText(ackPayload)) as FileAckJson;
        if (!ack.ok || ack.index !== index) {
          throw new Error(`file ${files[index].name} not acknowledged`);
        }
      }
      await transport.send(encodeFrame(NearShareFrameType.DONE, new Uint8Array(0)));
      await inbox.next(NearShareFrameType.DONE, HANDSHAKE_TIMEOUT_MS);
    } finally {
      await transport.close();
    }
  }

  private async sendFile(
    transport: GsTransport,
    index: number,
    file: GsOutgoingFile,
    onDelta: (delta: number) => void
  ): Promise<void> {
    const handle = fs.openSync(file.path, fs.OpenMode.READ_ONLY);
    try {
      const buffer = new ArrayBuffer(CHUNK_SIZE);
      let offset = 0;
      const indexBytes = GsBytes.writeU32BE(index);
      while (offset < file.size) {
        const length = Math.min(CHUNK_SIZE, file.size - offset);
        const readCount = await fs.read(handle.fd, buffer, { offset, length });
        if (readCount <= 0) {
          break;
        }
        await transport.send(encodeFrame(NearShareFrameType.DATA,
          GsBytes.concat([indexBytes, new Uint8Array(buffer.slice(0, readCount))])));
        offset += readCount;
        onDelta(readCount);
      }
    } finally {
      fs.closeSync(handle);
    }
  }

  static capabilities(): GsCdpCapability[] {
    return [
      { name: 'NearSharePlatform', version: 1, enabled: true },
      { name: 'TcpTransport', version: 1, enabled: true },
      { name: 'FileMetadata', version: 1, enabled: true },
      { name: 'ChunkedTransfer', version: 1, enabled: true }
    ];
  }

  static validateOffer(offer: OfferJson): void {
    if (typeof offer.sessionId !== 'string' || offer.sessionId.length < 16 || offer.sessionId.length > 128) {
      throw new Error('NearShare offer has invalid session id');
    }
    if (!Array.isArray(offer.files) || offer.files.length === 0 || offer.files.length > MAX_OFFER_FILES) {
      throw new Error('NearShare offer file count is out of range');
    }
    let total = 0;
    for (const file of offer.files) {
      if (file === undefined || file === null || typeof file.name !== 'string' || file.name.length === 0 || GsBytes.encodeText(file.name).length > MAX_FILE_NAME_BYTES) {
        throw new Error('NearShare offer contains an invalid file name');
      }
      if (!Number.isSafeInteger(file.size) || file.size < 0 || file.size > MAX_FILE_BYTES) {
        throw new Error('NearShare offer file size is out of range');
      }
      total += file.size;
      if (total > MAX_TOTAL_BYTES) {
        throw new Error('NearShare offer total size is too large');
      }
    }
  }
}

interface ReceiverConnection {
  sendBytes(data: Uint8Array): Promise<void>;
  onData(listener: (chunk: Uint8Array) => void): void;
  onClose(listener: () => void): void;
  close(): void;
}

class TcpReceiverConnection implements ReceiverConnection {
  private readonly conn: socket.TCPSocketConnection;

  constructor(conn: socket.TCPSocketConnection) {
    this.conn = conn;
  }

  sendBytes(data: Uint8Array): Promise<void> {
    return this.conn.send({ data: GsBytes.toArrayBuffer(data) });
  }

  onData(listener: (chunk: Uint8Array) => void): void {
    this.conn.on('message', (info: socket.SocketMessageInfo): void => {
      listener(new Uint8Array(info.message));
    });
  }

  onClose(listener: () => void): void {
    this.conn.on('close', listener);
    this.conn.on('error', (): void => listener());
  }

  close(): void {
    this.conn.close().catch((): void => undefined);
  }
}

export class NearShareReceiver {
  private tcpServer?: socket.TCPSocketServer;
  private active?: ReceiverConnection;
  private readonly context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  async start(port: number, hooks: GsReceiveHooks, bindAddress?: string): Promise<void> {
    if (this.tcpServer !== undefined) { return; }
    const server = socket.constructTCPSocketServerInstance();
    this.tcpServer = server;
    try {
      server.on('connect', (socketConn: socket.TCPSocketConnection): void => {
        const conn = new TcpReceiverConnection(socketConn);
        if (this.tcpServer !== server || this.active !== undefined) { conn.close(); return; }
        this.active = conn;
        this.runSession(conn, hooks).finally((): void => {
          if (this.active === conn) { this.active = undefined; }
          conn.close();
        }).catch((error: Error): void => console.warn('NearShare session failed: ' + error.message));
      });
      await server.listen({ address: bindAddress !== undefined && bindAddress.length > 0 ? bindAddress : '0.0.0.0',
        family: 1, port: port });
    } catch (error) {
      if (this.tcpServer === server) { this.stop(); }
      throw error as Error;
    }
  }

  stop(): void {
    const server = this.tcpServer;
    this.tcpServer = undefined;
    if (server !== undefined) {
      server.off('connect');
      server.close().catch((): void => undefined);
    }
    this.active?.close();
  }

  private async runSession(conn: ReceiverConnection, hooks: GsReceiveHooks): Promise<void> {
    const stream = new FrameStream();
    const inbox = new GsFrameInbox<Uint8Array>();
    let closed = false;
    let pendingBytes = 0;
    let offered = false;
    let ready = false;
    const end = (error: Error): void => {
      closed = true;
      inbox.end(error);
    };
    conn.onClose((): void => end(new Error('NearShare 对端已断开')));
    conn.onData((chunk: Uint8Array): void => {
      if (closed) { return; }
      try {
        for (const frame of stream.push(chunk)) {
          if (frame.type === NearShareFrameType.ERROR) { throw new Error(GsBytes.decodeText(frame.payload)); }
          if (frame.type === NearShareFrameType.OFFER) {
            if (offered || frame.payload.length > 128 * 1024) { throw new Error('NearShare 无效接收请求'); }
            offered = true;
          } else if (frame.type === NearShareFrameType.DATA) {
            if (!ready || frame.payload.length <= 4 || frame.payload.length > CHUNK_SIZE + 4
              || pendingBytes + frame.payload.length > MAX_PENDING_BYTES) {
              throw new Error('NearShare 文件数据无效或队列超限');
            }
            pendingBytes += frame.payload.length;
          } else if (frame.type !== NearShareFrameType.DONE || inbox.queuedCount(NearShareFrameType.DONE) > 0) {
            continue;
          }
          inbox.deliver(frame.type, frame.payload);
        }
      } catch (error) {
        end(error instanceof Error ? error : new Error(String(error)));
        conn.close();
      }
    });
    let accepted = false;
    let gateKey = '';
    const received: GsIncomingFile[] = [];
    let failure: Error | undefined = undefined;
    try {
      const offerPayload = await inbox.next(NearShareFrameType.OFFER, HANDSHAKE_TIMEOUT_MS);
      const offer = JSON.parse(GsBytes.decodeText(offerPayload)) as OfferJson;
      NearShareProtocol.validateOffer(offer);
      const peerName = typeof offer.deviceName === 'string' && offer.deviceName.length > 0 ? offer.deviceName : 'Windows PC';
      gateKey = GsCrypto.createToken();
      accepted = await hooks.onIncomingSession(gateKey, peerName, offer.files, offer.pin ?? '');
      if (closed || this.tcpServer === undefined) { throw new Error('NearShare 对端已断开'); }
      const accept: AcceptJson = { ok: accepted, sessionId: offer.sessionId,
        endpoint: { host: '', port: GS_NEARSHARE_PORT, deviceId: '' }, capabilities: NearShareProtocol.capabilities() };
      ready = accepted;
      await conn.sendBytes(encodeFrame(NearShareFrameType.ACCEPT, GsBytes.encodeText(JSON.stringify(accept))));
      if (!accepted) { return; }
      const root = this.context.filesDir + '/incoming/nearshare';
      if (!fs.accessSync(root)) { fs.mkdirSync(root, true); }
      const dir = fs.mkdtempSync(root + '/batch-XXXXXX');
      let totalBytes = 0;
      for (const file of offer.files) { totalBytes += file.size; }
      let receivedBytes = 0;
      for (let index = 0; index < offer.files.length; index++) {
        const meta = offer.files[index];
        received.push(await this.receiveFile(inbox, dir, index, meta, (length: number): void => {
          pendingBytes -= length + 4;
          receivedBytes += length;
          hooks.onProgress(totalBytes > 0 ? Math.min(99.9, receivedBytes / totalBytes * 100) : 99.9);
        }));
        const ack: FileAckJson = { ok: true, index: index };
        await conn.sendBytes(encodeFrame(NearShareFrameType.FILE_ACK, GsBytes.encodeText(JSON.stringify(ack))));
      }
      await inbox.next(NearShareFrameType.DONE, HANDSHAKE_TIMEOUT_MS);
      if (pendingBytes !== 0) { throw new Error('NearShare 收到未请求的文件数据'); }
      await conn.sendBytes(encodeFrame(NearShareFrameType.DONE, new Uint8Array(0)));
    } catch (error) {
      failure = error instanceof Error ? error : new Error(String(error));
      if (!closed) {
        await conn.sendBytes(encodeFrame(NearShareFrameType.ERROR, GsBytes.encodeText(failure.message)))
          .catch((): void => undefined);
      }
    } finally {
      conn.close();
    }
    // SaveButton and media conversion run after the peer receives its wire acknowledgement.
    for (const file of received) { await hooks.onFileReceived(file); }
    if (failure !== undefined) {
      if (accepted) { hooks.onSessionFailed?.(gateKey, failure.message); }
      throw failure;
    }
    hooks.onProgress(100);
  }

  private async receiveFile(data: GsFrameInbox<Uint8Array>, dir: string, index: number,
    meta: GsSessionFileMeta, onDelta: (delta: number) => void): Promise<GsIncomingFile> {
    const sanitized = meta.name.replace(/[\\/:*?"<>|\x00-\x1f]/g, '_');
    const target = dir + '/' + index + '-' + sanitized;
    const handle = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    let received = 0;
    let complete = false;
    try {
      while (received < meta.size) {
        const payload = await data.next(NearShareFrameType.DATA, FILE_ACK_TIMEOUT_MS);
        if (payload.length <= 4 || GsBytes.readU32BE(payload, 0) !== index) {
          throw new Error('NearShare 文件编号无效');
        }
        const chunk = payload.slice(4);
        if (chunk.length > meta.size - received) { throw new Error('NearShare 文件数据超过声明大小'); }
        let written = 0;
        while (written < chunk.length) {
          const count = await fs.write(handle.fd, GsBytes.toArrayBuffer(chunk.subarray(written)));
          if (count <= 0 || count > chunk.length - written) { throw new Error('NearShare 文件写入不完整'); }
          written += count;
        }
        received += written;
        onDelta(written);
      }
      complete = true;
    } finally {
      try { fs.closeSync(handle); }
      finally {
        if (!complete) { try { fs.unlinkSync(target); } catch (_error) {} }
      }
    }
    return { name: meta.name, size: received, savedPath: target, mime: meta.mime };
  }
}
