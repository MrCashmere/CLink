import { LogCapture as Lg } from '../../common/LogCapture';
import ble from '@ohos.bluetooth.ble';
import constant from '@ohos.bluetooth.constant';
import { ByteUtils } from '../../common/ByteUtils';
import {
  NearbyBleSocketCodec,
  BLE_SOCKET_SERVICE_UUID,
  BLE_SOCKET_SECOND_PROFILE_SERVICE_UUID,
  BLE_SOCKET_TO_PERIPHERAL_UUID,
  BLE_SOCKET_FROM_PERIPHERAL_UUID,
  BLE_SOCKET_CCCD_UUID,
  NEARBY_SERVICE_ID_HASH,
  WEAVE_VERSION,
  WEAVE_HEADER_SIZE,
  WEAVE_MIN_PACKET_SIZE,
  WEAVE_MAX_PACKET_SIZE,
  WEAVE_DEFAULT_ATT_PAYLOAD_SIZE,
  WEAVE_MAX_PACKET_COUNTER,
  WeaveConnectionRequest,
  WeaveConnectionConfirm,
  WeaveConnectionClose,
  WeaveDataPacket,
  BleSocketControlFrame,
  BleSocketControlType,
  BleSocketSocketVersion
} from './NearbyBleSocketCodec';
import { GsStreamConnection } from '../../protocol/gs/GsFacade';

const CCCD_NOTIFY: Uint8Array = new Uint8Array([0x01, 0x00]);
const CCCD_INDICATE: Uint8Array = new Uint8Array([0x02, 0x00]);

export interface NearbyBleSocketServerConfig {
  readonly gattAdvertisement: Uint8Array;
  readonly advertisementCharacteristicUuid: string;
  readonly onConnection: (conn: GsStreamConnection) => void;
}

/**
 * Receiver-side BLE GATT socket (Nearby "second profile"). Stock Quick Share's
 * off-LAN path connects to a connectable 0xFEF3 advertiser and opens a small
 * Weave-over-GATT socket before the normal Nearby stream begins. This server
 * registers the Weave write/notify characteristics next to the slot-0
 * advertisement (all inside one 0xFEF3 service so stock Galaxy/Pixel scanners
 * find them) and demultiplexes the first virtual Nearby socket back into the
 * Quick Share receive pipeline via [GsStreamConnection].
 *
 * UNVERIFIED against stock Android until captured on-device.
 */
class BleSocketStreamConnection implements GsStreamConnection {
  private listener?: (chunk: Uint8Array) => void;
  private closeListener?: () => void;
  private closed: boolean = false;

  private readonly session: BleSocketSession;

  constructor(session: BleSocketSession) {
    this.session = session;
  }

  onData(listener: (chunk: Uint8Array) => void): void {
    this.listener = listener;
  }

  onClose(listener: () => void): void {
    this.closeListener = listener;
    if (this.closed) { listener(); }
  }

  feed(chunk: Uint8Array): void {
    if (!this.closed && this.listener !== undefined) {
      this.listener(chunk);
    }
  }

  sendBytes(data: Uint8Array): Promise<void> {
    if (this.closed) {
      return Promise.resolve();
    }
    this.session.sendSocketBytes(data);
    return Promise.resolve();
  }

  close(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.listener = undefined;
    this.closeListener?.();
    this.session.onStreamClosed();
  }

  isClosed(): boolean {
    return this.closed;
  }
}

class BleSocketSession {
  private readonly deviceId: string;
  private readonly gattServer: ble.GattServer;
  private packetSize: number;
  private readonly notificationQueue: Uint8Array[] = [];
  private readonly messageBuffer: number[] = [];
  private readonly connection: (conn: GsStreamConnection) => void;
  private stream?: BleSocketStreamConnection;
  private introReceived: boolean = false;
  private subscribed: boolean = false;
  private subscriptionMode: 'notify' | 'indicate' | 'disabled' = 'disabled';
  private sending: boolean = false;
  private closed: boolean = false;
  private sendCounter: number = 1;
  onEnabled?: (deviceId: string) => void;

  constructor(deviceId: string, gattServer: ble.GattServer, negotiationPacketSize: number,
    onConnection: (conn: GsStreamConnection) => void) {
    this.deviceId = deviceId;
    this.gattServer = gattServer;
    this.packetSize = negotiationPacketSize;
    this.connection = onConnection;
  }

  setSubscription(mode: 'notify' | 'indicate' | 'disabled'): void {
    this.subscriptionMode = mode;
    this.subscribed = mode !== 'disabled';
    Lg.i('[QUICKSHARE][BLE socket] subscription=' + mode + ' device=' + this.deviceId);
    this.drainNotifications();
  }

  setMtu(mtu: number): void {
    // On MTU negotiation the server can raise the usable payload; the client's
    // ConnectionRequest.maxPacketSize usually already reflects it, so we keep
    // packetSize fixed at the negotiated value and only log the bump.
    Lg.i('[QUICKSHARE][BLE socket] mtu=' + mtu + ' packetSize=' + this.packetSize + ' device=' + this.deviceId);
  }

  static cccdMode(value: Uint8Array): 'notify' | 'indicate' | 'disabled' {
    if (value.length > 0) {
      if (value[0] === 1) {
        return 'notify';
      }
      if (value[0] === 2) {
        return 'indicate';
      }
    }
    return 'disabled';
  }

  cccdValue(): Uint8Array {
    if (this.subscriptionMode === 'notify') {
      return CCCD_NOTIFY;
    }
    if (this.subscriptionMode === 'indicate') {
      return CCCD_INDICATE;
    }
    return new Uint8Array([0, 0]);
  }

  onIncomingWeavePacket(packetBytes: Uint8Array): void {
    if (this.closed) {
      return;
    }
    if (packetBytes.length <= 16) {
      Lg.i('[QUICKSHARE][BLE socket] small write len=' + packetBytes.length
        + ' device=' + this.deviceId);
    }
    const packet: WeaveConnectionRequest | WeaveConnectionConfirm | WeaveDataPacket | WeaveConnectionClose | undefined =
      NearbyBleSocketCodec.parseWeavePacket(packetBytes);
    if (packet instanceof WeaveConnectionRequest) {
      this.handleConnectionRequest(packet);
    } else if (packet instanceof WeaveConnectionClose) {
      this.close();
    } else if (packet instanceof WeaveDataPacket) {
      this.handleDataPacket(packet);
    } else {
      Lg.w('[QUICKSHARE][BLE socket] invalid Weave packet len=' + packetBytes.length);
    }
  }

  close(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.notificationQueue.length = 0;
    this.stream?.close();
  }

  sendSocketBytes(bytes: Uint8Array): void {
    if (this.closed) {
      return;
    }
    const payload: Uint8Array = ByteUtils.concat([NEARBY_SERVICE_ID_HASH, bytes]);
    this.sendWeavePayload(payload);
  }

  onStreamClosed(): void {
    // The protocol layer closed the stream; nothing to do besides stop queueing.
  }

  private handleConnectionRequest(packet: WeaveConnectionRequest): void {
    // A stock sender writes the Weave ConnectionRequest on To-Peripheral; it
    // expects ConnectionConfirm back as a notification on From-Peripheral. Some
    // Android builds subscribe (write CCCD) only after this first write, or the OS
    // handles the CCCD without surfacing descriptorWrite to us. Treat the
    // ConnectionRequest as "peer is ready" so we don't queue the confirm behind a
    // subscription that never arrives.
    this.subscribed = true;
    this.subscriptionMode = 'notify';
    if (packet.maxVersion < WEAVE_VERSION || packet.minVersion > WEAVE_VERSION) {
      this.enqueueNotification(NearbyBleSocketCodec.encodeConnectionClose(this.sendCounter, 2));
      return;
    }
    let requested: number = packet.maxPacketSize > 0 ? packet.maxPacketSize : WEAVE_DEFAULT_ATT_PAYLOAD_SIZE;
    if (requested > WEAVE_MAX_PACKET_SIZE) {
      requested = WEAVE_MAX_PACKET_SIZE;
    }
    if (requested < WEAVE_MIN_PACKET_SIZE) {
      requested = WEAVE_MIN_PACKET_SIZE;
    }
    this.packetSize = requested;
    this.enqueueNotification(NearbyBleSocketCodec.encodeConnectionConfirm(WEAVE_VERSION, requested));
    this.sendCounter = 1;
    Lg.i('[QUICKSHARE][BLE socket] Weave connected packetSize=' + requested + ' device=' + this.deviceId);
  }

  private handleDataPacket(packet: WeaveDataPacket): void {
    if (packet.firstPacket) {
      this.messageBuffer.length = 0;
    }
    if (this.messageBuffer.length + packet.data.length > 16 * 1024 * 1024 + 7) {
      this.close();
      return;
    }
    for (let i = 0; i < packet.data.length; i++) {
      this.messageBuffer.push(packet.data[i]);
    }
    if (!packet.lastPacket) {
      return;
    }
    const message: Uint8Array = new Uint8Array(this.messageBuffer);
    this.messageBuffer.length = 0;
    this.handleSocketMessage(message);
  }

  private handleSocketMessage(message: Uint8Array): void {
    if (!this.introReceived) {
      this.handleIntroductionMessage(message);
      return;
    }
    this.handleServiceMessage(message);
  }

  private handleIntroductionMessage(message: Uint8Array): void {
    const control: BleSocketControlFrame | undefined = NearbyBleSocketCodec.parseControlPacket(message);
    const isIntroduction: boolean = control !== undefined
      && control.type === BleSocketControlType.INTRODUCTION
      && control.introduction !== undefined
      && control.introduction.socketVersion === BleSocketSocketVersion.V2
      && NearbyBleSocketCodec.startsWith(control.introduction.serviceIdHash, NEARBY_SERVICE_ID_HASH);
    if (isIntroduction) {
      this.introReceived = true;
      Lg.i('[QUICKSHARE][BLE socket] Introduction accepted device=' + this.deviceId);
      if (this.onEnabled !== undefined) {
        this.onEnabled(this.deviceId);
      }
    } else {
      Lg.w('[QUICKSHARE][BLE socket] discarded non-introduction first message device=' + this.deviceId);
    }
  }

  private handleServiceMessage(message: Uint8Array): void {
    if (NearbyBleSocketCodec.isControlPacket(message)) {
      const control: BleSocketControlFrame | undefined = NearbyBleSocketCodec.parseControlPacket(message);
      if (control !== undefined && control.type === BleSocketControlType.DISCONNECTION) {
        Lg.i('[QUICKSHARE][BLE socket] peer disconnection device=' + this.deviceId);
        this.close();
      }
      return;
    }
    if (message.length <= NEARBY_SERVICE_ID_HASH.length
      || !NearbyBleSocketCodec.startsWith(message, NEARBY_SERVICE_ID_HASH)) {
      Lg.w('[QUICKSHARE][BLE socket] discarded BLE payload for unexpected service hash device=' + this.deviceId);
      return;
    }
    const payload: Uint8Array = message.slice(NEARBY_SERVICE_ID_HASH.length);
    // The PacketAcknowledgement is a socket control packet (00 00 00 + proto). It
    // must be wrapped in a Weave DATA packet (counter + first/last bits) before
    // notifying; sending it raw makes Android's Weave client reject it with
    // "expected remote packet counter 1 but found 0" / "first packet does not have
    // first packet bit".
    this.sendWeavePayload(NearbyBleSocketCodec.encodePacketAckPacket(NEARBY_SERVICE_ID_HASH, payload.length));
    if (this.stream === undefined) {
      this.stream = new BleSocketStreamConnection(this);
      Lg.i('[QUICKSHARE][BLE socket] raw Nearby stream ready device=' + this.deviceId);
      this.connection(this.stream);
    }
    this.stream.feed(payload);
  }

  private sendWeavePayload(payload: Uint8Array): void {
    const maxChunk: number = Math.max(1, this.packetSize - WEAVE_HEADER_SIZE);
    let offset: number = 0;
    let counter: number = this.sendCounter;
    while (offset < payload.length) {
      const n: number = Math.min(maxChunk, payload.length - offset);
      const first: boolean = offset === 0;
      const last: boolean = offset + n >= payload.length;
      this.enqueueNotification(
        NearbyBleSocketCodec.encodeDataPacket(counter, first, last, payload.slice(offset, offset + n))
      );
      counter = (counter + 1) % WEAVE_MAX_PACKET_COUNTER;
      offset += n;
    }
    this.sendCounter = counter;
  }

  private enqueueNotification(packet: Uint8Array): void {
    if (this.closed) {
      return;
    }
    Lg.i('[QUICKSHARE][BLE socket] enqueue notification len=' + packet.length + ' device=' + this.deviceId);
    this.notificationQueue.push(packet);
    this.drainNotifications();
  }

  private drainNotifications(): void {
    if (this.closed) {
      return;
    }
    if (!this.subscribed) {
      Lg.i('[QUICKSHARE][BLE socket] notify blocked: not subscribed queueLen='
        + this.notificationQueue.length + ' device=' + this.deviceId);
      return;
    }
    if (this.sending) {
      return;
    }
    const packet: Uint8Array | undefined = this.notificationQueue.shift();
    if (packet === undefined) {
      return;
    }
    this.sending = true;
    Lg.i('[QUICKSHARE][BLE socket] send notification len=' + packet.length
      + ' confirm=' + (this.subscriptionMode === 'indicate') + ' device=' + this.deviceId);
    const notify: ble.NotifyCharacteristic = {
      serviceUuid: BLE_SOCKET_SECOND_PROFILE_SERVICE_UUID,
      characteristicUuid: BLE_SOCKET_FROM_PERIPHERAL_UUID,
      characteristicValue: ByteUtils.toArrayBuffer(packet),
      confirm: this.subscriptionMode === 'indicate'
    };
    this.gattServer.notifyCharacteristicChanged(this.deviceId, notify)
      .then((): void => {
        this.sending = false;
        this.drainNotifications();
      })
      .catch((error: Object): void => {
        Lg.w('[QUICKSHARE][BLE socket] notify failed: ' + JSON.stringify(error));
        this.sending = false;
        this.drainNotifications();
      });
  }
}

export class NearbyBleSocketServer {
  private gattServer?: ble.GattServer;
  private started: boolean = false;
  private readonly sessions: Map<string, BleSocketSession> = new Map();
  onSessionStart?: (deviceId: string) => void;

  async start(config: NearbyBleSocketServerConfig): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    try {
      const gattServer: ble.GattServer = ble.createGattServer();
      this.gattServer = gattServer;

      const toPeripheral: ble.BLECharacteristic = {
        serviceUuid: BLE_SOCKET_SECOND_PROFILE_SERVICE_UUID,
        characteristicUuid: BLE_SOCKET_TO_PERIPHERAL_UUID,
        characteristicValue: new ArrayBuffer(0),
        descriptors: [],
        properties: { write: true, writeNoResponse: true },
        permissions: { write: true }
      };
      const cccd: ble.BLEDescriptor = {
        serviceUuid: BLE_SOCKET_SECOND_PROFILE_SERVICE_UUID,
        characteristicUuid: BLE_SOCKET_FROM_PERIPHERAL_UUID,
        descriptorUuid: BLE_SOCKET_CCCD_UUID,
        descriptorValue: new Uint8Array([0, 0]).buffer,
        permissions: { read: true, write: true }
      };
      const fromPeripheral: ble.BLECharacteristic = {
        serviceUuid: BLE_SOCKET_SECOND_PROFILE_SERVICE_UUID,
        characteristicUuid: BLE_SOCKET_FROM_PERIPHERAL_UUID,
        characteristicValue: new ArrayBuffer(0),
        descriptors: [cccd],
        properties: { read: true, notify: true, indicate: true },
        permissions: { read: true }
      };
      const advertisement: ble.BLECharacteristic = {
        serviceUuid: BLE_SOCKET_SERVICE_UUID,
        characteristicUuid: config.advertisementCharacteristicUuid,
        characteristicValue: ByteUtils.toArrayBuffer(config.gattAdvertisement),
        descriptors: [],
        properties: { read: true },
        permissions: { read: true }
      };
      // Two services: the standard 0xFEF3 carries the slot-0 advertisement, and
      // the Nearby second-profile socket service (0000fef3-0004-...) carries the
      // Weave write/notify characteristics. Stock Android's socket client looks
      // for the Weave chars under the 0004 service; keeping them only in the
      // standard 0xFEF3 resulted in Android connect+MTU+disconnect with no read.
      const advertisementService: ble.GattService = {
        serviceUuid: BLE_SOCKET_SERVICE_UUID,
        isPrimary: true,
        characteristics: [advertisement]
      };
      const socketService: ble.GattService = {
        serviceUuid: BLE_SOCKET_SECOND_PROFILE_SERVICE_UUID,
        isPrimary: true,
        characteristics: [toPeripheral, fromPeripheral]
      };
      gattServer.addService(advertisementService);
      gattServer.addService(socketService);

      gattServer.on('characteristicRead', (request: ble.CharacteristicReadRequest): void => {
        Lg.i('[QUICKSHARE][BLE socket] read char=' + request.characteristicUuid
          + ' offset=' + request.offset + ' device=' + request.deviceId);
        if (NearbyBleSocketServer.sameUuid(request.characteristicUuid, config.advertisementCharacteristicUuid)) {
          this.respondRead(request, config.gattAdvertisement);
        } else if (NearbyBleSocketServer.sameUuid(request.characteristicUuid, BLE_SOCKET_FROM_PERIPHERAL_UUID)) {
          this.respondRead(request, new Uint8Array(0));
        }
      });
      gattServer.on('characteristicWrite', (request: ble.CharacteristicWriteRequest): void => {
        Lg.i('[QUICKSHARE][BLE socket] write char=' + request.characteristicUuid
          + ' len=' + request.value.byteLength + ' offset=' + request.offset
          + ' needRsp=' + request.needRsp + ' device=' + request.deviceId);
        const session: BleSocketSession = this.sessionFor(request.deviceId, config.onConnection);
        let status: number = 0;
        if (NearbyBleSocketServer.sameUuid(request.characteristicUuid, BLE_SOCKET_TO_PERIPHERAL_UUID) && request.offset === 0) {
          session.onIncomingWeavePacket(new Uint8Array(request.value));
        } else {
          status = 0x0f;
          Lg.w('[QUICKSHARE][BLE socket] reject write char=' + request.characteristicUuid
            + ' offset=' + request.offset + ' device=' + request.deviceId);
        }
        if (request.needRsp) {
          gattServer.sendResponse({
            deviceId: request.deviceId,
            transId: request.transId,
            status: status,
            offset: request.offset,
            value: new ArrayBuffer(0)
          });
        }
      });
      gattServer.on('descriptorWrite', (request: ble.DescriptorWriteRequest): void => {
        Lg.i('[QUICKSHARE][BLE socket] descWrite desc=' + request.descriptorUuid
          + ' char=' + request.characteristicUuid
          + ' offset=' + request.offset + ' device=' + request.deviceId);
        const mode: 'notify' | 'indicate' | 'disabled' = BleSocketSession.cccdMode(new Uint8Array(request.value));
        if (NearbyBleSocketServer.sameUuid(request.descriptorUuid, BLE_SOCKET_CCCD_UUID)
          && NearbyBleSocketServer.sameUuid(request.characteristicUuid, BLE_SOCKET_FROM_PERIPHERAL_UUID)) {
          const session: BleSocketSession = this.sessionFor(request.deviceId, config.onConnection);
          session.setSubscription(mode);
        }
        if (request.needRsp) {
          gattServer.sendResponse({
            deviceId: request.deviceId,
            transId: request.transId,
            status: 0,
            offset: request.offset,
            value: new ArrayBuffer(0)
          });
        }
      });
      gattServer.on('descriptorRead', (request: ble.DescriptorReadRequest): void => {
        Lg.i('[QUICKSHARE][BLE socket] descRead desc=' + request.descriptorUuid
          + ' char=' + request.characteristicUuid + ' offset=' + request.offset + ' device=' + request.deviceId);
        if (NearbyBleSocketServer.sameUuid(request.descriptorUuid, BLE_SOCKET_CCCD_UUID)) {
          const session: BleSocketSession = this.sessionFor(request.deviceId, config.onConnection);
          gattServer.sendResponse({
            deviceId: request.deviceId,
            transId: request.transId,
            status: 0,
            offset: request.offset,
            value: ByteUtils.toArrayBuffer(session.cccdValue())
          });
        }
      });
      gattServer.on('connectionStateChange', (state: ble.BLEConnectionChangeState): void => {
        Lg.i('[QUICKSHARE][BLE socket] connState=' + state.state + ' device=' + state.deviceId);
        if (state.state === constant.ProfileConnectionState.STATE_CONNECTED) {
          this.sessionFor(state.deviceId, config.onConnection);
        } else {
          this.sessions.get(state.deviceId)?.close();
          this.sessions.delete(state.deviceId);
        }
      });

      // Best-effort MTU bump: not detectable via a GATT server event, so the
      // negotiated packet size follows the client's ConnectionRequest.
      Lg.i('[QUICKSHARE][BLE socket] server active service=' + BLE_SOCKET_SERVICE_UUID);
    } catch (error) {
      this.started = false;
      Lg.w('[QUICKSHARE][BLE socket] start failed: ' + JSON.stringify(error));
    }
  }

  stop(): void {
    if (!this.started) {
      return;
    }
    this.started = false;
    this.sessions.forEach((session: BleSocketSession): void => { session.close(); });
    this.sessions.clear();
    if (this.gattServer !== undefined) {
      try {
        this.gattServer.off('characteristicRead');
        this.gattServer.off('characteristicWrite');
        this.gattServer.off('descriptorWrite');
        this.gattServer.off('descriptorRead');
        this.gattServer.off('connectionStateChange');
        this.gattServer.removeService(BLE_SOCKET_SERVICE_UUID);
        this.gattServer.removeService(BLE_SOCKET_SECOND_PROFILE_SERVICE_UUID);
        this.gattServer.close();
      } catch (error) {
        Lg.w('[QUICKSHARE][BLE socket] stop failed: ' + JSON.stringify(error));
      }
      this.gattServer = undefined;
    }
  }

  private sessionFor(deviceId: string, onConnection: (conn: GsStreamConnection) => void): BleSocketSession {
    let session: BleSocketSession | undefined = this.sessions.get(deviceId);
    if (session === undefined) {
      session = new BleSocketSession(deviceId, this.gattServer as ble.GattServer, WEAVE_DEFAULT_ATT_PAYLOAD_SIZE, onConnection);
      session.onEnabled = (id: string): void => {
        if (this.onSessionStart !== undefined) {
          this.onSessionStart(id);
        }
      };
      this.sessions.set(deviceId, session);
    }
    return session;
  }

  private respondRead(request: ble.CharacteristicReadRequest, value: Uint8Array): void {
    const offset: number = request.offset > 0 ? request.offset : 0;
    const response: Uint8Array = value.slice(Math.min(offset, value.length));
    const gattServer: ble.GattServer | undefined = this.gattServer;
    if (gattServer !== undefined) {
      gattServer.sendResponse({
        deviceId: request.deviceId,
        transId: request.transId,
        status: 0,
        offset: request.offset,
        value: ByteUtils.toArrayBuffer(response)
      });
    }
  }

  private static sameUuid(a: string, b: string): boolean {
    return a.length === b.length && a.toLowerCase() === b.toLowerCase();
  }
}
