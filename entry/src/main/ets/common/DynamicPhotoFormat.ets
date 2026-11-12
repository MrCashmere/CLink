/**
 * 动态图片格式探测与解析（纯字节层，无任何 UI / 文件系统依赖，便于单测）。
 *
 * 「动态图片」在不同生态里是不同的容器封装：
 *
 *  - 鸿蒙动态照片：系统相册里是「图片 + 视频」的资产对（见 photoAccessHelper
 *    PhotoSubtype.MOVING_PHOTO）；从系统分享 / 文件管理导出的常见形态是
 *    `.livp`（一个 ZIP，内部含一张 JPEG 与一段 MP4）。
 *  - Google Motion Photo（Pixel / 部分 Android）：单文件 JPEG/HEIC，视频以
 *    XMP 包头 `http://ns.google.com/photos/1.0/camera/`（旧版 `MicroVideoOffset`，
 *    从文件末尾计数）或 `http://ns.google.com/photos/1.0/container/`
 *    （`Container:Directory` + `Item:Length`，按段长顺序拼接）描述。
 *  - 三星 Motion Photo：JPEG 末尾追加 MP4，再追加 `SEFH`/`SEFT` trailer；
 *    XMP 里带 `MotionPhoto=1` / `MotionPhotoVersion` /
 *    `MotionPhotoPresentationTimestampUs`。
 *  - Apple Live Photo：图片 + `.MOV` 两个文件，通过
 *    `com.apple.quicktime.content.identifier`（MOV）与图片 EXIF MakerNote 里的
 *    ContentIdentifier 配对。
 *  - 小米 / OPPO / vivo / 荣耀等国产机型：多数沿用 Google 那套
 *    「JPEG + XMP + 末尾追加 MP4」的封装（Namespace 可能换成自家或
 *    `http://ns.adobe.com/xap/1.0/` 下的自定义字段），少数厂商使用独立容器。
 *
 * 本模块只负责「识别 + 定位其中图片段与视频段的字节范围」，不负责解码、
 * 不依赖任何猜测性的私有魔数以外的格式。
 */

import { util } from '@kit.ArkTS';
import { Isobmff, HeifMetaData, IsobmffView, QuickTimeMetadata } from './Isobmff';

const textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8');

/** head/tail 两段缓冲拼出的稀疏视图持有者（避免在 ArkTS 里到处传闭包）。 */
export interface IsobmffViewClosure {
  readonly head: Uint8Array;
  readonly headStart: number;
  readonly tail: Uint8Array;
  readonly tailStart: number;
  /** 读取文件 [offset, offset+length) 的字节。 */
  read: (offset: number, length: number) => Uint8Array;
}

/** 一个文件已读入的头部与尾部缓冲（供 Isobmff / EXIF / MOV 解析复用）。 */
export interface DynamicPhotoBytes {
  readonly holder: IsobmffViewClosure;
  readonly fileSize: number;
  readonly head: Uint8Array;
  readonly tail: Uint8Array;
  readonly tailStart: number;
}

/** 动态图片（实况照片）的生态/封装类型。 */
export type DynamicPhotoKind =  | 'none'
  | 'harmony-livp'
  | 'google-motion'
  | 'samsung-motion'
  | 'vendor-motion'
  | 'apple-live';

/** 图片段本身的编码格式。 */
export type DynamicPhotoImageFormat = 'unknown' | 'jpeg' | 'heic' | 'png' | 'webp' | 'avif';

/** 探测结果：图片段 / 视频段在原始文件中的字节范围。 */
export interface DynamicPhotoProbe {
  readonly kind: DynamicPhotoKind;
  readonly imageFormat: DynamicPhotoImageFormat;
  /** 图片段在文件内的起始偏移（JPEG 通常为 0）。 */
  readonly imageOffset: number;
  /** 图片段字节长度；未知为 -1。 */
  readonly imageLength: number;
  /** 视频段在文件内的起始偏移；无内嵌视频为 -1。 */
  readonly videoOffset: number;
  /** 视频段字节长度；未知为 -1。 */
  readonly videoLength: number;
  /** 图片段建议扩展名（不含点），例如 'jpg' / 'heic'。 */
  readonly imageExtension: string;
  /** 视频段建议扩展名（不含点），通常为 'mp4'；无视频为空串。 */
  readonly videoExtension: string;
  /** 用于日志/UI 的厂商标识，例如 'HarmonyOS' / 'Google' / 'Samsung' / 'Apple'。 */
  readonly vendor: string;
}

function emptyProbe(kind: DynamicPhotoKind, vendor: string): DynamicPhotoProbe {
  return {
    kind: kind,
    imageFormat: 'unknown',
    imageOffset: 0,
    imageLength: -1,
    videoOffset: -1,
    videoLength: -1,
    imageExtension: '',
    videoExtension: '',
    vendor: vendor
  };
}

/**
 * XMP `Container:Directory` 里的一个条目（CIPA DC-007 / Google Motion Photo 容器描述）。
 * 目录只声明各段的长度与 padding，不声明偏移：各段按目录顺序从文件偏移 0 起紧密排布。
 */
export interface XmpContainerItem {
  /** `Item:Mime`，例如 `image/jpeg` / `video/mp4`。 */
  readonly mime: string;
  /** `Item:Semantic`，例如 `Primary` / `GainMap` / `MotionPhoto`。 */
  readonly semantic: string;
  /** `Item:Length`；**<=0 表示该段长度未声明**（规范里 Primary 段常写 0，表示「占满到下一段之前」）。 */
  readonly length: number;
  /** `Item:Padding`，紧随该段之后的填充字节数；未声明为 0。 */
  readonly padding: number;
}

/** 从文件尾部再读取一些字节用于探测（尾部 trailer 很小，默认 256KB 足够）。 */
export function dynamicPhotoTailLength(size: number): number {
  const TAIL = 256 * 1024;
  return size < TAIL ? size : TAIL;
}

export class DynamicPhotoFormat {
  /** 判据用的字节签名。 */
  private static readonly MP4_SIGNATURE: Uint8Array = new Uint8Array([0x66, 0x74, 0x79, 0x70]); // 'ftyp'
  private static readonly QUICKTIME_SIGNATURE: Uint8Array = new Uint8Array([0x71, 0x74, 0x20, 0x20]); // 'qt  '
  private static readonly ZIP_LOCAL_SIGNATURE: Uint8Array = new Uint8Array([0x50, 0x4b, 0x03, 0x04]); // 'PK\u0003\u0004'
  private static readonly UTF8_XMP_HINT: Uint8Array = new Uint8Array([
    0x78, 0x6d, 0x70, 0x6d, 0x65, 0x74, 0x61 // 'xmpmeta'
  ]);
  private static readonly UTF8_GOOGLE_CAMERA: Uint8Array = new Uint8Array([
    0x47, 0x43, 0x61, 0x6d, 0x65, 0x72, 0x61 // 'GCamera'
  ]);
  private static readonly UTF8_GOOGLE_CONTAINER: Uint8Array = new Uint8Array([
    0x43, 0x6f, 0x6e, 0x74, 0x61, 0x69, 0x6e, 0x65, 0x72, 0x3a, 0x44, 0x69, 0x72, 0x65, 0x63, 0x74, 0x6f, 0x72, 0x79
  ]); // 'Container:Directory'
  private static readonly UTF8_MOTION_PHOTO: Uint8Array = new Uint8Array([
    0x4d, 0x6f, 0x74, 0x69, 0x6f, 0x6e, 0x50, 0x68, 0x6f, 0x74, 0x6f
  ]); // 'MotionPhoto'
  private static readonly UTF8_APPLE_ID: Uint8Array = new Uint8Array([
    0x63, 0x6f, 0x6d, 0x2e, 0x61, 0x70, 0x70, 0x6c, 0x65, 0x2e, 0x71, 0x75, 0x69, 0x63, 0x6b, 0x74, 0x69, 0x6d,
    0x65, 0x2e, 0x63, 0x6f, 0x6e, 0x74, 0x65, 0x6e, 0x74, 0x2e, 0x69, 0x64, 0x65, 0x6e, 0x74, 0x69, 0x66, 0x69,
    0x65, 0x72
  ]); // 'com.apple.quicktime.content.identifier'
  private static readonly UTF8_SEFH: Uint8Array = new Uint8Array([0x53, 0x45, 0x46, 0x48]); // 'SEFH'
  private static readonly ZIP_EOCD: Uint8Array = new Uint8Array([0x50, 0x4b, 0x05, 0x06]); // 'PK\u0005\u0006'
  /**
   * ftyp 容差搜索的最大半径：XMP 声明的偏移有偏差（相机改写图片段/尾部被追加字节）时，
   * 以声明值为锚点向外找最近的合法 ftyp；上限用于避免在大文件上退化成全文件扫描。
   */
  private static readonly FTYP_SEARCH_WINDOW: number = 2 * 1024 * 1024;

  // ---------------------------------------------------------------------
  // 基础检索工具
  // ---------------------------------------------------------------------

  /** 在 bytes[from, min(to, len)) 中查找 needle，返回首次出现的下标，找不到返回 -1。 */
  static indexOf(bytes: Uint8Array, needle: Uint8Array, from: number = 0, to: number = -1): number {
    const limit = to < 0 || to > bytes.length ? bytes.length : to;
    const last = limit - needle.length;
    if (needle.length === 0 || last < from) {
      return -1;
    }
    const first = needle[0];
    for (let i = from < 0 ? 0 : from; i <= last; i++) {
      if (bytes[i] !== first) {
        continue;
      }
      let matched = true;
      for (let j = 1; j < needle.length; j++) {
        if (bytes[i + j] !== needle[j]) {
          matched = false;
          break;
        }
      }
      if (matched) {
        return i;
      }
    }
    return -1;
  }

  static readU16BE(bytes: Uint8Array, offset: number): number {
    return ((bytes[offset] << 8) | bytes[offset + 1]) & 0xffff;
  }

  static readU32BE(bytes: Uint8Array, offset: number): number {
    return ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0;
  }

  static readU16LE(bytes: Uint8Array, offset: number): number {
    return (bytes[offset] | (bytes[offset + 1] << 8)) & 0xffff;
  }

  static readU32LE(bytes: Uint8Array, offset: number): number {
    return (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;
  }

  private static readU64LE(bytes: Uint8Array, offset: number): number {
    const low = DynamicPhotoFormat.readU32LE(bytes, offset);
    const high = DynamicPhotoFormat.readU32LE(bytes, offset + 4);
    // 动态照片不会超过 2^53，直接按 double 组合即可。
    return high * 4294967296 + low;
  }

  private static asciiAt(bytes: Uint8Array, offset: number, text: string): boolean {
    if (offset < 0 || offset + text.length > bytes.length) {
      return false;
    }
    for (let i = 0; i < text.length; i++) {
      if (bytes[offset + i] !== text.charCodeAt(i)) {
        return false;
      }
    }
    return true;
  }

  /** 截取字节区间（越界自动收敛）。 */
  static slice(bytes: Uint8Array, from: number, to: number): Uint8Array {
    const start = from < 0 ? 0 : (from > bytes.length ? bytes.length : from);
    const end = to > bytes.length ? bytes.length : (to < start ? start : to);
    return bytes.slice(start, end);
  }

  /** 解码一段字节为 UTF-8 文本（非法字节由 TextDecoder 替换，不抛异常）。 */
  static decodeUtf8(bytes: Uint8Array): string {
    try {
      return textDecoder.decodeToString(bytes);
    } catch (error) {
      let text = '';
      for (let i = 0; i < bytes.length; i++) {
        text += String.fromCharCode(bytes[i]);
      }
      return text;
    }
  }

  /** 扩展名小写化（不含点）。 */
  static extensionOf(name: string): string {
    const slash = name.lastIndexOf('/');
    const base = slash >= 0 ? name.substring(slash + 1) : name;
    const query = base.indexOf('?');
    const clean = query >= 0 ? base.substring(0, query) : base;
    const dot = clean.lastIndexOf('.');
    if (dot < 0 || dot === clean.length - 1) {
      return '';
    }
    return clean.substring(dot + 1).toLowerCase();
  }

  /** 不含扩展名的文件名（含目录），用于「同名图片 + 视频」配对判定。 */
  static baseNameOf(name: string): string {
    const slash = name.lastIndexOf('/');
    const base = slash >= 0 ? name.substring(slash + 1) : name;
    const dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }

  /** 该扩展名是否可能是「动态图片的图片段」。 */
  static isImageExtension(extension: string): boolean {
    return extension === 'jpg' || extension === 'jpeg' || extension === 'jpe' || extension === 'heic'
      || extension === 'heif' || extension === 'hif' || extension === 'livp' || extension === 'png'
      || extension === 'webp' || extension === 'avif';
  }

  /** 该扩展名是否可能是「动态图片的视频段」。 */
  static isVideoExtension(extension: string): boolean {
    return extension === 'mp4' || extension === 'mov' || extension === 'm4v' || extension === 'qt';
  }

  // ---------------------------------------------------------------------
  // 图片格式识别
  // ---------------------------------------------------------------------

  static sniffImageFormat(head: Uint8Array): DynamicPhotoImageFormat {
    if (head.length >= 3 && head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) {
      return 'jpeg';
    }
    if (head.length >= 12 && DynamicPhotoFormat.asciiAt(head, 4, 'ftyp')) {
      const brand = DynamicPhotoFormat.decodeUtf8(DynamicPhotoFormat.slice(head, 8, 12));
      if (brand.indexOf('avif') >= 0) {
        return 'avif';
      }
      if (brand.indexOf('heic') >= 0 || brand.indexOf('heix') >= 0 || brand.indexOf('hevc') >= 0
        || brand.indexOf('hevx') >= 0 || brand.indexOf('mif1') >= 0 || brand.indexOf('msf1') >= 0
        || brand.indexOf('heim') >= 0 || brand.indexOf('heis') >= 0 || brand.indexOf('hevm') >= 0
        || brand.indexOf('hevs') >= 0) {
        return 'heic';
      }
      return 'heic';
    }
    if (head.length >= 8 && head[0] === 0x89 && head[1] === 0x50 && head[2] === 0x4e && head[3] === 0x47) {
      return 'png';
    }
    if (head.length >= 12 && DynamicPhotoFormat.asciiAt(head, 0, 'RIFF')
      && DynamicPhotoFormat.asciiAt(head, 8, 'WEBP')) {
      return 'webp';
    }
    return 'unknown';
  }

  static imageExtensionFor(format: DynamicPhotoImageFormat, fallbackExtension: string): string {
    switch (format) {
      case 'jpeg':
        return fallbackExtension === 'jpeg' || fallbackExtension === 'jpe' ? fallbackExtension : 'jpg';
      case 'heic':
        return fallbackExtension === 'heif' || fallbackExtension === 'hif' ? fallbackExtension : 'heic';
      case 'png':
        return 'png';
      case 'webp':
        return 'webp';
      case 'avif':
        return 'avif';
      default:
        return fallbackExtension.length > 0 ? fallbackExtension : 'bin';
    }
  }

  /** 传入整个文件头（≥32 字节足够）即可得到最基本的格式判定。 */
  static isDynamicPhotoContainer(head: Uint8Array, extension: string): boolean {
    if (extension === 'livp') {
      return true;
    }
    return head.length >= 4 && head[0] === 0x50 && head[1] === 0x4b && head[2] === 0x03 && head[3] === 0x04;
  }

  // ---------------------------------------------------------------------
  // XMP / 动图标记提取
  // ---------------------------------------------------------------------

  /**
   * 扫描 JPEG 的 APP 段，返回 APP1 中的 XMP 文本（找不到返回空串）。
   * 只解析 marker 结构，不做完整 JPEG 解码。
   *
   * 注意：必须在 EOI(0xFFD9) 处停止。动态图片的 JPEG 段后面直接跟着 MP4 视频，
   * 若继续按 marker 结构往后走，视频数据里的 0xFF 字节会把解析器带偏，
   * 得到错误的段边界并丢掉 XMP。
   */
  static extractJpegXmp(head: Uint8Array): string {
    if (head.length < 4 || head[0] !== 0xff || head[1] !== 0xd8) {
      return '';
    }
    let offset = 2;
    while (offset + 4 <= head.length) {
      if (head[offset] !== 0xff) {
        // 允许填充字节 0xFF
        offset += 1;
        continue;
      }
      let marker = head[offset + 1];
      while (marker === 0xff && offset + 2 < head.length) {
        offset += 1;
        marker = head[offset + 1];
      }
      if (marker === 0xd8 || (marker >= 0xd0 && marker <= 0xd7) || marker === 0x01) {
        offset += 2;
        continue;
      }
      // SOS / EOI：图像数据开始，元数据段到此为止。
      if (marker === 0xda || marker === 0xd9) {
        return '';
      }
      if (offset + 4 > head.length) {
        return '';
      }
      const length = DynamicPhotoFormat.readU16BE(head, offset + 2);
      if (length < 2 || offset + 2 + length > head.length) {
        return '';
      }
      const payloadStart = offset + 4;
      const payloadEnd = offset + 2 + length;
      if (marker === 0xe1) {
        const payload = DynamicPhotoFormat.slice(head, payloadStart, payloadEnd);
        if (DynamicPhotoFormat.indexOf(payload, DynamicPhotoFormat.UTF8_XMP_HINT, 0) >= 0) {
          const prefixLength = DynamicPhotoFormat.indexOf(payload, DynamicPhotoFormat.UTF8_XMP_HINT, 0);
          return DynamicPhotoFormat.decodeUtf8(DynamicPhotoFormat.slice(payload, prefixLength, payload.length));
        }
      }
      offset = payloadEnd;
    }
    return '';
  }

  /**
   * 从整份字节（或文件尾部若干字节）里取出 XMP 文本：
   * 优先走 JPEG APP1 段；HEIC / 其它容器退化为全文件扫描 'xmpmeta' 标记。
   */
  static findXmpText(bytes: Uint8Array, isJpeg: boolean): string {
    if (isJpeg) {
      const fromSegments = DynamicPhotoFormat.extractJpegXmp(bytes);
      if (fromSegments.length > 0) {
        return fromSegments;
      }
    }
    const at = DynamicPhotoFormat.indexOf(bytes, DynamicPhotoFormat.UTF8_XMP_HINT, 0);
    if (at < 0) {
      return '';
    }
    // XMP 包以 </x:xmpmeta> 结束，向后截一段即可（避免把后续二进制也当文本）。
    const endMarker = DynamicPhotoFormat.indexOf(bytes, new Uint8Array([0x3c, 0x2f, 0x78, 0x3a, 0x78, 0x6d, 0x70, 0x6d, 0x65, 0x74, 0x61, 0x3e]), at);
    const end = endMarker >= 0 ? endMarker + 12 : Math.min(at + 65536, bytes.length);
    return DynamicPhotoFormat.decodeUtf8(DynamicPhotoFormat.slice(bytes, at, end));
  }

  private static xmpNumber(xmp: string, keys: string[]): number {
    for (const key of keys) {
      const at = xmp.indexOf(key);
      if (at < 0) {
        continue;
      }
      let i = at + key.length;
      while (i < xmp.length && (xmp.charAt(i) === '"' || xmp.charAt(i) === '=' || xmp.charAt(i) === ' '
        || xmp.charAt(i) === ':' || xmp.charAt(i) === '\'')) {
        i += 1;
      }
      let text = '';
      while (i < xmp.length) {
        const ch = xmp.charAt(i);
        if (ch >= '0' && ch <= '9') {
          text += ch;
        } else {
          break;
        }
        i += 1;
      }
      if (text.length > 0) {
        const value = Number.parseInt(text, 10);
        if (!Number.isNaN(value)) {
          return value;
        }
      }
    }
    return -1;
  }

  /** 纯 ASCII 字符串转字节（XMP 检索用；非 ASCII 折叠为 '?'）。 */
  static encodeAscii(text: string): Uint8Array {
    const bytes = new Uint8Array(text.length);
    for (let i = 0; i < text.length; i++) {
      const code = text.charCodeAt(i);
      bytes[i] = code > 0xff ? 0x3f : code;
    }
    return bytes;
  }

  /** XMP 是否声明这是一张动态图片（各厂商字段名汇总）。 */
  static xmpDeclaresMotionPhoto(xmp: string): boolean {
    if (xmp.length === 0) {
      return false;
    }
    const ascii = DynamicPhotoFormat.encodeAscii(xmp);
    // 'MotionPhoto' 会同时命中 'MotionPhotoVersion' / 'MotionPhotoPresentationTimestampUs'，同属一类标记。
    if (DynamicPhotoFormat.indexOf(ascii, DynamicPhotoFormat.UTF8_MOTION_PHOTO, 0) >= 0) {
      return true;
    }
    if (DynamicPhotoFormat.indexOf(ascii, DynamicPhotoFormat.UTF8_GOOGLE_CAMERA, 0) >= 0) {
      return true;
    }
    return false;
  }

  /**
   * 解析 XMP 中的视频段描述，返回 [offsetFromEnd, length] 或 undefined。
   *  - 旧版 Google MicroVideo：`MicroVideoOffset` 表示「从文件末尾倒数」的偏移。
   *  - 新版 Google Container：`Item:Length`（Primary 之后的那一段）即视频长度。
   *  - 三星：`MotionPhotoVersion` 配合尾部 SEF trailer（另有专门路径）。
   */
  static parseXmpVideoHint(xmp: string): DynamicPhotoVideoHint | undefined {
    if (xmp.length === 0) {
      return undefined;
    }
    const ascii = DynamicPhotoFormat.encodeAscii(xmp);
    const microVideoOffset = DynamicPhotoFormat.xmpNumber(xmp, ['GCamera:MicroVideoOffset', 'MicroVideoOffset']);
    if (microVideoOffset > 0) {
      return {
        offsetFromEnd: microVideoOffset,
        length: microVideoOffset,
        source: 'microvideo-offset',
        itemLengths: [],
        itemPaddings: [],
        items: []
      };
    }
    const directoryAt = DynamicPhotoFormat.indexOf(ascii, DynamicPhotoFormat.UTF8_GOOGLE_CONTAINER, 0);
    if (directoryAt >= 0) {
      // XMP 的 Container 目录只给出每段的长度与 padding，不含偏移：
      // 各段按目录顺序从文件偏移 0 起紧密排布，第 N 段的起始 = 前面所有段的
      // (Length + Padding) 之和。这里把逐段信息完整带出去，由调用方算偏移。
      const items = DynamicPhotoFormat.parseXmpContainerItems(xmp);
      if (items.length >= 1) {
        const lengths: number[] = [];
        const paddings: number[] = [];
        for (const item of items) {
          lengths.push(item.length > 0 ? item.length : 0);
          paddings.push(item.padding > 0 ? item.padding : 0);
        }
        return {
          offsetFromEnd: -1,
          length: -1,
          source: 'container-directory',
          itemLengths: lengths,
          itemPaddings: paddings,
          items: items
        };
      }
    }
    return undefined;
  }

  /**
   * 解析 `Container:Directory` 里的条目列表（顺序即字节顺序）。
   *
   * 每个条目是一段 `<Container:Item ... />`，属性顺序各厂商不一致，因此按「相邻两个
   * Container:Item 之间」切块后逐块取属性。
   */
  static parseXmpContainerItems(xmp: string): XmpContainerItem[] {
    const items: XmpContainerItem[] = [];
    if (xmp.length === 0) {
      return items;
    }
    const marker = 'Container:Item';
    let from = 0;
    while (items.length < 8) {
      const at = xmp.indexOf(marker, from);
      if (at < 0) {
        break;
      }
      const next = xmp.indexOf(marker, at + marker.length);
      const block = next < 0 ? xmp.substring(at) : xmp.substring(at, next);
      const length = DynamicPhotoFormat.xmpNumber(block, ['Item:Length']);
      const padding = DynamicPhotoFormat.xmpNumber(block, ['Item:Padding']);
      items.push({
        mime: DynamicPhotoFormat.xmpString(block, 'Item:Mime'),
        semantic: DynamicPhotoFormat.xmpString(block, 'Item:Semantic'),
        length: length > 0 ? length : 0,
        padding: padding > 0 ? padding : 0
      });
      if (next < 0) {
        break;
      }
      from = next;
    }
    return items;
  }

  /** 读取 XMP 属性 `key="value"` 的值；缺失返回空串。 */
  private static xmpString(xmp: string, key: string): string {
    const at = xmp.indexOf(key);
    if (at < 0) {
      return '';
    }
    let i = at + key.length;
    while (i < xmp.length && (xmp.charAt(i) === ' ' || xmp.charAt(i) === '=')) {
      i += 1;
    }
    if (i >= xmp.length) {
      return '';
    }
    const quote = xmp.charAt(i);
    if (quote !== '"' && quote !== '\'') {
      return '';
    }
    const start = i + 1;
    const end = xmp.indexOf(quote, start);
    return end < 0 ? '' : xmp.substring(start, end);
  }

  /** 该目录条目是否是「视频段」。 */
  static isVideoContainerItem(item: XmpContainerItem): boolean {
    const mime = item.mime.toLowerCase();
    if (mime.startsWith('video/')) {
      return true;
    }
    const semantic = item.semantic.toLowerCase();
    return semantic === 'motionphoto' || semantic === 'motionphotovideo' || semantic === 'video';
  }

  static allXmpNumbers(xmp: string, key: string): number[] {
    const values: number[] = [];
    let from = 0;
    while (from < xmp.length) {
      const at = xmp.indexOf(key, from);
      if (at < 0) {
        break;
      }
      let i = at + key.length;
      while (i < xmp.length && (xmp.charAt(i) === '"' || xmp.charAt(i) === '=' || xmp.charAt(i) === ' '
        || xmp.charAt(i) === ':' || xmp.charAt(i) === '\'')) {
        i += 1;
      }
      let text = '';
      while (i < xmp.length) {
        const ch = xmp.charAt(i);
        if (ch >= '0' && ch <= '9') {
          text += ch;
        } else {
          break;
        }
        i += 1;
      }
      if (text.length > 0) {
        const value = Number.parseInt(text, 10);
        if (!Number.isNaN(value)) {
          values.push(value);
        }
      }
      from = at + key.length;
    }
    return values;
  }

  /**
   * 从尾部 trailer 里定位三星 SEF 段。
   * 三星会在 MP4 之后追加 `SEFH`(header) + … + `SEFT`(footer)；
   * trailer 末尾 4 字节是大端表示的 trailer 长度（含自身）。
   */
  static parseSamsungTrailer(tail: Uint8Array, tailStart: number, fileSize: number): DynamicPhotoVideoHint | undefined {
    const seftAt = DynamicPhotoFormat.indexOf(tail, DynamicPhotoFormat.UTF8_SEFH, 0);
    if (seftAt < 0) {
      return undefined;
    }
    // SEFH 段起始即视频段的结束位置；SEFH 之前应紧邻视频尾部。
    // 三星 trailer 中 SEFH 的 payload 里也记录了视频偏移，但各机型存在差异，
    // 因此这里采用结构性判据：在 SEFH 之前向后回溯查找最近的合法 ftyp。
    // 注意：三星也会给「没有视频的普通照片」追加 SEF trailer，所以调用方必须用
    // ftyp 校验通过后才算动态图片（见 probe）。
    return {
      offsetFromEnd: fileSize - (tailStart + seftAt),
      length: -1,
      source: 'samsung-sef',
      itemLengths: [],
      itemPaddings: [],
      items: []
    };
  }

  /** 给定「视频起始绝对偏移」生成探测结果。 */
  static probeWithVideo(
    kind: DynamicPhotoKind,
    vendor: string,
    imageFormat: DynamicPhotoImageFormat,
    imageOffset: number,
    imageLength: number,
    videoOffset: number,
    videoLength: number,
    fallbackImageExtension: string
  ): DynamicPhotoProbe {
    return {
      kind: kind,
      imageFormat: imageFormat,
      imageOffset: imageOffset,
      imageLength: imageLength,
      videoOffset: videoOffset,
      videoLength: videoLength,
      imageExtension: DynamicPhotoFormat.imageExtensionFor(imageFormat, fallbackImageExtension),
      videoExtension: videoLength > 0 ? 'mp4' : '',
      vendor: vendor
    };
  }

  // ---------------------------------------------------------------------
  // livp（ZIP 容器）解析
  // ---------------------------------------------------------------------

  /**
   * 扫描 `fileSize` 大小文件的尾部缓冲区，解析 ZIP 中央目录。
   * 返回各个被引用到的字节区间（{offset, length}），调用方据此精确读取所需区域。
   */
  static listZipEntries(tail: Uint8Array, tailStart: number, fileSize: number): ZipEntryInfo[] {
    const entries: ZipEntryInfo[] = [];
    const eocdAt = DynamicPhotoFormat.indexOf(tail, DynamicPhotoFormat.ZIP_EOCD, 0);
    if (eocdAt < 0 || eocdAt + 22 > tail.length) {
      return entries;
    }
    const entryCount = DynamicPhotoFormat.readU16LE(tail, eocdAt + 10);
    const centralOffset = DynamicPhotoFormat.readU32LE(tail, eocdAt + 16);
    const absolute = centralOffset - tailStart;
    if (absolute < 0 || absolute >= tail.length) {
      return entries;
    }
    let cursor = absolute;
    let scanned = 0;
    while (cursor + 46 <= tail.length && scanned < 64 && scanned < entryCount + 8) {
      if (!DynamicPhotoFormat.asciiAt(tail, cursor, 'PK\u0001\u0002')) {
        break;
      }
      const method = DynamicPhotoFormat.readU16LE(tail, cursor + 10);
      const compressedSize = DynamicPhotoFormat.readU32LE(tail, cursor + 20);
      const uncompressedSize = DynamicPhotoFormat.readU32LE(tail, cursor + 24);
      const nameLength = DynamicPhotoFormat.readU16LE(tail, cursor + 28);
      const extraLength = DynamicPhotoFormat.readU16LE(tail, cursor + 30);
      const commentLength = DynamicPhotoFormat.readU16LE(tail, cursor + 32);
      const localOffset = DynamicPhotoFormat.readU32LE(tail, cursor + 42);
      const nameStart = cursor + 46;
      if (nameStart + nameLength > tail.length) {
        break;
      }
      const name = DynamicPhotoFormat.decodeUtf8(DynamicPhotoFormat.slice(tail, nameStart, nameStart + nameLength));
      entries.push({
        name: name,
        method: method,
        compressedSize: compressedSize,
        uncompressedSize: uncompressedSize,
        localHeaderOffset: localOffset
      });
      cursor = nameStart + nameLength + extraLength + commentLength;
      scanned += 1;
    }
    return entries;
  }

  /** 解析 ZIP 本地文件头，返回数据段（可能是压缩数据）在文件中的绝对偏移。 */
  static zipDataOffset(head: Uint8Array, headStart: number, localHeaderOffset: number): number {
    const local = localHeaderOffset - headStart;
    if (local < 0 || local + 30 > head.length) {
      return -1;
    }
    if (!DynamicPhotoFormat.asciiAt(head, local, 'PK\u0003\u0004')) {
      return -1;
    }
    const nameLength = DynamicPhotoFormat.readU16LE(head, local + 26);
    const extraLength = DynamicPhotoFormat.readU16LE(head, local + 28);
    return localHeaderOffset + 30 + nameLength + extraLength;
  }

  /**
   * 在 ZIP 条目里选出「图片条目」或「视频条目」。
   * livp 内部条目名各机型不一致（可能是 `image.jpg`/`video.mp4`，也可能是
   * 相机原始名 `IMG_0001.JPG`/`IMG_0001.MP4`），因此按扩展名判定而不是按名字。
   */
  static findZipEntryByExtension(entries: ZipEntryInfo[], wantImage: boolean): ZipEntryInfo | undefined {
    let best: ZipEntryInfo | undefined = undefined;
    for (const entry of entries) {
      const name = entry.name;
      // 目录条目以 '/' 结尾，跳过。
      if (name.length === 0 || name.endsWith('/')) {
        continue;
      }
      const extension = DynamicPhotoFormat.extensionOf(name);
      if (!wantImage) {
        if (extension === 'mp4' || extension === 'mov' || extension === 'm4v') {
          if (best === undefined || extension === 'mp4') {
            best = entry;
          }
        }
        continue;
      }
      if (DynamicPhotoFormat.isImageExtension(extension) && extension !== 'livp') {
        if (best === undefined || extension === 'jpg' || extension === 'jpeg' || extension === 'heic') {
          best = entry;
        }
      }
    }
    return best;
  }

  /** 去掉拆分配对标记（结尾的 `.dp`）后的 basename，用于图片/视频配对判定。 */
  static stripPairMarker(name: string): string {
    return name.toLowerCase().endsWith('.dp') ? name.substring(0, name.length - 3) : name;
  }

  /** 该 MP4/QuickTime 字节流里是否带 Apple Live Photo 的内容标识符。 */
  static movHasAppleContentIdentifier(videoBytes: Uint8Array): boolean {
    return DynamicPhotoFormat.indexOf(videoBytes, DynamicPhotoFormat.UTF8_APPLE_ID, 0) >= 0;
  }

  /** 从 ISO-BMFF（MOV/MP4）里提取 Apple 内容标识符（UUID 文本形式）。 */
  static extractAppleContentIdentifier(videoBytes: Uint8Array): string {
    const at = DynamicPhotoFormat.indexOf(videoBytes, DynamicPhotoFormat.UTF8_APPLE_ID, 0);
    if (at < 0) {
      return '';
    }
    // 标识符值是一个带连字符的 UUID 文本。key 之后紧跟 `data` box（size + type + locale），
    // 因此不能简单地「从 key 末尾按可打印字符连读」—— 实测会把 size='0'、'data'、type、locale
    // 一起拼进来。改为按「8-4-4-4-12 的分组形状」在 key 之后寻找第一个匹配的文本。
    const searchFrom = at + DynamicPhotoFormat.UTF8_APPLE_ID.length;
    const groups = [8, 4, 4, 4, 12];
    for (let i = searchFrom; i < videoBytes.length; i++) {
      if (!DynamicPhotoFormat.isHexByte(videoBytes[i])) {
        continue;
      }
      let cursor = i;
      let text = '';
      let matched = true;
      for (let g = 0; g < groups.length && matched; g++) {
        if (g > 0) {
          if (cursor >= videoBytes.length || videoBytes[cursor] !== 0x2d) {
            matched = false;
            break;
          }
          text += '-';
          cursor += 1;
        }
        for (let k = 0; k < groups[g]; k++) {
          if (cursor >= videoBytes.length || !DynamicPhotoFormat.isHexByte(videoBytes[cursor])) {
            matched = false;
            break;
          }
          text += String.fromCharCode(videoBytes[cursor]);
          cursor += 1;
        }
      }
      if (matched && text.length === 36) {
        return text;
      }
    }
    return '';
  }

  private static isHexByte(ch: number): boolean {
    return (ch >= 0x30 && ch <= 0x39) || (ch >= 0x41 && ch <= 0x46) || (ch >= 0x61 && ch <= 0x66);
  }

  // ---------------------------------------------------------------------
  // HEIC / HEIF 路径
  // ---------------------------------------------------------------------

  /**
   * 用 head/tail 两个缓冲拼一个「稀疏视图」给 Isobmff 用：box 结构在头部，
   * 而 iloc 指向的 XMP/Exif/视频数据通常在尾部的 mdat 里。
   */
  static makeView(head: Uint8Array, headStart: number, tail: Uint8Array, tailStart: number): IsobmffViewClosure {
    return {
      head: head,
      headStart: headStart,
      tail: tail,
      tailStart: tailStart,
      read: (offset: number, length: number): Uint8Array => {
        if (length <= 0) {
          return new Uint8Array(0);
        }
        const fromHead = offset - headStart;
        if (fromHead >= 0 && fromHead + length <= head.length) {
          return head.slice(fromHead, fromHead + length);
        }
        const fromTail = offset - tailStart;
        if (fromTail >= 0 && fromTail + length <= tail.length) {
          return tail.slice(fromTail, fromTail + length);
        }
        // 跨缓冲：先看头、再看尾，能拼多少拼多少（box 头 8~16 字节足够）。
        const parts: Uint8Array[] = [];
        if (fromHead >= 0 && fromHead < head.length) {
          parts.push(head.slice(fromHead, Math.min(head.length, fromHead + length)));
        }
        const need = length - (parts.length > 0 ? parts[0].length : 0);
        if (need > 0 && fromTail >= 0 && fromTail < tail.length) {
          parts.push(tail.slice(fromTail, Math.min(tail.length, fromTail + need)));
        }
        return DynamicPhotoFormat.joinParts(parts);
      }
    };
  }

  private static joinParts(parts: Uint8Array[]): Uint8Array {
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

  /**
   * HEIC/HEIF 动态图片探测。返回 undefined 表示「这不是一张 HEIF 动态图片」，
   * 由调用方继续走 JPEG/三星/兜底路径。
   */
  static probeHeif(
    fileName: string,
    head: Uint8Array,
    tail: Uint8Array,
    tailStart: number,
    fileSize: number,
    imageFormat: DynamicPhotoImageFormat
  ): DynamicPhotoProbe | undefined {
    const extension = DynamicPhotoFormat.extensionOf(fileName);
    const fallbackExtension = extension.length > 0 ? extension : 'heic';
    // head/tail 只拼一次视图，HEIF 的 box 结构在头部、iloc 指向的数据在尾部 mdat。
    const holder = DynamicPhotoFormat.makeView(head, 0, tail, tailStart);
    const readAt = (offset: number, length: number): Uint8Array => holder.read(offset, length);
    let meta: HeifMetaData;
    try {
      meta = Isobmff.readHeifMeta(readAt, fileSize);
    } catch (error) {
      return undefined;
    }

    // 1) Apple Live Photo 的图片侧标识符（Exif MakerNote 0x0011）。
    const imageIdentifier = DynamicPhotoFormat.readHeifContentIdentifier(head, tail, tailStart, meta, fileSize, readAt);
    if (imageIdentifier.length >= 32) {
      return {
        kind: 'apple-live',
        imageFormat: imageFormat,
        imageOffset: 0,
        imageLength: fileSize,
        videoOffset: -1,
        videoLength: -1,
        imageExtension: DynamicPhotoFormat.imageExtensionFor(imageFormat, fallbackExtension),
        videoExtension: 'mov',
        vendor: 'Apple'
      };
    }

    // 2) 内嵌视频（Google Motion Photo 存成 HEIC 的形态，或厂商把视频作为独立 item）。
    const xmp = meta.xmp;
    if (xmp.length > 0) {
      const hint = DynamicPhotoFormat.parseXmpVideoHint(xmp);
      if (meta.videoItemIds.length > 0) {
        const located = DynamicPhotoFormat.locateHeifVideo(tail, tailStart, fileSize, meta);
        if (located !== undefined) {
          const vendor = DynamicPhotoFormat.vendorFromXmp(xmp);
          const kind: DynamicPhotoKind = vendor === 'Google' ? 'google-motion' : 'vendor-motion';
          return DynamicPhotoFormat.probeWithVideo(kind, vendor, imageFormat, 0, located[0],
            located[0], fileSize - located[0], fallbackExtension);
        }
      }
      if (hint !== undefined) {
        const located = DynamicPhotoFormat.locateVideo(tail, tailStart, fileSize, hint, 0);
        if (located !== undefined) {
          const vendor = DynamicPhotoFormat.vendorFromXmp(xmp);
          const kind: DynamicPhotoKind = vendor === 'Google' ? 'google-motion' : 'vendor-motion';
          return DynamicPhotoFormat.probeWithVideo(kind, vendor, imageFormat, 0, located[0],
            located[0], fileSize - located[0], fallbackExtension);
        }
      }
      // HEIC 没有 EOI，验证手段只有 ftyp 校验；声明了动图但找不到视频段时不可武断判定。
      if (DynamicPhotoFormat.xmpDeclaresMotionPhoto(xmp)) {
        const byScan = DynamicPhotoFormat.findFtypNear(tail, tailStart, 0, fileSize, fileSize - 8);
        if (byScan > 0) {
          return DynamicPhotoFormat.probeWithVideo('vendor-motion', DynamicPhotoFormat.vendorFromXmp(xmp),
            imageFormat, 0, byScan, byScan, fileSize - byScan, fallbackExtension);
        }
      }
    } else if (meta.videoItemIds.length > 0) {
      // 有视频 item 但没有 XMP：多半是 Apple Live Photo 的 HEIC（视频其实在同目录的 .MOV 里，
      // HEIC 内部的 track/item 只是残留），不当作内嵌动图。按「同批次同名视频配对」处理。
      return undefined;
    }
    return undefined;
  }

  /**
   * 依据 iloc 给出的 item 位置定位 HEIF 内嵌视频段：取视频 item 的第一个 extent，
   * 校验其首字节是合法 `ftyp`，再向外扩展到文件末尾（MP4 通常就是文件的最后一段）。
   */
  private static locateHeifVideo(
    tail: Uint8Array,
    tailStart: number,
    fileSize: number,
    meta: HeifMetaData
  ): number[] | undefined {
    for (const itemId of meta.videoItemIds) {
      const location = Isobmff.locationOf(meta.locations, itemId);
      if (location === undefined || location.extents.length === 0) {
        continue;
      }
      const start = location.baseOffset + location.extents[0].offset;
      if (start <= 0 || start >= fileSize) {
        continue;
      }
      if (DynamicPhotoFormat.isFtypAt(tail, tailStart, start)) {
        return [start, start];
      }
      // iloc 可能只覆盖一小段（分片存储），退化为以 item 起始为锚点搜索。
      const byScan = DynamicPhotoFormat.findFtypNear(tail, tailStart, start > 64 ? start - 64 : 0, fileSize, start);
      if (byScan > 0) {
        return [byScan, byScan];
      }
    }
    return undefined;
  }

  /** 读 HEIF 里 Exif item 的 Apple ContentIdentifier。 */
  private static readHeifContentIdentifier(
    head: Uint8Array,
    tail: Uint8Array,
    tailStart: number,
    meta: HeifMetaData,
    fileSize: number,
    readAt: (offset: number, length: number) => Uint8Array
  ): string {
    if (meta.exifOffset < 0 || meta.exifLength <= 0) {
      return '';
    }
    const view: IsobmffView = readAt;
    const limit = Math.min(meta.exifOffset + meta.exifLength, fileSize);
    // Exif item 载荷前缀有三种写法：`Exif\0\0`(6) / exif_tiff_header_offset(4) / 直接 TIFF 头。
    const prefix = view(meta.exifOffset, 8);
    if (prefix.length < 8) {
      return '';
    }
    if (prefix[0] === 0x45 && prefix[1] === 0x78 && prefix[2] === 0x69 && prefix[3] === 0x66
      && prefix[4] === 0x00 && prefix[5] === 0x00) {
      return Isobmff.readAppleContentIdentifier(view, meta.exifOffset + 6, limit);
    }
    const isTiffHeader = (prefix[0] === 0x49 && prefix[1] === 0x49 && prefix[2] === 0x2a)
      || (prefix[0] === 0x4d && prefix[1] === 0x4d && prefix[2] === 0x00);
    if (isTiffHeader) {
      return Isobmff.readAppleContentIdentifier(view, meta.exifOffset, limit);
    }
    const headerOffset = DynamicPhotoFormat.readU32BE(prefix, 0);
    if (headerOffset >= 0 && headerOffset < meta.exifLength) {
      return Isobmff.readAppleContentIdentifier(view, meta.exifOffset + headerOffset, limit);
    }
    return '';
  }

  // ---------------------------------------------------------------------
  // QuickTime MOV：Apple content identifier
  // ---------------------------------------------------------------------

  /**
   * 从 MOV/MP4 里读 Apple Live Photo 的 content identifier。
   *
   * 两条路径都要试，因为不同 iOS 版本/写入方不一样：
   *  1. 标准路径：`moov[/udta]/meta` 的 `keys`+`ilst` mdta 键
   *     `com.apple.quicktime.content.identifier`（UTF-8 data 值）；
   *  2. 兜底：直接在 `moov` 范围内按 UUID 形状找（有些写入方把键名与值放在普通 box 里）。
   */
  static readMovContentIdentifier(holder: IsobmffViewClosure, fileSize: number): string {
    const view: IsobmffView = (offset: number, length: number): Uint8Array => holder.read(offset, length);
    try {
      const meta = Isobmff.findMoovMeta(view, fileSize);
      if (meta !== undefined) {
        const metadata: QuickTimeMetadata = Isobmff.readQuickTimeMetadata(view, meta);
        for (let i = 0; i < metadata.keys.length; i++) {
          if (metadata.keys[i].toLowerCase() === 'com.apple.quicktime.content.identifier') {
            const value = metadata.values[i] ?? '';
            if (value.length >= 32) {
              return value;
            }
          }
        }
      }
      // 兜底：在 moov 范围内找键名，再按 UUID 形状取值。
      const top = Isobmff.childBoxes(view, 0, fileSize);
      for (const box of top) {
        if (box.type !== 'moov') {
          continue;
        }
        const bytes = holder.read(box.start, box.end - box.start);
        const marker = DynamicPhotoFormat.indexOf(DynamicPhotoFormat.UTF8_APPLE_ID, bytes, 0);
        if (marker >= 0) {
          const extracted = DynamicPhotoFormat.extractAppleContentIdentifier(bytes);
          if (extracted.length >= 32) {
            return extracted;
          }
        }
      }
    } catch (error) {
      return '';
    }
    return '';
  }

  /**
   * MOV 里是否带 `com.apple.quicktime.still-image-time`（Apple Live Photo 的伴随键）。
   * 作为「这是实况照片」的辅助判据，不作为唯一依据。
   */
  static movHasStillImageTime(holder: IsobmffViewClosure, fileSize: number): boolean {
    const view: IsobmffView = (offset: number, length: number): Uint8Array => holder.read(offset, length);
    try {
      const meta = Isobmff.findMoovMeta(view, fileSize);
      if (meta === undefined) {
        return false;
      }
      const metadata: QuickTimeMetadata = Isobmff.readQuickTimeMetadata(view, meta);
      for (const key of metadata.keys) {
        if (key.toLowerCase() === 'com.apple.quicktime.still-image-time') {
          return true;
        }
      }
    } catch (error) {
      return false;
    }
    return false;
  }

  /**
   * Apple Live Photo 的「同源」判定：图片侧标识符与视频侧标识符相同。
   * 入参为空串时返回 false，调用方应退化为按文件名配对。
   */
  static appleIdentifiersMatch(imageIdentifier: string, videoIdentifier: string): boolean {
    if (imageIdentifier.length < 32 || videoIdentifier.length < 32) {
      return false;
    }
    return imageIdentifier.trim().toUpperCase() === videoIdentifier.trim().toUpperCase();
  }

  /**
   * 图片侧 Apple ContentIdentifier：按扩展名/字节签名分派。
   *  - JPEG：找 APP1 里的 `Exif\0\0`，TIFF 头就在其后 6 字节；
   *  - HEIC/HEIF：走 `meta` 的 Exif item（iloc 定位，前缀三种写法都试）。
   *
   * 两条路径都用同一套「先按 MakerNote 结构解析、失败再扫 Exif 载荷里的 UUID 串」策略：
   * 真机 iPhone 实况照片（含 HDR 实况照片）的标识就写在 Exif 里，是一串 **36 字符带连字符的
   * UUID**（`apple-hdr-live.heic`：Exif item 内 `'Apple iOS'` 魔数 @766、UUID @2030；
   * `apple-live-photo.heic`：@756 / @1996），**没有任何 XMP 键**。只按 MakerNote 的 IFD 结构找
   * 会因为 MakerNote 内部布局差异读不到（实测两对真机样本都返回空 → 实况照片配不上对）。
   */
  static readImageContentIdentifier(holder: DynamicPhotoBytes, fileSize: number, extension: string): string {
    const head = holder.head;
    const format = DynamicPhotoFormat.sniffImageFormat(head);
    const view: IsobmffView = (offset: number, length: number): Uint8Array => holder.holder.read(offset, length);
    if (format === 'jpeg' || extension === 'jpg' || extension === 'jpeg') {
      const payloadStart = DynamicPhotoFormat.findExifApp1Offset(head);
      if (payloadStart < 0) {
        return '';
      }
      // payloadStart 指向 'Exif\0\0' 之后（TIFF 头）。
      const limit = Math.min(fileSize, head.length);
      const structured = Isobmff.readAppleContentIdentifier(view, payloadStart, limit);
      if (structured.length >= 32) {
        return structured;
      }
      // 兜底：扫 Exif APP1 载荷里的 UUID 串（App1 段最长 64KB，范围有界）。
      const scanEnd = Math.min(limit, payloadStart + 65533);
      return DynamicPhotoFormat.uuidFromPayload(view(payloadStart, Math.max(scanEnd - payloadStart, 0)));
    }
    if (format === 'heic' || format === 'avif' || extension === 'heic' || extension === 'heif') {
      let meta: HeifMetaData;
      try {
        meta = Isobmff.readHeifMeta(view, fileSize);
      } catch (error) {
        return '';
      }
      const structured = DynamicPhotoFormat.readHeifContentIdentifier(head, holder.tail, holder.tailStart,
        meta, fileSize, view);
      if (structured.length >= 32) {
        return structured;
      }
      // 兜底：扫 Exif item 载荷里的 UUID 串（真机 HEIC 的标识就在这里）。
      return DynamicPhotoFormat.uuidFromExifItem(view, meta, fileSize);
    }
    return '';
  }

  /**
   * 在 Exif item 载荷里扫 Apple ContentIdentifier（UUID 形状的 36 字符串）。
   *
   * 为什么不在全文件范围扫：真机 HEIC 里能扫到 3 个 UUID（另外两个在 Exif item 之外），
   * 而 **Exif item 内只有一个**，正好是内容标识。范围收在 Exif item 内既准确又便宜。
   */
  private static uuidFromExifItem(view: IsobmffView, meta: HeifMetaData, fileSize: number): string {
    if (meta.exifOffset < 0 || meta.exifLength <= 0) {
      return '';
    }
    const length = Math.min(meta.exifLength, fileSize - meta.exifOffset);
    if (length <= 0) {
      return '';
    }
    return DynamicPhotoFormat.uuidFromPayload(view(meta.exifOffset, length));
  }

  /** 在给定字节里找「36 字符 UUID」串（大小写都认），返回大写形式；找不到返回空串。 */
  private static uuidFromPayload(bytes: Uint8Array): string {
    const limit = bytes.length - 36;
    for (let i = 0; i <= limit; i++) {
      if (!DynamicPhotoFormat.isHexByte(bytes[i]) || !DynamicPhotoFormat.isHexByte(bytes[i + 1])
        || !DynamicPhotoFormat.isHexByte(bytes[i + 2]) || !DynamicPhotoFormat.isHexByte(bytes[i + 3])
        || !DynamicPhotoFormat.isHexByte(bytes[i + 4]) || !DynamicPhotoFormat.isHexByte(bytes[i + 5])
        || !DynamicPhotoFormat.isHexByte(bytes[i + 6]) || !DynamicPhotoFormat.isHexByte(bytes[i + 7])) {
        continue;
      }
      if (bytes[i + 8] !== 0x2d) {
        continue;
      }
      if (!DynamicPhotoFormat.isHexRun(bytes, i + 9, 4) || bytes[i + 13] !== 0x2d) {
        continue;
      }
      if (!DynamicPhotoFormat.isHexRun(bytes, i + 14, 4) || bytes[i + 18] !== 0x2d) {
        continue;
      }
      if (!DynamicPhotoFormat.isHexRun(bytes, i + 19, 4) || bytes[i + 23] !== 0x2d) {
        continue;
      }
      if (!DynamicPhotoFormat.isHexRun(bytes, i + 24, 12)) {
        continue;
      }
      let out = '';
      for (let j = 0; j < 36; j++) {
        const ch = bytes[i + j];
        out += String.fromCharCode(ch >= 0x61 && ch <= 0x7a ? ch - 0x20 : ch);
      }
      return out;
    }
    return '';
  }

  private static isHexRun(bytes: Uint8Array, from: number, count: number): boolean {
    for (let i = 0; i < count; i++) {
      if (!DynamicPhotoFormat.isHexByte(bytes[from + i])) {
        return false;
      }
    }
    return true;
  }

  /** 找 JPEG 的 APP1 `Exif\0\0`，返回 TIFF 头的绝对偏移（找不到 -1）。 */
  static findExifApp1Offset(head: Uint8Array): number {
    if (head.length < 4 || head[0] !== 0xff || head[1] !== 0xd8) {
      return -1;
    }
    let offset = 2;
    while (offset + 4 <= head.length) {
      if (head[offset] !== 0xff) {
        offset += 1;
        continue;
      }
      let marker = head[offset + 1];
      while (marker === 0xff && offset + 2 < head.length) {
        offset += 1;
        marker = head[offset + 1];
      }
      if (marker === 0xda || marker === 0xd9) {
        return -1;
      }
      if (marker === 0xd8 || (marker >= 0xd0 && marker <= 0xd7) || marker === 0x01) {
        offset += 2;
        continue;
      }
      if (offset + 4 > head.length) {
        return -1;
      }
      const length = DynamicPhotoFormat.readU16BE(head, offset + 2);
      if (length < 2) {
        return -1;
      }
      const payloadStart = offset + 4;
      if (marker === 0xe1 && payloadStart + 6 <= head.length
        && head[payloadStart] === 0x45 && head[payloadStart + 1] === 0x78
        && head[payloadStart + 2] === 0x69 && head[payloadStart + 3] === 0x66
        && head[payloadStart + 4] === 0x00 && head[payloadStart + 5] === 0x00) {
        return payloadStart + 6;
      }
      offset += 2 + length;
    }
    return -1;
  }

  // ---------------------------------------------------------------------
  // 顶层探测
  // ---------------------------------------------------------------------

  /**
   * 探测一份文件是否为动态图片，并给出图片段 / 视频段的字节范围。
   *
   * @param fileName 文件名（仅用于扩展名与厂商提示，不读取磁盘）
   * @param head 文件头部字节（建议 ≥ 256KB，需覆盖 JPEG 的 APP 段与 HEIC 的 meta）
   * @param tail 文件尾部字节（建议 ≥ 256KB，需覆盖 XMP / SEF trailer / ZIP 中央目录）
   * @param tailStart tail[0] 在文件中的绝对偏移
   * @param fileSize 文件总字节数
   */
  static probe(
    fileName: string,
    head: Uint8Array,
    tail: Uint8Array,
    tailStart: number,
    fileSize: number
  ): DynamicPhotoProbe {
    const extension = DynamicPhotoFormat.extensionOf(fileName);
    const imageFormat = DynamicPhotoFormat.sniffImageFormat(head);
    const fallbackExtension = extension.length > 0 ? extension : 'bin';

    // livp：ZIP 容器，内部含图片 + 视频两个条目（华为/鸿蒙导出形态）。
    if (extension === 'livp' || (head.length >= 4 && head[0] === 0x50 && head[1] === 0x4b && head[2] === 0x03 && head[3] === 0x04)) {
      return DynamicPhotoFormat.probeLivp(fallbackExtension);
    }

    const isJpeg = imageFormat === 'jpeg';

    // HEIC/HEIF：XMP 是 `meta/iinf/infe` 里 item_type='mime' 且内容类型为 application/rdf+xml
    // 的条目（字节由 iloc 给出），Exif 是 item_type='Exif' 的条目。先走 HEIF 解析。
    if (imageFormat === 'heic' || imageFormat === 'avif') {
      const viaHeif = DynamicPhotoFormat.probeHeif(fileName, head, tail, tailStart, fileSize, imageFormat);
      if (viaHeif !== undefined) {
        return viaHeif;
      }
    }

    // 优先在尾部找 XMP（内嵌视频的 XMP 通常写在文件头 APP1，但也可出现在 HEIC 任意位置）。
    let xmp = DynamicPhotoFormat.findXmpText(head, isJpeg);
    if (xmp.length === 0) {
      xmp = DynamicPhotoFormat.findXmpText(tail, false);
    }
    const hint = DynamicPhotoFormat.parseXmpVideoHint(xmp);
    const declaresMotion = DynamicPhotoFormat.xmpDeclaresMotionPhoto(xmp);

    // 三星 SEF trailer：视频段紧邻 SEFH 之前。
    // 注意：三星也会给「没有视频的普通照片」追加 SEF trailer，因此 ftyp 校验是必需的，
    // 校验不通过时必须当作普通照片，不能误报为动态图片。
    const samsung = DynamicPhotoFormat.parseSamsungTrailer(tail, tailStart, fileSize);
    if (samsung !== undefined) {
      const searchEnd = fileSize - samsung.offsetFromEnd;
      const jpegEnd = isJpeg ? DynamicPhotoFormat.jpegEndOffset(head, head.length) : -1;
      const ftypAt = DynamicPhotoFormat.findFtypNear(tail, tailStart,
        jpegEnd > 0 ? jpegEnd : 0, searchEnd, searchEnd - 8);
      if (ftypAt >= 0 && searchEnd > ftypAt) {
        return DynamicPhotoFormat.probeWithVideo('samsung-motion', 'Samsung', imageFormat, 0,
          ftypAt, ftypAt, searchEnd - ftypAt, fallbackExtension);
      }
    }

    if (hint !== undefined) {
      const located = DynamicPhotoFormat.locateVideo(tail, tailStart, fileSize, hint,
        isJpeg ? DynamicPhotoFormat.jpegEndOffset(head, head.length) : 0);
      if (located !== undefined) {
        // 厂商仅用于日志/展示：只要 XMP 出现在这两类判据里，就按命名空间归类（缺失时自然落到 Generic）。
        const vendor = DynamicPhotoFormat.vendorFromXmp(xmp);
        const kind: DynamicPhotoKind = vendor === 'Google' ? 'google-motion' : 'vendor-motion';
        // located = [视频起始偏移, 图片段结束偏移]：图片段只取 Primary 那一段，
        // 不能把中间的 GainMap 段一起当成图片（否则图片资源尾部会多出一段 JPEG 数据）。
        return DynamicPhotoFormat.probeWithVideo(kind, vendor, imageFormat, 0, located[1],
          located[0], fileSize - located[0], fallbackExtension);
      }
    }

    // 兜底：文件尾部直接跟着 MP4（部分国产机型与三星旧机型），且 XMP 已声明是动态图片。
    // 搜索必须从「JPEG 的 EOI 之后」开始：JPEG 熵编码数据里 0xFF 后必跟 0x00，但
    // 0x66 0x74 0x79 0x70（'ftyp'）这样的普通字节序列可以出现在熵数据中，
    // 从头扫描会把普通照片误判成动态图片。
    if (declaresMotion) {
      const searchFrom = isJpeg ? DynamicPhotoFormat.jpegEndOffset(head, head.length) : 0;
      const ftypAt = DynamicPhotoFormat.findFtypNear(tail, tailStart, searchFrom, fileSize, fileSize - 8);
      if (ftypAt > 0) {
        return DynamicPhotoFormat.probeWithVideo('vendor-motion', DynamicPhotoFormat.vendorFromXmp(xmp),
          imageFormat, 0, ftypAt, ftypAt, fileSize - ftypAt, fallbackExtension);
      }
    }

    // 非动态图片：只回填图片段信息，视频段为空。
    const result = emptyProbe('none', '');
    return {
      kind: result.kind,
      imageFormat: imageFormat,
      imageOffset: 0,
      imageLength: fileSize,
      videoOffset: -1,
      videoLength: -1,
      imageExtension: DynamicPhotoFormat.imageExtensionFor(imageFormat, fallbackExtension),
      videoExtension: '',
      vendor: ''
    };
  }

  /** livp 结果：图片段与视频段都在 ZIP 内部，由调用方解压后再落盘。 */
  private static probeLivp(fallbackExtension: string): DynamicPhotoProbe {
    return {
      kind: 'harmony-livp',
      imageFormat: 'unknown',
      imageOffset: -1,
      imageLength: -1,
      videoOffset: -1,
      videoLength: -1,
      imageExtension: fallbackExtension === 'livp' ? 'jpg' : fallbackExtension,
      videoExtension: 'mp4',
      vendor: 'HarmonyOS'
    };
  }

  /** 依据 XMP 里的命名空间/作者字段判断厂商，纯日志与展示用途。 */
  static vendorFromXmp(xmp: string): string {
    if (xmp.length === 0) {
      return 'Generic';
    }
    const ascii = DynamicPhotoFormat.encodeAscii(xmp);
    const has = (text: string): boolean => DynamicPhotoFormat.indexOf(ascii, DynamicPhotoFormat.encodeAscii(text), 0) >= 0;
    // 先认「自家命名空间」：国产机型多数同时写 Google 容器与自家字段
    // （例如 OPPO 的 `OpCamera:` + `ns.oplus.com`），按 Google 优先会把它们全归成 Google。
    if (has('ns.oplus.com') || has('OpCamera') || has('oplus') || has('OPPO') || has('ColorOS')) {
      return 'OPPO';
    }
    if (has('ns.xiaomi') || has('Xiaomi') || has('miui') || has('MIUI') || has('XiaoMi')) {
      return 'Xiaomi';
    }
    if (has('ns.vivo') || has('vivo') || has('Vivo')) {
      return 'vivo';
    }
    if (has('ns.hihonor') || has('Honor') || has('HONOR') || has('honor')) {
      return 'Honor';
    }
    if (has('Huawei') || has('HUAWEI') || has('HarmonyOS')) {
      return 'Huawei';
    }
    if (has('Samsung') || has('samsung')) {
      return 'Samsung';
    }
    if (has('GCamera') || has('ns.google.com/photos')) {
      return 'Google';
    }
    return 'Generic';
  }

  /**
   * 指定绝对偏移处是否是「一段 MP4 的开头」——比裸 `ftyp` 匹配严格得多，用于：
   *  - 容差搜索时排除 JPEG 熵编码数据里偶然出现的 `ftyp` 字节序列（曾经的误判来源）；
   *  - 校验 XMP 声明偏移是否真的落在视频段起点。
   *
   * 判据：`size`(u32BE) + `ftyp` + 可打印的 major brand，且 size 合理；
   * 若后续字节可读，则紧随其后的 box 类型必须是已知的顶层 box（moov/mdat/free/…）。
   */
  static isMp4StartAt(bytes: Uint8Array, base: number, absoluteOffset: number, fileSize: number): boolean {
    const local = absoluteOffset - base;
    if (local < 0 || local + 16 > bytes.length || absoluteOffset > fileSize - 16) {
      return false;
    }
    if (!DynamicPhotoFormat.asciiAt(bytes, local + 4, 'ftyp')) {
      return false;
    }
    const size = DynamicPhotoFormat.readU32BE(bytes, local);
    // ftyp box 至少 16 字节（size/type/major/minor），实际机型一般 16~64 字节。
    if (size < 16 || size > 65536) {
      return false;
    }
    for (let i = 0; i < 4; i++) {
      const c = bytes[local + 8 + i];
      if (c < 0x20 || c > 0x7e) {
        return false;
      }
    }
    const next = local + size;
    if (next + 8 <= bytes.length) {
      return DynamicPhotoFormat.isKnownTopLevelBoxAt(bytes, next + 4);
    }
    // 后续 box 不在缓冲内（ftyp 正好在缓冲区末尾）：仅靠 brand 判据采信。
    return absoluteOffset + size >= fileSize - 8;
  }

  /** 该偏移处是否是已知的 MP4 顶层 box 类型（用于鉴别「这确实是一段 MP4」）。 */
  private static isKnownTopLevelBoxAt(bytes: Uint8Array, offset: number): boolean {
    const known: string[] = ['moov', 'mdat', 'free', 'skip', 'wide', 'uuid', 'styp', 'sidx', 'moof',
      'pdin', 'meta', 'ftyp', 'junk', 'pnot', 'udta'];
    for (const item of known) {
      if (DynamicPhotoFormat.asciiAt(bytes, offset, item)) {
        return true;
      }
    }
    return false;
  }

  /** 在 tail 覆盖的绝对区间 [max(tailStart, from), min(fileEnd, to)) 内，找最靠近
   * `anchor` 的合法 `ftyp` box 起始偏移（找不到返回 -1）。
   *
   * 用途：XMP 声明的视频偏移只是「大概率正确」的锚点 —— 相机在写完视频后又改写了图片段、
   * 或尾部被追加过几个字节时，声明值会有偏差；此时按锚点向外做有界扩展搜索，
   * 找到的候选仍必须通过 ftyp 校验，因此不会降低判定的严格性。
   *
   * 下界必须限定：JPEG 熵编码数据里可能出现 `ftyp` 这样的普通字节序列，
   * 若从文件头开始扫描，普通照片会被误判成动态图片。
   */
  static findFtypNear(tail: Uint8Array, tailStart: number, from: number, to: number, anchor: number): number {
    const lower = Math.max(from, tailStart);
    const upper = Math.min(to, tailStart + tail.length);
    if (upper - lower < 8) {
      return -1;
    }
    const window = Math.min(upper - lower, DynamicPhotoFormat.FTYP_SEARCH_WINDOW);
    // tail 缓冲区按定义是「文件最后 tail.length 字节」，因此 tailStart + tail.length 即文件大小。
    const fileSize = tailStart + tail.length;
    for (let delta = 0; delta <= window; delta++) {
      const forward = anchor + delta;
      if (forward + 8 <= upper && DynamicPhotoFormat.isMp4StartAt(tail, tailStart, forward, fileSize)) {
        return forward;
      }
      const backward = anchor - delta;
      if (backward >= lower && DynamicPhotoFormat.isMp4StartAt(tail, tailStart, backward, fileSize)) {
        return backward;
      }
    }
    return -1;
  }

  /** 指定绝对偏移处是否是合法的 `ftyp` box 起始（size ≥ 8 且类型为 'ftyp'）。 */
  static isFtypAt(tail: Uint8Array, tailStart: number, absoluteOffset: number): boolean {
    const local = absoluteOffset - tailStart;
    if (local < 0 || local + 8 > tail.length) {
      return false;
    }
    if (tail[local + 4] !== 0x66 || tail[local + 5] !== 0x74
      || tail[local + 6] !== 0x79 || tail[local + 7] !== 0x70) {
      return false;
    }
    return DynamicPhotoFormat.readU32BE(tail, local) >= 8;
  }

  /**
   * 在 JPEG 头部字节里定位 EOI(0xFFD9) 的结束偏移（= 图片段结束位置）。
   *
   * 依据 JPEG 规范：熵编码数据中 0xFF 只会后跟 0x00（字节填充）或 RST(0xD0..0xD7)，
   * 因此 SOS 之后「第一个 0xFFD9」必然是 EOI，可安全截断。
   * 传入的字节里若没有 EOI，返回 -1（调用方按「未知」处理）。
   */
  static jpegEndOffset(head: Uint8Array, from: number): number {
    let sosAt = -1;
    let offset = 2;
    while (offset + 4 <= head.length) {
      if (head[offset] !== 0xff) {
        offset += 1;
        continue;
      }
      let marker = head[offset + 1];
      while (marker === 0xff && offset + 2 < head.length) {
        offset += 1;
        marker = head[offset + 1];
      }
      if (marker === 0xda) {
        sosAt = offset;
        break;
      }
      if (marker === 0xd9 || marker === 0xd8) {
        break;
      }
      if (marker >= 0xd0 && marker <= 0xd7) {
        offset += 2;
        continue;
      }
      if (offset + 4 > head.length) {
        break;
      }
      const length = DynamicPhotoFormat.readU16BE(head, offset + 2);
      if (length < 2) {
        break;
      }
      offset += 2 + length;
    }
    if (sosAt < 0) {
      return -1;
    }
    const searchFrom = Math.max(sosAt, from);
    for (let i = searchFrom; i + 1 < head.length; i++) {
      if (head[i] === 0xff && head[i + 1] === 0xd9) {
        return i + 2;
      }
    }
    return -1;
  }

  /**
   * 依据 XMP 提示定位视频段，返回 [视频起始绝对偏移, 图片段结束绝对偏移]。
   * 定位后一律用 `ftyp` box 校验，避免把误命中的偏移当成视频。
   */
  private static locateVideo(
    tail: Uint8Array,
    tailStart: number,
    fileSize: number,
    hint: DynamicPhotoVideoHint,
    searchFrom: number
  ): number[] | undefined {
    if (hint.source === 'microvideo-offset' && hint.offsetFromEnd > 0) {
      // 旧版 Google MicroVideo：MicroVideoOffset 是从文件末尾数的「视频长度」（不是起始偏移）。
      // 若声明值可信，视频段正好占据文件最后 N 字节：起始偏移 = fileSize - N，结束偏移 = fileSize。
      const start = fileSize - hint.offsetFromEnd;
      if (start <= 0) {
        return undefined;
      }
      const insideWindow = start >= tailStart;
      if (!insideWindow) {
        // 视频起点在已读取的尾部窗口之外（大视频）：纯字节层看不到视频头部，先按 XMP 算术
        // 采信作为候选项，由 DynamicPhotoBridge.probePath 定向读 16 字节复核后才会真正切分。
        return [start, start];
      }
      if (DynamicPhotoFormat.isMp4StartAt(tail, tailStart, start, fileSize)) {
        return [start, start];
      }
      // 声明值有小偏差（相机改写图片段/尾部追加过字节）：以声明值为锚点，在图片段之后容差搜索。
      const lower = searchFrom > 0 ? searchFrom : 0;
      const byScan = DynamicPhotoFormat.findFtypNear(tail, tailStart, lower, fileSize, start);
      if (byScan > 0 && byScan < fileSize) {
        return [byScan, byScan];
      }
      return undefined;
    }
    if (hint.source === 'container-directory' && hint.items.length >= 2) {
      const items = hint.items;
      // 目录里的各段按顺序从偏移 0 紧密排布，每段占 (Length + Padding)。
      //
      // 关键：Primary 段的 `Item:Length` 规范上常写 0，语义是「长度未声明，占满到下一段
      // 之前」——即文件剩余字节数减去其它所有已声明的段。真实机型（如 OPPO 的
      // O-LivePhoto：Primary(0) + GainMap(102953) + MotionPhoto(5928316)）就是这样写的，
      // 早期实现按字面 0 累加，算出的视频起点落在图片段内部，导致整张动图被判成普通照片。
      let declaredOthers = 0;
      let undeclared = 0;
      for (const item of items) {
        if (item.length > 0) {
          declaredOthers += item.length + (item.padding > 0 ? item.padding : 0);
        } else {
          undeclared += 1;
        }
      }
      if (undeclared > 1) {
        // 多段都没声明长度：无法用「剩余字节」反推，放弃（宁可漏判也不误判）。
        return undefined;
      }
      const impliedLength = fileSize - declaredOthers;
      let cursor = 0;
      let primaryEnd = -1;
      let videoStart = -1;
      let videoLength = -1;
      for (let i = 0; i < items.length; i++) {
        const item = items[i];
        const length = item.length > 0 ? item.length : impliedLength;
        if (length <= 0) {
          return undefined;
        }
        if (i === 0) {
          primaryEnd = cursor + length;
        } else if (DynamicPhotoFormat.isVideoContainerItem(item)) {
          videoStart = cursor;
          videoLength = length;
          break;
        }
        cursor += length + (item.padding > 0 ? item.padding : 0);
      }
      if (videoStart <= 0 || videoLength <= 0) {
        return undefined;
      }
      const imageEnd = primaryEnd > 0 ? primaryEnd : videoStart;
      // 视频起点在已读尾部窗口内：用「确实是一段 MP4」的强判据复核。
      if (DynamicPhotoFormat.isMp4StartAt(tail, tailStart, videoStart, fileSize)) {
        return [videoStart, imageEnd];
      }
      // 声明值与真实排布不一致时（相机改写图片段会让声明值偏小、尾部被追加过字节会让它偏大）：
      // 以声明值为锚点容差搜索。下界取「图片段结束」或「锚点往回 2MB」，二者取较大且不小于 0。
      const floor = searchFrom > 0 ? searchFrom : videoStart - DynamicPhotoFormat.FTYP_SEARCH_WINDOW;
      const lower = Math.max(0, floor);
      const byScan = DynamicPhotoFormat.findFtypNear(tail, tailStart, lower, fileSize, videoStart);
      if (byScan > 0 && byScan < fileSize) {
        return [byScan, byScan];
      }
      // 视频起点在窗口之外（视频远大于尾部窗口，例如 5.9MB 视频 / 256KB 窗口）：
      // 此时纯字节层看不到视频头部，只能把「按容器目录算出来的起点」当作候选项返回，
      // 由带 I/O 的调用方（DynamicPhotoBridge.probePath）定向读取 16 字节复核，复核不过即丢弃。
      // 注意：这里不能再拿「各段长度之和 == 文件大小」当判据 —— 只要有一段长度未声明，
      // 它的长度就是按文件大小反推出来的，这个等式恒成立，等于没有校验。
      if (videoStart < tailStart && videoStart + videoLength === fileSize) {
        return [videoStart, imageEnd];
      }
      return undefined;
    }
    return undefined;
  }
}

/** XMP / trailer 给出的「视频段在哪里」的提示。 */
export interface DynamicPhotoVideoHint {
  /** 自文件末尾倒数的字节数；容器目录形式未知为 -1。 */
  readonly offsetFromEnd: number;
  /** 视频段长度；未知为 -1。 */
  readonly length: number;
  /** 判据来源，便于日志定位（microvideo-offset / container-directory / samsung-sef ...）。 */
  readonly source: string;
  /** 容器目录里各段长度（按顺序，末段为视频），非该形式时为空数组。 */
  readonly itemLengths: number[];
  /** 容器目录里各段的 padding（紧随该段之后），非该形式时为空数组。 */
  readonly itemPaddings: number[];
  /** 容器目录的逐段信息（含 mime / semantic，用于准确挑出视频段），非该形式时为空数组。 */
  readonly items: XmpContainerItem[];
}

/** ZIP 中央目录里的一个条目（用于解析 livp）。 */
export interface ZipEntryInfo {
  /** 条目名（含路径）。 */
  readonly name: string;
  /** 压缩方式：0 = 存储，8 = deflate。 */
  readonly method: number;
  /** 压缩后长度（存储方式下等于原始长度）。 */
  readonly compressedSize: number;
  /** 解压后长度。 */
  readonly uncompressedSize: number;
  /** 本地文件头在文件中的绝对偏移。 */
  readonly localHeaderOffset: number;
}
