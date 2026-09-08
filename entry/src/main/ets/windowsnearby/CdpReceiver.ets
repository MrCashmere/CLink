import { LogCapture as Lg } from '../common/LogCapture';
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ByteUtils } from '../common/ByteUtils';

const LOG_TAG = '羊绒互传 CdpReceiver';
const CDP_SIGNATURE = 0x3030;
const CDP_TCP_PORT = 5040;
const CDP_UDP_PORT = 5050;
const MAX_MESSAGE_BYTES = 32 * 1024 * 1024;
const MAX_ACCUMULATED = 2 * 1024 * 1024;

export interface CdpRawFrame {
  readonly type: number;
  readonly messageLength: number;
  readonly version: number;
  readonly flags: number;
  readonly sessionId: number;
  readonly channelId: number;
  readonly fragmentIndex: number;
  readonly fragmentCount: number;
  readonly payloadHex: string;
  readonly rawHex: string;
}

export interface CdpIncomingText {
  readonly text: string;
}

export type CdpStatusListener = (text: string) => void;
export type CdpRawFrameListener = (frame: CdpRawFrame) => void;

export class CdpReceiveListener {
  onStatus(text: string): void {
  }

  onFrame(frame: CdpRawFrame): void {
  }

  onText(text: CdpIncomingText): void {
  }
}

export class CdpReceiver {
  private readonly listener: CdpReceiveListener;
  private tcpServer?: socket.TCPSocketServer;
  private udpServer?: socket.UDPSocket;
  private started = false;

  constructor(listener: CdpReceiveListener) {
    this.listener = listener;
  }

  get isStarted(): boolean {
    return this.started;
  }

  async start(): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    try {
      await this.startTcp();
    } catch (error) {
      Lg.w(LOG_TAG + ': tcp start failed: ' + JSON.stringify(error));
      this.started = false;
      throw new Error('Windows CDP TCP start failed: ' + (error instanceof Error ? error.message : JSON.stringify(error)));
    }
    await this.startUdp();
    this.listener.onText({ text: '已监听 Windows CDP TCP ' + CDP_TCP_PORT + ' / UDP ' + CDP_UDP_PORT });
  }

  stop(): void {
    if (!this.started) {
      return;
    }
    this.started = false;
    const tcp = this.tcpServer;
    this.tcpServer = undefined;
    if (tcp !== undefined) {
      try {
        tcp.off('connect');
        tcp.close().catch((): void => undefined);
      } catch (error) {
        Lg.w(LOG_TAG + ': tcp close failed: ' + JSON.stringify(error));
      }
    }
    const udp = this.udpServer;
    this.udpServer = undefined;
    if (udp !== undefined) {
      try {
        udp.off('message');
        udp.close().catch((): void => undefined);
      } catch (error) {
        Lg.w(LOG_TAG + ': udp close failed: ' + JSON.stringify(error));
      }
    }
  }

  private async startTcp(): Promise<void> {
    const server = socket.constructTCPSocketServerInstance();
    server.on('connect', (conn: socket.TCPSocketConnection): void => {
      Lg.i(LOG_TAG + ': TCP client connected');
      this.handleTcpConnection(conn);
    });
    try {
      await server.listen({ address: '0.0.0.0', family: 1, port: CDP_TCP_PORT });
      this.tcpServer = server;
      Lg.i(LOG_TAG + ': TCP listener on ' + CDP_TCP_PORT);
      this.listener.onText({ text: 'TCP ' + CDP_TCP_PORT + ' 监听已启动' });
    } catch (error) {
      Lg.w(LOG_TAG + ': TCP listen failed: ' + JSON.stringify(error));
      try {
        server.close();
      } catch (closeError) {
        Lg.w(LOG_TAG + ': TCP close after listen failure failed: ' + JSON.stringify(closeError));
      }
      throw new Error('Windows CDP TCP listen failed: ' + (error instanceof Error ? error.message : JSON.stringify(error)));
    }
  }

  private async startUdp(): Promise<void> {
    const udp = socket.constructUDPSocketInstance();
    udp.on('message', (value: socket.SocketMessageInfo): void => {
      const bytes = new Uint8Array(value.message);
      Lg.i(LOG_TAG + ': UDP datagram from ' + value.remoteInfo.address + ':' + value.remoteInfo.port
        + ' len=' + bytes.length + ' hex=' + ByteUtils.toHex(bytes));
    });
    try {
      await udp.bind({ address: '0.0.0.0', port: CDP_UDP_PORT, family: 1 });
      this.udpServer = udp;
      Lg.i(LOG_TAG + ': UDP bind on ' + CDP_UDP_PORT);
      this.listener.onText({ text: 'UDP ' + CDP_UDP_PORT + ' 监听已绑定' });
    } catch (error) {
      Lg.w(LOG_TAG + ': UDP bind failed: ' + JSON.stringify(error));
      try {
        udp.close();
      } catch (closeError) {
        Lg.w(LOG_TAG + ': UDP close after bind failure failed: ' + JSON.stringify(closeError));
      }
    }
  }

  private handleTcpConnection(conn: socket.TCPSocketConnection): void {
    let buffer = new Uint8Array(0);
    conn.on('message', (info: socket.SocketMessageInfo): void => {
      const chunk = new Uint8Array(info.message);
      buffer = ByteUtils.concat([buffer, chunk]);
      if (buffer.length > MAX_ACCUMULATED) {
        Lg.w(LOG_TAG + ': accumulated buffer too large, resetting');
        buffer = new Uint8Array(0);
        return;
      }
      const parsed = CdpReceiver.tryParseFrames(buffer);
      buffer = parsed.rest;
      for (const frame of parsed.frames) {
        Lg.i(LOG_TAG + ': frame type=' + frame.type + ' session=' + frame.sessionId.toString(16)
          + ' channel=' + frame.channelId.toString(16) + ' hex=' + frame.rawHex);
        this.listener.onFrame(frame);
      }
    });
    conn.on('close', (): void => {
      Lg.i(LOG_TAG + ': TCP client closed');
    });
    conn.on('error', (error: BusinessError): void => {
      Lg.w(LOG_TAG + ': TCP client error: ' + JSON.stringify(error));
    });
  }

  private static tryParseFrames(buffer: Uint8Array): CdpParseResult {
    const frames: CdpRawFrame[] = [];
    let head = 0;
    while (true) {
      if (buffer.length - head < 12) {
        break;
      }
      const signature = CdpReceiver.readU16BE(buffer, head);
      if (signature !== CDP_SIGNATURE) {
        Lg.w(LOG_TAG + ': bad signature 0x' + signature.toString(16) + ' at offset ' + head
          + ' hex=' + ByteUtils.toHex(buffer.slice(head, Math.min(head + 24, buffer.length))));
        head += 1;
        continue;
      }
      const messageLength = CdpReceiver.readU16BE(buffer, head + 2);
      if (messageLength < 24 || messageLength > MAX_MESSAGE_BYTES) {
        Lg.w(LOG_TAG + ': improbable message length ' + messageLength);
        break;
      }
      if (buffer.length - head < messageLength) {
        break;
      }
      const raw = buffer.slice(head, head + messageLength);
      const frame = CdpHeaderReader.readFrame(raw);
      frames.push(frame);
      head += messageLength;
    }
    const rest = head >= buffer.length ? new Uint8Array(0) : buffer.slice(head);
    return { frames, rest } as CdpParseResult;
  }

  private static readU16BE(bytes: Uint8Array, offset: number): number {
    return ((bytes[offset] << 8) | bytes[offset + 1]) >>> 0;
  }
}

interface CdpParseResult {
  frames: CdpRawFrame[];
  rest: Uint8Array;
}

class CdpHeaderReader {
  private readonly bytes: Uint8Array;
  private offset: number = 0;

  constructor(bytes: Uint8Array) {
    this.bytes = bytes;
  }

  static readFrame(raw: Uint8Array): CdpRawFrame {
    const reader = new CdpHeaderReader(raw);
    return reader.read(raw.length);
  }

  private read(rawLength: number): CdpRawFrame {
    this.skip(2); // signature
    const messageLength = this.readU16BE();
    const version = this.readU8();
    const type = this.readU8();
    const flags = this.readI16BE();
    this.skip(4); // sequence number
    this.skip(8); // request id
    const fragmentIndex = this.readU16BE();
    const fragmentCount = this.readU16BE();
    const sessionId = this.readU64BE();
    const channelId = this.readU64BE();
    this.skipAdditionalHeaders();
    const payloadHex = ByteUtils.toHex(this.bytes.slice(this.offset));
    const rawHex = ByteUtils.toHex(this.bytes.slice(0, rawLength));
    return {
      type,
      messageLength,
      version,
      flags,
      sessionId,
      channelId,
      fragmentIndex,
      fragmentCount,
      payloadHex,
      rawHex
    };
  }

  private skipAdditionalHeaders(): void {
    while (true) {
      if (this.remaining < 2) {
        return;
      }
      const headerType = this.readU8();
      const headerSize = this.readU8();
      if (headerType === 0 && headerSize === 0) {
        return;
      }
      if (headerSize === 0) {
        return;
      }
      if (this.remaining < headerSize) {
        break;
      }
      this.skip(headerSize);
    }
  }

  private get remaining(): number {
    return this.bytes.length - this.offset;
  }

  private readU8(): number {
    const value = this.bytes[this.offset];
    this.offset += 1;
    return value;
  }

  private readU16BE(): number {
    const value = ((this.bytes[this.offset] << 8) | this.bytes[this.offset + 1]) >>> 0;
    this.offset += 2;
    return value;
  }

  private readI16BE(): number {
    const value = this.readU16BE();
    return value & 0x8000 !== 0 ? value - 0x10000 : value;
  }

  private readU32BE(): number {
    const value = ((this.bytes[this.offset] * 0x1000000) + (this.bytes[this.offset + 1] << 16)
      + (this.bytes[this.offset + 2] << 8) + this.bytes[this.offset + 3]) >>> 0;
    this.offset += 4;
    return value;
  }

  private readU64BE(): number {
    const high = this.readU32BE();
    const low = this.readU32BE();
    return high * 0x100000000 + low;
  }

  private skip(length: number): void {
    this.offset += length;
  }
}
