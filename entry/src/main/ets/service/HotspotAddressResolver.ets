import { socket } from '@kit.NetworkKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { LogCapture as Lg } from '../common/LogCapture';
import { HOTSPOT_GATEWAY_CANDIDATES, localHotspotGateways, looksLikeGatewayAddress }
  from '../common/NetAddress';

const LOG_TAG: string = '[HOTSPOT]';
const PROBE_TIMEOUT_MS: number = 700;
const SOCKET_EINPROGRESS: number = 2301115;
/**
 * 探到热点地址后的缓存时长。
 * UI 每 5 秒取一次地址，命中后 60 秒不再重复建连接探测（旧实现 15 秒一轮，
 * 日志里就是每 15 秒一条 self-probe hit，全是无效开销）。
 */
const HIT_CACHE_TTL_MS: number = 60000;
/**
 * 没探到时的缓存时长 —— 必须短。
 * 旧实现命中/未命中一律缓存 15 秒，服务端还没监听时的那次失败会把「蜂窝地址
 * 10.x」钉在 UI 上十几秒，这正是「要等一段时间才变成 192.168.43.1」的原因。
 */
const MISS_CACHE_TTL_MS: number = 1500;
/** 热点开关状态的查询缓存（系统服务调用，2 秒足够）。 */
const HOTSPOT_FLAG_TTL_MS: number = 2000;
/** HarmonyOS / Android 系统个人热点的默认网关，作为「不等探测」时的首选答案。 */
const DEFAULT_HOTSPOT_GATEWAY: string = '192.168.43.1';

export interface HotspotResolveResult {
  /** 确认可用的本机热点/共享网段地址；空串表示没探到。 */
  readonly address: string;
  /** 探测时使用的端口。 */
  readonly port: number;
  /** 来源：枚举命中 / 自连探测命中 / 未命中。 */
  readonly source: 'enumerated' | 'probed' | 'none';
  /** 本次尝试过的候选地址，落日志用。 */
  readonly tried: string[];
}

/**
 * 热点场景下的「本机地址」解析器。
 *
 * 背景：手机开个人热点时，`netConnection.getAllNetsSync()` 常常**枚举不到 SoftAP 网络**
 * （热点网络对三方应用不可见，三方应用也无法用代码开启/绑定它）。此时 NetAddress 只能看到
 * 蜂窝数据的地址（典型 10.x.x.x 运营商内网），于是本机对外显示成 192.0.2.10 这种
 * 「电脑永远连不上」的地址 —— 而连着热点的电脑实际在 192.168.43.0/24，网关是 192.168.43.1。
 *
 * 两层答案，缺一不可：
 * 1) `provisional()` —— **零等待**。向系统问一句「热点开着吗」（wifiManager.isHotspotActive），
 *    开着就直接给出 192.168.43.1（上次探测确认过的地址优先）。UI 首帧就是对的，不用等探测。
 * 2) `resolve()` —— **自连探测确认**。逐个候选网关地址对本机自己的服务端口发起 TCP 连接，
 *    并发验证候选；只有连接的本地地址与目标地址相同才算自连。
 *    热点网段非默认（如 192.168.8.1）时，由这一层在百毫秒内纠正第 1 层的猜测。
 */
export class HotspotAddressResolver {

  private static cache: HotspotResolveResult | undefined = undefined;
  private static cacheAt: number = 0;
  private static readonly inflight: Map<number, Promise<HotspotResolveResult>> = new Map();
  private static hotspotGeneration: number = 0;
  /** 最近一次探测确认过的热点地址：进程内长期记忆，下次开热点时首帧就能用真答案。 */
  private static lastConfirmed: string = '';
  private static hotspotOn: boolean = false;
  private static hotspotFlagAt: number = 0;
  private static readonly listeners: Set<(address: string) => void> = new Set<(address: string) => void>();
  private static lastNotified: string = '';
  private static lastProvisionalLogged: string = '';

  /** 热点开关状态（带 2 秒缓存；取不到一律按「未开启」处理，退回普通局域网逻辑）。 */
  static isHotspotOn(): boolean {
    const now: number = Date.now();
    if (now - HotspotAddressResolver.hotspotFlagAt < HOTSPOT_FLAG_TTL_MS) {
      return HotspotAddressResolver.hotspotOn;
    }
    let on: boolean = false;
    try {
      on = wifiManager.isHotspotActive();
    } catch (error) {
      // 无权限 / 接口不可用时不能让整条地址链路挂掉：按未开热点处理即可。
      on = false;
    }
    if (HotspotAddressResolver.hotspotOn && !on) {
      HotspotAddressResolver.hotspotGeneration += 1;
      HotspotAddressResolver.cache = undefined;
      HotspotAddressResolver.lastConfirmed = '';
      HotspotAddressResolver.lastNotified = '';
      HotspotAddressResolver.inflight.clear();
    }
    HotspotAddressResolver.hotspotOn = on;
    HotspotAddressResolver.hotspotFlagAt = now;
    return on;
  }

  /**
   * 不等探测的即时答案：热点开着时直接给出热点网段地址。
   *
   * 顺序：上次探测确认过的地址（真答案）→ 系统热点默认网关 192.168.43.1。
   * 热点没开时返回空串，调用方回落到普通 Wi-Fi 地址，行为与旧逻辑一致。
   */
  static provisional(): string {
    if (!HotspotAddressResolver.isHotspotOn()) {
      return '';
    }
    let answer: string = '';
    if (HotspotAddressResolver.lastConfirmed.length > 0) {
      answer = HotspotAddressResolver.lastConfirmed;
    } else {
      const cached: HotspotResolveResult | undefined = HotspotAddressResolver.cache;
      answer = cached !== undefined && cached.address.length > 0
        ? cached.address
        : DEFAULT_HOTSPOT_GATEWAY;
    }
    if (answer !== HotspotAddressResolver.lastProvisionalLogged) {
      HotspotAddressResolver.lastProvisionalLogged = answer;
      Lg.i(LOG_TAG + ' hotspot on, using ' + answer + ' without waiting for probe');
    }
    return answer;
  }

  /** 上一次确认过的热点地址（同步、可能为空）。供 UI/链接生成在探测未完成时兜底使用。 */
  static lastKnown(): string {
    if (!HotspotAddressResolver.isHotspotOn() || HotspotAddressResolver.cache === undefined) {
      return '';
    }
    const age: number = Date.now() - HotspotAddressResolver.cacheAt;
    if (age > 5 * 60 * 1000) {
      return '';
    }
    return HotspotAddressResolver.cache.address;
  }

  /** 当前应当展示的本机地址：已确认的热点地址 → 热点即时答案 → 空串（交给调用方回落）。 */
  static bestAddress(): string {
    const known: string = HotspotAddressResolver.lastKnown();
    if (known.length > 0) {
      return known;
    }
    return HotspotAddressResolver.provisional();
  }

  /** 订阅「热点地址确认」事件：探测命中后立刻回调，页面不必等下一个 5 秒刷新周期。 */
  static onResolved(listener: (address: string) => void): void {
    HotspotAddressResolver.listeners.add(listener);
  }

  static offResolved(listener: (address: string) => void): void {
    HotspotAddressResolver.listeners.delete(listener);
  }

  private static notify(address: string): void {
    if (address.length === 0 || address === HotspotAddressResolver.lastNotified) {
      return;
    }
    HotspotAddressResolver.lastNotified = address;
    HotspotAddressResolver.listeners.forEach((listener: (address: string) => void): void => {
      listener(address);
    });
  }

  /**
   * 解析本机在热点/共享网段上的地址。
   *
   * @param port 本机对外提供服务的端口（网页传输端口或 LocalSend 端口）。<=0 时返回空结果。
   */
  static resolve(port: number): Promise<HotspotResolveResult> {
    if (port <= 0 || !HotspotAddressResolver.isHotspotOn()) {
      return Promise.resolve<HotspotResolveResult>({
        address: '', port: port, source: 'none', tried: []
      });
    }
    // 枚举就能拿到热点地址时直接采信，不必再发探测包。
    const enumerated: string[] = localHotspotGateways();
    if (enumerated.length > 0) {
      const hit: HotspotResolveResult = {
        address: enumerated[0], port: port, source: 'enumerated', tried: enumerated
      };
      HotspotAddressResolver.remember(hit);
      Lg.i(LOG_TAG + ' enumerated hotspot address ' + enumerated[0]);
      return Promise.resolve(hit);
    }
    const now: number = Date.now();
    const cached: HotspotResolveResult | undefined = HotspotAddressResolver.cache;
    if (cached !== undefined && cached.port === port) {
      // 命中长缓存、未命中短缓存：未命中时下一次 UI 刷新（5 秒）就能重试，
      // 不会再出现「失败一次就摊手十几秒」的等待。
      const ttl: number = cached.address.length > 0 ? HIT_CACHE_TTL_MS : MISS_CACHE_TTL_MS;
      if (now - HotspotAddressResolver.cacheAt < ttl) {
        return Promise.resolve(cached);
      }
    }
    const existing = HotspotAddressResolver.inflight.get(port);
    if (existing !== undefined) { return existing; }
    const generation = HotspotAddressResolver.hotspotGeneration;
    const task = HotspotAddressResolver.probeAll(port).then((result: HotspotResolveResult): HotspotResolveResult => {
      if (!HotspotAddressResolver.isHotspotOn() || HotspotAddressResolver.hotspotGeneration !== generation) {
        return { address: '', port: port, source: 'none', tried: result.tried };
      }
      HotspotAddressResolver.remember(result);
      return result;
    }).finally((): void => {
      if (HotspotAddressResolver.inflight.get(port) === task) {
        HotspotAddressResolver.inflight.delete(port);
      }
    });
    HotspotAddressResolver.inflight.set(port, task);
    return task;
  }

  private static remember(result: HotspotResolveResult): void {
    HotspotAddressResolver.cache = result;
    HotspotAddressResolver.cacheAt = Date.now();
    if (result.address.length > 0) {
      HotspotAddressResolver.lastConfirmed = result.address;
      HotspotAddressResolver.notify(result.address);
    }
  }

  /** 候选地址顺序：已知热点网段 → 由 /24 推断的其他网关。 */
  private static candidates(): string[] {
    const out: string[] = [];
    for (const addr of HOTSPOT_GATEWAY_CANDIDATES) {
      if (out.indexOf(addr) < 0) {
        out.push(addr);
      }
    }
    return out;
  }

  /**
   * 并发自连探测：所有候选同时发起，第一个连上的即本机热点地址。
   *
   * 串行版本最坏要 8 × 700ms ≈ 5.6 秒，UI 得等满这一轮才拿得到正确地址；
   * 并发后整体耗时 = 最快那个候选的建连时间（本机地址通常几十毫秒），
   * 上限仍是单个探测的 700ms。落选的连接由各自超时自行关闭。
   */
  private static probeAll(port: number): Promise<HotspotResolveResult> {
    const list: string[] = HotspotAddressResolver.candidates();
    const tried: string[] = list.slice();
    if (list.length === 0) {
      return Promise.resolve<HotspotResolveResult>({
        address: '', port: port, source: 'none', tried: tried
      });
    }
    return new Promise<HotspotResolveResult>(
      (resolve: (result: HotspotResolveResult) => void): void => {
        let winner: string = '';
        let finished: number = 0;
        const settle = (): void => {
          finished += 1;
          if (winner.length === 0 && finished < list.length) {
            return;
          }
          if (winner.length > 0) {
            Lg.i(LOG_TAG + ' self-probe hit ' + winner + ':' + port + ' (local hotspot gateway)');
            resolve({ address: winner, port: port, source: 'probed', tried: tried });
            return;
          }
          Lg.i(LOG_TAG + ' no hotspot gateway reachable on :' + port + ' (tried ' + tried.length + ')');
          resolve({ address: '', port: port, source: 'none', tried: tried });
        };
        for (const addr of list) {
          HotspotAddressResolver.tcpProbe(addr, port)
            .then((ok: boolean): void => {
              if (ok && winner.length === 0) {
                winner = addr;
              }
              settle();
            })
            .catch((): void => {
              settle();
            });
        }
      });
  }

  /** 一次 TCP 自连探测；容忍 EINPROGRESS，连接成功后核对实际本地地址。 */
  private static tcpProbe(host: string, port: number): Promise<boolean> {
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
      let checking = false;
      const verify = (): void => {
        if (done || checking) { return; }
        checking = true;
        tcp.getLocalAddress().then((local: socket.NetAddress): void => finish(local.address === host))
          .catch((): void => finish(false));
      };
      tcp.on('connect', verify);
      tcp.on('close', (): void => finish(false));
      tcp.on('error', (error: object): void => {
        if (HotspotAddressResolver.code(error) !== SOCKET_EINPROGRESS) { finish(false); }
      });
      timer = setTimeout((): void => finish(false), PROBE_TIMEOUT_MS);
      tcp.bind({ address: '0.0.0.0', family: 1, port: 0 }).then(async (): Promise<void> => {
        if (!done) { await tcp.connect({ address: { address: host, family: 1, port: port } }); }
      }).then(verify).catch((error: object): void => {
        if (HotspotAddressResolver.code(error) !== SOCKET_EINPROGRESS) { finish(false); }
      });
    });
  }

  private static code(error: object): number {
    const text: string = JSON.stringify(error);
    const match: RegExpExecArray | null = /"code"\s*:\s*(\d+)/.exec(text);
    if (match !== null) {
      const value: number = parseInt(match[1], 10);
      return Number.isNaN(value) ? 0 : value;
    }
    return text.indexOf('2301115') >= 0 ? SOCKET_EINPROGRESS : 0;
  }

  /** 该地址是否「像」一个热点网关（供 UI 决定要不要提示热点引导）。 */
  static isLikelyHotspotGateway(addr: string): boolean {
    return looksLikeGatewayAddress(addr);
  }
}
