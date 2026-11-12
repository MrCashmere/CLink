/**
 * ISO-BMFF（ISO/IEC 14496-12）与 HEIF（ISO/IEC 23008-12）box 解析 + EXIF/TIFF 遍历。
 *
 * 从 DynamicPhotoFormat 拆出来，只做两件事：
 *  1. 在一个「稀疏视图」上遍历 box 树，取回 HEIC 的 `meta`（iinf/infe/iloc/iref/pitm）
 *     与 QuickTime MOV 的 `moov/meta`（keys/ilst）字段；
 *  2. 按 TIFF IFD 规则遍历 EXIF，读出 Apple MakerNote 里的 ContentIdentifier。
 *
 * 为什么要「稀疏视图」而不是直接传 Uint8Array：
 *  - HEIC 的 `meta` 在文件头部，但 `iloc` 指向的 Exif/XMP/视频数据通常在文件尾部的
 *    `mdat` 里；一次性把整个文件读进内存对照片来说不可接受（可能上百 MB）。
 *  - 因此解析器只认 `ViewFn = (offset, length) => Uint8Array`，由调用方决定
 *    是从已读缓冲里切片，还是回磁盘 seek 读取。
 *
 * 所有偏移都是「文件绝对偏移」，head/tail 缓冲的绝对基址由调用方在 ViewFn 里处理。
 */

import { util } from '@kit.ArkTS';

/** 稀疏读取接口：返回文件 [offset, offset+length) 的字节；读不到时返回空数组。 */
export type IsobmffView = (offset: number, length: number) => Uint8Array;

/** 默认的空视图（读不到任何字节），用于防御性初始化。 */
export const EMPTY_ISOBMFF_VIEW: IsobmffView = (offset: number, length: number): Uint8Array => new Uint8Array(0);

/** box 头信息。 */
export interface IsobmffBox {
  readonly type: string;
  /** box 起始（含头）。 */
  readonly start: number;
  /** box 内容起始（跳过 size/type[/largesize/usertype] 与 FullBox 的 version+flags）。 */
  readonly contentStart: number;
  /** box 结束（不含）。 */
  readonly end: number;
  /** 是否是 FullBox（内容前 4 字节为 version+flags）。 */
  readonly fullBox: boolean;
  readonly version: number;
  readonly flags: number;
}

/** HEIF `infe` 条目（item info entry）。 */
export interface HeifItemInfo {
  readonly itemId: number;
  /** 4CC 类型：'hvc1' / 'avc1' / 'Exif' / 'mime' / 'grid' ... */
  readonly itemType: string;
  /** mime 条目时这里是内容类型（如 application/rdf+xml）；否则是条目名。 */
  readonly itemName: string;
}

/** HEIF `iloc` 中一个 extent 的位置。 */
export interface HeifExtent {
  readonly offset: number;
  readonly length: number;
}

/** HEIF `iloc` 中一个 item 的所有 extent。 */
export interface HeifItemLocation {
  readonly itemId: number;
  readonly baseOffset: number;
  /** 0 = 文件偏移；1 = 同一文件的 idat； */
  readonly constructionMethod: number;
  readonly extents: HeifExtent[];
}

/** 从 HEIF/BMFF 中取出的元数据。 */
export interface HeifMetaData {
  readonly primaryItemId: number;
  /** 图片级 XMP 文本（application/rdf+xml mime 条目）；没有则空串。 */
  readonly xmp: string;
  /** Exif 条目载荷的文件绝对起始偏移（指向 Exif 数据本身，未剥前缀）；没有则 -1。 */
  readonly exifOffset: number;
  readonly exifLength: number;
  /** 视频类条目（itemType 以 'mp4'/'avc'/'hvc'/'hev'/'vmhd' 等开头，或 mime 为 video/*）。 */
  readonly videoItemIds: number[];
  readonly items: HeifItemInfo[];
  readonly locations: HeifItemLocation[];
}

/** MOV/MP4 里的 QuickTime mdta 元数据键值对。 */
export interface QuickTimeMetadata {
  readonly keys: string[];
  readonly values: string[];
}

function emptyHeifMeta(): HeifMetaData {
  return {
    primaryItemId: 0,
    xmp: '',
    exifOffset: -1,
    exifLength: -1,
    videoItemIds: [],
    items: [],
    locations: []
  };
}

/** 4CC 字节 → 字符串（不可打印字节按 '?' 折叠，仅用于判据与日志）。 */
export function fourCc(bytes: Uint8Array, offset: number): string {
  let text = '';
  for (let i = 0; i < 4; i++) {
    const ch = bytes[offset + i];
    text += (ch >= 0x20 && ch <= 0x7e) ? String.fromCharCode(ch) : '?';
  }
  return text;
}

export class Isobmff {
  /** 单次读取的最大字节数：避免调用方按超大 box 一次性读盘。 */
  private static readonly READ_CHUNK: number = 1024 * 1024;
  /** box 递归深度上限（防御损坏文件造成的无限递归）。 */
  private static readonly MAX_DEPTH: number = 8;
  /** 单层 box 数量上限。 */
  private static readonly MAX_BOXES: number = 512;
  /**
   * 元数据条目上限。
   *
   * keys box 的 entry_count 在真实文件里并不总是可靠，因此 keys/ilst 的遍历改用
   * box 边界作为主上界；这个常量只作为兜底，防止异常文件把循环拖得过长。
   */
  private static readonly MAX_METADATA_ENTRIES: number = 256;

  // ---------------------------------------------------------------------
  // box 遍历
  // ---------------------------------------------------------------------

  /** 读取一个 box 头；读不到或非法返回 undefined。 */
  static readBoxHead(view: IsobmffView, offset: number, limit: number): IsobmffBox | undefined {
    if (offset < 0 || offset + 8 > limit) {
      return undefined;
    }
    const header = view(offset, 16);
    if (header.length < 8) {
      return undefined;
    }
    let size = Isobmff.readU32(header, 0);
    const type = fourCc(header, 4);
    let headerLength = 8;
    if (size === 1) {
      // 64 位 largesize：high*2^32 + low（媒体文件不会超过 2^53）。
      if (header.length < 16) {
        return undefined;
      }
      const large = Isobmff.readU32(header, 8) * 4294967296 + Isobmff.readU32(header, 12);
      if (large < 16 || offset + large > limit) {
        return undefined;
      }
      size = large;
      headerLength = 16;
    } else if (size === 0) {
      // size=0 表示「延伸到文件末尾」，只有最后一个 box 合法。
      size = limit - offset;
    } else if (size < 8) {
      // 真实文件里会见到被破坏/被其它数据覆盖的 box，size<8 一律视为不可解析。
      // 关键：绝不能让 readBoxHead 接受它（否则 size 会让后续 box 定位到错误位置）。
      return undefined;
    }
    if (size < headerLength || offset + size > limit) {
      return undefined;
    }
    // uuid box 在 type 之后还有 16 字节 usertype。
    if (type === 'uuid') {
      headerLength += 16;
      if (size < headerLength) {
        return undefined;
      }
    }
    // 需要判断是否 FullBox：读内容前 4 字节。
    const probe = view(offset + headerLength, 4);
    let fullBox = Isobmff.FULL_BOX_TYPES.indexOf(type) >= 0;
    if (type === 'meta') {
      // `meta` 有两种真实写法，必须按字节判，判错就一个子 box 都读不到：
      //  - ISO / HEIF：FullBox → 内容以 version(1B)+flags(3B) 开头，子 box 从 **+12** 开始；
      //  - QuickTime（Apple MOV，真机 iPhone 实况照片就是）：**没有** version/flags，子 box 从 **+8** 开始。
      //    证据：`apple-hdr-live.mov` 的 `meta@3435719`，+8 处是 `00 00 00 22 'hdlr'`；
      //    按 ISO 的 +12 解析会把 `'hdlr'` 当 size（荒谬值）→ keys 一个都列不出来，
      //    `com.apple.quicktime.content.identifier` 读不到，实况照片就配不上对。
      fullBox = Isobmff.looksLikeIsoMeta(view, offset + headerLength, offset + size);
    }
    const version = fullBox && probe.length >= 4 ? probe[0] : 0;
    const flags = fullBox && probe.length >= 4
      ? ((probe[1] << 16) | (probe[2] << 8) | probe[3]) >>> 0
      : 0;
    return {
      type: type,
      start: offset,
      contentStart: offset + headerLength + (fullBox ? 4 : 0),
      end: offset + size,
      fullBox: fullBox,
      version: version,
      flags: flags
    };
  }

  /**
   * `meta` 是 ISO FullBox（子 box 从 +12）还是 QuickTime 风格（子 box 从 +8）。
   *
   * 判定方式：谁的「第一个子 box」看起来像 meta 的已知子 box，就按谁算；两个都不像时保持旧行为
   * （当作 ISO FullBox），避免影响既有解析路径。
   */
  private static looksLikeIsoMeta(view: IsobmffView, contentStart: number, end: number): boolean {
    const iso = Isobmff.readBoxHead(view, contentStart + 4, end);
    if (iso !== undefined && Isobmff.META_CHILD_TYPES.indexOf(iso.type) >= 0) {
      return true;
    }
    const quickTime = Isobmff.readBoxHead(view, contentStart, end);
    if (quickTime !== undefined && Isobmff.META_CHILD_TYPES.indexOf(quickTime.type) >= 0) {
      return false;
    }
    return true;
  }

  /** 遍历 [start, end) 内的直接子 box。 */  static childBoxes(view: IsobmffView, start: number, end: number, depth: number = 0, maxResync: number = 0): IsobmffBox[] {
    const boxes: IsobmffBox[] = [];
    if (depth > Isobmff.MAX_DEPTH) {
      return boxes;
    }
    let cursor = start;
    let guard = 0;
    let skipped = 0;
    while (cursor + 8 <= end && guard < Isobmff.MAX_BOXES) {
      const box = Isobmff.readBoxHead(view, cursor, end);
      if (box === undefined) {
        // 容器内可能有非 box 数据/被破坏的 box：允许有限次重同步，其余情况停止。
        if (skipped >= maxResync) {
          break;
        }
        cursor += 1;
        skipped += 1;
        continue;
      }
      boxes.push(box);
      cursor = box.end;
      skipped = 0;
      guard += 1;
    }
    return boxes;
  }

  /**
   * 在 [start, end) 里找第一个指定类型的直接子 box。
   *
   * 与 `childBoxes` 的差别：遇到不可解析的 box 时不直接放弃，而是**有界重同步**
   * （逐字节向后找下一个「size/type 自洽」的 box 头）。真实文件里容器内可能夹着
   * 非 box 数据或被破坏的 box，若前面有一段垃圾就丢掉后面全部子 box，会漏掉
   * moov/meta 等关键结构。
   */
  static findChild(view: IsobmffView, start: number, end: number, type: string, maxResync: number = 4096): IsobmffBox | undefined {
    let cursor = start;
    let guard = 0;
    let skipped = 0;
    while (cursor + 8 <= end && guard < Isobmff.MAX_BOXES) {
      const box = Isobmff.readBoxHead(view, cursor, end);
      if (box === undefined) {
        if (skipped >= maxResync) {
          return undefined;
        }
        cursor += 1;
        skipped += 1;
        continue;
      }
      if (box.type === type) {
        return box;
      }
      cursor = box.end;
      skipped = 0;
      guard += 1;
    }
    return undefined;
  }

  /**
   * 查找 `moov` 下的 `meta`：QuickTime 允许两种挂载点 —— `moov/meta`（现代 iOS）与
   * `moov/udta/meta`（旧布局），两者都要试。
   */
  static findMoovMeta(view: IsobmffView, fileSize: number): IsobmffBox | undefined {
    const top = Isobmff.childBoxes(view, 0, fileSize);
    for (const box of top) {
      if (box.type !== 'moov') {
        continue;
      }
      const direct = Isobmff.findChild(view, box.contentStart, box.end, 'meta');
      if (direct !== undefined) {
        return direct;
      }
      const udta = Isobmff.findChild(view, box.contentStart, box.end, 'udta');
      if (udta !== undefined) {
        const nested = Isobmff.findChild(view, udta.contentStart, udta.end, 'meta');
        if (nested !== undefined) {
          return nested;
        }
      }
    }
    return undefined;
  }

  /** 查找顶层 `meta`（HEIF 的文件级 meta）。 */
  static findTopMeta(view: IsobmffView, fileSize: number): IsobmffBox | undefined {
    const top = Isobmff.childBoxes(view, 0, fileSize);
    for (const box of top) {
      if (box.type === 'meta') {
        return box;
      }
    }
    return undefined;
  }

  // ---------------------------------------------------------------------
  // QuickTime mdta（keys / ilst）
  // ---------------------------------------------------------------------

  /**
   * 解析 `meta` 里的 `keys` + `ilst`，返回 mdta 键与第一个 UTF-8 字符串值。
   *
   * keys box 字节布局（`contentStart` 已跳过 version+flags）：
   *
   *   contentStart+0   entry_count(4)
   *   contentStart+4   第一个条目：entry_size(4, 含自身) + namespace(4='mdta') + key_string
   *
   * 实现上**不**用 entry_count 作为循环条件：真实文件里这个字段并不可靠，而
   * `contentStart + 8 ≤ end` 这个 box 边界本身就已经给出了安全的上界 ——
   * 依赖 count 只会让「count 读错时整体解析失败」。
   *
   * 键索引从 1 开始。
   *
   * ilst box 布局：若干 item，每项 item_size(4) + item_type(4=key 索引)，
   * 然后若干 data box：data_size(4) + 'data'(4) + type(4) + locale(4) + payload。
   */
  static readQuickTimeMetadata(view: IsobmffView, meta: IsobmffBox): QuickTimeMetadata {
    const keysBox = Isobmff.findChild(view, meta.contentStart, meta.end, 'keys');
    const keys: string[] = [];
    if (keysBox !== undefined) {
      let cursor = keysBox.contentStart + 4; // 跳过 entry_count
      let read = 0;
      while (cursor + 8 <= keysBox.end && read < Isobmff.MAX_METADATA_ENTRIES) {
        const entry = view(cursor, 8);
        if (entry.length < 8) {
          break;
        }
        const entrySize = Isobmff.readU32(entry, 0);
        if (entrySize < 8 || cursor + entrySize > keysBox.end) {
          break;
        }
        // 条目 = size(4) + namespace(4='mdta') + key 字符串
        if (entrySize > 8) {
          keys.push(Isobmff.trimText(Isobmff.decodeUtf8(view(cursor + 8, entrySize - 8))));
        }
        cursor += entrySize;
        read += 1;
      }
    }
    const values: string[] = [];
    const ilst = Isobmff.findChild(view, meta.contentStart, meta.end, 'ilst');
    if (ilst !== undefined) {
      // 逐 key 取值：按 keys 顺序查 ilst 里 item_type == 索引 的子 box。
      for (let i = 0; i < keys.length; i++) {
        values.push(Isobmff.readIlistString(view, ilst, i + 1));
      }
    }
    return { keys: keys, values: values };
  }

  /** 在 ilst 中找 item_type == keyIndex 的条目，并取第一个 UTF-8 data 值。 */
  private static readIlistString(view: IsobmffView, ilst: IsobmffBox, keyIndex: number): string {
    let cursor = ilst.contentStart;
    let guard = 0;
    while (cursor + 8 <= ilst.end && guard < Isobmff.MAX_BOXES) {
      const head = view(cursor, 8);
      if (head.length < 8) {
        return '';
      }
      const itemSize = Isobmff.readU32(head, 0);
      if (itemSize < 8 || cursor + itemSize > ilst.end) {
        return '';
      }
      const itemType = Isobmff.readU32(head, 4);
      if (itemType === keyIndex) {
        let dataCursor = cursor + 8;
        while (dataCursor + 16 <= cursor + itemSize) {
          const dataHead = view(dataCursor, 16);
          if (dataHead.length < 16) {
            break;
          }
          const dataSize = Isobmff.readU32(dataHead, 0);
          if (dataSize < 16 || dataCursor + dataSize > cursor + itemSize) {
            break;
          }
          const typeFlag = Isobmff.readU32(dataHead, 8);
          const payloadStart = dataCursor + 16;
          const payloadLength = dataSize - 16;
          if (typeFlag === 1) {
            // UTF-8 字符串
            return Isobmff.trimText(Isobmff.decodeUtf8(view(payloadStart, payloadLength)));
          }
          if (typeFlag === 2) {
            // UTF-16BE
            const raw = view(payloadStart, payloadLength);
            let text = '';
            for (let i = 0; i + 1 < raw.length; i += 2) {
              text += String.fromCharCode((raw[i] << 8) | raw[i + 1]);
            }
            return Isobmff.trimText(text);
          }
          dataCursor += dataSize;
        }
        return '';
      }
      cursor += itemSize;
      guard += 1;
    }
    return '';
  }

  // ---------------------------------------------------------------------
  // HEIF meta
  // ---------------------------------------------------------------------

  /** 解析 HEIF 文件级 `meta`，取回 XMP / Exif 位置 / 视频 item。 */
  static readHeifMeta(view: IsobmffView, fileSize: number): HeifMetaData {
    const meta = Isobmff.findTopMeta(view, fileSize);
    if (meta === undefined) {
      return emptyHeifMeta();
    }
    const items = Isobmff.readHeifItems(view, meta);
    const locations = Isobmff.readHeifLocations(view, meta);
    const primaryItemId = Isobmff.readPrimaryItemId(view, meta);

    let xmp = '';
    let exifOffset = -1;
    let exifLength = -1;
    const videoItemIds: number[] = [];
    for (const item of items) {
      const location = Isobmff.locationOf(locations, item.itemId);
      if (item.itemType === 'mime') {
        const mime = Isobmff.mediaTypeOf(item.itemName);
        if (mime === 'application/rdf+xml' || mime === 'application/xml') {
          xmp = Isobmff.readItemText(view, location);
        } else if (mime.startsWith('video/') && location !== undefined) {
          videoItemIds.push(item.itemId);
        }
        continue;
      }
      if (item.itemType === 'Exif') {
        if (location !== undefined && location.extents.length > 0) {
          exifOffset = location.baseOffset + location.extents[0].offset;
          exifLength = location.extents[0].length;
        }
        continue;
      }
      if (Isobmff.isVideoItemType(item.itemType)) {
        videoItemIds.push(item.itemId);
      }
    }
    return {
      primaryItemId: primaryItemId,
      xmp: xmp,
      exifOffset: exifOffset,
      exifLength: exifLength,
      videoItemIds: videoItemIds,
      items: items,
      locations: locations
    };
  }

  /** item 数据的文件绝对偏移（按 extent 展开）。 */
  static locationOf(locations: HeifItemLocation[], itemId: number): HeifItemLocation | undefined {
    for (const location of locations) {
      if (location.itemId === itemId) {
        return location;
      }
    }
    return undefined;
  }

  /**
   * 解析 `iinf` → `infe` 列表。
   *
   * 真实文件里 `iinf` 的 entry_count 偶尔会和实际 `infe` 数量对不上（写入方 bug、
   * 或者 box 被截断）。这里不把 count 当权威：以「实际能遍历到的 infe」为准，
   * 只有当 count 比实际少时，才说明 count 可信并据此截断（避免把后续其它类型 box 误读成 infe）。
   */
  private static readHeifItems(view: IsobmffView, meta: IsobmffBox): HeifItemInfo[] {
    const items: HeifItemInfo[] = [];
    const iinf = Isobmff.findChild(view, meta.contentStart, meta.end, 'iinf');
    if (iinf === undefined) {
      return items;
    }
    // iinf 的内容以 u16 entry_count 开头（不是 4 字节），infe 紧随其后。
    const countRaw = view(iinf.contentStart, 2);
    const declaredCount = countRaw.length >= 2 ? Isobmff.readU16(countRaw, 0) : 0;
    const boxes = Isobmff.childBoxes(view, iinf.contentStart + 2, iinf.end, 1);
    for (const box of boxes) {
      if (box.type !== 'infe') {
        // 遇到非 infe 且已经收集到条目：说明 infe 区段结束。
        if (items.length > 0) {
          break;
        }
        continue;
      }
      const item = Isobmff.readInfe(view, box);
      if (item === undefined || item.itemId <= 0) {
        continue;
      }
      items.push(item);
      if (declaredCount > 0 && items.length >= declaredCount) {
        break;
      }
    }
    return items;
  }

  /** 单个 `infe`：v0/v1 无 item_type；v2 item_ID 为 u16；v3 为 u32。 */
  private static readInfe(view: IsobmffView, box: IsobmffBox): HeifItemInfo | undefined {
    const head = view(box.contentStart, 8);
    if (head.length < 8) {
      return undefined;
    }
    const version = box.version;
    let cursor = box.contentStart;
    let itemId = 0;
    if (version >= 3) {
      const raw = view(cursor, 4);
      if (raw.length < 4) {
        return undefined;
      }
      itemId = Isobmff.readU32(raw, 0);
      cursor += 4;
    } else {
      const raw = view(cursor, 2);
      if (raw.length < 2) {
        return undefined;
      }
      itemId = (raw[0] << 8) | raw[1];
      cursor += 2;
    }
    const protection = view(cursor, 2);
    if (protection.length < 2) {
      return undefined;
    }
    cursor += 2;
    let itemType = '';
    if (version >= 2) {
      const typeBytes = view(cursor, 4);
      if (typeBytes.length < 4) {
        return undefined;
      }
      itemType = fourCc(typeBytes, 0);
      cursor += 4;
    }
    const nameLength = box.end - cursor;
    const itemName = nameLength > 0
      ? Isobmff.trimText(Isobmff.decodeUtf8(view(cursor, nameLength > 512 ? 512 : nameLength)))
      : '';
    return { itemId: itemId, itemType: itemType, itemName: itemName };
  }

  /** 解析 `iloc`。offset_size/length_size/base_offset_size 都是 4 bit 变长字段。 */
  private static readHeifLocations(view: IsobmffView, meta: IsobmffBox): HeifItemLocation[] {
    const locations: HeifItemLocation[] = [];
    const iloc = Isobmff.findChild(view, meta.contentStart, meta.end, 'iloc');
    if (iloc === undefined) {
      return locations;
    }
    const version = iloc.version;
    let cursor = iloc.contentStart;
    const sizes = view(cursor, 2);
    if (sizes.length < 2) {
      return locations;
    }
    const offsetSize = (sizes[0] >> 4) & 0x0f;
    const lengthSize = sizes[0] & 0x0f;
    const baseOffsetSize = (sizes[1] >> 4) & 0x0f;
    // v1/v2：第二个字节低 4 bit 是 index_size（必须为 0）。
    cursor += 2;
    const countRaw = view(cursor, 2);
    if (countRaw.length < 2) {
      return locations;
    }
    const itemCount = Isobmff.readU16(countRaw, 0);
    cursor += 2;
    let index = 0;
    while (index < itemCount && index < Isobmff.MAX_BOXES && cursor + 2 <= iloc.end) {
      const idRaw = view(cursor, 2);
      if (idRaw.length < 2) {
        break;
      }
      const itemId = Isobmff.readU16(idRaw, 0);
      cursor += 2;
      let constructionMethod = 0;
      if (version === 1 || version === 2) {
        const cmRaw = view(cursor, 2);
        if (cmRaw.length < 2) {
          break;
        }
        constructionMethod = (cmRaw[0] >> 4) & 0x0f;
        cursor += 2;
      }
      const refRaw = view(cursor, 2);
      if (refRaw.length < 2) {
        break;
      }
      cursor += 2; // data_reference_index
      const base = Isobmff.readVariable(view, cursor, baseOffsetSize);
      cursor += baseOffsetSize;
      const extentRaw = view(cursor, 2);
      if (extentRaw.length < 2) {
        break;
      }
      const extentCount = Isobmff.readU16(extentRaw, 0);
      cursor += 2;
      const extents: HeifExtent[] = [];
      for (let e = 0; e < extentCount && e < Isobmff.MAX_BOXES; e++) {
        const offset = Isobmff.readVariable(view, cursor, offsetSize);
        cursor += offsetSize;
        const length = Isobmff.readVariable(view, cursor, lengthSize);
        cursor += lengthSize;
        extents.push({ offset: offset, length: length });
      }
      locations.push({
        itemId: itemId,
        baseOffset: base,
        constructionMethod: constructionMethod,
        extents: extents
      });
      index += 1;
    }
    return locations;
  }

  /** 读 4bit 指定长度的无符号大端整数（0 表示字段不存在 → 0）。 */
  private static readVariable(view: IsobmffView, offset: number, size: number): number {
    if (size <= 0) {
      return 0;
    }
    if (size > 8) {
      return 0;
    }
    const raw = view(offset, size);
    if (raw.length < size) {
      return 0;
    }
    let value = 0;
    for (let i = 0; i < size; i++) {
      value = value * 256 + raw[i];
    }
    return value;
  }

  /** `pitm` → 主 item ID（v0 为 u16，v1 为 u32）。 */
  private static readPrimaryItemId(view: IsobmffView, meta: IsobmffBox): number {
    const pitm = Isobmff.findChild(view, meta.contentStart, meta.end, 'pitm');
    if (pitm === undefined) {
      return 0;
    }
    if (pitm.version >= 1) {
      const raw = view(pitm.contentStart, 4);
      return raw.length >= 4 ? Isobmff.readU32(raw, 0) : 0;
    }
    const raw = view(pitm.contentStart, 2);
    return raw.length >= 2 ? Isobmff.readU16(raw, 0) : 0;
  }

  /** 读取 item 的完整数据（第一个 extent）。 */
  static readItemBytes(view: IsobmffView, location: HeifItemLocation | undefined): Uint8Array {
    if (location === undefined || location.extents.length === 0) {
      return new Uint8Array(0);
    }
    const extent = location.extents[0];
    // constructionMethod=1 表示数据在 idat 里，本解析器不支持（罕见）。
    if (location.constructionMethod === 1) {
      return new Uint8Array(0);
    }
    const bytes = view(location.baseOffset + extent.offset, extent.length);
    if (bytes.length > 0) {
      return bytes;
    }
    // 超过单次读取上限时，分段拼接（这里只用于 XMP 这类小数据，正常不会走到）。
    const parts: Uint8Array[] = [];
    let read = 0;
    while (read < extent.length) {
      const take = Math.min(Isobmff.READ_CHUNK, extent.length - read);
      const chunk = view(location.baseOffset + extent.offset + read, take);
      if (chunk.length === 0) {
        break;
      }
      parts.push(chunk);
      read += chunk.length;
    }
    return Isobmff.concat(parts);
  }

  private static readItemText(view: IsobmffView, location: HeifItemLocation | undefined): string {
    const bytes = Isobmff.readItemBytes(view, location);
    if (bytes.length === 0) {
      return '';
    }
    const hint = Isobmff.indexOf(hintXmpMeta, bytes, 0);
    if (hint >= 0) {
      return Isobmff.decodeUtf8(Isobmff.slice(bytes, hint, bytes.length));
    }
    return Isobmff.decodeUtf8(bytes);
  }

  /** item 4CC → 是否视频类（avc1/hvc1/hev1/mp4v/vp09/av01/dvhe/dvh1/dva1/encv…）。 */
  static isVideoItemType(itemType: string): boolean {
    if (itemType.length !== 4) {
      return false;
    }
    return itemType === 'avc1' || itemType === 'avc2' || itemType === 'avc3' || itemType === 'avc4'
      || itemType === 'hvc1' || itemType === 'hev1' || itemType === 'hvc2' || itemType === 'hev2'
      || itemType === 'mp4v' || itemType === 'vp08' || itemType === 'vp09' || itemType === 'av01'
      || itemType === 'dvhe' || itemType === 'dvh1' || itemType === 'dva1' || itemType === 'dvav'
      || itemType === 'encv';
  }

  /** 取 MIME 类型主体（去掉 ';charset=...' 参数并小写化）。 */
  static mediaTypeOf(raw: string): string {
    const semi = raw.indexOf(';');
    const head = semi >= 0 ? raw.substring(0, semi) : raw;
    return head.trim().toLowerCase();
  }

  // ---------------------------------------------------------------------
  // EXIF / TIFF
  // ---------------------------------------------------------------------

  /**
   * 在 EXIF 数据里找 Apple Live Photo 的 ContentIdentifier。
   *
   * HEIF 的 Exif item 载荷前 4 字节是 `exif_tiff_header_offset`（TIFF 偏移），
   * 有的写入方直接放 `Exif\0\0`，也有的直接就是 TIFF 头 —— 三种都要试。
   *
   * JPEG 的 APP1 载荷已经剥掉 `Exif\0\0`，传 `tiffBase` 指向 TIFF 头即可。
   *
   * @param view 稀疏读取接口（文件绝对偏移）
   * @param tiffBase TIFF 头的文件绝对偏移
   * @param limit Exif 数据的文件绝对结束偏移（遍历不得越界）
   */
  static readAppleContentIdentifier(view: IsobmffView, tiffBase: number, limit: number): string {
    const header = view(tiffBase, 8);
    if (header.length < 8) {
      return '';
    }
    let little = false;
    if (header[0] === 0x49 && header[1] === 0x49 && header[2] === 0x2a && header[3] === 0x00) {
      little = true;
    } else if (header[0] === 0x4d && header[1] === 0x4d && header[2] === 0x00 && header[3] === 0x2a) {
      little = false;
    } else {
      return '';
    }
    // 注意：这两个读取闭包接受**文件绝对偏移**（调用方负责把 TIFF 相对偏移加上 tiffBase）。
    // 这两个闭包接受「文件绝对偏移」。三个 IFD 辅助函数内部都自行换算成绝对偏移，
    const readU16 = (offset: number): number => {
      const raw = view(offset, 2);
      if (raw.length < 2) {
        return -1;
      }
      return little ? (raw[0] | (raw[1] << 8)) : ((raw[0] << 8) | raw[1]);
    };
    const readU32 = (offset: number): number => {
      const raw = view(offset, 4);
      if (raw.length < 4) {
        return -1;
      }
      return little
        ? ((raw[0] | (raw[1] << 8) | (raw[2] << 16) | (raw[3] << 24)) >>> 0)
        : (((raw[0] << 24) | (raw[1] << 16) | (raw[2] << 8) | raw[3]) >>> 0);
    };
    // TIFF 头里第 4~7 字节是 IFD0 的「相对 TIFF 头」偏移。
    const ifd0Relative = readU32(tiffBase + 4);
    if (ifd0Relative < 0) {
      return '';
    }
    const ifd0Offset = tiffBase + ifd0Relative;
    if (ifd0Offset < 0) {
      return '';
    }
    // IFD0 → ExifIFD（0x8769）→ MakerNote（0x927C）→ Apple IFD → 0x0011
    const exifIfdRelative = Isobmff.findIfdEntryValue(view, readU16, readU32, tiffBase, ifd0Offset, 0x8769, limit);
    if (exifIfdRelative < 0) {
      return '';
    }
    const exifIfd = tiffBase + exifIfdRelative;
    if (exifIfd < 0) {
      return '';
    }
    const makerNote = Isobmff.findIfdEntryOffset(view, readU16, readU32, tiffBase, exifIfd, 0x927c, limit);
    // findIfdEntryOffset 返回的是文件绝对偏移，因此这里直接用，不再叠加 tiffBase。
    if (makerNote < 0 || !Isobmff.hasAppleMakerNoteMagic(view, makerNote)) {
      return '';
    }
    return Isobmff.readAppleMakerNote(view, readU16, readU32, tiffBase, makerNote, limit);
  }

  /** 指定绝对偏移处是否以 ASCII 'Apple iOS' 开头（Apple MakerNote 魔数）。 */
  private static hasAppleMakerNoteMagic(view: IsobmffView, absoluteOffset: number): boolean {
    if (absoluteOffset < 0) {
      return false;
    }
    const magic = view(absoluteOffset, 9);
    return magic.length >= 9 && Isobmff.indexOf(appleIosMagic, magic, 0) === 0;
  }

  /**
   * 解析 Apple MakerNote（以 ASCII `Apple iOS\0` 开头），返回 tag 0x0011 的字符串。
   *
   * Apple IFD 相对 MakerNote 起点的偏移在实测中有 12/14/16 等几种说法，这里不硬编码：
   * 先定位 `Apple iOS` 魔数，再对候选起点逐个尝试，接受「entry 数与 tag 0x0011 都合理」的那个。
   *
   * 偏移口径（很容易踩坑）：`makerNoteOffset` 是**文件绝对偏移**，而
   * `readU16/readU32/readIfdStringEntry` 接受的 `ifdOffset` 都是**相对 TIFF 头**的偏移。
   * 因此这里必须先减掉 `tiffBase` 再传下去，否则会被再叠加一次基准，偏移整体偏大。
   */
  private static readAppleMakerNote(
    view: IsobmffView,
    readU16: (offset: number) => number,
    readU32: (offset: number) => number,
    tiffBase: number,
    makerNoteOffset: number,
    limit: number
  ): string {
    const magic = view(makerNoteOffset, 32);
    if (magic.length < 32) {
      return '';
    }
    // Apple MakerNote 以 ASCII 'Apple iOS' + 若干 NUL 开头；不匹配就不是 Apple MakerNote。
    if (Isobmff.indexOf(appleIosMagic, magic, 0) !== 0) {
      return '';
    }

    const candidates = [14, 12, 16, 10, 18];
    for (const delta of candidates) {
      const ifdOffset = makerNoteOffset + delta;
      const count = readU16(ifdOffset);
      if (count <= 0 || count > 256) {
        continue;
      }
      if (ifdOffset + 2 + count * 12 > limit) {
        continue;
      }
      const value = Isobmff.readIfdStringEntry(view, readU16, readU32, tiffBase, ifdOffset, 0x0011, limit);
      if (value.length >= 32) {
        return value;
      }
    }
    return '';
  }

  /** 在 IFD 里找 tag，返回其「值」（SHORT/LONG 内联值）。 */
  private static findIfdEntryValue(
    view: IsobmffView,
    readU16: (offset: number) => number,
    readU32: (offset: number) => number,
    tiffBase: number,
    ifdOffset: number,
    tag: number,
    limit: number
  ): number {
    // ifdOffset 是「相对 TIFF 头」的偏移，这里换算成绝对位置后再读取。
    const count = readU16(ifdOffset);
    if (count <= 0 || count > 4096) {
      return -1;
    }
    for (let i = 0; i < count; i++) {
      const entry = ifdOffset + 2 + i * 12;
      if (entry + 12 > limit) {
        return -1;
      }
      if (readU16(entry) === tag) {
        // 指针型 tag（如 0x8769）的值是「相对 TIFF 头」的偏移。
        return readU32(entry + 8);
      }
    }
    return -1;
  }

  /** 在 IFD 里找 tag，返回其数据（UNDEFINED/ASCII）的文件绝对偏移。 */
  private static findIfdEntryOffset(
    view: IsobmffView,
    readU16: (offset: number) => number,
    readU32: (offset: number) => number,
    tiffBase: number,
    ifdOffset: number,
    tag: number,
    limit: number
  ): number {
    // ifdOffset 是「相对 TIFF 头」的偏移，这里换算成绝对位置后再读取。
    const count = readU16(ifdOffset);
    if (count <= 0 || count > 4096) {
      return -1;
    }
    for (let i = 0; i < count; i++) {
      const entry = ifdOffset + 2 + i * 12;
      if (entry + 12 > limit) {
        return -1;
      }
      if (readU16(entry) !== tag) {
        continue;
      }
      const type = readU16(entry + 2);
      const itemCount = readU32(entry + 4);
      const size = Isobmff.tiffTypeSize(type) * itemCount;
      if (size <= 0) {
        return -1;
      }
      // 总长 ≤ 4 时值内联在 entry+8（本身就是绝对偏移）；否则 entry+8 存的是「相对 TIFF 头」
      // 的偏移量，这里统一换算成文件绝对偏移返回，避免调用方在两种口径之间混淆。
      return size <= 4 ? (entry + 8) : (tiffBase + readU32(entry + 8));
    }
    return -1;
  }

  /** 读 IFD 里某个字符串型 tag（内联或跨偏移）。 */
  private static readIfdStringEntry(
    view: IsobmffView,
    readU16: (offset: number) => number,
    readU32: (offset: number) => number,
    tiffBase: number,
    ifdOffset: number,
    tag: number,
    limit: number
  ): string {
    // ifdOffset 是「相对 TIFF 头」的偏移，这里换算成绝对位置后再读取。
    const count = readU16(ifdOffset);
    if (count <= 0 || count > 4096) {
      return '';
    }
    for (let i = 0; i < count; i++) {
      const entry = ifdOffset + 2 + i * 12;
      if (entry + 12 > limit) {
        return '';
      }
      if (readU16(entry) !== tag) {
        continue;
      }
      const type = readU16(entry + 2);
      const itemCount = readU32(entry + 4);
      const size = Isobmff.tiffTypeSize(type) * itemCount;
      if (size <= 0 || size > 256) {
        return '';
      }
      let dataOffset = entry + 8;
      if (size > 4) {
        const pointed = readU32(entry + 8);
        if (pointed < 0) {
          return '';
        }
        dataOffset = tiffBase + pointed;
      }
      const raw = view(dataOffset, size);
      if (raw.length === 0) {
        return '';
      }
      return Isobmff.trimText(Isobmff.decodeUtf8(raw));
    }
    return '';
  }

  /** TIFF 字段类型 → 单元素字节数（未列入的类型返回 1，交由长度检查兜底）。 */
  static tiffTypeSize(type: number): number {
    switch (type) {
      case 1:
      case 2:
      case 6:
      case 7:
        return 1;
      case 3:
      case 8:
        return 2;
      case 4:
      case 9:
      case 11:
        return 4;
      case 5:
      case 10:
      case 12:
        return 8;
      default:
        return 1;
    }
  }

  // ---------------------------------------------------------------------
  // 小工具
  // ---------------------------------------------------------------------

  static readU16(bytes: Uint8Array, offset: number): number {
    return ((bytes[offset] << 8) | bytes[offset + 1]) & 0xffff;
  }

  static readU32(bytes: Uint8Array, offset: number): number {
    return ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0;
  }

  static indexOf(needle: Uint8Array, haystack: Uint8Array, from: number): number {
    const last = haystack.length - needle.length;
    if (needle.length === 0 || last < from) {
      return -1;
    }
    for (let i = from < 0 ? 0 : from; i <= last; i++) {
      let matched = true;
      for (let j = 0; j < needle.length; j++) {
        if (haystack[i + j] !== needle[j]) {
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

  static slice(bytes: Uint8Array, from: number, to: number): Uint8Array {
    const start = from < 0 ? 0 : (from > bytes.length ? bytes.length : from);
    const end = to > bytes.length ? bytes.length : (to < start ? start : to);
    return bytes.slice(start, end);
  }

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

  /** 去掉尾部 NUL 与首尾空白。 */
  static trimText(text: string): string {
    let end = text.length;
    while (end > 0) {
      const code = text.charCodeAt(end - 1);
      if (code === 0 || code === 0x20 || code === 0x0a || code === 0x0d || code === 0x09) {
        end -= 1;
      } else {
        break;
      }
    }
    return text.substring(0, end).trim();
  }

  static concat(parts: Uint8Array[]): Uint8Array {
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

  /** FullBox 类型集合：这些 box 的内容以 version(1B)+flags(3B) 开头。 */
  private static readonly FULL_BOX_TYPES: string[] = [
    'meta', 'iinf', 'infe', 'iloc', 'iref', 'pitm', 'iprp', 'ipco', 'ipma', 'idat',
    'keys', 'hdlr', 'mvhd', 'tkhd', 'mdhd', 'stsd', 'dref', 'url ', 'urn ', 'elng'
  ];

  /** `meta` 的已知子 box 类型（用于分辨 ISO FullBox 与 QuickTime 两种布局）。 */
  private static readonly META_CHILD_TYPES: string[] = [
    'hdlr', 'keys', 'ilst', 'dinf', 'iprp', 'iloc', 'iinf', 'pitm', 'idat', 'iref',
    'ipco', 'ipma', 'free', 'skip', 'mdat', 'uuid'
  ];
}

const textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8');

const hintXmpMeta: Uint8Array = new Uint8Array([0x78, 0x6d, 0x70, 0x6d, 0x65, 0x74, 0x61]); // 'xmpmeta'
const appleIosMagic: Uint8Array = new Uint8Array([0x41, 0x70, 0x70, 0x6c, 0x65, 0x20, 0x69, 0x4f, 0x53]); // 'Apple iOS'