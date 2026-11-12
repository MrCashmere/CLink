import { LogCapture as Lg } from '../../common/LogCapture';
import { socket } from '@kit.NetworkKit';
import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { picker, fileUri } from '@kit.CoreFileKit';
import { ByteUtils } from '../../common/ByteUtils';
import { SecurityUtils } from '../../common/SecurityUtils';
import { SettingsStore } from '../../common/SettingsStore';
import { CertificateStore } from '../../common/CertificateStore';
import { IncomingFile, OutgoingFile, SessionFileMeta, WebShareInfo } from '../../model/TransferModels';
import { DynamicPhotoService } from '../../common/DynamicPhotoService';
import { DynamicPhotoBridge } from '../../common/DynamicPhotoBridge';
import { PeerDecision, PeerLivePhotoFormat } from '../../common/PeerLivePhotoFormat';
import { GalleryAutoSaveService } from '../../quickshare/service/GalleryAutoSaveService';
import { GalleryMediaClassifier } from '../../quickshare/storage/GalleryMediaClassifier';
import tlsNative from 'libtls_transport.so';
import { sendNativeTls } from '../../common/TlsTransport';

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
  onSessionFailed?(sessionId: string, error: string): void;
  /**
   * 文件已完整落盘到应用沙箱、**尚未**被搬到下载目录时调用（await 期间会推迟搬运）。
   *
   * 存在的理由：搬运会把沙箱副本复制到下载目录后删掉源文件，而下载目录路径应用没有读
   * 权限 —— 动态图片需要在沙箱副本还在时读完并解析（见 DynamicPhotoService）。
   */
  onFileStaged(sessionId: string, file: IncomingFile): Promise<void>;
}

interface OpenStreamResult {
  file: fs.File;
  path: string;
}

interface StreamState {
  file: fs.File;
  path: string;
  sessionId: string;
  fileId: string;
  name: string;
  mime?: string;
  lastPct: number;
  pos: number;
  total: number;
  received: number;
  chunkSize: number;
  chunkPhase: number;
  mpDelim?: Uint8Array;
}

interface SessionState {
  readonly token: string;
  readonly pin: string;
  readonly files: Map<string, SessionFileMeta>;
  receivedBytes: number;
  readonly activeFiles: Set<string>;
  readonly receivedFiles: Set<string>;
  readonly savedFiles: Set<string>;
  totalBytes: number;
  expiresAt: number;
  failed?: boolean;
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

/** 按浏览器设备改写后的下载产物（缓存在 `webConverted` 里）。 */
interface WebConvertedShare {
  readonly path: string;
  readonly name: string;
  readonly size: number;
  /** 需要第二个文件的形态（Apple 实况照片：JPEG + MOV）时，伴侣文件的共享 id。 */
  readonly companionId: string;
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
    return sendNativeTls(this.handle, data, (): boolean => !this.closed);
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
/**
 * 网页端「局域网网页传输」专用端口：始终用明文 HTTP，避免 HTTPS 自签证书在浏览器上的拦截。
 *
 * ⚠️ 不要改成 53317/53318/53319，也不要改回 53318：
 * - 53317 = LocalSend 主端口（含 UDP 组播 / 子网扫描 / mDNS 通告）；
 * - 53318 = Quick Share 标准接收端口（`gs/src/main/ets/model/GsConstants.ets` 的
 *   `GS_QUICKSHARE_PORT`，`quickshare/controller/QuickShareBrowser.ets` 另有一份副本）。
 *   历史上本常量曾等于 53318：`AppServices.doStartReceive()` 先起 LocalSendServer（网页
 *   监听先占住 53318），再起 Quick Share 接收端 → Quick Share bind 失败，而 mDNS 仍按
 *   53318 对外通告，对端入站连接被网页 HTTP 解析器接管（收不到文件）；
 * - 53319 = Quick Share 环回自检端口（`QuickShareChannel.selfTest`）。
 *
 * 选 23333 的理由：低于 Linux/Android 的临时端口区间（典型 32768–60999，53317/53318/53319
 * 都在区间内，监听端口可能被出站连接的随机源端口偶发占用）；不在浏览器禁用端口表内；
 * IANA 未分配；与上述端口全不冲突。
 */
const WEB_PORT = 23333;
/** 网页监听的回退候选端口：首选被别的进程占用时依次尝试，全部失败则置 0 并明确报错。 */
const WEB_PORT_CANDIDATES: number[] = [23333, 23334, 23335];
const CRLF_CRLF = new Uint8Array([13, 10, 13, 10]);
const CRLF = new Uint8Array([13, 10]);
const MAX_HEAD_BYTES = 64 * 1024;
const MAX_BODY_BYTES = 2 * 1024 * 1024 * 1024;
const MAX_CONTROL_BODY_BYTES = 16 * 1024 * 1024;
const MAX_SNIFF_WAIT_BYTES = 1024 * 1024;
const MAX_MP_SCAN_BYTES = 1024 * 1024;
const MAX_MP_HEADER_BYTES = 64 * 1024;
const IDLE_SETTLE_MS = 60000;
const DONE_SETTLE_MS = 3000;
const SESSION_TTL_MS = 30 * 60 * 1000;
const SESSION_SWEEP_MS = 60 * 1000;
const MAX_SESSIONS = 16;
const SHARE_TTL_MS = 30 * 60 * 1000;

/** HTTP 层拿到的对端身份信号（register / send-request 请求自带对端的设备信息）。 */
export interface LocalSendPeerSignal {
  readonly address: string;
  readonly alias: string;
  readonly deviceModel: string;
  readonly fingerprint: string;
  readonly port: number;
  readonly protocol: string;
}

/** register / send-request 请求体里可能出现的对端字段（宽容解析，缺啥留空）。 */
interface PeerInfoJson {
  alias?: string;
  deviceModel?: string;
  fingerprint?: string;
  port?: number;
  protocol?: string;
}

export class LocalSendServer {
  /**
   * 对端身份信号回调：对端收到本机 announce 后会 POST /register 自报家门（LocalSend v2 协议），
   * 发送请求 /send-request 里也带对端 info。热点模式下组播收包不可靠，这条 TCP 单播通道是
   * 「对端主动告诉本机我在这里」的最稳信号，由 AppServices 接到发现链路上屏。
   */
  static onPeerSignal?: (signal: LocalSendPeerSignal) => void;
  private static downloadDirUri: string = '';
  static lastHttpsActive: boolean = false;
  static actualPort: number = 0;
  static actualWebPort: number = 0;
  private tcpServer?: socket.TCPSocketServer;
  private webTcpServer?: socket.TCPSocketServer;
  private listenHandle: number = 0;
  private readonly sessions: Map<string, SessionState> = new Map();
  private readonly pinAttempts: Map<string, number> = new Map();
  private readonly shares: Map<string, ShareState> = new Map();
  private handler?: LocalSendIncomingHandler;
  private started = false;
  private generation: number = 0;
  private startOperation?: Promise<void>;
  private closeOperation: Promise<void> = Promise.resolve();
  private httpsActiveValue = false;
  private sweepTimer: number = -1;
  /** 缓存浏览器「局域网网页传输」HTML 页面，避免每次请求都读一次 rawfile。 */
  private webHtmlCache: string = '';
  /**
   * 网页端下载时的「按浏览器设备改写后」的产物缓存（键 = 共享 id + 目标格式 + 方言）。
   *
   * 为什么必须缓存：一次转换要整份读入、重建 XMP/MPF、再写一份（真机样本 9.5 MB），
   * 浏览器还可能重复请求（用户点两次、断线重试）。同一个共享 + 同一类设备只转一次。
   */
  private readonly webConverted: Map<string, WebConvertedShare> = new Map();

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
      this.releaseWebConverted(id);
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
    const expired: string[] = [];
    this.shares.forEach((s: ShareState, id: string): void => {
      if (s.expiresAt <= now) {
        expired.push(id);
      }
    });
    for (const id of expired) {
      this.shares.delete(id);
      this.releaseWebConverted(id);
    }
  }

  /**
   * 释放某个共享对应的「按浏览器改写」产物：丢掉缓存条目，并删掉改写产生的临时文件。
   *
   * 只删动态图片工作目录里的文件：改写产物都写在那里（`DynamicPhotoBridge.workDir`）；
   * 用户原始文件绝不在删除范围内，`path === share.path` 的条目直接跳过。
   */
  private releaseWebConverted(shareId: string): void {
    const workDir = DynamicPhotoBridge.workDir(this.context);
    const drop: string[] = [];
    this.webConverted.forEach((item: WebConvertedShare, key: string): void => {
      if (key.startsWith(shareId + '|') || item.companionId === shareId) {
        drop.push(key);
      }
    });
    for (const key of drop) {
      const item = this.webConverted.get(key);
      this.webConverted.delete(key);
      if (item === undefined || !item.path.startsWith(workDir)) {
        continue;
      }
      try {
        fs.unlinkSync(item.path);
      } catch (error) {
        Lg.w('[WEB] drop converted file failed: ' + item.path + ' '
          + (error instanceof Error ? error.message : JSON.stringify(error)));
      }
    }
  }

  async start(): Promise<void> {
    if (this.startOperation !== undefined) {
      await this.startOperation;
    }
    if (this.started) {
      return;
    }
    this.started = true;
    const generation: number = ++this.generation;
    const operation: Promise<void> = this.startOwned(generation);
    this.startOperation = operation;
    try {
      await operation;
    } finally {
      if (this.startOperation === operation) {
        this.startOperation = undefined;
      }
    }
  }

  private isCurrent(generation: number): boolean {
    return this.started && generation === this.generation;
  }

  private async startOwned(generation: number): Promise<void> {
    await this.closeOperation;
    if (!this.isCurrent(generation)) {
      return;
    }
    try {
      LocalSendServer.actualPort = 0;
      LocalSendServer.actualWebPort = 0;
      // 若开启加密，优先提供原生 mbedTLS HTTPS（避免 @ohos.net.socket TLSSocket 的 memcpy_s bug）。
      if ((SettingsStore.current().encryptionEnabled ?? true) && await this.tryStartTls(generation)) {
        Lg.i(`羊绒互传 LocalSend server listening on ${PORT} (https)`);
      } else {
        if (!this.isCurrent(generation)) {
          return;
        }
        await this.startPlain(generation);
        Lg.i(`羊绒互传 LocalSend server listening on ${PORT} (http)`);
      }
      if (!this.isCurrent(generation)) {
        return;
      }
      LocalSendServer.actualPort = PORT;
      // 网页端「局域网网页传输」始终以明文 HTTP 单独提供（即使主端口走 HTTPS），
      // 让对端浏览器无需处理自签证书。端口必须与 Quick Share 接收端口（53318）区分开
      // （见 WEB_PORT 注释）；首选端口被占用时 startWebListener 内部会依次回退，
      // 全部失败也只影响网页端，不阻塞主服务。
      try {
        await this.startWebListener(generation);
      } catch (error) {
        Lg.w('羊绒互传 LocalSend web listener start failed: ' + JSON.stringify(error));
      }
      if (this.isCurrent(generation)) {
        this.startSweep();
      }
    } catch (error) {
      if (!this.isCurrent(generation)) {
        return;
      }
      this.started = false;
      this.httpsActiveValue = false;
      LocalSendServer.lastHttpsActive = false;
      LocalSendServer.actualPort = 0;
      LocalSendServer.actualWebPort = 0;
      Lg.e(`羊绒互传 LocalSend server start failed: ${JSON.stringify(error)}`);
      throw error as Error;
    }
  }

  /** 原生 mbedTLS 服务端：socket 由 native 用 POSIX listen/accept 创建(可用)，每连接把 fd 交给
   *  native 做 TLS 握手。native 独占 fd，避免 @ohos.net.socket 事件循环与 mbedTLS 争抢。失败返回 false 走明文。 */
  private async tryStartTls(generation: number): Promise<boolean> {
    try {
      const material = await this.certs.ensure();
      if (material === undefined) {
        return false;
      }
      const certPem = await fs.readText(material.certPath);
      const keyPem = await fs.readText(material.keyPath);
      if (!this.isCurrent(generation)) {
        return false;
      }
      const listenHandle = tlsNative.listen(PORT, { certPem: certPem, keyPem: keyPem },
        (fd: number, peerIp: string): void => {
          const conn: TlsServerConnection = new TlsServerConnection(fd, certPem, keyPem, peerIp);
          if (this.isCurrent(generation)) {
            this.handleConnection(conn);
          } else {
            conn.close();
          }
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
    this.generation += 1;
    this.started = false;
    this.httpsActiveValue = false;
    LocalSendServer.lastHttpsActive = false;
    LocalSendServer.actualPort = 0;
    LocalSendServer.actualWebPort = 0;
    this.stopSweep();
    if (this.listenHandle > 0) {
      tlsNative.stopListen(this.listenHandle);
      this.listenHandle = 0;
    }
    if (this.tcpServer !== undefined) {
      this.tcpServer.off('connect');
      const closing: Promise<void> = this.tcpServer.close().catch((): void => undefined);
      this.closeOperation = Promise.all([this.closeOperation, closing]).then((): void => undefined);
      this.tcpServer = undefined;
    }
    if (this.webTcpServer !== undefined) {
      this.webTcpServer.off('connect');
      const closing: Promise<void> = this.webTcpServer.close().catch((): void => undefined);
      this.closeOperation = Promise.all([this.closeOperation, closing]).then((): void => undefined);
      this.webTcpServer = undefined;
    }
    if (this.sessions.size > 0) {
      Lg.w('羊绒互传 LocalSend stopping with ' + this.sessions.size + ' sessions in flight');
      for (const id of Array.from(this.sessions.keys())) {
        this.failSession(id, '接收服务已停止');
      }
    }
    // 先把改写产物连同共享一起释放（伴侣共享也在 shares 里），再清空共享表。
    const sharedIds: string[] = [];
    this.shares.forEach((s: ShareState, id: string): void => {
      sharedIds.push(id);
    });
    for (const id of sharedIds) {
      this.releaseWebConverted(id);
    }
    this.shares.clear();
    this.webConverted.clear();
  }

  private async startPlain(generation: number): Promise<void> {
    const server = socket.constructTCPSocketServerInstance();
    this.tcpServer = server;
    server.on('connect', (conn: socket.TCPSocketConnection): void => {
      if (this.isCurrent(generation)) {
        this.handleConnection(new TcpServerConnection(conn));
      } else {
        conn.close().catch((): void => undefined);
      }
    });
    await server.listen({ address: '0.0.0.0', family: 1, port: PORT });
    if (!this.isCurrent(generation)) {
      await server.close().catch((): void => undefined);
    }
  }

  /** 网页端「局域网网页传输」：在独立端口用明文 HTTP 监听，同一套会话/落盘管线复用，
   *  但浏览器始终通过 http:// 访问，不涉及自签证书。
   *  首选端口被别的进程占用时按 WEB_PORT_CANDIDATES 依次回退，成功即把实际端口写回
   *  actualWebPort（UI 上的访问地址由它生成）；全部失败则置 0 并明确报错。 */
  private async startWebListener(generation: number): Promise<void> {
    for (let i = 0; i < WEB_PORT_CANDIDATES.length; i++) {
      if (!this.isCurrent(generation)) {
        return;
      }
      const candidate: number = WEB_PORT_CANDIDATES[i];
      const server = socket.constructTCPSocketServerInstance();
      server.on('connect', (conn: socket.TCPSocketConnection): void => {
        if (this.isCurrent(generation)) {
          this.handleConnection(new TcpServerConnection(conn));
        } else {
          conn.close().catch((): void => undefined);
        }
      });
      try {
        await server.listen({ address: '0.0.0.0', family: 1, port: candidate });
        if (!this.isCurrent(generation)) {
          await server.close().catch((): void => undefined);
          return;
        }
        this.webTcpServer = server;
        LocalSendServer.actualWebPort = candidate;
        if (candidate === WEB_PORT) {
          Lg.i(`羊绒互传 LocalSend web page listening on ${candidate} (http)`);
        } else {
          Lg.w('羊绒互传 LocalSend web page 首选端口 ' + WEB_PORT + ' 被占用，已回退到 ' + candidate + ' (http)');
        }
        return;
      } catch (error) {
        server.off('connect');
        server.close().catch((): void => undefined);
        Lg.w('羊绒互传 LocalSend web page listen failed on ' + candidate + ': ' + JSON.stringify(error));
      }
    }
    LocalSendServer.actualWebPort = 0;
    Lg.e('羊绒互传 局域网网页传输监听失败：端口 ' + WEB_PORT_CANDIDATES.join('/')
      + ' 全部被占用，网页端将无法访问（Quick Share 接收不受影响，其 53318 未被动用）');
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
        this.failSession(id, '接收会话已超时');
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

  private failSession(id: string, reason: string): void {
    const session: SessionState | undefined = this.sessions.get(id);
    if (session === undefined || session.failed === true) {
      return;
    }
    session.failed = true;
    this.sessions.delete(id);
    this.handler?.onSessionFailed?.(id, reason);
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
    const settle = (respond: boolean, status: number, body: string, framed: boolean = true): void => {
      if (stream === undefined || handled) {
        return;
      }
      handled = true;
      clearTimers();
      const session = this.sessions.get(stream.sessionId);
      const incomplete = !framed || session === undefined || stream.received !== stream.total;
      if (session !== undefined) {
        try {
          // 只记录长度，不打印文件内容（避免泄露接收到的文件字节）。
          Lg.i('LocalSend file check: declared=' + stream.total + ' wrote=' + stream.received);
        } catch (readError) {
          Lg.w('LocalSend file check failed: ' + JSON.stringify(readError));
        }
        session.activeFiles.delete(stream.fileId);
        if (!incomplete) {
          session.receivedFiles.add(stream.fileId);
          Lg.i('羊绒互传 LocalSend upload streamed complete: ' + stream.sessionId + ' ' + stream.received + ' bytes -> ' + stream.path);
        }
      }
      this.closeStream(stream);
      if (incomplete) {
        LocalSendServer.removePartial(stream.path);
        this.failSession(stream.sessionId, '文件接收不完整：' + stream.received + '/' + stream.total + ' 字节');
      }
      if (respond) {
        conn.sendBytes(LocalSendServer.encodeResponse(incomplete ? 400 : status,
          incomplete ? '{"status":"incomplete-upload"}' : body)).then(() => {
          conn.close();
        }).catch(() => {
          conn.close();
        });
      } else {
        conn.close();
      }
      if (session !== undefined) {
        if (!incomplete) {
          this.reportReceived(stream, session, session.files.size === 1).catch((error: Error): void => {
            this.failSession(stream?.sessionId ?? '', '保存接收文件失败：' + error.message);
          });
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
        if (!handled) {
          if (stream !== undefined) {
            Lg.w('羊绒互传 LocalSend upload idle, settling partial stream');
            settle(false, 0, '', mode === 'raw' && (contentLength === 0 || stream.received === contentLength));
          } else {
            respondAndClose(408, '{"status":"request-timeout"}');
          }
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
      try {
      if (handled) {
        return;
      }
      armIdle();
      if (!headParsed) {
        buffer = ByteUtils.concat([buffer, chunk]);
        const headerEnd = ByteUtils.indexOf(buffer, CRLF_CRLF, 0);
        if (headerEnd < 0) {
          if (buffer.length > MAX_HEAD_BYTES) {
            respondAndClose(431, '{"status":"head-too-large"}');
          }
          return;
        }
        if (headerEnd > MAX_HEAD_BYTES) {
          respondAndClose(431, '{"status":"head-too-large"}');
          return;
        }
        headText = ByteUtils.decodeText(buffer.slice(0, headerEnd));
        bodyStart = headerEnd + 4;
        contentLength = LocalSendServer.readContentLength(headText);
        if (contentLength < 0) {
          respondAndClose(400, '{"status":"invalid-content-length"}');
          return;
        }
        const head = LocalSendServer.parseRequest(headText, new Uint8Array(0));
        transferEncoding = (head.headers.get('transfer-encoding') ?? '').toLowerCase();
        claimsChunked = transferEncoding.indexOf('chunked') >= 0;
        const contentType: string = head.headers.get('content-type') ?? '';
        headQuery = head.query;
        const isUpload = LocalSendServer.isUploadPath(head.path);
        if (isUpload && head.method !== 'POST') {
          respondAndClose(405, '{"status":"method-not-allowed"}');
          return;
        }
        const expectContinue = (head.headers.get('expect') ?? '').toLowerCase() === '100-continue';
        Lg.i('LocalSend http head: ' + head.method + ' ' + head.path + ' cl=' + contentLength + ' te=' + (transferEncoding.length > 0 ? transferEncoding : '-') + ' ct=' + (contentType.length > 0 ? contentType : '-'));
        if (expectContinue) {
          conn.sendBytes(LocalSendServer.encodeContinue()).catch((): void => undefined);
        }
        if (claimsChunked) {
          if (!isUpload) {
            Lg.w('LocalSend chunked body on non-upload path rejected: ' + head.path);
            respondAndClose(415, '{"status":"unsupported-media-type"}');
            return;
          }
          mode = 'sniff';
        } else if (isUpload) {
          if (contentType.toLowerCase().indexOf('multipart/form-data') >= 0) {
            const boundaryText = LocalSendServer.readBoundary(contentType);
            if (boundaryText.length === 0) {
              Lg.w('LocalSend multipart upload missing boundary, rejected');
              respondAndClose(400, '{"status":"bad-request"}');
              return;
            }
            mpDelimBytes = ByteUtils.encodeText('--' + boundaryText);
            mpScanPos = bodyStart;
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
            if (opened === 'duplicate') {
              respondAndClose(409, '{"status":"duplicate-upload"}');
              return;
            }
            if (opened === 'error') {
              respondAndClose(500, '{"status":"error"}');
              return;
            }
            stream = opened;
            if (head.headers.has('content-length') && contentLength !== stream.total) {
              settle(true, 400, '', false);
              return;
            }
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
          settle(false, 0, '', false);
          return;
        }
        this.touchSession(stream.sessionId);
        this.writeRawData(session, stream, chunk);
        if (contentLength > 0 && stream.received >= contentLength) {
          settle(true, 200, '{"status":"ok"}');
          return;
        }
        if (contentLength === 0 && stream.received >= stream.total) {
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
        if (opened === 'duplicate') {
          respondAndClose(409, '{"status":"duplicate-upload"}');
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
        const parsed = this.consumeChunked(buffer, stream, session);
        if (parsed === 1) {
          settle(true, 200, '{"status":"ok"}');
          return;
        }
        if (parsed === -1) {
          settle(true, 400, '', false);
          return;
        }
        if (stream.pos > 0) {
          buffer = buffer.slice(stream.pos);
          stream.pos = 0;
        }
        return;
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
          if (opened === 'duplicate') {
            respondAndClose(409, '{"status":"duplicate-upload"}');
            return;
          }
          if (opened === 'error') {
            respondAndClose(500, '{"status":"error"}');
            return;
          }
          stream = opened;
          stream.pos = result.fileDataStart;
          stream.mpDelim = ByteUtils.concat([CRLF, mpDelimBytes]);
          Lg.i('LocalSend multipart upload started: ' + stream.sessionId + ' ' + stream.name + ' -> ' + stream.path);
        }
        const sessionForStream = this.sessions.get(stream.sessionId);
        if (sessionForStream === undefined) {
          settle(false, 0, '', false);
          return;
        }
        this.touchSession(stream.sessionId);
        const parsed = this.consumeMultipart(buffer, stream, sessionForStream);
        if (parsed === 1) {
          settle(true, 200, '{"status":"ok"}');
          return;
        }
        if (parsed === -1) {
          settle(true, 400, '', false);
          return;
        }
        if (stream.pos >= 1024 * 1024) {
          buffer = buffer.slice(stream.pos);
          stream.pos = 0;
          bodyStart = 0;
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
      } catch (error) {
        Lg.e('LocalSend receive I/O failed: ' + JSON.stringify(error));
        if (stream !== undefined) {
          this.releaseStream(stream);
        }
        respondAndClose(500, '{"status":"write-failed"}');
      }
    });
    conn.onClose((): void => {
      clearTimers();
      if (!handled && stream !== undefined) {
        Lg.i('羊绒互传 LocalSend upload connection closed, settling stream (mode=' + mode + ' received=' + stream.received + ')');
        settle(false, 0, '', mode === 'raw' && (contentLength === 0 || stream.received === contentLength));
      }
    });
    armIdle();
  }

  private releaseStream(state: StreamState): void {
    const session = this.sessions.get(state.sessionId);
    if (session !== undefined) {
      session.activeFiles.delete(state.fileId);
      this.failSession(state.sessionId, '接收文件流失败');
    }
    this.closeStream(state);
    LocalSendServer.removePartial(state.path);
  }

  private static removePartial(path: string): void {
    try { fs.unlinkSync(path); }
    catch (error) { Lg.w('LocalSend partial cleanup failed: ' + JSON.stringify(error)); }
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
        // 先上报对端信号再应答：对端能 POST 到这里，说明它已经发现了本机（announce 生效）。
        await this.notifyPeerSignal(request, conn, 'register');
        await conn.sendBytes(LocalSendServer.encodeResponse(200, await this.infoJson()));
        return;
      }
      if (path === '/api/localsend/v2/cancel' || path === '/api/localsend/v1/cancel') {
        const sessionId = request.query.get('sessionId') ?? '';
        this.failSession(sessionId, '对端已取消传输');
        Lg.i('羊绒互传 LocalSend cancel: session ' + sessionId);
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

  /**
   * 把 register / send-request 请求体里的对端身份连同来源 IP 上报给发现链路。
   *
   * 真机日志（2026-09-20，热点模式）：对端收到本机 announce 后 400ms 内就发来 /register，
   * 说明「对端能发现本机」这条路是通的 —— 此前这个信号只回了个 200 就扔掉了，
   * 本机设备列表毫无感知。体解析失败/字段缺失时仍然上报（至少有 IP 供子网探测兜底）。
   */
  private async notifyPeerSignal(request: ParsedRequest, conn: ServerConnection, via: string): Promise<void> {
    if (LocalSendServer.onPeerSignal === undefined) {
      return;
    }
    try {
      const peerIp = await conn.peerAddress();
      if (peerIp.length === 0) {
        return;
      }
      let alias = '';
      let deviceModel = '';
      let fingerprint = '';
      let port = 0;
      let protocol = '';
      try {
        const json = JSON.parse(ByteUtils.decodeText(request.body)) as PeerInfoJson;
        alias = json.alias ?? '';
        deviceModel = json.deviceModel ?? '';
        fingerprint = json.fingerprint ?? '';
        port = json.port ?? 0;
        protocol = json.protocol ?? '';
      } catch (error) {
        // 非 JSON 体：仅凭来源 IP 上报。
      }
      if (alias.length === 0 && fingerprint.length === 0) {
        return; // 连个身份都没有，多半不是 LocalSend 对端。
      }
      if (port <= 0 || port > 65535) {
        port = LocalSendServer.actualPort;
      }
      Lg.i('羊绒互传 LocalSend peer signal via ' + via + ' from ' + peerIp + ':' + port
        + ' alias=' + alias + ' model=' + deviceModel);
      LocalSendServer.onPeerSignal({
        address: peerIp,
        alias: alias.length > 0 ? alias : peerIp,
        deviceModel: deviceModel.length > 0 ? deviceModel : 'LocalSend device',
        fingerprint: fingerprint,
        port: port,
        protocol: protocol
      });
    } catch (error) {
      Lg.w('羊绒互传 LocalSend peer signal failed: ' + JSON.stringify(error));
    }
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
    const registered = this.shares.get(id);
    if (registered === undefined) {
      Lg.w('羊绒互传 web download 404: id=' + id);
      await conn.sendBytes(LocalSendServer.encodeResponse(404, '{"status":"not-found"}'));
      return;
    }
    // 网页端没有 LocalSend 发现信息，只有请求头里的 User-Agent —— 用它识别对端设备，
    // 再决定发哪种动态照片/HDR 形态（不然 OPPO 浏览器下到的是鸿蒙形态的文件，相册不认）。
    const share = await this.shareForBrowser(registered, id, request.headers.get('user-agent') ?? '');
    let fd = -1;
    // 提到 try 外面：失败日志要带上「已经发出去多少字节」——真机踩过「浏览器第一次请求中断，
    // 用户打开的是半截文件」，而半截文件正好会「既没有 HDR 又没有动图」（增益图与视频都在尾部）。
    let sent = 0;
    let total = share.size;
    try {
      fd = fs.openSync(share.path, fs.OpenMode.READ_ONLY).fd;
      // 以**打开的 fd 的真实大小**为准：登记大小取自选择器返回 URI 的 stat，可能与实际可读字节数
      // 不一致（实测：HEIC 登记 1 832 802，实际可读 1 835 008+；28 MB 的文件只读到 2.5 MB）。
      // 按登记大小写 Content-Length 会让浏览器一直等剩下的字节 → 下载失败/连接重置（真实 bug）。
      total = share.size;
      try {
        const stat = fs.statSync(fd);
        if (stat.size > 0) {
          total = stat.size;
        }
      } catch (statError) {
        Lg.w('web download fstat failed, fall back to registered size: '
          + (statError instanceof Error ? statError.message : JSON.stringify(statError)));
      }
      if (total !== share.size) {
        Lg.w('web download size mismatch: registered=' + share.size + ' actual=' + total
          + ' name=' + share.name);
      }
      const safeName = share.name.replace(/["\\\r\n]/g, '_');
      // 用已打开文件的长度检查完整性。中途读不到剩余数据时不发送结束块，
      // 让浏览器把这次下载视为中断。
      const head = 'HTTP/1.1 200 OK\r\n' +
        'Content-Type: application/octet-stream\r\n' +
        'Content-Disposition: attachment; filename="' + safeName + '"\r\n' +
        'Transfer-Encoding: chunked\r\n' +
        'Connection: close\r\n\r\n';
      await conn.sendBytes(ByteUtils.encodeText(head));
      const chunkSize = 256 * 1024;
      const buf = new ArrayBuffer(chunkSize);
      while (sent < total) {
        const take = Math.min(chunkSize, total - sent);
        // 显式给 offset/length：不依赖 fd 的隐式游标，也就不会出现「多读一块撑破 Content-Length」。
        const n = fs.readSync(fd, buf, { offset: sent, length: take });
        if (n <= 0) {
          break;
        }
        await conn.sendBytes(ByteUtils.encodeText(n.toString(16) + '\r\n'));
        await conn.sendBytes(new Uint8Array(buf.slice(0, n)));
        await conn.sendBytes(ByteUtils.encodeText('\r\n'));
        sent += n;
      }
      if (sent !== total) {
        throw new Error('共享文件未完整读取：' + sent + '/' + total);
      }
      await conn.sendBytes(ByteUtils.encodeText('0\r\n\r\n'));
      Lg.i('羊绒互传 web download complete: ' + id + ' sent=' + sent + '/' + total
        + ' name=' + share.name);
    } catch (error) {
      // 带上已发送字节数：真机踩过「浏览器第一次请求中断（Broken pipe），用户打开的是半截文件」，
      // 而日志里只有一句失败，看不出到底传了多少 —— 半截文件正好会「既没有 HDR 又没有动图」
      // （增益图与视频都在文件尾部）。
      Lg.w('羊绒互传 web download failed: ' + JSON.stringify(error)
        + ' sent=' + sent + '/' + total + ' name=' + share.name);
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

  /**
   * 按**浏览器 UA** 识别对端设备，把共享文件改写成它认的动态照片/HDR 形态。
   *
   * 背景：网页端（浏览器）不走 LocalSend 发现，拿不到设备名/型号，唯一的线索就是请求头里的
   * `User-Agent`。而动态图片各家格式不通用 —— 直接把鸿蒙形态的图片给 OPPO 浏览器，对方相册
   * 既不认动态照片也不认 HDR。这里复用发送侧同一条改写链路
   * （`DynamicPhotoService.prepareOutgoing` + `HdrPhotoService`），决策来源换成 UA。
   *
   * 行为约定（宁可不改，也不要猜错）：
   *  - UA 判为桌面/鸿蒙/认不出 → **原样发文件**（`format === 'split'`）；
   *  - UA 判为某家 Android → 单文件动态照片 + 该家私有方言；判为 iOS/macOS → 实况照片那对
   *    （JPEG 为主文件、MOV 登记成伴侣共享，页面列表刷新后即可下载）；
   *  - 文件本身不是动态照片时 `prepareOutgoing` 原样返回 → 也走原样发；
   *  - 结果按「共享 id + 格式 + 方言」缓存，同一个文件不重复转换。
   */
  private async shareForBrowser(share: ShareState, requestId: string, userAgent: string): Promise<ShareState> {
    const decision: PeerDecision = PeerLivePhotoFormat.resolveForUserAgent(userAgent);
    const trimmedUa = userAgent.length > 160 ? userAgent.substring(0, 160) + '…' : userAgent;
    Lg.i('[WEB] browser peer: platform=' + decision.platform + ' brand='
      + (decision.brand.length > 0 ? decision.brand : '-') + ' target=' + decision.format
      + (decision.format === 'android' ? ' dialect=' + PeerLivePhotoFormat.dialectLabel(decision.dialect) : '')
      + ' reason=' + decision.reason + ' ua=' + (trimmedUa.length > 0 ? trimmedUa : '-'));
    if (decision.format === 'split') {
      return share; // 桌面/鸿蒙/认不出：原样给字节
    }
    const key = requestId + '|' + decision.format + '|' + decision.dialect;
    const cached = this.webConverted.get(key);
    if (cached !== undefined) {
      return { id: share.id, path: cached.path, name: cached.name, size: cached.size,
        addedAt: share.addedAt, expiresAt: share.expiresAt };
    }
    try {
      const source: OutgoingFile = {
        path: share.path, name: share.name, size: share.size,
        mime: LocalSendServer.mimeOfName(share.name)
      };
      const expanded = await DynamicPhotoService.prepareOutgoing(this.context, [source], decision);
      if (expanded.length === 0 || expanded[0].path === share.path) {
        // 不是动态图片（或开关关着、转换失败退回原文件）：原样发，并记一行便于排查。
        Lg.i('[WEB] browser rewrite not applied (not a dynamic photo or conversion off): ' + share.name);
        return share;
      }
      const primary = expanded[0];
      let companionId = '';
      if (expanded.length > 1) {
        // 两个文件的形态（Apple 实况照片的 JPEG + MOV）：主文件按本次请求发，
        // 伴侣登记成新的共享项，页面 8 秒自动刷新后会出现在列表里。
        const extra = expanded[1];
        companionId = this.addShare(extra.path, extra.name, extra.size);
        Lg.i('[WEB] browser rewrite companion share: ' + extra.name + ' -> ' + companionId);
      }
      this.webConverted.set(key, {
        path: primary.path, name: primary.name, size: primary.size, companionId: companionId
      });
      Lg.i('[WEB] browser rewrite: ' + share.name + ' -> ' + primary.name + ' '
        + primary.size + ' bytes (target=' + decision.format
        + (decision.format === 'android' ? ' dialect=' + decision.dialect : '') + ')');
      return { id: share.id, path: primary.path, name: primary.name, size: primary.size,
        addedAt: share.addedAt, expiresAt: share.expiresAt };
    } catch (error) {
      Lg.w('[WEB] browser rewrite failed, send original: '
        + (error instanceof Error ? error.message : JSON.stringify(error)));
      return share;
    }
  }

  /** 粗略 MIME：只用于 `prepareOutgoing` 的输入字段，改写器按文件头判类型，不依赖它。 */
  private static mimeOfName(name: string): string {
    const lower = name.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.heic') || lower.endsWith('.heif')) {
      return 'image/heic';
    }
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.mp4') || lower.endsWith('.mov')) {
      return 'video/mp4';
    }
    return 'application/octet-stream';
  }

  private async infoJson(): Promise<string> {
    const settings = SettingsStore.current();
    const fingerprint = await this.certs.discoveryFingerprint(this.httpsActive);
    return JSON.stringify({
      alias: settings.alias,
      version: '2.0',
      deviceModel: 'HarmonyOS NEXT',
      deviceType: 'mobile',
      fingerprint,
      port: LocalSendServer.actualPort,
      protocol: this.httpsActive ? 'https' : 'http',
      download: false
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
      // 能发 send-request 说明对端已经知道本机地址：顺手作为发现信号（与 /register 同管线）。
      await this.notifyPeerSignal(request, conn, 'send-request');
    } catch (error) {
      await conn.sendBytes(LocalSendServer.encodeResponse(400, '{"status":"bad-request"}'));
      return;
    }
    const files: Map<string, SessionFileMeta> = new Map();
    const metaList: SessionFileMeta[] = [];
    let totalBytes = 0;
    if (parsed !== null && parsed.files !== undefined && parsed.files !== null
      && typeof parsed.files === 'object' && !Array.isArray(parsed.files)) {
      const ids = Object.keys(parsed.files);
      for (const id of ids) {
        const info = parsed.files[id];
        if (id.length === 0 || info === null || typeof info !== 'object'
          || typeof info.fileName !== 'string' || info.fileName.trim().length === 0
          || !Number.isSafeInteger(info.size) || info.size < 0
          || !Number.isSafeInteger(totalBytes + info.size)) {
          await conn.sendBytes(LocalSendServer.encodeResponse(400, '{"status":"invalid-file-metadata"}'));
          return;
        }
        const meta: SessionFileMeta = { id, name: info.fileName, size: info.size,
          mime: typeof info.fileType === 'string' ? info.fileType : undefined };
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
      activeFiles: new Set<string>(),
      receivedFiles: new Set<string>(),
      savedFiles: new Set<string>(),
      expiresAt: Date.now() + SESSION_TTL_MS
    });
    const peerName = typeof parsed.info?.alias === 'string' && parsed.info.alias.length > 0
      ? parsed.info.alias : 'LocalSend peer';
    // 网页端（浏览器）只有 UA 能说明它是什么设备：识别出的品牌直接补在对端名后面，
    // 本机确认弹窗里就能看到「Android 浏览器 · OPPO」而不是干巴巴一个「Android 浏览器」。
    // 原生 LocalSend 客户端没有浏览器 UA（okhttp/dart 之类）→ 识别为空 → 名字保持不变。
    const uaDecision: PeerDecision = PeerLivePhotoFormat.resolveForUserAgent(request.headers.get('user-agent') ?? '');
    const peerLabel = uaDecision.brand.length > 0 && peerName.indexOf(uaDecision.brand) < 0
      ? peerName + ' · ' + uaDecision.brand : peerName;
    Lg.i('羊绒互传 LocalSend send-request: peer=' + peerLabel + ' files=' + metaList.length
      + ' totalBytes=' + totalBytes + (uaDecision.brand.length > 0 ? ' ua-brand=' + uaDecision.brand : ''));
    let accepted = true;
    if (this.handler !== undefined) {
      accepted = await this.handler.onSessionRequested({ sessionId, peerName: peerLabel, files: metaList, pin });
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
        }
      }
    }
    const stream = this.tryOpenUploadStream(sessionId, fileId, token);
    if (stream === 'unauthorized') {
      await conn.sendBytes(LocalSendServer.encodeResponse(401, '{"status":"unauthorized"}'));
      return;
    }
    if (stream === 'duplicate') {
      await conn.sendBytes(LocalSendServer.encodeResponse(409, '{"status":"duplicate-upload"}'));
      return;
    }
    if (stream === 'error') {
      await conn.sendBytes(LocalSendServer.encodeResponse(500, '{"status":"write-failed"}'));
      return;
    }
    const session = this.sessions.get(sessionId);
    if (session === undefined || fileData.length !== stream.total) {
      this.releaseStream(stream);
      await conn.sendBytes(LocalSendServer.encodeResponse(400, '{"status":"incomplete-upload"}'));
      return;
    }
    try {
      this.writeRawData(session, stream, fileData);
    } catch (error) {
      this.releaseStream(stream);
      await conn.sendBytes(LocalSendServer.encodeResponse(500, '{"status":"write-failed"}'));
      return;
    }
    this.closeStream(stream);
    session.activeFiles.delete(fileId);
    session.receivedFiles.add(fileId);
    try {
      await conn.sendBytes(LocalSendServer.encodeResponse(200, '{"status":"ok"}'));
    } finally {
      this.reportReceived(stream, session, session.files.size === 1)
        .catch((error: Error): void => this.failSession(sessionId, '保存接收文件失败：' + error.message));
    }
  }

  /**
   * 在「搬到下载目录」之前把沙箱副本交给上层（动态图片需要在这里把内容读完）。
   * 上层失败/超时都不影响接收主流程，只记日志。
   */
  private async stageIncoming(sessionId: string, file: IncomingFile): Promise<void> {
    if (this.handler === undefined) {
      return;
    }
    try {
      await this.handler.onFileStaged(sessionId, file);
    } catch (error) {
      Lg.w('LocalSend stage hook failed: ' + (error instanceof Error ? error.message : JSON.stringify(error)));
    }
  }

  private openIncomingStream(fileName: string): OpenStreamResult {
    const dir = `${this.context.filesDir}/incoming`;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    const sanitized = GalleryMediaClassifier.safeFileName(fileName);
    const dot = sanitized.lastIndexOf('.');
    const stem = dot > 0 ? sanitized.substring(0, dot) : sanitized;
    const ext = dot > 0 ? sanitized.substring(dot) : '';
    for (let index = 0; index < 10000; index++) {
      const target = dir + '/' + stem + (index === 0 ? '' : ' (' + index + ')') + ext;
      if (!fs.accessSync(target)) {
        return { file: fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE), path: target };
      }
    }
    throw new Error('无法分配不重名的接收文件');
  }

  private tryOpenUploadStream(sessionId: string, fileId: string, token: string): StreamState | 'unauthorized' | 'duplicate' | 'error' {
    const session = this.sessions.get(sessionId);
    if (session === undefined || session.token !== token) {
      Lg.w('LocalSend upload 401: session=' + (session === undefined ? 'missing' : 'token-mismatch') + ' id=' + sessionId);
      return 'unauthorized';
    }
    if (session.expiresAt <= Date.now()) {
      this.failSession(sessionId, '接收会话已超时');
      Lg.w('LocalSend upload rejected: session expired id=' + sessionId);
      return 'unauthorized';
    }
    const meta = session.files.get(fileId);
    if (meta === undefined) {
      return 'unauthorized';
    }
    if (session.activeFiles.has(fileId) || session.receivedFiles.has(fileId)) {
      return 'duplicate';
    }
    const name = meta.name;
    try {
      const opened = this.openIncomingStream(name);
      session.activeFiles.add(fileId);
      session.expiresAt = Date.now() + SESSION_TTL_MS;
      return {
        file: opened.file,
        path: opened.path,
        sessionId,
        fileId,
        name,
        mime: meta.mime,
        lastPct: -1,
        pos: 0,
        total: meta !== undefined ? meta.size : 0,
        received: 0,
        chunkSize: 0,
        chunkPhase: 0
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
    if (data.length > stream.total - stream.received) { throw new Error('接收数据超过声明大小'); }
    const written: number = fs.writeSync(stream.file.fd, ByteUtils.toArrayBuffer(data));
    if (written !== data.length) {
      throw new Error('接收文件写入不完整');
    }
    stream.received += data.length;
    session.receivedBytes += data.length;
    session.expiresAt = Date.now() + SESSION_TTL_MS;
    const total = session.totalBytes;
    const capped = total > 0 ? Math.min(session.receivedBytes / total * 100, 100) : 100;
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
    await this.reportSaved(stream, session, allowPrompt);
  }

  private async reportSaved(stream: StreamState, session: SessionState, allowPrompt: boolean): Promise<void> {
    if (session.failed) { return; }
    const sessionId = stream.sessionId;
    const name = stream.name;
    const path = stream.path;
    const size = stream.received;
    // 先让上层读沙箱副本（动态图片解析），再搬到下载目录 —— 搬运会删除沙箱源文件。
    await this.stageIncoming(sessionId, { name, size, savedPath: path, mime: stream.mime });
    const finalPath = await this.relocateIncoming(path, allowPrompt, name);
    if (session.failed) {
      return;
    }
    session.savedFiles.add(stream.fileId);
    if (this.handler !== undefined) {
      this.handler.onFileReceived(sessionId,
        { name, size, savedPath: finalPath, localPath: path, mime: stream.mime });
      this.handler.onProgress(sessionId,
        session.savedFiles.size === session.files.size ? 100 :
          Math.min(99.9, session.totalBytes > 0 ? session.receivedBytes / session.totalBytes * 100
            : session.savedFiles.size / session.files.size * 100));
    }
    if (session.savedFiles.size === session.files.size) {
      this.sessions.delete(sessionId);
    }
  }

  private async relocateIncoming(srcPath: string, allowPrompt: boolean, preferredName: string = ''): Promise<string> {
    Lg.i('LocalSend receive relocate: src=' + srcPath + ' allowPrompt=' + allowPrompt);
    const slash = srcPath.lastIndexOf('/');
    const name = GalleryMediaClassifier.safeFileName(
      preferredName.length > 0 ? preferredName : (slash >= 0 ? srcPath.substring(slash + 1) : srcPath));
    const galleryUri: string = GalleryAutoSaveService.galleryUriForSourcePath(srcPath);
    if (galleryUri.length > 0) {
      LocalSendServer.removePartial(srcPath);
      Lg.i('LocalSend receive relocate: already in gallery, return asset uri: ' + galleryUri);
      return galleryUri;
    }
    // 设置「动态图片/HDR图片不保存至下载文件夹」：已经处理成相册动态照片的文件不再放副本，
    // 直接留在沙箱（相册里已经是移动照片，下载目录再存一份原始文件属重复）。
    if (!DynamicPhotoService.shouldKeepDownloadCopy(srcPath)) {
      Lg.i('LocalSend receive relocate: skipped by setting (kept in sandbox): ' + name);
      return srcPath;
    }
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
    throw new Error('无法分配不重名的下载文件');
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
    const dest = this.uniqueDestination(folder, name);
    Lg.i('LocalSend receive relocate: silent dest=' + dest);
    let srcFd = -1;
    let dstFd = -1;
    let created = false;
    try {
      srcFd = fs.openSync(srcPath, fs.OpenMode.READ_ONLY).fd;
      dstFd = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE).fd;
      created = true;
      LocalSendServer.copyVerified(srcFd, dstFd);
      fs.closeSync(srcFd);
      srcFd = -1;
      fs.closeSync(dstFd);
      dstFd = -1;
      LocalSendServer.removePartial(srcPath);
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
      if (created) { LocalSendServer.removePartial(dest); }
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
      LocalSendServer.copyVerified(srcFd, dstFd);
      fs.closeSync(srcFd);
      srcFd = -1;
      fs.closeSync(dstFd);
      dstFd = -1;
      LocalSendServer.removePartial(srcPath);
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
  private static copyVerified(source: number, target: number): void {
    const expected = fs.statSync(source).size;
    const buffer = new ArrayBuffer(1024 * 1024);
    let copied = 0;
    while (copied < expected) {
      const count = fs.readSync(source, buffer, { length: Math.min(buffer.byteLength, expected - copied) });
      if (count <= 0) { throw new Error('源文件未完整读取'); }
      let written = 0;
      while (written < count) {
        const delta = fs.writeSync(target, buffer.slice(written, count));
        if (delta <= 0 || delta > count - written) { throw new Error('目标文件未完整写入'); }
        written += delta;
      }
      copied += count;
    }
    if (fs.statSync(target).size !== expected) { throw new Error('目标文件长度与源文件不符'); }
  }

  private closeStream(state: StreamState): void {
    try {
      fs.closeSync(state.file);
    } catch (error) {
      Lg.w('LocalSend stream close failed: ' + JSON.stringify(error));
    }
  }

  private consumeChunked(buffer: Uint8Array, state: StreamState, session: SessionState): number {
    while (true) {
      if (state.chunkPhase === 0) { // size line
        const end = ByteUtils.indexOf(buffer, CRLF, state.pos);
        if (end < 0) { return buffer.length - state.pos > 1024 ? -1 : 0; }
        if (end - state.pos > 1024) { return -1; }
        const sizeText = ByteUtils.decodeText(buffer.slice(state.pos, end)).split(';')[0];
        if (!/^[0-9a-fA-F]+$/.test(sizeText)) { return -1; }
        const size = parseInt(sizeText, 16);
        if (!Number.isSafeInteger(size) || size > state.total - state.received) { return -1; }
        state.pos = end + 2;
        state.chunkSize = size;
        state.chunkPhase = size > 0 ? 1 : 3;
      }
      if (state.chunkPhase === 1) { // body bytes, possibly spread over many packets
        const count = Math.min(state.chunkSize, buffer.length - state.pos);
        if (count <= 0) { return 0; }
        this.writeRawData(session, state, buffer.slice(state.pos, state.pos + count));
        state.pos += count;
        state.chunkSize -= count;
        if (state.chunkSize > 0) { return 0; }
        state.chunkPhase = 2;
      }
      if (state.chunkPhase === 2) { // CRLF after nonempty data
        if (buffer.length - state.pos < 2) { return 0; }
        if (buffer[state.pos] !== 13 || buffer[state.pos + 1] !== 10) { return -1; }
        state.pos += 2;
        state.chunkPhase = 0;
      } else if (state.chunkPhase === 3) { // trailer section; empty line always terminates it
        if (buffer.length - state.pos < 2) { return 0; }
        if (buffer[state.pos] === 13 && buffer[state.pos + 1] === 10) { return 1; }
        const end = ByteUtils.indexOf(buffer, CRLF_CRLF, state.pos);
        if (end < 0) { return buffer.length - state.pos > MAX_HEAD_BYTES ? -1 : 0; }
        return end - state.pos > MAX_HEAD_BYTES ? -1 : 1;
      }
    }
  }

  private consumeMultipart(buffer: Uint8Array, state: StreamState, session: SessionState): number {
    const delim = state.mpDelim;
    if (delim === undefined) { return -1; }
    // Each upload token authorizes exactly one file of a known size. Boundary-like
    // bytes inside it are data. Only look for the form delimiter after that size.
    const count = Math.min(state.total - state.received, buffer.length - state.pos);
    if (count > 0) {
      this.writeRawData(session, state, buffer.slice(state.pos, state.pos + count));
      state.pos += count;
    }
    if (state.received !== state.total || buffer.length - state.pos < delim.length + 2) { return 0; }
    for (let i = 0; i < delim.length; i++) {
      if (buffer[state.pos + i] !== delim[i]) { return -1; }
    }
    const after = state.pos + delim.length;
    if (buffer[after] === 45 && buffer[after + 1] === 45) { return 1; }
    if (buffer[after] !== 13 || buffer[after + 1] !== 10) { return -1; }
    // Older clients may append non-file form fields. Wait for the closing delimiter
    // with a bounded buffer; never append the fields to the file.
    const close = ByteUtils.concat([delim, new Uint8Array([45, 45])]);
    if (ByteUtils.indexOf(buffer, close, after) >= 0) { return 1; }
    return buffer.length - after > MAX_MP_SCAN_BYTES ? -1 : 0;
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
    let length = -1;
    for (const line of headText.split('\r\n')) {
      if (line.toLowerCase().startsWith('content-length:')) {
        const raw = line.substring(15).trim();
        const value = Number(raw);
        if (!/^[0-9]+$/.test(raw) || !Number.isSafeInteger(value) ||
          (length >= 0 && length !== value)) { return -1; }
        length = value;
      }
    }
    return Math.max(0, length);
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
