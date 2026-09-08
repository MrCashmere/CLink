/**
 * Microsoft Bond "Compact Binary" v1 codec for the MS-CDP ValueSet payload,
 * byte-for-byte compatible with ShortDev.IO's CompactBinaryWriter/Reader.
 *
 * The CDP control-plane carries a ValueSet (a map<wstring, PropertyValue>).
 * Each PropertyValue has a field-0 "Type" marker plus exactly one value field.
 * Field ids and BondDataType values below mirror the generated
 * ValueSet.Schema.cs in the reference.
 */

import { ByteUtils } from '../../common/ByteUtils';

/** BondDataType enum (ShortDev.IO Bond/Consts.cs). */
export enum BondDataType {
  BT_STOP = 0,
  BT_STOP_BASE = 1,
  BT_BOOL = 2,
  BT_UINT8 = 3,
  BT_UINT16 = 4,
  BT_UINT32 = 5,
  BT_UINT64 = 6,
  BT_FLOAT = 7,
  BT_DOUBLE = 8,
  BT_STRING = 9,
  BT_STRUCT = 10,
  BT_LIST = 11,
  BT_SET = 12,
  BT_MAP = 13,
  BT_INT8 = 14,
  BT_INT16 = 15,
  BT_INT32 = 16,
  BT_INT64 = 17,
  BT_WSTRING = 18,
  BT_UNAVAILABLE = 127
}

/** PropertyType enum (ValueSet.Schema.cs). Only the types used by NearShare are complete. */
export enum CdpPropertyType {
  Empty = 0,
  UInt8 = 1,
  Int16 = 2,
  UInt16 = 3,
  Int32 = 4,
  UInt32 = 5,
  Int64 = 6,
  UInt64 = 7,
  Boolean = 11,
  WString = 12,
  Guid = 15,
  ValueSet = 19,
  UInt8Array = 20,
  UInt32Array = 24,
  UInt64Array = 26,
  String = 39,
  StringArray = 40
}

/** LEB128-like variable length unsigned integer. */
export function encodeVarUInt(value: number): Uint8Array {
  const bytes: number[] = [];
  let v = value;
  while (v >= 128) {
    bytes.push((v % 128) | 0x80);
    v = Math.floor(v / 128);
  }
  bytes.push(v % 128);
  return new Uint8Array(bytes);
}

/**
 * Encodes an unsigned 64-bit value as a Bond LEB128 varint without going
 * through a JS Number, so GUID OperationId/Data4 (native 64-bit) stays
 * byte-exact even when it exceeds 2^53. The source is the low 8 bytes of a
 * GUID rendered as exactly 16 hex characters (big-endian).
 */
function encodeVarUInt64FromHex(hex: string): Uint8Array {
  const le = new Uint8Array(8);
  for (let i = 0; i < 8; i++) {
    le[7 - i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  const emitted: number[] = [];
  while (isNonZeroLE(le)) {
    let byte = le[0] & 0x7f;
    shiftRight1LE(le);
    shiftRight1LE(le);
    shiftRight1LE(le);
    shiftRight1LE(le);
    shiftRight1LE(le);
    shiftRight1LE(le);
    shiftRight1LE(le);
    if (isNonZeroLE(le)) {
      byte |= 0x80;
    }
    emitted.push(byte);
  }
  if (emitted.length === 0) {
    emitted.push(0);
  }
  return new Uint8Array(emitted);
}

/** Right-shift an 8-byte little-endian array by one bit. */
function shiftRight1LE(bytes: Uint8Array): void {
  let carry = 0;
  for (let i = bytes.length - 1; i >= 0; i--) {
    const nextCarry = bytes[i] & 1;
    bytes[i] = (bytes[i] >> 1) | (carry << 7);
    carry = nextCarry;
  }
}

function isNonZeroLE(bytes: Uint8Array): boolean {
  for (let i = 0; i < bytes.length; i++) {
    if (bytes[i] !== 0) {
      return true;
    }
  }
  return false;
}

/** Reverses the byte order of a hex string (e.g. "bba0..." -> "6059..."). */
function reverseHexBytes(hex: string): string {
  let out = '';
  for (let i = hex.length; i > 0; i -= 2) {
    out += hex.substring(i - 2, i);
  }
  return out;
}

/** Reads a variable length unsigned integer from bytes at offset. */
export function decodeVarUInt(bytes: Uint8Array, offset: number): CdpVarIntResult {
  let result = 0;
  let shift = 0;
  let index = offset;
  for (let i = 0; i < 8; i++) {
    if (index >= bytes.length) {
      throw new Error('Bond varint truncated');
    }
    const b = bytes[index];
    index += 1;
    result += (b & 0x7f) * Math.pow(2, shift);
    if ((b & 0x80) === 0) {
      break;
    }
    shift += 7;
  }
  return new CdpVarIntResult(result, index);
}

export class CdpVarIntResult {
  readonly value: number;
  readonly next: number;

  constructor(value: number, next: number) {
    this.value = value;
    this.next = next;
  }
}

function zigzag32(value: number): number {
  return ((value << 1) ^ (value >> 31)) >>> 0;
}

function unzigzag32(value: number): number {
  return (value >>> 1) ^ -((value & 1) >>> 0);
}

/** Tagged protocol writer. */
export class BondWriter {
  private readonly parts: Uint8Array[] = [];

  writeByte(value: number): void {
    this.parts.push(new Uint8Array([value & 0xff]));
  }

  writeUBytes(value: Uint8Array): void {
    if (value.length > 0) {
      this.parts.push(value);
    }
  }

  writeVarUInt(value: number): void {
    this.parts.push(encodeVarUInt(value));
  }

  writeStructBegin(): void {
    // Compact v1 has no struct length prefix.
  }

  writeStructEnd(): void {
    this.writeByte(BondDataType.BT_STOP);
  }

  writeBaseEnd(): void {
    this.writeByte(BondDataType.BT_STOP_BASE);
  }

  writeFieldBegin(type: BondDataType, id: number): void {
    const fieldType = type;
    if (id <= 5) {
      this.writeByte(fieldType | (id << 5));
    } else if (id <= 0xff) {
      // little-endian ushort: [fieldType|0xC0, id]
      this.writeByte((fieldType | (0x06 << 5)) & 0xff);
      this.writeByte(id & 0xff);
    } else {
      this.writeByte((fieldType | (0x07 << 5)) & 0xff);
      this.writeByte(id & 0xff);
      this.writeByte((id >>> 8) & 0xff);
    }
  }

  writeContainerBegin(count: number, elementType: BondDataType): void {
    this.writeByte(elementType);
    this.writeVarUInt(count);
  }

  writeMapBegin(keyType: BondDataType, valueType: BondDataType, count: number): void {
    this.writeByte(keyType);
    this.writeByte(valueType);
    this.writeVarUInt(count);
  }

  writeUInt8(value: number): void {
    this.writeByte(value);
  }

  writeUInt16(value: number): void {
    this.writeVarUInt(value);
  }

  writeUInt32(value: number): void {
    this.writeVarUInt(value);
  }

  writeUInt64(value: number): void {
    this.writeVarUInt(value);
  }

  writeInt32(value: number): void {
    this.writeVarUInt(zigzag32(value));
  }

  writeBool(value: boolean): void {
    this.writeByte(value ? 1 : 0);
  }

  writeString(value: string): void {
    if (value.length === 0) {
      this.writeVarUInt(0);
      return;
    }
    const bytes = ByteUtils.encodeText(value);
    this.writeVarUInt(bytes.length);
    this.writeUBytes(bytes);
  }

  writeWString(value: string): void {
    if (value.length === 0) {
      this.writeVarUInt(0);
      return;
    }
    this.writeVarUInt(value.length);
    for (let i = 0; i < value.length; i++) {
      const code = value.charCodeAt(i);
      this.writeByte(code & 0xff);
      this.writeByte((code >>> 8) & 0xff);
    }
  }

  finish(): Uint8Array {
    return ByteUtils.concat(this.parts);
  }
}

/** Tagged protocol reader over a Uint8Array. */
export class BondReader {
  private readonly bytes: Uint8Array;
  private offset: number = 0;

  constructor(bytes: Uint8Array) {
    this.bytes = bytes;
  }

  get remaining(): number {
    return this.bytes.length - this.offset;
  }

  readU8(): number {
    if (this.offset >= this.bytes.length) {
      throw new Error('Bond read past end');
    }
    const value = this.bytes[this.offset];
    this.offset += 1;
    return value;
  }

  readVarUInt(): number {
    const result = decodeVarUInt(this.bytes, this.offset);
    this.offset = result.next;
    return result.value;
  }

  /** Returns the raw LEB128 bytes (little-endian, LSB first) without decoding to a JS number. */
  readVarUIntBytes(): Uint8Array {
    const start = this.offset;
    while (true) {
      if (this.offset >= this.bytes.length) {
        throw new Error('Bond varint truncated');
      }
      const b = this.bytes[this.offset];
      this.offset += 1;
      if ((b & 0x80) === 0) {
        break;
      }
    }
    return this.bytes.slice(start, this.offset);
  }

  readStructBegin(): void {
    // v1: no prefix.
  }

  readStructEnd(): void {
    // The field loop already consumed the single terminating BT_STOP byte via
    // readFieldBegin(); here we must not read another byte.
  }

  readFieldBegin(): CdpFieldHeader {
    const raw = this.readU8();
    const type = (raw & 0x1f) as BondDataType;
    const shifted = raw >> 5;
    let id = 0;
    if (shifted < 6) {
      id = shifted;
    } else if (shifted === 6) {
      id = this.readU8();
    } else {
      id = this.readU8() | (this.readU8() << 8);
    }
    return new CdpFieldHeader(type, id);
  }

  readContainerBegin(): CdpContainerHeader {
    const elemType = this.readU8() as BondDataType;
    const count = this.readVarUInt();
    return new CdpContainerHeader(elemType, count);
  }

  readMapBegin(): CdpMapHeader {
    const keyType = this.readU8() as BondDataType;
    const valueType = this.readU8() as BondDataType;
    const count = this.readVarUInt();
    return new CdpMapHeader(keyType, valueType, count);
  }

  readUInt8(): number {
    return this.readU8();
  }

  readUInt16(): number {
    return this.readVarUInt();
  }

  readUInt32(): number {
    return this.readVarUInt();
  }

  readUInt64(): number {
    return this.readVarUInt();
  }

  readInt32(): number {
    return unzigzag32(this.readVarUInt());
  }

  readBool(): boolean {
    return this.readU8() !== 0;
  }

  readString(): string {
    const length = this.readVarUInt();
    if (length === 0) {
      return '';
    }
    const raw = this.readBytes(length);
    return ByteUtils.decodeText(raw);
  }

  readWString(): string {
    const count = this.readVarUInt();
    if (count === 0) {
      return '';
    }
    let text = '';
    for (let i = 0; i < count; i++) {
      const low = this.readU8();
      const high = this.readU8();
      text += String.fromCharCode(low | (high << 8));
    }
    return text;
  }

  readBytes(length: number): Uint8Array {
    if (length < 0 || this.offset + length > this.bytes.length) {
      throw new Error('Bond read past end');
    }
    const result = this.bytes.slice(this.offset, this.offset + length);
    this.offset += length;
    return result;
  }

  skip(type: BondDataType): void {
    switch (type) {
      case BondDataType.BT_BOOL:
      case BondDataType.BT_UINT8:
      case BondDataType.BT_INT8:
        this.skipBytes(1);
        return;
      case BondDataType.BT_UINT16:
      case BondDataType.BT_INT16:
        this.skipBytes(2);
        return;
      case BondDataType.BT_UINT32:
      case BondDataType.BT_INT32:
      case BondDataType.BT_FLOAT:
        this.skipBytes(4);
        return;
      case BondDataType.BT_UINT64:
      case BondDataType.BT_INT64:
      case BondDataType.BT_DOUBLE:
        this.skipBytes(8);
        return;
      case BondDataType.BT_STRING:
        this.skipBytes(this.readVarUInt());
        return;
      case BondDataType.BT_WSTRING:
        // WString is UTF-16: each code unit occupies 2 bytes.
        this.skipBytes(this.readVarUInt() * 2);
        return;
      case BondDataType.BT_LIST:
      case BondDataType.BT_SET:
        {
          const container = this.readContainerBegin();
          for (let i = 0; i < container.count; i++) {
            this.skip(container.elementType);
          }
        }
        return;
      case BondDataType.BT_MAP:
        {
          const map = this.readMapBegin();
          for (let i = 0; i < map.count; i++) {
            this.skip(map.keyType);
            this.skip(map.valueType);
          }
        }
        return;
      case BondDataType.BT_STRUCT:
        {
          this.readStructBegin();
          while (true) {
            const field = this.readFieldBegin();
            if (field.type === BondDataType.BT_STOP || field.type === BondDataType.BT_STOP_BASE) {
              break;
            }
            this.skip(field.type);
          }
        }
        return;
      default:
        return;
    }
  }

  private skipBytes(count: number): void {
    if (this.offset + count > this.bytes.length) {
      throw new Error('Bond skip past end');
    }
    this.offset += count;
  }
}

export class CdpFieldHeader {
  readonly type: BondDataType;
  readonly id: number;

  constructor(type: BondDataType, id: number) {
    this.type = type;
    this.id = id;
  }
}

export class CdpContainerHeader {
  readonly elementType: BondDataType;
  readonly count: number;

  constructor(elementType: BondDataType, count: number) {
    this.elementType = elementType;
    this.count = count;
  }
}

export class CdpMapHeader {
  readonly keyType: BondDataType;
  readonly valueType: BondDataType;
  readonly count: number;

  constructor(keyType: BondDataType, valueType: BondDataType, count: number) {
    this.keyType = keyType;
    this.valueType = valueType;
    this.count = count;
  }
}

/** A single PropertyValue: a "Type" marker plus one value. */
export class CdpPropertyValue {
  type: CdpPropertyType = CdpPropertyType.Empty;
  numberValue: number = 0;
  boolValue: boolean = false;
  stringValue: string = '';
  guidValue: string = '';
  bytesValue: Uint8Array = new Uint8Array(0);
  uintArray: number[] = [];
  ulongArray: number[] = [];
  stringArray: string[] = [];
  nested?: CdpValueSet;
}

/**
 * ValueSet = map<wstring, PropertyValue>.
 * Convenience builders write exactly the on-wire form used by NearShare.
 */
export class CdpValueSet {
  private readonly entries: Map<string, CdpPropertyValue> = new Map<string, CdpPropertyValue>();

  static parse(bytes: Uint8Array): CdpValueSet {
    const reader = new BondReader(bytes);
    const vs = new CdpValueSet();
    vs.readFrom(reader);
    return vs;
  }

  serialize(): Uint8Array {
    const writer = new BondWriter();
    writer.writeStructBegin();
    if (this.entries.size > 0) {
      writer.writeFieldBegin(BondDataType.BT_MAP, 1);
      writer.writeMapBegin(BondDataType.BT_WSTRING, BondDataType.BT_STRUCT, this.entries.size);
      this.entries.forEach((value: CdpPropertyValue, key: string): void => {
        writer.writeWString(key);
        writePropertyValue(writer, value);
      });
    }
    writer.writeStructEnd();
    return writer.finish();
  }

  size(): number {
    return this.entries.size;
  }

  readFrom(reader: BondReader): void {
    reader.readStructBegin();
    while (true) {
      const field = reader.readFieldBegin();
      if (field.type === BondDataType.BT_STOP || field.type === BondDataType.BT_STOP_BASE) {
        break;
      }
      if (field.id === 1 && field.type === BondDataType.BT_MAP) {
        const map = reader.readMapBegin();
        if (map.keyType !== BondDataType.BT_WSTRING) {
          throw new Error('ValueSet expected WSTRING map key, got ' + map.keyType);
        }
        for (let i = 0; i < map.count; i++) {
          const key = reader.readWString();
          const value = readPropertyValue(reader);
          this.entries.set(key, value);
        }
      } else {
        reader.skip(field.type);
      }
    }
  }

  has(key: string): boolean {
    return this.entries.has(key);
  }

  get(key: string): CdpPropertyValue | undefined {
    return this.entries.get(key);
  }

  getUInt32(key: string): number {
    const value = this.entries.get(key);
    if (value === undefined) {
      return 0;
    }
    return value.numberValue >>> 0;
  }

  getUInt64(key: string): number {
    const value = this.entries.get(key);
    if (value === undefined) {
      return 0;
    }
    return value.numberValue;
  }

  getString(key: string): string {
    const value = this.entries.get(key);
    if (value === undefined) {
      return '';
    }
    return value.stringValue;
  }

  getGuid(key: string): string {
    const value = this.entries.get(key);
    if (value === undefined) {
      return '';
    }
    return value.guidValue;
  }

  getUInt8Array(key: string): Uint8Array {
    const value = this.entries.get(key);
    if (value === undefined) {
      return new Uint8Array(0);
    }
    return value.bytesValue;
  }

  getUInt32Array(key: string): number[] {
    const value = this.entries.get(key);
    if (value === undefined) {
      return [];
    }
    return value.uintArray;
  }

  getUInt64Array(key: string): number[] {
    const value = this.entries.get(key);
    if (value === undefined) {
      return [];
    }
    return value.ulongArray;
  }

  getStringArray(key: string): string[] {
    const value = this.entries.get(key);
    if (value === undefined) {
      return [];
    }
    return value.stringArray;
  }

  addUInt32(key: string, value: number): void {
    const prop = new CdpPropertyValue();
    prop.type = CdpPropertyType.UInt32;
    prop.numberValue = value >>> 0;
    this.entries.set(key, prop);
  }

  addUInt64(key: string, value: number): void {
    const prop = new CdpPropertyValue();
    prop.type = CdpPropertyType.UInt64;
    prop.numberValue = value;
    this.entries.set(key, prop);
  }

  addUInt8Array(key: string, value: Uint8Array): void {
    const prop = new CdpPropertyValue();
    prop.type = CdpPropertyType.UInt8Array;
    prop.bytesValue = value;
    this.entries.set(key, prop);
  }

  addUInt32Array(key: string, value: number[]): void {
    const prop = new CdpPropertyValue();
    prop.type = CdpPropertyType.UInt32Array;
    prop.uintArray = value;
    this.entries.set(key, prop);
  }

  addUInt64Array(key: string, value: number[]): void {
    const prop = new CdpPropertyValue();
    prop.type = CdpPropertyType.UInt64Array;
    prop.ulongArray = value;
    this.entries.set(key, prop);
  }

  addStringArray(key: string, value: string[]): void {
    const prop = new CdpPropertyValue();
    prop.type = CdpPropertyType.StringArray;
    prop.stringArray = value;
    this.entries.set(key, prop);
  }

  addString(key: string, value: string): void {
    const prop = new CdpPropertyValue();
    prop.type = CdpPropertyType.String;
    prop.stringValue = value;
    this.entries.set(key, prop);
  }

  addGuid(key: string, value: string): void {
    const prop = new CdpPropertyValue();
    prop.type = CdpPropertyType.Guid;
    prop.guidValue = value;
    this.entries.set(key, prop);
  }
}

function writePropertyValue(writer: BondWriter, value: CdpPropertyValue): void {
  writer.writeStructBegin();
  writer.writeFieldBegin(BondDataType.BT_INT32, 0);
  writer.writeInt32(value.type);
  switch (value.type) {
    case CdpPropertyType.UInt8:
      writer.writeFieldBegin(BondDataType.BT_UINT8, 100);
      writer.writeUInt8(value.numberValue);
      break;
    case CdpPropertyType.Int16:
      writer.writeFieldBegin(BondDataType.BT_INT16, 101);
      writer.writeVarUInt((value.numberValue << 1) ^ (value.numberValue >> 15));
      break;
    case CdpPropertyType.UInt16:
      writer.writeFieldBegin(BondDataType.BT_UINT16, 102);
      writer.writeUInt16(value.numberValue);
      break;
    case CdpPropertyType.Int32:
      writer.writeFieldBegin(BondDataType.BT_INT32, 103);
      writer.writeInt32(value.numberValue);
      break;
    case CdpPropertyType.UInt32:
      writer.writeFieldBegin(BondDataType.BT_UINT32, 104);
      writer.writeUInt32(value.numberValue >>> 0);
      break;
    case CdpPropertyType.Int64:
      writer.writeFieldBegin(BondDataType.BT_INT64, 105);
      writer.writeVarUInt(zigzag64(value.numberValue));
      break;
    case CdpPropertyType.UInt64:
      writer.writeFieldBegin(BondDataType.BT_UINT64, 106);
      writer.writeUInt64(value.numberValue);
      break;
    case CdpPropertyType.Boolean:
      writer.writeFieldBegin(BondDataType.BT_BOOL, 110);
      writer.writeBool(value.boolValue);
      break;
    case CdpPropertyType.WString:
      writer.writeFieldBegin(BondDataType.BT_WSTRING, 111);
      writer.writeWString(value.stringValue);
      break;
    case CdpPropertyType.ValueSet:
      // Reference serializes a nested ValueSet as LIST<STRUCT>(count=1).
      writer.writeFieldBegin(BondDataType.BT_LIST, 118);
      writer.writeContainerBegin(1, BondDataType.BT_STRUCT);
      if (value.nested !== undefined) {
        writeValueSetStruct(writer, value.nested);
      } else {
        writer.writeStructBegin();
        writer.writeStructEnd();
      }
      break;
    case CdpPropertyType.Guid:
      // Reference serializes a Guid as LIST<STRUCT>(count=1) holding one UUID.
      writer.writeFieldBegin(BondDataType.BT_LIST, 114);
      writer.writeContainerBegin(1, BondDataType.BT_STRUCT);
      writeGuid(writer, value.guidValue);
      break;
    case CdpPropertyType.String:
      writer.writeFieldBegin(BondDataType.BT_STRING, 119);
      writer.writeString(value.stringValue);
      break;
    case CdpPropertyType.UInt8Array:
      writer.writeFieldBegin(BondDataType.BT_LIST, 200);
      writer.writeContainerBegin(value.bytesValue.length, BondDataType.BT_UINT8);
      writer.writeUBytes(value.bytesValue);
      break;
    case CdpPropertyType.UInt32Array:
      writer.writeFieldBegin(BondDataType.BT_LIST, 204);
      writer.writeContainerBegin(value.uintArray.length, BondDataType.BT_UINT32);
      for (const item of value.uintArray) {
        writer.writeUInt32(item >>> 0);
      }
      break;
    case CdpPropertyType.UInt64Array:
      writer.writeFieldBegin(BondDataType.BT_LIST, 206);
      writer.writeContainerBegin(value.ulongArray.length, BondDataType.BT_UINT64);
      for (const item of value.ulongArray) {
        writer.writeUInt64(item);
      }
      break;
    case CdpPropertyType.StringArray:
      writer.writeFieldBegin(BondDataType.BT_LIST, 219);
      writer.writeContainerBegin(value.stringArray.length, BondDataType.BT_STRING);
      for (const item of value.stringArray) {
        writer.writeString(item);
      }
      break;
    default:
      break;
  }
  writer.writeStructEnd();
}

function zigzag64(value: number): number {
  return (value << 1) ^ (value >> 63);
}

function writeValueSetStruct(writer: BondWriter, vs: CdpValueSet): void {
  // A nested ValueSet is itself a Bond struct (struct begin + field 1 map +
  // struct end). serialize() already emits that exact shape.
  writer.writeUBytes(vs.serialize());
}

function readPropertyValue(reader: BondReader): CdpPropertyValue {
  reader.readStructBegin();
  const prop = new CdpPropertyValue();
  let typeSet = false;
  while (true) {
    const field = reader.readFieldBegin();
    if (field.type === BondDataType.BT_STOP || field.type === BondDataType.BT_STOP_BASE) {
      break;
    }
    if (field.id === 0 && !typeSet) {
      prop.type = reader.readInt32() as CdpPropertyType;
      typeSet = true;
      continue;
    }
    if (field.id === 100) {
      prop.numberValue = reader.readUInt8();
    } else if (field.id === 101) {
      prop.numberValue = reader.readVarUInt();
    } else if (field.id === 102) {
      prop.numberValue = reader.readUInt16();
    } else if (field.id === 103) {
      prop.numberValue = reader.readInt32();
    } else if (field.id === 104) {
      prop.numberValue = reader.readUInt32();
    } else if (field.id === 105) {
      prop.numberValue = reader.readVarUInt();
    } else if (field.id === 106) {
      prop.numberValue = reader.readUInt64();
    } else if (field.id === 110) {
      prop.boolValue = reader.readBool();
    } else if (field.id === 111) {
      prop.stringValue = reader.readWString();
    } else if (field.id === 119) {
      prop.stringValue = reader.readString();
    } else if (field.id === 118) {
      // Nested ValueSet is LIST<STRUCT>(count=1).
      const container = reader.readContainerBegin();
      const nested = new CdpValueSet();
      if (container.count > 0) {
        nested.readFrom(reader);
        for (let i = 1; i < container.count; i++) {
          const extra = new CdpValueSet();
          extra.readFrom(reader);
        }
      }
      prop.nested = nested;
    } else if (field.id === 114) {
      // Guid is LIST<STRUCT>(count=1) holding one UUID.
      const container = reader.readContainerBegin();
      if (container.count > 0) {
        prop.guidValue = readGuid(reader);
        for (let i = 1; i < container.count; i++) {
          readGuid(reader);
        }
      }
    } else if (field.id === 200) {
      const container = reader.readContainerBegin();
      prop.bytesValue = reader.readBytes(container.count);
    } else if (field.id === 204) {
      const container = reader.readContainerBegin();
      const items: number[] = [];
      for (let i = 0; i < container.count; i++) {
        items.push(reader.readUInt32() >>> 0);
      }
      prop.uintArray = items;
    } else if (field.id === 206) {
      const container = reader.readContainerBegin();
      const items: number[] = [];
      for (let i = 0; i < container.count; i++) {
        items.push(reader.readUInt64());
      }
      prop.ulongArray = items;
    } else if (field.id === 219) {
      const container = reader.readContainerBegin();
      const items: string[] = [];
      for (let i = 0; i < container.count; i++) {
        items.push(reader.readString());
      }
      prop.stringArray = items;
    } else {
      reader.skip(field.type);
    }
  }
  reader.readStructEnd();
  return prop;
}

function writeGuid(writer: BondWriter, value: string): void {
  const parts = parseGuid(value);
  writer.writeStructBegin();
  writer.writeFieldBegin(BondDataType.BT_UINT32, 0);
  writer.writeUInt32(parts.data1);
  writer.writeFieldBegin(BondDataType.BT_UINT16, 1);
  writer.writeUInt16(parts.data2);
  writer.writeFieldBegin(BondDataType.BT_UINT16, 2);
  writer.writeUInt16(parts.data3);
  writer.writeFieldBegin(BondDataType.BT_UINT64, 3);
  const clean = value.replace(/-/g, '');
  // Bond UUID.Data4 is a little-endian ulong; reverse the string bytes so the
  // encoded value matches the reference (UUID.FromGuid reads a native ulong).
  writer.writeUBytes(encodeVarUInt64FromHex(reverseHexBytes(clean.substring(16, 32))));
  writer.writeStructEnd();
}

function readGuid(reader: BondReader): string {
  reader.readStructBegin();
  let data1 = 0;
  let data2 = 0;
  let data3 = 0;
  let data4Hex = '';
  while (true) {
    const field = reader.readFieldBegin();
    if (field.type === BondDataType.BT_STOP || field.type === BondDataType.BT_STOP_BASE) {
      break;
    }
    if (field.id === 0) {
      data1 = reader.readUInt32() >>> 0;
    } else if (field.id === 1) {
      data2 = reader.readUInt16();
    } else if (field.id === 2) {
      data3 = reader.readUInt16();
    } else if (field.id === 3) {
      // Read the raw varint so a 64-bit Data4 survives without JS precision loss,
      // then revert the little-endian value back into the Guid string byte order.
      const raw = reader.readVarUIntBytes();
      let v = 0n;
      for (let i = 0; i < raw.length; i++) {
        v |= BigInt(raw[i] & 0x7f) << BigInt(8 * i);
      }
      data4Hex = reverseHexBytes(v.toString(16).padStart(16, '0'));
    } else {
      reader.skip(field.type);
    }
  }
  reader.readStructEnd();
  const h = (v: number): string => v.toString(16).padStart(8, '0');
  const h16 = (v: number): string => v.toString(16).padStart(4, '0');
  return h(data1) + '-' + h16(data2) + '-' + h16(data3) + '-' + data4Hex.substring(0, 4) + '-' + data4Hex.substring(4);
}

function parseGuid(value: string): CdpGuidParts {
  const clean = value.replace(/-/g, '');
  const data1 = parseInt(clean.substring(0, 8), 16) >>> 0;
  const data2 = parseInt(clean.substring(8, 12), 16) & 0xffff;
  const data3 = parseInt(clean.substring(12, 16), 16) & 0xffff;
  const data4 = parseInt(clean.substring(16, 32), 16);
  const parts = new CdpGuidParts(data1, data2, data3, data4);
  return parts;
}

class CdpGuidParts {
  readonly data1: number;
  readonly data2: number;
  readonly data3: number;
  readonly data4: number;

  constructor(data1: number, data2: number, data3: number, data4: number) {
    this.data1 = data1;
    this.data2 = data2;
    this.data3 = data3;
    this.data4 = data4;
  }
}

export function propertySize(vs: CdpValueSet): number {
  return vs.serialize().length;
}
