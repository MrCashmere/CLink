import { LogCapture as Lg } from '../common/LogCapture';
/**
 * MS-CDP client (sender) for Windows Nearby Sharing.
 *
 * The phone connects to a Windows host on TCP 5040, completes the
 * ConnectResponse -> DeviceAuth -> AuthDone -> DeviceInfo handshake, opens the
 * NearShare handshake + platform channels, sends StartTransfer and then serves
 * the pull-model FetchDataRequest stream by sending FetchDataResponse chunks.
 *
 * Independent of the old gs JSON protocol and of Quick Share.
 */

import { socket } from '@kit.NetworkKit';
import netConnection from '@ohos.net.connection';
import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { ByteUtils } from '../common/ByteUtils';
import {
  CdpCommonHeader,
  CdpWriter,
  CdpReader,
  CdpMessageType,
  CdpMessageFlags,
  CdpAdditionalHeaderType,
  CdpBinaryMsgHeader,
  CdpAdditionalHeader,
  CDP_DEFAULT_FRAGMENT_SIZE
} from '../protocol/windowsnearby/CdpCodec';
import { CdpCryptor } from '../protocol/windowsnearby/CdpCryptor';
import { CdpSecurity } from '../protocol/windowsnearby/CdpSecurity';
import {
  CdpConnectionHeader,
  CdpConnectionRequest,
  CdpConnectionResponse,
  CdpAuthenticationPayload,
  CdpResultPayload,
  CdpStartChannelRequest,
  CdpStartChannelResponse,
  CdpDeviceInfoMessage,
  CdpConnectionType,
  CdpConnectionMode,
  CdpCurveType,
  CdpResult,
  CdpConnectionBody
} from '../protocol/windowsnearby/CdpConnection';
import { CdpValueSet } from '../protocol/windowsnearby/CdpBond';

const LOG_TAG = '羊绒互传 WindowsNearbySender';
const APP_HANDSHAKE_ID = '0d472c30-80b5-4722-a279-0f3b97f0dcf2';
const APP_PLATFORM_NAME = 'NearSharePlatform';
const CONNECT_TIMEOUT_MS = 8000;
const HANDSHAKE_TIMEOUT_MS = 15000;
const MAX_FETCH_BYTES = 16 * 1024 * 1024;
const MAX_INPUT_QUEUE_BYTES = 32 * 1024 * 1024;
const MAX_FETCH_RANGES = 8192;

interface SentRange {
  start: number;
  end: number;
}
const SESSION_ID_HOST_FLAG = 0x80000000;

export interface WindowsNearbyOutgoingFile {
  readonly path: string;
  readonly name: string;
  readonly size: number;
}

export class WindowsNearbySenderListener {
  onStatus(text: string): void {
  }

  onProgress(percent: number): void {
  }

  onCompleted(): void {
  }
}

interface CdpClientMsg {
  readonly kind: 'connect' | 'control' | 'session';
  readonly header: CdpCommonHeader;
  readonly connType: number;
  readonly controlType: number;
  readonly channelId: number;
  readonly binaryHeader: CdpBinaryMsgHeader;
  readonly valueSet: CdpValueSet;
  readonly reader: CdpReader;
}

export class WindowsNearbySender {
  private readonly context: common.Context;
  private readonly listener: WindowsNearbySenderListener;
  private readonly security: CdpSecurity;
  private tcp?: socket.TCPSocket;
  private buffer: Uint8Array = new Uint8Array(0);

  private cryptor?: CdpCryptor;
  private localNonce: Uint8Array = new Uint8Array(8);
  private remoteNonce: Uint8Array = new Uint8Array(8);
  private localSessionHi: number = 0;
  private nextLocalSessionId: number = 1;
  private seq: number = 0;
  private remoteSessionHi: number = 0;
  private requestIdCounter: number = 1;

  private handshakeChannelId: number = 0;
  private platformChannelId: number = 0;
  private transferStarted = false;
  private operationId: string = '';
  private files: WindowsNearbyOutgoingFile[] = [];
  private sourcePaths: string[] = [];
  private spoolDir: string = '';
  private sentRanges: Map<number, SentRange[]> = new Map();
  private readQueue: Promise<void> = Promise.resolve();
  private queuedReadBytes: number = 0;
  private bytesToSend: number = 0;
  private bytesSent: number = 0;
  private completionResolve?: () => void;
  private completionReject?: (error: Error) => void;
  private completionError?: Error;
  private completed: boolean = false;
  private completionTimer: number = -1;
  private sending: boolean = false;
  private writeQueue: Promise<void> = Promise.resolve();

  private waiterKind?: 'connect' | 'control' | 'session';
  private waiterReject?: (error: Error) => void;
  private pendingMessages: CdpClientMsg[] = [];
  private waiterChannel?: number;
  private waiterResolve?: (msg: CdpClientMsg) => void;

  private constructor(context: common.Context, listener: WindowsNearbySenderListener, security: CdpSecurity) {
    this.context = context;
    this.listener = listener;
    this.security = security;
  }

  static async create(context: common.Context, listener: WindowsNearbySenderListener): Promise<WindowsNearbySender> {
    const security = await CdpSecurity.load(context);
    return new WindowsNearbySender(context, listener, security);
  }

  async send(host: string, port: number, files: WindowsNearbyOutgoingFile[]): Promise<void> {
    if (this.sending) {
      throw new Error('另一个 Windows 发送任务正在进行');
    }
    this.sending = true;
    this.completed = false;
    this.completionError = undefined;
    this.pendingMessages = [];
    this.readQueue = Promise.resolve();
    this.queuedReadBytes = 0;
    try {
      await this.runSend(host, port, files);
    } finally {
      this.cleanupSources();
      this.sentRanges.clear();
      this.sending = false;
      this.pendingMessages = [];
      if (this.completionTimer !== -1) {
        clearTimeout(this.completionTimer);
        this.completionTimer = -1;
      }
    }
  }

  private async runSend(host: string, port: number, files: WindowsNearbyOutgoingFile[]): Promise<void> {
    if (host.length === 0) {
      throw new Error('缺少 Windows 主机 IP');
    }
    this.files = files;
    Lg.i(LOG_TAG + ': sending to ' + host + ':' + port + ' files=' + files.length);
    this.bytesToSend = 0;
    this.bytesSent = 0;
    this.transferStarted = false;
    this.cryptor = undefined;
    this.buffer = new Uint8Array(0);
    for (const file of files) {
      if (!Number.isSafeInteger(file.size) || file.size < 0) {
        throw new Error('发送源文件大小无效');
      }
      this.bytesToSend += file.size;
    }
    if (files.length === 0 || !Number.isSafeInteger(this.bytesToSend)) { throw new Error('发送文件列表无效'); }
    // A picker URI need not support seeking. Copy it once into a seekable file
    // using a fixed-size buffer; ordinary sandbox paths can be read in place.
    for (let i = 0; i < files.length; i++) {
      this.sourcePaths.push(await this.prepareSource(files[i], i));
      this.assertPreparing();
    }

    const tcp = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    try {
      await tcp.bind({ address: '0.0.0.0', family: 1, port: 0 });
      this.assertSocket(tcp);
      tcp.on('message', (info: socket.SocketMessageInfo): void => {
        if (this.tcp !== tcp) { return; }
        this.onData(new Uint8Array(info.message));
      });
      tcp.on('error', (error: BusinessError): void => {
        if (this.tcp !== tcp) { return; }
        this.listener.onStatus('发送 socket 错误：' + JSON.stringify(error));
        this.failCompletion(new Error('发送连接错误：' + error.message));
      });
      tcp.on('close', (): void => {
        if (this.tcp !== tcp) { return; }
        this.listener.onStatus('发送 socket 已关闭');
        this.failCompletion(new Error('对端连接已断开，发送未完成'));
      });
      await this.connectTcp(tcp, host, port);
      Lg.i(LOG_TAG + ': TCP connected to ' + host + ':' + port);
      // The CDP handshake has no per-step acknowledgement timeout on its own; a peer
      // that accepts TCP but never answers ConnectResponse/DeviceAuth would otherwise
      // hang send() forever with no toast/progress ("完全没反应"). Bound it so a
      // stalled handshake surfaces a clear send failure instead.
      await withTimeout(this.runHandshake(), HANDSHAKE_TIMEOUT_MS, 'CDP 握手超时');
      await this.awaitCompletion();
    } catch (error) {
      Lg.w(LOG_TAG + ': send failed: ' + (error instanceof Error ? (error.stack ?? error.message) : JSON.stringify(error)));
      throw (error instanceof Error ? error : new Error(JSON.stringify(error)));
    } finally {
      await this.close();
    }
  }

  async close(): Promise<void> {
    if (this.sending && !this.completed) {
      this.failCompletion(new Error('发送已停止'));
    }
    const tcp = this.tcp;
    this.tcp = undefined;
    if (tcp !== undefined) {
      try {
        tcp.off('message');
        tcp.off('close');
        tcp.off('error');
      } catch (error) {
        Lg.w(LOG_TAG + ': tcp off failed: ' + JSON.stringify(error));
      }
      await tcp.close().catch((): void => undefined);
    }
  }

  private async connectTcp(tcp: socket.TCPSocket, host: string, port: number): Promise<void> {
    try {
      await tcp.connect({ address: { address: host, family: 1, port }, timeout: CONNECT_TIMEOUT_MS });
    } catch (error) {
      Lg.w(LOG_TAG + ': TCP connect failed to ' + host + ':' + port + ': ' + JSON.stringify(error));
      throw new Error('TCP connect failed: ' + (error instanceof Error ? error.message : JSON.stringify(error)));
    }
  }

  private onData(chunk: Uint8Array): void {
    const ownedSocket = this.tcp;
    if (ownedSocket === undefined || this.completionError !== undefined) { return; }
    if (this.buffer.length + chunk.length + this.queuedReadBytes > MAX_INPUT_QUEUE_BYTES) {
      this.failCompletion(new Error('Windows CDP 接收队列超限'));
      return;
    }
    this.buffer = ByteUtils.concat([this.buffer, chunk]);
    while (this.buffer.length >= 4) {
      const messageLength = CdpCommonHeader.readRawMessageLength(this.buffer);
      if (messageLength < 42 || messageLength > MAX_INPUT_QUEUE_BYTES) {
        this.failCompletion(new Error('Windows CDP 帧长度无效'));
        return;
      }
      if (this.buffer.length < messageLength) { return; }
      const frame = this.buffer.slice(0, messageLength);
      this.buffer = this.buffer.slice(messageLength);
      this.queuedReadBytes += frame.length;
      this.readQueue = this.readQueue.then(async (): Promise<void> => {
        if (this.tcp !== ownedSocket || this.completionError !== undefined) { return; }
        await this.processFrame(frame);
      }).catch((error: Error): void => {
        if (this.tcp === ownedSocket) {
          Lg.w(LOG_TAG + ': CDP process error: ' + error.message);
          this.failCompletion(error);
        }
      }).finally((): void => {
        if (this.tcp === ownedSocket) { this.queuedReadBytes -= frame.length; }
      });
    }
  }

  private async processFrame(frame: Uint8Array): Promise<void> {
    const ownedSocket = this.tcp;
    const reader = new CdpReader(frame);
    const header = reader.readHeader();
    Lg.i(LOG_TAG + ': recv frame type=' + header.type + ' seq=' + header.sequenceNumber +
      ' enc=' + header.hasFlag(CdpMessageFlags.SessionEncrypted) + ' len=' + frame.length);
    let payload: Uint8Array;
    const encrypted = header.hasFlag(CdpMessageFlags.SessionEncrypted);
    if (encrypted) {
      const cryptor = this.cryptor;
      if (cryptor === undefined || !header.hasFlag(CdpMessageFlags.HasHMAC)) {
        throw new Error('Windows CDP 帧缺少会话认证');
      }
      payload = await cryptor.decryptFrame(frame, header);
    } else {
      if (this.cryptor !== undefined || header.type !== CdpMessageType.Connect) {
        throw new Error('Windows CDP 收到未认证的明文帧');
      }
      payload = frame.slice(header.calcSize());
    }
    if (ownedSocket === undefined || ownedSocket !== this.tcp) { return; }

    if (header.type === CdpMessageType.Connect) {
      const payloadReader = new CdpReader(payload);
      const connHeader = CdpConnectionHeader.parse(payloadReader);
      this.deliver({
        kind: 'connect',
        header,
        connType: connHeader.messageType,
        controlType: -1,
        channelId: -1,
        binaryHeader: new CdpBinaryMsgHeader(0),
        valueSet: new CdpValueSet(),
        reader: payloadReader
      });
      return;
    }
    if (header.type === CdpMessageType.Control) {
      const payloadReader = new CdpReader(payload);
      const controlType = payloadReader.readU8();
      Lg.i(LOG_TAG + ': recv Control type=' + controlType);
      this.deliver({
        kind: 'control',
        header,
        connType: -1,
        controlType,
        channelId: -1,
        binaryHeader: new CdpBinaryMsgHeader(0),
        valueSet: new CdpValueSet(),
        reader: payloadReader
      });
      return;
    }
    if (header.type === CdpMessageType.Session) {
      const payloadReader = new CdpReader(payload);
      const binaryHeader = payloadReader.readBinaryMsgHeader();
      const valueSet = CdpValueSet.parse(payloadReader.readRemaining());
      const channelId = readU32BE(header.channelId, 4);
      Lg.i(LOG_TAG + ': recv Session ch=' + channelId + ' msgId=' + binaryHeader.messageId);
      if (this.transferStarted && channelId === this.platformChannelId) {
        await this.handleFetchRequest(binaryHeader, valueSet);
        return;
      }
      this.deliver({
        kind: 'session',
        header,
        connType: -1,
        controlType: -1,
        channelId,
        binaryHeader,
        valueSet,
        reader: payloadReader
      });
      return;
    }
  }

  private async runHandshake(): Promise<void> {
    const ownedSocket = this.tcp;
    // 1. ConnectRequest.
    this.localNonce = await randomBytes(8);
    this.assertSocket(ownedSocket);
    this.localSessionHi = this.nextLocalSessionId++;
    this.remoteSessionHi = 0;
    const point = this.security.publicPoint;
    await this.sendConnect(CdpConnectionType.ConnectRequest, () => {
      const request = new CdpConnectionRequest();
      request.curveType = CdpCurveType.CT_NIST_P256_KDF_SHA512;
      request.hmacSize = 32;
      request.nonceBytes = this.localNonce;
      request.messageFragmentSize = 16384;
      request.publicKeyX = point.x;
      request.publicKeyY = point.y;
      return request;
    });
    Lg.i(LOG_TAG + ': sent ConnectRequest');

    // 2. ConnectResponse -> derive key.
    const connectResp = await this.awaitMessage('connect', CdpConnectionType.ConnectResponse);
    const connResponse = CdpConnectionResponse.parse(connectResp.reader);
    this.remoteNonce = connResponse.nonceBytes;
    this.remoteSessionHi = readU32BE(connectResp.header.sessionId, 0) & ~SESSION_ID_HOST_FLAG;
    const secret = await this.security.deriveSharedSecret(connResponse.publicKeyX, connResponse.publicKeyY);
    this.assertSocket(ownedSocket);
    this.cryptor = CdpSecurity.createCryptor(secret);
    Lg.i(LOG_TAG + ': session cryptor established');
    this.listener.onStatus('CDP 握手：会话加密已建立');

    // 3. DeviceAuthRequest.
    const deviceSigned = await this.security.signThumbprint(this.remoteNonce, this.localNonce);
    this.assertSocket(ownedSocket);
    const deviceAuthPayload = new CdpAuthenticationPayload();
    deviceAuthPayload.certificate = this.security.certificateDer;
    deviceAuthPayload.signedThumbprint = deviceSigned;
    await this.sendConnected(CdpConnectionType.DeviceAuthRequest, () => deviceAuthPayload);
    Lg.i(LOG_TAG + ': sent DeviceAuthRequest');

    // 4. DeviceAuthResponse -> verify -> UserDeviceAuthRequest.
    const deviceAuthResp = await this.awaitMessage('connect', CdpConnectionType.DeviceAuthResponse);
    await this.verifyAuthPayload(deviceAuthResp.reader);
    this.assertSocket(ownedSocket);
    Lg.i(LOG_TAG + ': verified DeviceAuthResponse');
    const userSigned = await this.security.signThumbprint(this.remoteNonce, this.localNonce);
    this.assertSocket(ownedSocket);
    const userDeviceAuth = new CdpAuthenticationPayload();
    userDeviceAuth.certificate = this.security.certificateDer;
    userDeviceAuth.signedThumbprint = userSigned;
    await this.sendConnected(CdpConnectionType.UserDeviceAuthRequest, () => userDeviceAuth);
    Lg.i(LOG_TAG + ': sent UserDeviceAuthRequest');

    // 5. UserDeviceAuthResponse -> verify -> AuthDoneRequest.
    const userAuth = await this.awaitMessage('connect', CdpConnectionType.UserDeviceAuthResponse);
    await this.verifyAuthPayload(userAuth.reader);
    this.assertSocket(ownedSocket);
    Lg.i(LOG_TAG + ': verified UserDeviceAuthResponse');
    await this.sendConnected(CdpConnectionType.AuthDoneRequest, () => new CdpResultPayload(CdpResult.Success));
    Lg.i(LOG_TAG + ': sent AuthDoneRequest');

    // 6. AuthDoneRespone.
    const authDone = await this.awaitMessage('connect', CdpConnectionType.AuthDoneRespone);
    const authResult = CdpResultPayload.parse(authDone.reader);
    if (authResult.result !== CdpResult.Success) {
      throw new Error('CDP 认证失败，对端返回 ' + authResult.result);
    }
    Lg.i(LOG_TAG + ': CDP auth completed');
    this.listener.onStatus('CDP 认证完成');

    // 7. DeviceInfoMessage.
    const deviceInfoJson = await buildSenderDeviceInfoJson(SettingsAliasProvider.instance.alias());
    this.assertSocket(ownedSocket);
    await this.sendConnected(CdpConnectionType.DeviceInfoMessage, () => {
      const info = new CdpDeviceInfoMessage();
      info.deviceInfoJson = deviceInfoJson;
      return info;
    });
    Lg.i(LOG_TAG + ': sent DeviceInfoMessage len=' + deviceInfoJson.length);
    // The reference client does NOT wait for DeviceInfoResponse (it proceeds to
    // the channel handshake immediately). Awaited responses from Windows would
    // otherwise stall the flow.

    // 9. Open the handshake channel.
    await this.openChannel(APP_HANDSHAKE_ID.toUpperCase(), APP_PLATFORM_NAME, (channelId: number): void => {
      this.handshakeChannelId = channelId;
    });

    // 10. HandShakeRequest / response.
    this.operationId = util.generateRandomUUID().toUpperCase();
    await this.sendValueSetOnChannel(this.handshakeChannelId, buildHandshakeRequest(this.operationId), 0);
    const handshake = await this.awaitMessage('session', this.handshakeChannelId);
    if (handshake.valueSet.getUInt32('VersionHandShakeResult') !== 1) {
      throw new Error('CDP 平台握手失败');
    }

    // 11. Open the NearShare platform channel.
    await this.openChannel(this.operationId, APP_PLATFORM_NAME, (channelId: number): void => {
      this.platformChannelId = channelId;
    });

    // 12. StartTransfer.
    this.transferStarted = true;
    await this.sendValueSetOnChannel(this.platformChannelId, buildStartTransfer(this.files), 10);
    this.listener.onStatus('已发送 StartTransfer，等待 Windows 拉取');
  }

  private async verifyAuthPayload(reader: CdpReader): Promise<void> {
    const payload = CdpAuthenticationPayload.parse(reader);
    const ok = await this.security.verifyThumbprint(payload.certificate, payload.signedThumbprint, this.remoteNonce, this.localNonce);
    if (!ok) {
      throw new Error('CDP 对端证书签名校验失败');
    }
  }

  private async handleFetchRequest(binaryHeader: CdpBinaryMsgHeader, valueSet: CdpValueSet): Promise<void> {
    const ownedSocket = this.tcp;
    const control = valueSet.getUInt32('ControlMessage');
    if (control === 5) { throw new Error('Windows 对端取消传输'); }
    if (control === 2) { // CompleteTransfer
      if (this.bytesSent !== this.bytesToSend) { throw new Error('Windows 在文件传完前确认了完成'); }
      this.listener.onStatus('Windows 已确认接收完成');
      this.resolveCompletion();
      this.listener.onCompleted();
      await this.close();
      return;
    }
    if (control !== 3) { // FetchDataRequest
      return;
    }
    this.armCompletionTimeout();
    const contentId = valueSet.getUInt32('ContentId');
    const start = valueSet.getUInt64('BlobPosition');
    const length = valueSet.getUInt32('BlobSize');
    const file = this.files[contentId];
    if (file === undefined) {
      throw new Error('CDP 未知 ContentId ' + contentId);
    }
    const blob = await this.readBlob(start, length, contentId);
    this.assertSocket(ownedSocket);
    const response = new CdpValueSet();
    response.addUInt32('ControlMessage', 4); // FetchDataResponse
    response.addUInt32('ContentId', contentId);
    response.addUInt64('BlobPosition', start);
    response.addUInt8Array('DataBlob', blob);
    await this.sendValueSetOnChannel(this.platformChannelId, response, binaryHeader.messageId);
    this.assertSocket(ownedSocket);
    if (blob.length > 0) {
      this.bytesSent += this.recordSentRange(contentId, start, start + blob.length);
    }
    this.listener.onProgress(this.bytesToSend === 0 ? 100 : Math.floor(this.bytesSent * 100 / this.bytesToSend));
  }

  private awaitCompletion(): Promise<void> {
    if (this.completionError !== undefined) {
      return Promise.reject(this.completionError);
    }
    if (this.completed) {
      return Promise.resolve();
    }
    return new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      this.completionResolve = resolve;
      this.completionReject = reject;
      this.armCompletionTimeout();
    });
  }

  private armCompletionTimeout(): void {
    if (this.completionTimer !== -1) {
      clearTimeout(this.completionTimer);
    }
    this.completionTimer = setTimeout((): void => {
      this.completionTimer = -1;
      this.failCompletion(new Error('Windows 对端长时间未响应，发送已超时'));
    }, 120000);
  }

  private failCompletion(error: Error): void {
    if (this.completed) {
      return;
    }
    this.completionError = error;
    if (this.completionTimer !== -1) {
      clearTimeout(this.completionTimer);
      this.completionTimer = -1;
    }
    const reject: ((error: Error) => void) | undefined = this.completionReject;
    this.completionReject = undefined;
    this.completionResolve = undefined;
    const rejectWaiter = this.waiterReject;
    this.waiterReject = undefined;
    this.waiterResolve = undefined;
    this.waiterKind = undefined;
    this.waiterChannel = undefined;
    rejectWaiter?.(error);
    reject?.(error);
  }

  private resolveCompletion(): void {
    this.completed = true;
    this.completionReject = undefined;
    if (this.completionTimer !== -1) {
      clearTimeout(this.completionTimer);
      this.completionTimer = -1;
    }
    if (this.completionResolve !== undefined) {
      const resolve = this.completionResolve;
      this.completionResolve = undefined;
      resolve();
    }
  }

  private recordSentRange(contentId: number, start: number, end: number): number {
    const ranges = this.sentRanges.get(contentId) ?? [];
    let index = 0;
    while (index < ranges.length && ranges[index].end < start) { index += 1; }
    let fresh = end - start;
    let from = start;
    let to = end;
    let next = index;
    while (next < ranges.length && ranges[next].start <= to) {
      const range = ranges[next];
      fresh -= Math.max(0, Math.min(end, range.end) - Math.max(start, range.start));
      from = Math.min(from, range.start);
      to = Math.max(to, range.end);
      next += 1;
    }
    if (next === index && ranges.length >= MAX_FETCH_RANGES) { throw new Error('Windows CDP 请求过于零散'); }
    ranges.splice(index, next - index, { start: from, end: to });
    this.sentRanges.set(contentId, ranges);
    return fresh;
  }

  private async readBlob(start: number, length: number, contentId: number): Promise<Uint8Array> {
    const path = this.sourcePaths[contentId];
    const size = this.files[contentId]?.size ?? -1;
    if (path === undefined || !Number.isSafeInteger(start) || start < 0 ||
      !Number.isSafeInteger(length) || length < 0 || length > MAX_FETCH_BYTES || length > size - start) {
      throw new Error('Windows CDP 文件读取范围无效');
    }
    const result = new Uint8Array(length);
    const handle = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      let read = 0;
      while (read < length) {
        const buffer = new ArrayBuffer(Math.min(1024 * 1024, length - read));
        const count = await fs.read(handle.fd, buffer, { offset: start + read, length: buffer.byteLength });
        if (count <= 0 || count > buffer.byteLength) { throw new Error('发送源文件未完整读入'); }
        result.set(new Uint8Array(buffer, 0, count), read);
        read += count;
      }
    } finally {
      fs.closeSync(handle);
    }
    return result;
  }

  private assertPreparing(): void {
    if (this.completionError !== undefined) { throw this.completionError; }
  }

  private async prepareSource(file: WindowsNearbyOutgoingFile, index: number): Promise<string> {
    const source = fs.openSync(file.path, fs.OpenMode.READ_ONLY);
    try {
      if (fs.statSync(source.fd).size !== file.size) { throw new Error('发送源文件大小已变化，请重新选择文件'); }
      if (file.path.startsWith('/')) { return file.path; }
      if (this.spoolDir.length === 0) {
        this.spoolDir = fs.mkdtempSync(this.context.cacheDir + '/windows-send-XXXXXX');
      }
      const path = this.spoolDir + '/' + index;
      const target = fs.openSync(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        let copied = 0;
        while (copied < file.size) {
          this.assertPreparing();
          const buffer = new ArrayBuffer(Math.min(1024 * 1024, file.size - copied));
          const read = await fs.read(source.fd, buffer);
          if (read <= 0 || read > buffer.byteLength) { throw new Error('发送源文件未完整读入'); }
          let wrote = 0;
          while (wrote < read) {
            const count = await fs.write(target.fd, buffer.slice(wrote, read));
            if (count <= 0 || count > read - wrote) { throw new Error('无法写入发送缓存'); }
            wrote += count;
          }
          copied += wrote;
        }
        return path;
      } catch (error) {
        try { fs.unlinkSync(path); } catch (_error) {}
        throw (error instanceof Error ? error : new Error(String(error)));
      } finally {
        fs.closeSync(target);
      }
    } finally {
      fs.closeSync(source);
    }
  }

  private cleanupSources(): void {
    if (this.spoolDir.length > 0) {
      try { fs.rmdirSync(this.spoolDir); } catch (_error) {}
      this.spoolDir = '';
    }
    this.sourcePaths = [];
  }

  private async sendConnect(connectionType: number, build: () => CdpConnectionBody): Promise<void> {
    const header = new CdpCommonHeader();
    header.type = CdpMessageType.Connect;
    header.additionalHeaders.push(new CdpAdditionalHeader(CdpAdditionalHeaderType.ChannelHostSettings, ByteUtils.writeU32BE(0x70000003)));
    header.additionalHeaders.push(new CdpAdditionalHeader(CdpAdditionalHeaderType.PeerCapabilities, u64ToBytes(0x1f)));
    header.additionalHeaders.push(new CdpAdditionalHeader(CdpAdditionalHeaderType.Header131, u64ToBytes(7)));
    const writer = new CdpWriter();
    new CdpConnectionHeader(connectionType, CdpConnectionMode.Proximal).write(writer);
    build().write(writer);
    await this.sendRaw(header, writer.finish());
  }

  private async sendConnected(connectionType: number, build: () => CdpConnectionBody): Promise<void> {
    const header = this.newHeader(CdpMessageType.Connect);
    const writer = new CdpWriter();
    new CdpConnectionHeader(connectionType, CdpConnectionMode.Proximal).write(writer);
    build().write(writer);
    await this.sendRaw(header, writer.finish());
  }

  private async openChannel(appId: string, appName: string, onChannel: (id: number) => void): Promise<void> {
    const header = this.newHeader(CdpMessageType.Control);
    header.requestId = u64ToBytes(this.requestIdCounter++);
    const writer = new CdpWriter();
    writer.writeU8(0); // StartChannelRequest
    const request = new CdpStartChannelRequest();
    request.id = appId;
    request.name = appName;
    request.write(writer);
    Lg.i(LOG_TAG + ': openChannel request type=Control msg=StartChannelRequest app=' + appId + ' name=' + appName);
    await this.sendRaw(header, writer.finish());
    const response = await this.awaitMessage('control', CdpControlTypeStartChannelResponse);
    const channelResponse = CdpStartChannelResponse.parse(response.reader);
    Lg.i(LOG_TAG + ': openChannel response result=' + channelResponse.result + ' channelId=' + channelResponse.channelId);
    if (channelResponse.result !== 0) {
      throw new Error('CDP 打开通道失败 ' + appName);
    }
    onChannel(channelResponse.channelId);
  }

  private async sendValueSetOnChannel(channelId: number, valueSet: CdpValueSet, messageId: number): Promise<void> {
    const binaryHeader = new CdpBinaryMsgHeader(messageId);
    const payloadWriter = new CdpWriter();
    payloadWriter.writeU32BE(1); // fragmentCount
    payloadWriter.writeU32BE(0); // fragmentIndex
    payloadWriter.writeU32BE(binaryHeader.messageId);
    const rawValueSet = valueSet.serialize();
    payloadWriter.writeBytes(rawValueSet);
    const payload = payloadWriter.finish();
    const header = this.newChannelHeader(channelId);
    header.additionalHeaders.push(new CdpAdditionalHeader(CdpAdditionalHeaderType.CorrelationVector, buildCorrelationVector()));
    Lg.i(LOG_TAG + ': send Session ch=' + channelId + ' msgId=' + messageId + ' vsLen=' + rawValueSet.length +
      ' vsHead=' + ByteUtils.toHex(rawValueSet.slice(0, 12)));
    await this.sendFragmented(header, payload);
  }

  /** CDP transport-level fragmentation (MessageFragmenter): each fragment is a
   *  separate encrypted frame carrying its own fragmentCount/Index. */
  private async sendFragmented(header: CdpCommonHeader, payload: Uint8Array): Promise<void> {
    if (payload.length <= CDP_DEFAULT_FRAGMENT_SIZE) {
      header.fragmentCount = 1;
      header.fragmentIndex = 0;
      await this.sendRaw(header, payload);
      return;
    }
    const count = Math.floor((payload.length + CDP_DEFAULT_FRAGMENT_SIZE - 1) / CDP_DEFAULT_FRAGMENT_SIZE);
    header.fragmentCount = count;
    for (let index = 0; index < count; index++) {
      const start = index * CDP_DEFAULT_FRAGMENT_SIZE;
      const end = Math.min(start + CDP_DEFAULT_FRAGMENT_SIZE, payload.length);
      const fragment = payload.slice(start, end);
      const fragmentHeader = this.cloneHeader(header);
      fragmentHeader.fragmentIndex = index;
      await this.sendRaw(fragmentHeader, fragment);
    }
  }

  private async sendRaw(header: CdpCommonHeader, payload: Uint8Array): Promise<void> {
    const ownedSocket = this.tcp;
    if (this.cryptor !== undefined) {
      const frame = await this.cryptor.encryptMessage(header, payload);
      this.assertSocket(ownedSocket);
      await this.writeFrame(frame);
    } else {
      const writer = new CdpWriter();
      header.setPayloadLength(payload.length);
      header.sessionId = this.sessionIdBytes();
      writer.writeHeader(header);
      await this.writeFrame(ByteUtils.concat([writer.finish(), payload]));
    }
  }

  private async writeFrame(frame: Uint8Array): Promise<void> {
    if (this.tcp === undefined) {
      throw new Error('发送 socket 未连接');
    }
    const tcp = this.tcp;
    // Serialise all writes so a burst of FetchDataResponse chunks never issues
    // overlapping socket.send calls (the CDP reference locks the output stream).
    const run = this.writeQueue.then(async (): Promise<void> => {
      this.assertSocket(tcp);
      await tcp.send({ data: ByteUtils.toArrayBuffer(frame) });
    });
    this.writeQueue = run.catch((error: Error): void => {
      Lg.w(LOG_TAG + ': send write failed: ' + error.message);
    });
    await run;
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

  private newChannelHeader(channelId: number): CdpCommonHeader {
    const header = this.newHeader(CdpMessageType.Session);
    writeU32BE(header.channelId, 4, channelId);
    return header;
  }

  private cloneHeader(header: CdpCommonHeader): CdpCommonHeader {
    const copy = new CdpCommonHeader();
    copy.version = header.version;
    copy.type = header.type;
    copy.flags = header.flags;
    copy.sequenceNumber = header.sequenceNumber;
    copy.requestId = header.requestId.slice();
    copy.fragmentIndex = header.fragmentIndex;
    copy.fragmentCount = header.fragmentCount;
    copy.sessionId = header.sessionId.slice();
    copy.channelId = header.channelId.slice();
    copy.additionalHeaders = header.additionalHeaders.map((additional: CdpAdditionalHeader): CdpAdditionalHeader =>
      new CdpAdditionalHeader(additional.type, additional.value));
    return copy;
  }

  private sessionIdBytes(): Uint8Array {
    const bytes = new Uint8Array(8);
    writeU32BE(bytes, 0, this.remoteSessionHi);
    writeU32BE(bytes, 4, this.localSessionHi);
    return bytes;
  }

  private deliver(msg: CdpClientMsg): void {
    if (this.waiterResolve === undefined) {
      this.queueMessage(msg);
      return;
    }
    if (this.waiterKind === 'connect' && msg.kind === 'connect' && msg.connType === this.waiterChannel) {
      this.resolveWaiter(msg);
      return;
    }
    if (this.waiterKind === 'control' && msg.kind === 'control' && msg.controlType === this.waiterChannel) {
      this.resolveWaiter(msg);
      return;
    }
    if (this.waiterKind === 'session' && msg.kind === 'session' && msg.channelId === this.waiterChannel) {
      this.resolveWaiter(msg);
      return;
    }
    this.queueMessage(msg);
  }

  private queueMessage(msg: CdpClientMsg): void {
    if (this.pendingMessages.length >= 64) { this.failCompletion(new Error('Windows 握手响应队列已满')); return; }
    this.pendingMessages.push(msg);
  }

  private assertSocket(tcp: socket.TCPSocket | undefined): void {
    if (tcp === undefined || this.tcp !== tcp || this.completionError !== undefined) {
      throw new Error('Windows 发送会话已结束');
    }
  }

  private resolveWaiter(msg: CdpClientMsg): void {
    const resolve = this.waiterResolve;
    this.waiterResolve = undefined;
    this.waiterReject = undefined;
    this.waiterKind = undefined;
    this.waiterChannel = undefined;
    if (resolve !== undefined) {
      resolve(msg);
    }
  }

  private awaitMessage(kind: 'connect' | 'control' | 'session', key: number): Promise<CdpClientMsg> {
    if (this.completionError !== undefined) { return Promise.reject(this.completionError); }
    const index = this.pendingMessages.findIndex((msg: CdpClientMsg): boolean => msg.kind === kind &&
      (kind === 'connect' ? msg.connType === key : kind === 'control' ? msg.controlType === key : msg.channelId === key));
    if (index >= 0) { return Promise.resolve(this.pendingMessages.splice(index, 1)[0]); }
    return new Promise<CdpClientMsg>((resolve: (msg: CdpClientMsg) => void, reject: (error: Error) => void): void => {
      this.waiterKind = kind;
      this.waiterChannel = key;
      this.waiterResolve = resolve;
      this.waiterReject = reject;
    });
  }
}

const CdpControlTypeStartChannelResponse = 1;

/** Reject `promise` with `label` if it does not settle within `ms`. */
function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  return new Promise<T>((resolve: (value: T) => void, reject: (reason: Error) => void): void => {
    let settled = false;
    const timer = setTimeout((): void => {
      if (settled) {
        return;
      }
      settled = true;
      reject(new Error(label));
    }, ms);
    promise.then((value: T): void => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      resolve(value);
    }).catch((error: Error): void => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      reject(error);
    });
  });
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

function u64ToBytes(value: number): Uint8Array {
  const bytes = new Uint8Array(8);
  writeU32BE(bytes, 0, Math.floor(value / 0x100000000));
  writeU32BE(bytes, 4, value >>> 0);
  return bytes;
}

async function randomBytes(length: number): Promise<Uint8Array> {
  const random = cryptoFramework.createRandom();
  const blob = await random.generateRandom(length);
  return new Uint8Array(blob.data);
}

/**
 * Microsoft Correlation Vector v1: "<16 base32 chars>.<counter>". Windows' CDPSvc
 * requires a parseable vector on every Session message (drops the message if it
 * cannot be extended). Alphabet excludes I, L, O, U.
 */
function buildCorrelationVector(): Uint8Array {
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  let chars = '';
  for (let i = 0; i < 16; i++) {
    chars += alphabet.charAt(Math.floor(Math.random() * alphabet.length));
  }
  return ByteUtils.encodeText(chars + '.0');
}

function buildHandshakeRequest(operationId: string): CdpValueSet {
  const vs = new CdpValueSet();
  vs.addUInt32('ControlMessage', 6); // HandShakeRequest
  vs.addUInt32('MaxPlatformVersion', 1);
  vs.addUInt32('MinPlatformVersion', 1);
  vs.addGuid('OperationId', operationId);
  return vs;
}

function buildStartTransfer(files: WindowsNearbyOutgoingFile[]): CdpValueSet {
  const vs = new CdpValueSet();
  vs.addUInt32('ControlMessage', 1); // StartTransfer
  vs.addUInt32('DataKind', 2); // File
  let total = 0;
  for (const file of files) {
    total += file.size;
  }
  vs.addUInt64('BytesToSend', total);
  vs.addUInt32('FileCount', files.length);
  const contentIds: number[] = [];
  const sizes: number[] = [];
  const names: string[] = [];
  for (let i = 0; i < files.length; i++) {
    contentIds.push(i);
    sizes.push(files[i].size);
    names.push(files[i].name);
  }
  vs.addUInt32Array('ContentIds', contentIds);
  vs.addUInt64Array('ContentSizes', sizes);
  vs.addStringArray('FileNames', names);
  return vs;
}

async function buildSenderDeviceInfoJson(name: string): Promise<string> {
  let ip = '127.0.0.1';
  try {
    const netHandle = await netConnection.getDefaultNet();
    const props = await netConnection.getConnectionProperties(netHandle);
    for (const link of props.linkAddresses) {
      const addr = link.address.address;
      if (addr.indexOf('.') > 0) {
        ip = addr;
        break;
      }
    }
  } catch (error) {
    Lg.w('羊绒互传 WindowsNearbySender: get local ip failed: ' + JSON.stringify(error));
  }
  // Reference LocalDeviceInfo.ToCdpDeviceInfo: DeviceId and DeduplicationHint are
  // a (double) base64 blob derived from name + platform type. Windows uses them
  // for device identity and a fixed endpoint list for transport upgrade.
  const dedup = ByteUtils.toBase64(ByteUtils.encodeText(name + '|harmonyos|1'));
  const endpoints = '[{"endpointType":1,"host":"' + ip + '","service":"5040"}]';
  const safeName = name.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  return '{"DeduplicationHint":"' + dedup + '","connectionModes":1,"deviceId":"' + dedup +
    '","endpoints":' + endpoints + ',"name":"' + safeName + '","type":8}';
}

/** Minimal alias provider to avoid coupling to SettingsStore. */
class SettingsAliasProvider {
  static readonly instance: SettingsAliasProvider = new SettingsAliasProvider();
  private aliasCache: string = '';

  alias(): string {
    return this.aliasCache.length > 0 ? this.aliasCache : 'CashmereLink';
  }

  setAlias(value: string): void {
    this.aliasCache = value;
  }
}
