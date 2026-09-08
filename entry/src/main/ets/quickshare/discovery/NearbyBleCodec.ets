import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { ByteUtils } from '../../common/ByteUtils';

export interface NearbyBleMediumData {
  // Serialized BleAdvertisementHeader (v2) bytes, to be put as the 0xFEF3
  // service data in the BLE advertisement.
  readonly advertisementHeader: Uint8Array;
  // Serialized BleAdvertisement (v2) bytes, to be served by the GATT server as
  // the advertisement characteristic value for slot 0.
  readonly gattAdvertisement: Uint8Array;
  // The GATT characteristic UUID that Android will read to obtain the
  // BleAdvertisement value.
  readonly advertisementCharacteristicUuid: string;
}

// Nearby Connections BLE (copresence) service. Android's NearbyMediums scans
// this UUID and reads the GATT characteristic to obtain the endpoint.
export const NEARBY_COPRESENCE_SERVICE_UUID = '0000fef3-0000-1000-8000-00805f9b34fb';

// The NearbySharing service id hash carried by the BleAdvertisement.
const NEARBY_SHARING_SERVICE_ID_HASH: number[] = [0xfc, 0x9f, 0x5e];

// serviceIdBloomFilter observed in the Android logcat capture (NearbySharing).
// It is a 10-byte bloom filter that contains the NearbySharing service id, so a
// discoverer filtering for NearbySharing will match and read our GATT.
const NEARBY_SHARING_BLOOM_FILTER: number[] = [
  0x20, 0x00, 0x20, 0x50, 0x62, 0x10, 0x02, 0x03, 0x00, 0x00
];

// The advertising slot base UUID: Uuid(0x0000000000003000, 0x8000000000000000 | slot).
// For slot 0 this resolves to the RFC-4122 string "00000000-0000-3000-8000-000000000000".
const ADVERTISEMENT_UUID_MSB: number[] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x00];
const ADVERTISEMENT_UUID_LSB_BASE: number[] = [0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];

export class NearbyBleCodec {
  // Builds a BleAdvertisement (v2, non-fast) as the GATT characteristic value.
  // Byte layout (matching Nearby Connections BleAdvertisement::operator ByteArray):
  //   [version_byte][service_id_hash(3)][data_size uint32 BE][data][device_token(2)]
  // version_byte = version(3 bits)<<5 | socketVersion(3 bits)<<2 | fast<<1 | secondProfile.
  static async buildGattAdvertisement(endpointId: string, deviceName: string): Promise<Uint8Array> {
    const data = NearbyBleCodec.buildBleServiceData(endpointId, deviceName);
    // version=2, socketVersion=2, fast=false, secondProfile=true. Android's
    // NearbyMediums reads the second-profile bit to decide whether the
    // peripheral exposes the GATT Weave socket; leaving it 0 makes a stock peer
    // believe there is no socket and it will never attempt the ble-gatt path.
    const versionByte = (2 << 5) | (2 << 2) | 1;
    const parts: Uint8Array[] = [];
    parts.push(new Uint8Array([versionByte]));
    parts.push(new Uint8Array(NEARBY_SHARING_SERVICE_ID_HASH));
    // data_size is a big-endian u32 on the wire (BleAdvertisement::operator
    // ByteArray). An LE length makes a stock scanner mis-size the endpoint
    // payload and reject the advertisement.
    parts.push(NearbyBleCodec.writeU32Be(data.length));
    parts.push(data);
    // device_token = first 2 bytes of SHA-256(data), matching Nearby's
    // BleAdvertisement layout. A zero token makes some stock scanners
    // reject/ignore the GATT-returned advertisement.
    const token: Uint8Array = await NearbyBleCodec.sha256Truncated(data, 2);
    parts.push(token);
    return ByteUtils.concat(parts);
  }

  // Builds a full fast-form BleAdvertisement that carries the second-profile
  // (socket) bit directly in the advertisement payload. Stock Android's
  // NearbyMediums refuses to GATT-read a peripheral's slot-0 advertisement while
  // it is scanning ("Not allow Gatt actions during scanning"), so a GATT-only
  // secondProfile bit is never seen and BLE GATT socket is never selected.
  // Advertising the complete fast form (header + data_len + data + device_token)
  // lets a stock peer decode secondProfile=true from the scan itself.
  static async buildFastAdvertisement(endpointId: string, deviceName: string): Promise<Uint8Array> {
    const data: Uint8Array = NearbyBleCodec.buildBleServiceData(endpointId, deviceName);
    const header: number = (2 << 5) | (2 << 2) | 0x02 | 0x01; // version=2, socketVersion=2, fast=1, secondProfile=1
    const token: Uint8Array = await NearbyBleCodec.sha256Truncated(data, 2);
    const parts: Uint8Array[] = [];
    parts.push(new Uint8Array([header]));
    parts.push(new Uint8Array([data.length & 0xff]));
    parts.push(data);
    parts.push(token);
    return ByteUtils.concat(parts);
  }

  // Nearby "BleServiceData" body shared by the fast advertisement and the GATT
  // slot-0 value. Stock Quick Share uses:
  //   [0x23 (version=1<<5 | pcp=3)][endpoint_id(4)][info_len(1)][EndpointInfo]
  // Byte 0x23 is NOT a bare PCP marker: its high 3 bits are the protocol version
  // (must be 1). The info_len prefix is required, otherwise a stock peer reads
  // the first two EndpointInfo bytes as the whole descriptor and fails to show a
  // device name.
  static buildBleServiceData(endpointId: string, deviceName: string): Uint8Array {
    const idBytes: Uint8Array = ByteUtils.encodeText(endpointId).slice(0, 4);
    const endpointInfo: Uint8Array = NearbyBleCodec.buildEndpointInfo(deviceName);
    const parts: Uint8Array[] = [];
    parts.push(new Uint8Array([0x23]));
    parts.push(idBytes);
    parts.push(new Uint8Array([endpointInfo.length & 0xff]));
    parts.push(endpointInfo);
    return ByteUtils.concat(parts);
  }

  // Quick Share EndpointInfo: byte0 = (version(3)<<5 | visibility(1)<<4 |
  // deviceType(3)<<1 | reserved(1)). version MUST be 1; we emit a visible phone,
  // so byte0 = 0x20 | (phone<<1) = 0x22. Version 0 makes Android's Quick Share
  // picker fail to parse the name and drop the endpoint from the UI.
  private static buildEndpointInfo(deviceName: string): Uint8Array {
    const nameBytes: Uint8Array = ByteUtils.encodeText(deviceName.length > 0 ? deviceName : 'HarmonyOS');
    const nameLen: number = Math.min(nameBytes.length, 255);
    const endpointInfo: Uint8Array = new Uint8Array(18 + nameLen);
    endpointInfo[0] = (1 << 5) | (1 << 1); // version=1, visible, deviceType=phone
    const random: string = NearbyBleCodec.randomToken();
    for (let i = 0; i < 16; i++) {
      endpointInfo[i + 1] = parseInt(random.substring(i * 2, i * 2 + 2), 16);
    }
    endpointInfo[17] = nameLen;
    endpointInfo.set(nameBytes.slice(0, nameLen), 18);
    return endpointInfo;
  }

  private static writeU32Be(value: number): Uint8Array {
    const out: Uint8Array = new Uint8Array(4);
    out[0] = (value >>> 24) & 0xff;
    out[1] = (value >>> 16) & 0xff;
    out[2] = (value >>> 8) & 0xff;
    out[3] = value & 0xff;
    return out;
  }

  // Builds the BleAdvertisementHeader (v2) that goes into the 0xFEF3 service data
  // of the BLE advertisement. Byte layout:
  //   [version_and_numslots][service_id_bloom_filter(10)][advertisement_hash(4)][psm(0)]
  // version bits = 2<<5 = 0x40, extended bit = 0, numSlots = 1.
  static buildAdvertisementHeader(advertisementHash: Uint8Array): Uint8Array {
    const firstByte = (2 << 5) | (1 & 0x0f); // version=2, extended=false, numSlots=1
    const parts: Uint8Array[] = [];
    parts.push(new Uint8Array([firstByte]));
    parts.push(new Uint8Array(NEARBY_SHARING_BLOOM_FILTER));
    parts.push(advertisementHash.slice(0, 4));
    return ByteUtils.concat(parts);
  }

  // The GATT characteristic UUID that serves the slot-0 advertisement. For slot 0:
  //   bytes = [msb(8)][lsb(8)] = 00000000-0000-3000-8000-000000000000.
  static advertisementUuidString(slot: number): string {
    const msb = ADVERTISEMENT_UUID_MSB;
    const lsb = ADVERTISEMENT_UUID_LSB_BASE.map((b: number, i: number): number =>
      i === 7 ? (b | (slot & 0xff)) : b);
    const all = ByteUtils.concat([new Uint8Array(msb), new Uint8Array(lsb)]);
    const hex = ByteUtils.toHex(all);
    return hex.substring(0, 8) + '-' + hex.substring(8, 12) + '-' + hex.substring(12, 16) + '-'
      + hex.substring(16, 20) + '-' + hex.substring(20);
  }

  // SHA-256 of a byte array truncated to `length` bytes (Nearby's
  // GenerateAdvertisementHash = Sha256Hash(data, 4)).
  static async sha256Truncated(data: Uint8Array, length: number): Promise<Uint8Array> {
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data });
    const out = await md.digest();
    const full = new Uint8Array(out.data);
    return full.slice(0, length);
  }

  private static randomToken(): string {
    // Deterministic-ish random 16 bytes as hex, 32 chars. Using a simple source is
    // fine; the salt is not security critical.
    let out = '';
    for (let i = 0; i < 32; i++) {
      out += Math.floor(Math.random() * 16).toString(16);
    }
    return out;
  }
}
