import { LogCapture as Lg } from '../../common/LogCapture';
import { common } from '@kit.AbilityKit';
import mdns from '@ohos.net.mdns';
import { BusinessError } from '@kit.BasicServicesKit';
import { ByteUtils } from '../../common/ByteUtils';
import { SecurityUtils } from '../../common/SecurityUtils';
import { SettingsStore } from '../../common/SettingsStore';
import { getLocalIpv4 } from '../../common/NetAddress';
import { QuickShareMdnsBrowser } from '../discovery/MdnsBrowser';
import { QuickShareBleScanner } from '../discovery/BleScanner';
import { QuickShareAdvertisementParser } from '../discovery/AdvertisementParser';
import { QuickShareMdnsService } from '../discovery/MdnsService';
import { QuickShareDiscoveredDevice } from '../model/DiscoveredDevice';

export interface QuickSharePageEndpoint {
  readonly id: string;
  readonly name: string;
  readonly endpointId: string;
  readonly address: string;
  readonly port: number;
  readonly source: 'mdns' | 'ble';
  readonly rssi?: number;
  readonly deviceType?: number;
}

const NEARBY_SERVICE_TYPE = '_FC9F5ED42C8A._tcp';
const GS_QUICKSHARE_PORT = 53318;

export class QuickShareBrowser {
  private readonly context: common.Context;
  private readonly mdnsBrowser: QuickShareMdnsBrowser;
  private readonly bleScanner: QuickShareBleScanner;
  private readonly bleEnabled: boolean;
  private readonly mdnsEndpoints: Map<string, QuickSharePageEndpoint> = new Map();
  private readonly bleDevices: Map<string, QuickShareDiscoveredDevice> = new Map();
  private readonly localEndpointId: string;
  private active = false;
  private nearbyLocalService?: mdns.LocalServiceInfo;
  private mdnsResendBusy = false;
  private onChange?: () => void;

  /**
   * @param context          应用上下文。
   * @param bleEnabled       是否启用本浏览器自带的 BLE 扫描。聚合页同时会启动 Windows
   *                         Nearby 的 BLE 扫描，而 HarmonyOS 的 BLE 扫描是全局单例
   *                         （过滤器和 BLEDeviceFind 回调互相覆盖），因此聚合页需传
   *                         false，让 Quick Share 仅走 mDNS 发现，由 Windows 扫描器独占
   *                         BLE。单独 Quick Share 页面传 true（默认）保持原行为。
   */
  constructor(context: common.Context, bleEnabled: boolean = true) {
    this.context = context;
    this.bleEnabled = bleEnabled;
    this.localEndpointId = SecurityUtils.createToken().slice(0, 4);
    this.mdnsBrowser = new QuickShareMdnsBrowser(context);
    this.bleScanner = new QuickShareBleScanner(
      new QuickShareAdvertisementParser(),
      (device: QuickShareDiscoveredDevice): void => {
        this.onBleDevice(device);
      },
      (): void => {
        this.onFastInitiation();
      });
  }

  start(): void {
    if (this.active) { return; }
    this.active = true;
    this.mdnsEndpoints.clear();
    this.bleDevices.clear();
    this.startMdns();
    if (this.bleEnabled) {
      this.startBle();
    }
    this.startAdvertise();
    Lg.i('[QUICKSHARE] Quick Share browser active (bleEnabled=' + this.bleEnabled + ')');
  }

  stop(): void {
    if (!this.active) { return; }
    this.active = false;
    this.mdnsBrowser.stop();
    this.bleScanner.stop();
    this.stopAdvertise();
    this.mdnsEndpoints.clear();
    this.bleDevices.clear();
    Lg.i('[QUICKSHARE] Quick Share browser inactive');
  }

  setOnChange(listener: () => void): void { this.onChange = listener; }

  localEndpointIdValue(): string {
    return this.localEndpointId;
  }

  /**
   * 返回某对端经 BLE 扫描得到的广告 MAC（即 Android 作为接收方广播时的
   * 可连接设备地址）。只有这个地址才承载 Weave socket 服务；「接收时缓存的对端
   * 客户端 MAC」是对方作为发起方/中心时用的地址，通常不暴露 socket 服务。
   * 若该 endpointId 当前没有 BLE 广告（例如对方未开启接收/可见），返回空串。
   */
  bleAddressFor(endpointId: string): string {
    if (endpointId.length === 0) {
      return '';
    }
    let found: string = '';
    this.bleDevices.forEach((device: QuickShareDiscoveredDevice): void => {
      if (found.length > 0) {
        return;
      }
      if (device.endpointId === endpointId && device.address !== undefined && device.address.length > 0) {
        found = device.address;
      }
    });
    return found;
  }

  private isSelf(endpointId: string): boolean {
    return endpointId.length > 0 && endpointId === this.localEndpointId;
  }

  endpoints(): QuickSharePageEndpoint[] {
    // 按 endpointId 去重：同一对端既可能经 mDNS（WIFI_LAN）又经 BLE 被发现。
    // WLAN 直连优先模式下优先展示 BLE（MAC）条目，使点击时 send() 走 BLE 而绕开
    // 原生局域网 TCP；普通模式优先保留 mDNS（走快速 LAN TCP）。
    const wlanDirect: boolean = SettingsStore.current().quickshareWlanDirect;
    const byId: Map<string, QuickSharePageEndpoint> = new Map();
    this.mdnsEndpoints.forEach((endpoint: QuickSharePageEndpoint): void => {
      if (!wlanDirect || !byId.has(endpoint.endpointId)) {
        byId.set(endpoint.endpointId, endpoint);
      }
    });
    this.bleDevices.forEach((device: QuickShareDiscoveredDevice): void => {
      if (device.address !== undefined && device.address.length > 0) {
        const ep: QuickSharePageEndpoint = {
          id: device.id,
          name: device.name,
          endpointId: device.endpointId,
          address: device.address,
          port: device.port ?? 0,
          source: 'ble',
          rssi: device.rssi
        };
        if (wlanDirect || !byId.has(device.endpointId)) {
          byId.set(device.endpointId, ep);
        }
      }
    });
    const result: QuickSharePageEndpoint[] = [];
    byId.forEach((endpoint: QuickSharePageEndpoint): void => { result.push(endpoint); });
    return result;
  }

  private startMdns(): void {
    try {
      this.mdnsBrowser.start((service: QuickShareMdnsService): void => {
        const endpointId = this.endpointIdFromService(service.instanceName);
        if (endpointId.length === 0) {
          Lg.w('[QUICKSHARE] ignored invalid nearby service ' + service.instanceName);
          return;
        }
        if (this.isSelf(endpointId)) {
          Lg.i('[QUICKSHARE] ignored own endpoint ' + endpointId);
          return;
        }
        const name = this.nameFromTxt(service.txt);
        const endpoint: QuickSharePageEndpoint = {
          id: 'quickshare:' + endpointId,
          name,
          endpointId,
          address: service.ipv4.length > 0 ? service.ipv4 : service.host,
          port: service.port > 0 ? service.port : GS_QUICKSHARE_PORT,
          source: 'mdns',
          deviceType: this.deviceTypeFromTxt(service.txt)
        };
        this.mdnsEndpoints.set(endpoint.id, endpoint);
        Lg.i('[QUICKSHARE] mDNS found ' + name + ' at ' + endpoint.address + ':' + endpoint.port);
        this.notify();
      });
    } catch (error) {
      Lg.w('[QUICKSHARE] mDNS start failed: ' + JSON.stringify(error));
    }
  }

  private startBle(): void {
    try {
      this.bleScanner.start();
    } catch (error) {
      Lg.w('[QUICKSHARE] BLE start failed: ' + JSON.stringify(error));
    }
  }

  private onBleDevice(device: QuickShareDiscoveredDevice): void {
    if (this.isSelf(device.endpointId)) {
      Lg.i('[QUICKSHARE] ignored own BLE endpoint ' + device.endpointId);
      return;
    }
    this.bleDevices.set(device.id, device);
    Lg.i('[QUICKSHARE] BLE saw ' + device.name + ' id=' + device.endpointId);
    this.notify();
  }

  private notify(): void {
    if (this.onChange !== undefined) {
      this.onChange();
    }
  }

  private startAdvertise(): void {
    // WLAN 直连优先模式：不发布 mDNS WIFI_LAN 端点。这样 stock Android 的
    // NearbyConnections 只会看到 BLE 端点（无 wifi-lan），从而选择 ble-gatt
    // bootstrap → 由本机 BLE GATT socket 接收控制通道，再升级 Wi-Fi Direct。
    // 若保留 mDNS，Android 会优先解析为局域网 TCP（192.168.x.x:53318），而该路径
    // 在原生网络下往往不可达，导致它从不降级到 BLE GATT。
    if (SettingsStore.current().quickshareWlanDirect) {
      Lg.i('[QUICKSHARE] WLAN 直连优先：跳过 mDNS WIFI_LAN 广播，仅走 BLE GATT + Wi-Fi Direct');
      return;
    }
    if (this.active && this.nearbyLocalService === undefined) {
      try {
        const serviceInfo = this.buildNearbyMdnsInfo(SettingsStore.current().alias);
        mdns.addLocalService(this.context, serviceInfo).then((added: mdns.LocalServiceInfo): void => {
          this.nearbyLocalService = added;
          Lg.i('[QUICKSHARE] mDNS advertise added ' + added.serviceName + ' port=' + added.port);
        }).catch((error: BusinessError): void => {
          Lg.w('[QUICKSHARE] mDNS advertise failed: ' + JSON.stringify(error));
        });
      } catch (error) {
        Lg.w('[QUICKSHARE] mDNS advertise start failed: ' + JSON.stringify(error));
      }
    }
  }

  private stopAdvertise(): void {
    if (this.nearbyLocalService !== undefined) {
      const service = this.nearbyLocalService;
      this.nearbyLocalService = undefined;
      mdns.removeLocalService(this.context, service).catch((error: BusinessError): void => {
        Lg.w('[QUICKSHARE] mDNS unadvertise failed: ' + JSON.stringify(error));
      });
    }
  }

  private endpointIdFromService(serviceName: string): string {
    try {
      const bytes = this.fromUrlSafeBase64(serviceName);
      if (bytes === undefined || bytes.length < 10 || bytes[0] !== 0x23 || bytes[5] !== 0xfc
        || bytes[6] !== 0x9f || bytes[7] !== 0x5e) {
        return '';
      }
      return ByteUtils.decodeText(bytes.slice(1, 5));
    } catch (error) {
      return '';
    }
  }

  private nameFromTxt(txt: Map<string, string>): string {
    const value = txt.get('n');
    if (value !== undefined && value.length > 0) {
      try {
        const bytes = this.fromUrlSafeBase64(value);
        if (bytes !== undefined && bytes.length > 18) {
          const nameLength = bytes[17];
          if (bytes.length >= nameLength + 18) {
            const decoded = ByteUtils.decodeText(bytes.slice(18, 18 + nameLength));
            if (decoded.length > 0) { return decoded; }
          }
        }
      } catch (error) {
        // fall through to the default label
      }
    }
    return 'Quick Share 设备';
  }

  // Quick Share EndpointInfo byte0: version(3)<<5 | visibility(1)<<4 |
  // deviceType(3)<<1 | reserved(1). deviceType: 0=unknown,1=phone,2=tablet,3=laptop.
  // Used to detect the official Windows Quick Share (laptop/PC) peer for the
  // PC-specific positive-random payload_id path.
  private deviceTypeFromTxt(txt: Map<string, string>): number {
    const value = txt.get('n');
    if (value !== undefined && value.length > 0) {
      try {
        const bytes = this.fromUrlSafeBase64(value);
        if (bytes !== undefined && bytes.length > 0) {
          return (bytes[0] >> 1) & 0x7;
        }
      } catch (error) {
        // fall through
      }
    }
    return 0;
  }

  private toUrlSafeBase64(bytes: Uint8Array): string {
    return ByteUtils.toBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
  }

  private fromUrlSafeBase64(value: string): Uint8Array | undefined {
    try {
      let normalized = value.trim().replace(/-/g, '+').replace(/_/g, '/');
      while (normalized.length % 4 !== 0) { normalized += '='; }
      return ByteUtils.fromBase64(normalized);
    } catch (error) {
      return undefined;
    }
  }

  private buildNearbyMdnsInfo(alias: string): mdns.LocalServiceInfo {
    const endpointId = this.localEndpointId;
    const nameBytes = ByteUtils.encodeText(alias.length > 0 ? alias : 'HarmonyOS');
    const nameLength = Math.min(nameBytes.length, 255);
    const endpointInfo = new Uint8Array(18 + nameLength);
    // byte0 = version(3)<<5 | visibility(1)<<4 | deviceType(3)<<1 | reserved(1).
    // version MUST be 1; we emit a visible phone => 0x20 | (1<<1) = 0x22.
    endpointInfo[0] = (1 << 5) | (1 << 1);
    const random = SecurityUtils.createToken();
    for (let i = 0; i < 16; i++) {
      endpointInfo[i + 1] = parseInt(random.substring(i * 2, i * 2 + 2), 16);
    }
    endpointInfo[17] = nameLength;
    endpointInfo.set(nameBytes.slice(0, nameLength), 18);
    const ipv4 = getLocalIpv4();
    const attributes: mdns.ServiceAttribute[] = [
      { key: 'n', value: this.toUrlSafeBase64(endpointInfo).split('').map((c: string): number => c.charCodeAt(0)) }
    ];
    // Android's Nearby WIFI_LAN prefers the explicit IPv4 TXT record. We pin it
    // to the WiFi interface so the 卓易通 virtual gateways (e.g. 172.17.1.1)
    // never become the connection target.
    if (ipv4.length > 0) {
      attributes.push({ key: 'IPv4', value: this.ipv4Bytes(ipv4) });
    }
    const serviceInfo: mdns.LocalServiceInfo = {
      serviceType: NEARBY_SERVICE_TYPE,
      serviceName: this.toUrlSafeBase64(this.buildNearbyServiceNameBytes(endpointId)),
      port: GS_QUICKSHARE_PORT,
      serviceAttribute: attributes
    };
    // Pin the mDNS SRV / A record to the reachable WiFi IPv4 address. Without
    // this, the OS also advertises the 卓易通 virtual NICs (e.g. 172.17.1.1),
    // so Android resolves the same service to multiple IPs and tries the bogus
    // gateway first -> ECONNREFUSED even though the receiver is listening.
    if (ipv4.length > 0) {
      serviceInfo.host = { address: ipv4, family: 1 };
      Lg.i('[QUICKSHARE] mDNS host pinned to ' + ipv4 + ':' + GS_QUICKSHARE_PORT);
    }
    return serviceInfo;
  }

  // Nearby publishes the IPv4 TXT as 4 raw network-order bytes, not the ASCII
  // string. Advertising the string bytes makes some peers parse a garbage
  // address; encode the dotted-quad as [a,b,c,d] instead.
  private ipv4Bytes(ipv4: string): number[] {
    const parts = ipv4.split('.');
    if (parts.length !== 4) {
      return [];
    }
    const out: number[] = [];
    for (const part of parts) {
      const n = Number(part);
      if (!Number.isInteger(n) || n < 0 || n > 255) {
        return [];
      }
      out.push(n);
    }
    return out;
  }

  private buildNearbyServiceNameBytes(endpointId: string): Uint8Array {
    const bytes = new Uint8Array(10);
    bytes[0] = 0x23;
    bytes.set(ByteUtils.encodeText(endpointId).slice(0, 4), 1);
    bytes[5] = 0xfc;
    bytes[6] = 0x9f;
    bytes[7] = 0x5e;
    return bytes;
  }

  // Invoked when our BLE scanner sees a peer broadcasting the Nearby Fast
  // Initiation beacon (i.e. a device that is starting a share session). We
  // re-announce our mDNS service because Android may not see a service that
  // was published before it began its discovery phase (rquickshare does the
  // same with register_resend). This is the trigger that lets Android resolve
  // our WIFI_LAN endpoint via the mDNS record that carries endpoint_info.
  private onFastInitiation(): void {
    this.resendMdns();
  }

  private resendMdns(): void {
    if (SettingsStore.current().quickshareWlanDirect) {
      return;
    }
    if (this.nearbyLocalService === undefined || this.mdnsResendBusy) { return; }
    this.mdnsResendBusy = true;
    const service = this.nearbyLocalService;
    this.nearbyLocalService = undefined;
    mdns.removeLocalService(this.context, service).then((): void => {
      const serviceInfo = this.buildNearbyMdnsInfo(SettingsStore.current().alias);
      mdns.addLocalService(this.context, serviceInfo).then((added: mdns.LocalServiceInfo): void => {
        this.mdnsResendBusy = false;
        if (this.active) {
          this.nearbyLocalService = added;
          Lg.i('[QUICKSHARE] mDNS re-announced ' + added.serviceName + ' port=' + added.port);
        } else {
          // The session was stopped while we were re-announcing; roll back so the
          // service does not leak into the next session.
          mdns.removeLocalService(this.context, added).catch((err: BusinessError): void => {
            Lg.w('[QUICKSHARE] mDNS rollback after stop failed: ' + JSON.stringify(err));
          });
        }
      }).catch((error: BusinessError): void => {
        this.nearbyLocalService = service;
        this.mdnsResendBusy = false;
        Lg.w('[QUICKSHARE] mDNS re-announce failed: ' + JSON.stringify(error));
      });
    }).catch((error: BusinessError): void => {
      this.nearbyLocalService = service;
      this.mdnsResendBusy = false;
      Lg.w('[QUICKSHARE] mDNS remove during re-announce failed: ' + JSON.stringify(error));
    });
  }
}


