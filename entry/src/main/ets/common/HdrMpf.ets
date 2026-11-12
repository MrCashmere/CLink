/**
 * MPF（Multi-Picture Format，CIPA DC-007）—— Ultra HDR 用它索引「第二张图 = 增益图」。
 *
 * 为什么需要本模块：Ultra HDR 参考实现（`google/libultrahdr` 的 `appendGainMap()`）在
 * **SOS 之前**插入一个 APP2 MPF，声明两张图（Primary + 增益图）；只写 XMP 容器目录而不写 MPF，
 * 属于「少写了一段必需结构」，认 MPF 的读取器就找不到增益图（降级为 SDR）。
 * 之前 staging 的实现在重排时**直接丢弃** MPF（因为旧偏移失效）—— 正确做法是**重建**。
 *
 * 与参考实现逐项对齐的布局（payload 共 86 字节，偏移一律相对 MPF 的 TIFF 头，即 `MM\0*` 那 4 字节之后）：
 *
 * ```
 *  0   'MPF\0'                       签名
 *  4   'MM\0*'                       TIFF 头（大端）
 *  8   (u32) 8                       指向 MP Index IFD
 *  12  (u16) 3                       tag 数
 *  14  0xB000 UNDEFINED count=4 '0100'   版本
 *  26  0xB001 LONG      count=1 2        图片张数
 *  38  0xB002 UNDEFINED count=32 (u32)50 MP 条目数组偏移（= 相对 TIFF 头的 50）
 *  50  (u32) 0                       下一个 IFD（不写）
 *  54  条目0：属性 0x00030000(主图)  size  offset
 *  70  条目1：属性 0x00000000(JPEG)  size  offset
 * ```
 *
 * 关键语义（照参考实现 `jpegr.cpp` 的 `secondary_image_offset = primary_image_size - pos - 8`）：
 *  - **主图偏移恒为 0**（主图自身包含 MPF 块）；
 *  - **第二张图的偏移 = 第二张图起始文件偏移 − MPF 的 TIFF 头文件偏移**（`mpfStart + 8`）；
 *  - 主图的 size 含 MPF 块本身，到主图 EOI 为止。
 *
 * **字节序**：CIPA DC-007 允许 TIFF 头用大端或小端，真机两种都在用（Apple 大端；Google/小米等
 * Android 侧的小端）。本模块**只写大端**（与参考实现一致），但**两种都能解析**：真机 Ultra HDR
 * 文件是小端，只认大端会让自检失败、整个 HDR 改写静默退回原图。
 *
 * 纯字节函数，可在 Node 端回归（见 `staging/hdr/tests`）。
 */

/** 解析出来的 MP 条目。 */
export interface MpfEntry {
  readonly attribute: number;
  readonly size: number;
  readonly offset: number;
}

/** 解析结果。 */
export interface MpfInfo {
  readonly version: string;
  readonly numberOfImages: number;
  readonly entries: MpfEntry[];
  /** MPF 的 TIFF 头在文件里的绝对偏移（= 段起始 + 8），用于把条目偏移换算成文件偏移。 */
  readonly tiffHeaderOffset: number;
  /** MP 条目数组在文件里的绝对偏移（便于自检/工具直接读写条目字段）。 */
  readonly entriesOffset: number;
  /** TIFF 头声明的是小端（`II*\0`）还是大端（`MM\0*`）；真机两种都有。 */
  readonly littleEndian: boolean;
}

const MPF_SIGNATURE: number[] = [0x4d, 0x50, 0x46, 0x00]; // 'MPF\0'
const MPF_BIG_ENDIAN: number[] = [0x4d, 0x4d, 0x00, 0x2a]; // 'MM\0*'
const TAG_VERSION = 0xb000;
const TAG_NUMBER_OF_IMAGES = 0xb001;
const TAG_MP_ENTRY = 0xb002;
const TYPE_LONG = 4;
const TYPE_UNDEFINED = 7;
const MP_ENTRY_SIZE = 16;
const TAG_SIZE = 12;
const TAG_COUNT = 3;
/** MP 条目数组相对 TIFF 头的偏移：4(签名)+4(端ian)+4(IFD 偏移)+2(tag 数)+3*12(tag)+4(next) − 4(签名) = 50。 */
const MP_ENTRY_DATA_OFFSET = 50;
/** 主图属性：JPEG + Primary。 */
const ATTRIBUTE_PRIMARY = 0x00030000;
/** 第二张图属性：普通 JPEG（Apple / Google / OPPO / Samsung 都写这个）。 */
const ATTRIBUTE_SECONDARY = 0x00000000;
/**
 * 第二张图属性：**HDR 增益图**（华为/鸿蒙写这个）。
 *
 * 真机证据（Mate 80 Pro Max 相机 HDR 照片）：MPF 条目 1 的 attribute = 0x00050000，
 * 而 Apple/Google/OPPO/Samsung 的增益图条目都是 0x00000000。要让鸿蒙把它认成 HDR 增益图，
 * 这个标记目前是最可疑的判据之一（与主图 APP2 的 ISO 21496-1 URN 配套）。
 */
export const ATTRIBUTE_GAINMAP = 0x00050000;

/** JPEG 里的 ISO 21496-1 标识段载荷（`urn:iso:std:iso:ts:21496:-1` + 4 个 0，共 32 字节）。 */
export const ISO_21496_URN_PAYLOAD: number[] = (() => {
  const text = 'urn:iso:std:iso:ts:21496:-1';
  const out: number[] = [];
  for (let i = 0; i < text.length; i++) {
    out.push(text.charCodeAt(i));
  }
  while (out.length < 32) {
    out.push(0);
  }
  return out;
})();

/** MPF 载荷固定长度。 */
export const MPF_PAYLOAD_LENGTH = 86;
/** MPF 的 TIFF 头相对段起始（0xFF 0xE2）的偏移：marker(2)+length(2)+签名(4)。 */
export const MPF_TIFF_HEADER_DELTA = 8;

function writeU16BE(bytes: Uint8Array, offset: number, value: number): void {
  bytes[offset] = (value >> 8) & 0xff;
  bytes[offset + 1] = value & 0xff;
}

function writeU32BE(bytes: Uint8Array, offset: number, value: number): void {
  bytes[offset] = Math.floor(value / 16777216) & 0xff;
  bytes[offset + 1] = (value >> 16) & 0xff;
  bytes[offset + 2] = (value >> 8) & 0xff;
  bytes[offset + 3] = value & 0xff;
}

function readU16BE(bytes: Uint8Array, offset: number): number {
  return ((bytes[offset] << 8) | bytes[offset + 1]) & 0xffff;
}

function readU32BE(bytes: Uint8Array, offset: number): number {
  return ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8)
    + bytes[offset + 3]) >>> 0;
}

/**
 * 按 TIFF 头声明的字节序读取。**两种端序在真机上都在用**：
 *  - `MM\0*`（大端）：Apple 增益图照片、本模块与参考实现写出的文件；
 *  - `II*\0`（小端）：**Google/小米等 Android 侧写出的 Ultra HDR**（真机样本 `pixel-ultrahdr.jpg` 就是）。
 * 只认大端时，真实 Ultra HDR 文件的 MPF 会解析失败（自检随之失败 → 整个 HDR 改写静默退回原图）。
 */
function readU16(bytes: Uint8Array, offset: number, little: boolean): number {
  if (little) {
    return ((bytes[offset + 1] << 8) | bytes[offset]) & 0xffff;
  }
  return readU16BE(bytes, offset);
}

function readU32(bytes: Uint8Array, offset: number, little: boolean): number {
  if (little) {
    return (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16)
      | (bytes[offset + 3] * 16777216)) >>> 0;
  }
  return readU32BE(bytes, offset);
}

export class HdrMpf {
  /** 构造 MPF 载荷（不含 APP2 段头）。 */
  static buildPayload(primarySize: number, primaryOffset: number,
    secondarySize: number, secondaryOffset: number,
    secondaryAttribute: number = ATTRIBUTE_SECONDARY): Uint8Array {
    const out = new Uint8Array(MPF_PAYLOAD_LENGTH);
    for (let i = 0; i < MPF_SIGNATURE.length; i++) {
      out[i] = MPF_SIGNATURE[i];
    }
    for (let i = 0; i < MPF_BIG_ENDIAN.length; i++) {
      out[4 + i] = MPF_BIG_ENDIAN[i];
    }
    writeU32BE(out, 8, 8); // MP Index IFD 偏移
    writeU16BE(out, 12, TAG_COUNT);
    // tag0：版本（UNDEFINED, count=4, 内联 '0100'）
    writeU16BE(out, 14, TAG_VERSION);
    writeU16BE(out, 16, TYPE_UNDEFINED);
    writeU32BE(out, 18, 4);
    out[22] = 0x30; out[23] = 0x31; out[24] = 0x30; out[25] = 0x30; // '0100'
    // tag1：图片张数（LONG, count=1, 值 2）
    writeU16BE(out, 26, TAG_NUMBER_OF_IMAGES);
    writeU16BE(out, 28, TYPE_LONG);
    writeU32BE(out, 30, 1);
    writeU32BE(out, 34, 2);
    // tag2：MP 条目数组（UNDEFINED, count=32, 偏移 50）
    writeU16BE(out, 38, TAG_MP_ENTRY);
    writeU16BE(out, 40, TYPE_UNDEFINED);
    writeU32BE(out, 42, MP_ENTRY_SIZE * 2);
    writeU32BE(out, 46, MP_ENTRY_DATA_OFFSET);
    // 下一个 IFD（不写）
    writeU32BE(out, 50, 0);
    // 条目 0：主图
    writeU32BE(out, 54, ATTRIBUTE_PRIMARY);
    writeU32BE(out, 58, primarySize);
    writeU32BE(out, 62, primaryOffset);
    writeU16BE(out, 66, 0);
    writeU16BE(out, 68, 0);
    // 条目 1：第二张图（增益图）。
    // attribute 不是随便写的：Apple/Google/OPPO/Samsung 写 0x0（普通 JPEG），
    // **华为/鸿蒙写 0x50000 明确标注「这是 HDR 增益图」**（真机 Mate 80 Pro Max 实测）。
    writeU32BE(out, 70, secondaryAttribute);
    writeU32BE(out, 74, secondarySize);
    writeU32BE(out, 78, secondaryOffset);
    writeU16BE(out, 82, 0);
    writeU16BE(out, 84, 0);
    return out;
  }

  /** 构造完整的 APP2 MPF 段（含 marker 与长度字段）。 */
  static buildApp2(primarySize: number, primaryOffset: number,
    secondarySize: number, secondaryOffset: number,
    secondaryAttribute: number = ATTRIBUTE_SECONDARY): Uint8Array {
    const payload = HdrMpf.buildPayload(primarySize, primaryOffset, secondarySize, secondaryOffset,
      secondaryAttribute);
    const segment = new Uint8Array(payload.length + 4);
    segment[0] = 0xff;
    segment[1] = 0xe2;
    writeU16BE(segment, 2, payload.length + 2);
    segment.set(payload, 4);
    return segment;
  }

  /** APP2 MPF 段的总长度（固定）。 */
  static segmentLength(): number {
    return MPF_PAYLOAD_LENGTH + 4;
  }

  /**
   * 解析文件里的 MPF（用于自检/日志）。
   *
   * @param bytes 文件字节
   * @param segmentStart APP2 段的起始（0xFF 所在位置）
   */
  static parseAt(bytes: Uint8Array, segmentStart: number): MpfInfo | undefined {
    const payloadStart = segmentStart + 4;
    if (payloadStart + MPF_PAYLOAD_LENGTH > bytes.length) {
      return undefined;
    }
    for (let i = 0; i < MPF_SIGNATURE.length; i++) {
      if (bytes[payloadStart + i] !== MPF_SIGNATURE[i]) {
        return undefined;
      }
    }
    const tiff = payloadStart + 4;
    const littleEndian = bytes[tiff] === 0x49 && bytes[tiff + 1] === 0x49;
    const bigEndian = bytes[tiff] === 0x4d && bytes[tiff + 1] === 0x4d;
    if (!bigEndian && !littleEndian) {
      return undefined;
    }
    const ifd = tiff + readU32(bytes, tiff + 4, littleEndian);
    const count = readU16(bytes, ifd, littleEndian);
    if (count <= 0 || count > 16) {
      return undefined;
    }
    let version = '';
    let numberOfImages = 0;
    let entriesRelative = -1;
    let entryCount = 0;
    for (let i = 0; i < count; i++) {
      const tag = readU16(bytes, ifd + 2 + i * TAG_SIZE, littleEndian);
      const valueOffset = ifd + 2 + i * TAG_SIZE + 8;
      if (tag === TAG_VERSION) {
        version = String.fromCharCode(bytes[valueOffset], bytes[valueOffset + 1],
          bytes[valueOffset + 2], bytes[valueOffset + 3]);
      } else if (tag === TAG_NUMBER_OF_IMAGES) {
        numberOfImages = readU32(bytes, valueOffset, littleEndian);
      } else if (tag === TAG_MP_ENTRY) {
        entryCount = readU32(bytes, ifd + 2 + i * TAG_SIZE + 4, littleEndian) / MP_ENTRY_SIZE;
        entriesRelative = tiff + readU32(bytes, valueOffset, littleEndian);
      }
    }
    const entries: MpfEntry[] = [];
    if (entriesRelative > 0) {
      for (let i = 0; i < entryCount && i < 16; i++) {
        const at = entriesRelative + i * MP_ENTRY_SIZE;
        if (at + MP_ENTRY_SIZE > bytes.length) {
          break;
        }
        entries.push({
          attribute: readU32(bytes, at, littleEndian),
          size: readU32(bytes, at + 4, littleEndian),
          offset: readU32(bytes, at + 8, littleEndian)
        });
      }
    }
    return {
      version: version, numberOfImages: numberOfImages, entries: entries,
      tiffHeaderOffset: tiff, entriesOffset: entriesRelative, littleEndian: littleEndian
    };
  }

  /** 主图属性是否是「JPEG + Primary」。 */
  static isPrimary(entry: MpfEntry): boolean {
    return entry.attribute === ATTRIBUTE_PRIMARY;
  }
}
