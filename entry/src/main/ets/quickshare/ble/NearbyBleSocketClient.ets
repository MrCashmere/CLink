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
  WEAVE_DEFAULT_ATT_PAYLOAD_SIZE,
  WEAVE_MAX_PACKET_COUNTER,
  WeaveConnectionConfirm,
  WeaveConnectionClose,
  WeaveDataPacket,
  BleSocketControlType
} from './NearbyBleSocketCodec';
import { GsStreamConnection } from '../../protocol/gs/GsFacade';

const CONNECT_TIMEOUT_MS: number = 8000;
const WEAVE_CONFIRM_TIMEOUT_MS: number = 3000;
const MAX_MESSAGE_BYTES: number = 1024 * 1024;

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
  private writeChar?: ble.BLECharacteristic;
  private stream?: BleClientStream;

  async connect(mac: string): Promise<GsStreamConnection> {
    if (this.gattClient !== undefined) { throw new Error('BLE 已有活动连接'); }
    const client = ble.createGattClientDevice(mac);
    this.gattClient = client;
    try {
      await NearbyBleSocketClient.waitConnected(client);
      client.on('BLEConnectionStateChange', (state: ble.BLEConnectionChangeState): void => {
        if (this.gattClient === client && state.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
          if (this.stream !== undefined) { this.stream.close(); }
          else { this.closeStream(); }
        }
      });
      const services = await client.getServices();
      const chars = NearbyBleSocketClient.findSocketChars(services);
      if (chars === undefined) { throw new Error('对端未发现 Nearby BLE socket 服务'); }
      if (this.gattClient !== client) { throw new Error('BLE 连接已关闭'); }
      this.writeChar = chars.write;
      const stream = new BleClientStream(this);
      this.stream = stream;
      client.on('BLECharacteristicChange', (char: ble.BLECharacteristic): void => {
        if (this.gattClient === client && char.characteristicUuid.toLowerCase() === BLE_SOCKET_FROM_PERIPHERAL_UUID.toLowerCase()) {
          stream.onNotify(new Uint8Array(char.characteristicValue));
        }
      });
      await client.setCharacteristicChangeNotification(chars.notify, true);
      await stream.handshake();
      return stream;
    } catch (error) {
      if (this.gattClient === client) {
        if (this.stream !== undefined) { this.stream.close(); }
        else { this.closeStream(); }
      }
      throw error as Error;
    }
  }

  closeStream(): void {
    const client = this.gattClient;
    this.gattClient = undefined;
    this.writeChar = undefined;
    this.stream = undefined;
    if (client === undefined) { return; }
    try {
      client.off('BLEConnectionStateChange');
      client.off('BLECharacteristicChange');
    } catch (_error) {}
    try { client.disconnect(); } catch (_error) {}
    try { client.close(); } catch (error) {
      Lg.w('[QUICKSHARE][BLE client] gatt close failed: ' + JSON.stringify(error));
    }
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
    await new Promise<void>((resolve: () => void, reject: (err: Error) => void): void => {
      let done = false;
      let timer = -1;
      const onState = (state: ble.BLEConnectionChangeState): void => {
        if (state.state === constant.ProfileConnectionState.STATE_CONNECTED) { finish(true); }
      };
      const finish = (ok: boolean): void => {
        if (done) { return; }
        done = true;
        clearTimeout(timer);
        try { client.off('BLEConnectionStateChange', onState); } catch (_error) {}
        if (ok) { resolve(); }
        else { reject(new Error('BLE 连接对端超时或失败')); }
      };
      timer = setTimeout((): void => finish(false), CONNECT_TIMEOUT_MS);
      try {
        client.on('BLEConnectionStateChange', onState);
        client.connect();
      } catch (error) { finish(false); }
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
  private closed: boolean = false;
  private confirmResolve?: () => void;
  private confirmReject?: (error: Error) => void;
  private closeListener?: () => void;

  constructor(client: NearbyBleSocketClient) {
    this.client = client;
  }

  onData(listener: (chunk: Uint8Array) => void): void {
    this.listener = listener;
  }

  onClose(listener: () => void): void {
    this.closeListener = listener;
    if (this.closed) { listener(); }
  }

  sendBytes(data: Uint8Array): Promise<void> {
    if (this.closed) { return Promise.reject(new Error('BLE 连接已关闭')); }
    const payload: Uint8Array = ByteUtils.concat([NEARBY_SERVICE_ID_HASH, data]);
    return this.sendSocketMessage(payload);
  }

  close(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.confirmReject?.(new Error('BLE 连接已关闭'));
    this.messageBuffer.length = 0;
    this.client.closeStream();
    this.closeListener?.();
  }

  onNotify(bytes: Uint8Array): void {
    if (this.closed) {
      return;
    }
    const packet: WeaveConnectionConfirm | WeaveDataPacket | WeaveConnectionClose | undefined =
      NearbyBleSocketCodec.parseWeavePacket(bytes) as WeaveConnectionConfirm | WeaveDataPacket | WeaveConnectionClose | undefined;
    if (packet instanceof WeaveConnectionConfirm) {
      if (packet.version !== WEAVE_VERSION || packet.packetSize < WEAVE_DEFAULT_ATT_PAYLOAD_SIZE
        || packet.packetSize > WEAVE_MAX_PACKET_SIZE) {
        this.close();
        return;
      }
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
      if (this.messageBuffer.length + packet.data.length > MAX_MESSAGE_BYTES) {
        this.close();
        return;
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
    if (this.closed) { throw new Error('BLE 连接已关闭'); }
    const confirm = new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      this.confirmResolve = resolve;
      this.confirmReject = reject;
    });
    const timer = setTimeout((): void => {
      this.confirmReject?.(new Error('等待 BLE 握手确认超时'));
    }, WEAVE_CONFIRM_TIMEOUT_MS);
    try {
      const request = NearbyBleSocketCodec.encodeConnectionRequest(0, WEAVE_VERSION, WEAVE_VERSION, WEAVE_MAX_PACKET_SIZE);
      await Promise.all([this.client.write(request), confirm]);
      await this.sendSocketMessage(NearbyBleSocketCodec.encodeIntroductionPacket(NEARBY_SERVICE_ID_HASH));
    } finally {
      clearTimeout(timer);
      this.confirmResolve = undefined;
      this.confirmReject = undefined;
    }
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

}
