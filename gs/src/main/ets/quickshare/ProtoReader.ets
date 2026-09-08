import { MAX_PROTO_BYTES, MAX_TCP_FRAME } from './ProtoWire';
export interface ProtoField { readonly field: number; readonly wireType: number; readonly value: Uint8Array | number; }
export class ProtoReader {
  private readonly bytes: Uint8Array; private offset: number = 0;
  constructor(bytes: Uint8Array) { if (bytes.length > MAX_PROTO_BYTES) throw new Error('protobuf message too large'); this.bytes = bytes; }
  readAll(): ProtoField[] { const fields: ProtoField[] = []; while (this.offset < this.bytes.length) { const tag: number = this.readVarint(); const field: number = Math.floor(tag / 8); const wireType: number = tag % 8; if (field <= 0 || wireType === 3 || wireType === 4) throw new Error('invalid protobuf tag'); if (wireType === 0) fields.push({ field, wireType, value: this.readVarint() }); else if (wireType === 1) this.skip(8); else if (wireType === 2) { const length: number = this.readVarint(); if (length > MAX_PROTO_BYTES || this.offset + length > this.bytes.length) throw new Error('protobuf length exceeds frame'); fields.push({ field, wireType, value: this.bytes.slice(this.offset, this.offset + length) }); this.offset += length; } else if (wireType === 5) this.skip(4); else throw new Error('unsupported protobuf wire type ' + wireType); } return fields; }
  private skip(length: number): void { if (this.offset + length > this.bytes.length) throw new Error('protobuf field exceeds frame'); this.offset += length; }
  // Nearby/Android encode int64 fields (e.g. a PayloadTransfer payload_id) as a
  // random 64-bit value that can be negative, which protobuf encodes as a
  // 10-byte varint reading as a value > Number.MAX_SAFE_INTEGER. Saturate the
  // value instead of throwing: identifiers only need to compare equal, and both
  // the full/LIST_CHUNK packets carry the same id so they saturate identically.
  // We still consume every varint byte so the read offset stays correct.
  private readVarint(): number { let value: number = 0; let multiplier: number = 1; for (let i = 0; i < 10; i++) { if (this.offset >= this.bytes.length) throw new Error('truncated protobuf varint'); const byte: number = this.bytes[this.offset++]; value += (byte & 0x7f) * multiplier; if (value > Number.MAX_SAFE_INTEGER) value = Number.MAX_SAFE_INTEGER; if ((byte & 0x80) === 0) return value; multiplier *= 128; } throw new Error('protobuf varint too long'); }
  static firstVarint(bytes: Uint8Array, field: number): number | undefined { for (const item of new ProtoReader(bytes).readAll()) if (item.field === field && item.wireType === 0) return item.value as number; return undefined; }
  static firstBytes(bytes: Uint8Array, field: number): Uint8Array | undefined { for (const item of new ProtoReader(bytes).readAll()) if (item.field === field && item.wireType === 2) return item.value as Uint8Array; return undefined; }
  static allBytes(bytes: Uint8Array, field: number): Uint8Array[] { return new ProtoReader(bytes).readAll().filter((item: ProtoField): boolean => item.field === field && item.wireType === 2).map((item: ProtoField): Uint8Array => item.value as Uint8Array); }
  static decodeFrame(frame: Uint8Array): Uint8Array { if (frame.length < 4) throw new Error('short TCP frame'); const length: number = ((frame[0] * 0x1000000) + (frame[1] << 16) + (frame[2] << 8) + frame[3]) >>> 0; if (length > MAX_TCP_FRAME || length !== frame.length - 4) throw new Error('invalid TCP frame length'); return frame.slice(4); }
}
