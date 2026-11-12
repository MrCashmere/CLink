/**
 * HDR / 动态照片链路里的「EXIF 与元数据段」保留工具（**不重编码**路线的核心）。
 *
 * 决策背景见 `docs/HDR_IMAGE.md`：EXIF 走「A. 不重编码」——不解码像素、不动原 EXIF 字节，
 * 让厂商 MakerNote、私有 IFD、缩略图（IFD1）、GPS、方向全部原样保留。
 *
 * 为什么必须字节级搬运而不是「读键值再写回」：
 *  - `readImageMetadata`/`modifyImageProperties` 是**白名单**（`PropertyKey` 枚举），厂商私有块容易丢；
 *  - 一旦把 EXIF 的 IFD 树搬坏（例如把指向原文件数据区的 `StripOffsets`/`ThumbnailOffset` 也搬过去），
 *    相册对「结构性损坏」的处理是**整段丢弃**（连拍摄时间、位置一起没），比「不读 EXIF」更糟。
 *
 * 因此本模块只做两件事：
 *  1. **整段复制**白名单段（EXIF / ICC / IPTC / Adobe / COM）——逐字节，不做任何重写；
 *  2. **丢弃**与旧文件布局绑定的段（典型是 APP2 `MPF\0` 多图格式：它用**绝对偏移**描述第二张图，
 *     容器一变就指向不存在的数据）。
 *
 * 所有函数都是纯字节变换，可在 Node 端直接跑回归（见 `staging/hdr/tests`）。
 */

/** 一个 JPEG 段（从 SOI 之后到 SOS 为止）。 */
export interface JpegSegmentInfo {
  /** 段标记，如 `0xE1`(APP1)、`0xE2`(APP2)、`0xFE`(COM)。 */
  readonly marker: number;
  /** 段起始（`0xFF` 所在位置）。 */
  readonly start: number;
  /** 段结束（不含）。 */
  readonly end: number;
  /** 载荷起始（已跳过长度字段）。 */
  readonly payloadStart: number;
  readonly payloadLength: number;
  /** 语义名：`EXIF` / `XMP` / `ICC` / `MPF` / `APP13` / `ADOBE` / `COM` / `SOS` / `APPn`。 */
  readonly name: string;
}

/** 元数据搬运结果。 */
export interface MetadataCopyResult {
  readonly bytes: Uint8Array;
  /** 成功搬过去的段（语义名，可能带长度）。 */
  readonly copied: string[];
  /** 有意丢弃的段及原因。 */
  readonly dropped: string[];
}

const SOI_0 = 0xff;
const SOI_1 = 0xd8;
const EOI_0 = 0xff;
const EOI_1 = 0xd9;
const EXIF_PREFIX: number[] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]; // 'Exif\0\0'
const XMP_NAMESPACE: number[] = [0x68, 0x74, 0x74, 0x70, 0x3a, 0x2f, 0x2f, 0x6e, 0x73, 0x2e,
  0x61, 0x64, 0x6f, 0x62, 0x65, 0x2e, 0x63, 0x6f, 0x6d, 0x2f, 0x78, 0x61, 0x70, 0x2f,
  0x31, 0x2e, 0x30, 0x2f, 0x00]; // 'http://ns.adobe.com/xap/1.0/\0'
const ICC_PREFIX: number[] = [0x49, 0x43, 0x43, 0x5f, 0x50, 0x52, 0x4f, 0x46, 0x49, 0x4c, 0x45, 0x00];
const MPF_PREFIX: number[] = [0x4d, 0x50, 0x46, 0x00]; // 'MPF\0'
const ADOBE_PREFIX: number[] = [0x41, 0x64, 0x6f, 0x62, 0x65]; // 'Adobe'

/** 默认搬运白名单（与旧文件布局无关、可整段复制的段）。 */
const DEFAULT_COPY: string[] = ['EXIF', 'ICC', 'APP13', 'ADOBE', 'COM'];
/** 默认丢弃黑名单（用绝对偏移描述「另一张图/另一段数据」的段）。 */
const DEFAULT_DROP: string[] = ['MPF'];

function concatBytes(parts: Uint8Array[]): Uint8Array {
  let total = 0;
  for (const part of parts) {
    total += part.length;
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
}

function startsWith(bytes: Uint8Array, at: number, prefix: number[]): boolean {
  if (at < 0 || at + prefix.length > bytes.length) {
    return false;
  }
  for (let i = 0; i < prefix.length; i++) {
    if (bytes[at + i] !== prefix[i]) {
      return false;
    }
  }
  return true;
}

export class HdrExifPreserve {
  static isJpeg(bytes: Uint8Array): boolean {
    return bytes.length >= 4 && bytes[0] === SOI_0 && bytes[1] === SOI_1;
  }

  /** 遍历 JPEG 段（到 SOS 为止；不解析熵编码数据）。 */
  static segments(bytes: Uint8Array, limit: number = -1): JpegSegmentInfo[] {
    const out: JpegSegmentInfo[] = [];
    if (!HdrExifPreserve.isJpeg(bytes)) {
      return out;
    }
    const end = limit > 0 && limit < bytes.length ? limit : bytes.length;
    let cursor = 2;
    let guard = 0;
    while (cursor + 4 <= end && guard < 512) {
      if (bytes[cursor] !== 0xff) {
        break;
      }
      const marker = bytes[cursor + 1];
      if (marker === 0xff) {
        cursor += 1;
        continue;
      }
      // 无载荷标记：RSTn / TEM / SOI
      if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
        cursor += 2;
        continue;
      }
      const length = (bytes[cursor + 2] << 8) | bytes[cursor + 3];
      if (length < 2 || cursor + 2 + length > end) {
        break;
      }
      const payloadStart = cursor + 4;
      const payloadLength = length - 2;
      const name = HdrExifPreserve.segmentName(bytes, marker, payloadStart, payloadLength);
      out.push({
        marker: marker,
        start: cursor,
        end: cursor + 2 + length,
        payloadStart: payloadStart,
        payloadLength: payloadLength,
        name: name
      });
      if (marker === 0xda) {
        break; // SOS 之后是压缩数据
      }
      cursor += 2 + length;
      guard += 1;
    }
    return out;
  }

  /** 段语义名（依据载荷前缀判别；标准标记按名字归类，只有 0xE0–0xEF 才是 APPn）。 */
  static segmentName(bytes: Uint8Array, marker: number, payloadStart: number, payloadLength: number): string {
    if (marker === 0xda) {
      return 'SOS';
    }
    if (marker === 0xfe) {
      return 'COM';
    }
    if (marker === 0xe1 && startsWith(bytes, payloadStart, EXIF_PREFIX)) {
      return 'EXIF';
    }
    if (marker === 0xe1 && startsWith(bytes, payloadStart, XMP_NAMESPACE)) {
      return 'XMP';
    }
    if (marker === 0xe2 && startsWith(bytes, payloadStart, ICC_PREFIX)) {
      return 'ICC';
    }
    if (marker === 0xe2 && startsWith(bytes, payloadStart, MPF_PREFIX)) {
      return 'MPF';
    }
    if (marker === 0xed) {
      return 'APP13';
    }
    if (marker === 0xee && startsWith(bytes, payloadStart, ADOBE_PREFIX)) {
      return 'ADOBE';
    }
    if (marker >= 0xe0 && marker <= 0xef) {
      return 'APP' + (marker - 0xe0).toString();
    }
    // 标准标记：早期实现把 0xC0/0xC4/0xDB 也算成 APPn，日志里出现 APP-32 / APP-28 这类噪音。
    if (marker === 0xc4) {
      return 'DHT';
    }
    if (marker === 0xc8) {
      return 'JPG';
    }
    if (marker === 0xcc) {
      return 'DAC';
    }
    if (marker === 0xdb) {
      return 'DQT';
    }
    if (marker === 0xdd) {
      return 'DRI';
    }
    if (marker >= 0xc0 && marker <= 0xcf) {
      return 'SOF';
    }
    return 'M' + marker.toString(16);
  }

  /** 找到第一个指定语义的段。 */
  static findSegment(bytes: Uint8Array, name: string, limit: number = -1): JpegSegmentInfo | undefined {
    const list = HdrExifPreserve.segments(bytes, limit);
    for (const seg of list) {
      if (seg.name === name) {
        return seg;
      }
    }
    return undefined;
  }

  /** 取出段载荷的完整字节（含宿主前缀，如 `Exif\0\0`）。 */
  static segmentPayload(bytes: Uint8Array, seg: JpegSegmentInfo): Uint8Array {
    return bytes.slice(seg.payloadStart, seg.payloadStart + seg.payloadLength);
  }

  /** EXIF 段载荷（含 `Exif\0\0` 前缀）；没有则 undefined。测试用它做「逐字节一致」比对。 */
  static exifPayload(bytes: Uint8Array, limit: number = -1): Uint8Array | undefined {
    const seg = HdrExifPreserve.findSegment(bytes, 'EXIF', limit);
    return seg === undefined ? undefined : HdrExifPreserve.segmentPayload(bytes, seg);
  }

  /**
   * JPEG 里第一张图的 EOI 之后的位置（找不到 EOI 返回 -1）。
   *
   * **不能**从 SOI 之后朴素地扫第一个 `FF D9`：EXIF APP1 里常常嵌着一张缩略图（IFD1），
   * 它的 EOI 会让扫描提前几十 KB 结束 —— 实测真实 OPPO 样本的 EXIF 是 65 KB（内含缩略图），
   * 朴素养法把 1.3 MB 的基础图截成了 7 KB。
   *
   * 正确做法：先按段走（`segments()` 会在 SOS 处停），从 SOS 之后开始找 EOI，
   * 并跳过字节填充（`FF 00`）、重启标记（`FF D0–D7`）与填充 `FF FF`。
   */
  static jpegEnd(bytes: Uint8Array): number {
    let sosEnd = -1;
    for (const seg of HdrExifPreserve.segments(bytes)) {
      if (seg.marker === 0xda) {
        sosEnd = seg.end;
        break;
      }
    }
    if (sosEnd < 0) {
      return -1;
    }
    let i = sosEnd;
    while (i + 1 < bytes.length) {
      if (bytes[i] !== EOI_0) {
        i += 1;
        continue;
      }
      const next = bytes[i + 1];
      if (next === EOI_1) {
        return i + 2;
      }
      if (next === 0x00 || next === 0xff || (next >= 0xd0 && next <= 0xd7)) {
        i += 2;
        continue;
      }
      // 其它标记：可能是多扫描（progressive）的下一个 SOS 或段头，跳过继续找。
      i += 2;
    }
    return -1;
  }

  /**
   * 把源图的元数据段整段搬到目标图。
   *
   * 规则：
   *  - 白名单段（EXIF/ICC/APP13/ADOBE/COM）**逐字节复制**，不改任何内容；
   *  - 目标里已存在同类段时先删掉，避免出现两个 EXIF；
   *  - 黑名单段（默认 `MPF`）**不搬**并记入 `dropped`（绝对偏移已失效）；
   *  - `includeXmp` 默认 false：XMP 由容器层（增益图/动态照片目录）统一重写，避免两套声明打架。
   */
  static copyMetadataSegments(
    source: Uint8Array,
    target: Uint8Array,
    copyNames: string[] = DEFAULT_COPY,
    dropNames: string[] = DEFAULT_DROP,
    includeXmp: boolean = false
  ): MetadataCopyResult {
    const copied: string[] = [];
    const dropped: string[] = [];
    if (!HdrExifPreserve.isJpeg(source) || !HdrExifPreserve.isJpeg(target)) {
      return { bytes: target, copied: copied, dropped: dropped };
    }
    const sourceSegments = HdrExifPreserve.segments(source);
    // 先把目标里的同类段剔除（保序：其余段原样）。
    let working = target;
    for (const name of copyNames) {
      const existing = HdrExifPreserve.segments(working).filter((seg: JpegSegmentInfo): boolean => seg.name === name);
      for (let i = existing.length - 1; i >= 0; i--) {
        working = HdrExifPreserve.removeSegment(working, existing[i]);
      }
    }
    // 逐个插入（放在 SOI 之后、其余段之前；XMP 惯例如需在前可由调用方再调序）。
    const inserted: Uint8Array[] = [];
    for (const seg of sourceSegments) {
      if (seg.name === 'XMP' && includeXmp) {
        inserted.push(source.slice(seg.start, seg.end));
        copied.push('XMP(' + seg.payloadLength + ')');
        continue;
      }
      if (copyNames.indexOf(seg.name) >= 0) {
        inserted.push(source.slice(seg.start, seg.end));
        copied.push(seg.name + '(' + seg.payloadLength + ')');
      } else if (dropNames.indexOf(seg.name) >= 0) {
        dropped.push(seg.name + '(绝对偏移与旧布局绑定)');
      }
    }
    if (inserted.length === 0) {
      return { bytes: working, copied: copied, dropped: dropped };
    }
    return {
      bytes: concatBytes([working.slice(0, 2), concatBytes(inserted), working.slice(2)]),
      copied: copied,
      dropped: dropped
    };
  }

  /** 删掉指定语义的段（用于「旧布局元数据」清理）。 */
  static dropSegments(bytes: Uint8Array, names: string[]): Uint8Array {
    let working = bytes;
    for (const name of names) {
      const list = HdrExifPreserve.segments(working).filter((seg: JpegSegmentInfo): boolean => seg.name === name);
      for (let i = list.length - 1; i >= 0; i--) {
        working = HdrExifPreserve.removeSegment(working, list[i]);
      }
    }
    return working;
  }

  /**
   * 删掉「ISO 21496-1 标识段」（APP2/APP11，载荷以 `urn:iso:std:iso:ts:21496` 开头）。
   *
   * 为什么需要：这是**华为/鸿蒙那套**（HDR Vivid）的 HDR 判据之一。把华为形态的图片转给
   * Android/Apple 时，我们改用 XMP（`hdrgm` + Container 目录）那套通用判据；两套判据**同时存在**
   * 会让读取器在两套元数据之间摇摆（而且 APP2 里只有一个 URN、没有参数），属于自己给自己制造歧义。
   */
  static dropIsoUrnSegments(bytes: Uint8Array): Uint8Array {
    const marker = 'urn:iso:std:iso:ts:21496';
    let working = bytes;
    const list = HdrExifPreserve.segments(working).filter((seg: JpegSegmentInfo): boolean => {
      if (seg.marker !== 0xe2 && seg.marker !== 0xeb) {
        return false;
      }
      const payload = HdrExifPreserve.segmentPayload(working, seg);
      if (payload.length < marker.length) {
        return false;
      }
      for (let i = 0; i < marker.length; i++) {
        if (payload[i] !== marker.charCodeAt(i)) {
          return false;
        }
      }
      return true;
    });
    for (let i = list.length - 1; i >= 0; i--) {
      working = HdrExifPreserve.removeSegment(working, list[i]);
    }
    return working;
  }

  /** 移除单个段，返回新字节。 */
  static removeSegment(bytes: Uint8Array, seg: JpegSegmentInfo): Uint8Array {
    return concatBytes([bytes.slice(0, seg.start), bytes.slice(seg.end)]);
  }

  /** 用新载荷构造一个 APPn 段（长度字段自洽）。 */
  static buildAppSegment(marker: number, payload: Uint8Array): Uint8Array | undefined {
    if (payload.length + 2 > 65533) {
      return undefined;
    }
    const out = new Uint8Array(payload.length + 4);
    out[0] = 0xff;
    out[1] = marker;
    out[2] = ((payload.length + 2) >> 8) & 0xff;
    out[3] = (payload.length + 2) & 0xff;
    out.set(payload, 4);
    return out;
  }
}
