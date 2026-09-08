import { LogCapture as Lg } from '../common/LogCapture';
import { socket } from '@kit.NetworkKit';
import deviceInfo from '@ohos.deviceInfo';
import { BusinessError } from '@kit.BasicServicesKit';
import { ByteUtils } from '../common/ByteUtils';
import { SecurityUtils } from '../common/SecurityUtils';
import { SettingsStore } from '../common/SettingsStore';
import { DeviceEndpoint } from '../model/TransferModels';

const LOG_TAG = '羊绒互传 multicast';
const MULTICAST_GROUP = '224.0.0.167';
const LIMITED_BROADCAST = '255.255.255.255';
const MULTICAST_PORT = 53317;
const ANNOUNCE_INTERVAL_MS = 5000;
const ERR_ADDRESS_IN_USE = 2301098;

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
  private announceTimer: number = -1;
  private advertising = false;
  private started = false;
  private announcedOnce = false;
  private groupJoined = false;
  private bound = false;

  constructor(emitDevice: AnnounceEmitter, isOwnAddress: AddressChecker, getLocalAddress: AddressProvider) {
    this.emitDevice = emitDevice;
    this.isOwnAddress = isOwnAddress;
    this.getLocalAddress = getLocalAddress;
  }

  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    const instance = socket.constructMulticastSocketInstance();
    instance.bind({ address: '0.0.0.0', port: MULTICAST_PORT, family: 1 }).then((): void => {
      Lg.i(LOG_TAG + ': UDP socket bound to 0.0.0.0:' + MULTICAST_PORT);
      // 绑定成功后才注册监听、建组、置位，避免用未绑定 socket 发送。
      this.multicastSocket = instance;
      this.bound = true;
      instance.on('message', (value: socket.SocketMessageInfo): void => {
        this.handleMessage(value);
      });
      this.joinGroup(instance, 0);
      instance.setExtraOptions({ broadcast: true, reuseAddress: true }).then((): void => {
        Lg.i(LOG_TAG + ': UDP broadcast enabled');
      }).catch((error: BusinessError): void => {
        Lg.w(LOG_TAG + ': UDP broadcast enable failed code=' + error.code + ' message=' + error.message);
      });
    }).catch((error: BusinessError): void => {
      Lg.w(LOG_TAG + ': UDP bind failed code=' + error.code + ' message=' + error.message);
      // 安全降级：不置 bound，不注册监听/建组，释放套接字引用。
      this.bound = false;
      this.multicastSocket = undefined;
      instance.close().catch((closeError: BusinessError): void => {
        Lg.w(LOG_TAG + ': socket close after bind failure failed code=' + closeError.code);
      });
    });
  }

  private joinGroup(instance: socket.MulticastSocket, attempt: number): void {
    const withPort: socket.NetAddress = { address: MULTICAST_GROUP, port: MULTICAST_PORT, family: 1 };
    const withFamily: socket.NetAddress = { address: MULTICAST_GROUP, family: 1 };
    const bare: socket.NetAddress = { address: MULTICAST_GROUP };
    const variants: socket.NetAddress[] = [withPort, withFamily, bare];
    if (attempt >= variants.length) {
      Lg.w(LOG_TAG + ': all addMembership variants failed; relying on broadcast/unicast paths');
      return;
    }
    instance.addMembership(variants[attempt]).then((): void => {
      this.groupJoined = true;
      Lg.i(LOG_TAG + ': joined multicast group ' + MULTICAST_GROUP + ' (variant ' + attempt + ')');
    }).catch((error: BusinessError): void => {
      if (error.code === ERR_ADDRESS_IN_USE) {
        this.groupJoined = true;
        Lg.i(LOG_TAG + ': multicast group already joined (2301098 confirms membership active)');
        return;
      }
      Lg.w(LOG_TAG + ': addMembership variant ' + attempt + ' failed code=' + error.code + ' message=' + error.message);
      this.joinGroup(instance, attempt + 1);
    });
  }

  stop(): void {
    if (!this.started) {
      return;
    }
    this.started = false;
    this.bound = false;
    this.stopAnnounceTimer();
    const instance = this.multicastSocket;
    this.multicastSocket = undefined;
    if (instance === undefined) {
      return;
    }
    if (this.groupJoined) {
      instance.dropMembership({ address: MULTICAST_GROUP }).catch((error: BusinessError): void => {
        Lg.w(LOG_TAG + ': drop membership failed code=' + error.code);
      });
    }
    instance.close().catch((error: BusinessError): void => {
      Lg.w(LOG_TAG + ': socket close failed code=' + error.code);
    });
    Lg.i(LOG_TAG + ': stopped');
  }

  setAdvertising(visible: boolean): void {
    if (visible === this.advertising) {
      return;
    }
    this.advertising = visible;
    if (visible) {
      this.sendAnnounce();
      this.announceTimer = setInterval((): void => {
        this.sendAnnounce();
      }, ANNOUNCE_INTERVAL_MS);
      Lg.i(LOG_TAG + ': periodic announce started (every ' + ANNOUNCE_INTERVAL_MS + ' ms)');
    } else {
      this.stopAnnounceTimer();
      Lg.i(LOG_TAG + ': periodic announce stopped');
    }
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
      download: true,
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
    const instance = this.multicastSocket;
    if (instance === undefined || !this.advertising || !this.bound) {
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

  private handleMessage(value: socket.SocketMessageInfo): void {
    const sender = value.remoteInfo.address;
    const text = ByteUtils.decodeText(new Uint8Array(value.message));
    if (!this.isOwnAddress(sender)) {
      Lg.i(LOG_TAG + ': datagram from ' + sender + ':' + value.remoteInfo.port + ' len=' + text.length);
    }
    let info: LocalSendAnnounce;
    try {
      info = JSON.parse(text) as LocalSendAnnounce;
    } catch (error) {
      Lg.w(LOG_TAG + ': non-LocalSend datagram from ' + sender + ': ' + text.substring(0, 48));
      return;
    }
    if (this.isOwnAddress(sender)) {
      return;
    }
    // 单独拦截 VPN / 容器类网段：这类源地址是本机虚拟网关/隧道，不代表真实对端，直接跳过。
    if (this.isVpnSegment(sender)) {
      return;
    }
    // 本机过滤：源地址是本机任一网卡地址（含 VPN/容器等非默认网卡）→ 已在上面丢弃。
    // fingerprint 是本机唯一身份：当源地址未枚举到（如 172.17.1.1）但 fingerprint 与本机
    // 一致时，同样视为本机丢弃（双端非空才比较，避免空指纹误伤对端）。
    if (info.fingerprint !== undefined && info.fingerprint.length > 0
      && info.fingerprint === this.fingerprint) {
      return;
    }
    const port = info.port !== undefined && info.port > 0 ? info.port : value.remoteInfo.port;
    const alias = info.alias !== undefined && info.alias.length > 0 ? info.alias : sender;
    const model = info.deviceModel !== undefined && info.deviceModel.length > 0 ? info.deviceModel : 'LocalSend device';
    const protocolText = info.protocol !== undefined ? info.protocol.toLowerCase() : '';
    Lg.i(LOG_TAG + ': LocalSend peer ' + alias + ' at ' + sender + ':' + port
      + ' protocol=' + (info.protocol !== undefined ? info.protocol : 'none')
      + ' announce=' + (info.announce === true || info.announcement === true));
    this.emitDevice({
      id: 'localsend:' + sender + ':' + port,
      name: alias,
      model,
      protocol: 'localsend',
      address: sender,
      port,
      https: protocolText !== 'http',
      fingerprint: info.fingerprint ?? '',
      source: 'lan'
    });
    // 只要收到对端 announce 就单播回包，让对端（尤其官方 LocalSend）无需手动刷新即可看到本机。
    this.replyTo(sender, port);
  }

  private replyTo(address: string, port: number): void {
    const instance = this.multicastSocket;
    if (instance === undefined) {
      return;
    }
    instance.send({
      data: this.buildAnnounce(false),
      address: { address, port, family: 1 }
    }).catch((error: BusinessError): void => {
      Lg.w(LOG_TAG + ': reply to ' + address + ':' + port + ' failed code=' + error.code);
    });
  }
}
