import { QuickShareDiscoveredDevice } from '../model/DiscoveredDevice';
import { ByteUtils } from '../../common/ByteUtils';

// The Nearby Fast Initiation signature (FE2C service data 0xFC 0x12 0x8E) is a
// proximity/wakeup trigger, not an endpoint advertisement. It carries no
// length-prefixed endpoint id, so we skip it here and handle it separately in
// BleScanner.
const FAST_INIT_SIGNATURE: number[] = [0xfc, 0x12, 0x8e];

export class QuickShareAdvertisementParser {
  parse(deviceId: string, name: string, rssi: number, payload: Uint8Array): QuickShareDiscoveredDevice | undefined {
    if (payload.length >= FAST_INIT_SIGNATURE.length) {
      let isFastInit = true;
      for (let i = 0; i < FAST_INIT_SIGNATURE.length; i++) {
        if (payload[i] !== FAST_INIT_SIGNATURE[i]) { isFastInit = false; break; }
      }
      if (isFastInit) { return undefined; }
    }
    // deviceId from the BLE scan result is the peripheral MAC; expose it as
    // `address` so a BLE-discovered peer can be used for a BLE GATT socket send.
    // The advertisement service data is length-variable (a full fast BleAdvertisement
    // or a bare BleServiceData), so we never discard a peer just because the
    // endpoint-id layout differs — the MAC alone is enough to drive a BLE send.
    // The peer's BleServiceData starts with 0x23 (PCP) followed by a 4-byte ASCII
    // endpoint id, the same value used in mDNS. Locate 0x23 and take the next 4
    // printable bytes so the BLE endpoint id matches the mDNS one for dedupe.
    let endpointId: string = '';
    const pcp: number = ByteUtils.indexOf(payload, new Uint8Array([0x23]), 0);
    if (pcp >= 0 && pcp + 5 <= payload.length) {
      endpointId = ByteUtils.decodeText(payload.slice(pcp + 1, pcp + 5));
    }
    const capability: number = payload.length > 8 ? (payload[8] ?? 0) : 0;
    return { id: deviceId, endpointId, name, capabilities: capability, rssi, address: deviceId };
  }
}
