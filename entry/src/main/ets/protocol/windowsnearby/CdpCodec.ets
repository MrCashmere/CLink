/**
 * MS-CDP (Windows Nearby Sharing) binary wire layer.
 *
 * Mirrors the C# reference (ShortDev.Microsoft.ConnectedDevices):
 *   - Endianness.BigEndian message writer used for every on-wire message
 *   - CommonHeader (signature 0x3030, version 3)
 *   - BinaryMsgHeader (fragmentCount / fragmentIndex / messageId) that prefixes
 *     every app-layer (Session) payload
 *
 * This module has no platform dependencies and is safe to unit test.
 */

import { ByteUtils } from '../../common/ByteUtils';

export const CDP_SIGNATURE = 0x3030;
export const CDP_PROTOCOL_VERSION = 3;
export const CDP_TCP_PORT = 5040;
export const CDP_UDP_PORT = 5050;
export const CDP_HMAC_SIZE = 32;
export const CDP_IV_SIZE = 16;
export const CDP_PARTITION_SIZE = 102400; // 100 KiB
export const CDP_DEFAULT_FRAGMENT_SIZE = 16384;
export const CDP_MAX_FRAME_BYTES = 32 * 1024 * 1024;

/** MessageType enum (byte) from MessageType.cs. */
export enum CdpMessageType {
  None = 0,
  Discovery = 1,
  Connect = 2,
  Control = 3,
  Session = 4,
  Ack = 5,
  ReliabilityResponse = 6,
  Disconnect = 7
}

/** MessageFlags enum (short) from MessageFlags.cs. */
export enum CdpMessageFlags {
  ShouldAck = 0x0001,
  HasHMAC = 0x0002,
  SessionEncrypted = 0x0004,
  WakeTarget = 0x0008
}

/** AdditionalHeaderType enum from AdditionalHeaderType.cs. */
export enum CdpAdditionalHeaderType {
  None = 0,
  ReplyToId = 1,
  CorrelationVector = 2,
  WatermarkId = 3,
  UserMessageRequestId = 5,
  ChannelHostSettings = 0x81,
  PeerCapabilities = 0x82,
  Header131 = 0x83
}

/** An additional header record: type byte + size byte + raw value. */
export class CdpAdditionalHeader {
  readonly type: number;
  readonly value: Uint8Array;

  constructor(type: number, value: Uint8Array) {
    this.type = type;
    this.value = value;
  }
}

/**
 * CommonHeader, the header common to every CDP message.
 *
 * 64-bit fields are kept as raw 8-byte arrays so values that exceed the
 * JS safe-integer range survive a round trip exactly (the reference keeps
 * them as ulong and matches byte-for-byte for IV generation and ReplyToId).
 */
export class CdpCommonHeader {
  messageLength: number = 0;
  version: number = CDP_PROTOCOL_VERSION;
  type: number = 0;
  flags: number = 0;
  sequenceNumber: number = 0;
  requestId: Uint8Array = new Uint8Array(8);
  fragmentIndex: number = 0;
  fragmentCount: number = 1;
  sessionId: Uint8Array = new Uint8Array(8);
  channelId: Uint8Array = new Uint8Array(8);
  additionalHeaders: CdpAdditionalHeader[] = [];

  hasFlag(flag: number): boolean {
    return (this.flags & flag) !== 0;
  }

  setFlag(flag: number): void {
    this.flags = this.flags | flag;
  }

  /** Size of the serialised header, including the 2-byte end-of-header marker. */
  calcSize(): number {
    let size = 40;
    for (const header of this.additionalHeaders) {
      size += 2 + header.value.length;
    }
    return size + 2;
  }

  /** MessageLength = header size + payload size (payload may include HMAC). */
  setPayloadLength(payloadSize: number): void {
    this.messageLength = payloadSize + this.calcSize();
  }

  payloadSize(): number {
    return this.messageLength - this.calcSize();
  }

  /** ReplyToId lives in an additional header with a little-endian 8-byte value. */
  setReplyToId(requestId: Uint8Array): void {
    this.additionalHeaders = this.additionalHeaders.filter((header: CdpAdditionalHeader): boolean => header.type !== CdpAdditionalHeaderType.ReplyToId);
    // The on-wire value is the u64 in little-endian (BinaryPrimitives.WriteUInt64LittleEndian).
    const little = new Uint8Array(8);
    for (let i = 0; i < 8; i++) {
      little[i] = requestId[7 - i];
    }
    this.additionalHeaders.push(new CdpAdditionalHeader(CdpAdditionalHeaderType.ReplyToId, little));
  }

  getReplyToId(): Uint8Array | undefined {
    for (const header of this.additionalHeaders) {
      if (header.type === CdpAdditionalHeaderType.ReplyToId && header.value.length === 8) {
        return header.value;
      }
    }
    return undefined;
  }

  /** Flip the host bit (bit 31 of the low dword) of SessionId. */
  correctClientSessionBit(): void {
    this.sessionId[4] = this.sessionId[4] ^ 0x80;
  }

  /** Big-endian read of a u32 at "offset" (used by HMAC length patching). */
  static readRawMessageLength(frame: Uint8Array): number {
    return ((frame[2] << 8) | frame[3]) >>> 0;
  }
}

/** BinaryMsgHeader from BinaryMsgHeader.cs (big-endian, 3 x u32). */
export class CdpBinaryMsgHeader {
  fragmentCount: number = 1;
  fragmentIndex: number = 0;
  messageId: number = 0;

  constructor(messageId: number = 0) {
    this.messageId = messageId;
  }
}

/** Big-endian byte writer used for all CDP message layers. */
export class CdpWriter {
  private readonly parts: Uint8Array[] = [];

  writeU8(value: number): void {
    this.parts.push(new Uint8Array([value & 0xff]));
  }

  writeI8(value: number): void {
    this.parts.push(new Uint8Array([value & 0xff]));
  }

  writeU16BE(value: number): void {
    this.parts.push(new Uint8Array([(value >>> 8) & 0xff, value & 0xff]));
  }

  writeI16BE(value: number): void {
    this.writeU16BE(value & 0xffff);
  }

  writeU32BE(value: number): void {
    this.parts.push(new Uint8Array([(value >>> 24) & 0xff, (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff]));
  }

  writeU64BE(hi: number, lo: number): void {
    this.writeU32BE(hi);
    this.writeU32BE(lo);
  }

  writeBytes(value: Uint8Array): void {
    if (value.length > 0) {
      this.parts.push(value);
    }
  }

  /** u16 length prefix + raw bytes (ReadBytesWithLength counterpart). */
  writeBytesWithLength(value: Uint8Array): void {
    const data = value !== undefined ? value : new Uint8Array(0);
    this.writeU16BE(data.length);
    this.writeBytes(data);
  }

  /** u16 length prefix + string bytes + trailing zero byte (WriteWithLength). */
  writeStringWithLength(value: string): void {
    const bytes = ByteUtils.encodeText(value !== undefined ? value : '');
    this.writeU16BE(bytes.length);
    this.writeBytes(bytes);
    this.writeU8(0);
  }

  writeHeader(header: CdpCommonHeader): void {
    this.writeU16BE(CDP_SIGNATURE);
    this.writeU16BE(header.messageLength);
    this.writeU8(header.version);
    this.writeU8(header.type);
    this.writeI16BE(header.flags);
    this.writeU32BE(header.sequenceNumber);
    // requestId / sessionId / channelId are stored as 8-byte big-endian arrays.
    this.writeBytes(header.requestId);
    this.writeU16BE(header.fragmentIndex);
    this.writeU16BE(header.fragmentCount);
    this.writeBytes(header.sessionId);
    this.writeBytes(header.channelId);
    for (const additional of header.additionalHeaders) {
      this.writeU8(additional.type);
      this.writeU8(additional.value.length);
      this.writeBytes(additional.value);
    }
    this.writeU8(0); // AdditionalHeaderType.None
    this.writeU8(0);
  }

  finish(): Uint8Array {
    return ByteUtils.concat(this.parts);
  }
}

/** Big-endian byte reader used for all CDP message layers. */
export class CdpReader {
  private readonly bytes: Uint8Array;
  private offset: number = 0;

  constructor(bytes: Uint8Array) {
    this.bytes = bytes;
  }

  get remaining(): number {
    return this.bytes.length - this.offset;
  }

  get position(): number {
    return this.offset;
  }

  readU8(): number {
    if (this.offset + 1 > this.bytes.length) {
      throw new Error('CDP read past end of buffer');
    }
    const value = this.bytes[this.offset];
    this.offset += 1;
    return value;
  }

  readI8(): number {
    const value = this.readU8();
    return (value & 0x80) !== 0 ? value - 0x100 : value;
  }

  readU16BE(): number {
    if (this.offset + 2 > this.bytes.length) {
      throw new Error('CDP read past end of buffer');
    }
    const value = ((this.bytes[this.offset] << 8) | this.bytes[this.offset + 1]) >>> 0;
    this.offset += 2;
    return value;
  }

  readI16BE(): number {
    const value = this.readU16BE();
    return (value & 0x8000) !== 0 ? value - 0x10000 : value;
  }

  readU32BE(): number {
    if (this.offset + 4 > this.bytes.length) {
      throw new Error('CDP read past end of buffer');
    }
    const value = ((this.bytes[this.offset] * 0x1000000) + (this.bytes[this.offset + 1] << 16)
      + (this.bytes[this.offset + 2] << 8) + this.bytes[this.offset + 3]) >>> 0;
    this.offset += 4;
    return value;
  }

  readU64BE(): number {
    const high = this.readU32BE();
    const low = this.readU32BE();
    return high * 0x100000000 + low;
  }

  readBytes(length: number): Uint8Array {
    if (length < 0 || this.offset + length > this.bytes.length) {
      throw new Error('CDP read past end of buffer');
    }
    const result = this.bytes.slice(this.offset, this.offset + length);
    this.offset += length;
    return result;
  }

  readU64(): Uint8Array {
    return this.readBytes(8);
  }

  /** u16 length prefix + raw bytes. */
  readBytesWithLength(): Uint8Array {
    const length = this.readU16BE();
    return this.readBytes(length);
  }

  /** u16 length prefix + string bytes + trailing zero byte. */
  readStringWithLength(): string {
    const length = this.readU16BE();
    const raw = this.readBytes(length);
    this.readU8(); // trailing zero
    return ByteUtils.decodeText(raw);
  }

  readHeader(): CdpCommonHeader {
    const signature = this.readU16BE();
    if (signature !== CDP_SIGNATURE) {
      throw new Error('CDP wrong signature 0x' + signature.toString(16));
    }
    const header = new CdpCommonHeader();
    header.messageLength = this.readU16BE();
    header.version = this.readU8();
    if (header.version !== CDP_PROTOCOL_VERSION) {
      throw new Error('CDP wrong version ' + header.version);
    }
    header.type = this.readU8();
    header.flags = this.readI16BE();
    header.sequenceNumber = this.readU32BE();
    header.requestId = this.readU64();
    header.fragmentIndex = this.readU16BE();
    header.fragmentCount = this.readU16BE();
    header.sessionId = this.readU64();
    header.channelId = this.readU64();
    while (true) {
      const type = this.readU8();
      const size = this.readU8();
      if (type === CdpAdditionalHeaderType.None) {
        break;
      }
      header.additionalHeaders.push(new CdpAdditionalHeader(type, this.readBytes(size)));
    }
    return header;
  }

  readBinaryMsgHeader(): CdpBinaryMsgHeader {
    const header = new CdpBinaryMsgHeader();
    header.fragmentCount = this.readU32BE();
    header.fragmentIndex = this.readU32BE();
    header.messageId = this.readU32BE();
    return header;
  }

  readRemaining(): Uint8Array {
    return this.readBytes(this.remaining);
  }

  /** Read a big-endian u64 into a fresh 8-byte array (helper). */
  readRawU64BE(): Uint8Array {
    return this.readBytes(8);
  }
}

/** Parse the prefix of a CDP message frame into a CommonHeader. */
export function parseCommonHeader(frame: Uint8Array): CdpCommonHeader {
  const reader = new CdpReader(frame);
  const header = reader.readHeader();
  if (header.messageLength > frame.length) {
    throw new Error('CDP incomplete frame: header ' + header.messageLength + ' > ' + frame.length);
  }
  return header;
}
