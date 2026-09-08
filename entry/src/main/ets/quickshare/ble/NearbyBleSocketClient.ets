import { LogCapture as Lg } from '../../common/LogCapture';
import ble from '@ohos.bluetooth.ble';
import constant from '@ohos.bluetooth.constant';
import { ByteUtils } from '../../common/ByteUtils';
import {
  NearbyBleSocketCodec,
  BLE_SOCKET_TO_PERIPHERAL_UUID,
  BLE_SOCKET_FROM_PERIPHERAL_UUID,
  NEARBY_SERVICE_ID_HASH,
  WEAVE_VERSION,
  WEAVE_HEADER_SIZE,
  WEAVE_MAX_PACKET_SIZE,
  WEAVE_MAX_PACKET_COUNTER,
  WeaveConnectionConfirm,
  WeaveConnectionClose,
  WeaveDataPacket,
  BleSocketControlType
} from './NearbyBleSocketCodec';
import { GsStreamConnection } from '../../protocol/gs/GsFacade';

const CONNECT_TIMEOUT_MS: number = 8000;

interface BleSocketChars {
  readonly serviceUuid: string;
  readonly write: ble.BLECharacteristic;
  readonly notify: ble.BLECharacteristic;
}

/**
 * Sender-side (central) BLE GATT socket. Connects to a stock Quick Share receiver's
 * Nearby second-profile socket service (0000fef3-0004-...), runs the Weave
 * handshake + socket introduction, then exposes a raw Nearby stream so the Quick
 * Share sender protocol can run over BLE when the LAN TCP path is unreachable.
 *
 * UNVERIFIED against stock Android until captured on-device.
 */
export class NearbyBleSocketClient {
  private gattClient?: ble.GattClientDevice;
  private writeServiceUuid: string = '';
  private writeChar?: ble.BLECharacteristic;
  private stream?: BleClientStream;

  async connect(mac: string): Promise<GsStreamConnection> {
    Lg.i('[QUICKSHARE][BLE client] connecting to mac=' + mac);
    const client: ble.GattClientDevice = ble.createGattClientDevice(mac);
    this.gattClient = client;
    await NearbyBleSocketClient.waitConnected(client);
    const services: ble.GattService[] = await client.getServices();
    for (const svc of services) {
      Lg.i('[QUICKSHARE][BLE client] service=' + svc.serviceUuid
        + ' chars=' + svc.characteristics.map((c: ble.BLECharacteristic): string => c.characteristicUuid).join(','));
    }
    const socket: BleSocketChars | undefined = NearbyBleSocketClient.findSocketChars(services);
    if (socket === undefined) {
      await client.close();
      throw new Error('对端未发现 Nearby BLE socket 服务（无 0101/0102 Weave 特征）。'
        + '对端可能正处于发送态、未广播可连接的接收 socket，或未开启「所有人可见」。');
    }
    this.writeServiceUuid = socket.serviceUuid;
    this.writeChar = socket.write;
    await client.setCharacteristicChangeNotification(socket.notify, true);
    client.on('BLECharacteristicChange', (char: ble.BLECharacteristic): void => {
      if (char.characteristicUuid.toLowerCase() === BLE_SOCKET_FROM_PERIPHERAL_UUID.toLowerCase()) {
        this.stream?.onNotify(new Uint8Array(char.characteristicValue));
      }
    });

    const stream: BleClientStream = new BleClientStream(this);
    this.stream = stream;
    await stream.handshake();
    Lg.i('[QUICKSHARE][BLE client] connected mac=' + mac + ' service=' + socket.serviceUuid);
    return stream;
  }

  closeStream(): void {
    try {
      this.gattClient?.disconnect();
    } catch (error) {
      Lg.w('[QUICKSHARE][BLE client] disconnect failed: ' + JSON.stringify(error));
    }
    try {
      this.gattClient?.close();
    } catch (error) {
      Lg.w('[QUICKSHARE][BLE client] gatt close failed: ' + JSON.stringify(error));
    }
    this.gattClient = undefined;
    this.stream = undefined;
  }

  write(packet: Uint8Array): Promise<void> {
    const client: ble.GattClientDevice | undefined = this.gattClient;
    const writeChar: ble.BLECharacteristic | undefined = this.writeChar;
    if (client === undefined || writeChar === undefined) {
      return Promise.reject(new Error('BLE client not ready'));
    }
    const value: ble.BLECharacteristic = {
      serviceUuid: writeChar.serviceUuid,
      characteristicUuid: writeChar.characteristicUuid,
      characteristicValue: ByteUtils.toArrayBuffer(packet),
      descriptors: [],
      properties: writeChar.properties,
      permissions: writeChar.permissions
    };
    return client.writeCharacteristicValue(value, ble.GattWriteType.WRITE_NO_RESPONSE);
  }

  private static async waitConnected(client: ble.GattClientDevice): Promise<void> {
    await new Promise<void>((resolve: (value: void) => void, reject: (err: Error) => void): void => {
      let done: boolean = false;
      const finish = (ok: boolean): void => {
        if (done) {
          return;
        }
        done = true;
        if (ok) {
          resolve();
        } else {
          reject(new Error('BLE 连接对端超时/失败'));
        }
      };
      const timer: number = setTimeout((): void => finish(false), CONNECT_TIMEOUT_MS);
      client.on('BLEConnectionStateChange', (state: ble.BLEConnectionChangeState): void => {
        if (state.deviceId.toLowerCase().length > 0 && state.state === constant.ProfileConnectionState.STATE_CONNECTED) {
          clearTimeout(timer);
          finish(true);
        }
      });
      try {
        client.connect();
      } catch (error) {
        clearTimeout(timer);
        finish(false);
      }
    });
  }

  private static findSocketChars(services: ble.GattService[]): BleSocketChars | undefined {
    for (const service of services) {
      let write: ble.BLECharacteristic | undefined = undefined;
      let notify: ble.BLECharacteristic | undefined = undefined;
      for (const char of service.characteristics) {
        const uuid: string = char.characteristicUuid.toLowerCase();
        if (uuid === BLE_SOCKET_TO_PERIPHERAL_UUID.toLowerCase()) {
          write = char;
        } else if (uuid === BLE_SOCKET_FROM_PERIPHERAL_UUID.toLowerCase()) {
          notify = char;
        }
      }
      if (write !== undefined && notify !== undefined) {
        return { serviceUuid: service.serviceUuid, write: write, notify: notify };
      }
    }
    return undefined;
  }
}

class BleClientStream implements GsStreamConnection {
  private readonly client: NearbyBleSocketClient;
  private listener?: (chunk: Uint8Array) => void;
  private readonly messageBuffer: number[] = [];
  private packetSize: number = WEAVE_MAX_PACKET_SIZE;
  private sendCounter: number = 0;
  private introSent: boolean = false;
  private closed: boolean = false;
  private confirmResolve?: () => void;
  private confirmPromise?: Promise<void>;

  constructor(client: NearbyBleSocketClient) {
    this.client = client;
  }

  onData(listener: (chunk: Uint8Array) => void): void {
    this.listener = listener;
  }

  sendBytes(data: Uint8Array): Promise<void> {
    if (this.closed) {
      return Promise.resolve();
    }
    const payload: Uint8Array = ByteUtils.concat([NEARBY_SERVICE_ID_HASH, data]);
    return this.sendSocketMessage(payload);
  }

  close(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.client.closeStream();
  }

  onNotify(bytes: Uint8Array): void {
    if (this.closed) {
      return;
    }
    const packet: WeaveConnectionConfirm | WeaveDataPacket | WeaveConnectionClose | undefined =
      NearbyBleSocketCodec.parseWeavePacket(bytes) as WeaveConnectionConfirm | WeaveDataPacket | WeaveConnectionClose | undefined;
    if (packet instanceof WeaveConnectionConfirm) {
      this.packetSize = packet.packetSize;
      if (this.confirmResolve !== undefined) {
        const resolve: () => void = this.confirmResolve;
        this.confirmResolve = undefined;
        resolve();
      }
    } else if (packet instanceof WeaveConnectionClose) {
      this.close();
    } else if (packet instanceof WeaveDataPacket) {
      if (packet.firstPacket) {
        this.messageBuffer.length = 0;
      }
      for (let i = 0; i < packet.data.length; i++) {
        this.messageBuffer.push(packet.data[i]);
      }
      if (packet.lastPacket) {
        const message: Uint8Array = new Uint8Array(this.messageBuffer);
        this.messageBuffer.length = 0;
        this.handleSocketMessage(message);
      }
    }
  }

  async handshake(): Promise<void> {
    // 1) Weave ConnectionRequest (we are the client/central).
    const request: Uint8Array = NearbyBleSocketCodec.encodeConnectionRequest(0, WEAVE_VERSION, WEAVE_VERSION, WEAVE_MAX_PACKET_SIZE);
    await this.client.write(request);
    // 2) Wait for ConnectionConfirm (the server notifies it). We parse packetSize
    //    as it arrives, then send the socket Introduction.
    this.confirmPromise = new Promise<void>((resolve: () => void): void => { this.confirmResolve = resolve; });
    await Promise.race([this.confirmPromise, BleClientStream.delay(500)]);
    // 3) BLE socket Introduction (00 00 00 + SocketControlFrame{INTRODUCTION}).
    const introduction: Uint8Array = NearbyBleSocketCodec.encodeIntroductionPacket(NEARBY_SERVICE_ID_HASH);
    await this.sendSocketMessage(introduction);
    this.introSent = true;
  }

  private async sendSocketMessage(payload: Uint8Array): Promise<void> {
    const maxChunk: number = Math.max(1, this.packetSize - WEAVE_HEADER_SIZE);
    let offset: number = 0;
    let counter: number = this.sendCounter;
    while (offset < payload.length) {
      const n: number = Math.min(maxChunk, payload.length - offset);
      const first: boolean = offset === 0;
      const last: boolean = offset + n >= payload.length;
      const packet: Uint8Array = NearbyBleSocketCodec.encodeDataPacket(counter, first, last, payload.slice(offset, offset + n));
      await this.client.write(packet);
      counter = (counter + 1) % WEAVE_MAX_PACKET_COUNTER;
      offset += n;
    }
    this.sendCounter = counter;
  }

  private handleSocketMessage(message: Uint8Array): void {
    if (NearbyBleSocketCodec.isControlPacket(message)) {
      const control = NearbyBleSocketCodec.parseControlPacket(message);
      if (control !== undefined && control.type === BleSocketControlType.DISCONNECTION) {
        this.close();
      }
      return;
    }
    if (message.length <= NEARBY_SERVICE_ID_HASH.length
      || !NearbyBleSocketCodec.startsWith(message, NEARBY_SERVICE_ID_HASH)) {
      return;
    }
    const payload: Uint8Array = message.slice(NEARBY_SERVICE_ID_HASH.length);
    if (this.listener !== undefined) {
      this.listener(payload);
    }
  }

  static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => { setTimeout(resolve, ms); });
  }
}
