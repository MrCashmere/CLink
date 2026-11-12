/**
 * 「增益图（双层）HDR」的容器层读写（**不重编码**路线）。
 *
 * 决策背景见 `docs/HDR_IMAGE.md`：HDR 走增益图（双层）——基础层是一张完整、可独立显示的
 * SDR 图，HDR 作为附加层。这样**只有一端支持 HDR 时两端都能正常显示**：不支持的一端只解基础层，
 * 支持的一端读增益图 + 增益图元数据还原 HDR。
 *
 * 本模块只做容器与元数据的搬排，**不解码、不重编码像素**，因此：
 *  - 基础图的 EXIF / ICC / IPTC 可以整段原样保留（见 `HdrExifPreserve`）；
 *  - 源文件里的增益图与它的元数据也是**原样搬运**，不重新生成（重新生成要 VPE 的 C API，见文档 §2.4）。
 *
 * 支持的两种分段来源：
 *  1. **容器目录 XMP**（`Container:Directory`）：真实 OPPO / Google 文件用的形态，
 *     `Primary`（常写 `Item:Length="0"` 表示"未声明，占满到下一段之前"）+ `GainMap` + `MotionPhoto`；
 *  2. **追加式双 JPEG 启发式**：没有可用 XMP 时，第一张图的 EOI 之后紧跟第二张 JPEG（`0xFFD8`）
 *     即视为增益图；紧跟 `ftyp` 则视为视频段（动态照片）。
 *
 * 所有函数都是纯字节变换，可在 Node 端直接跑回归（见 `staging/hdr/tests`）。
 */

import { util } from '@kit.ArkTS';
import { DynamicPhotoFormat, XmpContainerItem } from './DynamicPhotoFormat';
import { HdrExifPreserve, JpegSegmentInfo } from './HdrExifPreserve';
import { HdrMpf, MPF_TIFF_HEADER_DELTA, ATTRIBUTE_GAINMAP, ISO_21496_URN_PAYLOAD } from './HdrMpf';
import { HdrIsoGainMap } from './HdrIsoGainMap';

const textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8');
const textEncoder: util.TextEncoder = new util.TextEncoder();

/** 容器里的一段。 */
export interface HdrLayer {
  /** `base` = SDR 基础图；`gainmap` = 增益图；`video` = 动态照片的视频段；其它归 `other`。 */
  readonly kind: string;
  readonly start: number;
  readonly end: number;
  readonly mime: string;
  readonly semantic: string;
  /** 分段依据：`container-directory` / `appended-jpeg` / `single`。 */
  readonly source: string;
}

/** 分层结果。 */
export interface HdrLayerSplit {
  readonly layers: HdrLayer[];
  readonly base: HdrLayer | undefined;
  readonly gainMap: HdrLayer | undefined;
  readonly video: HdrLayer | undefined;
  /** XMP 里是否出现增益图元数据/语义标记。 */
  readonly hasGainMapMetadata: boolean;
  /** 判定过程（写日志用）。 */
  readonly reason: string;
}

/** 写出双 JPEG 的结果。 */
export interface DualJpegWriteResult {
  readonly bytes: Uint8Array;
  readonly baseLength: number;
  readonly gainMapLength: number;
  /** 增益图之后原样搬运的附加段长度之和（当前只有动态照片的视频段）。 */
  readonly trailingLength: number;
  /** `replaced` = 替换了已有 XMP 段；`inserted` = 新建了 XMP 段。 */
  readonly xmpAction: string;
  /**
   * 增益图参数的来源：
   *  - `existing-xmp`：增益图本来就带 `hdrgm:` 参数（Android/Apple 源）→ 原样保留；
   *  - `iso-21496`：从增益图自己的 ISO 21496-1 APP2 段翻译出来的（华为/鸿蒙 vivid 源）；
   *  - `none`：两边都没有参数 → 无法生成 HDR 元数据（调用方应当知道这一点，见真机事故说明）；
   *  - `vivid-no-xmp`：vivid（鸿蒙）形态按设计不带 XMP 参数，走 APP2 URN + MPF 0x50000。
   */
  readonly gainMapMetadata: string;
}

/**
 * 跟在增益图之后的附加段（原样搬运，**不重编码**）。
 *
 * 为什么需要：真机 Ultra HDR **动态照片**是三段共存的（`pixel-ultrahdr.jpg`：Primary + GainMap +
 * MotionPhoto）。只搬前两段会把视频丢掉——动态照片就变成静态图了，而且 XMP 目录里声明的段与实际
 * 字节不再一致。`semantic` 必须写回目录（`MotionPhoto`），读取器才按长度切开。
 */
export interface HdrExtraLayer {
  readonly semantic: string;
  readonly mime: string;
  readonly bytes: Uint8Array;
}

/** `withGainMapMetadata` 的结果。 */
export interface GainMapMetadataResult {
  readonly bytes: Uint8Array;
  /** `existing-xmp` / `iso-21496` / `none`，见 `DualJpegWriteResult.gainMapMetadata`。 */
  readonly source: string;
}

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

/** 增益图段尾允许的填充字节上限（真机样本实测 16 字节；给到 4KB 足够，又不会放过真正的切错）。 */
const MAX_GAINMAP_TAIL = 4096;

/** XMP 命名空间前缀（`http://ns.adobe.com/xap/1.0/\0`）。 */
const XMP_NS = 'http://ns.adobe.com/xap/1.0/\u0000';

/** 增益图元数据/语义标记（任一命中即认为带增益图信息）。 */
const GAINMAP_MARKERS: string[] = [
  'Container:Item Item:Mime="image/jpeg" Item:Semantic="GainMap"',
  'Item:Semantic="GainMap"',
  'hdrgm:',
  'ns.adobe.com/xmp/extension',
  'GainMapMin'
];

/**
 * 容器目录元素的前缀有两种写法，**命名空间 URI 相同**
 * （`http://ns.google.com/photos/1.0/container/`）：
 *  - `Container:`   —— Google/OPPO 式动态照片（真实 OPPO 样本就是这个）；
 *  - `GContainer:`  —— Ultra HDR（Android 14+ 增益图）官方文档里的元素名。
 *
 * 顺序很重要：长前缀在前。`'<GContainer:Directory'` 与 `'<Container:Directory'` 互不包含
 * （`<` 后面紧跟的字符不同），但闭标签 `'</Container:Directory>'` 是 `'</GContainer:Directory>'`
 * 的**子串**，所以必须先按长前缀整块处理，否则会把 GContainer 的闭标签漏掉。
 */
const DIRECTORY_TAGS: string[] = ['GContainer:Directory', 'Container:Directory'];

/** 从 XMP 文本里判断源文件用的是哪种前缀（都不含则返回默认的 `Container:Directory`）。 */
function directoryTagOf(xmpText: string): string {
  for (const tag of DIRECTORY_TAGS) {
    if (xmpText.indexOf('<' + tag) >= 0) {
      return tag;
    }
  }
  return 'Container:Directory';
}

/** ISO 21496-1 标识串（华为/鸿蒙形态靠它认 HDR）。 */
const ISO_URN_TEXT = 'urn:iso:std:iso:ts:21496';

/** 在文件里找 ISO 21496-1 标识串的位置（找不到返回 -1）。 */
function isoUrnOffset(bytes: Uint8Array): number {
  const needle = new Uint8Array(ISO_URN_TEXT.length);
  for (let i = 0; i < ISO_URN_TEXT.length; i++) {
    needle[i] = ISO_URN_TEXT.charCodeAt(i);
  }
  return DynamicPhotoFormat.indexOf(bytes, needle, 0);
}

/** 我们写出的容器目录片段（自带命名空间，避免污染原有 rdf:Description）。 */
function directoryDescription(gainMapLength: number, tag: string, extras: HdrExtraLayer[],
  extraAttributes: string = ''): string {
  const suffix = ':Directory';
  const prefix = tag.substring(0, tag.length - suffix.length);
  let items = '<rdf:li rdf:parseType="Resource">'
    + '<' + prefix + ':Item Item:Mime="image/jpeg" Item:Semantic="Primary" Item:Length="0" Item:Padding="0"/>'
    + '</rdf:li>'
    + '<rdf:li rdf:parseType="Resource">'
    + '<' + prefix + ':Item Item:Mime="image/jpeg" Item:Semantic="GainMap" Item:Length="' + gainMapLength + '"'
    + ' Item:Padding="0"/>'
    + '</rdf:li>';
  for (const extra of extras) {
    items += '<rdf:li rdf:parseType="Resource">'
      + '<' + prefix + ':Item Item:Mime="' + extra.mime + '" Item:Semantic="' + extra.semantic
      + '" Item:Length="' + extra.bytes.length + '" Item:Padding="0"/>'
      + '</rdf:li>';
  }
  // `hdrgm:Version` 是「这张图带增益图」的规范标记（Adobe 增益图规范：主图 XMP 里有增益图时
  // 必须写版本号）。真实 OPPO/小米的 Ultra HDR 动态照片里就有它；缺了它，部分读取器即使看到
  // GainMap 项也不按 HDR 处理。extraAttributes 用来把厂商私有字段（OpCamera/XMPhoto/vivo…）
  // 拼进同一个 rdf:Description —— 真实文件就是这么写的（见 docs/DYNAMIC_PHOTO.md §1.6.1）。
  return '<rdf:Description rdf:about=""'
    + ' xmlns:' + prefix + '="http://ns.google.com/photos/1.0/container/"'
    + ' xmlns:Item="http://ns.google.com/photos/1.0/container/item/"'
    + ' xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/"'
    + ' hdrgm:Version="1.0"'
    + extraAttributes
    + '>'
    + '<' + prefix + ':Directory><rdf:Seq>'
    + items
    + '</rdf:Seq></' + prefix + ':Directory>'
    + '</rdf:Description>';
}

/** 全新的最小 XMP（源里没有 XMP 时用）。 */
function freshXmp(gainMapLength: number, tag: string, extras: HdrExtraLayer[],
  extraAttributes: string = ''): string {
  return '<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?>'
    + '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Cashmere Link">'
    + '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
    + directoryDescription(gainMapLength, tag, extras, extraAttributes)
    + '</rdf:RDF></x:xmpmeta>';
}

export class HdrGainMap {
  /** 探测文件里的分层（基础图 / 增益图 / 视频）。 */
  static detectLayers(bytes: Uint8Array, name: string, size: number): HdrLayerSplit {
    const empty: HdrLayerSplit = {
      layers: [], base: undefined, gainMap: undefined, video: undefined,
      hasGainMapMetadata: false, reason: 'not-jpeg'
    };
    if (!HdrExifPreserve.isJpeg(bytes)) {
      // HEIC / AVIF 等：本轮不做容器改写（见 docs/HDR_IMAGE.md §4.3），只报事实。
      return {
        layers: [], base: undefined, gainMap: undefined, video: undefined,
        hasGainMapMetadata: false, reason: 'not-jpeg(' + name + ')'
      };
    }
    const xmpText = HdrGainMap.xmpText(bytes);
    const hasMeta = HdrGainMap.hasGainMapMarkers(xmpText);
    const fromDirectory = HdrGainMap.layersFromContainerDirectory(bytes, xmpText, size);
    if (fromDirectory !== undefined) {
      return HdrGainMap.summarize(fromDirectory, hasMeta, 'container-directory');
    }
    const heuristic = HdrGainMap.layersByHeuristic(bytes, size);
    return HdrGainMap.summarize(heuristic, hasMeta, 'appended-jpeg');
  }

  /** 读 JPEG 里的 XMP 文本（无 XMP 返回空串）。 */
  static xmpText(bytes: Uint8Array): string {
    const seg = HdrExifPreserve.findSegment(bytes, 'XMP');
    if (seg === undefined) {
      return '';
    }
    const payload = HdrExifPreserve.segmentPayload(bytes, seg);
    const prefixLength = XMP_NS.length;
    if (payload.length <= prefixLength) {
      return '';
    }
    return textDecoder.decodeToString(payload.slice(prefixLength));
  }

  /** XMP 里是否带增益图语义/元数据标记。 */
  static hasGainMapMarkers(xmpText: string): boolean {
    if (xmpText.length === 0) {
      return false;
    }
    for (const marker of GAINMAP_MARKERS) {
      if (xmpText.indexOf(marker) >= 0) {
        return true;
      }
    }
    return false;
  }

  /**
   * 按 `Container:Directory` 分段。
   *
   * 长度规则（与真实 OPPO/Google 文件一致）：
   *  - `Item:Length > 0` 的段直接按其长度推进（`Item:Padding` 也算进去）；
   *  - 首段 `Item:Length == 0`（"未声明"）有三种真实写法，不能只按一种算 —— 见下面两个候选；
   *  - 目录走完后若仍有剩余字节，就是**未声明段**（真实文件里常是视频段），按内容嗅探归类后保留。
   *
   * **主图长度的两个候选**（真机样本证明单一规则必错）：
   *  1. **锚在 EOI**：主图就是第一张 JPEG，结束在它自己的 EOI 上。
   *     `XiaomiNew.jpg`（目录只声明 Primary+GainMap、视频不声明）必须用这条：相减会把增益图
   *     和视频一起吞进主图，算出的增益图切片根本不是 JPEG。
   *  2. **总长 − 已声明段之和**：Google 的规范解释（"其余全归主图"）。
   *     `pixel-6-small.jpg`（主图 EOI 之后还有一段 25 KB 的 aecDebug/预览数据，视频是声明的）
   *     必须用这条：锚在 EOI 会把视频段起点算早 25 KB，还凭空多出一段"未声明尾巴"。
   *
   * 取舍办法：两个候选都组装出来，**按每段字节与它声明的 MIME 是否相符打分**，取分高的；
   * 打平时取「锚在 EOI」（对 OPPO/三星这类布局两者本来就一致）。这是纯结构判据，不猜。
   */
  static layersFromContainerDirectory(bytes: Uint8Array, xmpText: string,
    size: number): HdrLayer[] | undefined {
    if (xmpText.length === 0) {
      return undefined;
    }
    const items: XmpContainerItem[] = DynamicPhotoFormat.parseXmpContainerItems(xmpText);
    if (items.length === 0) {
      return undefined;
    }
    const totalSize = size > 0 ? size : bytes.length;
    const firstImageEnd = HdrExifPreserve.jpegEnd(bytes);
    let declaredSum = 0;
    let undeclaredCount = 0;
    for (const item of items) {
      if (item.length > 0) {
        declaredSum += item.length + (item.padding > 0 ? item.padding : 0);
      } else {
        undeclaredCount += 1;
      }
    }
    if (undeclaredCount > 1) {
      return undefined;
    }
    const candidates: number[] = [];
    if (firstImageEnd > 0 && firstImageEnd <= totalSize) {
      candidates.push(firstImageEnd);
    }
    const byRemainder = totalSize - declaredSum;
    if (byRemainder > 0 && byRemainder <= totalSize && byRemainder !== firstImageEnd) {
      candidates.push(byRemainder);
    }
    let best: HdrLayer[] | undefined = undefined;
    let bestScore = -1000;
    for (const primaryLength of candidates) {
      const layout = HdrGainMap.layoutFromItems(bytes, items, primaryLength, totalSize, declaredSum);
      if (layout === undefined) {
        continue;
      }
      const score = HdrGainMap.scoreLayout(bytes, layout);
      if (score > bestScore) {
        bestScore = score;
        best = layout;
      }
    }
    return best;
  }

  /** 按给定主图长度把目录项铺成段；末尾剩余字节归为「未声明段」。 */
  private static layoutFromItems(bytes: Uint8Array, items: XmpContainerItem[],
    primaryLength: number, totalSize: number, declaredSum: number): HdrLayer[] | undefined {
    const layers: HdrLayer[] = [];
    let cursor = 0;
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      let length = item.length;
      if (length <= 0) {
        length = i === 0 ? primaryLength - cursor : totalSize - declaredSum;
      }
      if (length <= 0 || cursor + length > totalSize) {
        return undefined;
      }
      const padding = item.padding > 0 ? item.padding : 0;
      layers.push({
        kind: HdrGainMap.kindOf(item.mime, item.semantic),
        start: cursor,
        end: cursor + length,
        mime: item.mime,
        semantic: item.semantic,
        source: 'container-directory'
      });
      cursor += length + padding;
    }
    if (cursor < totalSize && layers.length > 0) {
      const isMp4 = HdrGainMap.isMp4BoxAt(bytes, cursor);
      const isJpeg = cursor + 2 <= totalSize && bytes[cursor] === 0xff && bytes[cursor + 1] === 0xd8;
      const known = isMp4 || isJpeg;
      layers.push({
        kind: isMp4 ? 'video' : (isJpeg ? 'gainmap' : 'other'),
        start: cursor,
        end: totalSize,
        mime: isMp4 ? 'video/mp4' : (isJpeg ? 'image/jpeg' : 'application/octet-stream'),
        semantic: isMp4 ? 'MotionPhoto' : (isJpeg ? 'GainMap' : 'Undeclared'),
        source: 'container-directory-tail'
      });
    }
    return layers;
  }

  /** 布局打分：每一段（主图之外）的字节是否与它声明的 MIME 相符；尾段按嗅探结果给分。 */
  private static scoreLayout(bytes: Uint8Array, layers: HdrLayer[]): number {
    let score = 0;
    for (let i = 1; i < layers.length; i++) {
      const layer = layers[i];
      if (layer.source === 'container-directory-tail') {
        // 未声明段：认得出来（JPEG / MP4）才加分，认不出来说明这个候选把布局切歪了。
        score += layer.kind === 'other' ? -1 : 1;
        continue;
      }
      score += HdrGainMap.mimeMatches(bytes, layer);
    }
    return score;
  }

  /** 段首字节与声明的 MIME 是否相符：+1 相符、−1 不符、0 无法判断。 */
  private static mimeMatches(bytes: Uint8Array, layer: HdrLayer): number {
    const mime = layer.mime.toLowerCase();
    if (mime.indexOf('image/jpeg') === 0) {
      return bytes[layer.start] === 0xff && bytes[layer.start + 1] === 0xd8 ? 1 : -1;
    }
    if (mime.indexOf('video/') === 0) {
      return HdrGainMap.isMp4BoxAt(bytes, layer.start) ? 1 : -1;
    }
    return 0;
  }

  /** 该偏移处是否是一个像样的 MP4 box 开头（box size + 'ftyp'）。 */
  private static isMp4BoxAt(bytes: Uint8Array, at: number): boolean {
    if (at < 0 || at + 8 > bytes.length) {
      return false;
    }
    const size = ((bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8)
      | bytes[at + 3]) >>> 0;
    const plausible = size === 1 || (size >= 8 && size <= 1024 * 1024);
    return plausible && bytes[at + 4] === 0x66 && bytes[at + 5] === 0x74
      && bytes[at + 6] === 0x79 && bytes[at + 7] === 0x70;
  }

  /** 该偏移处是否是「新容器」的开头（JPEG SOI 或 MP4 box）。 */
  private static startsContainer(bytes: Uint8Array, at: number): boolean {
    if (at + 8 > bytes.length) {
      return false;
    }
    if (bytes[at] === 0xff && bytes[at + 1] === 0xd8) {
      return true;
    }
    return HdrGainMap.isMp4BoxAt(bytes, at);
  }

  /** 没有可用 XMP 时的启发式分段：第一张图 + 紧随其后的第二张 JPEG / MP4。 */
  static layersByHeuristic(bytes: Uint8Array, size: number): HdrLayer[] {
    const layers: HdrLayer[] = [];
    const totalSize = size > 0 ? size : bytes.length;
    const firstEnd = HdrExifPreserve.jpegEnd(bytes);
    if (firstEnd <= 0) {
      return layers;
    }
    layers.push({
      kind: 'base', start: 0, end: firstEnd,
      mime: 'image/jpeg', semantic: 'Primary', source: 'appended-jpeg'
    });
    // 依次往后接：追加的 JPEG 段 / 尾部视频段。最多认 4 段，避免异常文件上无限循环。
    let cursor = firstEnd;
    let guard = 0;
    while (cursor + 8 <= bytes.length && guard < 4) {
      guard += 1;
      if (bytes[cursor] === 0xff && bytes[cursor + 1] === 0xd8) {
        const secondEnd = HdrExifPreserve.jpegEnd(bytes.slice(cursor));
        if (secondEnd <= 0) {
          break;
        }
        let end = cursor + secondEnd;
        // 追加式第二张图后面可能还有少量尾部数据（真机 OPPO 的增益图就带 16 字节尾巴，
        // 我们自己也把这种尾巴原样搬过去）：只要剩余字节不是**新的容器**（JPEG / MP4）
        // **且足够小**，就并进这一段 —— 否则会出现「各段长度之和 != 文件长度」，自检会把正确的
        // 输出判成坏的（真机日志：`vivid self-check failed: split-layers-length(4867979!=4867995)`）。
        //
        // 但必须**有上限**：华为相机的 HDR 照片在增益图之后还有一段 446 KB 的 HDR Vivid 元数据块，
        // 那不是增益图的一部分（把它算进增益图 → 声明长度与实际 JPEG 相差 400 多 KB，
        // 送去别的品牌会被当成一段越界的「增益图」）。所以只吸收 ≤ MAX_GAINMAP_TAIL 的填充，
        // 更大的尾部独立登记为 other，不能并进增益图；本地转换需原样保留其字节与位置。
        if (end < totalSize && totalSize - end <= MAX_GAINMAP_TAIL
          && !HdrGainMap.startsContainer(bytes, end)) {
          end = totalSize;
        }
        const isGainMap = layers.length === 1;
        layers.push({
          kind: isGainMap ? 'gainmap' : 'other', start: cursor, end: end,
          mime: 'image/jpeg', semantic: isGainMap ? 'GainMap' : 'Other',
          source: 'appended-jpeg'
        });
        cursor = end;
        continue;
      }
      if (bytes[cursor + 4] === 0x66 && bytes[cursor + 5] === 0x74
        && bytes[cursor + 6] === 0x79 && bytes[cursor + 7] === 0x70) {
        layers.push({
          kind: 'video', start: cursor, end: totalSize,
          mime: 'video/mp4', semantic: 'MotionPhoto', source: 'appended-jpeg'
        });
        cursor = totalSize;
        continue;
      }
      break;
    }
    if (cursor < totalSize && totalSize <= bytes.length) {
      layers.push({ kind: 'other', start: cursor, end: totalSize,
        mime: 'application/octet-stream', semantic: 'Undeclared', source: 'appended-jpeg' });
    }
    return layers;
  }

  /** mime + semantic → 语义分类。 */
  static kindOf(mime: string, semantic: string): string {
    const lowerSemantic = semantic.toLowerCase();
    const lowerMime = mime.toLowerCase();
    if (lowerSemantic === 'primary') {
      return 'base';
    }
    if (lowerSemantic === 'gainmap') {
      return 'gainmap';
    }
    if (lowerMime.indexOf('video/') === 0 || lowerSemantic.indexOf('motion') >= 0) {
      return 'video';
    }
    return 'other';
  }

  private static summarize(layers: HdrLayer[], hasMeta: boolean, source: string): HdrLayerSplit {
    let base: HdrLayer | undefined = undefined;
    let gainMap: HdrLayer | undefined = undefined;
    let video: HdrLayer | undefined = undefined;
    for (const layer of layers) {
      if (layer.kind === 'base' && base === undefined) {
        base = layer;
      } else if (layer.kind === 'gainmap' && gainMap === undefined) {
        gainMap = layer;
      } else if (layer.kind === 'video' && video === undefined) {
        video = layer;
      }
    }
    return {
      layers: layers, base: base, gainMap: gainMap, video: video,
      hasGainMapMetadata: hasMeta, reason: source + '/layers=' + layers.length
    };
  }

  /** 分层结果的一行摘要（日志用）。 */
  static describe(split: HdrLayerSplit, name: string): string {
    const parts: string[] = [];
    for (const layer of split.layers) {
      parts.push(layer.kind + '[' + layer.start + ',' + layer.end + ')'
        + (layer.semantic.length > 0 ? '/' + layer.semantic : ''));
    }
    return name + ' reason=' + split.reason + ' meta=' + split.hasGainMapMetadata
      + ' layers=' + (parts.length > 0 ? parts.join(' ') : '-');
  }

  /**
   * 组装「基础图 + 增益图」双 JPEG（**不重编码**）。
   *
   * 基础图与增益图都原样保留（含各自的 EXIF / 元数据），只在基础图的 XMP 里补一段容器目录，
   * 声明 `Primary`(Length=0) 与 `GainMap`(Length=增益图长度)。返回 undefined 表示无法安全写出
   * （例如 XMP 段超长、增益图不是 JPEG）。
   *
   * **增益图参数**：真机事故（2026-09-10）—— 只写 `hdrgm:Version` 而没有参数，对端算不出增益
   * 怎么用，只能按 SDR 显示。所以这里先把增益图的元数据补齐（`withGainMapMetadata`）：
   *  - 增益图已有 `hdrgm:` 参数（OPPO/Pixel/小米 那些文件）→ 原样保留；
   *  - 增益图只有 ISO 21496-1 的 APP2 参数（华为/鸿蒙 vivid）→ 翻译成 `hdrgm:` 写进增益图的 XMP；
   *  - 两边都没有 → 不编造参数，`gainMapMetadata='none'` 交给调用方决定（日志/放弃）。
   */
  static writeDualJpegWithGainMap(baseJpeg: Uint8Array, gainMapJpeg: Uint8Array,
    extras: HdrExtraLayer[] = [], extraAttributes: string = ''): DualJpegWriteResult | undefined {
    if (!HdrExifPreserve.isJpeg(baseJpeg) || !HdrExifPreserve.isJpeg(gainMapJpeg)) {
      return undefined;
    }
    const baseEnd = HdrExifPreserve.jpegEnd(baseJpeg);
    if (baseEnd <= 0) {
      return undefined;
    }
    // 增益图参数补齐（长度可能变化，之后所有长度计算都用补齐后的这份）。
    const annotated = HdrGainMap.withGainMapMetadata(gainMapJpeg);
    const gainMap = annotated.bytes;
    // 基础图的有效区（丢掉 EOI 之后的旧附加数据，避免与增益图重叠）。
    // 顺便删掉「华为形态」的 ISO 21496-1 标识段：本函数写的是 **XMP（hdrgm + Container 目录）**
    // 那套通用判据，两套判据同时存在会让读取器摇摆（真机来源常常正是我们自己的 vivid 输出，
    // 它带着 APP2 URN）。vivid 分支是自己的写入函数，不受这里影响。
    const base = HdrExifPreserve.dropIsoUrnSegments(baseJpeg.slice(0, baseEnd));
    const segment = HdrExifPreserve.findSegment(base, 'XMP');
    // 沿用源文件已有的前缀（`Container:` 或 Ultra HDR 的 `GContainer:`），避免同一文件里混用两种写法。
    const sourceXmp = segment === undefined ? '' : HdrGainMap.xmpText(base);
    const tag = directoryTagOf(sourceXmp);
    const directory = directoryDescription(gainMap.length, tag, extras, extraAttributes);
    let newXmp = '';
    let action = '';
    if (segment === undefined) {
      newXmp = freshXmp(gainMap.length, tag, extras, extraAttributes);
      action = 'inserted';
    } else {
      const merged = HdrGainMap.mergeDirectory(sourceXmp, directory);
      if (merged === undefined) {
        return undefined;
      }
      newXmp = merged;
      action = 'replaced';
    }
    const payload = concatBytes([textEncoder.encodeInto(XMP_NS),
      textEncoder.encodeInto(newXmp)]);
    const app1 = HdrExifPreserve.buildAppSegment(0xe1, payload);
    if (app1 === undefined) {
      return undefined;
    }
    // 源里可能已有 MPF（描述旧的第二张图）——先整段删掉，稍后按新布局重建。
    let working = segment === undefined
      ? HdrGainMap.insertAfterMetadata(base, app1)
      : concatBytes([base.slice(0, segment.start), app1, base.slice(segment.end)]);
    working = HdrExifPreserve.dropSegments(working, ['MPF']);

    // MPF 必须放在 SOS 之前（CIPA DC-007 / 参考实现一致）。
    const sos = HdrGainMap.findSos(working);
    if (sos < 0) {
      return undefined;
    }
    const mpfLength = HdrMpf.segmentLength();
    // 主图 size 含 MPF 块本身，到主图 EOI 为止；第二张图紧跟在主图之后。
    const primarySize = working.length + mpfLength;
    // MP 条目偏移相对 MPF 的 TIFF 头（段起始 + 8），且首图偏移恒为 0。
    const secondaryOffset = primarySize - (sos + MPF_TIFF_HEADER_DELTA);
    if (secondaryOffset <= 0) {
      return undefined;
    }
    const mpf = HdrMpf.buildApp2(primarySize, 0, gainMap.length, secondaryOffset);
    const primary = concatBytes([working.slice(0, sos), mpf, working.slice(sos)]);
    // 增益图之后再原样接上附加段（动态照片的视频段）：顺序与 XMP 目录里声明的顺序一致。
    const parts: Uint8Array[] = [primary, gainMap];
    let trailingLength = 0;
    for (const extra of extras) {
      parts.push(extra.bytes);
      trailingLength += extra.bytes.length;
    }
    return {
      bytes: concatBytes(parts),
      baseLength: primary.length,
      gainMapLength: gainMap.length,
      trailingLength: trailingLength,
      xmpAction: action,
      gainMapMetadata: annotated.source
    };
  }

  /**
   * 保证增益图带 `hdrgm:` 参数（`hdrgm:GainMapMin/Max/Gamma/OffsetSDR/OffsetHDR/HDRCapacity*`）。
   *
   * 三种情况：
   *  1. 增益图已有 `hdrgm:GainMapMax`（Android/Pixel/小米/OPPO 源）→ **原样返回**（不动源字节）；
   *  2. 增益图有 ISO 21496-1 参数（华为/鸿蒙 vivid 源）→ 翻译后插入一段新的 XMP（若已有 XMP，
   *     则插在同一个包里的 `</rdf:RDF>` 之前，避免两个 XMP 包互相覆盖）；
   *  3. 都没有 → 原样返回，`source='none'` 并打一行警告（不编造参数：增益图的取值刻度未知，
   *     瞎填会让画面比 SDR 还难看）。
   */
  static withGainMapMetadata(gainMapJpeg: Uint8Array): GainMapMetadataResult {
    if (HdrGainMap.xmpText(gainMapJpeg).indexOf('hdrgm:GainMapMax') >= 0) {
      return { bytes: gainMapJpeg, source: 'existing-xmp' };
    }
    const attributes = HdrIsoGainMap.attributesFromGainMap(gainMapJpeg);
    if (attributes.length === 0) {
      // 不在这里打日志：本模块是纯字节变换，也跑在 Node 回归里；把结论放在 `source` 里由调用方处理。
      return { bytes: gainMapJpeg, source: 'none' };
    }
    const description = '<rdf:Description rdf:about=""' + attributes + '/>';
    const existing = HdrExifPreserve.findSegment(gainMapJpeg, 'XMP');
    let packet = '';
    if (existing === undefined) {
      packet = '<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?>'
        + '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Cashmere Link">'
        + '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
        + description
        + '</rdf:RDF></x:xmpmeta>';
    } else {
      const current = HdrGainMap.xmpText(gainMapJpeg);
      const close = current.lastIndexOf('</rdf:RDF>');
      if (close < 0) {
        packet = '<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?>'
          + '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Cashmere Link">'
          + '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
          + description
          + '</rdf:RDF></x:xmpmeta>';
      } else {
        packet = current.substring(0, close) + description + current.substring(close);
      }
    }
    const payload = concatBytes([textEncoder.encodeInto(XMP_NS), textEncoder.encodeInto(packet)]);
    const app1 = HdrExifPreserve.buildAppSegment(0xe1, payload);
    if (app1 === undefined) {
      return { bytes: gainMapJpeg, source: 'none' };
    }
    const withXmp = existing === undefined
      ? HdrGainMap.insertAfterMetadata(gainMapJpeg, app1)
      : concatBytes([gainMapJpeg.slice(0, existing.start), app1, gainMapJpeg.slice(existing.end)]);
    return { bytes: withXmp, source: 'iso-21496' };
  }


  /**
   * 把一段 APPn 插到「已有的 APP0/APP1（JFIF/EXIF）之后」。
   *
   * 真实 OPPO / Google / Apple 的段顺序都是 `APP0 → EXIF → XMP → MPF → ICC → …`；早期实现把
   * 新 XMP 直接顶到 SOI 之后（EXIF 前面），与真机形态不一致。读取器大多不挑顺序，但既然目标是
   * 「和真实文件长得一样」，就不要在这里引入差异。
   */
  private static insertAfterMetadata(base: Uint8Array, segment: Uint8Array): Uint8Array {
    let at = 2;
    for (const seg of HdrExifPreserve.segments(base)) {
      if (seg.marker === 0xe0 || seg.marker === 0xe1) {
        at = seg.end;
        continue;
      }
      break;
    }
    return concatBytes([base.slice(0, at), segment, base.slice(at)]);
  }

  /** 找第一个 SOS 段的起始位置（MPF 要插在它之前）；没有返回 -1。 */  private static findSos(bytes: Uint8Array): number {
    for (const seg of HdrExifPreserve.segments(bytes)) {
      if (seg.marker === 0xda) {
        return seg.start;
      }
    }
    return -1;
  }

  /**
   * 写「华为/鸿蒙形态」的 HDR 照片（HDR Vivid 那套判据，**同样不重编码**）。
   *
   * 为什么要单独一套：真机实测（Mate 80 Pro Max 相机 HDR 照片）证明鸿蒙认的 HDR 判据是
   *   ① 主图 APP2 段带 `urn:iso:std:iso:ts:21496:-1`（ISO 21496-1 标识）；
   *   ② MPF 第二条目 attribute = **0x50000**（标注「第二张图是 HDR 增益图」）；
   *   ③ 主图**完全没有 XMP**（不是 Apple/Google 的 `hdrgm` + `Container:Directory` 那套）。
   * 而 OPPO/Apple/Google/Pixel 的 Ultra HDR 增益图照片写的是 XMP + attribute 0x0 —— 两者数据
   * （主图、增益图）完全一样，只是「元数据外壳」不同，所以转换可以做到**零重编码**：
   * 主图与增益图的字节原样保留（EXIF/ICC 也在），只重建 APP2 URN + MPF 并去掉 XMP 段。
   *
   * 布局对齐真机：`[EXIF][APP2(ISO URN)][APP2(MPF)][ICC …][图像数据][增益图 JPEG][附加段]`。
   *
   * 注意：华为真机在增益图之后还有一段 446 KB 的 HDR Vivid 元数据块（相机按自己的色调映射算出来的），
   * 我们**生成不出来**。它在「被认出 HDR」里是否必需，只能靠真机实验判定（见 docs/HDR_IMAGE.md §7.3）。
   */
  static writeVividJpeg(baseJpeg: Uint8Array, gainMapJpeg: Uint8Array,
    extras: HdrExtraLayer[] = [], preservePrimaryLength: number = 0): DualJpegWriteResult | undefined {
    if (!HdrExifPreserve.isJpeg(baseJpeg) || !HdrExifPreserve.isJpeg(gainMapJpeg)) {
      return undefined;
    }
    const baseEnd = HdrExifPreserve.jpegEnd(baseJpeg);
    if (baseEnd <= 0) {
      return undefined;
    }
    // 1) 丢掉 EOI 之后的旧附加数据，并删掉 XMP（华为形态不带 XMP）与旧 MPF（稍后重建）。
    let working = HdrExifPreserve.dropSegments(baseJpeg.slice(0, baseEnd), ['XMP', 'MPF']);
    // 2) 插入点：紧跟 EXIF 段之后（与真机一致：EXIF → APP2 URN → APP2 MPF → ICC）。
    const exif = HdrExifPreserve.findSegment(working, 'EXIF');
    const insertAt = exif === undefined ? 2 : exif.end;
    if (insertAt < 2 || insertAt > working.length) {
      return undefined;
    }
    const urnPayload = new Uint8Array(ISO_21496_URN_PAYLOAD.length);
    for (let i = 0; i < ISO_21496_URN_PAYLOAD.length; i++) {
      urnPayload[i] = ISO_21496_URN_PAYLOAD[i];
    }
    const urnSegment = HdrExifPreserve.buildAppSegment(0xe2, urnPayload);
    if (urnSegment === undefined) {
      return undefined;
    }
    // 3) MPF 的偏移都相对它自己的 TIFF 头（段起始 + 8），主图 size 含 APP2 URN + MPF 两块。
    const mpfLength = HdrMpf.segmentLength();
    const mpfStart = insertAt + urnSegment.length;
    if (preservePrimaryLength > 0) {
      // 厂商尾部可能记录绝对偏移；用合法 APP15 填充主图，保持所有附加层起点不变。
      // 转换结果比原主图大、或剩余空间放不下一个合法段时，安全放弃转换。
      let paddingLength: number = preservePrimaryLength - working.length - urnSegment.length - mpfLength;
      if (paddingLength < 0) { return undefined; }
      const padding: Uint8Array[] = [];
      while (paddingLength > 0) {
        if (paddingLength < 4) { return undefined; }
        let segmentLength: number = Math.min(paddingLength, 65535);
        const remaining: number = paddingLength - segmentLength;
        if (remaining > 0 && remaining < 4) { segmentLength -= 4 - remaining; }
        const segment: Uint8Array | undefined = HdrExifPreserve.buildAppSegment(
          0xef, new Uint8Array(segmentLength - 4));
        if (segment === undefined) { return undefined; }
        padding.push(segment);
        paddingLength -= segment.length;
      }
      // 插在 MPF 后、原 JPEG 的其余段之前，不改变 MPF 自身的计算基准。
      working = concatBytes([working.slice(0, insertAt)].concat(padding).concat([working.slice(insertAt)]));
    }
    const primarySize = working.length + urnSegment.length + mpfLength;
    const secondaryOffset = primarySize - (mpfStart + MPF_TIFF_HEADER_DELTA);
    if (secondaryOffset <= 0) {
      return undefined;
    }
    const mpf = HdrMpf.buildApp2(primarySize, 0, gainMapJpeg.length, secondaryOffset, ATTRIBUTE_GAINMAP);
    const primary = concatBytes([
      working.slice(0, insertAt), urnSegment, mpf, working.slice(insertAt)
    ]);
    const parts: Uint8Array[] = [primary, gainMapJpeg];
    let trailingLength = 0;
    for (const extra of extras) {
      parts.push(extra.bytes);
      trailingLength += extra.bytes.length;
    }
    return {
      bytes: concatBytes(parts),
      baseLength: primary.length,
      gainMapLength: gainMapJpeg.length,
      trailingLength: trailingLength,
      xmpAction: 'vivid',
      // vivid 形态不带 XMP 参数（鸿蒙认的是 APP2 URN + MPF 0x50000），这里如实标注。
      gainMapMetadata: 'vivid-no-xmp'
    };
  }

  /**
   * 自检「华为/鸿蒙形态」的输出：APP2 URN 在、MPF attribute=0x50000、第二张图落在增益图上、
   * 没有 XMP 目录残留、增益图字节数与声明一致。
   */
  static verifyVividJpeg(bytes: Uint8Array, split: HdrLayerSplit): string[] {
    const problems: string[] = [];
    if (!HdrExifPreserve.isJpeg(bytes)) {
      problems.push('not-jpeg');
      return problems;
    }
    const firstEnd = HdrExifPreserve.jpegEnd(bytes);
    if (firstEnd <= 0 || firstEnd >= bytes.length) {
      problems.push('base-or-gainmap-missing');
      return problems;
    }
    // ① ISO 21496-1 标识段
    const urn = isoUrnOffset(bytes);
    if (urn < 0) {
      problems.push('iso-urn-missing');
    } else {
      const owner = HdrExifPreserve.segments(bytes).filter((s) => s.start <= urn && s.end > urn);
      if (owner.length === 0 || owner[0].marker !== 0xe2) {
        problems.push('iso-urn-not-in-app2');
      }
    }
    // ② XMP 不该有（华为形态不带 XMP）
    if (HdrExifPreserve.findSegment(bytes, 'XMP') !== undefined) {
      problems.push('xmp-should-be-absent');
    }
    // ③ MPF：第二条目必须标成增益图，且落在增益图起点上
    const mpfSegment = HdrExifPreserve.findSegment(bytes, 'MPF');
    if (mpfSegment === undefined) {
      problems.push('mpf-missing');
    } else {
      const info = HdrMpf.parseAt(bytes, mpfSegment.start);
      if (info === undefined || info.entries.length !== 2) {
        problems.push('mpf-unparsable');
      } else {
        const primary = info.entries[0];
        const secondary = info.entries[1];
        if (!HdrMpf.isPrimary(primary)) {
          problems.push('mpf-primary-attribute');
        }
        if (secondary.attribute !== ATTRIBUTE_GAINMAP) {
          problems.push('mpf-gainmap-attribute(0x' + secondary.attribute.toString(16) + ')');
        }
        const secondaryAt = info.tiffHeaderOffset + secondary.offset;
        if (secondaryAt !== firstEnd) {
          problems.push('mpf-secondary-offset(' + secondaryAt + '!=' + firstEnd + ')');
        }
        if (primary.size !== firstEnd) {
          problems.push('mpf-primary-size(' + primary.size + '!=' + firstEnd + ')');
        }
      }
    }
    // ④ 分层衔接
    if (split.gainMap === undefined) {
      problems.push('gainmap-not-detected');
    } else if (split.gainMap.start !== firstEnd) {
      problems.push('gainmap-start(' + split.gainMap.start + '!=' + firstEnd + ')');
    }
    if (split.layers.length > 0) {
      let cursor = 0;
      for (const layer of split.layers) {
        if (layer.start !== cursor) {
          problems.push('split-layer-gap(' + layer.kind + '@' + layer.start + ')');
        }
        cursor = layer.end;
      }
      if (cursor !== bytes.length) {
        problems.push('split-layers-length(' + cursor + '!=' + bytes.length + ')');
      }
    }
    return problems;
  }

  /**
   * 把容器目录片段合并进已有 XMP 文本。
   *
   * 策略（宁可保守，也不写出非法 XMP）：
   *  1. 先删掉已有的 `Container:Directory` 块（避免两套声明打架）；
   *  2. 在 `</rdf:RDF>` 之前插入**我们自己的** `rdf:Description`（自带 Container/Item 命名空间）；
   *  3. 没有 `</rdf:RDF>` 时退一步插到 `</x:xmpmeta>` 之前；
   *  4. 两者都没有 → 返回 undefined（调用方应改用全新 XMP）。
   */
  static mergeDirectory(xmpText: string, directory: string): string | undefined {
    if (xmpText.length === 0) {
      return undefined;
    }
    let working = HdrGainMap.stripExistingDirectory(xmpText);
    const rdfClose = working.lastIndexOf('</rdf:RDF>');
    if (rdfClose >= 0) {
      return working.substring(0, rdfClose) + directory + working.substring(rdfClose);
    }
    const metaClose = working.lastIndexOf('</x:xmpmeta>');
    if (metaClose >= 0) {
      return working.substring(0, metaClose) + directory + working.substring(metaClose);
    }
    return undefined;
  }

  /**
   * 去掉 XMP 里已有的容器目录块（含其中的 rdf:Seq）。
   *
   * **两种前缀都要处理**：`Container:Directory`（Google/OPPO 动态照片）与
   * `GContainer:Directory`（Ultra HDR）。只认前者时，遇到 Ultra HDR 文件会漏删旧目录，
   * 于是同一份 XMP 里出现两个目录声明（长度互相矛盾）。
   */
  static stripExistingDirectory(xmpText: string): string {
    let working = xmpText;
    for (const tag of DIRECTORY_TAGS) {
      const openTag = '<' + tag;
      const closeTag = '</' + tag + '>';
      let guard = 0;
      while (guard < 8) {
        const open = working.indexOf(openTag);
        if (open < 0) {
          break;
        }
        const close = working.indexOf(closeTag, open);
        working = close < 0
          ? working.substring(0, open)
          : working.substring(0, open) + working.substring(close + closeTag.length);
        guard += 1;
      }
    }
    return working;
  }

  /** XMP 里容器目录出现的次数（两种前缀都算；正常应当恰好 1）。 */
  static directoryCount(xmpText: string): number {
    let count = 0;
    for (const tag of DIRECTORY_TAGS) {
      const openTag = '<' + tag;
      let from = 0;
      while (from < xmpText.length) {
        const at = xmpText.indexOf(openTag, from);
        if (at < 0) {
          break;
        }
        count += 1;
        from = at + openTag.length;
      }
    }
    return count;
  }

  /**
   * 只保留基础层：剥掉增益图，并**同步删掉 XMP 里的容器目录**（否则目录会声明一段不存在的
   * 增益图，解析方按长度跳转就会读到图片尾部之外）。
   *
   * 用途：对端是老设备 / Windows（没有 HDR 概念），发纯 SDR 基础图最省体积也最安全。
   * 基础图本身是原图字节，EXIF / ICC 等仍然是原样（不重编码）。
   */
  static writeBaseOnlyJpeg(baseJpeg: Uint8Array): DualJpegWriteResult | undefined {
    if (!HdrExifPreserve.isJpeg(baseJpeg)) {
      return undefined;
    }
    const baseEnd = HdrExifPreserve.jpegEnd(baseJpeg);
    if (baseEnd <= 0) {
      return undefined;
    }
    // 增益图被扔掉后，MPF 里「第二张图」那条记录就指向文件外了（真实 Apple/Ultra HDR 文件
    // 用 MPF 单独索引增益图），所以只发基础层时必须整段删掉 MPF。
    const base = HdrExifPreserve.dropSegments(baseJpeg.slice(0, baseEnd), ['MPF']);
    const segment = HdrExifPreserve.findSegment(base, 'XMP');
    if (segment === undefined) {
      // 没有 XMP：本来就是纯 SDR 图，直接截到 EOI。
      return { bytes: base, baseLength: base.length, gainMapLength: 0, trailingLength: 0,
      xmpAction: 'none', gainMapMetadata: 'none' };
    }
    const current = HdrGainMap.xmpText(base);
    const stripped = HdrGainMap.stripExistingDirectory(current);
    if (stripped === current) {
      return { bytes: base, baseLength: base.length, gainMapLength: 0, trailingLength: 0,
      xmpAction: 'none', gainMapMetadata: 'none' };
    }
    const payload = concatBytes([textEncoder.encodeInto(XMP_NS), textEncoder.encodeInto(stripped)]);
    const app1 = HdrExifPreserve.buildAppSegment(0xe1, payload);
    if (app1 === undefined) {
      return undefined;
    }
    const out = concatBytes([base.slice(0, segment.start), app1, base.slice(segment.end)]);
    return { bytes: out, baseLength: out.length, gainMapLength: 0, trailingLength: 0,
      xmpAction: 'replaced', gainMapMetadata: 'none' };
  }

  /**
   * 自检写出的双 JPEG：返回问题列表（空数组 = 通过）。
   *
   * 独立于解析器：直接按段/长度规则核对字节，避免「长度字段写错但恰好还能读」这类问题。
   *
   * `split` 除了给增益图，还用来确认**增益图之后**的原样搬运段（动态照片的视频段）：
   * 三段文件（Primary + GainMap + MotionPhoto，真机 Pixel Ultra HDR 就是）里，文件末尾并不是
   * 增益图的 EOI，所以「增益图必须结束在文件末尾」这条只有在没有附加段时才成立。
   */
  static verifyDualJpeg(bytes: Uint8Array, split: HdrLayerSplit): string[] {
    const problems: string[] = [];
    if (!HdrExifPreserve.isJpeg(bytes)) {
      problems.push('not-jpeg');
      return problems;
    }
    const firstEnd = HdrExifPreserve.jpegEnd(bytes);
    if (firstEnd <= 0) {
      problems.push('base-missing-eoi');
      return problems;
    }
    if (firstEnd >= bytes.length) {
      problems.push('gainmap-missing');
      return problems;
    }
    if (!(bytes[firstEnd] === 0xff && bytes[firstEnd + 1] === 0xd8)) {
      problems.push('gainmap-not-jpeg');
    }
    // 增益图的真实结束位置：有附加段时不是文件末尾。
    const gainMapEnd = split.gainMap === undefined ? bytes.length : split.gainMap.end;
    const secondEnd = HdrExifPreserve.jpegEnd(bytes.slice(firstEnd));
    if (secondEnd <= 0) {
      problems.push('gainmap-missing-eoi');
    } else if (firstEnd + secondEnd > gainMapEnd) {
      // 增益图的 JPEG 结束位置超过了它所在段的末尾：布局真的切错了。
      problems.push('gainmap-overrun(' + (firstEnd + secondEnd) + '>' + gainMapEnd + ')');
    } else if (gainMapEnd - (firstEnd + secondEnd) > MAX_GAINMAP_TAIL) {
      // 允许段尾带一小段填充：真机 OPPO 的增益图 JPEG 尾部就有 16 字节零填充
      // （声明 658 647 / 自身 EOI 658 631），我们**原样搬运**，不能因此判成坏的。
      problems.push('gainmap-length-mismatch(' + (bytes.length - firstEnd) + ' vs ' + secondEnd + ')');
    }
    // 分层必须无缝衔接、且合计正好等于文件长度（中间既不能有缝，也不能有没声明的尾部数据）。
    if (split.layers.length > 0) {
      let cursor = 0;
      for (const layer of split.layers) {
        if (layer.start !== cursor) {
          problems.push('split-layer-gap(' + layer.kind + '@' + layer.start + '!=' + cursor + ')');
        }
        cursor = layer.end;
      }
      if (cursor !== bytes.length) {
        problems.push('split-layers-length(' + cursor + '!=' + bytes.length + ')');
      }
    }
    const xmp = HdrGainMap.xmpText(bytes);
    if (xmp.indexOf('Item:Semantic="GainMap"') < 0) {
      problems.push('xmp-missing-gainmap-item');
    }
    if (xmp.indexOf('Item:Semantic="Primary"') < 0) {
      problems.push('xmp-missing-primary-item');
    }
    const directories = HdrGainMap.directoryCount(xmp);
    if (directories !== 1) {
      problems.push('xmp-directory-count(' + directories + ')');
    }
    // 附加段（视频等）必须在目录里声明，否则读取器按目录切分时会把它算进增益图。
    if (split.gainMap !== undefined) {
      for (const layer of split.layers) {
        if (layer.start < split.gainMap.end) {
          continue;
        }
        const declared = 'Item:Semantic="' + layer.semantic + '" Item:Length="' + (layer.end - layer.start) + '"';
        if (xmp.indexOf('Item:Semantic="' + layer.semantic + '"') < 0) {
          problems.push('xmp-missing-extra-item(' + layer.semantic + ')');
        } else if (xmp.indexOf(declared) < 0) {
          problems.push('xmp-extra-length(' + layer.semantic + '@' + (layer.end - layer.start) + ')');
        }
      }
    }
    // MPF：Ultra HDR 靠它索引第二张图；条目必须与真实布局一致。
    const mpfSegment = HdrExifPreserve.findSegment(bytes, 'MPF');
    if (mpfSegment === undefined) {
      problems.push('mpf-missing');
    } else {
      const info = HdrMpf.parseAt(bytes, mpfSegment.start);
      if (info === undefined) {
        problems.push('mpf-unparsable');
      } else {
        if (info.numberOfImages !== 2) {
          problems.push('mpf-image-count(' + info.numberOfImages + ')');
        }
        if (info.entries.length !== 2) {
          problems.push('mpf-entry-count(' + info.entries.length + ')');
        } else {
          const primary = info.entries[0];
          const secondary = info.entries[1];
          if (!HdrMpf.isPrimary(primary)) {
            problems.push('mpf-primary-attribute');
          }
          if (primary.offset !== 0) {
            problems.push('mpf-primary-offset(' + primary.offset + ')');
          }
          // 主图 size 应等于主图（含 MPF 块）到 EOI 的长度，也就是 firstEnd。
          //
          // 这是**本实现**的写入约定，也与参考实现 libultrahdr 的公式一致
          // （primary_image_size = pos + 2 + length + (base_size − sos_offset)，pos 为 MPF 段起始）。
          // 注意别把这条当成通用规则去校验别人的文件：真实 Apple 增益图照片（macOS/iOS 导出）
          // 的 entry0.size 比真实主图长 70 字节，是「建议值」；真正被读取的是 entry1.offset，
          // 它按 primary_size − pos − 8 算出来正好落在主图 EOI 上。外部分析请用 real-samples 里的宽松判定。
          if (primary.size !== firstEnd) {
            problems.push('mpf-primary-size(' + primary.size + '!=' + firstEnd + ')');
          }
          const secondaryFileOffset = info.tiffHeaderOffset + secondary.offset;
          if (secondaryFileOffset !== firstEnd) {
            problems.push('mpf-secondary-offset(' + secondaryFileOffset + '!=' + firstEnd + ')');
          }
          // MPF 只索引「图片」：第二张图是增益图，视频段不在 MPF 的条目里（真机文件同样如此）。
          if (secondary.size !== gainMapEnd - firstEnd) {
            problems.push('mpf-secondary-size(' + secondary.size + '!=' + (gainMapEnd - firstEnd) + ')');
          }
        }
      }
    }
    return problems;
  }

  /** 基础图里的 EXIF 段是否仍然存在（不重编码路线的最小保证）。 */
  static baseHasExif(bytes: Uint8Array): boolean {
    return HdrExifPreserve.exifPayload(bytes, HdrExifPreserve.jpegEnd(bytes)) !== undefined;
  }

  /** 段信息（供日志：EXIF / ICC / MPF 是否在、多大）。 */
  static segmentSummary(bytes: Uint8Array, limit: number = -1): string {
    const list: JpegSegmentInfo[] = HdrExifPreserve.segments(bytes, limit);
    const names: string[] = [];
    for (const seg of list) {
      names.push(seg.name);
    }
    return names.join(',');
  }
}
