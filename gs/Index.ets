export { GsFacadeImpl } from './src/main/ets/GsImpl';
export { ProtoWire } from './src/main/ets/quickshare/ProtoWire';
export { ProtoReader } from './src/main/ets/quickshare/ProtoReader';
export { NearDropWire } from './src/main/ets/quickshare/NearDropWire';
export { SecureMessage } from './src/main/ets/quickshare/SecureMessage';
export {
  BandwidthUpgrade,
  BandwidthUpgradeEvent,
  BandwidthUpgradeMedium
} from './src/main/ets/quickshare/BandwidthUpgrade';
export {
  GS_QUICKSHARE_PORT,
  GS_NEARSHARE_PORT,
  GS_CDP_SERVICE_UUID,
  GS_NEARSHARE_SCENARIO,
  GS_CDP_MANUFACTURER_ID,
  GS_CDP_DEVICE_TYPE
} from './src/main/ets/model/GsConstants';
export type { GsProtocolKind } from './src/main/ets/model/GsTypes';
export type {
  GsDevice,
  GsOutgoingFile,
  GsIncomingFile,
  GsSessionFileMeta,
  GsSendHooks,
  GsReceiveHooks,
  GsTlsMaterial,
  GsTlsProvider,
  GsDeps,
  GsStreamConnection,
  GsCdpDevice,
  WifiDirectUpgradeCredentials
} from './src/main/ets/model/GsTypes';
