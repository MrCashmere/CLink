import { ByteUtils } from '../../common/ByteUtils';

/**
 * Weave + Nearby BLE socket framing for the second-profile GATT socket.
 *
 * Two layers are concatenated on the GATT characteristic:
 *
 *  1. Weave packet (1-byte header + body/data), which is the reliability /
 *     reassembly layer over a single GATT write or notification.
 *  2. Socket message: either a control packet (`00 00 00` prefix + a
 *     `SocketControlFrame` proto) or raw Nearby stream data (`FC 9F 5E` +
 *     payload), where the payload is the standard 4-byte length-prefixed
 *     `OfflineFrame` stream used by Quick Share over TCP.
 *
 * Byte layout is derived from the public Nearby Connections `/mediums` proto
 * (ble_frames.proto) and the Bada/LibreDrop open-source Weave framing. It is a
 * re-implementation for ArkTS of a publicly documented protocol, not copied
 * source. UNVERIFIED against stock Android until captured on-device.
 */

export const WEAVE_VERSION: number = 1;
export const WEAVE_HEADER_SIZE: number = 1;
export const WEAVE_MIN_PACKET_SIZE: number = 20;
export const WEAVE_MAX_PACKET_SIZE: number = 509;
export const WEAVE_DEFAULT_ATT_PAYLOAD_SIZE: number = 20;
export const WEAVE_MAX_PACKET_COUNTER: number = 8;
const WEAVE_CLOSE_NO_COMMON_VERSION: number = 2;

const WEAVE_PACKET_TYPE_CONTROL: number = 0x80;
const WEAVE_PACKET_COUNTER_MASK: number = 0x70;
const WEAVE_PACKET_COUNTER_SHIFT: number = 4;
const WEAVE_CONTROL_COMMAND_MASK: number = 0x0f;
const WEAVE_CONTROL_CONNECTION_REQUEST: number = 0;
const WEAVE_CONTROL_CONNECTION_CONFIRM: number = 1;
const WEAVE_CONTROL_CONNECTION_CLOSE: number = 2;
const WEAVE_DATA_FIRST_FLAG: number = 0x08;
const WEAVE_DATA_LAST_FLAG: number = 0x04;

// serviceIdHash = first 3 bytes of SHA-256("NearbySharing") = FC 9F 5E.
export const NEARBY_SERVICE_ID_HASH: Uint8Array = new Uint8Array([0xfc, 0x9f, 0x5e]);
const CONTROL_PACKET_PREFIX: Uint8Array = new Uint8Array([0x00, 0x00, 0x00]);

export const BLE_SOCKET_SERVICE_UUID: string = '0000fef3-0000-1000-8000-00805f9b34fb';
// Nearby second-profile socket service. Stock Android's socket client looks for
// the Weave write/notify characteristics under THIS UUID (not the standard
// copresence service). Keep it as its own service alongside the standard 0xFEF3
// slot advertisement.
export const BLE_SOCKET_SECOND_PROFILE_SERVICE_UUID: string = '0000fef3-0004-1000-8000-001a11000100';
export const BLE_SOCKET_TO_PERIPHERAL_UUID: string = '00000100-0004-1000-8000-001a11000101';
export const BLE_SOCKET_FROM_PERIPHERAL_UUID: string = '00000100-0004-1000-8000-001a11000102';
export const BLE_SOCKET_CCCD_UUID: string = '00002902-0000-1000-8000-00805f9b34fb';

export enum BleSocketControlType {
  UNKNOWN = 0,
  INTRODUCTION = 1,
  DISCONNECTION = 2,
  PACKET_ACKNOWLEDGEMENT = 3
}

export enum BleSocketSocketVersion {
  UNKNOWN = 0,
  V1 = 1,
  V2 = 2
}

/** Sealed Weave packet variants. Class-based so ArkTS keeps a finite union. */
export class WeaveConnectionRequest {
  readonly minVersion: number;
  readonly maxVersion: number;
  readonly maxPacketSize: number;

  constructor(minVersion: number, maxVersion: number, maxPacketSize: number) {
    this.minVersion = minVersion;
    this.maxVersion = maxVersion;
    this.maxPacketSize = maxPacketSize;
  }
}

export class WeaveConnectionConfirm {
  readonly version: number;
  readonly packetSize: number;

  constructor(version: number, packetSize: number) {
    this.version = version;
    this.packetSize = packetSize;
  }
}

export class WeaveDataPacket {
  readonly counter: number;
  readonly firstPacket: boolean;
  readonly lastPacket: boolean;
  readonly data: Uint8Array;

  constructor(counter: number, firstPacket: boolean, lastPacket: boolean, data: Uint8Array) {
    this.counter = counter;
    this.firstPacket = firstPacket;
    this.lastPacket = lastPacket;
    this.data = data;
  }
}

export class WeaveConnectionClose {
  readonly reason: number;

  constructor(reason: number) {
    this.reason = reason;
  }
}

export type WeavePacket = WeaveConnectionRequest | WeaveConnectionConfirm | WeaveDataPacket | WeaveConnectionClose;

export class BleIntroductionFrame {
  readonly serviceIdHash: Uint8Array;
  readonly socketVersion: number;
  readonly salt: string;

  constructor(serviceIdHash: Uint8Array, socketVersion: number, salt: string) {
    this.serviceIdHash = serviceIdHash;
    this.socketVersion = socketVersion;
    this.salt = salt;
  }
}

export class BleDisconnectionFrame {
  readonly serviceIdHash: Uint8Array;

  constructor(serviceIdHash: Uint8Array) {
    this.serviceIdHash = serviceIdHash;
  }
}

export class BlePacketAckFrame {
  readonly serviceIdHash: Uint8Array;
  readonly receivedSize: number;

  constructor(serviceIdHash: Uint8Array, receivedSize: number) {
    this.serviceIdHash = serviceIdHash;
    this.receivedSize = receivedSize;
  }
}

export class BleSocketControlFrame {
  readonly type: BleSocketControlType;
  readonly introduction?: BleIntroductionFrame;
  readonly disconnection?: BleDisconnectionFrame;
  readonly packetAcknowledgement?: BlePacketAckFrame;

  constructor(type: BleSocketControlType, introduction?: BleIntroductionFrame,
    disconnection?: BleDisconnectionFrame, packetAcknowledgement?: BlePacketAckFrame) {
    this.type = type;
    this.introduction = introduction;
    this.disconnection = disconnection;
    this.packetAcknowledgement = packetAcknowledgement;
  }
}

export class NearbyBleSocketCodec {
  // ---- Weave packet encode -------------------------------------------
  static encodeConnectionRequest(packetCounter: number, minVersion: number, maxVersion: number,
    maxPacketSize: number): Uint8Array {
    const header: number = WEAVE_PACKET_TYPE_CONTROL
      | ((packetCounter % WEAVE_MAX_PACKET_COUNTER) << WEAVE_PACKET_COUNTER_SHIFT)
      | WEAVE_CONTROL_CONNECTION_REQUEST;
    const out: Uint8Array = new Uint8Array(7);
    out[0] = header;
    out[1] = (minVersion >>> 8) & 0xff;
    out[2] = minVersion & 0xff;
    out[3] = (maxVersion >>> 8) & 0xff;
    out[4] = maxVersion & 0xff;
    out[5] = (maxPacketSize >>> 8) & 0xff;
    out[6] = maxPacketSize & 0xff;
    return out;
  }

  static encodeConnectionConfirm(version: number, packetSize: number): Uint8Array {
    const header: number = WEAVE_PACKET_TYPE_CONTROL | WEAVE_CONTROL_CONNECTION_CONFIRM;
    const out: Uint8Array = new Uint8Array(5);
    out[0] = header;
    out[1] = (version >>> 8) & 0xff;
    out[2] = version & 0xff;
    out[3] = (packetSize >>> 8) & 0xff;
    out[4] = packetSize & 0xff;
    return out;
  }

  static encodeConnectionClose(packetCounter: number, reason: number): Uint8Array {
    const header: number = WEAVE_PACKET_TYPE_CONTROL
      | ((packetCounter % WEAVE_MAX_PACKET_COUNTER) << WEAVE_PACKET_COUNTER_SHIFT)
      | WEAVE_CONTROL_CONNECTION_CLOSE;
    const out: Uint8Array = new Uint8Array(3);
    out[0] = header;
    out[1] = (reason >>> 8) & 0xff;
    out[2] = reason & 0xff;
    return out;
  }

  static encodeDataPacket(packetCounter: number, firstPacket: boolean, lastPacket: boolean,
    data: Uint8Array): Uint8Array {
    let header: number = (packetCounter % WEAVE_MAX_PACKET_COUNTER) << WEAVE_PACKET_COUNTER_SHIFT;
    if (firstPacket) header |= WEAVE_DATA_FIRST_FLAG;
    if (lastPacket) header |= WEAVE_DATA_LAST_FLAG;
    const out: Uint8Array = new Uint8Array(1 + data.length);
    out[0] = header;
    out.set(data, 1);
    return out;
  }

  // ---- Weave packet decode -------------------------------------------
  static parseWeavePacket(bytes: Uint8Array): WeavePacket | undefined {
    if (bytes.length === 0) {
      return undefined;
    }
    const header: number = bytes[0] & 0xff;
    const counter: number = (header & WEAVE_PACKET_COUNTER_MASK) >>> WEAVE_PACKET_COUNTER_SHIFT;
    if ((header & WEAVE_PACKET_TYPE_CONTROL) !== 0) {
      return NearbyBleSocketCodec.parseControl(header, bytes);
    }
    return new WeaveDataPacket(counter, (header & WEAVE_DATA_FIRST_FLAG) !== 0,
      (header & WEAVE_DATA_LAST_FLAG) !== 0, bytes.slice(WEAVE_HEADER_SIZE));
  }

  private static parseControl(header: number, bytes: Uint8Array): WeavePacket | undefined {
    const command: number = header & WEAVE_CONTROL_COMMAND_MASK;
    if (command === WEAVE_CONTROL_CONNECTION_REQUEST) {
      if (bytes.length < 7) {
        return undefined;
      }
      return new WeaveConnectionRequest(NearbyBleSocketCodec.readU16(bytes, 1),
        NearbyBleSocketCodec.readU16(bytes, 3), NearbyBleSocketCodec.readU16(bytes, 5));
    }
    if (command === WEAVE_CONTROL_CONNECTION_CONFIRM) {
      if (bytes.length < 5) {
        return undefined;
      }
      return new WeaveConnectionConfirm(NearbyBleSocketCodec.readU16(bytes, 1),
        NearbyBleSocketCodec.readU16(bytes, 3));
    }
    if (command === WEAVE_CONTROL_CONNECTION_CLOSE) {
      const reason: number = bytes.length >= 3 ? NearbyBleSocketCodec.readU16(bytes, 1) : 0;
      return new WeaveConnectionClose(reason);
    }
    return undefined;
  }

  // ---- Socket control packet encode ----------------------------------
  static encodeIntroductionPacket(serviceIdHash: Uint8Array): Uint8Array {
    const intro: Uint8Array = NearbyBleSocketCodec.encodeIntroductionFrame(
      serviceIdHash, BleSocketSocketVersion.V2, '');
    return ByteUtils.concat([
      CONTROL_PACKET_PREFIX,
      NearbyBleSocketCodec.encodeControlFrame(BleSocketControlType.INTRODUCTION, intro)
    ]);
  }

  static encodeDisconnectionPacket(serviceIdHash: Uint8Array): Uint8Array {
    const disconn: Uint8Array = NearbyBleSocketCodec.encodeDisconnectionFrame(serviceIdHash);
    return ByteUtils.concat([
      CONTROL_PACKET_PREFIX,
      NearbyBleSocketCodec.encodeControlFrame(BleSocketControlType.DISCONNECTION, disconn)
    ]);
  }

  static encodePacketAckPacket(serviceIdHash: Uint8Array, receivedSize: number): Uint8Array {
    const ack: Uint8Array = NearbyBleSocketCodec.encodePacketAckFrame(serviceIdHash, receivedSize);
    return ByteUtils.concat([
      CONTROL_PACKET_PREFIX,
      NearbyBleSocketCodec.encodeControlFrame(BleSocketControlType.PACKET_ACKNOWLEDGEMENT, ack)
    ]);
  }

  // ---- Socket control packet decode ----------------------------------
  static parseControlPacket(packet: Uint8Array): BleSocketControlFrame | undefined {
    if (packet.length <= CONTROL_PACKET_PREFIX.length) {
      return undefined;
    }
    const hasControlPrefix: boolean = packet[0] === 0 && packet[1] === 0 && packet[2] === 0;
    if (!hasControlPrefix) {
      return undefined;
    }
    return NearbyBleSocketCodec.decodeControlFrame(packet.slice(CONTROL_PACKET_PREFIX.length));
  }

  static isControlPacket(packet: Uint8Array): boolean {
    return packet.length > 3 && packet[0] === 0 && packet[1] === 0 && packet[2] === 0;
  }

  static startsWith(bytes: Uint8Array, prefix: Uint8Array): boolean {
    if (bytes.length < prefix.length) {
      return false;
    }
    for (let i = 0; i < prefix.length; i++) {
      if (bytes[i] !== prefix[i]) {
        return false;
      }
    }
    return true;
  }

  private static encodeControlFrame(type: BleSocketControlType, body: Uint8Array): Uint8Array {
    const parts: Uint8Array[] = [];
    parts.push(NearbyBleSocketCodec.writeVarintField(1, type));
    // type==1 -> introduction (field 2), type==2 -> disconnection (field 3),
    // type==3 -> packet_acknowledgement (field 4).
    if (type === BleSocketControlType.INTRODUCTION) {
      parts.push(NearbyBleSocketCodec.writeBytesField(2, body));
    } else if (type === BleSocketControlType.DISCONNECTION) {
      parts.push(NearbyBleSocketCodec.writeBytesField(3, body));
    } else if (type === BleSocketControlType.PACKET_ACKNOWLEDGEMENT) {
      parts.push(NearbyBleSocketCodec.writeBytesField(4, body));
    }
    return ByteUtils.concat(parts);
  }

  private static decodeControlFrame(bytes: Uint8Array): BleSocketControlFrame | undefined {
    const reader = new VarintReader(bytes);
    let type: number = 0;
    const firstKey: number | undefined = reader.readVarint();
    if (firstKey !== undefined && (firstKey & 7) === 0 && (firstKey >>> 3) === 1) {
      const value: number | undefined = reader.readVarint();
      if (value !== undefined) {
        type = value;
      }
    }
    let introduction: BleIntroductionFrame | undefined = undefined;
    let disconnection: BleDisconnectionFrame | undefined = undefined;
    let packetAck: BlePacketAckFrame | undefined = undefined;
    for (;;) {
      const field: number | undefined = reader.readVarint();
      if (field === undefined) {
        break;
      }
      const wireType: number = field & 7;
      const fieldNum: number = field >>> 3;
      if (wireType === 2) {
        const bytesValue: Uint8Array | undefined = reader.readBytes();
        if (bytesValue === undefined) {
          break;
        }
        if (fieldNum === 2) {
          introduction = NearbyBleSocketCodec.decodeIntroductionFrame(bytesValue);
        } else if (fieldNum === 3) {
          disconnection = NearbyBleSocketCodec.decodeDisconnectionFrame(bytesValue);
        } else if (fieldNum === 4) {
          packetAck = NearbyBleSocketCodec.decodePacketAckFrame(bytesValue);
        }
      } else if (wireType === 0) {
        reader.skipVarint();
      } else {
        break;
      }
    }
    return new BleSocketControlFrame(type as BleSocketControlType, introduction, disconnection, packetAck);
  }

  private static encodeIntroductionFrame(serviceIdHash: Uint8Array, socketVersion: number, salt: string): Uint8Array {
    const parts: Uint8Array[] = [];
    parts.push(NearbyBleSocketCodec.writeBytesField(1, serviceIdHash));
    parts.push(NearbyBleSocketCodec.writeVarintField(2, socketVersion));
    if (salt.length > 0) {
      parts.push(NearbyBleSocketCodec.writeBytesField(3, ByteUtils.encodeText(salt)));
    }
    return ByteUtils.concat(parts);
  }

  private static decodeIntroductionFrame(bytes: Uint8Array): BleIntroductionFrame | undefined {
    const reader = new VarintReader(bytes);
    let serviceIdHash: Uint8Array = new Uint8Array(0);
    let socketVersion: number = 0;
    let salt: string = '';
    for (;;) {
      const field: number | undefined = reader.readVarint();
      if (field === undefined) {
        break;
      }
      const wireType: number = field & 7;
      const fieldNum: number = field >>> 3;
      if (wireType === 2) {
        const bytesValue: Uint8Array | undefined = reader.readBytes();
        if (bytesValue === undefined) {
          break;
        }
        if (fieldNum === 1) {
          serviceIdHash = bytesValue;
        } else if (fieldNum === 3) {
          salt = ByteUtils.decodeText(bytesValue);
        }
      } else if (wireType === 0) {
        const value: number | undefined = reader.readVarint();
        if (value === undefined) {
          break;
        }
        if (fieldNum === 2) {
          socketVersion = value;
        }
      } else {
        break;
      }
    }
    return new BleIntroductionFrame(serviceIdHash, socketVersion, salt);
  }

  private static encodeDisconnectionFrame(serviceIdHash: Uint8Array): Uint8Array {
    return NearbyBleSocketCodec.writeBytesField(1, serviceIdHash);
  }

  private static decodeDisconnectionFrame(bytes: Uint8Array): BleDisconnectionFrame | undefined {
    const reader = new VarintReader(bytes);
    let serviceIdHash: Uint8Array = new Uint8Array(0);
    for (;;) {
      const field: number | undefined = reader.readVarint();
      if (field === undefined) {
        break;
      }
      const fieldNum: number = field >>> 3;
      const wireType: number = field & 7;
      if (fieldNum === 1 && wireType === 2) {
        const bytesValue: Uint8Array | undefined = reader.readBytes();
        if (bytesValue !== undefined) {
          serviceIdHash = bytesValue;
        }
      } else if (wireType === 0) {
        reader.skipVarint();
      } else {
        break;
      }
    }
    return new BleDisconnectionFrame(serviceIdHash);
  }

  private static encodePacketAckFrame(serviceIdHash: Uint8Array, receivedSize: number): Uint8Array {
    const parts: Uint8Array[] = [];
    parts.push(NearbyBleSocketCodec.writeBytesField(1, serviceIdHash));
    parts.push(NearbyBleSocketCodec.writeVarintField(2, receivedSize));
    return ByteUtils.concat(parts);
  }

  private static decodePacketAckFrame(bytes: Uint8Array): BlePacketAckFrame | undefined {
    const reader = new VarintReader(bytes);
    let serviceIdHash: Uint8Array = new Uint8Array(0);
    let receivedSize: number = 0;
    for (;;) {
      const field: number | undefined = reader.readVarint();
      if (field === undefined) {
        break;
      }
      const fieldNum: number = field >>> 3;
      const wireType: number = field & 7;
      if (fieldNum === 1 && wireType === 2) {
        const bytesValue: Uint8Array | undefined = reader.readBytes();
        if (bytesValue !== undefined) {
          serviceIdHash = bytesValue;
        }
      } else if (fieldNum === 2 && wireType === 0) {
        const value: number | undefined = reader.readVarint();
        if (value !== undefined) {
          receivedSize = value;
        }
      } else {
        break;
      }
    }
    return new BlePacketAckFrame(serviceIdHash, receivedSize);
  }

  // ---- Small protobuf helpers ----------------------------------------
  static writeVarintField(field: number, value: number): Uint8Array {
    return NearbyBleSocketCodec.concatBytes(
      NearbyBleSocketCodec.varint((field << 3) & 0x7f),
      NearbyBleSocketCodec.varint(value)
    );
  }

  static writeBytesField(field: number, value: Uint8Array): Uint8Array {
    return NearbyBleSocketCodec.concatBytes(
      NearbyBleSocketCodec.varint(((field << 3) & 0x7f) | 2),
      NearbyBleSocketCodec.varint(value.length),
      value
    );
  }

  private static varint(value: number): Uint8Array {
    let v: number = value >>> 0;
    const out: number[] = [];
    while (v >= 0x80) {
      out.push((v & 0x7f) | 0x80);
      v >>>= 7;
    }
    out.push(v);
    return new Uint8Array(out);
  }

  private static readU16(bytes: Uint8Array, offset: number): number {
    return ((bytes[offset] & 0xff) << 8) | (bytes[offset + 1] & 0xff);
  }

  private static concatBytes(...parts: Uint8Array[]): Uint8Array {
    return ByteUtils.concat(parts);
  }
}

/** Minimal varint reader for decoding the tiny socket control protos. */
class VarintReader {
  private readonly bytes: Uint8Array;
  private pos: number;

  constructor(bytes: Uint8Array) {
    this.bytes = bytes;
    this.pos = 0;
  }

  readVarint(): number | undefined {
    let shift: number = 0;
    let result: number = 0;
    for (;;) {
      if (this.pos >= this.bytes.length) {
        return undefined;
      }
      const byte: number = this.bytes[this.pos];
      this.pos += 1;
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) === 0) {
        return result >>> 0;
      }
      shift += 7;
      if (shift > 28) {
        return result >>> 0;
      }
    }
  }

  skipVarint(): void {
    while (this.pos < this.bytes.length && (this.bytes[this.pos] & 0x80) !== 0) {
      this.pos += 1;
    }
    this.pos += 1;
  }

  readBytes(): Uint8Array | undefined {
    const length: number | undefined = this.readVarint();
    if (length === undefined) {
      return undefined;
    }
    if (this.pos + length > this.bytes.length) {
      return undefined;
    }
    const out: Uint8Array = this.bytes.slice(this.pos, this.pos + length);
    this.pos += length;
    return out;
  }

}
