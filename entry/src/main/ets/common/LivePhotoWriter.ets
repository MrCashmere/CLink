/**
 * 动态图片「写出」：把「图片 + 视频」重新封装成对端相册认得的动态图片格式。
 *
 * 本文件只做纯字节变换（输入 Uint8Array → 输出 Uint8Array），不碰文件系统：
 * 这样可以脱离真机在 `tests/dp-format` 里跑回归（与 DynamicPhotoFormat 的解析互为往返）。
 *
 * 支持两种输出：
 *
 *  1. **Android 标准动态照片**（Google Motion Photo / CIPA DC-007 容器）
 *     - 一张 JPEG：XMP（APP1）里声明 `GCamera:MotionPhoto="1"`，并用
 *       `Container:Directory`（Primary + MotionPhoto 两段）与旧版 `GCamera:MicroVideoOffset`
 *       （从文件末尾倒数的视频长度）两套方言同时描述；
 *     - 视频（MP4）直接**追加在 JPEG 的 EOI 之后**，不需要改动 JPEG 的其它结构。
 *     两套方言都写是为了兼容：新版解析器读 Container，老解析器只认 MicroVideoOffset。
 *
 *  2. **Apple 实况照片**
 *     - 成对的两个文件（同名）：`xxx.jpg` + `xxx.mov`；
 *     - 视频（QuickTime）的 `moov` 下插入 mdta `meta`，写入
 *       `com.apple.quicktime.content.identifier`（资产标识）与
 *       `com.apple.quicktime.still-image-time`；
 *     - 静态图 EXIF 的 `ExifIFD → MakerNote(0x927C) → Apple MakerNote → tag 0x0011`
 *       写入同一个标识。二者一致，iOS「照片」才把这一对认成一张实况照片。
 *
 * 坑（都踩过）：
 *  - 往 `moov` 里插字节会让**它后面的 box 整体后移**，`stco/co64` 里的分片偏移必须同步加上
 *    插入长度，否则视频会花屏/播不动（只有当 `mdat` 排在插入点之后时才需要平移）；
 *  - JPEG 的 APP1 段长度字段是 2 字节（最大 65533 字节载荷），XMP 段超长必须放弃而不是写出坏段；
 *  - 重写 EXIF 时不能只换 MakerNote：IFD0 里的 ExifIFD(0x8769)/GPS(0x8825)/Interop(0xA005)
 *    指针和「值超过 4 字节的条目」都指向原文件里的数据区，必须整棵树一起搬。
 */

import { Isobmff, IsobmffView } from './Isobmff';
import { HdrMp4 } from './HdrMp4';

/** 目标动态图片格式。 */
export type LivePhotoWriteFormat = 'apple' | 'android';

/**
 * Android 动态照片的**厂商方言**。
 *
 * 国产机型在 Google 容器之外还会写自家命名空间（真实 OPPO 样本就同时写 `GCamera:` 与
 * `OpCamera:`+`ns.oplus.com`），各家相册是否认账主要由自家字段决定。因此按对端品牌选方言：
 * 通用字段照写，额外叠加该品牌的命名空间与字段。
 *
 * `samsung` 只叠 `GCamera:MotionPhotoOwner`：三星自家文件另有 SEFH/SEFT 尾部表，
 * 其内部字段未实现（见 docs/DYNAMIC_PHOTO.md §3.3），所以走的是三星同样兼容的 Google 容器。
 */
export type AndroidMotionDialect = 'google' | 'xiaomi' | 'oppo' | 'vivo' | 'samsung' | 'universal';

/** Apple 实况照片写出结果（成对文件）。 */
export interface AppleLivePhotoResult {
  readonly image: Uint8Array;
  readonly video: Uint8Array;
  /** 写入两侧的资产标识（32/36 字符的 UUID 文本）。 */
  readonly identifier: string;
}

/** Android 标准动态照片写出结果（单文件）。 */
export interface AndroidMotionPhotoResult {
  readonly bytes: Uint8Array;
  /** 主图（含 XMP 的 JPEG）长度。 */
  readonly primaryLength: number;
  readonly videoLength: number;
  /**
   * 追加前对视频做的 MP4 处理结果（`HdrMp4.makeFaststart` 的 `reason`）。
   * 动图视频从鸿蒙动态照片提取出来时 `moov` 在文件末尾，而 OPPO/小米自家文件都是 `moov` 在前
   * —— 国产相册很可能只前向解析，所以写入前统一搬到前面（见 `HdrMp4`）。
   */
  readonly videoLayout: string;
}

/** JPEG 段（不含 SOI 之前）。 */
interface JpegSegment {
  readonly marker: number;
  readonly start: number;
  readonly end: number;
  /** 段载荷起始（已跳过长度字段）。 */
  readonly payloadStart: number;
}

/** 从源 EXIF 里读出的条目（值已展开成字节）。 */
interface TiffRawEntry {
  readonly tag: number;
  readonly type: number;
  readonly count: number;
  readonly data: Uint8Array;
  /** 指针型 tag（0x8769/0x8825/0xA005）指向的子 IFD。 */
  readonly child?: TiffRawIfd;
}

interface TiffRawIfd {
  readonly entries: TiffRawEntry[];
}

/** 待写出的 EXIF 条目。 */
interface OutEntry {
  tag: number;
  type: number;
  count: number;
  data: Uint8Array;
  /** 指针型条目的子 IFD。 */
  child?: OutIfd;
  /** 需要额外排布的裸数据块（Apple MakerNote 里指向的标识字符串）。 */
  extra?: Uint8Array;
  /** 计算出的数据块偏移（相对 TIFF 头）。 */
  dataOffset: number;
  extraOffset: number;
}

interface OutIfd {
  entries: OutEntry[];
  offset: number;
}

const APP1_MARKER: number = 0xe1;
const XMP_NAMESPACE: string = 'http://ns.adobe.com/xap/1.0/\u0000';
const XMP_NAMESPACE_BYTES: Uint8Array = asciiBytes(XMP_NAMESPACE);
const EXIF_PREFIX: Uint8Array = new Uint8Array([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]); // 'Exif\0\0'
const APPLE_MAKER_NOTE_MAGIC: Uint8Array = new Uint8Array([0x41, 0x70, 0x70, 0x6c, 0x65, 0x20, 0x69, 0x4f, 0x53]); // 'Apple iOS'
/** Apple MakerNote 固定长度：9 字节魔数 + 5 字节头 + 1 条 IFD 条目 + next 指针。 */
const APPLE_MAKER_NOTE_LENGTH: number = 32;
/** MakerNote 内 IFD 相对 MakerNote 起点的偏移（解析端按 14/12/16/10/18 试，14 命中）。 */
const APPLE_MAKER_NOTE_IFD_DELTA: number = 14;
const TIFF_HEADER_LENGTH: number = 8;
const MAX_SEGMENT_PAYLOAD: number = 65533;
const MAX_TIFF_VALUE_BYTES: number = 8 * 1024 * 1024;

/** 把 ASCII 字符串转成字节（XMP / 键名都是 ASCII；非 ASCII 一律按 '?' 折叠）。 */
function asciiBytes(text: string): Uint8Array {
  const out = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    out[i] = code <= 0x7f ? code : 0x3f;
  }
  return out;
}

/** 把 UTF-8 字符串转成字节（标识字符串是 ASCII，用同一实现即可）。 */
function utf8Bytes(text: string): Uint8Array {
  return asciiBytes(text);
}

function align4(value: number): number {
  return (value + 3) & ~3;
}

/** 读取 4 字节 4CC（不可打印字节按 '?' 折叠，仅用于判据）。 */
function fourCcAt(bytes: Uint8Array, offset: number): string {
  if (offset < 0 || offset + 4 > bytes.length) {
    return '';
  }
  return String.fromCharCode(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]);
}

/** MP4/MOV 的已知顶层 box 类型。 */
const KNOWN_TOP_LEVEL_BOXES: string[] = [
  'moov', 'mdat', 'free', 'skip', 'wide', 'uuid', 'meta', 'moof', 'sidx', 'pdin', 'junk', 'udta'
];

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

function writeU16LE(bytes: Uint8Array, offset: number, value: number): void {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >> 8) & 0xff;
}

function writeU32LE(bytes: Uint8Array, offset: number, value: number): void {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >> 8) & 0xff;
  bytes[offset + 2] = (value >> 16) & 0xff;
  bytes[offset + 3] = Math.floor(value / 16777216) & 0xff;
}

/** 读取 4 字节无符号整数（小端）。 */
function readU32LE(bytes: Uint8Array, offset: number): number {
  return (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16)
    | (bytes[offset + 3] * 16777216)) >>> 0;
}

export class LivePhotoWriter {
  // ---------------------------------------------------------------------
  // 通用
  // ---------------------------------------------------------------------

  /** 生成一个 Apple 风格的资产标识（大写 UUID，与 iOS 写出的形态一致）。 */
  static newIdentifier(seed?: number): string {
    const base = seed !== undefined && seed > 0 ? seed : Date.now();
    let state = (base % 4294967296) >>> 0;
    if (state === 0) {
      state = 0x9e3779b9;
    }
    const hex = '0123456789ABCDEF';
    let raw = '';
    for (let i = 0; i < 32; i++) {
      // xorshift32：只要确定性、不重复即可，不用于安全用途。
      state ^= (state << 13) >>> 0;
      state = state >>> 0;
      state ^= state >>> 17;
      state ^= (state << 5) >>> 0;
      state = state >>> 0;
      raw += hex.charAt(state & 0x0f);
    }
    return raw.substring(0, 8) + '-' + raw.substring(8, 12) + '-' + raw.substring(12, 16)
      + '-' + raw.substring(16, 20) + '-' + raw.substring(20, 32);
  }

  static isJpeg(bytes: Uint8Array): boolean {
    return bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8;
  }

  /**
   * 粗略校验「这是一段 MP4/MOV」：以 `ftyp` 开头、首个 box 尺寸自洽。
   *
   * 为什么要判：Android 动态照片是「JPEG 尾部直接追加视频字节」，追加一段非 MP4 的东西
   * 会得到一个坏掉的动态照片（相册打开就报错），不如提前放弃、退回「图片 + 视频」拆分。
   */
  static looksLikeMp4(bytes: Uint8Array): boolean {
    if (bytes.length < 16) {
      return false;
    }
    if (fourCcAt(bytes, 4) !== 'ftyp') {
      return false;
    }
    const size = Isobmff.readU32(bytes, 0);
    if (size < 16 || size > bytes.length || size > 65536) {
      return false;
    }
    // 紧随 ftyp 之后应当还有一个已知顶层 box（moov/mdat/free…），避免把巧合字节当成视频。
    if (size + 8 <= bytes.length) {
      return KNOWN_TOP_LEVEL_BOXES.indexOf(fourCcAt(bytes, size + 4)) >= 0;
    }
    return true;
  }

  /** 遍历 JPEG 的段（到 SOS 为止）。 */
  static jpegSegments(bytes: Uint8Array): JpegSegment[] {
    const segments: JpegSegment[] = [];
    if (!LivePhotoWriter.isJpeg(bytes)) {
      return segments;
    }
    let cursor = 2;
    let guard = 0;
    while (cursor + 4 <= bytes.length && guard < 512) {
      if (bytes[cursor] !== 0xff) {
        break;
      }
      const marker = bytes[cursor + 1];
      if (marker === 0xff) {
        cursor += 1;
        continue;
      }
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
        cursor += 2;
        continue;
      }
      const length = (bytes[cursor + 2] << 8) | bytes[cursor + 3];
      if (length < 2 || cursor + 2 + length > bytes.length) {
        break;
      }
      segments.push({
        marker: marker,
        start: cursor,
        end: cursor + 2 + length,
        payloadStart: cursor + 4
      });
      if (marker === 0xda) {
        break; // SOS 之后是压缩数据，不再当作段解析。
      }
      cursor += 2 + length;
      guard += 1;
    }
    return segments;
  }

  private static startsWith(bytes: Uint8Array, at: number, prefix: Uint8Array): boolean {
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

  /** 构造一个 APP1 段（含 marker 与长度字段）。返回 undefined 表示载荷超长。 */
  private static app1Segment(payload: Uint8Array): Uint8Array | undefined {
    if (payload.length > MAX_SEGMENT_PAYLOAD) {
      return undefined;
    }
    const segment = new Uint8Array(payload.length + 4);
    segment[0] = 0xff;
    segment[1] = APP1_MARKER;
    writeU16BE(segment, 2, payload.length + 2);
    segment.set(payload, 4);
    return segment;
  }

  /** 找到 JPEG 里第一个 XMP APP1 段。 */
  private static findXmpSegment(bytes: Uint8Array): JpegSegment | undefined {
    for (const segment of LivePhotoWriter.jpegSegments(bytes)) {
      if (segment.marker === APP1_MARKER
        && LivePhotoWriter.startsWith(bytes, segment.payloadStart, XMP_NAMESPACE_BYTES)) {
        return segment;
      }
    }
    return undefined;
  }

  /** 找到 JPEG 里第一个 `Exif\0\0` APP1 段。 */
  private static findExifSegment(bytes: Uint8Array): JpegSegment | undefined {
    for (const segment of LivePhotoWriter.jpegSegments(bytes)) {
      if (segment.marker === APP1_MARKER
        && LivePhotoWriter.startsWith(bytes, segment.payloadStart, EXIF_PREFIX)) {
        return segment;
      }
    }
    return undefined;
  }

  /**
   * 写入/替换 JPEG 的 XMP（APP1）。已有 XMP 段时原地替换，否则插到 SOI 之后（Google 相机的位置）。
   */
  static writeXmpApp1(jpeg: Uint8Array, xmp: string): Uint8Array | undefined {
    if (!LivePhotoWriter.isJpeg(jpeg)) {
      return undefined;
    }
    const payload = concatBytes([XMP_NAMESPACE_BYTES, utf8Bytes(xmp)]);
    const app1 = LivePhotoWriter.app1Segment(payload);
    if (app1 === undefined) {
      return undefined;
    }
    const existing = LivePhotoWriter.findXmpSegment(jpeg);
    if (existing !== undefined) {
      return concatBytes([jpeg.slice(0, existing.start), app1, jpeg.slice(existing.end)]);
    }
    return concatBytes([jpeg.slice(0, 2), app1, jpeg.slice(2)]);
  }

  // ---------------------------------------------------------------------
  // Android 标准动态照片
  // ---------------------------------------------------------------------

  /**
   * 构造 Google Motion Photo 的 XMP 文本（可按厂商方言叠加自家字段）。
   *
   * 同时写两套方言：
   *  - `Container:Directory`（Android 13+ / CIPA DC-007）：按段顺序声明 Primary 与 MotionPhoto；
   *  - `GCamera:MicroVideoOffset`（旧版 Google 相机）：从**文件末尾**倒数的视频长度。
   *
   * 对端是具体品牌时再叠该品牌的命名空间（`dialect`）：真实 OPPO 样本的形态是
   * `GCamera` + `OpCamera`(`ns.oplus.com`) 并存，因此「通用 + 自家」是最稳的组合。
   */
  /**
   * 动图的**属性部分**：Google 的动图声明 + 需要时的旧版 `GCamera:MicroVideo*` + 厂商私有字段。
   *
   * 抽出来是为了让 HDR 路径复用：HDR 动态照片的 XMP 由 `HdrGainMap` 生成，
   * 早期只写了 `hdrgm` + 容器目录 + 厂商字段，**漏了「这是动图」的声明** ——
   * 结果 Google 相册不把它当动态照片（真机实测）。两边共用这一份就不会再漏。
   *
   * `MicroVideo*`（旧版 Google 相机那套）**只对非 OPPO 方言写**：真机 OPPO 自家文件的 XMP 里
   * 一条 `MicroVideo*` 都没有（只有 `GCamera:MotionPhoto*` + `OpCamera:*`），而 Pixel 自家文件
   * 也没有 —— 说明现代读取器靠 `Container:Directory` 找视频，旧字段属于历史包袱。OPPO 相册在
   * 「Google 相册认、ColorOS 不认」的实测下，少写无关字段更接近它自家形态。
   */
  static buildMotionPhotoAttributes(videoLength: number, dialect: AndroidMotionDialect): string {
    const google = ' xmlns:GCamera="http://ns.google.com/photos/1.0/camera/"'
      + ' GCamera:MotionPhoto="1"'
      + ' GCamera:MotionPhotoVersion="1"'
      + ' GCamera:MotionPhotoPresentationTimestampUs="0"';
    // 旧版字段：`MicroVideoOffset` = 从**文件末尾**倒数的视频长度（Google 旧规范）。
    const legacy = dialect === 'oppo'
      ? ''
      : ' GCamera:MicroVideo="1"'
        + ' GCamera:MicroVideoVersion="1"'
        + ' GCamera:MicroVideoOffset="' + videoLength + '"'
        + ' GCamera:MicroVideoPresentationTimestampUs="0"';
    return google + legacy + LivePhotoWriter.buildMotionPhotoVendorAttributes(videoLength, dialect);
  }

  /**
   * 各家「私有方言」的 XMP 命名空间 + 字段（直接拼进 `rdf:Description` 用的字符串）。
   *
   * 抽成公开方法是为了让 **HDR 路径复用**：HDR 动态照片要在一个 XMP 里同时声明
   * 三家容器项（Primary + GainMap + MotionPhoto）与厂商字段（见
   * `HdrGainMap.writeDualJpegWithGainMap` 的 extraAttributes）。两边各写一份必然走样。
   */
  static buildMotionPhotoVendorAttributes(videoLength: number, dialect: AndroidMotionDialect): string {
    if (dialect === 'oppo') {
      // 与真机 OPPO 自家文件的字段集合对齐（`OpCamera` 的那几个字段一个不少、也不多写）：
      // `MotionPhotoOwner` / `OLivePhotoVersion` / `VideoLength`（视频字节数）/
      // `MotionPhotoPrimaryPresentationTimestampUs`（照片对应视频里的哪一帧，我们取 0 = 第一帧）。
      return ' xmlns:OpCamera="http://ns.oplus.com/photos/1.0/camera/"'
        + ' OpCamera:MotionPhotoOwner="oplus" OpCamera:OLivePhotoVersion="2"'
        + ' OpCamera:MotionPhotoPrimaryPresentationTimestampUs="0"'
        + ' OpCamera:VideoLength="' + videoLength + '"';
    }
    if (dialect === 'xiaomi') {
      return ' xmlns:XMPhoto="http://ns.xiaomi.com/photos/1.0/camera/"'
        + ' XMPhoto:MotionPhotoOwner="xiaomi" XMPhoto:MotionPhotoVersion="1"'
        + ' XMPhoto:VideoLength="' + videoLength + '"';
    }
    if (dialect === 'vivo') {
      return ' xmlns:vivo="http://ns.vivo.com/photos/1.0/camera/"'
        + ' vivo:MotionPhotoOwner="vivo" vivo:MotionPhotoVersion="1"'
        + ' vivo:VideoLength="' + videoLength + '"';
    }
    if (dialect === 'samsung') {
      // 三星不在自家文件里依赖私有命名空间（它另有 SEF 尾部表，本工程未实现），
      // 这里补一个厂商归属字段，容器仍走 Google 那套。
      return ' GCamera:MotionPhotoOwner="samsung"';
    }
    if (dialect === 'universal') {
      // 「全方言」：认不出对端品牌时用。
      //
      // 真机踩到的场景：对端是 OnePlus/OPPO，但它广播的名字（如「皓然的手机」）与 model 里
      // 都没有品牌关键字 → 识别失败 → 回落成 Google 通用方言，OPPO 相册不当自家动态照片。
      // 各家只读自己命名空间里的字段、对陌生命名空间一律忽略，所以**一次全写**是安全的：
      // OPPO 读 OpCamera、小米读 XMPhoto/MiCamera、vivo 读 vivo，Google 那套谁都认。
      // 依据：真实小米文件用 `MiCamera` 前缀（URI 与 XMPhoto 相同）、OPPO 用 OpCamera
      // （见 docs/DYNAMIC_PHOTO.md §1.6.1），以及 flashlab/motion-live-photo 的「三方言同写」模板。
      return ' xmlns:OpCamera="http://ns.oplus.com/photos/1.0/camera/"'
        + ' xmlns:XMPhoto="http://ns.xiaomi.com/photos/1.0/camera/"'
        + ' xmlns:MiCamera="http://ns.xiaomi.com/photos/1.0/camera/"'
        + ' xmlns:vivo="http://ns.vivo.com/photos/1.0/camera/"'
        + ' OpCamera:MotionPhotoOwner="oplus" OpCamera:OLivePhotoVersion="2"'
        + ' OpCamera:MotionPhotoPrimaryPresentationTimestampUs="0"'
        + ' OpCamera:VideoLength="' + videoLength + '"'
        + ' XMPhoto:MotionPhotoOwner="xiaomi" XMPhoto:MotionPhotoVersion="1"'
        + ' XMPhoto:VideoLength="' + videoLength + '"'
        + ' vivo:MotionPhotoOwner="vivo" vivo:MotionPhotoVersion="1"'
        + ' vivo:VideoLength="' + videoLength + '"'
        + ' MiCamera:XMPMeta="&lt;?xml version=\'1.0\' encoding=\'UTF-8\' standalone=\'yes\' ?&gt;"';
    }
    return '';
  }

  static buildMotionPhotoXmp(primaryLength: number, videoLength: number,
    dialect: AndroidMotionDialect): string {
    const attributes = LivePhotoWriter.buildMotionPhotoAttributes(videoLength, dialect);
    const head = '<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?>'
      + '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Cashmere Link">'
      + '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
      + '<rdf:Description rdf:about=""'
      + ' xmlns:Container="http://ns.google.com/photos/1.0/container/"'
      + ' xmlns:Item="http://ns.google.com/photos/1.0/container/item/"'
      + attributes + '>'
      + '<Container:Directory><rdf:Seq>'
      + '<rdf:li rdf:parseType="Resource"><Container:Item'
      + ' Item:Mime="image/jpeg" Item:Semantic="Primary"'
      + ' Item:Length="' + primaryLength + '" Item:Padding="0"/></rdf:li>'
      + '<rdf:li rdf:parseType="Resource"><Container:Item'
      + ' Item:Mime="video/mp4" Item:Semantic="MotionPhoto"'
      + ' Item:Length="' + videoLength + '" Item:Padding="0"/></rdf:li>'
      + '</rdf:Seq></Container:Directory>'
      + '</rdf:Description></rdf:RDF></x:xmpmeta>';
    return head;
  }

  /**
   * 把「图片 + 视频」写成 Android 标准动态照片（单文件）。
   *
   * 主图长度会写进 XMP，而 XMP 自己又占字节 —— 因此这里迭代几次让长度自洽
   * （XMP 数字位数最多变一次，2~3 轮必收敛）。
   */
  static writeAndroidMotionPhoto(jpeg: Uint8Array, video: Uint8Array,
    dialect: AndroidMotionDialect): AndroidMotionPhotoResult | undefined {
    if (!LivePhotoWriter.isJpeg(jpeg) || !LivePhotoWriter.looksLikeMp4(video)) {
      return undefined;
    }
    // 视频统一搬到 `moov` 在前（faststart）：OPPO / 小米自家动图的视频都是这个布局，
    // 而我们从鸿蒙动态照片提取的视频是 `moov` 在后（真机：Google 相册认、OPPO 相册不认）。
    const faststart = HdrMp4.makeFaststart(video);
    const embedded = faststart.bytes;
    let primaryLength = jpeg.length;
    let image = LivePhotoWriter.writeXmpApp1(jpeg,
      LivePhotoWriter.buildMotionPhotoXmp(primaryLength, embedded.length, dialect));
    if (image === undefined) {
      return undefined;
    }
    for (let pass = 0; pass < 4; pass++) {
      if (image.length === primaryLength) {
        break;
      }
      primaryLength = image.length;
      const next = LivePhotoWriter.writeXmpApp1(jpeg,
        LivePhotoWriter.buildMotionPhotoXmp(primaryLength, embedded.length, dialect));
      if (next === undefined) {
        return undefined;
      }
      image = next;
    }
    return {
      bytes: concatBytes([image, embedded]),
      primaryLength: image.length,
      videoLength: embedded.length,
      videoLayout: faststart.moved ? 'moov-moved:' + faststart.reason : faststart.reason
    };
  }

  // ---------------------------------------------------------------------
  // Apple 实况照片：JPEG 侧（EXIF ContentIdentifier）
  // ---------------------------------------------------------------------

  /** 构造 Apple MakerNote（32 字节），其中 IFD 条目 0x0011 指向标识字符串。 */
  private static buildAppleMakerNote(little: boolean, magicCount: number, tiffOffset: number): Uint8Array {
    const note = new Uint8Array(APPLE_MAKER_NOTE_LENGTH);
    note.set(APPLE_MAKER_NOTE_MAGIC, 0);
    note[9] = 0x00;
    // Apple 写入的版本号（不参与解析，按真实文件形态填 0x0001）。
    if (little) {
      writeU16LE(note, 10, 0x0001);
      writeU16LE(note, 12, 0x0000);
      writeU16LE(note, APPLE_MAKER_NOTE_IFD_DELTA, 1);
      const entry = APPLE_MAKER_NOTE_IFD_DELTA + 2;
      writeU16LE(note, entry, 0x0011);
      writeU16LE(note, entry + 2, 2); // ASCII
      writeU32LE(note, entry + 4, magicCount);
      writeU32LE(note, entry + 8, tiffOffset);
      writeU32LE(note, entry + 12, 0);
    } else {
      writeU16BE(note, 10, 0x0001);
      writeU16BE(note, 12, 0x0000);
      writeU16BE(note, APPLE_MAKER_NOTE_IFD_DELTA, 1);
      const entry = APPLE_MAKER_NOTE_IFD_DELTA + 2;
      writeU16BE(note, entry, 0x0011);
      writeU16BE(note, entry + 2, 2); // ASCII
      writeU32BE(note, entry + 4, magicCount);
      writeU32BE(note, entry + 8, tiffOffset);
      writeU32BE(note, entry + 12, 0);
    }
    return note;
  }

  /** 读源 TIFF 的一个 IFD（含子 IFD 递归）。返回 undefined 表示结构不可解析。 */
  private static readIfd(tiff: Uint8Array, offset: number, little: boolean, depth: number): TiffRawIfd | undefined {
    if (depth > 3 || offset < 0 || offset + 2 > tiff.length) {
      return undefined;
    }
    const count = little
      ? (tiff[offset] | (tiff[offset + 1] << 8))
      : ((tiff[offset] << 8) | tiff[offset + 1]);
    if (count <= 0 || count > 1024 || offset + 2 + count * 12 > tiff.length) {
      return undefined;
    }
    const entries: TiffRawEntry[] = [];
    for (let i = 0; i < count; i++) {
      const at = offset + 2 + i * 12;
      const tag = little
        ? (tiff[at] | (tiff[at + 1] << 8))
        : ((tiff[at] << 8) | tiff[at + 1]);
      const type = little
        ? (tiff[at + 2] | (tiff[at + 3] << 8))
        : ((tiff[at + 2] << 8) | tiff[at + 3]);
      const itemCount = little ? readU32LE(tiff, at + 4) : Isobmff.readU32(tiff, at + 4);
      const valueField = little ? readU32LE(tiff, at + 8) : Isobmff.readU32(tiff, at + 8);
      if (type <= 0 || type > 12) {
        return undefined;
      }
      const size = Isobmff.tiffTypeSize(type) * itemCount;
      if (size < 0 || size > MAX_TIFF_VALUE_BYTES) {
        return undefined;
      }
      if (tag === 0x8769 || tag === 0x8825 || tag === 0xa005) {
        const child = LivePhotoWriter.readIfd(tiff, valueField, little, depth + 1);
        entries.push({ tag: tag, type: type, count: itemCount, data: new Uint8Array(0), child: child });
        continue;
      }
      let data: Uint8Array;
      if (size <= 4) {
        const raw = tiff.slice(at + 8, at + 12);
        data = raw.slice(0, size);
      } else {
        if (valueField + size > tiff.length) {
          return undefined;
        }
        data = tiff.slice(valueField, valueField + size);
      }
      entries.push({ tag: tag, type: type, count: itemCount, data: data });
    }
    return { entries: entries };
  }

  private static toOutEntry(raw: TiffRawEntry): OutEntry {
    if (raw.child !== undefined) {
      return {
        tag: raw.tag, type: raw.type, count: raw.count, data: new Uint8Array(0),
        child: LivePhotoWriter.toOutIfd(raw.child), dataOffset: 0, extraOffset: 0
      };
    }
    return {
      tag: raw.tag, type: raw.type, count: raw.count, data: raw.data,
      dataOffset: 0, extraOffset: 0
    };
  }

  private static toOutIfd(raw: TiffRawIfd): OutIfd {
    const entries: OutEntry[] = [];
    for (const item of raw.entries) {
      entries.push(LivePhotoWriter.toOutEntry(item));
    }
    return { entries: entries, offset: 0 };
  }

  /** 取出（或新建）ExifIFD，并把 Apple MakerNote 条目写进去。 */
  private static attachMakerNoteIfd(root: OutIfd, magicCount: number, identifierBytes: Uint8Array): OutIfd {
    let exif: OutIfd | undefined = undefined;
    for (const entry of root.entries) {
      if (entry.tag === 0x8769 && entry.child !== undefined) {
        exif = entry.child;
      }
    }
    if (exif === undefined) {
      exif = { entries: [], offset: 0 };
      root.entries.push({
        tag: 0x8769, type: 4, count: 1, data: new Uint8Array(4),
        child: exif, dataOffset: 0, extraOffset: 0
      });
    }
    // 去掉源文件里已有的 MakerNote（可能是别家厂商的，格式不兼容）后写入我们的。
    const kept: OutEntry[] = [];
    for (const entry of exif.entries) {
      if (entry.tag !== 0x927c) {
        kept.push(entry);
      }
    }
    kept.push({
      tag: 0x927c,
      type: 7,
      count: APPLE_MAKER_NOTE_LENGTH,
      data: new Uint8Array(APPLE_MAKER_NOTE_LENGTH),
      extra: identifierBytes,
      dataOffset: 0,
      extraOffset: 0
    });
    exif.entries = kept;
    return exif;
  }

  /**
   * 序列化 EXIF（TIFF）树。
   *
   * 两遍：
   *  1. 先给所有 IFD 和数据块分配偏移，从而知道标识字符串最终落在哪里；
   *  2. 用它回填 Apple MakerNote 里的指针，再真正写出字节。
   */
  private static serializeTiff(root: OutIfd, little: boolean, magicCount: number, identifierBytes: Uint8Array): Uint8Array {
    const ifds: OutIfd[] = [];
    const collect = (ifd: OutIfd): void => {
      ifds.push(ifd);
      for (const entry of ifd.entries) {
        if (entry.child !== undefined) {
          collect(entry.child);
        }
      }
    };
    collect(root);
    let cursor = TIFF_HEADER_LENGTH;
    for (const ifd of ifds) {
      ifd.entries.sort((a: OutEntry, b: OutEntry): number => a.tag - b.tag);
      ifd.offset = cursor;
      cursor += 2 + ifd.entries.length * 12 + 4;
    }
    let identifierOffset = -1;
    for (const ifd of ifds) {
      for (const entry of ifd.entries) {
        if (entry.child !== undefined) {
          continue;
        }
        if (entry.data.length > 4) {
          entry.dataOffset = cursor;
          cursor = align4(cursor + entry.data.length);
        }
        if (entry.extra !== undefined) {
          entry.extraOffset = cursor;
          cursor = align4(cursor + entry.extra.length);
          if (identifierOffset < 0) {
            identifierOffset = entry.extraOffset;
          }
        }
      }
    }
    // 回填 MakerNote：它内部 IFD 里 0x0011 的值偏移必须相对 TIFF 头。
    for (const ifd of ifds) {
      for (const entry of ifd.entries) {
        if (entry.tag === 0x927c && entry.extra !== undefined && identifierOffset >= 0) {
          entry.data = LivePhotoWriter.buildAppleMakerNote(little, magicCount, identifierOffset);
        }
      }
    }
    const out = new Uint8Array(cursor);
    if (little) {
      out[0] = 0x49;
      out[1] = 0x49;
      writeU16LE(out, 2, 0x2a);
      writeU32LE(out, 4, TIFF_HEADER_LENGTH);
    } else {
      out[0] = 0x4d;
      out[1] = 0x4d;
      writeU16BE(out, 2, 0x2a);
      writeU32BE(out, 4, TIFF_HEADER_LENGTH);
    }
    for (const ifd of ifds) {
      const base = ifd.offset;
      if (little) {
        writeU16LE(out, base, ifd.entries.length);
      } else {
        writeU16BE(out, base, ifd.entries.length);
      }
      for (let i = 0; i < ifd.entries.length; i++) {
        const entry = ifd.entries[i];
        const at = base + 2 + i * 12;
        if (little) {
          writeU16LE(out, at, entry.tag);
          writeU16LE(out, at + 2, entry.type);
          writeU32LE(out, at + 4, entry.count);
        } else {
          writeU16BE(out, at, entry.tag);
          writeU16BE(out, at + 2, entry.type);
          writeU32BE(out, at + 4, entry.count);
        }
        if (entry.child !== undefined) {
          if (little) {
            writeU32LE(out, at + 8, entry.child.offset);
          } else {
            writeU32BE(out, at + 8, entry.child.offset);
          }
          continue;
        }
        if (entry.data.length > 4) {
          if (little) {
            writeU32LE(out, at + 8, entry.dataOffset);
          } else {
            writeU32BE(out, at + 8, entry.dataOffset);
          }
          out.set(entry.data, entry.dataOffset);
        } else {
          out.set(entry.data, at + 8);
        }
      }
      if (little) {
        writeU32LE(out, base + 2 + ifd.entries.length * 12, 0);
      } else {
        writeU32BE(out, base + 2 + ifd.entries.length * 12, 0);
      }
    }
    for (const ifd of ifds) {
      for (const entry of ifd.entries) {
        if (entry.extra !== undefined) {
          out.set(entry.extra, entry.extraOffset);
        }
      }
    }
    return out;
  }

  /**
   * 把标识写进 JPEG 的 EXIF（ExifIFD → MakerNote → Apple tag 0x0011）。
   *
   * 源文件已有 EXIF 时会**整棵树重建**（IFD0 + ExifIFD + GPS/Interop + 超长值数据块），
   * 只替换 MakerNote；保留其它条目是为了不丢方向/时间等拍摄信息。
   * 重建失败时退回「最小 EXIF」——宁可丢原 EXIF，也不能写出坏结构。
   */
  static writeAppleExifIdentifier(jpeg: Uint8Array, identifier: string): Uint8Array | undefined {
    if (!LivePhotoWriter.isJpeg(jpeg)) {
      return undefined;
    }
    const identifierBytes = concatBytes([utf8Bytes(identifier), new Uint8Array(1)]); // 33 字节含结尾 NUL
    const magicCount = identifierBytes.length;
    const existing = LivePhotoWriter.findExifSegment(jpeg);
    let tiff: Uint8Array | undefined = undefined;
    let little = false;
    if (existing !== undefined) {
      const payload = jpeg.slice(existing.payloadStart + EXIF_PREFIX.length, existing.end);
      if (payload.length >= TIFF_HEADER_LENGTH) {
        const isLittle = payload[0] === 0x49 && payload[1] === 0x49;
        const isBig = payload[0] === 0x4d && payload[1] === 0x4d;
        if (isLittle || isBig) {
          const ifd0Offset = isLittle
            ? ((payload[4] | (payload[5] << 8) | (payload[6] << 16) | (payload[7] * 16777216)) >>> 0)
            : Isobmff.readU32(payload, 4);
          const raw = LivePhotoWriter.readIfd(payload, ifd0Offset, isLittle, 0);
          if (raw !== undefined) {
            little = isLittle;
            const root = LivePhotoWriter.toOutIfd(raw);
            LivePhotoWriter.attachMakerNoteIfd(root, magicCount, identifierBytes);
            tiff = LivePhotoWriter.serializeTiff(root, little, magicCount, identifierBytes);
          }
        }
      }
    }
    if (tiff === undefined) {
      // 兜底：只有 IFD0 → ExifIFD → MakerNote 三个结构的最小 EXIF（大端，贴近 Apple 习惯）。
      little = false;
      const exifIfd: OutIfd = { entries: [], offset: 0 };
      const root: OutIfd = {
        entries: [{
          tag: 0x8769, type: 4, count: 1, data: new Uint8Array(4),
          child: exifIfd, dataOffset: 0, extraOffset: 0
        }],
        offset: 0
      };
      LivePhotoWriter.attachMakerNoteIfd(root, magicCount, identifierBytes);
      tiff = LivePhotoWriter.serializeTiff(root, little, magicCount, identifierBytes);
    }
    const app1 = LivePhotoWriter.app1Segment(concatBytes([EXIF_PREFIX, tiff]));
    if (app1 === undefined) {
      return undefined;
    }
    if (existing !== undefined) {
      return concatBytes([jpeg.slice(0, existing.start), app1, jpeg.slice(existing.end)]);
    }
    return concatBytes([jpeg.slice(0, 2), app1, jpeg.slice(2)]);
  }

  // ---------------------------------------------------------------------
  // Apple 实况照片：MOV 侧（mdta 元数据 + 分片偏移平移）
  // ---------------------------------------------------------------------

  /** 构造 QuickTime `meta`（FullBox，mdta handler）盒，写入资产标识与静态图时间。 */
  private static buildMetaBox(identifier: string): Uint8Array {
    const keyIdentifier = 'com.apple.quicktime.content.identifier';
    const keyStillTime = 'com.apple.quicktime.still-image-time';
    const identifierBytes = utf8Bytes(identifier);
    const identifierKeyBytes = asciiBytes(keyIdentifier);
    const stillTimeKeyBytes = asciiBytes(keyStillTime);

    // keys：size(4) type(4) version+flags(4) entry_count(4)，然后每条 8 + 键名长度。
    const keysLength = 16 + (8 + identifierKeyBytes.length) + (8 + stillTimeKeyBytes.length);
    const keys = new Uint8Array(keysLength);
    writeU32BE(keys, 0, keysLength);
    keys[4] = 0x6b; keys[5] = 0x65; keys[6] = 0x79; keys[7] = 0x73; // 'keys'
    writeU32BE(keys, 8, 0); // version + flags
    writeU32BE(keys, 12, 2); // entry_count
    let at = 16;
    writeU32BE(keys, at, 8 + identifierKeyBytes.length);
    keys.set(asciiBytes('mdta'), at + 4);
    keys.set(identifierKeyBytes, at + 8);
    at += 8 + identifierKeyBytes.length;
    writeU32BE(keys, at, 8 + stillTimeKeyBytes.length);
    keys.set(asciiBytes('mdta'), at + 4);
    keys.set(stillTimeKeyBytes, at + 8);

    // ilst：两个 item（item 类型 = key 索引）
    const identifierDataLength = 16 + identifierBytes.length;
    const identifierItemLength = 8 + identifierDataLength;
    const stillItemLength = 8 + 16 + 4;
    const ilstLength = 8 + identifierItemLength + stillItemLength;
    const ilst = new Uint8Array(ilstLength);
    writeU32BE(ilst, 0, ilstLength);
    ilst[4] = 0x69; ilst[5] = 0x6c; ilst[6] = 0x73; ilst[7] = 0x74; // 'ilst'
    let cursor = 8;
    writeU32BE(ilst, cursor, identifierItemLength);
    writeU32BE(ilst, cursor + 4, 1); // key index 1
    writeU32BE(ilst, cursor + 8, identifierDataLength);
    ilst.set(asciiBytes('data'), cursor + 12);
    writeU32BE(ilst, cursor + 16, 1); // UTF-8
    writeU32BE(ilst, cursor + 20, 0); // locale
    ilst.set(identifierBytes, cursor + 24);
    cursor += identifierItemLength;
    writeU32BE(ilst, cursor, stillItemLength);
    writeU32BE(ilst, cursor + 4, 2); // key index 2
    writeU32BE(ilst, cursor + 8, 20);
    ilst.set(asciiBytes('data'), cursor + 12);
    writeU32BE(ilst, cursor + 16, 21); // signed int (BE)
    writeU32BE(ilst, cursor + 20, 0); // locale
    writeU32BE(ilst, cursor + 24, 0); // 静态图时间：0（第 0 秒）

    // hdlr（mdta）：size(4) type(4) version+flags(4) pre_defined(4) handler_type(4) reserved[3](12) name(NUL 结尾)
    const handlerName = asciiBytes('Apple metadata');
    const hdlrLength = 32 + handlerName.length + 1;
    const hdlr = new Uint8Array(hdlrLength);
    writeU32BE(hdlr, 0, hdlrLength);
    hdlr[4] = 0x68; hdlr[5] = 0x64; hdlr[6] = 0x6c; hdlr[7] = 0x72; // 'hdlr'
    writeU32BE(hdlr, 8, 0); // version + flags
    writeU32BE(hdlr, 12, 0); // pre_defined
    hdlr.set(asciiBytes('mdta'), 16);
    hdlr.set(handlerName, 32);

    const metaLength = 8 + 4 + hdlrLength + keysLength + ilstLength;
    const meta = new Uint8Array(metaLength);
    writeU32BE(meta, 0, metaLength);
    meta[4] = 0x6d; meta[5] = 0x65; meta[6] = 0x74; meta[7] = 0x61; // 'meta'
    writeU32BE(meta, 8, 0); // version + flags
    let out = 12;
    meta.set(hdlr, out);
    out += hdlrLength;
    meta.set(keys, out);
    out += keysLength;
    meta.set(ilst, out);
    return meta;
  }

  /** 在 moov 内递归查找 box（深度受限）。用 `Isobmff.readBoxHead` 解析头，兼容 64 位 largesize。 */
  static collectBoxes(bytes: Uint8Array, start: number, end: number, type: string,
    depth: number, found: number[]): void {
    if (depth > 5) {
      return;
    }
    const view: IsobmffView = (offset: number, length: number): Uint8Array =>
      bytes.subarray(offset, offset + length);
    let cursor = start;
    let guard = 0;
    while (cursor + 8 <= end && guard < 64) {
      const box = Isobmff.readBoxHead(view, cursor, end);
      if (box === undefined) {
        return;
      }
      if (box.type === type) {
        found.push(cursor);
      }
      if (box.type === 'trak' || box.type === 'mdia' || box.type === 'minf' || box.type === 'stbl') {
        LivePhotoWriter.collectBoxes(bytes, cursor + 8, box.end, type, depth + 1, found);
      }
      cursor = box.end;
      guard += 1;
    }
  }

  /** 把 moov 内所有 `stco/co64` 的分片偏移整体加 `delta`。 */
  private static shiftChunkOffsets(bytes: Uint8Array, moovStart: number, moovEnd: number, delta: number): number {
    let shifted = 0;
    const stco: number[] = [];
    LivePhotoWriter.collectBoxes(bytes, moovStart + 8, moovEnd, 'stco', 0, stco);
    for (const at of stco) {
      const size = Isobmff.readU32(bytes, at);
      const count = Isobmff.readU32(bytes, at + 12);
      for (let i = 0; i < count; i++) {
        const field = at + 16 + i * 4;
        if (field + 4 > at + size) {
          break;
        }
        writeU32BE(bytes, field, (Isobmff.readU32(bytes, field) + delta) >>> 0);
        shifted += 1;
      }
    }
    const co64: number[] = [];
    LivePhotoWriter.collectBoxes(bytes, moovStart + 8, moovEnd, 'co64', 0, co64);
    for (const at of co64) {
      const size = Isobmff.readU32(bytes, at);
      const count = Isobmff.readU32(bytes, at + 12);
      for (let i = 0; i < count; i++) {
        const field = at + 16 + i * 8;
        if (field + 8 > at + size) {
          break;
        }
        const high = Isobmff.readU32(bytes, field);
        const low = Isobmff.readU32(bytes, field + 4);
        const value = high * 4294967296 + low + delta;
        writeU32BE(bytes, field, Math.floor(value / 4294967296));
        writeU32BE(bytes, field + 4, value % 4294967296);
        shifted += 1;
      }
    }
    return shifted;
  }

  /** 把视频包装成 Apple 实况照片里的 QuickTime 电影（注入 mdta 元数据）。 */
  static injectQuickTimeMetadata(video: Uint8Array, identifier: string): Uint8Array | undefined {
    if (video.length < 16) {
      return undefined;
    }
    const view: IsobmffView = (offset: number, length: number): Uint8Array =>
      video.subarray(offset, offset + length);
    let moovStart = -1;
    let moovEnd = -1;
    let mdatStart = -1;
    let ftypStart = -1;
    let cursor = 0;
    let guard = 0;
    // 用 readBoxHead 解析顶层 box：它能正确处理 64 位 largesize（真实录制文件的 mdat
    // 常见 `size=1` + largesize 的写法，自己按 u32 读会把 mdat 认错，从而漏掉分片偏移平移）。
    while (cursor + 8 <= video.length && guard < 64) {
      const box = Isobmff.readBoxHead(view, cursor, video.length);
      if (box === undefined) {
        break;
      }
      if (box.type === 'moov') {
        moovStart = box.start;
        moovEnd = box.end;
      } else if (box.type === 'mdat') {
        mdatStart = box.start;
      } else if (box.type === 'ftyp') {
        ftypStart = box.start;
      }
      cursor = box.end;
      guard += 1;
    }
    if (moovStart < 0) {
      return undefined;
    }
    const meta = LivePhotoWriter.buildMetaBox(identifier);
    // 插入点：优先放在 moov 的**第一个子 box（mvhd）之后**，而不是 moov 末尾。
    // 真实手机录制的 MP4 往往已经带一个 `moov/meta`（iTunes / Android 元数据），而读取方
    // （QuickTime 与 Apple 照片、也包括本工程的解析器）通常取**第一个** meta ——
    // 放末尾等于把刚写进去的标识藏起来（实测 OPPO 视频就同时有 moov/meta 与我们的 meta）。
    // 放在 mvhd 之后还能保住「mvhd 是 moov 第一个子 box」的惯例。
    let insertAt = moovStart + 8;
    const firstChild = Isobmff.readBoxHead(view, moovStart + 8, moovEnd);
    if (firstChild !== undefined && firstChild.type === 'mvhd') {
      insertAt = firstChild.end;
    }
    const out = concatBytes([video.slice(0, insertAt), meta, video.slice(insertAt)]);
    // moov 变长：插入点之后（典型是 mdat）的分片偏移必须整体平移，否则视频会花屏。
    if (mdatStart >= insertAt) {
      LivePhotoWriter.shiftChunkOffsets(out, moovStart, moovEnd + meta.length, meta.length);
    }
    writeU32BE(out, moovStart, Isobmff.readU32(video, moovStart) + meta.length);
    // 品牌改成 QuickTime：iOS「照片」按 QuickTime 电影处理实况照片的视频部分。
    if (ftypStart >= 0) {
      out[ftypStart + 8] = 0x71; // 'q'
      out[ftypStart + 9] = 0x74; // 't'
      out[ftypStart + 10] = 0x20;
      out[ftypStart + 11] = 0x20;
    }
    return out;
  }

  /** 写出 Apple 实况照片（同名成对：图片带 EXIF 标识，视频带 mdta 标识）。 */
  static writeAppleLivePhoto(jpeg: Uint8Array, video: Uint8Array, identifier: string): AppleLivePhotoResult | undefined {
    const image = LivePhotoWriter.writeAppleExifIdentifier(jpeg, identifier);
    if (image === undefined) {
      return undefined;
    }
    const movie = LivePhotoWriter.injectQuickTimeMetadata(video, identifier);
    if (movie === undefined) {
      return undefined;
    }
    return { image: image, video: movie, identifier: identifier };
  }
}
