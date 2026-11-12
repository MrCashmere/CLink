import { LogCapture as Lg } from '../common/LogCapture';
import { socket } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { CertificateStore } from '../common/CertificateStore';
import { ByteTransport, Transports } from '../common/TlsTransport';
import { ByteUtils } from '../common/ByteUtils';
import { HttpBodyParser } from '../common/HttpBodyParser';
import { DeviceEndpoint } from '../model/TransferModels';

const PORT = 53317;
// 两个超时区分开：LAN 上服务器毫秒级 accept，拒绝也是毫秒级；
// 只有“丢包/防火墙 drop”的主机才会挂到 connect 超时。connect 超时设小可让
// 整个 /24 扫描几秒内完成，而不是拖着几十秒。读超时略大，给首包留时间。
// 注意：@ohos.net.socket 的异步 connect 在其“主线程完成回调(OnTcpConnectComplete)”
// 与后台 ConnectMonitor 线程之间存在一个已知的释放竞争——若我们在 connect 仍被框架
// 完结时就把大量 socket 同时 close，两个线程会去 free 同一个连接上下文，触发
// “may double free” SIGTRAP（见 docs/LOCALSEND_TLS.md run-12）。因此这里刻意
// 压低并发、拉长 connect 超时，让扫描进程更慢但更稳，避免同刻产生过多
// “还在完结中就被 close”的 connect。
const CONNECT_TIMEOUT_MS = 1500;
const READ_TIMEOUT_MS = 2500;
const INFO_PATHS: string[] = ['/api/localsend/v2/info', '/api/localsend/v1/info', '/api/info'];
const CONCURRENCY = 4;

type DeviceEmitter = (device: DeviceEndpoint) => void;
type AddressChecker = (address: string) => boolean;

interface LocalSendPeerInfo {
  alias?: string;
  deviceModel?: string;
  fingerprint?: string;
  protocol?: string;
  port?: number;
}

interface InfoProbeResult {
  readonly raw: string;
  readonly connected: boolean;
}

export class LocalSendSubnetScanner {
  private readonly emit: DeviceEmitter;
  private readonly isOwn: AddressChecker;
  private running = false;
  private generation = 0;
  private readonly cancellations: Set<() => void> = new Set();
  private readonly certs: CertificateStore;
  private foundCount = 0;

  constructor(emit: DeviceEmitter, isOwn: AddressChecker, context: common.Context) {
    this.certs = new CertificateStore(context);
    this.emit = emit;
    this.isOwn = isOwn;
  }

  async scan(localAddress: string): Promise<void> {
    if (this.running || localAddress.indexOf('.') < 0) {
      return;
    }
    const parts = localAddress.split('.');
    if (parts.length !== 4) {
      return;
    }
    const generation = this.generation;
    this.running = true;
    this.foundCount = 0;
    try {
      let next = 1;
      const worker = async (): Promise<void> => {
        while (next <= 254 && generation === this.generation) {
          const host = parts[0] + '.' + parts[1] + '.' + parts[2] + '.' + next;
          next += 1;
          if (!this.isOwn(host)) {
            await this.probe(host, generation);
          }
        }
      };
      const workers: Promise<void>[] = [];
      for (let i = 0; i < CONCURRENCY; i++) {
        workers.push(worker());
      }
      await Promise.all(workers);
      Lg.i('LocalSend subnet scan complete for ' + localAddress + ' (found=' + this.foundCount + ')');
    } finally {
      this.running = false;
    }
  }

  stop(): void {
    this.generation += 1;
    this.cancellations.forEach((cancel: () => void): void => cancel());
    this.cancellations.clear();
  }

  /** 自检必须采用本机实际监听的协议，否则 HTTPS 会被误报为未启动。 */
  async probeSelf(host: string, secure: boolean = false): Promise<boolean> {
    const result = await this.requestInfo(host, INFO_PATHS[0], secure);
    return result.raw.startsWith('HTTP/1.1 200 ') || result.raw.startsWith('HTTP/1.0 200 ');
  }

  /** 托底连接：容忍 EINPROGRESS，用 connect 事件 + getState().isConnected 判定真实连接。 */
  private static connectChecked(tcp: socket.TCPSocket, host: string, port: number): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      let done = false;
      let timer = -1;
      const finish = (ok: boolean): void => {
        if (done) {
          return;
        }
        done = true;
        if (timer !== -1) {
          clearTimeout(timer);
        }
        resolve(ok);
      };
      tcp.on('connect', (): void => finish(true));
      tcp.on('close', (): void => finish(false));
      tcp.on('error', (error: Object): void => {
        // EINPROGRESS(2301115) 不是硬失败，等待 connect 事件或 getState 再定论。
        if (LocalSendSubnetScanner.socketCode(error) !== 2301115) {
          finish(false);
        }
      });
      timer = setTimeout((): void => {
        tcp.getState().then((state: socket.SocketStateBase): void => {
          finish(state.isConnected);
        }).catch((): void => finish(false));
      }, CONNECT_TIMEOUT_MS);
      try {
        tcp.connect({ address: { address: host, family: 1, port }, timeout: CONNECT_TIMEOUT_MS })
          .then((): void => finish(true))
          .catch((error: Object): void => {
            if (LocalSendSubnetScanner.socketCode(error) !== 2301115) {
              finish(false);
            }
          });
      } catch (error) {
        finish(false);
      }
    });
  }

  private static socketCode(error: Object): number {
    const text = JSON.stringify(error);
    const match = /"code"\s*:\s*(\d+)/.exec(text);
    if (match !== null) {
      const value = parseInt(match[1], 10);
      if (!Number.isNaN(value)) {
        return value;
      }
    }
    return text.indexOf('2301115') >= 0 ? 2301115 : 0;
  }

  private async probe(host: string, generation: number): Promise<void> {
    // Try each known info path on its own TCP connection. A shared socket +
    // a single settled Promise breaks multi-path probing because the second
    // request reads the already-resolved first response.
    let anyTcpConnected = false;
    let openPorts = 0;
    for (const infoPath of INFO_PATHS) {
      const result = await this.requestInfo(host, infoPath);
      if (generation !== this.generation) {
        return;
      }
      if (result.connected) {
        anyTcpConnected = true;
        openPorts += 1;
      }
      const raw = result.raw;
      if (raw === '') {
        // 连接超时/拒绝：该主机未监听 53317，再试其余 path 只会重复等超时，直接跳过本主机。
        if (!result.connected) {
          return;
        }
        // 端口可连但无 HTTP 响应：极可能是 TLS-only 对端。别再试其余 path（每次都要等 read 超时），
        // 直接去做 TLS 探测，显著加快 HTTPS 对端出现卡片。
        break;
      }
      const split = raw.indexOf('\r\n\r\n');
      if (split < 0) {
        continue;
      }
      const status = raw.substring(0, split).split(' ')[1] ?? '';
      if (status !== '200') {
        continue;
      }
      let info: LocalSendPeerInfo;
      try {
        info = JSON.parse(raw.substring(split + 4)) as LocalSendPeerInfo;
      } catch (error) {
        Lg.w('LocalSend subnet parse failed ' + host + ': ' + JSON.stringify(error));
        continue;
      }
      if (info === null || typeof info !== 'object' || typeof info.alias !== 'string'
        || (info.protocol !== undefined && typeof info.protocol !== 'string')) {
        continue;
      }
      const peerPort = typeof info.port === 'number' && Number.isInteger(info.port)
        && info.port > 0 && info.port <= 65535 ? info.port : PORT;
      const https = (info.protocol ?? '').toLowerCase() === 'https';
      Lg.i('LocalSend subnet peer ' + host + ':' + peerPort + ' alias=' + (info.alias ?? host) + ' https=' + https);
      this.foundCount += 1;
      this.emit({
        id: 'localsend:' + host + ':' + peerPort,
        name: info.alias ?? host,
        model: typeof info.deviceModel === 'string' ? info.deviceModel : 'LocalSend device',
        protocol: 'localsend',
        address: host,
        port: peerPort,
        https,
        fingerprint: typeof info.fingerprint === 'string' ? info.fingerprint : '',
        source: 'lan'
      });
      return;
    }
    if (anyTcpConnected) {
      // 端口开着但没有 HTTP 响应 → 极可能是**只讲 TLS 的对端**（官方 LocalSend 默认 HTTPS + 自签证书）。
      // 这正是「搜不到对端 LocalSend App」的第二条原因：老实现到这里就结束了，从没做过 TLS 探测
      // （注释里写了要做，代码里没有）。补上：跳过证书校验发一次 GET。
      Lg.i('LocalSend subnet host ' + host + ':' + PORT
        + ' port open (' + openPorts + ' path connection(s)) but no /info HTTP 200 → 试 TLS');
      await this.probeTls(host, generation);
    }
  }

  /** 与发送共用原生 TLS 和客户端证书，避免另一套 TLSSocket 握手路径。 */
  private async probeTls(host: string, generation: number): Promise<void> {
    for (const infoPath of INFO_PATHS) {
      const result = await this.requestInfo(host, infoPath, true);
      if (generation !== this.generation || result.raw === '') {
        return;
      }
      const split = result.raw.indexOf('\r\n\r\n');
      if (split < 0 || result.raw.substring(0, split).split(' ')[1] !== '200') {
        continue;
      }
      try {
        const info = JSON.parse(result.raw.substring(split + 4)) as LocalSendPeerInfo;
        if (info === null || typeof info !== 'object' || typeof info.alias !== 'string'
        || (info.protocol !== undefined && typeof info.protocol !== 'string')) {
          continue;
        }
        const port = typeof info.port === 'number' && Number.isInteger(info.port)
          && info.port > 0 && info.port <= 65535 ? info.port : PORT;
        this.foundCount += 1;
        this.emit({
          id: 'localsend:' + host + ':' + port,
          name: info.alias,
          model: typeof info.deviceModel === 'string' ? info.deviceModel : 'LocalSend device',
          protocol: 'localsend', address: host, port, https: true,
          fingerprint: typeof info.fingerprint === 'string' ? info.fingerprint : '', source: 'lan'
        });
        return;
      } catch (error) {
        Lg.w('LocalSend subnet TLS info parse failed ' + host + ': ' + JSON.stringify(error));
      }
    }
  }

  /**
   * 判断响应是否已经**完整**收到；完整则返回「头部 + 完整 body」的字节（供上层按 `\r\n\r\n` 切分）。
   *
   * 真机踩过的坑：官方 LocalSend（Dart）的 `/info` 响应是 `Transfer-Encoding: chunked`、没有
   * `Content-Length`。老实现把「没有 Content-Length」当成「已经收完」，于是**只拿到响应头就 resolve**，
   * 之后的 `JSON.parse` 必然失败 → 子网扫描永远发现不了对端。这里用共享的 `HttpBodyParser`：
   * chunked 走解块、有长度等够长度、两者都没有则等 JSON 完整；调用方限制大小和总等待时间。
   */
  private static completeResponse(bytes: Uint8Array): Uint8Array | undefined {
    const headerEnd = HttpBodyParser.headerEnd(bytes);
    if (headerEnd < 0) {
      return undefined;
    }
    const parsed = HttpBodyParser.parseHead(
      ByteUtils.decodeText(bytes.slice(0, headerEnd)));
    const body = bytes.slice(headerEnd + 4);
    if (parsed.chunked) {
      const decoded = HttpBodyParser.decodeChunked(body);
      if (decoded === undefined) {
        return undefined;
      }
      return ByteUtils.concat([bytes.slice(0, headerEnd + 4), decoded]);
    }
    if (parsed.contentLength >= 0) {
      return body.length >= parsed.contentLength ? bytes.slice(0, headerEnd + 4 + parsed.contentLength) : undefined;
    }
    // 无长度且非 chunked：只能靠调用方的读超时/上限兜底。
    try {
      JSON.parse(ByteUtils.decodeText(body));
      return bytes;
    } catch (error) {
      return undefined;
    }
  }

  private async requestInfo(host: string, infoPath: string, secure: boolean = false): Promise<InfoProbeResult> {
    let connected = false;
    let finished = false;
    let transport: ByteTransport | undefined;
    let tcp: socket.TCPSocket | undefined;
    let tcpClosed = false;
    const closeTcp = (): void => {
      if (tcp !== undefined && !tcpClosed) {
        tcpClosed = true;
        void tcp.close().catch((): void => {});
      }
    };
    let dataBytes = new Uint8Array(0);
    let resolveResponse: (value: string) => void = (): void => {};
    const response = new Promise<string>((resolve: (value: string) => void): void => {
      resolveResponse = resolve;
    });
    const finish = (raw: string): void => {
      if (!finished) {
        finished = true;
        resolveResponse(raw);
      }
    };
    const cancel = (): void => finish('');
    this.cancellations.add(cancel);
    // Covers certificate loading, connect, handshake, send and response, not only read.
    const timer = setTimeout(cancel, CONNECT_TIMEOUT_MS + READ_TIMEOUT_MS);
    const onData = (bytes: Uint8Array): void => {
      if (finished) {
        return;
      }
      if (dataBytes.length + bytes.length > 65536) {
        finish('');
        return;
      }
      dataBytes = ByteUtils.concat([dataBytes, bytes]);
      const ready = LocalSendSubnetScanner.completeResponse(dataBytes);
      if (ready !== undefined) {
        finish(ByteUtils.decodeText(ready));
      }
    };
    const request = ByteUtils.encodeText('GET ' + infoPath + ' HTTP/1.1\r\nHost: '
      + host + '\r\nConnection: close\r\n\r\n');
    const run = async (): Promise<void> => {
      if (secure) {
        const material = await this.certs.ensure();
        if (finished) {
          return;
        }
        const certPem = material === undefined ? '' : await fs.readText(material.certPath);
        const keyPem = material === undefined ? '' : await fs.readText(material.keyPath);
        if (finished) {
          return;
        }
        const opened = await Transports.open(host, PORT, true, certPem, keyPem);
        if (finished) {
          void opened.close().catch((): void => {});
          return;
        }
        transport = opened;
        connected = true;
        opened.onData(onData);
        await opened.send(request);
      } else {
        const instance = socket.constructTCPSocketInstance();
        tcp = instance;
        instance.on('message', (info: socket.SocketMessageInfo): void => onData(new Uint8Array(info.message)));
        instance.on('close', cancel);
        const ok = await LocalSendSubnetScanner.connectChecked(instance, host, PORT);
        if (finished || !ok) {
          // Also releases a connection whose completion arrives after cancellation.
          closeTcp();
          finish('');
          return;
        }
        connected = true;
        await instance.send({ data: ByteUtils.toArrayBuffer(request) });
      }
    };
    void run().catch(cancel);
    try {
      return { raw: await response, connected };
    } finally {
      clearTimeout(timer);
      this.cancellations.delete(cancel);
      if (transport !== undefined) {
        void transport.close().catch((): void => {});
      }
      closeTcp();
    }
  }
}
