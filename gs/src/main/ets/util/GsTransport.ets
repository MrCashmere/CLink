import { socket } from '@kit.NetworkKit';
import { GsBytes } from './GsBytes';

export type GsTransportListener = (chunk: Uint8Array) => void;

export interface GsTransport {
  send(data: Uint8Array): Promise<void>;
  onData(listener: GsTransportListener): void;
  close(): Promise<void>;
}

const CONNECT_TIMEOUT_MS = 8000;
const CONNECT_GRACE_MS = 1500;

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

  private readonly tcp: socket.TCPSocket;

  private constructor(tcp: socket.TCPSocket) {
    this.tcp = tcp;
  }

  static async connect(host: string, port: number, sourceAddress?: string): Promise<GsTcpClientTransport> {
    console.info('Quick Share TCP connecting to ' + host + ':' + port);
    const tcp = socket.constructTCPSocketInstance();
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
    const onConnected = (): void => {
      if (!settled && resolveConnected !== undefined) {
        resolveConnected();
      }
    };
    const onUnexpectedClose = (): void => {
      if (!settled && rejectWait !== undefined) {
        settled = true;
        rejectWait(new Error('TCP peer closed before connect completed'));
      }
    };
    tcp.on('connect', onConnected);
    tcp.on('close', onUnexpectedClose);
    tcp.on('error', (error: Object): void => {
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
        + '; waiting for connect event or socket close/error up to ' + CONNECT_GRACE_MS + 'ms');
      try {
        await waitForSocketReady(connectEvent, closedOrError, tcp, host, port);
        settled = true;
        console.info('Quick Share TCP connected (during EINPROGRESS grace) to ' + host + ':' + port);
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
  }

  async send(data: Uint8Array): Promise<void> {
    await this.tcp.send({ data: GsBytes.toArrayBuffer(data) });
  }

  onData(listener: GsTransportListener): void {
    this.listener = listener;
  }

  async close(): Promise<void> {
    try {
      this.tcp.off('message');
    } catch (error) {
      console.warn('gs TCP off failed: ' + JSON.stringify(error));
    }
    await this.tcp.close().catch((): void => undefined);
  }
}

async function waitForSocketReady(
  connectEvent: Promise<void>,
  closedOrError: Promise<void>,
  tcp: socket.TCPSocket,
  host: string,
  port: number
): Promise<void> {
  return new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
    let done = false;
    let timer: number | undefined = undefined;
    const finish = (error?: Error): void => {
      if (done) {
        return;
      }
      done = true;
      if (timer !== undefined) {
        clearTimeout(timer);
      }
      if (error !== undefined) {
        reject(error);
      } else {
        resolve();
      }
    };
    connectEvent.then((): void => finish(), (): void => finish(new Error('TCP connect event failed')));
    closedOrError.then((): void => finish(new Error('TCP peer closed before connect completed')),
      (error: Error): void => finish(error));
    timer = setTimeout((): void => {
      // Some HarmonyOS releases return EINPROGRESS during a slow connect and
      // never surface the 'connect' event through the Promise. Prefer the
      // native callback; if it does not come, probe the real socket state so
      // the sender no longer sends on an unconnected socket (2301107).
      console.info('Quick Share TCP EINPROGRESS grace elapsed for ' + host + ':' + port + '; probing socket state');
        tcp.getState().then((state: socket.SocketStateBase): void => {
          if (state.isConnected) {
            finish();
          } else {
            // EINPROGRESS followed by isConnected=false means the SYN got no
            // response: the peer is not listening on this port, or a firewall /
            // AP client-isolation is dropping device-to-device unicast. It is
            // NOT a connection-refused (RST) or routing error, so surface a
            // diagnostic that directs the user to the right check.
            finish(new Error('TCP socket connect did not complete to ' + host + ':' + port
              + ': SYN 无应答（对端可能未在监听该端口，或无线 AP 开启了客户端隔离/防火墙拦截设备间单播）；'
              + 'state.isConnected=' + state.isConnected));
          }
        }).catch((error: Object): void => {
          console.warn('Quick Share TCP getState failed (treating as not connected) '
          + host + ':' + port + ': ' + JSON.stringify(error));
        finish(new Error('TCP socket connect did not complete before timeout'));
      });
    }, CONNECT_GRACE_MS);
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
