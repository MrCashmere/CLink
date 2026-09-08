export const GS_QUICKSHARE_PORT = 53318;
export const GS_NEARSHARE_PORT = 5050;

// Verified against nearby-sharing/android (ShortDev.Microsoft.ConnectedDevices):
// - The CDP discovery beacon is *manufacturer data* under Microsoft's company
//   id 0x0006, carrying the fixed-layout BLeBeacon payload.
// - Beacon byte 0 is the ScenarioType: 1 = Bluetooth (see BLeBeacon.cs /
//   ScenarioType.cs). The legacy 0x0B "NearShare" value is NOT used by the
//   current reference implementation.
// - Byte 1 is DeviceType (8 = Android).
export const GS_NEARSHARE_SCENARIO = 0x01;
export const GS_CDP_MANUFACTURER_ID = 0x0006;
export const GS_CDP_DEVICE_TYPE = 0x08;

// Microsoft Co-Discovery (CDP) service UUID — confirmed real (Windows Nearby
// Sharing BTHENUM instance, google/nearby ble_types). Still useful as a
// GATT/RFCOMM-level service identifier even though the discovery beacon itself
// is manufacturer data.
export const GS_CDP_SERVICE_UUID = 'a82efa21-ae5c-3dde-9bbc-f16da7b16c5a';