import { wifiManager } from '@kit.ConnectivityKit';
import { socket } from '@kit.NetworkKit';
import { LogCapture as Lg } from '../../common/LogCapture';
import { getLocalIpv4 } from '../../common/NetAddress';
import { QuickShareTransportMode } from '../model/TransportPolicy';

/** Wi-Fi 射频与关联状态。P2P 要求 STA 处于开启状态（未关联 AP 也可以建组）。 */
export type WifiRadioState = 'off' | 'sta-no-ap' | 'sta-ap';

/**
 * 传输决策：
 * - `lan`     —— 对端单播可达，直接走局域网 TCP（零建组开销，最快）；
 * - `ble-p2p` —— 对端不可达 / 只在 BLE 发现到 / 跨网段：先经 BLE 引导建会话，再升级 Wi-Fi Direct。
 */
export type TransportChoice = 'lan' | 'ble-p2p';

export interface TransportDecision {
  readonly choice: TransportChoice;
  /** 决策依据，落日志用于真机排查（见 docs/WIFI_DIRECT.md §5.4）。 */
  readonly reason: string;
}

interface ProbeCacheEntry {
  readonly ok: boolean;
  readonly at: number;
}

const PROBE_TIMEOUT_MS: number = 1200;
const CACHE_TTL_MS: number = 30000;
const SOCKET_EINPROGRESS: number = 2301115;

/**
 * 「是不是局域网」的判定工具。
 *
 * 关键设计：判据是**对端单播 TCP 是否可达**，不是「本机有没有连 Wi-Fi」。
 * 真机证据见 docs/QUICKSHARE_CHAIN.md §2：同一个 AP、mDNS 也发现到了对端，
 * 但官方端 TCP `ECONNREFUSED`（AP 客户端隔离 / GMS 应用绑网 / 卓易通虚拟网卡），
 * 这三种情况下「看起来都在局域网里」全都成立，只有探测能区分。
 *
 * 探测实现与 `QuickShare.selfTcpTest` / `LocalSendSubnetScanner.connectChecked` 一致，
 * 都**必须容忍 EINPROGRESS(2301115)**：connect() 返回它并不代表失败。
 */
export class LanReachability {
  private static readonly cache: Map<string, ProbeCacheEntry> = new Map<string, ProbeCacheEntry>();

  /** 0 成本前置：Wi-Fi 关着时 P2P 也建不起来（wifiManager 会报 2801001）。 */
  static wifiRadio(): WifiRadioState {
    try {
      if (!wifiManager.isWifiActive()) {
        return 'off';
      }
      return wifiManager.isConnected() ? 'sta-ap' : 'sta-no-ap';
    } catch (error) {
      Lg.w('[LANCHK] wifi state query failed: ' + JSON.stringify(error as object));
      return 'off';
    }
  }

  /**
   * 发送前的介质决策。
   *
   * @param mode     传输方式（设置项，三态）：`direct` 跳过探测强制直连；`lan` 只用局域网；
   *                 `auto` 走下面的探测判定。
   * @param peerKey  对端稳定标识（endpointId / fingerprint），仅用于探测结果缓存
   * @param peerIp   mDNS/局域网发现到的对端 IPv4；空串表示只经 BLE 发现到（没有局域网端点）
   * @param peerPort 对端监听端口
   */
  static async choose(mode: QuickShareTransportMode, peerKey: string, peerIp: string,
    peerPort: number): Promise<TransportDecision> {
    if (mode === 'direct') {
      return { choice: 'ble-p2p', reason: 'mode=direct (probe skipped)' };
    }
    if (mode === 'lan') {
      // 「仅局域网」= 不做 WLAN 直连升级。没有局域网端点时仍允许 BLE 兜底传输，
      // 但是否用 BLE 由调用方按 peerIp 决定，且不会请求升级。
      return { choice: 'lan', reason: 'mode=lan (upgrade disabled)' };
    }
    const radio: WifiRadioState = LanReachability.wifiRadio();
    if (radio === 'off') {
      // 此时 BLE 仍然可用，但 P2P 建不起来（2801001）。交给调用方提示用户开 WLAN。
      return { choice: 'lan', reason: 'wifi-radio-off: P2P unavailable, ask user to enable WLAN' };
    }
    if (peerIp.length === 0 || peerPort <= 0) {
      return { choice: 'ble-p2p', reason: 'peer only visible over BLE (no LAN endpoint)' };
    }
    if (!LanReachability.sameSubnet(getLocalIpv4(), peerIp)) {
      return { choice: 'ble-p2p', reason: 'peer outside local subnet' };
    }
    const ok: boolean = await LanReachability.probe(peerKey, peerIp, peerPort);
    return ok
      ? { choice: 'lan', reason: 'peer TCP reachable' }
      : { choice: 'ble-p2p', reason: 'LAN endpoint advertised but unicast TCP unreachable' };
  }

  /**
   * 同网段剪枝。只用来省一次探测：判错（拿不到掩码、掩码语义理解有误）时保守返回 true，
   * 让后续的探测负责定论。
   * 注意：`wifiManager.IpInfo.netmask` 是 number，SDK 未写清是 uint32 打包还是前缀长度，
   * 这里按 uint32 大端处理（待真机确认，见 docs/UNVERIFIED.md）。
   */
  static sameSubnet(local: string, peer: string): boolean {
    if (local.length === 0 || peer.length === 0) {
      return true;
    }
    try {
      const info: wifiManager.IpInfo = wifiManager.getIpInfo();
      const mask: string = LanReachability.dottedFromNumber(info.netmask);
      if (mask.length === 0) {
        return true;
      }
      const l: number[] = LanReachability.octets(local);
      const p: number[] = LanReachability.octets(peer);
      const m: number[] = LanReachability.octets(mask);
      if (l.length !== 4 || p.length !== 4 || m.length !== 4) {
        return true;
      }
      if (m[0] === 0 && m[1] === 0 && m[2] === 0 && m[3] === 0) {
        return true;
      }
      for (let i = 0; i < 4; i++) {
        if ((l[i] & m[i]) !== (p[i] & m[i])) {
          return false;
        }
      }
      return true;
    } catch (error) {
      return true;
    }
  }

  /** 带缓存的可达性探测（同一对端 CACHE_TTL_MS 内只探一次）。 */
  static probe(peerKey: string, host: string, port: number): Promise<boolean> {
    const now: number = Date.now();
    const hit: ProbeCacheEntry | undefined = LanReachability.cache.get(peerKey);
    if (hit !== undefined && now - hit.at < CACHE_TTL_MS) {
      return Promise.resolve(hit.ok);
    }
    return LanReachability.tcpProbe(host, port, PROBE_TIMEOUT_MS).then((ok: boolean): boolean => {
      LanReachability.cache.set(peerKey, { ok: ok, at: now });
      Lg.i('[LANCHK] probe ' + host + ':' + port + ' => ' + (ok ? 'reachable' : 'unreachable'));
      return ok;
    });
  }

  /** 主动作废某个对端的探测缓存（例如刚发生过一次连接失败）。 */
  static invalidate(peerKey: string): void {
    LanReachability.cache.delete(peerKey);
  }

  /** 一次 TCP 探测；容忍 EINPROGRESS，超时后用 socket 状态定论。 */
  private static tcpProbe(host: string, port: number, timeoutMs: number): Promise<boolean> {
    return new Promise<boolean>((resolve: (ok: boolean) => void): void => {
      const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
      let done: boolean = false;
      let timer: number = -1;
      const finish = (ok: boolean): void => {
        if (done) {
          return;
        }
        done = true;
        if (timer !== -1) {
          clearTimeout(timer);
        }
        tcp.close().catch((): void => undefined);
        resolve(ok);
      };
      tcp.on('connect', (): void => finish(true));
      tcp.on('close', (): void => finish(false));
      tcp.on('error', (error: object): void => {
        if (LanReachability.socketCode(error) !== SOCKET_EINPROGRESS) {
          finish(false);
        }
      });
      timer = setTimeout((): void => {
        tcp.getState().then((state: socket.SocketStateBase): void => finish(state.isConnected))
          .catch((): void => finish(false));
      }, timeoutMs);
      try {
        tcp.connect({ address: { address: host, family: 1, port: port } })
          .then((): void => finish(true))
          .catch((error: object): void => {
            if (LanReachability.socketCode(error) !== SOCKET_EINPROGRESS) {
              finish(false);
            }
          });
      } catch (error) {
        finish(false);
      }
    });
  }

  private static socketCode(error: object): number {
    const text: string = JSON.stringify(error);
    const match: RegExpExecArray | null = /"code"\s*:\s*(\d+)/.exec(text);
    if (match !== null) {
      const value: number = parseInt(match[1], 10);
      return Number.isNaN(value) ? 0 : value;
    }
    return text.indexOf('2301115') >= 0 ? SOCKET_EINPROGRESS : 0;
  }

  private static octets(addr: string): number[] {
    const parts: string[] = addr.split('.');
    if (parts.length !== 4) {
      return [];
    }
    const out: number[] = [];
    for (const part of parts) {
      const n: number = Number(part);
      if (!Number.isInteger(n) || n < 0 || n > 255) {
        return [];
      }
      out.push(n);
    }
    return out;
  }

  /** ⚠️ IpInfo 的 number 语义待真机确认；这里按「uint32 大端打包」转点分十进制。 */
  private static dottedFromNumber(value: number): string {
    if (!(value > 0)) {
      return '';
    }
    const n: number = value >>> 0;
    return ((n >>> 24) & 0xff) + '.' + ((n >>> 16) & 0xff) + '.' + ((n >>> 8) & 0xff) + '.' + (n & 0xff);
  }
}
