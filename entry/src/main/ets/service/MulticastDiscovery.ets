import { LogCapture as Lg } from '../common/LogCapture';
import { socket } from '@kit.NetworkKit';
import deviceInfo from '@ohos.deviceInfo';
import { BusinessError } from '@kit.BasicServicesKit';
import { ByteUtils } from '../common/ByteUtils';
import { SecurityUtils } from '../common/SecurityUtils';
import { SettingsStore } from '../common/SettingsStore';
import { DeviceEndpoint } from '../model/TransferModels';
import { NetDiscoveryNative } from './NetDiscoveryNative';

const LOG_TAG = '羊绒互传 multicast';
const MULTICAST_GROUP = '224.0.0.167';
const LIMITED_BROADCAST = '255.255.255.255';
/** mDNS 组播组：热点网卡上也要加，否则对端的 `_localsend._tcp` 响应进不来。 */
const MDNS_GROUP = '224.0.0.251';
const MDNS_PORT = 5353;
const MULTICAST_PORT = 53317;
const ANNOUNCE_INTERVAL_MS = 5000;
const ERR_ADDRESS_IN_USE = 2301098;
/** 自检等待时间（本机回环，毫秒级足够；给足余量避免误判）。 */
const SELF_TEST_WAIT_MS = 1200;

/** native 收包中继的封装：`__relay` 为真时 `data` 才是原始报文，`from` 是热点上的真实源地址。 */
interface RelayEnvelope {
  __relay?: boolean;
  from?: string;
  port?: number;
  data?: string;
}

interface LocalSendAnnounce {
  alias?: string;
  version?: string;
  deviceModel?: string;
  deviceType?: string;
  fingerprint?: string;
  port?: number;
  protocol?: string;
  download?: boolean;
  announcement?: boolean;
  announce?: boolean;
}

type AnnounceEmitter = (device: DeviceEndpoint) => void;
type AddressChecker = (address: string) => boolean;
type AddressProvider = () => string;

export class MulticastDiscovery {
  private readonly emitDevice: AnnounceEmitter;
  private readonly isOwnAddress: AddressChecker;
  private readonly getLocalAddress: AddressProvider;
  private fingerprint: string = SecurityUtils.createToken();
  private httpsEnabled: boolean = false;
  private announcePort: number = MULTICAST_PORT;
  private readonly failedTargets: Set<string> = new Set();
  private multicastSocket?: socket.MulticastSocket;
  /** 是否已在热点网卡上补加过组播组（native 侧），避免重复建 socket。 */
  private hotspotJoined: boolean = false;
  /** 接口清单是否打过日志（排障用，只打一次）。 */
  private ifaceDumped: boolean = false;
  private announceTimer: number = -1;
  private advertising = false;
  private started = false;
  private announcedOnce = false;
  private groupJoined = false;
  private bound = false;
  /** 所有 bind/close 共用串行队列，停服会使旧代次回调失效。 */
  private socketOperation: Promise<void> = Promise.resolve();
  private generation = 0;
  private retryTimer = -1;
  private selfTestTimer = -1;
  private selfTestToken = '';
  /** 自检：发给自己 53317 的探测包有没有回来。 */
  private selfTestSeen = false;
  private openAttempts = 0;
  /** 单播回包限频表（address -> 上次回包时刻）：见 shouldReplyTo 的风暴说明。 */
  private readonly lastReplyAt: Map<string, number> = new Map();
  /**
   * 发现链路的健康提示（空串 = 正常）。给 UI 用：多播接收不可用时，页面上直接告诉用户
   * 「搜不到对端」的原因和处置办法，而不是只留在日志里。
   */
  private healthHintValue: string = '';

  constructor(emitDevice: AnnounceEmitter, isOwnAddress: AddressChecker, getLocalAddress: AddressProvider) {
    this.emitDevice = emitDevice;
    this.isOwnAddress = isOwnAddress;
    this.getLocalAddress = getLocalAddress;
  }

  /** 当前发现链路的健康提示（空串 = 正常）。 */
  statusHint(): string {
    return this.healthHintValue;
  }

  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.generation += 1;
    this.openAttempts = 0;
    this.healthHintValue = '';
    // Native helpers share this lifecycle. Never let a membership-only socket
    // occupy the wildcard receive endpoint before the ArkTS reader is ready.
    NetDiscoveryNative.stopRelay();
    NetDiscoveryNative.leaveAllMulticast();
    this.hotspotJoined = false;
    this.openSocket();
    if (this.advertising) {
      this.startAnnounceTimer();
    }
  }

  private isCurrent(instance: socket.MulticastSocket, generation: number): boolean {
    return this.started && this.generation === generation && this.multicastSocket === instance;
  }

  // Serialize bind AND close, including sockets whose bind has not completed.
  // Retain ownership after close failure so the next attempt can release it.
  private async closeSocket(): Promise<void> {
    const instance = this.multicastSocket;
    if (instance === undefined) {
      return;
    }
    await instance.close();
    if (this.multicastSocket === instance) {
      this.multicastSocket = undefined;
    }
  }

  private openSocket(): void {
    const generation = this.generation;
    this.socketOperation = this.socketOperation.then(async (): Promise<void> => {
      if (!this.started || generation !== this.generation) {
        return;
      }
      NetDiscoveryNative.stopRelay();
      NetDiscoveryNative.leaveAllMulticast();
      this.hotspotJoined = false;
      await this.closeSocket();
      if (!this.started || generation !== this.generation) {
        return;
      }
      const instance = socket.constructMulticastSocketInstance();
      this.multicastSocket = instance;
      // SDK requires bind before setExtraOptions. No native helper may bind
      // until this reader has bound and enabled reuse for the group-only relay.
      await instance.bind({ address: '0.0.0.0', port: MULTICAST_PORT, family: 1 });
      if (!this.isCurrent(instance, generation)) {
        return;
      }
      instance.on('message', (value: socket.SocketMessageInfo): void => {
        if (!this.isCurrent(instance, generation)) {
          return;
        }
        const text = ByteUtils.decodeText(new Uint8Array(value.message));
        if (text === this.selfTestToken) {
          this.selfTestSeen = true;
          return;
        }
        this.handleMessage(value);
      });
      await instance.setExtraOptions({ reuseAddress: true, broadcast: true });
      if (!this.isCurrent(instance, generation)) {
        return;
      }
      this.bound = true;
      this.joinGroupOnHotspotInterfaces();
      this.joinGroup(instance, 0, generation);
      this.runBindSelfTest(instance, generation);
      this.sendAnnounce();
      Lg.i(LOG_TAG + ': UDP reader bound to 0.0.0.0:' + MULTICAST_PORT);
    }).catch(async (error: BusinessError): Promise<void> => {
      if (!this.started || generation !== this.generation) {
        return;
      }
      this.bound = false;
      this.healthHintValue = '多播接收不可用（UDP 53317 初始化失败，正在重试；可手动连接）';
      Lg.w(LOG_TAG + ': UDP setup/close failed code=' + error.code + ' message=' + error.message);
      await this.closeSocket().catch((closeError: BusinessError): void => {
        Lg.w(LOG_TAG + ': failed attempt close failed; retaining ownership code=' + closeError.code);
      });
      this.scheduleRetry(generation);
    });
  }

  private runBindSelfTest(instance: socket.MulticastSocket, generation: number): void {
    this.selfTestSeen = false;
    this.selfTestToken = JSON.stringify({ cashmereSelfTest: SecurityUtils.createToken() });
    // Arm the deadline before send: a hung send must not suppress the check.
    this.selfTestTimer = setTimeout((): void => {
      this.selfTestTimer = -1;
      if (!this.isCurrent(instance, generation)) {
        return;
      }
      if (this.selfTestSeen) {
        this.healthHintValue = '';
        Lg.i(LOG_TAG + ': UDP 53317 loopback receive check passed');
        return;
      }
      this.healthHintValue = '多播接收不可用（UDP 53317 回环自检未通过；可手动连接）';
      Lg.w(LOG_TAG + ': loopback check failed; port ownership/network cause is unverified');
      this.scheduleRetry(generation);
    }, SELF_TEST_WAIT_MS);
    instance.send({
      data: this.selfTestToken,
      address: { address: '127.0.0.1', port: MULTICAST_PORT, family: 1 }
    }).catch((error: BusinessError): void => {
      Lg.w(LOG_TAG + ': loopback probe send failed code=' + error.code);
    });
  }

  private scheduleRetry(generation: number): void {
    if (this.retryTimer !== -1 || !this.started || generation !== this.generation) {
      return;
    }
    if (this.openAttempts >= 1) {
      this.healthHintValue = '多播接收不可用（UDP 53317 重试失败；可手动连接或重新开启接收）';
      return;
    }
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      if (!this.started || generation !== this.generation) {
        return;
      }
      this.openAttempts += 1;
      this.bound = false;
      this.groupJoined = false;
      this.openSocket();
    }, 600);
  }

  /**
   * 在热点网卡上补加组播组（内核级成员关系）。
   *
   * `MulticastSocket.addMembership()` 只作用于系统默认网络，开热点时默认网络是蜂窝，
   * 热点网卡上压根没加组 —— 连着热点的电脑发来的 announce 会被内核直接丢掉，
   * 手机因此永远看不到对端。走 native 显式指定 `imr_interface` 就能把该网卡也加进组。
   */
  private joinGroupOnHotspotInterfaces(): void {
    if (this.hotspotJoined) {
      return;
    }
    if (!this.ifaceDumped) {
      this.ifaceDumped = true;
      NetDiscoveryNative.dumpInterfaces('discovery start');
    }
    const interfaces = NetDiscoveryNative.hotspotInterfaces();
    if (interfaces.length === 0) {
      Lg.i(LOG_TAG + ': no hotspot interface found; hotspot announce/relay skipped');
      return;
    }
    let joined = false;
    for (const iface of interfaces) {
      // 收包中继：把热点网卡上收到的 announce 搬到回环口，ArkTS socket 才看得到。
      // 这是「手机搜不到对端」的关键一环 —— 只加组不够，收包的 socket 是 ArkTS 那个。
      if (NetDiscoveryNative.startRelay(iface.address, MULTICAST_PORT, MULTICAST_GROUP)) {
        Lg.i(LOG_TAG + ': multicast relay started on hotspot iface ' + iface.name
          + ' (' + iface.address + ') -> loopback:' + MULTICAST_PORT);
      }
      if (NetDiscoveryNative.joinMulticastOn(MULTICAST_GROUP, MULTICAST_PORT, iface.address)) {
        joined = true;
        Lg.i(LOG_TAG + ': joined ' + MULTICAST_GROUP + ' on hotspot iface ' + iface.name
          + ' (' + iface.address + ')');
      }
      // mDNS 组一并加上：`@ohos.net.mdns` 的系统守护进程只在默认网络上加组，热点网卡上
      // 没有成员关系，从 ap0 进来的 224.0.0.251 查询内核不投递给它。
      // 注意：目前这一步只建立了内核级 IGMP 成员关系（native socket 收包但不读），
      // 让 ap0 上的组播能被内核接收；要真正把 mDNS 查询变成 Nearby Sharing 的可见性，
      // 还需要 native 收包 + 上抛解析这一步（尚未实现）。失败只记日志，不影响组播链路。
      NetDiscoveryNative.joinMulticastOn(MDNS_GROUP, MDNS_PORT, iface.address);
    }
    this.hotspotJoined = joined;
  }

  private joinGroup(instance: socket.MulticastSocket, attempt: number, generation: number): void {
    if (!this.isCurrent(instance, generation)) {
      return;
    }
    const withPort: socket.NetAddress = { address: MULTICAST_GROUP, port: MULTICAST_PORT, family: 1 };
    const withFamily: socket.NetAddress = { address: MULTICAST_GROUP, family: 1 };
    const bare: socket.NetAddress = { address: MULTICAST_GROUP };
    const variants: socket.NetAddress[] = [withPort, withFamily, bare];
    if (attempt >= variants.length) {
      Lg.w(LOG_TAG + ': all addMembership variants failed; relying on broadcast/unicast paths');
      return;
    }
    instance.addMembership(variants[attempt]).then((): void => {
      if (!this.isCurrent(instance, generation)) {
        return;
      }
      this.groupJoined = true;
      this.joinGroupOnHotspotInterfaces();
      Lg.i(LOG_TAG + ': joined multicast group ' + MULTICAST_GROUP + ' (variant ' + attempt + ')');
    }).catch((error: BusinessError): void => {
      if (!this.isCurrent(instance, generation)) {
        return;
      }
      if (error.code === ERR_ADDRESS_IN_USE) {
        this.groupJoined = true;
        this.joinGroupOnHotspotInterfaces();
        Lg.i(LOG_TAG + ': multicast group already joined (2301098 confirms membership active)');
        return;
      }
      Lg.w(LOG_TAG + ': addMembership variant ' + attempt + ' failed code=' + error.code + ' message=' + error.message);
      this.joinGroup(instance, attempt + 1, generation);
    });
  }

  stop(): void {
    this.started = false;
    this.generation += 1;
    this.bound = false;
    this.groupJoined = false;
    this.advertising = false;
    this.healthHintValue = '';
    this.stopAnnounceTimer();
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    if (this.selfTestTimer !== -1) {
      clearTimeout(this.selfTestTimer);
      this.selfTestTimer = -1;
    }
    NetDiscoveryNative.stopRelay();
    NetDiscoveryNative.leaveAllMulticast();
    this.hotspotJoined = false;
    this.socketOperation = this.socketOperation.then((): Promise<void> => this.closeSocket())
      .catch((error: BusinessError): void => {
        Lg.w(LOG_TAG + ': socket close failed; retaining ownership code=' + error.code);
      });
  }

  setAdvertising(visible: boolean): void {
    this.advertising = visible;
    this.stopAnnounceTimer();
    if (visible && this.started) {
      this.startAnnounceTimer();
    }
  }

  private startAnnounceTimer(): void {
    this.stopAnnounceTimer();
    this.sendAnnounce();
    this.announceTimer = setInterval((): void => this.sendAnnounce(), ANNOUNCE_INTERVAL_MS);
  }

  private stopAnnounceTimer(): void {
    if (this.announceTimer !== -1) {
      clearInterval(this.announceTimer);
      this.announceTimer = -1;
    }
  }

  setFingerprint(value: string): void {
    if (value.length > 0) {
      this.fingerprint = value;
    }
  }

  /** 判断 IPv4 是否属于 VPN / 容器类网段（172.16-172.31、100.64-100.127），此类地址不当作真实对端。 */
  private isVpnSegment(addr: string): boolean {
    if (addr.length === 0 || addr.indexOf('.') < 0) {
      return false;
    }
    const parts: string[] = addr.split('.');
    if (parts.length !== 4) {
      return false;
    }
    const octet1: number = Number(parts[0]);
    const octet2: number = Number(parts[1]);
    if (octet1 === 172 && octet2 >= 16 && octet2 <= 31) {
      return true;
    }
    if (octet1 === 100 && octet2 >= 64 && octet2 <= 127) {
      return true;
    }
    return false;
  }

  setHttps(value: boolean): void {
    this.httpsEnabled = value;
  }

  setPort(value: number): void {
    if (value > 0) {
      this.announcePort = value;
    }
  }

  /** 立即广播一次 announce，促使在线的对端马上回包（而不是等下一个 5s 定时）。 */
  announceNow(): void {
    this.sendAnnounce();
  }

  private buildAnnounce(announce: boolean = true): string {
    const settings = SettingsStore.current();
    const payload: LocalSendAnnounce = {
      alias: settings.alias,
      version: '2.0',
      deviceModel: deviceInfo.marketName,
      deviceType: 'mobile',
      fingerprint: this.fingerprint,
      port: this.announcePort,
      protocol: this.httpsEnabled ? 'https' : 'http',
      download: false,
      announcement: announce,
      announce
    };
    return JSON.stringify(payload);
  }

  private buildTargets(): string[] {
    const targets: string[] = [MULTICAST_GROUP, LIMITED_BROADCAST];
    const localAddress = this.getLocalAddress();
    const parts = localAddress.split('.');
    if (parts.length === 4) {
      targets.push(parts[0] + '.' + parts[1] + '.' + parts[2] + '.255');
    }
    return targets;
  }

  private sendAnnounce(): void {
    if (!this.started || !this.advertising) {
      return;
    }
    // 热点补发不依赖 OHOS socket 是否绑上：native 用的是自己那套独立 socket。
    // 真机上 53317 被残留 socket 占住时 `bound` 会是 false，若在这里提前返回，
    // 热点网卡上的 announce 也跟着一份都发不出去 —— 那正是「怎么都传不出去」的来源。
    this.sendAnnounceOnHotspotInterfaces(this.buildAnnounce());
    const instance = this.multicastSocket;
    if (instance === undefined || !this.bound) {
      return;
    }
    const data = this.buildAnnounce();
    const targets = this.buildTargets();
    for (const target of targets) {
      instance.send({
        data,
        address: { address: target, port: MULTICAST_PORT, family: 1 }
      }).then((): void => {
        if (!this.announcedOnce) {
          this.announcedOnce = true;
          Lg.i(LOG_TAG + ': announce sent to ' + targets.join(', '));
        }
      }).catch((error: BusinessError): void => {
        if (!this.failedTargets.has(target)) {
          this.failedTargets.add(target);
          Lg.w(LOG_TAG + ': announce to ' + target + ' failed code=' + error.code + ' message=' + error.message);
        }
      });
    }
  }

  /**
   * 热点网卡补发 announce。
   *
   * 开热点时系统默认数据网络仍是蜂窝，上面 `instance.send()` 发的包全部按默认路由走蜂窝出去，
   * 连着热点的对端一个都收不到；`buildTargets()` 用 `getLocalAddress()`（此时是蜂窝地址）算出的
   * 定向广播也是蜂窝网段，同样白搭。
   *
   * 这里改走 native：把包 pin 到热点接口地址（`bind()` + `IP_MULTICAST_IF`），再往组播地址和
   * 该接口的定向广播各发一份 —— 这样 announce 才是真的从热点网卡出去，对端 LocalSend 收到后
   * 会回包/请求 info，设备列表也就有了。native 不可用时静默跳过，不影响常规链路。
   */
  private sendAnnounceOnHotspotInterfaces(data: string): void {
    const interfaces = NetDiscoveryNative.hotspotInterfaces();
    if (interfaces.length === 0) {
      return;
    }
    for (const iface of interfaces) {
      const broadcast = NetDiscoveryNative.broadcastOf(iface.address);
      if (broadcast.length === 0) {
        continue;
      }
      const toGroup: boolean = NetDiscoveryNative.send(MULTICAST_GROUP, MULTICAST_PORT, iface.address, data);
      const toBroadcast: boolean = NetDiscoveryNative.send(broadcast, MULTICAST_PORT, iface.address, data);
      if (toGroup || toBroadcast) {
        Lg.i(LOG_TAG + ': announce via hotspot iface ' + iface.name + ' (' + iface.address + ') -> '
          + MULTICAST_GROUP + ' + ' + broadcast);
      } else {
        Lg.w(LOG_TAG + ': announce via hotspot iface ' + iface.name + ' (' + iface.address + ') failed');
      }
    }
  }

  private handleMessage(value: socket.SocketMessageInfo): void {
    const text = ByteUtils.decodeText(new Uint8Array(value.message));
    this.handleDatagram(text, value.remoteInfo.address, value.remoteInfo.port);
  }

  /**
   * 处理一个报文。`sender` 可能是本机回环（native 中继注入），此时要先解出真实源地址。
   *
   * 中继封装形如 `{"__relay":true,"from":"192.0.2.10","port":53317,"data":"{...原始 announce...}"}`，
   * 由 `net_discovery.cpp` 的 relay 线程注入 —— 它把热点网卡上收到的组播搬到回环口，
   * 因为 ArkTS socket 只在默认网络加了组，热点上的包本来投递不到它。
   * 解包后 `from` 才是真正的对端地址，后面所有过滤/回包都用它。
   */
  private handleDatagram(raw: string, sender: string, senderPort: number): void {
    let text: string = raw;
    let from: string = sender;
    let fromPort: number = senderPort;
    if (raw.indexOf('"__relay"') >= 0) {
      try {
        const envelope: RelayEnvelope = JSON.parse(raw) as RelayEnvelope;
        if (envelope !== null && envelope.__relay === true && typeof envelope.from === 'string' && typeof envelope.data === 'string') {
          text = envelope.data;
          from = envelope.from;
          fromPort = typeof envelope.port === 'number' && Number.isInteger(envelope.port) && envelope.port > 0 && envelope.port <= 65535 ? envelope.port : senderPort;
        }
      } catch (error) {
        // 不是合法中继封装：按普通报文处理。
      }
    }
    if (text.indexOf('cashmereSelfTest') >= 0) {
      return;
    }
    if (!this.isOwnAddress(from)) {
      Lg.i(LOG_TAG + ': datagram from ' + from + ':' + fromPort + ' len=' + text.length);
    }
    let info: LocalSendAnnounce;
    try {
      info = JSON.parse(text) as LocalSendAnnounce;
    } catch (error) {
      Lg.w(LOG_TAG + ': non-LocalSend datagram from ' + from + ': ' + text.substring(0, 48));
      return;
    }
    if (info === null || typeof info !== 'object' || typeof info.alias !== 'string'
      || (info.protocol !== undefined && typeof info.protocol !== 'string')) {
      return;
    }
    if (this.isOwnAddress(from)) {
      return;
    }
    // 单独拦截 VPN / 容器类网段：这类源地址是本机虚拟网关/隧道，不代表真实对端，直接跳过。
    if (this.isVpnSegment(from)) {
      return;
    }
    // 本机过滤：源地址是本机任一网卡地址（含 VPN/容器等非默认网卡）→ 已在上面丢弃。
    // fingerprint 是本机唯一身份：当源地址未枚举到（如 192.0.2.10）但 fingerprint 与本机
    // 一致时，同样视为本机丢弃（双端非空才比较，避免空指纹误伤对端）。
    if (info.fingerprint !== undefined && info.fingerprint.length > 0
      && info.fingerprint === this.fingerprint) {
      return;
    }
    const port = typeof info.port === 'number' && Number.isInteger(info.port) && info.port > 0 && info.port <= 65535 ? info.port : fromPort;
    const alias = info.alias !== undefined && info.alias.length > 0 ? info.alias : from;
    const model = typeof info.deviceModel === 'string' && info.deviceModel.length > 0 ? info.deviceModel : 'LocalSend device';
    const protocolText = info.protocol !== undefined ? info.protocol.toLowerCase() : '';
    Lg.i(LOG_TAG + ': LocalSend peer ' + alias + ' at ' + from + ':' + port
      + ' protocol=' + (info.protocol !== undefined ? info.protocol : 'none')
      + ' announce=' + (info.announce === true || info.announcement === true));
    this.emitDevice({
      id: 'localsend:' + from + ':' + port,
      name: alias,
      model,
      protocol: 'localsend',
      address: from,
      port,
      https: protocolText !== 'http',
      fingerprint: typeof info.fingerprint === 'string' ? info.fingerprint : '',
      source: 'lan'
    });
    // 收到对端 announce 就单播回包，让对端（尤其官方 LocalSend）无需手动刷新即可看到本机。
    // 回包必须限频：对端收到回包（也是 announce）可能再次发 announce，若每个包都回会形成
    // 两端互相放大的回包风暴（真机 2026-09-20：OPPO 对端 100ms 内互飙十几次 register/announce）。
    if (this.shouldReplyTo(from)) {
      this.replyTo(from, port);
    }
  }

  /**
   * 是否应该向 `address` 单播回包：同一目标 30s 内最多回一次。
   *
   * 不沿用 emit 的 3s 节流是因为对端自己也会周期 announce（5s），3s 粒度仍然可能与对端
   * 形成 5s 级的共振循环；30s 足以让新上线的对端看到本机（本机的组播 announce 本来也
   * 每 5s 就到它那儿一趟，回包只是兜底）。
   */
  private shouldReplyTo(address: string): boolean {
    const now = Date.now();
    const last = this.lastReplyAt.get(address);
    if (last !== undefined && now - last < 30000) {
      return false;
    }
    this.lastReplyAt.set(address, now);
    if (this.lastReplyAt.size > 64) {
      // 粗略防膨胀：超限就整体清空（回包只是兜底，丢了无关紧要）。
      this.lastReplyAt.clear();
      this.lastReplyAt.set(address, now);
    }
    return true;
  }

  /**
   * 单播回包。热点网段内的对端必须走 native 从热点网卡发出 —— 走 `@ohos.net.socket`
   * 会按默认路由（蜂窝）出去，对端根本收不到，于是「电脑看不到手机」。
   */
  private replyTo(address: string, port: number): void {
    const data: string = this.buildAnnounce(false);
    const iface: string = NetDiscoveryNative.ifaceOnSameSubnet(address);
    if (iface.length > 0 && NetDiscoveryNative.send(address, port, iface, data)) {
      Lg.i(LOG_TAG + ': reply to ' + address + ':' + port + ' via hotspot iface ' + iface);
      return;
    }
    const instance = this.multicastSocket;
    if (instance === undefined) {
      return;
    }
    instance.send({
      data,
      address: { address, port, family: 1 }
    }).catch((error: BusinessError): void => {
      Lg.w(LOG_TAG + ': reply to ' + address + ':' + port + ' failed code=' + error.code);
    });
  }
}
