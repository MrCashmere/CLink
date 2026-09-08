import { GsBytes } from '../util/GsBytes';
export const MAX_PROTO_BYTES: number = 8 * 1024 * 1024;
export const MAX_TCP_FRAME: number = 16 * 1024 * 1024;
export class ProtoWire {
  static varint(value: number): Uint8Array { if (!Number.isFinite(value) || value < 0 || value > Number.MAX_SAFE_INTEGER) throw new Error('invalid unsigned varint'); let current: number = Math.floor(value); const out: number[] = []; while (current >= 128) { out.push((current % 128) | 0x80); current = Math.floor(current / 128); if (out.length >= 10) throw new Error('varint too long'); } out.push(current); return new Uint8Array(out); }
  static int32(value: number): Uint8Array { if (!Number.isInteger(value) || value < -2147483648 || value > 2147483647) throw new Error('invalid int32'); return ProtoWire.varint(value < 0 ? 0x100000000 + value : value); }
  // Signed 64-bit varint (two's complement, up to 10 bytes). Android/Windows
  // Nearby encode int64 fields (e.g. PayloadTransfer payload_id) as a random
  // 64-bit value that can be negative; the legacy unsigned varint throws for
  // those. This mirrors protobuf int64 semantics. Within the JS-safe range the
  // value is exact; positive values encode as a canonical short varint.
  static int64(value: number): Uint8Array {
    if (!Number.isInteger(value) || value < -9007199254740991 || value > 9007199254740991) {
      throw new Error('invalid int64');
    }
    const MOD: number = 4294967296;
    let lo: number = value % MOD;
    if (lo < 0) { lo += MOD; }
    let hi: number = Math.floor(value / MOD);
    if (value < 0) {
      hi = 0xFFFFFFFF - Math.floor((-value - 1) / MOD);
    }
    const out: number[] = [];
    let l: number = lo;
    let h: number = hi;
    while (h !== 0) {
      out.push((l & 0x7f) | 0x80);
      l = ((l >>> 7) | ((h & 0x7f) << 25)) >>> 0;
      h = h >>> 7;
    }
    while (l >= 0x80) {
      out.push((l & 0x7f) | 0x80);
      l = l >>> 7;
    }
    out.push(l);
    return new Uint8Array(out);
  }
  static fieldInt32(field: number, value: number): Uint8Array { return ProtoWire.fieldVarint(field, value < 0 ? 0x100000000 + value : value); }
  static fieldInt64(field: number, value: number): Uint8Array {
    if (!Number.isInteger(field) || field <= 0 || field > 0x1fffffff) throw new Error('invalid field number');
    return GsBytes.concat([ProtoWire.varint(field * 8), ProtoWire.int64(value)]);
  }
  static fieldEnum(field: number, value: number): Uint8Array { return ProtoWire.fieldVarint(field, value); }
  static fieldBool(field: number, value: boolean): Uint8Array { return ProtoWire.fieldVarint(field, value ? 1 : 0); }
  static fieldVarint(field: number, value: number): Uint8Array { if (!Number.isInteger(field) || field <= 0 || field > 0x1fffffff) throw new Error('invalid field number'); return GsBytes.concat([ProtoWire.varint(field * 8), ProtoWire.varint(value)]); }
  static fieldBytes(field: number, value: Uint8Array): Uint8Array { if (value.length > MAX_PROTO_BYTES) throw new Error('protobuf field too large'); return GsBytes.concat([ProtoWire.varint(field * 8 + 2), ProtoWire.varint(value.length), value]); }
  static fieldString(field: number, value: string): Uint8Array { return ProtoWire.fieldBytes(field, GsBytes.encodeText(value)); }
  static nested(field: number, body: Uint8Array): Uint8Array { return ProtoWire.fieldBytes(field, body); }
  static message(parts: Uint8Array[]): Uint8Array { const out: Uint8Array = GsBytes.concat(parts); if (out.length > MAX_PROTO_BYTES) throw new Error('protobuf message too large'); return out; }
  static frame(message: Uint8Array): Uint8Array { if (message.length > MAX_TCP_FRAME) throw new Error('frame too large'); return GsBytes.concat([GsBytes.writeU32BE(message.length), message]); }
}
