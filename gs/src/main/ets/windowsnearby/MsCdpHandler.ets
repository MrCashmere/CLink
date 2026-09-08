import { GsBytes } from '../util/GsBytes';
import {
  GS_CDP_DEVICE_TYPE,
  GS_CDP_MANUFACTURER_ID,
  GS_CDP_SERVICE_UUID,
  GS_NEARSHARE_SCENARIO
} from '../model/GsConstants';

export { GS_CDP_DEVICE_TYPE, GS_CDP_MANUFACTURER_ID, GS_CDP_SERVICE_UUID, GS_NEARSHARE_SCENARIO };

const BLE_BEACON_VERSION = 1;
const BLE_BEACON_FLAGS_PUBLIC = 0x01;
const BLE_BEACON_DEVICE_NAME_MAX_BYTES = 17;
// ExtendedDeviceStatus flags: RemoteSessionsNotHosted(2) | NearShareAuthPolicyPermissive(8)
const BLE_BEACON_DEVICE_STATUS = 0x02 | 0x08;

export interface CdpAdvertisement {
  readonly version: number;
  readonly scenario: number;
  readonly flags: number;
  readonly deviceId: string;
  readonly deviceName: string;
  readonly services: string[];
  readonly deviceType: number;
  readonly deviceStatus: number;
  readonly capabilities: string[];
  readonly sessionHint: string;
}

/**
 * MS-CDP discovery beacon codec, aligned with nearby-sharing/android
 * `ShortDev.Microsoft.ConnectedDevices.Transports.Bluetooth.BLeBeacon`.
 *
 * The beacon is broadcast as **BLE manufacturer data** (company id 0x0006,
 * Microsoft) with this fixed layout — NOT a service-data TLV:
 *
 *     [0]          scenario     = 0x01 (ScenarioType.Bluetooth)
 *     [1]          deviceType   = 0x08 (DeviceType.Android)
 *     [2]          version<<5 | flags   (version=1, flags=1 Public)  => 0x21
 *     [3]          deviceStatus = 0x0A (RemoteSessionsNotHosted | NearShareAuthPolicyPermissive)
 *     [4..9]       MAC address (6 bytes)
 *     [10..]       device name (UTF-8, max 17 bytes)
 *
 * This replaces the legacy placeholder layout (bogus GUID, fake truncated
 * signature, TLV attributes) that was not byte-compatible with the reference.
 */
export class MsCdpHandler {
  static buildAdvertisement(deviceName: string, macHex: string): Uint8Array {
    const nameBytes = GsBytes.encodeText(deviceName);
    const name = nameBytes.length > BLE_BEACON_DEVICE_NAME_MAX_BYTES
      ? nameBytes.slice(0, BLE_BEACON_DEVICE_NAME_MAX_BYTES)
      : nameBytes;
    const head = new Uint8Array([
      GS_NEARSHARE_SCENARIO,
      GS_CDP_DEVICE_TYPE,
      (BLE_BEACON_VERSION << 5) | BLE_BEACON_FLAGS_PUBLIC,
      BLE_BEACON_DEVICE_STATUS
    ]);
    return GsBytes.concat([head, MsCdpHandler.macBytes(macHex), name]);
  }

  static parseAdvertisement(bytes: Uint8Array): CdpAdvertisement {
    if (bytes.length < 10) {
      throw new Error('CDP beacon too short');
    }
    const scenario = bytes[0];
    if (scenario !== GS_NEARSHARE_SCENARIO) {
      throw new Error(`unsupported CDP scenario ${scenario}`);
    }
    const version = (bytes[2] >>> 5) & 0x07;
    if (version !== BLE_BEACON_VERSION) {
      throw new Error(`unsupported CDP beacon version ${version}`);
    }
    const flags = bytes[2] & 0x1f;
    const deviceType = bytes[1];
    const deviceStatus = bytes[3];
    const deviceId = GsBytes.toHex(bytes.slice(4, 10));
    // Name runs to the end of the payload; real Windows beacons NUL-terminate,
    // so stop at the first NUL and trim trailing NULs defensively.
    let end = bytes.length;
    for (let i = 10; i < bytes.length; i++) {
      if (bytes[i] === 0) {
        end = i;
        break;
      }
    }
    const deviceName = GsBytes.decodeText(bytes.slice(10, end));
    const sessionHint = end < bytes.length ? GsBytes.decodeText(bytes.slice(end + 1)) : '';
    return {
      version,
      scenario,
      flags,
      deviceId,
      deviceName,
      services: ['NEARSHARE'],
      deviceType,
      deviceStatus,
      capabilities: MsCdpHandler.capabilities(deviceStatus),
      sessionHint
    };
  }

  static parseServiceData(payload: Uint8Array): CdpAdvertisement | undefined {
    try {
      return MsCdpHandler.parseAdvertisement(payload);
    } catch (error) {
      return undefined;
    }
  }

  private static macBytes(macHex: string): Uint8Array {
    const normalized = macHex.replace(/-/g, '').replace(/:/g, '').padEnd(12, '0').slice(0, 12);
    return GsBytes.fromHex(normalized);
  }

  private static capabilities(status: number): string[] {
    const values: string[] = ['NearShare'];
    if ((status & 0x02) !== 0) {
      values.push('RemoteSessionsNotHosted');
    }
    if ((status & 0x08) !== 0) {
      values.push('PermissiveAuth');
    }
    return values;
  }
}
