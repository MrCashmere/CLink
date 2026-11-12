import { LogCapture as Lg } from '../common/LogCapture';
import { common } from '@kit.AbilityKit';
import netConnection from '@ohos.net.connection';
import mdns from '@ohos.net.mdns';
import deviceInfo from '@ohos.deviceInfo';
import { BusinessError } from '@kit.BasicServicesKit';
import { ByteUtils } from '../common/ByteUtils';
import { SecurityUtils } from '../common/SecurityUtils';
import { SettingsStore } from '../common/SettingsStore';
import { DeviceEndpoint } from '../model/TransferModels';
import { getLocalIpv4, isLocalIpv4Address } from '../common/NetAddress';
import { AdvertisementIdentity } from '../common/AdvertisementIdentity';
import { MulticastDiscovery } from './MulticastDiscovery';
import { NetDiscoveryNative } from './NetDiscoveryNative';
import { LocalSendSubnetScanner } from './LocalSendSubnetScanner';

type DeviceListener = (device: DeviceEndpoint) => void;

const LOG_TAG = '羊绒互传 LocalSend discovery';
const LOCALSEND_SERVICE_TYPE = '_localsend._tcp';
const LOCALSEND_PORT = 53317;
const OWN_SERVICE_PREFIX = 'yangrong-';
const EMIT_THROTTLE_MS = 3000;
const MAP_PRUNE_INTERVAL_MS = 60000;
const SEEN_TTL_MS = 300000;

// One advertised instance name per device, persisted across launches (see
// AdvertisementIdentity). The system mdns daemon keeps every registration alive
// beyond the app process - the device log showed 63 LocalSend registrations and
// 0 removals, which is what filled peers' lists with duplicate "羊绒互传" devices.
const MDNS_SERVICE_INSTANCE_DUPLICATED = 2204007;

export class LocalSendDiscovery {
  private readonly listeners: Set<DeviceListener> = new Set();
  private readonly seen: Map<string, number> = new Map();
  private readonly localAddresses: Set<string> = new Set();
  private readonly multicast: MulticastDiscovery;
  private readonly localSendSubnet: LocalSendSubnetScanner;

  private serviceActive = false;
  private scanning = false;
  private scanGeneration = 0;
  private advertisementGeneration = 0;
  private advertisementOperation: Promise<void> = Promise.resolve();
  private advertisedOnce = false;
  private advertising = false;
  private fingerprint: string = '';
  private httpsEnabled: boolean = false;
  private servicePort: number = LOCALSEND_PORT;
  private localAddress: string = '';
  private discoveryService?: mdns.DiscoveryService;
  private advertisedService?: mdns.LocalServiceInfo;
  private advertisedServiceName: string = '';
  private subnetScanTimer: number = -1;
  private pruneTimer: number = -1;

  private readonly context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
    this.multicast = new MulticastDiscovery((device: DeviceEndpoint): void => this.emit(device),
      (address: string): boolean => this.localAddresses.has(address),
      (): string => this.localAddress);
    // 子网扫描走 emitExternal（带本机指纹过滤）：热点网段扫描必然探到热点地址上的本机服务
    // （192.168.43.1:53317 = 自己），而 localAddresses（getAllNetsSync 枚举）看不到 SoftAP，
    // scanner 的地址自识别拦不住它 —— 只能靠指纹拦（2026-09-20 真机：自己以「羊绒互传」上屏）。
    this.localSendSubnet = new LocalSendSubnetScanner((device: DeviceEndpoint): void => this.emitExternal(device),
      (address: string): boolean => this.localAddresses.has(address), context);
  }

  addListener(listener: DeviceListener): void {
    this.listeners.add(listener);
  }

  /**
   * 非发现模块入口上报的对端（HTTP 服务端把 register / send-request 信号转进来）。
   * 与组播/扫描路径共用去重与回调管线；本机指纹/本机地址过滤照旧，
   * 防止自连探测、本机访问自己的服务时把自己上屏。
   */
  emitExternal(device: DeviceEndpoint): void {
    if (this.fingerprint.length > 0 && device.fingerprint.length > 0
      && device.fingerprint === this.fingerprint) {
      Lg.i(LOG_TAG + ': ignored own device via fingerprint (http signal ' + device.address + ')');
      return;
    }
    if (this.isOwnService(device.name, device.address)) {
      return;
    }
    this.emit(device);
  }

  removeListener(listener: DeviceListener): void {
    this.listeners.delete(listener);
  }

  getLocalAddress(): string {
    return this.localAddress;
  }

  /** 发现链路的健康提示（空串 = 正常）；供页面显示「为什么搜不到对端」。 */
  statusHint(): string {
    return this.multicast.statusHint();
  }

  isVisible(): boolean {
    return this.advertising;
  }

  setFingerprint(value: string): void {
    if (value.length > 0) {
      this.fingerprint = value;
    }
    this.multicast.setFingerprint(value);
    if (this.advertising) {
      this.stopMdnsAdvertisement();
      this.startMdnsAdvertisement();
    }
  }

  setHttps(value: boolean): void {
    this.httpsEnabled = value;
    this.multicast.setHttps(value);
    if (this.advertising) {
      this.stopMdnsAdvertisement();
      this.startMdnsAdvertisement();
    }
  }

  setPort(value: number): void {
    if (value > 0) {
      this.servicePort = value;
      this.multicast.setPort(value);
      if (this.advertising) {
        this.stopMdnsAdvertisement();
        this.startMdnsAdvertisement();
      }
    }
  }

  setVisible(visible: boolean): void {
    if (visible === this.advertising) {
      return;
    }
    this.advertising = visible;
    if (!visible) {
      this.stopMdnsAdvertisement();
    }
    this.multicast.setAdvertising(visible);
    if (visible) {
      this.startMdnsAdvertisement();
    }
  }

  /** 全局 LocalSend 服务：只保持接收/广播能力，不主动扫描附近设备。 */
  startReceiveOnly(): void {
    if (this.serviceActive) {
      return;
    }
    this.serviceActive = true;
    this.refreshLocalNetwork();
    this.multicast.start();
    this.startPruneTimer();
    if (SettingsStore.current().alwaysVisible) {
      this.setVisible(true);
    }
    Lg.i(LOG_TAG + ': receive-only started (no active scanning)');
  }

  /** LocalSend 页面进入时启动专属扫描。 */
  startScan(): void {
    this.ensureService();
    if (this.scanning) {
      return;
    }
    this.scanning = true;
    this.scanGeneration += 1;
    this.refreshLocalNetwork();
    this.setVisible(SettingsStore.current().alwaysVisible);
    this.startMdnsDiscovery();
    this.startSubnetScan();
    // 立即广播一次 announce，让在线对端马上回包，卡片无需等下一个 5s 定时。
    this.multicast.announceNow();
    // 自连本机 IP:53317：区分“服务端没起来”还是“对端到不了本机”。
    const selfAddr = this.localAddress;
    if (selfAddr.length > 0) {
      void this.localSendSubnet.probeSelf(selfAddr, this.httpsEnabled).then((ok: boolean): void => {
        Lg.i(LOG_TAG + ': self-test ' + selfAddr + ':53317 -> '
          + (ok ? 'OK (LocalSend server listening)' : 'FAIL (server not reachable)'));
      });
    }
    Lg.i(LOG_TAG + ': scanning started');
  }

  /** 离开 LocalSend 页面时停止扫描，保留首页接收/广播服务。 */
  stopScan(): void {
    if (!this.scanning) {
      return;
    }
    this.scanning = false;
    this.scanGeneration += 1;
    this.localSendSubnet.stop();
    if (this.subnetScanTimer !== -1) {
      clearInterval(this.subnetScanTimer);
      this.subnetScanTimer = -1;
    }
    if (this.discoveryService !== undefined) {
      try {
        this.discoveryService.stopSearchingMDNS();
      } catch (error) {
        Lg.w(LOG_TAG + ': mDNS stop failed: ' + JSON.stringify(error));
      }
      this.discoveryService = undefined;
    }
    this.setVisible(SettingsStore.current().alwaysVisible);
    this.seen.clear();
    Lg.i(LOG_TAG + ': scanning stopped');
  }

  stop(): void {
    this.scanning = false;
    this.scanGeneration += 1;
    this.localSendSubnet.stop();
    if (this.subnetScanTimer !== -1) {
      clearInterval(this.subnetScanTimer);
      this.subnetScanTimer = -1;
    }
    this.stopPruneTimer();
    if (this.discoveryService !== undefined) {
      try {
        this.discoveryService.stopSearchingMDNS();
      } catch (error) {
        Lg.w(LOG_TAG + ': mDNS stop failed: ' + JSON.stringify(error));
      }
      this.discoveryService = undefined;
    }
    this.multicast.stop();
    this.setVisible(false);
    this.seen.clear();
    this.serviceActive = false;
    Lg.i(LOG_TAG + ': stopped');
  }

  private ensureService(): void {
    if (this.serviceActive) {
      return;
    }
    this.startReceiveOnly();
  }

  private startSubnetScan(): void {
    const scan = (): void => {
      this.refreshLocalNetwork();
      // 只扫描“可用于发现对端的局域网”网段，避免把本机容器/VPN 网卡（如 192.0.2.10）也当成子网扫描，
      // 那只会反复探测虚拟子网、拖慢扫描。localAddresses 仍保留全部网卡地址，用于自识别。
      const addressSet: Set<string> = new Set();
      for (const addr of this.localAddresses) {
        if (this.isLanScannerAddress(addr)) {
          addressSet.add(addr);
        }
      }
      // 热点网卡地址必须显式并入：SoftAP 不出现在 getAllNetsSync() 的枚举里，开热点时
      // 系统默认网络又是蜂窝，localAddresses 里只剩 10.x —— 按老逻辑会去扫蜂窝 /24，
      // 连着热点的对端（192.168.43.x）一台都扫不到（2026-09-20 真机日志实证）。
      // native getifaddrs() 能枚举到热点网卡，扫描它的 /24 即可覆盖对端。
      for (const iface of NetDiscoveryNative.hotspotInterfaces()) {
        if (this.isLanScannerAddress(iface.address)) {
          addressSet.add(iface.address);
        }
      }
      const addresses: string[] = Array.from(addressSet);
      if (addresses.length === 0 && this.localAddress.length > 0) {
        addresses.push(this.localAddress);
      }
      Lg.i(LOG_TAG + ': subnet scan round over addresses=[' + addresses.join(', ') + '] (port 53317)');
      void this.scanLocalSendAddresses(addresses, this.scanGeneration);
    };
    scan();
    this.subnetScanTimer = setInterval(scan, 20000);
    Lg.i(LOG_TAG + ': subnet scan started (53317, every 20000 ms)');
  }

  /** 判定该 IPv4 是否属于可用于发现对端的局域网网段（排除本机容器/VPN/回环/链路本地）。 */
  private isLanScannerAddress(addr: string): boolean {
    if (addr.length === 0 || addr.indexOf('.') < 0) {
      return false;
    }
    if (addr.startsWith('127.') || addr.startsWith('169.254.') || addr.startsWith('0.')) {
      return false;
    }
    const octet1: number = Number(addr.split('.')[0]);
    // 172.16.0.0/12（172.16..172.31）为容器桥 / VPN TUN 常用网段。
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
  }

  /**
   * 判断 IPv4 是否属于 VPN / 容器类网段。这类地址（常见 172.16-172.31、100.64-100.127）
   * 是本机容器/虚拟网关或路由隧道地址，不代表真实的局域网对端，LocalSend 应一律忽略：
   * 不当作本机地址读取，也不当作可发现设备展示。
   */
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
    // 172.16.0.0/12（172.16..172.31）— 容器桥 / VPN TUN / 虚拟网关网段。
    if (octet1 === 172 && octet2 >= 16 && octet2 <= 31) {
      return true;
    }
    // 100.64.0.0/10（100.64..100.127）— CGNAT / 部分 VPN 网段。
    if (octet1 === 100 && octet2 >= 64 && octet2 <= 127) {
      return true;
    }
    return false;
  }

  private async scanLocalSendAddresses(addresses: string[], generation: number): Promise<void> {
    if (addresses.length === 0) {
      return;
    }
    for (const address of addresses) {
      if (!this.scanning || generation !== this.scanGeneration) {
        return;
      }
      try {
        await this.localSendSubnet.scan(address);
        Lg.i(LOG_TAG + ': subnet scan round done for ' + address);
      } catch (error) {
        Lg.w(LOG_TAG + ': subnet scan failed for ' + address + ': ' + JSON.stringify(error));
      }
    }
  }

  private startMdnsDiscovery(): void {
    try {
      const generation = this.scanGeneration;
      const service = mdns.createDiscoveryService(this.context, LOCALSEND_SERVICE_TYPE);
      service.on('serviceFound', (info: mdns.LocalServiceInfo): void => {
        if (this.scanning && generation === this.scanGeneration) {
          this.resolveMdnsService(info);
        }
      });
      service.startSearchingMDNS();
      this.discoveryService = service;
      Lg.i(LOG_TAG + ': mDNS discovery started for ' + LOCALSEND_SERVICE_TYPE);
    } catch (error) {
      Lg.w(LOG_TAG + ': mDNS discovery start failed: ' + JSON.stringify(error));
    }
  }

  private resolveMdnsService(info: mdns.LocalServiceInfo): void {
    const generation = this.scanGeneration;
    mdns.resolveLocalService(this.context, info).then((resolved: mdns.LocalServiceInfo): void => {
      if (!this.scanning || generation !== this.scanGeneration) {
        return;
      }
      const host = resolved.host;
      if (host === undefined || host.address === undefined || host.address.length === 0) {
        return;
      }
      // 单独拦截 VPN / 容器类网段：这类地址是本机虚拟网关/隧道，不代表真实对端，直接跳过。
      if (this.isVpnSegment(host.address)) {
        Lg.i(LOG_TAG + ': skipped VPN-segment mDNS device ' + host.address);
        return;
      }
      if (this.isOwnService(resolved.serviceName, host.address)) {
        return;
      }
      let alias = resolved.serviceName;
      let model = 'LocalSend device';
      let fingerprint = '';
      let https = false;
      let protocol = '';
      if (resolved.serviceAttribute !== undefined) {
        for (const attribute of resolved.serviceAttribute) {
          const value = ByteUtils.decodeText(new Uint8Array(attribute.value));
          if (attribute.key === 'alias' || attribute.key === 'fn' || attribute.key === 'name' || attribute.key === 'n') {
            alias = value;
          } else if (attribute.key === 'deviceModel') {
            model = value;
          } else if (attribute.key === 'fingerprint') {
            fingerprint = value;
          } else if (attribute.key === 'protocol') {
            protocol = value.toLowerCase();
          }
        }
      }
      const port = resolved.port ?? LOCALSEND_PORT;
      if (protocol === 'http') {
        https = false;
      } else if (protocol === 'https') {
        https = true;
      }
      // 身份兜底：经 VPN/热点等未枚举网卡发现回本机自己的 LocalSend 服务时直接丢弃。
      // fingerprint 是本机唯一身份，与地址枚举/服务名解析无关，双端非空且一致即视为本机。
      if (this.fingerprint.length > 0 && fingerprint.length > 0 && fingerprint === this.fingerprint) {
        Lg.i(LOG_TAG + ': ignored own device via fingerprint (' + host.address + ')');
        return;
      }
      Lg.i(LOG_TAG + ': discovered LAN device ' + alias + ' at ' + host.address + ':' + port
        + ' https=' + https);
      this.emit({
        id: 'localsend:' + host.address + ':' + port,
        name: alias,
        model,
        protocol: 'localsend',
        address: host.address,
        port,
        https,
        fingerprint,
        source: 'mdns'
      });
    }).catch((error: BusinessError): void => {
      Lg.w(LOG_TAG + ': mDNS resolve failed: ' + JSON.stringify(error));
    });
  }

  private startMdnsAdvertisement(): void {
    const generation = ++this.advertisementGeneration;
    const settings = SettingsStore.current();
    const suffix = AdvertisementIdentity.localSendInstanceSuffix(this.context);
    const serviceName = OWN_SERVICE_PREFIX + suffix;
    this.advertisedServiceName = serviceName;
    const fingerprint = this.fingerprint.length > 0 ? this.fingerprint : suffix;
    const serviceInfo: mdns.LocalServiceInfo = {
      serviceType: LOCALSEND_SERVICE_TYPE,
      serviceName: serviceName,
      port: this.servicePort,
      serviceAttribute: [
        { key: 'alias', value: Array.from(ByteUtils.encodeText(settings.alias)) },
        { key: 'fn', value: Array.from(ByteUtils.encodeText(settings.alias)) },
        { key: 'port', value: Array.from(ByteUtils.encodeText(this.servicePort.toString())) },
        { key: 'version', value: Array.from(ByteUtils.encodeText('2.0')) },
        { key: 'deviceModel', value: Array.from(ByteUtils.encodeText(deviceInfo.marketName)) },
        { key: 'deviceType', value: Array.from(ByteUtils.encodeText('mobile')) },
        { key: 'protocol', value: Array.from(ByteUtils.encodeText(this.httpsEnabled ? 'https' : 'http')) },
        { key: 'download', value: Array.from(ByteUtils.encodeText('true')) },
        { key: 'announce', value: Array.from(ByteUtils.encodeText('true')) },
        { key: 'https', value: Array.from(ByteUtils.encodeText(this.httpsEnabled ? '1' : '0')) },
        { key: 'fingerprint', value: Array.from(ByteUtils.encodeText(fingerprint)) }
      ]
    };
    this.advertisementOperation = this.advertisementOperation.then(async (): Promise<void> => {
      if (!this.advertising || generation !== this.advertisementGeneration) {
        return;
      }
      let added: mdns.LocalServiceInfo;
      try {
        added = await mdns.addLocalService(this.context, serviceInfo);
      } catch (error) {
        if ((error as BusinessError).code !== MDNS_SERVICE_INSTANCE_DUPLICATED) {
          throw error instanceof Error ? error : new Error(JSON.stringify(error));
        }
        added = serviceInfo;
      }
      this.advertisedService = added;
      if (!this.advertising || generation !== this.advertisementGeneration) {
        await mdns.removeLocalService(this.context, added);
        this.advertisedService = undefined;
      }
    }).catch((error: BusinessError): void => {
      Lg.w(LOG_TAG + ': mDNS advertise/update failed: ' + JSON.stringify(error));
    });
  }

  private stopMdnsAdvertisement(): void {
    this.advertisementGeneration += 1;
    this.advertisedServiceName = '';
    this.advertisementOperation = this.advertisementOperation.then(async (): Promise<void> => {
      const service = this.advertisedService;
      if (service !== undefined) {
        await mdns.removeLocalService(this.context, service);
        this.advertisedService = undefined;
      }
    }).catch((error: BusinessError): void => {
      Lg.w(LOG_TAG + ': mDNS unadvertise failed: ' + JSON.stringify(error));
    });
  }

  private emit(device: DeviceEndpoint): void {
    const now = Date.now();
    const last = this.seen.get(device.id);
    if (last !== undefined && now - last < EMIT_THROTTLE_MS) {
      return;
    }
    this.seen.set(device.id, now);
    this.listeners.forEach((listener: DeviceListener): void => listener(device));
  }

  private startPruneTimer(): void {
    this.stopPruneTimer();
    this.pruneTimer = setInterval((): void => this.pruneMaps(), MAP_PRUNE_INTERVAL_MS);
  }

  private stopPruneTimer(): void {
    if (this.pruneTimer !== -1) {
      clearInterval(this.pruneTimer);
      this.pruneTimer = -1;
    }
  }

  private pruneMaps(): void {
    LocalSendDiscovery.pruneByAge(this.seen, Date.now(), SEEN_TTL_MS);
  }

  private static pruneByAge(map: Map<string, number>, now: number, maxAgeMs: number): void {
    if (map.size === 0) {
      return;
    }
    const keys = Array.from(map.keys());
    for (const key of keys) {
      const value = map.get(key);
      if (value !== undefined && now - value > maxAgeMs) {
        map.delete(key);
      }
    }
  }

  private refreshLocalNetwork(): void {
    try {
      this.localAddresses.clear();
      let fallback = '';
      // 遍历所有存在的网络（而非仅默认网络），但单独拦截 VPN/容器类网段（172.16-31、100.64-127）：
      // 这类地址是本机虚拟网关/隧道，不当作“本机地址”，避免经它发现回自己上屏，也不参与扫描/广播。
      const handles: netConnection.NetHandle[] = netConnection.getAllNetsSync();
      for (const handle of handles) {
        const properties: netConnection.ConnectionProperties = netConnection.getConnectionPropertiesSync(handle);
        for (const link of properties.linkAddresses) {
          const addr = link.address.address;
          if (addr.indexOf('.') >= 0 && !this.isVpnSegment(addr)) {
            this.localAddresses.add(addr);
            if (fallback.length === 0) {
              fallback = addr;
            }
          }
        }
      }
      // 兜底：若以上没拿到任何 IPv4（如无网络），回退到默认网络（同样跳过 VPN 段）。
      if (this.localAddresses.size === 0) {
        const netHandle = netConnection.getDefaultNetSync();
        const properties: netConnection.ConnectionProperties = netConnection.getConnectionPropertiesSync(netHandle);
        for (const link of properties.linkAddresses) {
          const addr = link.address.address;
          if (addr.indexOf('.') >= 0 && !this.isVpnSegment(addr)) {
            this.localAddresses.add(addr);
            if (fallback.length === 0) {
              fallback = addr;
            }
          }
        }
      }
      // 主显示地址仍优先挑可用局域网 IPv4（192.168/10，跳过 172.16-31/容器/VPN），
      // 避免把容器/虚拟网关 IP 当成“本机地址”展示，或据此算错误的定向广播。
      const usable = getLocalIpv4();
      this.localAddress = usable.length > 0 ? usable : fallback;
    } catch (error) {
      Lg.w(LOG_TAG + ': local network refresh failed: ' + JSON.stringify(error));
    }
  }

  private isOwnService(serviceName: string, address: string): boolean {
    const normalized = serviceName.trim().replace(/\.$/, '');
    const own = this.advertisedServiceName.trim().replace(/\.$/, '');
    if (own.length > 0 && normalized === own) {
      return true;
    }
    // Address check against *every* local interface, including the VPN/container
    // segments that localAddresses deliberately excludes (192.0.2.10 = 卓易通's
    // virtual gateway). Our own advertisement is echoed back from that interface
    // too, and those copies are the ones that used to pile up in the device list.
    if (isLocalIpv4Address(address)) {
      Lg.i(LOG_TAG + ': ignored own device at local address ' + address);
      return true;
    }
    return this.localAddresses.has(address);
  }
}
