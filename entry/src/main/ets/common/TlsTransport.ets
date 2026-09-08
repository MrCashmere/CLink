import { LogCapture as Lg } from '../common/LogCapture';
import { socket } from '@kit.NetworkKit';
import { ByteUtils } from './ByteUtils';
import tlsNative from 'libtls_transport.so';

export type TransportListener = (chunk: Uint8Array) => void;

export interface ByteTransport {
  send(data: Uint8Array): Promise<void>;
  onData(listener: TransportListener): void;
  close(): Promise<void>;
}

const CONNECT_TIMEOUT_MS = 8000;

class TlsClientTransport implements ByteTransport {
  private listener?: TransportListener;

  private readonly tls: socket.TLSSocket;

  private constructor(tls: socket.TLSSocket) {
    this.tls = tls;
  }

  static async connect(host: string, port: number): Promise<TlsClientTransport> {
    const tls = socket.constructTLSSocketInstance();
    await tls.bind({ address: '0.0.0.0', family: 1, port: 0 });
    const transport = new TlsClientTransport(tls);
    tls.on('message', (info: socket.SocketMessageInfo) => {
      if (transport.listener !== undefined) {
        transport.listener(new Uint8Array(info.message));
      }
    });
    await tls.connect({
      address: { address: host, family: 1, port: port },
      secureOptions: { protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13] },
      skipRemoteValidation: true
    });
    return transport;
  }

  async send(data: Uint8Array): Promise<void> {
    await this.tls.send(ByteUtils.toArrayBuffer(data));
  }

  onData(listener: TransportListener): void {
    this.listener = listener;
  }

  async close(): Promise<void> {
    try {
      this.tls.off('message');
    } catch (error) {
      Lg.w(`TLS off failed: ${JSON.stringify(error)}`);
    }
    await this.tls.close().catch(() => undefined);
  }
}

class TcpClientTransport implements ByteTransport {
  private listener?: TransportListener;

  private readonly tcp: socket.TCPSocket;

  private constructor(tcp: socket.TCPSocket) {
    this.tcp = tcp;
  }

  static async connect(host: string, port: number): Promise<TcpClientTransport> {
    const tcp = socket.constructTCPSocketInstance();
    await tcp.bind({ address: '0.0.0.0', family: 1, port: 0 });
    const transport = new TcpClientTransport(tcp);
    tcp.on('message', (info: socket.SocketMessageInfo) => {
      if (transport.listener !== undefined) {
        transport.listener(new Uint8Array(info.message));
      }
    });
    await tcp.connect({
      address: { address: host, family: 1, port: port },
      timeout: CONNECT_TIMEOUT_MS
    });
    return transport;
  }

  async send(data: Uint8Array): Promise<void> {
    await this.tcp.send({ data: ByteUtils.toArrayBuffer(data) });
  }

  onData(listener: TransportListener): void {
    this.listener = listener;
  }

  async close(): Promise<void> {
    try {
      this.tcp.off('message');
    } catch (error) {
      Lg.w(`TCP off failed: ${JSON.stringify(error)}`);
    }
    await this.tcp.close().catch(() => undefined);
  }
}

// Native mbedTLS transport (via libtls_transport.so). The native module creates the TCP
// socket itself (POSIX connect), then runs the mbedTLS handshake/read/write on a worker
// thread and delivers data/close through a threadsafe callback. There is no
// @ohos.net.socket in the TLS data path: its event loop would otherwise compete with
// mbedTLS over the same fd and stall the handshake.
class NativeTlsTransport implements ByteTransport {
  private handle: number = 0;
  private listener?: TransportListener;
  private closed: boolean = false;
  private readonly pending: Uint8Array[] = [];

  private constructor() {
    // native owns the socket
  }

  static async connect(host: string, port: number, certPem?: string, keyPem?: string): Promise<NativeTlsTransport> {
    const transport = new NativeTlsTransport();
    // Native connect() does the TCP connect + mbedTLS handshake on a worker thread
    // and returns immediately with a handle. LocalSend uses mutual TLS: the client must
    // also present its own self-signed cert (the peer sends certificate_required if it
    // is missing), so we forward the app's cert/key as a client certificate.
    Lg.i('羊绒互传 TLS: NativeTlsTransport.connect -> ' + host + ':' + port);
    const rawHandle = tlsNative.connect(host, port,
      { host: host, skipVerify: true, certPem: certPem ?? '', keyPem: keyPem ?? '' },
      (chunk: ArrayBuffer | null, err: string | null): void => transport.routeNativeEvent(chunk, err)) as number | null | undefined;
    Lg.i('羊绒互传 TLS: native connect handle=' + rawHandle);
    if (rawHandle !== undefined && rawHandle !== null && rawHandle > 0) {
      transport.handle = rawHandle;
      return transport;
    }
    throw new Error('native TLS connect failed');
  }

  private routeNativeEvent(chunk: ArrayBuffer | null, err: string | null): void {
    if (err !== null && err !== undefined) {
      Lg.i('羊绒互传 TLS: native closed error=' + err);
      this.closed = true;
      return;
    }
    if (chunk === null) {
      Lg.i('羊绒互传 TLS: native closed (no more data)');
      this.closed = true;
      return;
    }
    if (chunk.byteLength === 0) {
      return;
    }
    Lg.i('羊绒互传 TLS: native data len=' + chunk.byteLength);
    const data = new Uint8Array(chunk);
    if (this.listener !== undefined) {
      this.listener(data);
    } else {
      this.pending.push(data);
    }
  }

  async send(data: Uint8Array): Promise<void> {
    if (this.handle <= 0 || this.closed) {
      throw new Error('native TLS transport closed');
    }
    const written = tlsNative.send(this.handle, ByteUtils.toArrayBuffer(data)) as number;
    if (written < 0) {
      throw new Error('native TLS send failed');
    }
  }

  onData(listener: TransportListener): void {
    this.listener = listener;
    while (this.pending.length > 0) {
      const buffered = this.pending.shift();
      if (buffered !== undefined) {
        listener(buffered);
      }
    }
  }

  async close(): Promise<void> {
    if (this.handle > 0) {
      tlsNative.close(this.handle);
      this.handle = 0;
    }
    this.closed = true;
  }
}

export class Transports {
  static async open(host: string, port: number, secure: boolean, certPem?: string, keyPem?: string): Promise<ByteTransport> {
    if (secure) {
      // Native mbedTLS transport (avoids the broken @ohos.net.socket TLSSocket).
      return NativeTlsTransport.connect(host, port, certPem, keyPem);
    }
    return TcpClientTransport.connect(host, port);
  }
}