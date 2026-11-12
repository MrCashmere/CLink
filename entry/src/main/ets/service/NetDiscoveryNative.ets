import { LogCapture as Lg } from '../common/LogCapture';
import { isHotspotGatewayAddress, looksLikeGatewayAddress } from '../common/NetAddress';
import netNative from 'libnet_discovery.so';

export interface NetInterfaceInfo {
  readonly name: string;
  readonly address: string;
}

/**
 * 已知的移动热点 / 网络共享接口名。不同 SoC 与机型差异很大（ap0 / swlan0 / softap0 …），
 * 这里用「包含匹配」而不是全等，覆盖 `ap0`、`swlan0`、`softap0` 及其变体。
 */
const HOTSPOT_IFACE_NAMES: string[] = [
  'ap0', 'ap1', 'swlan0', 'swlan1', 'softap0', 'wlan-softap', 'rndis0', 'usb0', 'bnep0'
];

const CACHE_TTL_MS: number = 5000;

/**
 * 热点/共享网卡上的发现能力（`libnet_discovery.so`，见 `cpp/net_discovery.cpp`）。
 *
 * 为什么需要它：开热点时系统默认数据网络仍是蜂窝，`@ohos.net.socket` 发出的 UDP 一律按
 * 默认路由走蜂窝出去，连着热点的对端一个都收不到；而 `getAllNetsSync()` 又不把 SoftAP
 * 暴露给三方应用，连 `NetHandle.bindSocket()` 都无从下手。
 *
 * native 层（POSIX）不受这套应用网络策略约束：`getifaddrs()` 能枚举到 ap0 及其地址，
 * 把 socket `bind()` 到该地址再配 `IP_MULTICAST_IF`，就能把包从热点网卡发出去。
 * 本模块只是那两个能力的 ArkTS 外壳，native 不可用时全部静默降级为空/失败，不影响主流程。
 *
 * ⚠️ 验证状态（2026-09-20）：**仅过编译，未真机验证**。
 * 未证实的前提：native 能否枚举到热点网卡、`IP_ADD_MEMBERSHIP` 是否被允许、
 * 绑定组播地址是否被允许、中继注入的回环包能否被 ArkTS socket 收到。
 * 详见 `docs/HOTSPOT_SHARING.md` 顶部「验证状态」一节。
 */
export class NetDiscoveryNative {

  private static cache: NetInterfaceInfo[] = [];
  private static cacheAt: number = 0;

  /** 本机所有 IPv4 接口（native 枚举，含系统不给应用看的热点网卡）。 */
  static interfaces(): NetInterfaceInfo[] {
    const now: number = Date.now();
    if (NetDiscoveryNative.cache.length > 0 && now - NetDiscoveryNative.cacheAt < CACHE_TTL_MS) {
      return NetDiscoveryNative.cache;
    }
    let out: NetInterfaceInfo[] = [];
    try {
      const raw: NetInterfaceInfo[] = netNative.getInterfaces() as NetInterfaceInfo[];
      if (raw !== undefined && raw.length > 0) {
        out = raw;
      }
    } catch (error) {
      Lg.w('[NETDISC] getInterfaces unavailable: ' + JSON.stringify(error));
    }
    NetDiscoveryNative.cache = out;
    NetDiscoveryNative.cacheAt = now;
    return out;
  }

  /** 其中疑似热点 / 共享网络的接口。 */
  static hotspotInterfaces(): NetInterfaceInfo[] {
    const all: NetInterfaceInfo[] = NetDiscoveryNative.interfaces();
    const byName: NetInterfaceInfo[] = [];
    const byGateway: NetInterfaceInfo[] = [];
    for (const iface of all) {
      if (NetDiscoveryNative.isHotspotInterface(iface)) {
        byName.push(iface);
      } else if (looksLikeGatewayAddress(iface.address)) {
        // 接口名没收录、但地址是私有段 .1 —— 型号未收录的热点大多长这样。
        // 只在名字完全没命中时才用，避免普通 Wi-Fi 下误判（代价只是多一份 relay 副本，
        // 设备列表按 `ip:port` 去重，不会重复出现）。
        byGateway.push(iface);
      }
    }
    if (byName.length > 0) {
      return byName;
    }
    if (byGateway.length > 0) {
      Lg.i('[NETDISC] no known hotspot iface name; falling back to gateway-shaped addresses: '
        + byGateway.map((i: NetInterfaceInfo): string => i.name + '/' + i.address).join(', '));
    }
    return byGateway;
  }

  /** 接口名命中已知热点名，或地址正好是已知热点网关（.1）。 */
  static isHotspotInterface(iface: NetInterfaceInfo): boolean {
    const name: string = iface.name.toLowerCase();
    for (const candidate of HOTSPOT_IFACE_NAMES) {
      if (name.indexOf(candidate) >= 0) {
        return true;
      }
    }
    return isHotspotGatewayAddress(iface.address);
  }

  /**
   * 把接口清单打进日志（排障用）。热点下搜不到对端时，第一件事就是看这里：
   * `hotspot=` 后面有没有东西 —— 空说明 native 没认出热点网卡，后面一切都免谈。
   */
  static dumpInterfaces(tag: string): void {
    const all: NetInterfaceInfo[] = NetDiscoveryNative.interfaces();
    const hot: NetInterfaceInfo[] = NetDiscoveryNative.hotspotInterfaces();
    const fmt = (i: NetInterfaceInfo): string => i.name + '/' + i.address;
    Lg.i('[NETDISC] ' + tag + ' ifaces=[' + all.map(fmt).join(', ') + '] hotspot=['
      + hot.map(fmt).join(', ') + ']');
  }

  /** 与 `address` 同 /24 的热点接口地址（用于单播回包选出口网卡）；没有则空串。 */
  static ifaceOnSameSubnet(address: string): string {
    for (const iface of NetDiscoveryNative.hotspotInterfaces()) {
      if (NetDiscoveryNative.sameSubnet(iface.address, address)) {
        return iface.address;
      }
    }
    return '';
  }

  /** 两个地址是否同 /24。 */
  static sameSubnet(a: string, b: string): boolean {
    const pa: string[] = a.split('.');
    const pb: string[] = b.split('.');
    if (pa.length !== 4 || pb.length !== 4) {
      return false;
    }
    return pa[0] === pb[0] && pa[1] === pb[1] && pa[2] === pb[2];
  }

  /**
   * 从指定接口地址发出一个 UDP 包。
   *
   * @param target  目的地：组播地址（224.0.0.167）或定向广播（192.0.2.10）
   * @param port    目的端口
   * @param ifaceAddress 出口接口的本机地址（决定走哪张网卡）
   * @param data    要发的文本（announce JSON）
   */
  static send(target: string, port: number, ifaceAddress: string, data: string): boolean {
    try {
      const ok: boolean = netNative.sendDatagram(target, port, ifaceAddress, data) as boolean;
      return ok === true;
    } catch (error) {
      Lg.w('[NETDISC] sendDatagram failed: ' + JSON.stringify(error));
      return false;
    }
  }

  /**
   * 在指定的热点接口上加入组播组（内核级 IGMP 成员关系）。
   *
   * `MulticastSocket` 的加组只跟着默认网络走，开热点时热点网卡上并没有加组，
   * 于是电脑发来的 announce 会被内核直接丢掉 —— 手机永远看不到对端。
   * 在 native 层显式指定 `imr_interface` 就能把该网卡也加进组，对端 announce 才收得到。
   */
  static joinMulticastOn(group: string, port: number, ifaceAddress: string): boolean {
    try {
      const ok: boolean = netNative.joinMulticastOn(group, port, ifaceAddress) as boolean;
      return ok === true;
    } catch (error) {
      Lg.w('[NETDISC] joinMulticastOn failed: ' + JSON.stringify(error));
      return false;
    }
  }

  /**
   * 启动收包中继：在热点接口上收 `group` 的组播包，再以本机回环单播注入 `127.0.0.1:port`。
   *
   * 为什么需要它：ArkTS 的 `MulticastSocket` 只在**默认网络**上加组，热点网卡上收到的
   * announce 永远投递不到它 —— 这正是「手机看不到电脑」的根因。中继把 ap0 上的包搬到
   * 回环口，ArkTS socket 就能收到了，而它自己的绑定/加组行为完全不变。
   *
   * native 侧监听 socket 绑的是**组播地址**而不是 0.0.0.0，这样它不参与单播查找，
   * 对端单播回包仍然只落在 ArkTS socket 上（不会抢）；且只中继来自热点网段的包，
   * 天然避开自己注入的那份回环副本。
   */
  static startRelay(ifaceAddress: string, port: number, group: string): boolean {
    try {
      const ok: boolean = netNative.startRelay(ifaceAddress, port, group) as boolean;
      return ok === true;
    } catch (error) {
      Lg.w('[NETDISC] startRelay failed: ' + JSON.stringify(error));
      return false;
    }
  }

  /** 停止收包中继（停服时调用）。 */
  static stopRelay(): void {
    try {
      netNative.stopRelay();
    } catch (error) {
      Lg.w('[NETDISC] stopRelay failed: ' + JSON.stringify(error));
    }
  }

  /** 释放全部 native 组播成员关系（停服 / 重建 socket 时调用）。 */
  static leaveAllMulticast(): void {
    try {
      netNative.leaveAllMulticast();
    } catch (error) {
      Lg.w('[NETDISC] leaveAllMulticast failed: ' + JSON.stringify(error));
    }
  }

  /** 接口的定向广播地址（x.x.x.255），地址不合法时返回空串。 */
  static broadcastOf(address: string): string {
    const parts: string[] = address.split('.');
    if (parts.length !== 4) {
      return '';
    }
    return parts[0] + '.' + parts[1] + '.' + parts[2] + '.255';
  }
}
