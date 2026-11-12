import { GsBytes } from '../util/GsBytes';
import { ProtoWire } from './ProtoWire';
import { ProtoField, ProtoReader } from './ProtoReader';

/**
 * ConnectionRequestFrame.Medium 里我们用得到的取值（完整枚举见
 * `connections/implementation/proto/offline_wire_formats.proto`）。
 */
export enum NearbyMedium {
  WIFI_LAN = 5,
  WIFI_DIRECT = 8
}

/**
 * MediumMetadata.WifiDirectAuthType：P2P 凭据类型。
 * 官方 `base_pcp_handler.cc::ComputeIntersectionOfSupportedMediums()` 会拿双方的这一项**求交集**，
 * 没有公共类型就**根本不会选 Wi-Fi Direct**（连通告都不会发）。
 */
export enum WifiDirectAuthType {
  /** 官方枚举名就是 `WIFI_DIRECT_TYPE_UNKNOWN`（不是 `UNKNOWN`）。 */
  WIFI_DIRECT_TYPE_UNKNOWN = 0,
  /** ssid + password（Android 支持，Windows 不支持）—— HarmonyOS 只实现了这一类。 */
  WIFI_DIRECT_WITH_PASSWORD = 1,
  /** WPS PIN，官方已标记 `[deprecated = true]`；HarmonyOS 也没有对应入口。 */
  WIFI_DIRECT_WITH_PIN = 2,
  /** device_name / WPS PIN（Android+Windows 支持）—— `setDeviceName()` 是系统接口，三方应用做不了。 */
  WIFI_DIRECT_WITH_DEVICE_NAME = 3
}

/** 从对端 ConnectionRequest 里解析出的升级能力。 */
export interface NearbyCapabilitySnapshot {
  /** `ConnectionRequestFrame.mediums`(5)：对端支持升级到的介质。 */
  readonly mediums: number[];
  /** `medium_metadata.supported_wifi_direct_auth_types`(13)：对端支持的 P2P 凭据类型（可能为空=未声明）。 */
  readonly authTypes: number[];
  /** `medium_metadata.medium_role`(12)：对端能否当 GO。 */
  readonly supportsGroupOwner: boolean;
  /** `medium_metadata.medium_role`(12)：对端能否当 GC（入组）。 */
  readonly supportsGroupClient: boolean;
}

/**
 * 我们在 `ConnectionRequestFrame` 里声明的升级能力。
 *
 * 真机证据：官方端是否愿意给 P2P 通道，取决于两件事（见 docs/WIFI_DIRECT.md §2.4/§2.5）：
 *   1. `mediums`(field 5) 里有没有 `WIFI_DIRECT(8)`；仓库原先只写了 `WIFI_LAN(5)`；
 *   2. `medium_metadata.supported_wifi_direct_auth_types`(field 13) 与对端有没有交集。
 * 两条缺一都表现成「对端毫无反应」，所以这里显式声明。
 *
 * 只声明 `WIFI_DIRECT_WITH_PASSWORD`：HarmonyOS 的 `wifiManager.WifiP2PConfig` 只暴露
 * `groupName` + `passphrase`，没有 WPS PIN / device_name 入口（见 §2.5）。
 */
export class NearbyCapabilities {
  static readonly UPGRADE_MEDIUMS: number[] = [NearbyMedium.WIFI_LAN, NearbyMedium.WIFI_DIRECT];
  static readonly AUTH_TYPES: number[] = [WifiDirectAuthType.WIFI_DIRECT_WITH_PASSWORD];

  /** 构造 `ConnectionRequestFrame.medium_metadata`(field 7)。 */
  static mediumMetadata(): Uint8Array {
    const role: Uint8Array = ProtoWire.message([
      ProtoWire.fieldBool(1, true),   // support_wifi_direct_group_owner：接收端会建组当 GO
      ProtoWire.fieldBool(2, true)    // support_wifi_direct_group_client：发送端会入组当 GC
    ]);
    return ProtoWire.message([
      ProtoWire.nested(12, role),
      ProtoWire.fieldBytes(13, NearbyCapabilities.packedVarints(NearbyCapabilities.AUTH_TYPES))
    ]);
  }

  /** 解析对端 ConnectionRequest 的 body（即去掉 OfflineFrame/V1Frame 两层之后的 ConnectionRequestFrame）。 */
  static read(body: Uint8Array): NearbyCapabilitySnapshot {
    const mediums: number[] = [];
    const authTypes: number[] = [];
    let groupOwner: boolean = false;
    let groupClient: boolean = false;
    try {
      for (const field of new ProtoReader(body).readAll()) {
        if (field.field === 5 && field.wireType === 0) {
          mediums.push(field.value as number);
          continue;
        }
        if (field.field !== 7 || field.wireType !== 2) {
          continue;
        }
        for (const meta of new ProtoReader(field.value as Uint8Array).readAll()) {
          if (meta.field === 12 && meta.wireType === 2) {
            const role: NearbyCapabilitySnapshot = NearbyCapabilities.readRole(meta.value as Uint8Array);
            groupOwner = role.supportsGroupOwner;
            groupClient = role.supportsGroupClient;
          } else if (meta.field === 13 && meta.wireType === 2) {
            for (const value of NearbyCapabilities.readPacked(meta.value as Uint8Array)) {
              authTypes.push(value);
            }
          }
        }
      }
    } catch (error) {
      // 能力位解析失败不影响连接本身：按「未声明」处理。
      console.warn('[NEARBY] capability parse failed: ' + JSON.stringify(error));
    }
    return { mediums, authTypes, supportsGroupOwner: groupOwner, supportsGroupClient: groupClient };
  }

  static supportsWifiDirect(snapshot: NearbyCapabilitySnapshot): boolean {
    return snapshot.mediums.indexOf(NearbyMedium.WIFI_DIRECT) >= 0;
  }

  /**
   * 双方有没有公共的 P2P 凭据类型。
   * 对端**未声明**（空数组，例如旧版本或本仓库此前的发送端）时返回 true：不能因为对方没说就当成不支持。
   */
  static hasCommonAuthType(snapshot: NearbyCapabilitySnapshot): boolean {
    if (snapshot.authTypes.length === 0) {
      return true;
    }
    for (const type of snapshot.authTypes) {
      if (NearbyCapabilities.AUTH_TYPES.indexOf(type) >= 0) {
        return true;
      }
    }
    return false;
  }

  private static readRole(role: Uint8Array): NearbyCapabilitySnapshot {
    let owner: boolean = false;
    let client: boolean = false;
    for (const field of new ProtoReader(role).readAll()) {
      if (field.wireType !== 0) {
        continue;
      }
      const value: number = field.value as number;
      if (field.field === 1) {
        owner = value !== 0;
      } else if (field.field === 2) {
        client = value !== 0;
      }
    }
    return { mediums: [], authTypes: [], supportsGroupOwner: owner, supportsGroupClient: client };
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

  private static packedVarints(values: number[]): Uint8Array {
    const parts: Uint8Array[] = [];
    for (const value of values) {
      parts.push(ProtoWire.varint(value));
    }
    return GsBytes.concat(parts);
  }
}
