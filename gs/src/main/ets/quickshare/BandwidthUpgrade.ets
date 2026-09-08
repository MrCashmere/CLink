import { GsBytes } from '../util/GsBytes';
import { ProtoWire } from './ProtoWire';
import { ProtoReader } from './ProtoReader';
import { NearDropWire, OfflineType } from './NearDropWire';
import { WifiDirectUpgradeCredentials } from '../model/GsTypes';

export enum BandwidthUpgradeEvent {
  UPGRADE_PATH_AVAILABLE = 1,
  LAST_WRITE_TO_PRIOR_CHANNEL = 2,
  SAFE_TO_CLOSE_PRIOR_CHANNEL = 3,
  CLIENT_INTRODUCTION = 4,
  UPGRADE_FAILURE = 5,
  CLIENT_INTRODUCTION_ACK = 6,
  UPGRADE_PATH_REQUEST = 7
}

export enum BandwidthUpgradeMedium {
  WIFI_DIRECT = 8
}

export interface BandwidthUpgradeDecoded {
  readonly eventType: number;
  readonly mediums: number[];
  readonly endpointId: string;
}

const STA_FREQUENCY_NOT_SET: number = -1;

/**
 * Builders for `OfflineFrame{V1, BANDWIDTH_UPGRADE_NEGOTIATION}` (type 4).
 *
 * Quick Share's bandwidth-upgrade is a six-event protocol on top of
 * `BandwidthUpgradeNegotiationFrame.event_type`. On the RECEIVER (server) side we
 * answer a stock sender's `UPGRADE_PATH_REQUEST` with `UPGRADE_PATH_AVAILABLE`
 * carrying our Wi-Fi Direct group credentials, then ACK the sender's
 * `CLIENT_INTRODUCTION` on the upgraded socket. The wire shape follows the public
 * Nearby Connections `OfflineFrame` format, re-implemented for ArkTS.
 */
export class BandwidthUpgrade {
  static upgradePathAvailable(credentials: WifiDirectUpgradeCredentials): Uint8Array {
    const direct: Uint8Array = ProtoWire.message([
      ProtoWire.fieldString(1, credentials.ssid),
      ProtoWire.fieldString(2, credentials.password),
      ProtoWire.fieldInt32(3, credentials.port),
      ProtoWire.fieldInt32(4, credentials.frequency),
      ProtoWire.fieldString(5, credentials.gateway)
    ]);
    const info: Uint8Array = ProtoWire.message([
      ProtoWire.fieldEnum(1, BandwidthUpgradeMedium.WIFI_DIRECT),
      ProtoWire.nested(6, direct),
      ProtoWire.fieldBool(9, true)
    ]);
    const negotiation: Uint8Array = ProtoWire.message([
      ProtoWire.fieldEnum(1, BandwidthUpgradeEvent.UPGRADE_PATH_AVAILABLE),
      ProtoWire.nested(2, info)
    ]);
    return NearDropWire.offline(OfflineType.BANDWIDTH_UPGRADE_NEGOTIATION, negotiation);
  }

  static upgradePathRequest(mediums: number[]): Uint8Array {
    const packed: Uint8Array = BandwidthUpgrade.packedVarints(mediums);
    const request: Uint8Array = ProtoWire.message([ProtoWire.fieldBytes(1, packed)]);
    const info: Uint8Array = ProtoWire.message([
      ProtoWire.fieldEnum(1, BandwidthUpgradeMedium.WIFI_DIRECT),
      ProtoWire.nested(10, request)
    ]);
    const negotiation: Uint8Array = ProtoWire.message([
      ProtoWire.fieldEnum(1, BandwidthUpgradeEvent.UPGRADE_PATH_REQUEST),
      ProtoWire.nested(2, info)
    ]);
    return NearDropWire.offline(OfflineType.BANDWIDTH_UPGRADE_NEGOTIATION, negotiation);
  }

  static clientIntroduction(endpointId: string, lastEndpointId: string = ''): Uint8Array {
    const intro: Uint8Array = ProtoWire.message([
      ProtoWire.fieldString(1, endpointId),
      ProtoWire.fieldBool(2, false),
      ProtoWire.fieldString(3, lastEndpointId)
    ]);
    const negotiation: Uint8Array = ProtoWire.message([
      ProtoWire.fieldEnum(1, BandwidthUpgradeEvent.CLIENT_INTRODUCTION),
      ProtoWire.nested(3, intro)
    ]);
    return NearDropWire.offline(OfflineType.BANDWIDTH_UPGRADE_NEGOTIATION, negotiation);
  }

  static clientIntroductionAck(): Uint8Array {
    const negotiation: Uint8Array = ProtoWire.message([
      ProtoWire.fieldEnum(1, BandwidthUpgradeEvent.CLIENT_INTRODUCTION_ACK),
      ProtoWire.nested(4, new Uint8Array(0))
    ]);
    return NearDropWire.offline(OfflineType.BANDWIDTH_UPGRADE_NEGOTIATION, negotiation);
  }

  static lastWriteToPriorChannel(): Uint8Array {
    const negotiation: Uint8Array = ProtoWire.message([
      ProtoWire.fieldEnum(1, BandwidthUpgradeEvent.LAST_WRITE_TO_PRIOR_CHANNEL)
    ]);
    return NearDropWire.offline(OfflineType.BANDWIDTH_UPGRADE_NEGOTIATION, negotiation);
  }

  static safeToClosePriorChannel(staFrequency: number = STA_FREQUENCY_NOT_SET): Uint8Array {
    const safe: Uint8Array = ProtoWire.message([ProtoWire.fieldInt32(1, staFrequency)]);
    const negotiation: Uint8Array = ProtoWire.message([
      ProtoWire.fieldEnum(1, BandwidthUpgradeEvent.SAFE_TO_CLOSE_PRIOR_CHANNEL),
      ProtoWire.nested(5, safe)
    ]);
    return NearDropWire.offline(OfflineType.BANDWIDTH_UPGRADE_NEGOTIATION, negotiation);
  }

  static upgradeFailure(medium: number = BandwidthUpgradeMedium.WIFI_DIRECT): Uint8Array {
    const info: Uint8Array = ProtoWire.message([ProtoWire.fieldEnum(1, medium)]);
    const negotiation: Uint8Array = ProtoWire.message([
      ProtoWire.fieldEnum(1, BandwidthUpgradeEvent.UPGRADE_FAILURE),
      ProtoWire.nested(2, info)
    ]);
    return NearDropWire.offline(OfflineType.BANDWIDTH_UPGRADE_NEGOTIATION, negotiation);
  }

  /**
   * Parse an `OfflineFrame{V1, BANDWIDTH_UPGRADE_NEGOTIATION}`. Returns the event
   * type plus the requested mediums (for UPGRADE_PATH_REQUEST) and the client's
   * endpoint id (for CLIENT_INTRODUCTION). Returns `null` for any other frame.
   */
  static parse(raw: Uint8Array): BandwidthUpgradeDecoded | undefined {
    if ((ProtoReader.firstVarint(raw, 1) ?? -1) !== 1) {
      return undefined;
    }
    const v1: Uint8Array | undefined = ProtoReader.firstBytes(raw, 2);
    if (v1 === undefined) {
      return undefined;
    }
    const frameType: number = ProtoReader.firstVarint(v1, 1) ?? 0;
    if (frameType !== OfflineType.BANDWIDTH_UPGRADE_NEGOTIATION) {
      return undefined;
    }
    const negotiation: Uint8Array | undefined = ProtoReader.firstBytes(v1, 5);
    if (negotiation === undefined) {
      return undefined;
    }
    const eventType: number = ProtoReader.firstVarint(negotiation, 1) ?? 0;
    let mediums: number[] = [];
    let endpointId: string = '';
    const upgradePathInfo: Uint8Array | undefined = ProtoReader.firstBytes(negotiation, 2);
    if (upgradePathInfo !== undefined) {
      const request: Uint8Array | undefined = ProtoReader.firstBytes(upgradePathInfo, 10);
      if (request !== undefined) {
        mediums = BandwidthUpgrade.readPacked(request);
      }
    }
    const clientIntro: Uint8Array | undefined = ProtoReader.firstBytes(negotiation, 3);
    if (clientIntro !== undefined) {
      endpointId = GsBytes.decodeText(ProtoReader.firstBytes(clientIntro, 1) ?? new Uint8Array(0));
    }
    return { eventType: eventType, mediums: mediums, endpointId: endpointId };
  }

  /**
   * Decode the Wi-Fi Direct credentials carried by an inbound
   * `UPGRADE_PATH_AVAILABLE` frame. Returns `undefined` for any other frame or a
   * missing `wifi_direct_credentials` sub-message.
   */
  static parseWifiDirectCredentials(raw: Uint8Array): WifiDirectUpgradeCredentials | undefined {
    if ((ProtoReader.firstVarint(raw, 1) ?? -1) !== 1) {
      return undefined;
    }
    const v1: Uint8Array | undefined = ProtoReader.firstBytes(raw, 2);
    if (v1 === undefined) {
      return undefined;
    }
    const frameType: number = ProtoReader.firstVarint(v1, 1) ?? 0;
    if (frameType !== OfflineType.BANDWIDTH_UPGRADE_NEGOTIATION) {
      return undefined;
    }
    const negotiation: Uint8Array | undefined = ProtoReader.firstBytes(v1, 5);
    if (negotiation === undefined) {
      return undefined;
    }
    const eventType: number = ProtoReader.firstVarint(negotiation, 1) ?? 0;
    if (eventType !== BandwidthUpgradeEvent.UPGRADE_PATH_AVAILABLE) {
      return undefined;
    }
    const info: Uint8Array | undefined = ProtoReader.firstBytes(negotiation, 2);
    if (info === undefined) {
      return undefined;
    }
    const direct: Uint8Array | undefined = ProtoReader.firstBytes(info, 6);
    if (direct === undefined) {
      return undefined;
    }
    const ssid: string = GsBytes.decodeText(ProtoReader.firstBytes(direct, 1) ?? new Uint8Array(0));
    const password: string = GsBytes.decodeText(ProtoReader.firstBytes(direct, 2) ?? new Uint8Array(0));
    const port: number = ProtoReader.firstVarint(direct, 3) ?? 0;
    const frequency: number = ProtoReader.firstVarint(direct, 4) ?? -1;
    const gateway: string = GsBytes.decodeText(ProtoReader.firstBytes(direct, 5) ?? new Uint8Array(0));
    if (ssid.length === 0 || gateway.length === 0 || port <= 0) {
      return undefined;
    }
    return { ssid: ssid, password: password, port: port, gateway: gateway, frequency: frequency };
  }

  private static packedVarints(values: number[]): Uint8Array {
    const parts: Uint8Array[] = [];
    for (const value of values) {
      parts.push(ProtoWire.varint(value));
    }
    return GsBytes.concat(parts);
  }

  private static readPacked(bytes: Uint8Array): number[] {
    const out: number[] = [];
    let pos: number = 0;
    while (pos < bytes.length) {
      let value: number = 0;
      let shift: number = 0;
      while (pos < bytes.length) {
        const b: number = bytes[pos];
        pos += 1;
        value |= (b & 0x7f) << shift;
        if ((b & 0x80) === 0) {
          break;
        }
        shift += 7;
        if (shift > 28) {
          break;
        }
      }
      out.push(value >>> 0);
    }
    return out;
  }
}
