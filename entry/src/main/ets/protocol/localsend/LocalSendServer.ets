import { LogCapture as Lg } from '../../common/LogCapture';
import { socket } from '@kit.NetworkKit';
import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { picker, fileUri } from '@kit.CoreFileKit';
import { ByteUtils } from '../../common/ByteUtils';
import { SecurityUtils } from '../../common/SecurityUtils';
import { SettingsStore } from '../../common/SettingsStore';
import { DeviceIdentity } from '../../common/DeviceIdentity';
import { CertificateStore } from '../../common/CertificateStore';
import { IncomingFile, SessionFileMeta, WebShareInfo } from '../../model/TransferModels';
import tlsNative from 'libtls_transport.so';

export interface IncomingSessionRequest {
  readonly sessionId: string;
  readonly peerName: string;
  readonly files: SessionFileMeta[];
  readonly pin: string;
}

export interface LocalSendIncomingHandler {
  onSessionRequested(request: IncomingSessionRequest): Promise<boolean>;
  onSessionResolved(sessionId: string, accepted: boolean): void;
  onFileReceived(sessionId: string, file: IncomingFile): void;
  onProgress(sessionId: string, progress: number): void;
}

interface OpenStreamResult {
  file: fs.File;
  path: string;
}

interface StreamState {
  file: fs.File;
  path: string;
  sessionId: string;
  name: string;
  lastPct: number;
  pos: number;
  total: number;
  received: number;
  chunkSize: number;
  waitingLine: boolean;
  mpDelim?: Uint8Array;
  mpPhase: number;
}

interface SessionState {
  readonly token: string;
  readonly pin: string;
  readonly files: Map<string, SessionFileMeta>;
  receivedBytes: number;
  completed: number;
  totalBytes: number;
  activeStreams: number;
  expiresAt: number;
}

/** 本机向网页端（局域网网页传输）共享的文件元信息与有效期。 */
interface ShareState {
  readonly id: string;
  readonly path: string;
  readonly name: string;
  readonly size: number;
  readonly addedAt: number;
  expiresAt: number;
}

interface ServerConnection {
  sendBytes(data: Uint8Array): Promise<void>;
  onData(listener: (chunk: Uint8Array) => void): void;
  onClose(listener: () => void): void;
  peerAddress(): Promise<string>;
  close(): void;
}

class TcpServerConnection implements ServerConnection {

  private readonly conn: socket.TCPSocketConnection;

  constructor(conn: socket.TCPSocketConnection) {
    this.conn = conn;
  }

  sendBytes(data: Uint8Array): Promise<void> {
    return this.conn.send({ data: ByteUtils.toArrayBuffer(data) });
  }

  onData(listener: (chunk: Uint8Array) => void): void {
    this.conn.on('message', (info: socket.SocketMessageInfo): void => {
      listener(new Uint8Array(info.message));
    });
  }

  onClose(listener: () => void): void {
    this.conn.on('close', (): void => {
      listener();
    });
  }

  async peerAddress(): Promise<string> {
    try {
      const info = await this.conn.getRemoteAddress();
      return info.address;
    } catch (error) {
      Lg.w('羊绒互传 LocalSend peerAddress failed: ' + JSON.stringify(error));
      return '';
    }
  }

  close(): void {
    this.conn.close().catch((): void => undefined);
  }
}

/** Native mbedTLS server connection (receive HTTPS). The native module accepts the
 *  socket (POSIX) and runs the TLS handshake on a worker thread; data/close arrive via
 *  the threadsafe callback. The fd is owned exclusively by native, so there is no
 *  @ohos.net.socket event loop competing with mbedTLS. */
class TlsServerConnection implements ServerConnection {

  private handle: number = 0;
  private dataListener?: (chunk: Uint8Array) => void;
  private closeListener?: () => void;
  private closed: boolean = false;
  private readonly pending: Uint8Array[] = [];
  private peerAddressValue: string = '';

  constructor(fd: number, certPem: string, keyPem: string, peerIp: string) {
    this.peerAddressValue = peerIp;
    Lg.i('羊绒互传 TLS: TlsServerConnection.accept -> fd=' + fd + ' peerIp=' + peerIp);
    // Native accept() returns immediately; TLS handshake runs on the native worker thread.
    const rawHandle = tlsNative.accept(fd, { certPem: certPem, keyPem: keyPem },
      (chunk: ArrayBuffer | null, err: string | null): void => this.routeNativeEvent(chunk, err)) as number | null | undefined;
    Lg.i('羊绒互传 TLS: native accept handle=' + rawHandle);
    if (rawHandle !== undefined && rawHandle !== null && rawHandle > 0) {
      this.handle = rawHandle;
    } else {
      this.closed = true;
    }
  }

  private routeNativeEvent(chunk: ArrayBuffer | null, err: string | null): void {
    if (err !== null && err !== undefined) {
      Lg.i('羊绒互传 TLS: native server closed error=' + err);
      this.closed = true;
      if (this.closeListener !== undefined) {
        this.closeListener();
      }
      return;
    }
    if (chunk === null) {
      Lg.i('羊绒互传 TLS: native server closed (no more data)');
      this.closed = true;
      if (this.closeListener !== undefined) {
        this.closeListener();
      }
      return;
    }
    if (chunk.byteLength === 0) {
      return;
    }
    Lg.i('羊绒互传 TLS: native server data len=' + chunk.byteLength);
    const data = new Uint8Array(chunk);
    if (this.dataListener !== undefined) {
      this.dataListener(data);
    } else {
      this.pending.push(data);
    }
  }

  sendBytes(data: Uint8Array): Promise<void> {
    // Allow writing even when this.closed is set: the server sends the final `200 OK`
    // response and then closes; if a prior "closed" flag was set (e.g. we raced a close),
    // refusing here would drop the success response and make the sender retry. Only a
    // torn-down handle (==0) is a hard failure.
    if (this.handle <= 0) {
      return Promise.reject(new Error('TLS connection closed'));
    }
    const written = tlsNative.send(this.handle, ByteUtils.toArrayBuffer(data)) as number;
    if (written < 0) {
      return Promise.reject(new Error('TLS send failed'));
    }
    return Promise.resolve();
  }

  onData(listener: (chunk: Uint8Array) => void): void {
    this.dataListener = listener;
    while (this.pending.length > 0) {
      const buffered = this.pending.shift();
      if (buffered !== undefined) {
        listener(buffered);
      }
    }
  }

  onClose(listener: () => void): void {
    this.closeListener = listener;
  }

  async peerAddress(): Promise<string> {
    return this.peerAddressValue;
  }

  close(): void {
    this.closed = true;
    if (this.handle > 0) {
      tlsNative.close(this.handle);
      this.handle = 0;
    }
  }
}

interface ParsedRequest {
  readonly method: string;
  readonly path: string;
  readonly query: Map<string, string>;
  readonly headers: Map<string, string>;
  readonly body: Uint8Array;
}

interface MultipartField {
  readonly name: string;
  readonly fileName: string;
  readonly data: Uint8Array;
}

interface FileInfoJson {
  fileName: string;
  size: number;
  sha256?: string;
  fileType?: string;
}

interface SendRequestJson {
  info?: SendRequestInfoJson;
  files: Record<string, FileInfoJson>;
  text?: string;
}

interface SendRequestInfoJson {
  alias?: string;
  deviceModel?: string;
  deviceType?: string;
}

interface MpScan {
  sessionId: string;
  fileId: string;
  token: string;
}

interface MpPartResult {
  readonly kind: 'need-more' | 'broken' | 'empty' | 'file';
  readonly sessionId: string;
  readonly fileId: string;
  readonly token: string;
  readonly fileName: string;
  readonly fileDataStart: number;
  readonly scanPos: number;
}


const PORT = 53317;
/** 网页端「局域网网页传输」专用端口：始终用明文 HTTP，避免 HTTPS 自签证书在浏览器上的拦截。 */
const WEB_PORT = 53318;
const CRLF_CRLF = new Uint8Array([13, 10, 13, 10]);
const CRLF = new Uint8Array([13, 10]);
const MAX_HEAD_BYTES = 64 * 1024;
const MAX_BODY_BYTES = 2 * 1024 * 1024 * 1024;
const MAX_CONTROL_BODY_BYTES = 16 * 1024 * 1024;
const MAX_SNIFF_WAIT_BYTES = 1024 * 1024;
const MAX_OVERREAD_BYTES = 16 * 1024 * 1024;
const MAX_MP_SCAN_BYTES = 1024 * 1024;
const MAX_MP_HEADER_BYTES = 64 * 1024;
const IDLE_SETTLE_MS = 60000;
const DONE_SETTLE_MS = 3000;
const SESSION_TTL_MS = 30 * 60 * 1000;
const SESSION_SWEEP_MS = 60 * 1000;
const MAX_SESSIONS = 16;
const SHARE_TTL_MS = 30 * 60 * 1000;

export class LocalSendServer {
  private static downloadDirUri: string = '';
  static lastHttpsActive: boolean = false;
  static actualPort: number = PORT;
  static actualWebPort: number = WEB_PORT;
  private tcpServer?: socket.TCPSocketServer;
  private webTcpServer?: socket.TCPSocketServer;
  private listenHandle: number = 0;
  private readonly sessions: Map<string, SessionState> = new Map();
  private readonly pinAttempts: Map<string, number> = new Map();
  private readonly shares: Map<string, ShareState> = new Map();
  private handler?: LocalSendIncomingHandler;
  private started = false;
  private httpsActiveValue = false;
  private sweepTimer: number = -1;
  /** 缓存浏览器「局域网网页传输」HTML 页面，避免每次请求都读一次 rawfile。 */
  private webHtmlCache: string = '';

  private readonly certs: CertificateStore;
  private readonly context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
    this.certs = new CertificateStore(context);
  }

  get httpsActive(): boolean {
    return this.httpsActiveValue;
  }

  setHandler(handler: LocalSendIncomingHandler): void {
    this.handler = handler;
  }

  /** 注册一个本机文件供网页端（局域网网页传输）下载，返回共享 id（空串表示失败）。 */
  addShare(path: string, name: string, size: number): string {
    const id = SecurityUtils.createToken();
    this.shares.set(id, {
      id: id,
      path: path,
      name: name,
      size: size,
      addedAt: Date.now(),
      expiresAt: Date.now() + SHARE_TTL_MS
    });
    this.pruneExpiredShares();
    Lg.i('羊绒互传 web share added: ' + id + ' name=' + name + ' size=' + size);
    return id;
  }

  removeShare(id: string): boolean {
    const removed = this.shares.delete(id);
    if (removed) {
      Lg.i('羊绒互传 web share removed: ' + id);
    }
    return removed;
  }

  /** 当前可下载的共享文件列表（已剔除过期项）。 */
  listShares(): WebShareInfo[] {
    this.pruneExpiredShares();
    const out: WebShareInfo[] = [];
    this.shares.forEach((s: ShareState): void => {
      out.push({ id: s.id, name: s.name, size: s.size });
    });
    return out;
  }

  private pruneExpiredShares(): void {
    const now = Date.now();
    this.shares.forEach((s: ShareState, id: string): void => {
      if (s.expiresAt <= now) {
        this.shares.delete(id);
      }
    });
  }

  async start(): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    try {
      LocalSendServer.actualPort = PORT;
      // 若开启加密，优先提供原生 mbedTLS HTTPS（避免 @ohos.net.socket TLSSocket 的 memcpy_s bug）。
      if ((SettingsStore.current().encryptionEnabled ?? true) && await this.tryStartTls()) {
        Lg.i(`羊绒互传 LocalSend server listening on ${PORT} (https)`);
      } else {
        await this.startPlain();
        Lg.i(`羊绒互传 LocalSend server listening on ${PORT} (http)`);
      }
      // 网页端「局域网网页传输」始终以明文 HTTP 单独提供（即使主端口走 HTTPS），
      // 让对端浏览器无需处理自签证书。失败不阻塞主服务。
      try {
        await this.startWebListener();
      } catch (error) {
        Lg.w('羊绒互传 LocalSend web listener start failed: ' + JSON.stringify(error));
      }
      this.startSweep();
    } catch (error) {
      this.started = false;
      this.httpsActiveValue = false;
      LocalSendServer.lastHttpsActive = false;
      LocalSendServer.actualPort = PORT;
      Lg.e(`羊绒互传 LocalSend server start failed: ${JSON.stringify(error)}`);
    }
  }

  /** 原生 mbedTLS 服务端：socket 由 native 用 POSIX listen/accept 创建(可用)，每连接把 fd 交给
   *  native 做 TLS 握手。native 独占 fd，避免 @ohos.net.socket 事件循环与 mbedTLS 争抢。失败返回 false 走明文。 */
  private async tryStartTls(): Promise<boolean> {
    try {
      const material = await this.certs.ensure();
      if (material === undefined) {
        return false;
      }
      const certPem = await fs.readText(material.certPath);
      const keyPem = await fs.readText(material.keyPath);
      const listenHandle = tlsNative.listen(PORT, { certPem: certPem, keyPem: keyPem },
        (fd: number, peerIp: string): void => {
          this.handleConnection(new TlsServerConnection(fd, certPem, keyPem, peerIp));
        }) as number | null | undefined;
      if (listenHandle === undefined || listenHandle === null || listenHandle <= 0) {
        Lg.w('羊绒互传 LocalSend TLS listen failed');
        return false;
      }
      this.listenHandle = listenHandle;
      this.httpsActiveValue = true;
      LocalSendServer.lastHttpsActive = true;
      return true;
    } catch (error) {
      Lg.w('羊绒互传 LocalSend TLS start failed, falling back to http: ' + JSON.stringify(error));
      this.httpsActiveValue = false;
      LocalSendServer.lastHttpsActive = false;
      return false;
    }
  }

  stop(): void {
    if (!this.started) {
      return;
    }
    this.started = false;
    this.httpsActiveValue = false;
    LocalSendServer.lastHttpsActive = false;
    LocalSendServer.actualPort = PORT;
    this.stopSweep();
    if (this.listenHandle > 0) {
      tlsNative.stopListen(this.listenHandle);
      this.listenHandle = 0;
    }
    if (this.tcpServer !== undefined) {
      this.tcpServer.off('connect');
      this.tcpServer.close().catch(() => undefined);
      this.tcpServer = undefined;
    }
    if (this.webTcpServer !== undefined) {
      this.webTcpServer.off('connect');
      this.webTcpServer.close().catch(() => undefined);
      this.webTcpServer = undefined;
    }
    if (this.sessions.size > 0) {
      Lg.w('羊绒互传 LocalSend stopping with ' + this.sessions.size + ' sessions in flight');
      this.sessions.clear();
    }
    this.shares.clear();
  }

  private async startPlain(): Promise<void> {
    const server = socket.constructTCPSocketServerInstance();
    server.on('connect', (conn: socket.TCPSocketConnection): void => {
      this.handleConnection(new TcpServerConnection(conn));
    });
    await server.listen({ address: '0.0.0.0', family: 1, port: PORT });
    this.tcpServer = server;
  }

  /** 网页端「局域网网页传输」：在独立端口用明文 HTTP 监听，同一套会话/落盘管线复用，
   *  但浏览器始终通过 http:// 访问，不涉及自签证书。 */
  private async startWebListener(): Promise<void> {
    const server = socket.constructTCPSocketServerInstance();
    server.on('connect', (conn: socket.TCPSocketConnection): void => {
      this.handleConnection(new TcpServerConnection(conn));
    });
    await server.listen({ address: '0.0.0.0', family: 1, port: WEB_PORT });
    this.webTcpServer = server;
    Lg.i(`羊绒互传 LocalSend web page listening on ${WEB_PORT} (http)`);
  }

  private startSweep(): void {
    this.stopSweep();
    this.sweepTimer = setInterval((): void => {
      this.sweepExpiredSessions();
    }, SESSION_SWEEP_MS);
  }

  private stopSweep(): void {
    if (this.sweepTimer !== -1) {
      clearInterval(this.sweepTimer);
      this.sweepTimer = -1;
    }
  }

  private sweepExpiredSessions(): void {
    const now = Date.now();
    this.sessions.forEach((session: SessionState, id: string): void => {
      if (session.expiresAt <= now) {
        Lg.w('羊绒互传 LocalSend session expired: ' + id + ' (ttl=' + SESSION_TTL_MS + 'ms) removed');
        this.sessions.delete(id);
      }
    });
    this.pruneExpiredShares();
  }

  private touchSession(id: string): void {
    const session = this.sessions.get(id);
    if (session !== undefined) {
      session.expiresAt = Date.now() + SESSION_TTL_MS;
    }
  }

  private handleConnection(conn: ServerConnection): void {
    let buffer = new Uint8Array(0);
    let handled = false;
    let headParsed = false;
    let mode: 'fixed' | 'chunked' | 'sniff' | 'raw' | 'mp' = 'fixed';
    let transferEncoding = '';
    let claimsChunked = false;
    let contentLength = 0;
    let bodyStart = 0;
    let headText = '';
    let headQuery = new Map<string, string>();
    let stream: StreamState | undefined = undefined;
    let idleTimer = -1;
    let doneTimer = -1;
    let mpDelimBytes: Uint8Array = new Uint8Array(0);
    let mpScanPos = 0;
    let sniffCompacted = false;
    const mpFields: MpScan = { sessionId: '', fileId: '', token: '' };
    const clearTimers = (): void => {
      if (idleTimer >= 0) {
        clearTimeout(idleTimer);
        idleTimer = -1;
      }
      if (doneTimer >= 0) {
        clearTimeout(doneTimer);
        doneTimer = -1;
      }
    };
    const settle = (respond: boolean, status: number, body: string): void => {
      if (stream === undefined || handled) {
        return;
      }
      handled = true;
      clearTimers();
      const session = this.sessions.get(stream.sessionId);
      let incomplete = false;
      if (session !== undefined) {
        try {
          // 只记录长度，不打印文件内容（避免泄露接收到的文件字节）。
          Lg.i('LocalSend file check: declared=' + stream.total + ' wrote=' + stream.received);
        } catch (readError) {
          Lg.w('LocalSend file check failed: ' + JSON.stringify(readError));
        }
        if (stream.total > 0 && stream.received > stream.total) {
          try {
            fs.truncateSync(stream.file.fd, stream.total);
            stream.received = stream.total;
            Lg.w('LocalSend upload truncated to declared size: ' + stream.total + ' (raw excess removed)');
          } catch (truncError) {
            Lg.w('LocalSend upload truncate failed: ' + JSON.stringify(truncError));
          }
        }
        const expected = stream.total > 0 ? stream.total : (contentLength > 0 ? contentLength : stream.received);
        incomplete = stream.received < expected;
        if (incomplete) {
          if (stream.received === 0) {
            Lg.w('羊绒互传 LocalSend upload incomplete: 0 bytes received (abandoned), removing ' + stream.path);
            try {
              fs.unlinkSync(stream.path);
            } catch (unlinkError) {
              Lg.w('羊绒互传 LocalSend upload cleanup failed: ' + JSON.stringify(unlinkError));
            }
          } else {
            Lg.w('羊绒互传 LocalSend upload incomplete: ' + stream.received + '/' + expected + ' bytes -> ' + stream.path + ' (partial file kept)');
          }
        } else {
          Lg.i('羊绒互传 LocalSend upload streamed complete: ' + stream.sessionId + ' ' + stream.received + ' bytes -> ' + stream.path);
        }
        session.activeStreams -= 1;
        session.completed += 1;
        if (session.activeStreams <= 0 && session.completed >= session.files.size) {
          this.sessions.delete(stream.sessionId);
        }
      }
      this.closeStream(stream);
      if (respond) {
        conn.sendBytes(LocalSendServer.encodeResponse(status, body)).then(() => {
          conn.close();
        }).catch(() => {
          conn.close();
        });
      } else {
        conn.close();
      }
      if (session !== undefined) {
        if (incomplete && stream.received === 0) {
          if (this.handler !== undefined) {
            // 空残缺已删除，仅用 onProgress(100) 收尾任务，不报文件
            this.handler.onProgress(stream.sessionId, 100);
          }
        } else if (incomplete) {
          if (this.handler !== undefined) {
            this.handler.onFileReceived(stream.sessionId, { name: stream.name, size: stream.received, savedPath: stream.path });
            this.handler.onProgress(stream.sessionId, 100);
          }
        } else {
          void this.reportReceived(stream, session, session.files.size === 1);
        }
      }
    };
    const armIdle = (): void => {
      if (handled) {
        return;
      }
      if (idleTimer >= 0) {
        clearTimeout(idleTimer);
      }
      idleTimer = setTimeout((): void => {
        idleTimer = -1;
        if (!handled && stream !== undefined) {
          Lg.w('羊绒互传 LocalSend upload idle, settling partial stream');
          settle(false, 0, '');
        }
      }, IDLE_SETTLE_MS);
    };
    const armDone = (): void => {
      if (handled) {
        return;
      }
      if (doneTimer >= 0) {
        clearTimeout(doneTimer);
      }
      if (idleTimer >= 0) {
        clearTimeout(idleTimer);
        idleTimer = -1;
      }
      doneTimer = setTimeout((): void => {
        doneTimer = -1;
        if (!handled && stream !== undefined) {
          Lg.i('LocalSend raw: declared size reached and idle, finalizing');
          settle(true, 200, '{"status":"ok"}');
        }
      }, DONE_SETTLE_MS);
    };
    const respondAndClose = (status: number, body: string): void => {
      handled = true;
      clearTimers();
      conn.sendBytes(LocalSendServer.encodeResponse(status, body)).then(() => {
        conn.close();
      }).catch(() => {
        conn.close();
      });
    };
    conn.onData((chunk: Uint8Array) => {
      if (handled) {
        return;
      }
      if (!headParsed) {
        buffer = ByteUtils.concat([buffer, chunk]);
        const headerEnd = ByteUtils.indexOf(buffer, CRLF_CRLF, 0);
        if (headerEnd < 0) {
          if (buffer.length > MAX_HEAD_BYTES) {
            respondAndClose(431, '{"status":"head-too-large"}');
          }
          return;
        }
        headText = ByteUtils.decodeText(buffer.slice(0, headerEnd));
        bodyStart = headerEnd + 4;
        contentLength = LocalSendServer.readContentLength(headText);
        const head = LocalSendServer.parseRequest(headText, new Uint8Array(0));
        transferEncoding = (head.headers.get('transfer-encoding') ?? '').toLowerCase();
        claimsChunked = transferEncoding.indexOf('chunked') >= 0;
        const contentType = (head.headers.get('content-type') ?? '').toLowerCase();
        headQuery = head.query;
        const expectContinue = (head.headers.get('expect') ?? '').toLowerCase() === '100-continue';
        Lg.i('LocalSend http head: ' + head.method + ' ' + head.path + ' cl=' + contentLength + ' te=' + (transferEncoding.length > 0 ? transferEncoding : '-') + ' ct=' + (contentType.length > 0 ? contentType : '-'));
        if (expectContinue) {
          conn.sendBytes(LocalSendServer.encodeContinue()).catch((): void => undefined);
        }
        if (claimsChunked) {
          if (!LocalSendServer.isUploadPath(head.path)) {
            Lg.w('LocalSend chunked body on non-upload path rejected: ' + head.path);
            respondAndClose(415, '{"status":"unsupported-media-type"}');
            return;
          }
          mode = 'sniff';
        } else if (LocalSendServer.isUploadPath(head.path)) {
          if (head.method !== 'POST') {
            Lg.w('LocalSend upload rejected: method ' + head.method + ' not allowed');
            respondAndClose(405, '{"status":"method-not-allowed"}');
            return;
          }
          if (contentType.indexOf('multipart/form-data') >= 0) {
            const boundaryText = LocalSendServer.readBoundary(contentType);
            if (boundaryText.length === 0) {
              Lg.w('LocalSend multipart upload missing boundary, rejected');
              respondAndClose(400, '{"status":"bad-request"}');
              return;
            }
            mpDelimBytes = ByteUtils.encodeText('--' + boundaryText);
            mode = 'mp';
          } else {
            if (contentLength > MAX_BODY_BYTES) {
              respondAndClose(413, '{"status":"payload-too-large"}');
              return;
            }
            mode = 'raw';
            const opened = this.tryOpenUploadStream(head.query.get('sessionId') ?? '', head.query.get('fileId') ?? '', head.query.get('token') ?? '');
            if (opened === 'unauthorized') {
              Lg.w('LocalSend upload 401: session missing or token mismatch id=' + (head.query.get('sessionId') ?? ''));
              respondAndClose(401, '{"status":"unauthorized"}');
              return;
            }
            if (opened === 'error') {
              respondAndClose(500, '{"status":"error"}');
              return;
            }
            stream = opened;
            Lg.i('LocalSend raw (content-length) upload started: ' + stream.sessionId + ' ' + stream.name + ' -> ' + stream.path + ' cl=' + contentLength);
            const residual = buffer.length > bodyStart ? buffer.slice(bodyStart) : new Uint8Array(0);
            if (residual.length > 0) {
              const session = this.sessions.get(stream.sessionId);
              if (session !== undefined) {
                this.writeRawData(session, stream, residual);
              }
            }
            headParsed = true;
            if (contentLength > 0 && stream.received >= contentLength) {
              settle(true, 200, '{"status":"ok"}');
              return;
            }
            if (contentLength === 0 && stream.received >= stream.total) {
              settle(true, 200, '{"status":"ok"}');
              return;
            }
            armIdle();
            return;
          }
        } else if (contentLength > MAX_CONTROL_BODY_BYTES) {
          respondAndClose(413, '{"status":"payload-too-large"}');
          return;
        }
        headParsed = true;
      } else if (mode === 'sniff' || mode === 'chunked' || mode === 'fixed' || mode === 'mp') {
        buffer = ByteUtils.concat([buffer, chunk]);
      }
      if (mode === 'raw') {
        if (stream === undefined) {
          respondAndClose(500, '{"status":"error"}');
          return;
        }
        const session = this.sessions.get(stream.sessionId);
        if (session === undefined) {
          settle(false, 0, '');
          return;
        }
        this.touchSession(stream.sessionId);
        this.writeRawData(session, stream, chunk);
        if (contentLength > 0 && stream.received >= contentLength) {
          settle(true, 200, '{"status":"ok"}');
          return;
        }
        if (stream.total > 0 && stream.received >= stream.total) {
          armDone();
          return;
        }
        armIdle();
        return;
      }
      if (mode === 'sniff') {
        if (buffer.length <= bodyStart) {
          return;
        }
        // 首行(CRLF)未完整前不能判定 chunked/raw：本端客户端会把长度行/CRLF/数据分多次 send，
        // 首包可能只含长度行；此时按 raw 会把帧字节混入文件。先等首行到齐，超上限才按 raw 兜底。
        const firstLineEnd = ByteUtils.indexOf(buffer, CRLF, bodyStart);
        let chunkFramed = false;
        if (firstLineEnd < 0) {
          if (buffer.length - bodyStart <= MAX_SNIFF_WAIT_BYTES) {
            return;
          }
          Lg.w('LocalSend sniff: no complete first line within ' + MAX_SNIFF_WAIT_BYTES + ' bytes, treat as raw');
        } else {
          chunkFramed = LocalSendServer.sniffChunkFraming(buffer, bodyStart);
        }
        const sessionId = headQuery.get('sessionId') ?? '';
        const fileId = headQuery.get('fileId') ?? '';
        const token = headQuery.get('token') ?? '';
        const opened = this.tryOpenUploadStream(sessionId, fileId, token);
        if (opened === 'unauthorized') {
          Lg.w('LocalSend upload 401: session missing or token mismatch id=' + sessionId);
          respondAndClose(401, '{"status":"unauthorized"}');
          return;
        }
        if (opened === 'error') {
          respondAndClose(500, '{"status":"error"}');
          return;
        }
        stream = opened;
        stream.pos = bodyStart;
        const session = this.sessions.get(stream.sessionId);
        const firstBody = buffer.slice(bodyStart, Math.min(bodyStart + 32, buffer.length));
        Lg.i('LocalSend body first bytes length=' + firstBody.length + ' (sniff=' + chunkFramed + ')');
        if (chunkFramed) {
          mode = 'chunked';
          Lg.i('LocalSend chunked upload started: ' + stream.sessionId + ' ' + stream.name + ' -> ' + stream.path);
        } else {
          mode = 'raw';
          Lg.w('LocalSend raw upload detected (te=' + transferEncoding + ' cl=' + contentLength + '): ' + stream.sessionId + ' ' + stream.name + ' -> ' + stream.path);
          if (session !== undefined) {
            this.writeRawData(session, stream, buffer.slice(bodyStart));
          }
          if (contentLength > 0 && stream.received >= contentLength) {
            settle(true, 200, '{"status":"ok"}');
          } else if (stream.total > 0 && stream.received >= stream.total) {
            armDone();
          } else {
            armIdle();
          }
          return;
        }
      }
      if (mode === 'chunked') {
        if (stream === undefined) {
          respondAndClose(500, '{"status":"error"}');
          return;
        }
        const session = this.sessions.get(stream.sessionId);
        if (session === undefined) {
          this.releaseStream(stream);
          respondAndClose(401, '{"status":"unauthorized"}');
          return;
        }
        this.touchSession(stream.sessionId);
        const parsed = this.consumeChunked(buffer, stream);
        if (parsed === -1) {
          Lg.w('LocalSend raw fallback: switching from chunked to raw (received=' + stream.received + ')');
          if (!sniffCompacted) {
            // 缓冲仍覆盖 bodyStart 起的全部内容：truncate 后整体按 raw 重写
            try {
              fs.truncateSync(stream.file.fd, 0);
              fs.lseek(stream.file.fd, 0, fs.WhenceType.SEEK_SET);
            } catch (truncError) {
              Lg.w('LocalSend raw fallback: truncate failed ' + JSON.stringify(truncError));
            }
            stream.received = 0;
            stream.lastPct = -1;
            stream.chunkSize = -1;
            this.writeRawData(session, stream, buffer.slice(bodyStart));
          } else {
            // 缓冲已压实无法重建前缀：仅剩余内容按 raw 追加
            Lg.w('LocalSend raw fallback: buffer compacted, appending raw tail from pos=' + stream.pos);
            this.writeRawData(session, stream, buffer.slice(stream.pos));
          }
          mode = 'raw';
          if (contentLength > 0 && stream.received >= contentLength) {
            settle(true, 200, '{"status":"ok"}');
          } else if (stream.total > 0 && stream.received >= stream.total) {
            armDone();
          } else {
            armIdle();
          }
          return;
        } else if (parsed === -2) {
          Lg.w('LocalSend chunked: writing raw tail from pos=' + stream.pos + ' (received=' + stream.received + ')');
          this.writeRawData(session, stream, buffer.slice(stream.pos));
          mode = 'raw';
          if (contentLength > 0 && stream.received >= contentLength) {
            settle(true, 200, '{"status":"ok"}');
          } else if (stream.total > 0 && stream.received >= stream.total) {
            armDone();
          } else {
            armIdle();
          }
          return;
        } else if (parsed === 0) {
          const streamTotal = stream.total > 0 ? stream.total : session.totalBytes;
          if (stream.received > streamTotal + MAX_OVERREAD_BYTES) {
            Lg.w('LocalSend chunked: overread limit reached (' + stream.received + ' > ' + streamTotal + '), aborting');
            this.releaseStream(stream);
            respondAndClose(500, '{"status":"error"}');
            return;
          }
          if (stream.pos >= 1024 * 1024) {
            buffer = buffer.slice(stream.pos);
            stream.pos = 0;
            sniffCompacted = true;
          }
          if (stream.total > 0 && stream.received >= stream.total) {
            armDone();
          } else {
            armIdle();
          }
          return;
        } else {
          settle(true, 200, '{"status":"ok"}');
          return;
        }
      }
      if (mode === 'mp') {
        if (mpDelimBytes.length === 0) {
          respondAndClose(400, '{"status":"bad-request"}');
          return;
        }
        if (stream === undefined && buffer.length <= bodyStart) {
          return;
        }
        if (stream === undefined) {
          const result = LocalSendServer.scanMultipartPart(buffer, mpScanPos, mpDelimBytes, mpFields);
          if (result.kind === 'need-more') {
            mpScanPos = result.scanPos;
            if (mpScanPos >= 1024 * 1024) {
              buffer = buffer.slice(mpScanPos);
              bodyStart = 0;
              mpScanPos = 0;
            }
            return;
          }
          if (result.kind !== 'file') {
            Lg.w('LocalSend multipart: no file part found (kind=' + result.kind + ')');
            respondAndClose(400, '{"status":"missing-file"}');
            return;
          }
          const effSessionId = mpFields.sessionId.length > 0 ? mpFields.sessionId : (headQuery.get('sessionId') ?? '');
          const effFileId = mpFields.fileId.length > 0 ? mpFields.fileId : (headQuery.get('fileId') ?? '');
          const effToken = mpFields.token.length > 0 ? mpFields.token : (headQuery.get('token') ?? '');
          const opened = this.tryOpenUploadStream(effSessionId, effFileId, effToken);
          if (opened === 'unauthorized') {
            Lg.w('LocalSend multipart upload 401: session missing or token mismatch id=' + effSessionId);
            respondAndClose(401, '{"status":"unauthorized"}');
            return;
          }
          if (opened === 'error') {
            respondAndClose(500, '{"status":"error"}');
            return;
          }
          stream = opened;
          if (result.fileName.length > 0) {
            stream.name = result.fileName;
          }
          stream.pos = result.fileDataStart;
          stream.mpDelim = mpDelimBytes;
          stream.mpPhase = 1;
          Lg.i('LocalSend multipart upload started: ' + stream.sessionId + ' ' + stream.name + ' -> ' + stream.path);
        }
        const sessionForStream = this.sessions.get(stream.sessionId);
        if (sessionForStream === undefined) {
          settle(false, 0, '');
          return;
        }
        this.touchSession(stream.sessionId);
        const parsed = this.consumeMultipart(buffer, stream);
        if (parsed === 1) {
          settle(true, 200, '{"status":"ok"}');
          return;
        }
        if (parsed === -1) {
          Lg.w('LocalSend multipart: framing broken, settling partial (received=' + stream.received + ')');
          settle(false, 0, '');
          return;
        }
        if (stream.pos >= 1024 * 1024) {
          buffer = buffer.slice(stream.pos);
          stream.pos = 0;
          bodyStart = 0;
        }
        if (stream.total > 0 && stream.received >= stream.total) {
          armDone();
        } else {
          armIdle();
        }
        return;
      }
      if (buffer.length < bodyStart + contentLength) {
        return;
      }
      handled = true;
      clearTimers();
      const request = LocalSendServer.parseRequest(headText, buffer.slice(bodyStart, bodyStart + contentLength));
      this.route(request, conn);
    });
    conn.onClose((): void => {
      clearTimers();
      if (!handled && stream !== undefined) {
        Lg.i('羊绒互传 LocalSend upload connection closed, settling stream (mode=' + mode + ' received=' + stream.received + ')');
        settle(false, 0, '');
      }
    });
  }

  private releaseStream(state: StreamState): void {
    const session = this.sessions.get(state.sessionId);
    if (session !== undefined) {
      session.activeStreams -= 1;
      session.completed += 1;
      if (session.activeStreams <= 0 && session.completed >= session.files.size) {
        this.sessions.delete(state.sessionId);
      }
    }
    this.closeStream(state);
  }

  private route(request: ParsedRequest, conn: ServerConnection): void {
    const normalized = request.path.replace(/\/+$/, '');
    this.dispatch(normalized, request, conn).then(() => {
      conn.close();
    }).catch((error: Error) => {
      Lg.w(`LocalSend route failed: ${error.message}`);
      conn.sendBytes(LocalSendServer.encodeResponse(500, '{"status":"error"}')).then(() => {
        conn.close();
      }).catch(() => {
        conn.close();
      });
    });
  }

  private async dispatch(path: string, request: ParsedRequest, conn: ServerConnection): Promise<void> {
    Lg.i('LocalSend http: ' + request.method + ' ' + path + ' bytes=' + request.body.length);
    // 浏览器「局域网网页传输」：GET 首页返回 HTML 上传页面（复用同一 LocalSend 接收管线）。
    // route() 会去掉尾部斜杠，因此根路径 '/' 在此处归一化为空串 ''，需一并匹配。
    if (request.method === 'GET' && (path === '' || path === '/' || path === '/index.html' || path === '/web')) {
      await conn.sendBytes(LocalSendServer.encodeHtmlResponse(200, await this.webPage()));
      return;
    }
    // 网页端下载本机共享文件：列出可下载文件（share/list）与下载文件流（share/download）。
    if (request.method === 'GET') {
      if (path === '/api/localsend/v2/share/list' || path === '/api/localsend/v1/share/list' || path === '/api/share/list') {
        const files = this.listShares();
        await conn.sendBytes(LocalSendServer.encodeResponse(200, JSON.stringify({ files: files })));
        return;
      }
      if (path === '/api/localsend/v2/share/download' || path === '/api/localsend/v1/share/download' || path === '/api/share/download') {
        const id = request.query.get('id') ?? '';
        await this.handleDownload(request, conn, id);
        return;
      }
    }
    if (request.method === 'GET' || request.method === 'POST') {
      if (path === '/api/info' || path === '/api/localsend/v1/info' || path === '/api/localsend/v2/info') {
        await conn.sendBytes(LocalSendServer.encodeResponse(200, await this.infoJson()));
        return;
      }
    }
    if (request.method === 'POST') {
      if (path === '/api/localsend/v2/register' || path === '/api/localsend/v1/register' || path === '/api/register') {
        await conn.sendBytes(LocalSendServer.encodeResponse(200, await this.infoJson()));
        return;
      }
      if (path === '/api/localsend/v2/cancel' || path === '/api/localsend/v1/cancel') {
        const sessionId = request.query.get('sessionId') ?? '';
        Lg.i('羊绒互传 LocalSend cancel: session ' + sessionId + ' removed=' + this.sessions.delete(sessionId));
        await conn.sendBytes(LocalSendServer.encodeResponse(200, '{}'));
        return;
      }
      if (path === '/api/send' || path === '/api/localsend/v1/send' || path === '/api/localsend/v2/prepare-upload') {
        await this.handleSendRequest(request, conn);
        return;
      }
      if (path === '/api/localsend/v2/send-request') {
        await this.handleSendRequest(request, conn);
        return;
      }
      if (path === '/api/upload' || path === '/api/localsend/v1/upload' || path === '/api/localsend/v2/upload') {
        await this.handleUpload(request, conn);
        return;
      }
    }
    await conn.sendBytes(LocalSendServer.encodeResponse(404, '{"status":"not-found"}'));
  }

  /** 浏览器「局域网网页传输」页面：从 rawfile 读取并缓存 HTML 内容。 */
  private async webPage(): Promise<string> {
    if (this.webHtmlCache.length > 0) {
      return this.webHtmlCache;
    }
    try {
      const raw = await this.context.resourceManager.getRawFileContent('web_receive.html');
      this.webHtmlCache = ByteUtils.decodeText(raw);
    } catch (error) {
      Lg.w('局域网网页传输页面加载失败: ' + JSON.stringify(error));
      return '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><title>局域网网页传输</title></head><body style="font-family:sans-serif;padding:24px">局域网网页传输页面加载失败，请确认资源已打包。</body></html>';
    }
    return this.webHtmlCache;
  }

  /** 网页端下载本机共享文件：先发响应头（含 Content-Length/Disposition），再按块流式发送文件体。 */
  private async handleDownload(request: ParsedRequest, conn: ServerConnection, id: string): Promise<void> {
    if (id.length === 0) {
      await conn.sendBytes(LocalSendServer.encodeResponse(404, '{"status":"not-found"}'));
      return;
    }
    this.pruneExpiredShares();
    const share = this.shares.get(id);
    if (share === undefined) {
      Lg.w('羊绒互传 web download 404: id=' + id);
      await conn.sendBytes(LocalSendServer.encodeResponse(404, '{"status":"not-found"}'));
      return;
    }
    let fd = -1;
    try {
      fd = fs.openSync(share.path, fs.OpenMode.READ_ONLY).fd;
      const safeName = share.name.replace(/["\\\r\n]/g, '_');
      const head = 'HTTP/1.1 200 OK\r\n' +
        'Content-Type: application/octet-stream\r\n' +
        'Content-Disposition: attachment; filename="' + safeName + '"\r\n' +
        'Content-Length: ' + share.size + '\r\n' +
        'Connection: close\r\n\r\n';
      await conn.sendBytes(ByteUtils.encodeText(head));
      const buf = new ArrayBuffer(256 * 1024);
      let sent = 0;
      while (true) {
        const n = fs.readSync(fd, buf);
        if (n <= 0) {
          break;
        }
        sent += n;
        if (sent > share.size) {
          break;
        }
        // sendBytes 需要 Uint8Array；TLS/TCP 内部会再转成全新 ArrayBuffer 发送，
        // 这里直接传 Uint8Array 即可（不要用 toArrayBuffer，它会返回 ArrayBuffer）。
        await conn.sendBytes(new Uint8Array(buf.slice(0, n)));
      }
      Lg.i('羊绒互传 web download complete: ' + id + ' sent=' + sent + '/' + share.size);
    } catch (error) {
      Lg.w('羊绒互传 web download failed: ' + JSON.stringify(error));
    } finally {
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (closeError) {
          Lg.w('羊绒互传 web download close failed: ' + JSON.stringify(closeError));
        }
      }
    }
  }

  private async infoJson(): Promise<string> {
    const settings = SettingsStore.current();
    const certFingerprint = await this.certs.fingerprint();
    const fingerprint = certFingerprint.length > 0 ? certFingerprint : await DeviceIdentity.load(this.context);
    return JSON.stringify({
      alias: settings.alias,
      version: '2.0',
      deviceModel: 'HarmonyOS NEXT',
      deviceType: 'mobile',
      fingerprint,
      port: LocalSendServer.actualPort,
      protocol: this.httpsActive ? 'https' : 'http',
      download: true
    });
  }

  private async handleSendRequest(request: ParsedRequest, conn: ServerConnection): Promise<void> {
    const pinResult = await this.checkPin(request, conn);
    if (pinResult === 'missing' || pinResult === 'invalid') {
      await conn.sendBytes(LocalSendServer.encodeResponse(401, '{"status":"unauthorized"}'));
      return;
    }
    if (pinResult === 'too-many') {
      await conn.sendBytes(LocalSendServer.encodeResponse(429, '{"status":"too-many-attempts"}'));
      return;
    }
    let parsed: SendRequestJson;
    try {
      parsed = JSON.parse(ByteUtils.decodeText(request.body)) as SendRequestJson;
    } catch (error) {
      await conn.sendBytes(LocalSendServer.encodeResponse(400, '{"status":"bad-request"}'));
      return;
    }
    const files: Map<string, SessionFileMeta> = new Map();
    const metaList: SessionFileMeta[] = [];
    let totalBytes = 0;
    if (parsed.files !== undefined) {
      const ids = Object.keys(parsed.files);
      for (const id of ids) {
        const info = parsed.files[id];
        const meta: SessionFileMeta = { id, name: info.fileName, size: info.size };
        files.set(id, meta);
        metaList.push(meta);
        totalBytes += info.size;
      }
    }
    if (metaList.length === 0) {
      await conn.sendBytes(LocalSendServer.encodeResponse(400, '{"status":"empty-request"}'));
      return;
    }
    this.sweepExpiredSessions();
    if (this.sessions.size >= MAX_SESSIONS) {
      Lg.w('羊绒互传 LocalSend session cap reached: ' + this.sessions.size + ', rejecting session request');
      await conn.sendBytes(LocalSendServer.encodeResponse(429, '{"status":"too-many-sessions"}'));
      return;
    }
    const sessionId = SecurityUtils.createToken();
    const token = SecurityUtils.createToken();
    const pin = SecurityUtils.createPin();
    this.sessions.set(sessionId, {
      token,
      pin,
      files,
      receivedBytes: 0,
      totalBytes,
      activeStreams: 0,
      completed: 0,
      expiresAt: Date.now() + SESSION_TTL_MS
    });
      const peerName = parsed.info !== undefined && parsed.info.alias !== undefined && parsed.info.alias.length > 0
      ? parsed.info.alias : 'LocalSend peer';
    Lg.i('羊绒互传 LocalSend send-request: peer=' + peerName + ' files=' + metaList.length + ' totalBytes=' + totalBytes);
    let accepted = true;
    if (this.handler !== undefined) {
      accepted = await this.handler.onSessionRequested({ sessionId, peerName, files: metaList, pin });
    }
    Lg.i('羊绒互传 LocalSend send-request: session ' + sessionId + ' accepted=' + accepted);
    if (!accepted) {
      this.sessions.delete(sessionId);
      await conn.sendBytes(LocalSendServer.encodeResponse(403, '{"status":"rejected"}'));
      return;
    }
      const fileTokens: Record<string, string> = {};
      for (const id of Array.from(files.keys())) {
        fileTokens[id] = token;
      }
    await conn.sendBytes(LocalSendServer.encodeResponse(200, JSON.stringify({ sessionId, token, files: fileTokens })));
  }

  /** LocalSend 官方 PIN 语义：接收方配置 receivePin 后，发送方必须携带匹配的 ?pin= 才能建会话。
   *  未配置 PIN 直接放行；连错 3 次按 IP 锁定返回 429。 */
  private async checkPin(request: ParsedRequest, conn: ServerConnection): Promise<'ok' | 'missing' | 'invalid' | 'too-many'> {
    const receivePin = SettingsStore.current().receivePin;
    if (receivePin === undefined || receivePin.length === 0) {
      return 'ok';
    }
    const remoteIp = await conn.peerAddress();
    const attempts = this.pinAttempts.get(remoteIp) ?? 0;
    const requestPin = request.query.get('pin') ?? '';
    if (requestPin === receivePin) {
      this.pinAttempts.delete(remoteIp);
      return 'ok';
    }
    const next = attempts + 1;
    this.pinAttempts.set(remoteIp, next);
    if (requestPin.length === 0) {
      return 'missing';
    }
    if (next >= 3) {
      Lg.w('羊绒互传 LocalSend pin lockout: ip=' + remoteIp + ' attempts=' + next);
      return 'too-many';
    }
    Lg.w('羊绒互传 LocalSend invalid pin from ' + remoteIp + ' attempts=' + next);
    return 'invalid';
  }

  private async handleUpload(request: ParsedRequest, conn: ServerConnection): Promise<void> {
    let sessionId = request.query.get('sessionId') ?? '';
    let fileId = request.query.get('fileId') ?? '';
    let token = request.query.get('token') ?? '';
    let fileName = request.query.get('fileName') ?? '';
    let fileData = request.body;
    const contentType = request.headers.get('content-type') ?? '';
    if (contentType.indexOf('multipart/form-data') >= 0) {
      const fields = LocalSendServer.parseMultipart(request.body, contentType);
      for (const field of fields) {
        if (field.name === 'sessionId') {
          sessionId = ByteUtils.decodeText(field.data);
        } else if (field.name === 'fileId') {
          fileId = ByteUtils.decodeText(field.data);
        } else if (field.name === 'token') {
          token = ByteUtils.decodeText(field.data);
        } else if (field.name === 'file') {
          fileData = field.data;
          if (field.fileName.length > 0) {
            fileName = field.fileName;
          }
        }
      }
    }
    const session = this.sessions.get(sessionId);
    if (session === undefined || session.token !== token) {
      await conn.sendBytes(LocalSendServer.encodeResponse(401, '{"status":"unauthorized"}'));
      return;
    }
    if (session.expiresAt <= Date.now()) {
      this.sessions.delete(sessionId);
      await conn.sendBytes(LocalSendServer.encodeResponse(401, '{"status":"unauthorized"}'));
      return;
    }
    const meta = session.files.get(fileId);
    const effectiveName = fileName.length > 0 ? fileName : (meta !== undefined ? meta.name : fileId);
    if (effectiveName.length === 0) {
      await conn.sendBytes(LocalSendServer.encodeResponse(400, '{"status":"missing-file"}'));
      return;
    }
    const savedPath = await this.writeIncomingFile(effectiveName, fileData);
    Lg.i('LocalSend upload saved: ' + effectiveName + ' (' + fileData.length + ' bytes) -> ' + savedPath);
    session.receivedBytes += fileData.length;
    session.expiresAt = Date.now() + SESSION_TTL_MS;
    if (this.handler !== undefined) {
      const progress = session.totalBytes > 0 ? session.receivedBytes / session.totalBytes * 100 : 100;
      // 数据已写入但尚未 relocate 到最终目录，clamp 到 <100 以免提前触发 completed
      // （与 chunked 路径一致），真正的完成交给下方 relocate 完成后的 onProgress(100)。
      this.handler.onProgress(sessionId, Math.min(progress, 99.9));
    }
    if (session.receivedBytes >= session.totalBytes) {
      this.sessions.delete(sessionId);
    }
    await conn.sendBytes(LocalSendServer.encodeResponse(200, '{"status":"ok"}'));
    void this.relocateIncoming(savedPath, session.files.size === 1, effectiveName).then((finalPath: string): void => {
      if (this.handler !== undefined) {
        this.handler.onFileReceived(sessionId, { name: effectiveName, size: fileData.length, savedPath: finalPath });
        this.handler.onProgress(sessionId, 100);
      }
    });
  }

  private openIncomingStream(fileName: string): OpenStreamResult {
    const dir = `${this.context.filesDir}/incoming`;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    const sanitized = fileName.replace(/[\\/:*?"<>|]/g, '_');
    let target = `${dir}/${sanitized}`;
    if (fs.accessSync(target)) {
      target = `${dir}/${Date.now()}-${sanitized}`;
    }
    const file = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    return { file, path: target };
  }

  private tryOpenUploadStream(sessionId: string, fileId: string, token: string): StreamState | 'unauthorized' | 'error' {
    const session = this.sessions.get(sessionId);
    if (session === undefined || session.token !== token) {
      Lg.w('LocalSend upload 401: session=' + (session === undefined ? 'missing' : 'token-mismatch') + ' id=' + sessionId);
      return 'unauthorized';
    }
    if (session.expiresAt <= Date.now()) {
      this.sessions.delete(sessionId);
      Lg.w('LocalSend upload rejected: session expired id=' + sessionId);
      return 'unauthorized';
    }
    const meta = session.files.get(fileId);
    const name = meta !== undefined ? meta.name : fileId;
    try {
      const opened = this.openIncomingStream(name);
      session.activeStreams += 1;
      session.expiresAt = Date.now() + SESSION_TTL_MS;
      return {
        file: opened.file,
        path: opened.path,
        sessionId,
        name,
        lastPct: -1,
        pos: 0,
        total: meta !== undefined ? meta.size : 0,
        received: 0,
        chunkSize: -1,
        waitingLine: false,
        mpPhase: 0
      };
    } catch (error) {
      Lg.w('LocalSend stream open failed: ' + JSON.stringify(error));
      return 'error';
    }
  }

  private writeRawData(session: SessionState, stream: StreamState, data: Uint8Array): void {
    if (data.length === 0) {
      return;
    }
    fs.writeSync(stream.file.fd, ByteUtils.toArrayBuffer(data));
    stream.received += data.length;
    session.receivedBytes += data.length;
    session.expiresAt = Date.now() + SESSION_TTL_MS;
    const total = stream.total > 0 ? stream.total : session.totalBytes;
    const capped = total > 0 ? Math.min(stream.received / total * 100, 100) : 100;
    const pct = Math.floor(capped);
    if (pct !== stream.lastPct) {
      stream.lastPct = pct;
      Lg.i('LocalSend raw progress: ' + stream.received + '/' + total + ' (' + pct + '%)');
      if (this.handler !== undefined) {
        this.handler.onProgress(stream.sessionId, Math.min(capped, 99.9));
      }
    }
  }

  private async reportReceived(stream: StreamState, session: SessionState, allowPrompt: boolean): Promise<void> {
    const finalPath = await this.relocateIncoming(stream.path, allowPrompt);
    if (this.handler !== undefined) {
      this.handler.onFileReceived(stream.sessionId, { name: stream.name, size: stream.received, savedPath: finalPath });
      this.handler.onProgress(stream.sessionId, 100);
    }
  }

  private async relocateIncoming(srcPath: string, allowPrompt: boolean, preferredName: string = ''): Promise<string> {
    Lg.i('LocalSend receive relocate: src=' + srcPath + ' allowPrompt=' + allowPrompt);
    const slash = srcPath.lastIndexOf('/');
    const name = preferredName.length > 0 ? preferredName : (slash >= 0 ? srcPath.substring(slash + 1) : srcPath);
    try {
      const silentDest = await this.trySilentDownload(srcPath, name);
      if (silentDest.length > 0) {
        return silentDest;
      }
    } catch (error) {
      Lg.w('LocalSend receive relocate: silent attempt failed ' + JSON.stringify(error));
    }
    try {
      let folder = LocalSendServer.downloadDirUri;
      if (folder.length === 0) {
        const savePicker = new picker.DocumentViewPicker();
        const options = new picker.DocumentSaveOptions();
        options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
        const uris = await savePicker.save(options);
        if (uris.length > 0) {
          folder = uris[0] ?? '';
          LocalSendServer.downloadDirUri = folder;
        }
      }
      const base = folder.length > 0 ? folder.substring(0, folder.lastIndexOf('/')) : 'file://docs/storage/Users/currentUser/Download';
      const targetDir = base + '/羊绒互传';
      if (!allowPrompt) {
        Lg.w('LocalSend receive relocate: multi-file session, keep in incoming (silent download failed)');
        return srcPath;
      }
      Lg.i('LocalSend receive relocate: prompting save-picker, dir=' + targetDir + ' name=' + name);
      const pickerResult = await this.trySavePicker(srcPath, name, targetDir);
      if (pickerResult.length > 0) {
        return pickerResult;
      }
      Lg.w('LocalSend receive relocate: save-picker cancelled or failed');
      return srcPath;
    } catch (error) {
      Lg.w('LocalSend receive relocate failed: ' + JSON.stringify(error));
      return srcPath;
    }
  }

  /** 目标路径是否已存在（用 statSync 捕获不存在错误判定）。 */
  private pathExists(path: string): boolean {
    try {
      fs.statSync(path);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 在 folder 下为 name 生成一个不重复的完整路径：若同名已存在则追加 (n) 后缀，
   *  避免重复接收同一文件时覆盖旧文件（发送端重试会把同一文件再传到同一目录）。 */
  private uniqueDestination(folder: string, name: string): string {
    const sep = folder.endsWith('/') ? '' : '/';
    const first = new fileUri.FileUri(folder + sep + name).path;
    if (!this.pathExists(first)) {
      return first;
    }
    const dot = name.lastIndexOf('.');
    const base = dot > 0 ? name.substring(0, dot) : name;
    const ext = dot > 0 ? name.substring(dot) : '';
    for (let i = 1; i < 999; i++) {
      const cand = new fileUri.FileUri(folder + sep + base + ' (' + i + ')' + ext).path;
      if (!this.pathExists(cand)) {
        return cand;
      }
    }
    return first;
  }

  private async trySilentDownload(srcPath: string, name: string): Promise<string> {
    let folder = LocalSendServer.downloadDirUri;
    if (folder.length === 0) {
      const savePicker = new picker.DocumentViewPicker(this.context);
      const options = new picker.DocumentSaveOptions();
      options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
      const uris = await savePicker.save(options);
      if (uris.length === 0) {
        return '';
      }
      folder = uris[0] ?? '';
      LocalSendServer.downloadDirUri = folder;
    }
    const sep = folder.endsWith('/') ? '' : '/';
    const dest = this.uniqueDestination(folder, name);
    Lg.i('LocalSend receive relocate: silent dest=' + dest);
    let srcFd = -1;
    let dstFd = -1;
    try {
      srcFd = fs.openSync(srcPath, fs.OpenMode.READ_ONLY).fd;
      dstFd = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE).fd;
      const buf = new ArrayBuffer(1024 * 1024);
      let n = fs.readSync(srcFd, buf);
      while (n > 0) {
        fs.writeSync(dstFd, buf.slice(0, n));
        n = fs.readSync(srcFd, buf);
      }
      fs.closeSync(srcFd);
      srcFd = -1;
      fs.closeSync(dstFd);
      dstFd = -1;
      fs.unlinkSync(srcPath);
      Lg.i('LocalSend receive relocated: ' + srcPath + ' -> ' + dest);
      return dest;
    } catch (error) {
      Lg.w('LocalSend receive relocate: silent write failed ' + JSON.stringify(error));
      try {
        if (srcFd >= 0) {
          fs.closeSync(srcFd);
        }
      } catch (closeError) {
        Lg.w('LocalSend receive relocate src close failed: ' + JSON.stringify(closeError));
      }
      try {
        if (dstFd >= 0) {
          fs.closeSync(dstFd);
        }
      } catch (closeError) {
        Lg.w('LocalSend receive relocate dst close failed: ' + JSON.stringify(closeError));
      }
      return '';
    }
  }

  private async trySavePicker(srcPath: string, name: string, targetDir: string): Promise<string> {
    let srcFd = -1;
    let dstFd = -1;
    try {
      const savePicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSaveOptions();
      options.pickerMode = picker.DocumentPickerMode.DEFAULT;
      options.newFileNames = [name];
      options.defaultFilePathUri = targetDir;
      const uris = await savePicker.save(options);
      if (uris.length === 0) {
        Lg.w('LocalSend receive relocate: save-picker returned no uri (cancelled?)');
        return '';
      }
      const dest = uris[0] ?? '';
      Lg.i('LocalSend receive relocate: picker dest=' + dest);
      srcFd = fs.openSync(srcPath, fs.OpenMode.READ_ONLY).fd;
      dstFd = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC).fd;
      const buf = new ArrayBuffer(1024 * 1024);
      let n = fs.readSync(srcFd, buf);
      while (n > 0) {
        fs.writeSync(dstFd, buf.slice(0, n));
        n = fs.readSync(srcFd, buf);
      }
      fs.closeSync(srcFd);
      srcFd = -1;
      fs.closeSync(dstFd);
      dstFd = -1;
      fs.unlinkSync(srcPath);
      Lg.i('LocalSend receive relocated: ' + srcPath + ' -> ' + dest);
      return dest;
    } catch (error) {
      Lg.w('LocalSend receive relocate: picker write failed ' + JSON.stringify(error));
      try {
        if (srcFd >= 0) {
          fs.closeSync(srcFd);
        }
      } catch (closeError) {
        Lg.w('LocalSend receive relocate src close failed: ' + JSON.stringify(closeError));
      }
      try {
        if (dstFd >= 0) {
          fs.closeSync(dstFd);
        }
      } catch (closeError) {
        Lg.w('LocalSend receive relocate dst close failed: ' + JSON.stringify(closeError));
      }
      return '';
    }
  }
  private closeStream(state: StreamState): void {
    try {
      fs.closeSync(state.file);
    } catch (error) {
      Lg.w('LocalSend stream close failed: ' + JSON.stringify(error));
    }
  }

  private consumeChunked(buffer: Uint8Array, state: StreamState): number {
    while (true) {
      if (state.chunkSize < 0) {
        const lineEnd = ByteUtils.indexOf(buffer, CRLF, state.pos);
        if (lineEnd < 0) {
          return 0;
        }
        const sizeText = ByteUtils.decodeText(buffer.slice(state.pos, lineEnd));
        const semi = sizeText.indexOf(';');
        const sizeHex = (semi >= 0 ? sizeText.substring(0, semi) : sizeText).trim();
        const size = parseInt(sizeHex, 16);
        if (Number.isNaN(size)) {
          if (!state.waitingLine) {
            state.waitingLine = true;
            Lg.w('LocalSend chunked: invalid size line (linePos=' + state.pos + ' lineLen=' + (lineEnd - state.pos) + ' chunkSize=' + state.chunkSize + ' received=' + state.received + ' bufLen=' + buffer.length + ')');
          }
          return -1;
        }
        state.pos = lineEnd + CRLF.length;
        state.waitingLine = false;
        state.chunkSize = size;
        if (size === 0) {
          if (buffer.length < state.pos + CRLF.length || buffer[state.pos] !== CRLF[0] || buffer[state.pos + 1] !== CRLF[1]) {
            return 0;
          }
          state.pos += CRLF.length;
          return 1;
        }
      }
      const needEnd = state.pos + state.chunkSize + CRLF.length;
      if (buffer.length < needEnd) {
        return 0;
      }
      const data = buffer.slice(state.pos, state.pos + state.chunkSize);
      fs.writeSync(state.file.fd, ByteUtils.toArrayBuffer(data));
      state.received += data.length;
      const chTotal = state.total > 0 ? state.total : 0;
      const rawProgress = chTotal > 0 ? state.received / chTotal * 100 : 100;
      const capped = Math.min(rawProgress, 100);
      const pct = Math.floor(capped);
      if (pct !== state.lastPct) {
        state.lastPct = pct;
        Lg.i('LocalSend chunked progress: ' + state.received + '/' + chTotal + ' (' + pct + '%)');
        if (this.handler !== undefined) {
          // 数据已写完但尚未 relocate 到最终目录，此时不要把进度推到 100：否则会提前触发
          // completed（receievedFiles 还没填充、sessionTasks 早删），后续 reportReceived
          // 的 onFileReceived/onProgress(100) 会被 taskForSession 判空而丢弃，导致完成框缺
          // 「打开」按钮、且被首次「保存位置」picker 遮挡。clamp 到 <100 让真正完成由
          // reportReceived 的 onProgress(100) 在落盘后统一收尾。
          this.handler.onProgress(state.sessionId, Math.min(capped, 99.9));
        }
      }
      if (chTotal > 0 && state.received > chTotal) {
        Lg.w('LocalSend chunked: overread received=' + state.received + ' total=' + chTotal);
      }
      state.pos += state.chunkSize + CRLF.length;
      state.chunkSize = -1;
    }
  }

  private consumeMultipart(buffer: Uint8Array, state: StreamState): number {
    const delim = state.mpDelim;
    if (delim === undefined || delim.length === 0) {
      return -1;
    }
    while (true) {
      if (state.mpPhase === 1) {
        const idx = ByteUtils.indexOf(buffer, delim, state.pos);
        if (idx < 0) {
          const keep = delim.length - 1;
          const writeEnd = Math.max(state.pos, buffer.length - keep);
          if (writeEnd > state.pos) {
            const session = this.sessions.get(state.sessionId);
            if (session !== undefined) {
              this.writeRawData(session, state, buffer.slice(state.pos, writeEnd));
            }
          }
          state.pos = Math.min(writeEnd, buffer.length);
          return 0;
        }
        let dataEnd = idx;
        if (dataEnd >= state.pos + 2 && buffer[dataEnd - 2] === 13 && buffer[dataEnd - 1] === 10) {
          dataEnd -= 2;
        }
        if (dataEnd > state.pos) {
          const session = this.sessions.get(state.sessionId);
          if (session !== undefined) {
            this.writeRawData(session, state, buffer.slice(state.pos, dataEnd));
          }
        }
        let p = idx + delim.length;
        if (p + 2 > buffer.length) {
          // 分隔符尾部（-- 或 CRLF）尚未到齐，等待更多数据后再判定，幂等重扫
          state.pos = idx;
          return 0;
        }
        if (buffer[p] === 0x2d && buffer[p + 1] === 0x2d) {
          state.pos = p + 2;
          return 1;
        }
        if (buffer[p] === 0x0d && buffer[p + 1] === 0x0a) {
          p += 2;
        }
        state.pos = p;
        state.mpPhase = 0;
        continue;
      }
      const idx = ByteUtils.indexOf(buffer, delim, state.pos);
      if (idx < 0) {
        if (buffer.length - state.pos > MAX_MP_SCAN_BYTES) {
          return -1;
        }
        return 0;
      }
      let p = idx + delim.length;
      if (p + 2 > buffer.length) {
        state.pos = idx;
        return 0;
      }
      if (buffer[p] === 0x2d && buffer[p + 1] === 0x2d) {
        state.pos = p + 2;
        return 1;
      }
      if (buffer[p] === 0x0d && buffer[p + 1] === 0x0a) {
        p += 2;
      }
      const headerEnd = ByteUtils.indexOf(buffer, CRLF_CRLF, p);
      if (headerEnd < 0) {
        if (buffer.length - p > MAX_MP_HEADER_BYTES) {
          return -1;
        }
        return 0;
      }
      const headerText = ByteUtils.decodeText(buffer.slice(p, headerEnd));
      const nameMatch = /name="([^"]*)"/.exec(headerText);
      const name = nameMatch !== null ? nameMatch[1] : '';
      if (name === 'file') {
        state.pos = headerEnd + 4;
        state.mpPhase = 1;
        continue;
      }
      const next = ByteUtils.indexOf(buffer, delim, headerEnd + 4);
      if (next < 0) {
        return 0;
      }
      state.pos = next;
    }
  }

  private async writeIncomingFile(fileName: string, data: Uint8Array): Promise<string> {
    const opened = this.openIncomingStream(fileName);
    try {
      await fs.write(opened.file.fd, ByteUtils.toArrayBuffer(data));
    } finally {
      fs.closeSync(opened.file);
    }
    return opened.path;
  }

  private static scanMultipartPart(buffer: Uint8Array, from: number, delim: Uint8Array, fields: MpScan): MpPartResult {
    let pos = from;
    while (true) {
      const idx = ByteUtils.indexOf(buffer, delim, pos);
      if (idx < 0) {
        if (buffer.length - pos > MAX_MP_SCAN_BYTES) {
          return { kind: 'broken', sessionId: fields.sessionId, fileId: fields.fileId, token: fields.token, fileName: '', fileDataStart: 0, scanPos: pos };
        }
        return { kind: 'need-more', sessionId: fields.sessionId, fileId: fields.fileId, token: fields.token, fileName: '', fileDataStart: 0, scanPos: pos };
      }
      let p = idx + delim.length;
      if (p + 1 < buffer.length && buffer[p] === 0x2d && buffer[p + 1] === 0x2d) {
        return { kind: 'empty', sessionId: fields.sessionId, fileId: fields.fileId, token: fields.token, fileName: '', fileDataStart: 0, scanPos: pos };
      }
      if (p + 1 < buffer.length && buffer[p] === 0x0d && buffer[p + 1] === 0x0a) {
        p += 2;
      }
      const headerEnd = ByteUtils.indexOf(buffer, CRLF_CRLF, p);
      if (headerEnd < 0) {
        if (buffer.length - p > MAX_MP_HEADER_BYTES) {
          return { kind: 'broken', sessionId: fields.sessionId, fileId: fields.fileId, token: fields.token, fileName: '', fileDataStart: 0, scanPos: pos };
        }
        return { kind: 'need-more', sessionId: fields.sessionId, fileId: fields.fileId, token: fields.token, fileName: '', fileDataStart: 0, scanPos: pos };
      }
      const headerText = ByteUtils.decodeText(buffer.slice(p, headerEnd));
      const nameMatch = /name="([^"]*)"/.exec(headerText);
      const name = nameMatch !== null ? nameMatch[1] : '';
      const fileMatch = /filename="([^"]*)"/.exec(headerText);
      const fileName = fileMatch !== null ? fileMatch[1] : '';
      if (name === 'file') {
        return { kind: 'file', sessionId: fields.sessionId, fileId: fields.fileId, token: fields.token, fileName, fileDataStart: headerEnd + 4, scanPos: pos };
      }
      const next = ByteUtils.indexOf(buffer, delim, headerEnd + 4);
      if (next < 0) {
        return { kind: 'need-more', sessionId: fields.sessionId, fileId: fields.fileId, token: fields.token, fileName: '', fileDataStart: 0, scanPos: pos };
      }
      let end = next;
      if (end - 2 >= headerEnd + 4 && buffer[end - 2] === 0x0d && buffer[end - 1] === 0x0a) {
        end -= 2;
      }
      const value = ByteUtils.decodeText(buffer.slice(headerEnd + 4, end));
      if (name === 'sessionId') {
        fields.sessionId = value;
      } else if (name === 'fileId') {
        fields.fileId = value;
      } else if (name === 'token') {
        fields.token = value;
      }
      pos = next;
    }
  }

  private static parseRequest(headText: string, body: Uint8Array): ParsedRequest {
    const lines = headText.split('\r\n');
    const requestLine = lines[0].split(' ');
    const method = requestLine[0] ?? 'GET';
    const target = requestLine[1] ?? '/';
    const query = new Map<string, string>();
    let path = target;
    const question = target.indexOf('?');
    if (question >= 0) {
      path = target.substring(0, question);
      const pairs = target.substring(question + 1).split('&');
      for (const pair of pairs) {
        const eq = pair.indexOf('=');
        if (eq > 0) {
          query.set(decodeURIComponent(pair.substring(0, eq)), decodeURIComponent(pair.substring(eq + 1)));
        }
      }
    }
    const headers = new Map<string, string>();
    for (let i = 1; i < lines.length; i++) {
      const colon = lines[i].indexOf(':');
      if (colon > 0) {
        headers.set(lines[i].substring(0, colon).trim().toLowerCase(), lines[i].substring(colon + 1).trim());
      }
    }
    return { method, path, query, headers, body };
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

  private static isUploadPath(path: string): boolean {
    return path === '/api/upload' || path === '/api/localsend/v1/upload' || path === '/api/localsend/v2/upload';
  }

  private static readBoundary(contentType: string): string {
    const boundaryIndex = contentType.indexOf('boundary=');
    if (boundaryIndex < 0) {
      return '';
    }
    let boundary = contentType.substring(boundaryIndex + 9).trim().replace(/"/g, '');
    const semicolon = boundary.indexOf(';');
    if (semicolon >= 0) {
      boundary = boundary.substring(0, semicolon);
    }
    return boundary;
  }

  private static sniffChunkFraming(buffer: Uint8Array, start: number): boolean {
    const lineEnd = ByteUtils.indexOf(buffer, CRLF, start);
    if (lineEnd < 0) {
      return false;
    }
    const text = ByteUtils.decodeText(buffer.slice(start, lineEnd));
    if (text.length === 0 || text.length > 32) {
      return false;
    }
    const sizePart = text.split(';')[0] ?? '';
    if (sizePart.length === 0) {
      return false;
    }
    for (let k = 0; k < sizePart.length; k++) {
      const ch = sizePart.charCodeAt(k);
      const hex = (ch >= 48 && ch <= 57) || (ch >= 65 && ch <= 70) || (ch >= 97 && ch <= 102);
      if (!hex) {
        return false;
      }
    }
    return true;
  }

  private static parseMultipart(body: Uint8Array, contentType: string): MultipartField[] {
    const boundaryIndex = contentType.indexOf('boundary=');
    if (boundaryIndex < 0) {
      return [];
    }
    let boundary = contentType.substring(boundaryIndex + 9).trim().replace(/"/g, '');
    const semicolon = boundary.indexOf(';');
    if (semicolon >= 0) {
      boundary = boundary.substring(0, semicolon);
    }
    const delimiter = ByteUtils.encodeText(`--${boundary}`);
    const fields: MultipartField[] = [];
    let pos = ByteUtils.indexOf(body, delimiter, 0);
    while (pos >= 0) {
      const partStart = pos + delimiter.length;
      if (partStart + 1 < body.length && body[partStart] === 0x2d && body[partStart + 1] === 0x2d) {
        break;
      }
      const next = ByteUtils.indexOf(body, delimiter, partStart);
      if (next < 0) {
        break;
      }
      let contentStart = partStart;
      if (contentStart + 1 < body.length && body[contentStart] === 13 && body[contentStart + 1] === 10) {
        contentStart += 2;
      }
      const contentEnd = Math.max(contentStart, next - 2);
      const headerEnd = ByteUtils.indexOf(body, CRLF_CRLF, contentStart);
      if (headerEnd >= contentStart && headerEnd < contentEnd) {
        const headerText = ByteUtils.decodeText(body.slice(contentStart, headerEnd));
        const nameMatch = /name="([^"]*)"/.exec(headerText);
        const fileMatch = /filename="([^"]*)"/.exec(headerText);
        fields.push({
          name: nameMatch !== null ? nameMatch[1] : '',
          fileName: fileMatch !== null ? fileMatch[1] : '',
          data: body.slice(headerEnd + 4, contentEnd)
        });
      }
      pos = next;
    }
    return fields;
  }

  private static encodeContinue(): Uint8Array {
    return ByteUtils.encodeText('HTTP/1.1 100 Continue\r\n\r\n');
  }

  private static encodeResponse(status: number, body: string): Uint8Array {
    const reason = status === 200 ? 'OK' : (status === 403 ? 'Forbidden' : (status === 404 ? 'Not Found' : 'Error'));
    const bodyBytes = ByteUtils.encodeText(body);
    const head = `HTTP/1.1 ${status} ${reason}\r\nContent-Type: application/json\r\nContent-Length: ${bodyBytes.length}\r\nConnection: close\r\n\r\n`;
    return ByteUtils.concat([ByteUtils.encodeText(head), bodyBytes]);
  }

  /** 返回 text/html 响应（浏览器「局域网网页传输」页面）。 */
  private static encodeHtmlResponse(status: number, body: string): Uint8Array {
    const bodyBytes = ByteUtils.encodeText(body);
    const head = `HTTP/1.1 ${status} OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${bodyBytes.length}\r\nConnection: close\r\n\r\n`;
    return ByteUtils.concat([ByteUtils.encodeText(head), bodyBytes]);
  }

  private static errorCode(error: BusinessError): string {
    if (error.code !== undefined && error.code !== null) {
      return String(error.code);
    }
    const text = JSON.stringify(error);
    const match = /"code"\s*:\s*(\d+)/.exec(text);
    return match !== null ? match[1] : 'unknown';
  }
}
