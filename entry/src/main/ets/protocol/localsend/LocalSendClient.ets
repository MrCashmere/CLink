import { LogCapture as Lg } from '../../common/LogCapture';
import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ByteUtils } from '../../common/ByteUtils';
import { SecurityUtils } from '../../common/SecurityUtils';
import { SettingsStore } from '../../common/SettingsStore';
import { DeviceIdentity } from '../../common/DeviceIdentity';
import { CertificateStore } from '../../common/CertificateStore';
import { Transports } from '../../common/TlsTransport';
import { LocalSendServer } from './LocalSendServer';
import { DeviceEndpoint, OutgoingFile } from '../../model/TransferModels';

export interface SendHooks {
  onProgress?: (percent: number) => void;
  /** 对端要求 PIN 时调用：返回用户录入的 PIN；返回 null 表示取消。 */
  onPinRequired?: () => Promise<string | null>;
}

interface ParsedResponse {
  readonly status: number;
  readonly body: Uint8Array;
}

interface RequestOptions {
  readonly method: string;
  readonly path: string;
  readonly contentType: string;
  readonly contentLength: number;
  readonly timeoutMs?: number;
  readonly stallMs?: number;
  readonly chunked?: boolean;
  readonly writeBody?: (send: (chunk: Uint8Array) => Promise<void>) => Promise<void>;
}

interface SenderInfoJson {
  alias: string;
  deviceModel: string;
  deviceType: string;
  fingerprint: string;
  port: number;
  protocol: string;
  download: boolean;
  version: string;
  discoverable: boolean;
  announce: boolean;
}

// 对端 /info 响应的局部视图：只需 download 字段判断其是否接收文件。
interface PeerInfoJson {
  download?: boolean;
}

interface FileInfoEntry {
  id: string;
  fileName: string;
  size: number;
  hash?: string;
  sha256?: string;
  fileType: string;
  legacy: boolean;
  preview: string;
}

interface SendBodyJson {
  info: SenderInfoJson;
  files: Record<string, FileInfoEntry>;
}

interface ResponseFileEntry {
  token?: string;
  skipped?: boolean;
}

interface SendResponseJson {
  sessionId?: string;
  token?: string;
  files?: Record<string, ResponseFileEntry | string>;
}

const CRLF_CRLF = new Uint8Array([13, 10, 13, 10]);
const CRLF = new Uint8Array([13, 10]);
const FINAL_CHUNK = ByteUtils.encodeText('0\r\n\r\n');
// 64KB chunks: small enough that a single TLS write burst stays well under the peer's TCP
// receive window (so the peer never falls behind on a big 512KB burst and stalls us via
// backpressure), yet large enough to keep the HTTP chunked framing overhead negligible.
const CHUNK_SIZE = 64 * 1024;
const REQUEST_TIMEOUT_MS = 600000;
const CONTROL_TIMEOUT_MS = 15000;
const SEND_TIMEOUT_MS = 300000;
const UPLOAD_TIMEOUT_MS = 900000;
const INFO_STALL_MS = 6000;
const UPLOAD_STALL_MS = 60000;
const STALL_CHECK_MS = 2000;
const SHA256_MAX_SIZE = 64 * 1024 * 1024;
// v2 is the current/default LocalSend protocol (and what modern peers like 2.2 implement
// for the send flow, e.g. /v2/prepare-upload). v1/legacy are fallbacks: some peers answer
// /v1/info with 200 (compat) but only implement v2 for the actual send, so v2 must be
// tried first — otherwise we pick v1 from the /info probe and then get 404 on the send path.
const API_FAMILIES: string[] = ['/api/localsend/v2', '/api/localsend/v1', '/api'];
const apiPrefixCache: Map<string, string> = new Map();
const IMAGE_EXTENSIONS: string[] = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.svg'];
const VIDEO_EXTENSIONS: string[] = ['.mp4', '.mkv', '.mov', '.avi', '.webm', '.3gp'];
const TEXT_EXTENSIONS: string[] = ['.txt', '.md', '.json', '.csv', '.xml', '.html', '.log'];

export class LocalSendClient {

  private readonly context: common.Context;
  private readonly certs: CertificateStore;
  // 对端 /info 是否宣告可接收文件(download)。LocalSend 对端关闭“接收”时返回
  // download:false。实践发现该字段并不可靠：某些对端(如"善良的葡萄" v2.2)返回
  // download:false 但仍能正常接收(其他 LocalSend 客户端可向其发送成功)。因此这里
  // 只做提示、不 fail-fast，让传输按真实对端响应推进，避免误拦一个能接收的对端。
  private peerCanReceive: boolean = true;

  constructor(context: common.Context) {
    this.context = context;
    this.certs = new CertificateStore(context);
  }

  async send(device: DeviceEndpoint, files: OutgoingFile[], hooks: SendHooks): Promise<void> {
    let totalBytes = 0;
    for (const file of files) {
      totalBytes += file.size;
    }
    Lg.i('LocalSend send: peer=' + device.address + ':' + device.port
      + ' https=' + device.https + ' files=' + files.length + ' totalBytes=' + totalBytes);
    const apiPrefix = await this.probeApiPrefix(device);
    if (!this.peerCanReceive) {
      // 对端宣告 download:false，但它可能仍能接收(该字段在部分对端上不可靠)。只提示，
      // 继续走 prepare-upload → upload 实际流程：若对端真的不接收，会由超时/响应自然暴露。
      Lg.w('LocalSend send: peer /info 返回 download:false，但仍继续尝试发送'
        + '(该字段在部分对端上不可靠)。若对端确不接收会按超时失败。');
    }
    const fileEntries: Record<string, FileInfoEntry> = {};
    const fileIds: Map<string, string> = new Map();
    for (const file of files) {
      const fileId = SecurityUtils.createToken();
      fileIds.set(file.path, fileId);
      const fileHash = await this.fileHash(file);
      const fileEntry: FileInfoEntry = {
        id: fileId,
        fileName: file.name,
        size: file.size,
        fileType: LocalSendClient.toLocalSendFileType(file.name),
        legacy: false,
        preview: ''
      };
      if (fileHash !== '') {
        fileEntry.hash = fileHash;
        fileEntry.sha256 = fileHash;
      }
      fileEntries[fileId] = fileEntry;
    }
    const body: SendBodyJson = {
      info: await this.senderInfo(),
      files: fileEntries
    };
    const sendBody = ByteUtils.encodeText(JSON.stringify(body));
    Lg.i('LocalSend send: requesting peer approval (' + files.length + ' files) via ' + apiPrefix);
    let useLegacySend = false;
    const sendRequestPath = LocalSendClient.route(apiPrefix, '/prepare-upload', '/send-request');
    const requestSend = async (path: string, pin: string): Promise<ParsedResponse> => {
      const pathWithPin = pin.length > 0 ? path + '?pin=' + encodeURIComponent(pin) : path;
      return this.request(device, {
        method: 'POST',
        path: pathWithPin,
        contentType: 'application/json',
        contentLength: sendBody.length,
        timeoutMs: SEND_TIMEOUT_MS,
        writeBody: async (sendChunk: (chunk: Uint8Array) => Promise<void>): Promise<void> => {
          await sendChunk(sendBody);
        }
      });
    };
    // LocalSend 官方 PIN 语义：对端配置 receivePin 时返回 401，需带 ?pin= 重试；连错锁定 429。
    let sendResponse: ParsedResponse = { status: 0, body: new Uint8Array(0) };
    let pin = '';
    let pinAttempts = 0;
    while (true) {
      const targetPath = useLegacySend
        ? apiPrefix + (apiPrefix === '/api/localsend/v1' ? '/send-request' : '/send')
        : sendRequestPath;
      sendResponse = await requestSend(targetPath, pin);
      Lg.i('LocalSend send: ' + targetPath + (pin.length > 0 ? '?pin=***' : '') + ' -> status ' + sendResponse.status);
      if ((sendResponse.status === 404 || sendResponse.status === 405) && !useLegacySend) {
        useLegacySend = true;
        continue;
      }
      if (sendResponse.status === 401) {
        if (pinAttempts >= 3) {
          throw new Error('对端 PIN 无效，请核对后重试');
        }
        const entered = await (hooks.onPinRequired !== undefined ? hooks.onPinRequired() : Promise.resolve(null));
        if (entered === null) {
          throw new Error('已取消：对端要求 PIN');
        }
        const trimmed = entered.trim();
        if (trimmed.length === 0) {
          throw new Error('已取消：对端要求 PIN');
        }
        pin = trimmed;
        pinAttempts += 1;
        continue;
      }
      if (sendResponse.status === 429) {
        throw new Error('对端 PIN 尝试次数过多，请稍后再试');
      }
      break;
    }
    if (sendResponse.status === 403) {
      throw new Error('对端拒绝了本次传输');
    }
    if (sendResponse.status === 409) {
      throw new Error('对端正被另一个传输会话占线（Blocked by another session）。请在对端 LocalSend 上拒绝或关闭挂起的接收请求后重试');
    }
    if (sendResponse.status !== 200) {
      // 不打印响应体：session 响应含对端下发的上传 token，属敏感凭证。
      Lg.w('LocalSend send: approval response status ' + sendResponse.status + ' (body omitted)');
      throw new Error('send request failed: ' + sendResponse.status);
    }
    Lg.i('LocalSend send: session response status ' + sendResponse.status + ' (body omitted)');
    const session = this.parseSession(sendResponse);
    const sessionId = session.sessionId !== undefined ? session.sessionId : '';
    if (sessionId === '') {
      throw new Error('对端未返回会话ID(sessionId)');
    }
    Lg.i('LocalSend send: session established, perFileTokens=' + (session.files !== undefined ? 'yes' : 'no') + ' legacySend=' + useLegacySend);
    let transferred = 0;
    let index = 0;
    for (const file of files) {
      index += 1;
      const fileId = fileIds.get(file.path) ?? '';
      if (this.isSkipped(session, fileId)) {
        Lg.i('LocalSend send: ' + index + '/' + files.length + ' ' + file.name + ' skipped by peer (already exists)');
        transferred += file.size;
        if (hooks.onProgress !== undefined) {
          hooks.onProgress(totalBytes > 0 ? Math.min(transferred / totalBytes * 100, 100) : 100);
        }
        continue;
      }
      const token = this.resolveToken(session, fileId);
      if (token === '') {
        throw new Error('对端未返回 ' + file.name + ' 的有效上传凭证(token)');
      }
      Lg.i('LocalSend send: uploading ' + index + '/' + files.length + ' ' + file.name + ' (' + file.size + ' bytes)');
      const uploaded = await this.uploadFile(apiPrefix, device, sessionId, token, fileId, file, (delta: number): void => {
        transferred += delta;
        if (hooks.onProgress !== undefined) {
          hooks.onProgress(totalBytes > 0 ? Math.min(transferred / totalBytes * 100, 100) : 100);
        }
      });
      if (!uploaded) {
        throw new Error('upload rejected for ' + file.name);
      }
    }
    Lg.i('LocalSend send: completed');
  }

  private async probeApiPrefix(device: DeviceEndpoint): Promise<string> {
    const cacheKey = device.address + ':' + device.port;
    const candidates: string[] = [];
    const cached = apiPrefixCache.get(cacheKey);
    if (cached !== undefined) {
      candidates.push(cached);
    }
    for (const family of API_FAMILIES) {
      if (candidates.indexOf(family) < 0) {
        candidates.push(family);
      }
    }
    for (const family of candidates) {
      const info = await this.request(device, {
        method: 'GET',
        path: family + '/info',
        contentType: 'application/json',
        contentLength: 0,
        timeoutMs: CONTROL_TIMEOUT_MS,
        stallMs: INFO_STALL_MS
      });
      Lg.i('LocalSend send: probe ' + family + '/info -> status ' + info.status);
      if (info.status === 200) {
        apiPrefixCache.set(cacheKey, family);
        const infoText = ByteUtils.decodeText(info.body);
        Lg.i('LocalSend send: peer info body: ' + infoText.substring(0, 256));
        // 对端若宣告 download:false，说明其当前不接收文件；立即标注，send() 据此 fail-fast。
        this.peerCanReceive = LocalSendClient.parsePeerCanReceive(infoText);
        return family;
      }
      if (info.status === 0) {
        if (device.https) {
          // 本端已接 HTTPS 客户端通道：不再引导用户“到对端关闭加密”，如实报告握手/连接失败
          throw new Error('连接对端失败（https）：TLS 握手或连接未完成（timeout）。本端已支持加密发送；请确认对端 LocalSend 正在运行、53317 端口可达，且其对端协议标记与实测一致');
        }
        throw new Error('连接对端失败：对端未响应，请检查对端是否在同一网络以及防火墙设置');
      }
      if (info.status !== 404 && info.status !== 405) {
        throw new Error('peer info failed: ' + info.status);
      }
    }
    throw new Error('对端 LocalSend 未响应任何已知 /info 接口（v1/v2/legacy 均 404）。请确认对端 LocalSend 版本较新且处于运行状态');
  }

  private async fileHash(file: OutgoingFile): Promise<string> {
    if (file.size === 0 || file.size > SHA256_MAX_SIZE) {
      return '';
    }
    try {
      const data = await this.readWholeFile(file.path, file.size);
      return await SecurityUtils.sha256Hex(data);
    } catch (error) {
      Lg.w('hash failed for ' + file.name + ': ' + JSON.stringify(error));
      return '';
    }
  }

  private async senderInfo(): Promise<SenderInfoJson> {
    const alias = SettingsStore.current().alias;
    const certFingerprint = await this.certs.fingerprint();
    return {
      alias: alias,
      deviceModel: 'HarmonyOS NEXT',
      deviceType: 'mobile',
      fingerprint: certFingerprint.length > 0 ? certFingerprint : await DeviceIdentity.load(this.context),
      port: 53317,
      protocol: 'http',
      download: false,
      version: '2.0',
      discoverable: true,
      announce: true
    };
  }

  private parseSession(response: ParsedResponse): SendResponseJson {
    const text = ByteUtils.decodeText(response.body);
    try {
      return JSON.parse(text) as SendResponseJson;
    } catch (error) {
      throw new Error('无法解析对端返回的会话响应: ' + text.substring(0, 128));
    }
  }

  private resolveToken(session: SendResponseJson, fileId: string): string {
    const perFile = session.files;
    if (perFile !== undefined && Object.keys(perFile).indexOf(fileId) >= 0) {
      const entry: ResponseFileEntry | string = perFile[fileId];
      if (typeof entry === 'string') {
        return entry;
      }
      if (entry.token !== undefined && entry.token !== '') {
        return entry.token;
      }
    }
    return session.token !== undefined ? session.token : '';
  }

  private isSkipped(session: SendResponseJson, fileId: string): boolean {
    const perFile = session.files;
    if (perFile !== undefined && Object.keys(perFile).indexOf(fileId) >= 0) {
      const entry: ResponseFileEntry | string = perFile[fileId];
      if (typeof entry === 'string') {
        return entry === '';
      }
      return entry.skipped === true;
    }
    return false;
  }

  private static toLocalSendFileType(name: string): string {
    const lower = name.toLowerCase();
    if (LocalSendClient.endsWithAny(lower, IMAGE_EXTENSIONS)) {
      return 'image';
    }
    if (LocalSendClient.endsWithAny(lower, VIDEO_EXTENSIONS)) {
      return 'video';
    }
    if (lower.endsWith('.pdf')) {
      return 'pdf';
    }
    if (LocalSendClient.endsWithAny(lower, TEXT_EXTENSIONS)) {
      return 'text';
    }
    if (lower.endsWith('.apk')) {
      return 'apk';
    }
    return 'other';
  }

  private static endsWithAny(name: string, extensions: string[]): boolean {
    for (const extension of extensions) {
      if (name.endsWith(extension)) {
        return true;
      }
    }
    return false;
  }

  /**
   * 解析对端 /info 响应中的 download 字段。
   * download 缺失或解析失败时按“可接收”处理(默认 true)，避免误拦正常对端。
   * 仅当对端明确返回 download:false 才判定为不接收。
   */
  private static parsePeerCanReceive(infoText: string): boolean {
    try {
      const parsed = JSON.parse(infoText) as PeerInfoJson;
      return parsed.download !== false;
    } catch (error) {
      return true;
    }
  }

  private async uploadFile(
    apiPrefix: string,
    device: DeviceEndpoint,
    sessionId: string,
    token: string,
    fileId: string,
    file: OutgoingFile,
    onDelta: (delta: number) => void
  ): Promise<boolean> {
    const uploadPath = LocalSendClient.route(apiPrefix, '/upload', '/send');
    const path = uploadPath + '?sessionId=' + encodeURIComponent(sessionId) +
      '&fileId=' + encodeURIComponent(fileId) + '&token=' + encodeURIComponent(token);
    const raw = await this.request(device, {
      method: 'POST',
      path,
      contentType: 'application/octet-stream',
      contentLength: file.size,
      timeoutMs: UPLOAD_TIMEOUT_MS,
      stallMs: UPLOAD_STALL_MS,
      chunked: true,
      writeBody: (sendChunk: (chunk: Uint8Array) => Promise<void>): Promise<void> => this.streamFile(file, sendChunk, onDelta)
    });
    if (raw.status >= 200 && raw.status < 300) {
      return true;
    }
    Lg.w('LocalSend upload raw status ' + raw.status + ' (body omitted)');
    if (raw.status !== 400 && raw.status !== 404 && raw.status !== 405 && raw.status !== 415 && raw.status !== 422) {
      return false;
    }
    const multipart = await this.uploadMultipart(apiPrefix, device, sessionId, token, fileId, file, onDelta);
    if (multipart.status >= 200 && multipart.status < 300) {
      return true;
    }
    Lg.w('LocalSend upload multipart status ' + multipart.status + ' (body omitted)');
    return false;
  }

  private async uploadMultipart(
    apiPrefix: string,
    device: DeviceEndpoint,
    sessionId: string,
    token: string,
    fileId: string,
    file: OutgoingFile,
    onDelta: (delta: number) => void
  ): Promise<ParsedResponse> {
    const boundary = 'cashmere' + token.substring(0, 8);
    const preamble = ByteUtils.encodeText(
      '--' + boundary + '\r\nContent-Disposition: form-data; name="sessionId"\r\n\r\n' + sessionId + '\r\n' +
      '--' + boundary + '\r\nContent-Disposition: form-data; name="fileId"\r\n\r\n' + fileId + '\r\n' +
      '--' + boundary + '\r\nContent-Disposition: form-data; name="token"\r\n\r\n' + token + '\r\n' +
      '--' + boundary + '\r\nContent-Disposition: form-data; name="file"; filename="' + file.name + '"\r\nContent-Type: application/octet-stream\r\n\r\n'
    );
    const epilogue = ByteUtils.encodeText('\r\n--' + boundary + '--\r\n');
    const uploadPath = LocalSendClient.route(apiPrefix, '/upload', '/send');
    const response = await this.request(device, {
      method: 'POST',
      path: uploadPath + '?sessionId=' + encodeURIComponent(sessionId) +
        '&fileId=' + encodeURIComponent(fileId) + '&token=' + encodeURIComponent(token),
      contentType: 'multipart/form-data; boundary=' + boundary,
      contentLength: preamble.length + file.size + epilogue.length,
      timeoutMs: UPLOAD_TIMEOUT_MS,
      stallMs: UPLOAD_STALL_MS,
      writeBody: async (sendChunk: (chunk: Uint8Array) => Promise<void>): Promise<void> => {
        await sendChunk(preamble);
        await this.streamFile(file, sendChunk, onDelta);
        await sendChunk(epilogue);
      }
    });
    return response;
  }

  private static route(apiPrefix: string, v2Path: string, v1Path: string): string {
    return apiPrefix + (apiPrefix === '/api/localsend/v1' ? v1Path : v2Path);
  }

  private async streamFile(
    file: OutgoingFile,
    sendChunk: (chunk: Uint8Array) => Promise<void>,
    onDelta: (delta: number) => void
  ): Promise<void> {
    const handle = fs.openSync(file.path, fs.OpenMode.READ_ONLY);
    try {
      const buffer = new ArrayBuffer(CHUNK_SIZE);
      let remaining = file.size;
      while (remaining > 0) {
        const toRead = Math.min(CHUNK_SIZE, remaining);
        // fs.read's ReadOptions.offset is the FILE start position (filePointer + offset),
        // and the fd's file pointer also advances after each call. Passing a running
        // `offset` here double-counts against the already-advanced pointer, which corrupts
        // or truncates any file larger than one 512KB chunk (e.g. the 1.19MB test file).
        // Omit `offset` so each call continues sequentially from the advancing file pointer.
        const readCount = await fs.read(handle.fd, buffer, { length: toRead });
        if (readCount <= 0) {
          break;
        }
        await sendChunk(new Uint8Array(buffer.slice(0, readCount)));
        remaining -= readCount;
        onDelta(readCount);
      }
    } finally {
      fs.closeSync(handle);
    }
  }

  private async readWholeFile(path: string, size: number): Promise<Uint8Array> {
    const handle = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const buffer = new ArrayBuffer(size);
      await fs.read(handle.fd, buffer);
      return new Uint8Array(buffer);
    } finally {
      fs.closeSync(handle);
    }
  }

  private async request(device: DeviceEndpoint, options: RequestOptions): Promise<ParsedResponse> {
    // 客户端按对端 protocol 标记走 TLS（自签证书，跳过远端校验）；对端未启用加密时走明文。
    // LocalSend 采用双向 TLS：本端也要向对端出示自己的自签证书（否则对端回 certificate_required）。
    let certPem = '';
    let keyPem = '';
    if (device.https) {
      try {
        const material = await this.certs.ensure();
        if (material !== undefined) {
          certPem = await fs.readText(material.certPath);
          keyPem = await fs.readText(material.keyPath);
        }
      } catch (error) {
        Lg.w('羊绒互传 TLS: load client cert failed: ' + JSON.stringify(error));
      }
    }
    const transport = await Transports.open(device.address, device.port, device.https, certPem, keyPem);
    try {
      const timeoutMs = options.timeoutMs !== undefined ? options.timeoutMs : REQUEST_TIMEOUT_MS;
      const framing = options.chunked === true
        ? 'Transfer-Encoding: chunked\r\n'
        : 'Content-Length: ' + options.contentLength + '\r\n';
      const head = options.method + ' ' + options.path + ' HTTP/1.1\r\n' +
        'Host: ' + device.address + ':' + device.port + '\r\n' +
        'Content-Type: ' + options.contentType + '\r\n' +
        framing +
        'Connection: close\r\n\r\n';
      let buffer = new Uint8Array(0);
      let settled = false;
      let bodySent = options.writeBody === undefined;
      let lastDataAt = Date.now();
      let resolver: ((response: ParsedResponse) => void) | undefined = undefined;
      let timer = -1;
      let stallTimer = -1;
      const settle = (response: ParsedResponse): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timer !== -1) {
          clearTimeout(timer);
        }
        if (stallTimer !== -1) {
          clearInterval(stallTimer);
        }
        if (resolver !== undefined) {
          resolver(response);
        }
      };
      timer = setTimeout((): void => {
        Lg.w('LocalSend request timeout: ' + options.method + ' ' + options.path + ' after ' + timeoutMs + ' ms');
        settle({ status: 0, body: new Uint8Array(0) });
      }, timeoutMs);
      stallTimer = setInterval((): void => {
        if (!settled && bodySent && options.stallMs !== undefined && Date.now() - lastDataAt > options.stallMs) {
          Lg.w('LocalSend request stalled: ' + options.method + ' ' + options.path + ' (peer sent no complete HTTP response)');
          settle({ status: 0, body: new Uint8Array(0) });
        }
      }, STALL_CHECK_MS);
      const completion = new Promise<ParsedResponse>((resolve: (response: ParsedResponse) => void): void => {
        resolver = resolve;
      });
      transport.onData((chunk: Uint8Array): void => {
        if (settled) {
          return;
        }
        lastDataAt = Date.now();
        buffer = ByteUtils.concat([buffer, chunk]);
        const headerEnd = ByteUtils.indexOf(buffer, CRLF_CRLF, 0);
        if (headerEnd < 0) {
          return;
        }
        const headText = ByteUtils.decodeText(buffer.slice(0, headerEnd));
        const contentLength = LocalSendClient.readContentLength(headText);
        const bodyStart = headerEnd + 4;
        if (buffer.length >= bodyStart + contentLength) {
          settle({
            status: LocalSendClient.readStatus(headText),
            body: buffer.slice(bodyStart, bodyStart + contentLength)
          });
        }
      });
      await transport.send(ByteUtils.encodeText(head));
      if (options.writeBody !== undefined) {
        try {
          if (options.chunked === true) {
            const sendFrame = async (chunk: Uint8Array): Promise<void> => {
              if (chunk.length === 0) {
                return;
              }
              await transport.send(ByteUtils.encodeText(chunk.length.toString(16)));
              await transport.send(CRLF);
              await transport.send(chunk);
              await transport.send(CRLF);
            };
            await options.writeBody(sendFrame);
            await transport.send(FINAL_CHUNK);
          } else {
            await options.writeBody((chunk: Uint8Array): Promise<void> => transport.send(chunk));
          }
          bodySent = true;
          lastDataAt = Date.now();
        } catch (error) {
          if (!settled) {
            throw error as Error;
          }
          Lg.w('LocalSend upload: peer responded before body finished (' + options.method + ' ' + options.path + ')');
        }
      }
      return await completion;
    } finally {
      await transport.close();
    }
  }

  private static readStatus(headText: string): number {
    const firstLine = headText.split('\r\n')[0] ?? '';
    const parts = firstLine.split(' ');
    const value = parseInt(parts[1] ?? '0', 10);
    return Number.isNaN(value) ? 0 : value;
  }

  private static readContentLength(headText: string): number {
    const lines = headText.split('\r\n');
    for (const line of lines) {
      if (line.toLowerCase().startsWith('content-length:')) {
        const value = parseInt(line.substring(15).trim(), 10);
        return Number.isNaN(value) ? 0 : value;
      }
    }
    return 0;
  }

  static errorCode(error: BusinessError): string {
    if (error.code !== undefined && error.code !== null) {
      return String(error.code);
    }
    const text = JSON.stringify(error);
    const match = /"code"\s*:\s*(\d+)/.exec(text);
    return match !== null ? match[1] : 'unknown';
  }

}
