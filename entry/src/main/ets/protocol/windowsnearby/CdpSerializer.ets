import { ByteUtils } from '../../common/ByteUtils';

/** Compact little-endian primitives used by the MS-CDP/Bond control plane. */
export class CdpBondWriter {
  private readonly parts: Uint8Array[] = [];

  writeU8(value: number): void { this.parts.push(new Uint8Array([value & 0xff])); }

  writeU16(value: number): void {
    this.parts.push(new Uint8Array([value & 0xff, (value >>> 8) & 0xff]));
  }

  writeU32(value: number): void {
    this.parts.push(new Uint8Array([value & 0xff, (value >>> 8) & 0xff, (value >>> 16) & 0xff, (value >>> 24) & 0xff]));
  }

  writeBytes(value: Uint8Array): void {
    this.writeU32(value.length);
    this.parts.push(value);
  }

  writeString(value: string): void { this.writeBytes(ByteUtils.encodeText(value)); }

  finish(): Uint8Array { return ByteUtils.concat(this.parts); }
}

export class CdpBondReader {
  private offset: number = 0;
  private readonly bytes: Uint8Array;

  constructor(bytes: Uint8Array) { this.bytes = bytes; }

  get remaining(): number { return this.bytes.length - this.offset; }

  readU8(): number { return this.read(1)[0]; }

  readU16(): number {
    const b = this.read(2);
    return b[0] | (b[1] << 8);
  }

  readU32(): number {
    const b = this.read(4);
    return (b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)) >>> 0;
  }

  readBytes(): Uint8Array {
    const length = this.readU32();
    if (length > this.remaining) { throw new Error('CDP field exceeds message'); }
    return this.read(length);
  }

  readString(): string { return ByteUtils.decodeText(this.readBytes()); }

  private read(length: number): Uint8Array {
    if (length < 0 || this.offset + length > this.bytes.length) { throw new Error('CDP message truncated'); }
    const result = this.bytes.slice(this.offset, this.offset + length);
    this.offset += length;
    return result;
  }
}

export interface CdpMessageEnvelope {
  readonly type: number;
  readonly sessionId: string;
  readonly payload: Uint8Array;
}

export class CdpMessageCodec {
  static encode(message: CdpMessageEnvelope): Uint8Array {
    const writer = new CdpBondWriter();
    writer.writeU16(message.type);
    writer.writeString(message.sessionId);
    writer.writeBytes(message.payload);
    return writer.finish();
  }

  static decode(bytes: Uint8Array): CdpMessageEnvelope {
    const reader = new CdpBondReader(bytes);
    const message: CdpMessageEnvelope = {
      type: reader.readU16(),
      sessionId: reader.readString(),
      payload: reader.readBytes()
    };
    if (reader.remaining !== 0) { throw new Error('CDP message has trailing bytes'); }
    return message;
  }
}
