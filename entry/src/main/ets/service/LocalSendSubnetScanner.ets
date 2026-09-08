import { LogCapture as Lg } from '../common/LogCapture';
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ByteUtils } from '../common/ByteUtils';
import { DeviceEndpoint } from '../model/TransferModels';

const PORT = 53317;
// 两个超时区分开：LAN 上服务器毫秒级 accept，拒绝也是毫秒级；
// 只有“丢包/防火墙 drop”的主机才会挂到 connect 超时。connect 超时设小可让
// 整个 /24 扫描几秒内完成，而不是拖着几十秒。读超时略大，给首包留时间。
// 注意：@ohos.net.socket 的异步 connect 在其“主线程完成回调(OnTcpConnectComplete)”
// 与后台 ConnectMonitor 线程之间存在一个已知的释放竞争——若我们在 connect 仍被框架
// 完结时就把大量 socket 同时 close，两个线程会去 free 同一个连接上下文，触发
// “may double free” SIGTRAP。因此这里刻意
// 压低并发、拉长 connect 超时，让扫描进程更慢但更稳，避免同刻产生过多
// “还在完结中就被 close”的 connect。
const CONNECT_TIMEOUT_MS = 1500;
const READ_TIMEOUT_MS = 2500;
const INFO_PATHS: string[] = ['/api/localsend/v2/info', '/api/localsend/v1/info', '/api/info'];
const CONCURRENCY = 4;
const CRLF_CRLF = new Uint8Array([13, 10, 13, 10]);

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
  private foundCount = 0;

  constructor(emit: DeviceEmitter, isOwn: AddressChecker) {
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
    this.running = true;
    this.foundCount = 0;
    try {
      let next = 1;
      const worker = async (): Promise<void> => {
        while (next <= 254) {
          const host = parts[0] + '.' + parts[1] + '.' + parts[2] + '.' + next;
          next += 1;
          if (!this.isOwn(host)) {
            await this.probe(host);
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

  /** 自连本机 IP:53317，检测 TCP 服务端是否真正监听并响应 /info。 */
  async probeSelf(host: string): Promise<boolean> {
    const result = await this.requestInfo(host, '/api/localsend/v2/info');
    const raw = result.raw;
    if (raw !== '') {
      const split = raw.indexOf('\r\n\r\n');
      if (split < 0) {
        return false;
      }
      const status = raw.substring(0, split).split(' ')[1] ?? '';
      if (status === '200') {
        return true;
      }
    }
    return false;
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

  private async probe(host: string): Promise<void> {
    // Try each known info path on its own TCP connection. A shared socket +
    // a single settled Promise breaks multi-path probing because the second
    // request reads the already-resolved first response.
    let anyTcpConnected = false;
    let openPorts = 0;
    for (const infoPath of INFO_PATHS) {
      const result = await this.requestInfo(host, infoPath);
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
      const rawPort = info.port !== undefined && info.port > 0 ? info.port : PORT;
      const peerPort = Number(rawPort) > 0 ? Number(rawPort) : PORT;
      const https = (info.protocol ?? '').toLowerCase() === 'https';
      Lg.i('LocalSend subnet peer ' + host + ':' + peerPort + ' alias=' + (info.alias ?? host) + ' https=' + https);
      this.foundCount += 1;
      this.emit({
        id: 'localsend:' + host + ':' + peerPort,
        name: info.alias ?? host,
        model: info.deviceModel ?? 'LocalSend device',
        protocol: 'localsend',
        address: host,
        port: peerPort,
        https,
        fingerprint: info.fingerprint ?? '',
        source: 'lan'
      });
      return;
    }
    if (anyTcpConnected) {
      Lg.i('LocalSend subnet host ' + host + ':' + PORT
        + ' port open (' + openPorts + ' path connection(s)) but no /info HTTP 200 (HTTP-only)');
    }
  }

  private async requestInfo(host: string, infoPath: string): Promise<InfoProbeResult> {
    const tcp = socket.constructTCPSocketInstance();
    let dataBytes = new Uint8Array(0);
    let connected = false;
    try {
      const response = new Promise<string>((resolve) => {
        tcp.on('message', (info: socket.SocketMessageInfo): void => {
          // 按字节累积，不能用 JS 字符串长度比较 Content-Length：
          // 响应体含中文（别名/设备名）时 UTF-8 一个字符占 3 字节，
          // 字符串 length 会小于真实字节数，导致永远判定为“体不完整”。
          dataBytes = ByteUtils.concat([dataBytes, new Uint8Array(info.message)]);
          const split = ByteUtils.indexOf(dataBytes, CRLF_CRLF, 0);
          if (split >= 0) {
            const header = ByteUtils.decodeText(dataBytes.slice(0, split)).toLowerCase();
            const match = header.match(/content-length:\s*(\d+)/);
            const expected = match === null ? -1 : parseInt(match[1], 10);
            const bodyBytes = dataBytes.length - (split + 4);
            if (expected < 0 || bodyBytes >= expected) {
              resolve(ByteUtils.decodeText(dataBytes));
            }
          } else if (dataBytes.length > 8192) {
            resolve(ByteUtils.decodeText(dataBytes));
          }
        });
      });
      // HarmonyOS 部分版本 tcp.connect 返回 2301115(EINPROGRESS) 后可能既不 resolve
      // 也不 reject、也不触发 connect 事件；直接用 connect 事件 + getState() 轮询
      // 判定真实连接，避免把已建立连接误判为超时而提前 close。
      const ok = await LocalSendSubnetScanner.connectChecked(tcp, host, PORT);
      if (!ok) {
        return { raw: '', connected: false };
      }
      connected = true;
      await tcp.send({ data: ByteUtils.toArrayBuffer(ByteUtils.encodeText(
        'GET ' + infoPath + ' HTTP/1.1\r\nHost: ' + host + '\r\nConnection: close\r\n\r\n'
      )) });
      const raw = await Promise.race([
        response,
        new Promise<string>((resolve) => setTimeout(() => resolve(''), READ_TIMEOUT_MS))
      ]);
      return { raw, connected };
    } catch (error) {
      return { raw: '', connected };
    } finally {
      tcp.close().catch((error: BusinessError): void => {
        void error;
      });
    }
  }

}
