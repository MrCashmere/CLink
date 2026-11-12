import { LogCapture as Lg } from '../common/LogCapture';
import netConnection from '@ohos.net.connection';

// 移动热点（本机作为 AP / 共享网络出口）常见的默认网关地址。
// 开热点时「本机在热点网段的地址」就是这个 .1；而蜂窝数据的地址同样落在私有段里
// （典型如 10.65.x.x 运营商内网），如果不显式优先挑网关，
// getLocalIpv4() 会按枚举顺序先撞上蜂窝地址，把 192.0.2.10 当成局域网地址显示出去，
// 而连着热点的电脑在 192.168.43.0/24 网段，永远连不到这个地址。
export const HOTSPOT_GATEWAY_CANDIDATES: string[] = [
  '192.168.43.1',   // Android / HarmonyOS 系统个人热点默认
  '192.168.137.1',  // Windows「移动热点」（电脑开热点、手机接入时的对侧网关）
  '172.20.10.1',    // iOS 个人热点
  '192.168.8.1',    // 华为 / 荣耀部分机型
  '192.168.42.1',   // USB 网络共享（rndis）
  '192.168.49.1',   // Wi-Fi Direct / Wi-Fi 直连（本机为 Group Owner）
  '192.168.123.1',  // 部分小米 / 中兴机型
  '192.168.232.1'   // 部分 OPPO / realme 机型
];

/** 该地址是否是一个已知的热点/共享网络网关地址。 */
export function isHotspotGatewayAddress(addr: string): boolean {
  return addr.length > 0 && HOTSPOT_GATEWAY_CANDIDATES.indexOf(addr) >= 0;
}

/** 私有网段里以 .1 结尾的地址 —— 未知型号热点的网关也大多长这样。 */
export function looksLikeGatewayAddress(addr: string): boolean {
  if (addr.length === 0 || !addr.endsWith('.1')) {
    return false;
  }
  return addr.startsWith('192.168.') || addr.startsWith('10.') || addr.startsWith('172.');
}

// Returns the device's LAN IPv4 (the interface the home page labels as the
// normal IP), preferring 192.168.* / 10.* so that virtual gateways created by
// third-party virtual networks (e.g. 卓易通's anco adapter on 172.17.*) are not
// returned. Falls back to the first IPv4 on the default network, then ''.
export function getLocalIpv4(): string {
  // Enumerate every active network (not just the default one). Inside 卓易通's
  // container network namespace the default net can be a virtual gateway
  // (192.0.2.10), so reading only the default network returns the container IP
  // and peers can't reach the app. Prefer the real 192.168.0.x / 10.x WiFi LAN
  // address and skip container/TUN/link-local ranges.
  const candidates: string[] = [];
  const isUsableLanIpv4 = (addr: string): boolean => {
    if (addr.length === 0 || addr.indexOf('.') < 0) {
      return false;
    }
    if (addr.startsWith('127.') || addr.startsWith('169.254.') || addr.startsWith('0.')) {
      return false;
    }
    const octet1: number = Number(addr.split('.')[0]);
    // 172.16.0.0/12 (172.16..172.31) is used by container bridges / VPN TUNs.
    if (octet1 === 172) {
      const octet2: number = Number(addr.split('.')[1]);
      if (octet2 >= 16 && octet2 <= 31) {
        return false;
      }
      return true;
    }
    if (octet1 === 10) {
      return true;
    }
    return octet1 === 192;
  };
  try {
    const handles: netConnection.NetHandle[] = netConnection.getAllNetsSync();
    for (const handle of handles) {
      const properties: netConnection.ConnectionProperties = netConnection.getConnectionPropertiesSync(handle);
      const links: netConnection.LinkAddress[] = properties.linkAddresses;
      for (const link of links) {
        const addr: string = link.address.address;
        if (isUsableLanIpv4(addr)) {
          candidates.push(addr);
        }
      }
    }
  } catch (error) {
    Lg.w('[NETADDR] local IPv4 lookup failed: ' + JSON.stringify(error));
  }
  if (candidates.length === 0) {
    return '';
  }
  // 优先顺序按「对端能不能连上」排，不按枚举顺序：
  // 1) 已知热点网关 —— 开热点时本机在热点网段的地址，连着热点的电脑就是靠它访问本机。
  //    必须压过蜂窝地址，否则热点场景下会返回 10.x.x.x 这种电脑根本不可达的地址。
  for (const addr of candidates) {
    if (isHotspotGatewayAddress(addr)) {
      return addr;
    }
  }
  // 2) 私有网段里的 .1 —— 型号未收录的热点 / 路由网关。
  for (const addr of candidates) {
    if (looksLikeGatewayAddress(addr)) {
      return addr;
    }
  }
  // 3) 常规 Wi-Fi 局域网。
  for (const addr of candidates) {
    if (addr.startsWith('192.168.')) {
      return addr;
    }
  }
  // 4) 兜底（含蜂窝 10.x —— 开热点时它对热点侧不可达，只能排最后）。
  return candidates[0];
}

/** 枚举结果里所有疑似热点网关的地址（已知网段优先，其余按 .1 特征补上）。 */
export function localHotspotGateways(): string[] {
  const out: string[] = [];
  const all = getLocalIpv4Addresses();
  for (const addr of all) {
    if (isHotspotGatewayAddress(addr) && out.indexOf(addr) < 0) {
      out.push(addr);
    }
  }
  for (const addr of all) {
    if (looksLikeGatewayAddress(addr) && out.indexOf(addr) < 0) {
      out.push(addr);
    }
  }
  return out;
}

// Every IPv4 address currently assigned to this device, across *all* networks -
// including container / VPN / hotspot adapters that getLocalIpv4() deliberately
// filters out. Self-discovery filtering needs the unfiltered list: our own mDNS
// advertisement comes back once per local interface, and the copy that arrives
// from 卓易通's virtual gateway (192.0.2.10) is exactly the one that used to fill
// the device list with "羊绒互传" entries. Cached briefly because this runs on
// every discovery callback.
let localAddressCache: string[] = [];
let localAddressCacheAt = 0;
const LOCAL_ADDRESS_CACHE_MS = 5000;

export function getLocalIpv4Addresses(): string[] {
  const now = Date.now();
  if (localAddressCache.length > 0 && now - localAddressCacheAt < LOCAL_ADDRESS_CACHE_MS) {
    return localAddressCache;
  }
  const out: string[] = [];
  try {
    const handles: netConnection.NetHandle[] = netConnection.getAllNetsSync();
    for (const handle of handles) {
      const properties: netConnection.ConnectionProperties = netConnection.getConnectionPropertiesSync(handle);
      const links: netConnection.LinkAddress[] = properties.linkAddresses;
      for (const link of links) {
        const addr: string = link.address.address;
        if (addr.length === 0 || addr.indexOf('.') < 0) {
          continue;
        }
        if (addr.startsWith('127.') || addr.startsWith('169.254.') || addr.startsWith('0.')) {
          continue;
        }
        if (out.indexOf(addr) < 0) {
          out.push(addr);
        }
      }
    }
  } catch (error) {
    Lg.w('[NETADDR] local IPv4 list failed: ' + JSON.stringify(error));
  }
  localAddressCache = out;
  localAddressCacheAt = now;
  return out;
}

// True when `addr` is one of this device's own IPv4 addresses, i.e. a record that
// came back from ourselves rather than from a peer.
export function isLocalIpv4Address(addr: string): boolean {
  if (addr.length === 0) {
    return false;
  }
  return getLocalIpv4Addresses().indexOf(addr) >= 0;
}

// True for 卓易通's virtual network (172.17.0.0/16, observed gateways 192.0.2.10 /
// 192.0.2.10). Inside the app's own network namespace that address is the
// container gateway, not a local interface address, so isLocalIpv4Address() does
// not recognise it - yet our own mDNS advertisement is echoed back from it and
// used to fill the Quick Share list with our own phone. Records arriving from it
// are always our own (or a duplicate of them), never a real peer's. Kept narrow
// on purpose: 172.20.10.x (iPhone hotspot) and other 172.16/12 peers stay visible.
export function isVirtualGatewayAddress(addr: string): boolean {
  if (addr.length === 0) {
    return false;
  }
  const octets = addr.split('.');
  if (octets.length !== 4) {
    return false;
  }
  return octets[0] === '172' && octets[1] === '17';
}
