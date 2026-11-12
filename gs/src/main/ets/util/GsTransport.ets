import { socket } from '@kit.NetworkKit';
import { GsBytes } from './GsBytes';

export type GsTransportListener = (chunk: Uint8Array) => void;

export interface GsTransport {
  send(data: Uint8Array): Promise<void>;
  onData(listener: GsTransportListener): void;
  onClose?(listener: () => void): void;
  close(): Promise<void>;
}

// 建连预算：现场实测同网段对端 ICMP 0% 丢包但 RTT 200–420ms（省电休眠），TCP 握手常需 2–4s，
// 故 OS 侧与本地等待都放宽到 10s；真正不可达的对端仍会在 10s 后判失败（回退端口再一轮）。
const CONNECT_TIMEOUT_MS = 10000;
// EINPROGRESS 之后的状态探测间隔（取代原来的固定 1.5s 宽限期，见 waitForSocketReady 注释）。
const PROBE_INTERVAL_MS = 250;

interface SocketOperationError {
  readonly code?: number;
  readonly message?: string;
}

function socketErrorCode(error: Object): number {
  const value = error as SocketOperationError;
  if (value.code !== undefined) {
    return value.code;
  }
  const message = value.message ?? '';
  return message.indexOf('2301115') >= 0 ? 2301115 : 0;
}

class GsTlsClientTransport implements GsTransport {
  private listener?: GsTransportListener;

  private readonly tls: socket.TLSSocket;

  private constructor(tls: socket.TLSSocket) {
    this.tls = tls;
  }

  static async connect(host: string, port: number, sourceAddress?: string): Promise<GsTlsClientTransport> {
    const tls = socket.constructTLSSocketInstance();
    try {
      await tls.bind({ address: sourceAddress !== undefined && sourceAddress.length > 0 ? sourceAddress : '0.0.0.0', family: 1, port: 0 });
      const transport = new GsTlsClientTransport(tls);
      tls.on('message', (info: socket.SocketMessageInfo): void => {
        if (transport.listener !== undefined) {
          transport.listener(new Uint8Array(info.message));
        }
      });
      await tls.connect({
        address: { address: host, family: 1, port },
        secureOptions: { protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13] }
      });
      return transport;
    } catch (error) {
      await tls.close().catch((): void => undefined);
      throw error instanceof Error ? error : new Error(JSON.stringify(error));
    }
  }

  async send(data: Uint8Array): Promise<void> {
    await this.tls.send(GsBytes.toArrayBuffer(data));
  }

  onData(listener: GsTransportListener): void {
    this.listener = listener;
  }

  async close(): Promise<void> {
    try {
      this.tls.off('message');
    } catch (error) {
      console.warn(`gs TLS off failed: ${JSON.stringify(error)}`);
    }
    await this.tls.close().catch((): void => undefined);
  }
}

class GsTcpClientTransport implements GsTransport {
  private listener?: GsTransportListener;
  private closeListener?: () => void;
  private closed: boolean = false;

  private readonly tcp: socket.TCPSocket;

  private constructor(tcp: socket.TCPSocket) {
    this.tcp = tcp;
  }

  static async connect(host: string, port: number, sourceAddress?: string): Promise<GsTcpClientTransport> {
    console.info('Quick Share TCP connecting to ' + host + ':' + port);
    const tcp = socket.constructTCPSocketInstance();
    try {
      await tcp.bind({ address: sourceAddress !== undefined && sourceAddress.length > 0 ? sourceAddress : '0.0.0.0', family: 1, port: 0 });
      const transport = new GsTcpClientTransport(tcp);
      tcp.on('message', (info: socket.SocketMessageInfo): void => {
        if (transport.listener !== undefined) {
          transport.listener(new Uint8Array(info.message));
        }
      });

      let settled = false;
      let rejectWait: ((error: Error) => void) | undefined;
      let resolveConnected: (() => void) | undefined;
      const connectEvent = new Promise<void>((resolve: () => void): void => {
        resolveConnected = resolve;
      });
      const closedOrError = new Promise<void>((_resolve: () => void, reject: (error: Error) => void): void => {
        rejectWait = reject;
      });
      void closedOrError.catch((): void => undefined);
      const onConnected = (): void => {
        if (!settled && resolveConnected !== undefined) {
          resolveConnected();
        }
      };
      const onUnexpectedClose = (): void => {
        transport.markClosed();
        if (!settled && rejectWait !== undefined) {
          settled = true;
          rejectWait(new Error('TCP peer closed before connect completed'));
        }
      };
      tcp.on('connect', onConnected);
      tcp.on('close', onUnexpectedClose);
      tcp.on('error', (error: Object): void => {
        transport.markClosed();
        console.warn('Quick Share TCP socket error to ' + host + ':' + port + ': ' + JSON.stringify(error));
        if (!settled && rejectWait !== undefined) {
          settled = true;
          rejectWait(error instanceof Error ? error : new Error(JSON.stringify(error)));
        }
      });

      try {
        await tcp.connect({
          address: { address: host, family: 1, port },
          timeout: CONNECT_TIMEOUT_MS
        });
        settled = true;
        console.info('Quick Share TCP connected to ' + host + ':' + port);
      } catch (error) {
        if (socketErrorCode(error as Object) !== 2301115) {
          console.warn('Quick Share TCP connect failed to ' + host + ':' + port + ': ' + JSON.stringify(error));
          throw (error instanceof Error ? error : new Error(JSON.stringify(error)));
        }
        console.warn('Quick Share TCP connect returned EINPROGRESS(2301115) to ' + host + ':' + port
          + '; polling socket state up to ' + CONNECT_TIMEOUT_MS + 'ms');
        try {
          await waitForSocketReady(connectEvent, closedOrError, tcp, host, port);
          settled = true;
        } catch (connectError) {
          console.warn('Quick Share TCP connect timeout/close to ' + host + ':' + port + ': ' + JSON.stringify(connectError));
          throw connectError instanceof Error
            ? connectError
            : new Error(JSON.stringify(connectError));
        }
      }

      // Avoid an unhandled rejection after the connect has already settled; the
      // close/error listeners are only relevant while the connect is pending.
      closedOrError.catch((): void => undefined);

      return transport;
    } catch (error) {
      await tcp.close().catch((): void => undefined);
      throw error instanceof Error ? error : new Error(JSON.stringify(error));
    }
  }

  async send(data: Uint8Array): Promise<void> {
    await this.tcp.send({ data: GsBytes.toArrayBuffer(data) });
  }

  onData(listener: GsTransportListener): void {
    this.listener = listener;
  }

  onClose(listener: () => void): void {
    this.closeListener = listener;
    if (this.closed) { listener(); }
  }

  private markClosed(): void {
    if (this.closed) { return; }
    this.closed = true;
    this.closeListener?.();
  }

  async close(): Promise<void> {
    this.markClosed();
    try {
      this.tcp.off('message');
    } catch (error) {
      console.warn('gs TCP off failed: ' + JSON.stringify(error));
    }
    await this.tcp.close().catch((): void => undefined);
  }
}

/**
 * EINPROGRESS 之后等待建连完成。
 *
 * 早期实现只等固定的 `CONNECT_GRACE_MS`(1.5s) 就探测一次 `getState()`，探到
 * `isConnected=false` 立刻判「SYN 无应答」并关连接。在真机上这条规则会把**慢但对端正常**的
 * 连接误判成失败：现场日志显示同网段对端 ICMP 0% 丢包、但 RTT 200–420ms（Android 省电休眠 /
 * AP 缓冲单播），TCP 三次握手常常要 2–4s（首个 SYN 被缓冲或丢弃，1s 后重传才拿到 SYN-ACK）。
 * 因此这里改为**轮询到 CONNECT_TIMEOUT_MS 为止**：事件先到就直接返回，否则每
 * `PROBE_INTERVAL_MS` 探一次 isConnected，成功即返回并记录实际耗时（便于确认是否属于慢建连），
 * 超时才判失败。
 */
async function waitForSocketReady(
  connectEvent: Promise<void>,
  closedOrError: Promise<void>,
  tcp: socket.TCPSocket,
  host: string,
  port: number
): Promise<void> {
  let eventConnected = false;
  // 用字符串记录关闭原因（ArkTS 不允许 throw 联合类型，见 arkts-limited-throw）。
  let closeMessage = '';
  connectEvent.then((): void => { eventConnected = true; }, (): void => { eventConnected = true; });
  closedOrError.then((): void => {
    closeMessage = 'TCP peer closed before connect completed';
  }, (error: Error): void => {
    closeMessage = error.message !== undefined && error.message.length > 0
      ? error.message : 'TCP peer closed before connect completed';
  });

  const startedAt: number = Date.now();
  while (Date.now() - startedAt < CONNECT_TIMEOUT_MS) {
    if (eventConnected) {
      return;
    }
    if (closeMessage.length > 0) {
      throw new Error(closeMessage);
    }
    try {
      const state: socket.SocketStateBase = await tcp.getState();
      if (state.isConnected) {
        console.info('Quick Share TCP connected (state probe) to ' + host + ':' + port
          + ' after ' + (Date.now() - startedAt) + 'ms');
        return;
      }
    } catch (error) {
      // getState 偶发失败不视为失败：继续等事件/下一次探测。
    }
    await delay(PROBE_INTERVAL_MS);
  }
  throw new Error('TCP socket connect did not complete to ' + host + ':' + port
    + ' within ' + CONNECT_TIMEOUT_MS + 'ms: SYN 无应答（对端可能未在监听该端口、处于省电休眠导致'
    + '握手被拖延，或链路拦截了设备间 TCP；同网段若 ICMP 通、TCP 不通，优先怀疑对端休眠/防火墙）；'
    + 'state.isConnected=false');
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

export class GsTransports {
  static async open(host: string, port: number, secure: boolean, sourceAddress?: string): Promise<GsTransport> {
    if (secure) {
      try {
        return await GsTlsClientTransport.connect(host, port, sourceAddress);
      } catch (error) {
        console.warn('gs TLS connect failed (' + JSON.stringify(error) + '); falling back to plain TCP.');
      }
    }
    return GsTcpClientTransport.connect(host, port, sourceAddress);
  }
}
