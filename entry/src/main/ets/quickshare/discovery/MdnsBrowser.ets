import { LogCapture as Lg } from '../../common/LogCapture';
import mdns from '@ohos.net.mdns';
import { common } from '@kit.AbilityKit';
import { QuickShareMdnsService } from './MdnsService';
import { ByteUtils } from '../../common/ByteUtils';

export interface QuickShareMdnsTxtAttribute {
  readonly key: string;
  readonly value: string;
}

export class QuickShareMdnsBrowser {
  private readonly context: common.Context;
  private service?: mdns.DiscoveryService;

  constructor(context: common.Context) { this.context = context; }

  start(onService: (service: QuickShareMdnsService) => void): void {
    this.service = mdns.createDiscoveryService(this.context, '_FC9F5ED42C8A._tcp');
    this.service.on('serviceFound', (info: mdns.LocalServiceInfo): void => {
      mdns.resolveLocalService(this.context, info).then((resolved: mdns.LocalServiceInfo): void => {
        const host = resolved.host;
        if (host === undefined || host.address === undefined) { return; }
        const txt = new Map<string, string>();
        const attributes: mdns.ServiceAttribute[] = resolved.serviceAttribute ?? [];
        attributes.forEach((item: mdns.ServiceAttribute): void => {
          const bytes = new Uint8Array(item.value);
          txt.set(item.key, this.decodeUtf8(bytes));
        });
        onService({
          instanceName: resolved.serviceName,
          host: host.address,
          ipv4: host.address,
          port: resolved.port ?? 0,
          txt
        });
      });
    });
    this.service.startSearchingMDNS();
  }

  private decodeUtf8(bytes: Uint8Array): string {
    try {
      return ByteUtils.decodeText(bytes);
    } catch (error) {
      return '';
    }
  }

  stop(): void {
    try {
      this.service?.stopSearchingMDNS();
    } catch (error) {
      // Same teardown race as the BLE scanner: stopSearchingMDNS can throw a
      // synchronous BusinessError when the discovery service is already gone, and
      // this is called from aboutToDisappear. Never let a best-effort stop crash
      // the page.
      Lg.w('[QUICKSHARE] mDNS stopSearchingMDNS failed: ' + JSON.stringify(error));
    }
    this.service = undefined;
  }
}
