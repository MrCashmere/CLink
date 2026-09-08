import { QuickShareAdvertisementParser } from '../entry/src/main/ets/quickshare/discovery/AdvertisementParser';
export function parsesEndpointAdvertisement(): boolean {
  const device = new QuickShareAdvertisementParser().parse('id', 'phone', -40, new Uint8Array([2, 0xab, 0xcd, 7]));
  return device !== undefined && device.endpointId === 'abcd' && device.capabilities === 7;
}

export function ignoresFastInitiationBeacon(): boolean {
  // A Nearby Fast Initiation beacon (FE2C service data 0xFC 0x12 0x8E) is a
  // proximity trigger and carries no length-prefixed endpoint id, so the parser
  // must skip it rather than build a bogus device.
  const device = new QuickShareAdvertisementParser().parse('id', 'phone', -40,
    new Uint8Array([0xfc, 0x12, 0x8e, 0x00, 0xfa]));
  return device === undefined;
}
