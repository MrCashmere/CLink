import { LogCapture as Lg } from '../../common/LogCapture';
import wifiManager from '@ohos.wifiManager';
import { socket } from '@kit.NetworkKit';
import { ByteUtils } from '../../common/ByteUtils';
import { GsStreamConnection, WifiDirectUpgradeCredentials } from '../../protocol/gs/GsFacade';

export interface P2pGroupCredentials {
  readonly groupName: string;
  readonly passphrase: string;
  readonly goIpAddress: string;
  readonly interfaceName: string;
  readonly frequency: number;
  readonly isGo: boolean;
}

const GO_POLL_INTERVAL_MS: number = 300;
const GO_POLL_TIMEOUT_MS: number = 15000;
const ALPHANUM: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

/**
 * Wi-Fi Direct upgrader. Stock Quick Share, after bootstrapping the control
 * channel over a BLE GATT socket, may offer to move the transfer to a freshly
 * formed Wi-Fi Direct group. On the receiver side we create the group as the
 * group owner (GO), read back the SSID/passphrase and the GO IPv4, and publish
 * those credentials so the adjacent medium-upgrade negotiation can hand them to
 * the peer. The connected TCP listener runs through the AppServices 0.0.0.0
 * receiver, which already accepts on whichever P2P interface comes up.
 *
 * UNVERIFIED: HarmonyOS Wi-Fi Direct group creation interoperability with
 * Android's Nearby medium-upgrade (whether the peer can join our GO group from
 * the SSID/PSK, whether GO_BAND_2GHZ is accepted) is not yet validated.
 */
export class NearbyP2pDirect {
  private groupActive: boolean = false;
  private lastCredentials?: P2pGroupCredentials;
  private connectionChangeCb?: (state: 'connected' | 'disconnected') => void;
  private readonly connectionChangeListener: (info: wifiManager.WifiP2pLinkedInfo) => void =
    (info: wifiManager.WifiP2pLinkedInfo): void => {
      const connected: boolean = info.connectState === wifiManager.P2pConnectState.CONNECTED;
      if (this.connectionChangeCb !== undefined) {
        this.connectionChangeCb(connected ? 'connected' : 'disconnected');
      }
    };

  onConnectionChange(cb: (state: 'connected' | 'disconnected') => void): void {
    this.connectionChangeCb = cb;
  }

  async createGroup(): Promise<P2pGroupCredentials> {
    try {
      wifiManager.on('p2pConnectionChange', this.connectionChangeListener);
    } catch (error) {
      Lg.w('[QUICKSHARE][P2P] subscribe p2pConnectionChange failed: ' + JSON.stringify(error));
    }
    const config: wifiManager.WifiP2PConfig = {
      deviceAddress: '00:00:00:00:00:00',
      deviceAddressType: wifiManager.DeviceAddressType.RANDOM_DEVICE_ADDRESS,
      netId: -1,
      passphrase: NearbyP2pDirect.generatePassphrase(),
      groupName: NearbyP2pDirect.generateGroupName(),
      goBand: wifiManager.GroupOwnerBand.GO_BAND_2GHZ,
      goFreq: 2437
    };
    Lg.i('[QUICKSHARE][P2P] createGroup ssid=' + config.groupName);
    wifiManager.createGroup(config);
    const credentials: P2pGroupCredentials | undefined = await this.pollGroup();
    if (credentials === undefined) {
      Lg.w('[QUICKSHARE][P2P] group formation timed out or GO info missing');
      return {
        groupName: config.groupName,
        passphrase: config.passphrase,
        goIpAddress: '',
        interfaceName: '',
        frequency: 0,
        isGo: false
      };
    }
    this.groupActive = true;
    this.lastCredentials = credentials;
    Lg.i('[QUICKSHARE][P2P] group ready ssid=' + credentials.groupName
      + ' pskLen=' + credentials.passphrase.length + ' go=' + credentials.goIpAddress
      + ' iface=' + credentials.interfaceName + ' freq=' + credentials.frequency);
    return credentials;
  }

  removeGroup(): void {
    if (!this.groupActive) {
      return;
    }
    this.groupActive = false;
    try {
      wifiManager.off('p2pConnectionChange', this.connectionChangeListener);
    } catch (error) {
      Lg.w('[QUICKSHARE][P2P] unsubscribe p2pConnectionChange failed: ' + JSON.stringify(error));
    }
    try {
      wifiManager.removeGroup();
      Lg.i('[QUICKSHARE][P2P] removed group');
    } catch (error) {
      Lg.w('[QUICKSHARE][P2P] removeGroup failed: ' + JSON.stringify(error));
    }
  }

  isActive(): boolean {
    return this.groupActive;
  }

  currentCredentials(): P2pGroupCredentials | undefined {
    return this.lastCredentials;
  }

  /**
   * Sender side: joins the peer-created Wi-Fi Direct group and opens a TCP socket
   * to the group-owner IP:port. UNVERIFIED against stock Android — joining a GO
   * group by SSID/PSK may require the GO's MAC, which the upgrade credentials do
   * not carry.
   */
  async connectAsClient(creds: WifiDirectUpgradeCredentials): Promise<GsStreamConnection | undefined> {
    try {
      const config: wifiManager.WifiP2PConfig = {
        deviceAddress: '00:00:00:00:00:00',
        deviceAddressType: wifiManager.DeviceAddressType.RANDOM_DEVICE_ADDRESS,
        netId: -1,
        passphrase: creds.password,
        groupName: creds.ssid,
        goBand: wifiManager.GroupOwnerBand.GO_BAND_AUTO,
        goFreq: creds.frequency > 0 ? creds.frequency : undefined
      };
      Lg.i('[QUICKSHARE][P2P] client connect ssid=' + creds.ssid + ' gateway=' + creds.gateway + ' port=' + creds.port);
      wifiManager.p2pConnect(config);
      await NearbyP2pDirect.pollConnected();
      const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
      await tcp.connect({ address: { address: creds.gateway, family: 1, port: creds.port } });
      Lg.i('[QUICKSHARE][P2P] client TCP connected to ' + creds.gateway + ':' + creds.port);
      return new WifiDirectClientStream(tcp);
    } catch (error) {
      Lg.w('[QUICKSHARE][P2P] connectAsClient failed: ' + JSON.stringify(error));
      return undefined;
    }
  }

  private static async pollConnected(): Promise<boolean> {
    const deadline: number = Date.now() + 15000;
    while (Date.now() < deadline) {
      try {
        const info: wifiManager.WifiP2pLinkedInfo = await wifiManager.getP2pLinkedInfo();
        if (info.connectState === wifiManager.P2pConnectState.CONNECTED) {
          return true;
        }
      } catch (error) {
        Lg.w('[QUICKSHARE][P2P] getP2pLinkedInfo failed, retrying: ' + JSON.stringify(error));
      }
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 300);
      });
    }
    Lg.w('[QUICKSHARE][P2P] client group connect timed out');
    return false;
  }

  private async pollGroup(): Promise<P2pGroupCredentials | undefined> {
    const deadline: number = Date.now() + GO_POLL_TIMEOUT_MS;
    while (Date.now() < deadline) {
      const credentials: P2pGroupCredentials | undefined = await this.readGroup();
      if (credentials !== undefined && credentials.goIpAddress.length > 0) {
        return credentials;
      }
      await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, GO_POLL_INTERVAL_MS); });
    }
    return undefined;
  }

  private async readGroup(): Promise<P2pGroupCredentials | undefined> {
    try {
      const info: wifiManager.WifiP2pGroupInfo = await wifiManager.getCurrentGroup();
      if (info.groupName.length === 0 || info.passphrase.length === 0) {
        return undefined;
      }
      return {
        groupName: info.groupName,
        passphrase: info.passphrase,
        goIpAddress: info.goIpAddress,
        interfaceName: info.interface,
        frequency: info.frequency,
        isGo: info.isP2pGo
      };
    } catch (error) {
      Lg.w('[QUICKSHARE][P2P] getCurrentGroup failed: ' + JSON.stringify(error));
      return undefined;
    }
  }

  private static generateGroupName(): string {
    return 'DIRECT-' + NearbyP2pDirect.random(2) + '-' + NearbyP2pDirect.random(6);
  }

  private static generatePassphrase(): string {
    return NearbyP2pDirect.random(16);
  }

  private static random(length: number): string {
    let out: string = '';
    for (let i = 0; i < length; i++) {
      out += ALPHANUM.charAt(Math.floor(Math.random() * ALPHANUM.length));
    }
    return out;
  }
}

class WifiDirectClientStream implements GsStreamConnection {
  private readonly tcp: socket.TCPSocket;

  constructor(tcp: socket.TCPSocket) {
    this.tcp = tcp;
  }

  sendBytes(data: Uint8Array): Promise<void> {
    return this.tcp.send({ data: ByteUtils.toArrayBuffer(data) });
  }

  onData(listener: (chunk: Uint8Array) => void): void {
    this.tcp.on('message', (info: socket.SocketMessageInfo): void => listener(new Uint8Array(info.message)));
  }

  close(): void {
    this.tcp.close().catch((): void => undefined);
  }
}
