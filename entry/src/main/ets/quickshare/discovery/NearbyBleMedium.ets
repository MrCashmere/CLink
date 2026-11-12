import { LogCapture as Lg } from '../../common/LogCapture';
import ble from '@ohos.bluetooth.ble';
import access from '@ohos.bluetooth.access';
import { ByteUtils } from '../../common/ByteUtils';
import { NearbyBleSocketServer } from '../ble/NearbyBleSocketServer';
import { NearbyBleCodec, NEARBY_COPRESENCE_SERVICE_UUID } from './NearbyBleCodec';
import { GsStreamConnection } from '../../protocol/gs/GsFacade';

const QUICKSHARE_SERVICE_UUID = '0000fe2c-0000-1000-8000-00805f9b34fb';
const FAST_INIT_SIGNATURE: number[] = [0xfc, 0x12, 0x8e];

/**
 * The Nearby Connections "copresence" BLE medium. It advertises the FE2C Fast
 * Initiation beacon and the 0xFEF3 copresence service, and runs a single
 * GATT server that serves the slot-0 BleAdvertisement characteristic AND the
 * Nearby second-profile Weave socket (write/notify). Stock Android's
 * NearbyMediums discovers us, reads the advertisement, and, when it cannot
 * reach a WIFI_LAN endpoint, opens the BLE GATT socket and feeds the raw Nearby
 * stream back into the Quick Share receive pipeline.
 *
 * UNVERIFIED: requires on-device testing against stock Android.
 */
export class NearbyBleMedium {
  private readonly socketServer: NearbyBleSocketServer = new NearbyBleSocketServer();
  private onConnectionCb?: (conn: GsStreamConnection) => void;
  private started: boolean = false;
  private watching: boolean = false;
  private generation: number = 0;
  private startOperation?: Promise<boolean>;
  private endpointId: string = '';
  private deviceName: string = '';
  private readonly stateListener: (state: access.BluetoothState) => void = (state: access.BluetoothState): void => {
    if (state === access.BluetoothState.STATE_ON && this.watching) {
      this.start(this.endpointId, this.deviceName).catch((error: Error): void => {
        Lg.w('[QUICKSHARE] BLE retry failed: ' + error.message);
      });
    } else if (state === access.BluetoothState.STATE_OFF) {
      this.stopRuntime();
    }
  };

  setOnConnection(cb: (conn: GsStreamConnection) => void): void {
    this.onConnectionCb = cb;
  }

  setOnSessionStart(cb: (deviceId: string) => void): void {
    this.socketServer.onSessionStart = cb;
  }

  async start(endpointId: string, deviceName: string): Promise<boolean> {
    this.endpointId = endpointId;
    this.deviceName = deviceName;
    if (!this.watching) {
      try {
        access.on('stateChange', this.stateListener);
        this.watching = true;
      } catch (error) {
        Lg.w('[QUICKSHARE] BLE state subscription failed: ' + JSON.stringify(error));
      }
    }
    const generation: number = this.generation;
    if (this.startOperation !== undefined) {
      await this.startOperation;
    }
    if (generation !== this.generation) { return false; }
    if (this.started) {
      return true;
    }
    const operation: Promise<boolean> = this.startRuntime(endpointId, deviceName, generation);
    this.startOperation = operation;
    try {
      return await operation;
    } finally {
      if (this.startOperation === operation) {
        this.startOperation = undefined;
      }
    }
  }

  private async startRuntime(endpointId: string, deviceName: string, generation: number): Promise<boolean> {
    try {
      if (access.getState() !== access.BluetoothState.STATE_ON) {
        Lg.w('[QUICKSHARE] Nearby BLE medium skipped (bluetooth off)');
        return false;
      }
    } catch (error) {
      Lg.w('[QUICKSHARE] Nearby BLE medium skipped (bluetooth unavailable): ' + JSON.stringify(error));
      return false;
    }
    this.started = true;

    try {
      const gattAdvertisement: Uint8Array = await NearbyBleCodec.buildGattAdvertisement(endpointId, deviceName);
      if (generation !== this.generation) { return false; }
      await this.socketServer.start({
        gattAdvertisement: gattAdvertisement,
        advertisementCharacteristicUuid: NearbyBleCodec.advertisementUuidString(0),
        onConnection: (conn: GsStreamConnection): void => {
          if (this.onConnectionCb !== undefined) {
            this.onConnectionCb(conn);
          }
        }
      });

      if (generation !== this.generation) {
        this.socketServer.stop();
        return false;
      }
      // Fast-init beacon signature for the legacy two-part advertisement.
      const beacon: Uint8Array = new Uint8Array(5);
      beacon.set(FAST_INIT_SIGNATURE, 0);
      beacon[3] = 0x00;
      beacon[4] = 0xfa;
      const dummy: Uint8Array = NearbyBleMedium.secureRandom(8);
      let hash: Uint8Array = await NearbyBleCodec.sha256Truncated(dummy, 4);
      hash = await NearbyBleCodec.sha256Truncated(ByteUtils.concat([hash, gattAdvertisement]), 4);
      const header: Uint8Array = NearbyBleCodec.buildAdvertisementHeader(hash);
      const legacyAdv: ble.AdvertiseData = {
        serviceUuids: [QUICKSHARE_SERVICE_UUID],
        serviceData: [{ serviceUuid: QUICKSHARE_SERVICE_UUID, serviceValue: ByteUtils.toArrayBuffer(beacon) }],
        manufactureData: [],
        includeDeviceName: false
      };
      const legacyScanRt: ble.AdvertiseData = {
        serviceUuids: [NEARBY_COPRESENCE_SERVICE_UUID],
        serviceData: [{ serviceUuid: NEARBY_COPRESENCE_SERVICE_UUID, serviceValue: ByteUtils.toArrayBuffer(header) }],
        manufactureData: [],
        includeDeviceName: false
      };
      // API 24: AdvertiseSetting has no `isExtended` field (that is @since 26), so
      // extended advertising cannot be requested. Advertise the legacy two-part
      // (header + GATT slot) form, which is what API 24 supports.
      if (generation !== this.generation) { return false; }
      ble.startAdvertising({ interval: 160, txPower: -6, connectable: true }, legacyAdv, legacyScanRt);
      Lg.i('[QUICKSHARE] Nearby BLE medium advertised legacy (API 24)');
      return true;
    } catch (error) {
      this.started = false;
      this.socketServer.stop();
      Lg.w('[QUICKSHARE] Nearby BLE medium start failed: ' + JSON.stringify(error));
      return false;
    }
  }

  stop(): void {
    if (this.watching) {
      try {
        access.off('stateChange', this.stateListener);
      } catch (error) {
        Lg.w('[QUICKSHARE] BLE state unsubscribe failed: ' + JSON.stringify(error));
      }
      this.watching = false;
    }
    this.stopRuntime();
  }

  private stopRuntime(): void {
    this.generation += 1;
    const wasStarted: boolean = this.started;
    this.started = false;
    try {
      if (wasStarted) {
        ble.stopAdvertising();
      }
    } catch (error) {
      Lg.w('[QUICKSHARE] Nearby BLE medium stopAdvertising failed: ' + JSON.stringify(error));
    }
    this.socketServer.stop();
  }

  private static secureRandom(length: number): Uint8Array {
    const out: Uint8Array = new Uint8Array(length);
    for (let i = 0; i < length; i++) {
      out[i] = Math.floor(Math.random() * 256);
    }
    return out;
  }
}
