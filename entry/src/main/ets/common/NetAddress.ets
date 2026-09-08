import { LogCapture as Lg } from '../common/LogCapture';
import netConnection from '@ohos.net.connection';

// Returns the device's LAN IPv4 (the interface the home page labels as the
// normal IP), preferring 192.168.* / 10.* so that virtual gateways created by
// third-party virtual networks (e.g. 卓易通's anco adapter on 172.17.*) are not
// returned. Falls back to the first IPv4 on the default network, then ''.
export function getLocalIpv4(): string {
  // Enumerate every active network (not just the default one). Inside 卓易通's
  // container network namespace the default net can be a virtual gateway
  // (172.17.1.1), so reading only the default network returns the container IP
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
  for (const addr of candidates) {
    if (addr.startsWith('192.168.') || addr.startsWith('10.')) {
      return addr;
    }
  }
  return candidates[0];
}
