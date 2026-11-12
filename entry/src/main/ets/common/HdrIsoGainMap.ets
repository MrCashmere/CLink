/**
 * ISO 21496-1 增益图元数据（JPEG APP2）的**读取**与到 Adobe `hdrgm:` 字段的**翻译**。
 *
 * 为什么必须有它（2026-09-10 真机事故）：我们把华为/鸿蒙「vivid」HDR 照片转成通用形态时，
 * 只写了 `hdrgm:Version="1.0"`，**没有增益图参数**（GainMapMin/Max/Gamma/Offset/HDRCapacity）。
 * 与真实文件逐字节对照：
 *
 * | 文件 | 增益图参数 | 位置 |
 * | --- | --- | --- |
 * | 真实 OPPO 实况照片 | ✔（`GainMapMin=0 GainMapMax=2.30045 Gamma=1 …`） | 增益图自己的 XMP |
 * | 真实 Pixel Ultra HDR | ✔（`GainMapMax=1.001239 …`） | 增益图自己的 XMP |
 * | 我们的输出 | ✘ **只有 Version** | —— |
 *
 * 解码器没有那组参数就**算不出增益怎么用**，只能按 SDR 显示（真机表现：下载到 OPPO 上「没有 HDR」）。
 * 而源之所以没有 XMP，是因为它是华为 vivid 形态：参数走 ISO 21496-1 的 **APP2 二进制结构体**。
 * 所以这里按标准把它读出来，翻译成对端认的 `hdrgm:` 字段。
 *
 * 结构（ISO 21496-1 C.4.6 "Gain map metadata"，APP2 载荷）：
 * ```
 * URN 28 字节 = "urn:iso:std:iso:ts:21496:-1" + NUL
 * u16 minimum_version
 * u16 writer_version
 * u8  flags                      // bit7: 1=多通道 0=单通道；bit6: 1=用基准图色彩空间
 * (u32 n, u32 d) baseline_hdr_capacity        // 有理数
 * (u32 n, u32 d) alternate_hdr_headroom
 * 每通道（单通道 1 组 / 多通道 3 组）各 5 个有理数：
 *   gain_map_min, gain_map_max, gamma, base_offset, alternate_offset
 * ```
 * 单通道总长 = 28 + 4 + 1 + 16 + 40 = **89 字节**（与真机华为样本的 APP2 载荷长度一致；主图那个
 * 32 字节的 APP2 只有版本信息，没有参数 —— 这是标准的划分方式）。
 *
 * 参考：ISO/IEC 21496-1:2025（C.4.6）；字段顺序与解释见
 * https://jackchou00.com/posts/iso-21496-1-gainmap-hdr/ （2026-09-10 核对）。
 */

/** 一个通道的增益图参数（全部是「有理数」即分子/分母，这里已算成数值）。 */
export interface IsoGainMapChannel {
  readonly gainMapMin: number;
  readonly gainMapMax: number;
  readonly gamma: number;
  readonly baseOffset: number;
  readonly alternateOffset: number;
}

/** ISO 21496-1 元数据全文。 */
export interface IsoGainMapMetadata {
  readonly minimumVersion: number;
  readonly writerVersion: number;
  readonly multiChannel: boolean;
  readonly useBaseColourSpace: boolean;
  readonly baselineHdrCapacity: number;
  readonly alternateHdrHeadroom: number;
  readonly channels: IsoGainMapChannel[];
  /** 结构体从 URN 起算的字节长度（用于判断是否把参数读全了）。 */
  readonly payloadLength: number;
  /** 是否只有版本信息（主图那种 APP2，没有参数）。 */
  readonly versionOnly: boolean;
}

const URN_TEXT = 'urn:iso:std:iso:ts:21496:-1';
/** URN 文本 + 结尾 NUL。 */
const URN_BYTES = 28;

function bytesIndexOf(bytes: Uint8Array, needle: Uint8Array, from: number): number {
  if (needle.length === 0 || bytes.length < needle.length) {
    return -1;
  }
  const first = needle[0];
  const last = bytes.length - needle.length;
  for (let i = Math.max(0, from); i <= last; i++) {
    if (bytes[i] !== first) {
      continue;
    }
    let hit = true;
    for (let j = 1; j < needle.length; j++) {
      if (bytes[i + j] !== needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) {
      return i;
    }
  }
  return -1;
}

function readU16(bytes: Uint8Array, at: number): number {
  return ((bytes[at] << 8) | bytes[at + 1]) >>> 0;
}

function readU32(bytes: Uint8Array, at: number): number {
  return (((bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3]) >>> 0);
}

/** 有理数：分母为 0 时按 0 处理（标准里不允许，但坏文件不该让整条链路崩掉）。 */
function rational(bytes: Uint8Array, at: number): number {
  const n = readU32(bytes, at);
  const d = readU32(bytes, at + 4);
  return d === 0 ? 0 : n / d;
}

/**
 * 把数值写成 XMP 属性里的短形式：`0`、`1`、`2.169925`（真实文件就是这么写的，不补零）。
 */
export function formatAttributeValue(value: number): string {
  if (!Number.isFinite(value)) {
    return '0';
  }
  if (value === 0) {
    return '0';
  }
  const rounded = Math.round(value * 1000000) / 1000000;
  let text = rounded.toString();
  if (text.indexOf('.') >= 0) {
    while (text.endsWith('0')) {
      text = text.substring(0, text.length - 1);
    }
    if (text.endsWith('.')) {
      text = text.substring(0, text.length - 1);
    }
  }
  return text;
}

export class HdrIsoGainMap {
  /**
   * 在 `[from, to)` 范围里找 ISO 21496-1 的 APP2 段并解析。
   *
   * 优先返回**带参数**的那份：一个文件里主图与增益图各有一段 APP2，主图那段只有版本信息。
   * 所以调用方应当先在增益图区间里找（见 `attributesFromGainMap`）。
   */
  static parse(bytes: Uint8Array, from: number = 0, to: number = -1): IsoGainMapMetadata | undefined {
    const end = to < 0 ? bytes.length : Math.min(to, bytes.length);
    const needle = HdrIsoGainMap.urnBytes();
    const at = bytesIndexOf(bytes, needle, from);
    if (at < 0 || at >= end) {
      return undefined;
    }
    // 段起点：从 URN 往回找离得最近的 APP2 标记（0xFFE2）。
    let segStart = at;
    while (segStart > from && !(bytes[segStart] === 0xff && bytes[segStart + 1] === 0xe2)) {
      segStart--;
    }
    if (!(bytes[segStart] === 0xff && bytes[segStart + 1] === 0xe2)) {
      return undefined;
    }
    const segLength = readU16(bytes, segStart + 2);
    const payloadStart = segStart + 4;
    const payloadLength = segLength - 2;
    if (payloadLength <= 0 || payloadStart + payloadLength > bytes.length) {
      return undefined;
    }
    return HdrIsoGainMap.parsePayload(bytes, payloadStart, payloadLength);
  }

  /** 直接解析已定位到起点的载荷（便于测试与诊断）。 */
  static parsePayload(bytes: Uint8Array, payloadStart: number, payloadLength: number): IsoGainMapMetadata | undefined {
    // 版本信息只有 4 字节（主图那种）。
    if (payloadLength < URN_BYTES + 4) {
      return undefined;
    }
    const minimumVersion = readU16(bytes, payloadStart + URN_BYTES);
    const writerVersion = readU16(bytes, payloadStart + URN_BYTES + 2);
    if (payloadLength === URN_BYTES + 4) {
      return {
        minimumVersion: minimumVersion,
        writerVersion: writerVersion,
        multiChannel: false,
        useBaseColourSpace: false,
        baselineHdrCapacity: 0,
        alternateHdrHeadroom: 0,
        channels: [],
        payloadLength: payloadLength,
        versionOnly: true
      };
    }
    const flags = bytes[payloadStart + URN_BYTES + 4];
    const multiChannel = (flags & 0x80) !== 0;
    const useBaseColourSpace = (flags & 0x40) !== 0;
    let cursor = payloadStart + URN_BYTES + 5;
    const baselineHdrCapacity = rational(bytes, cursor);
    cursor += 8;
    const alternateHdrHeadroom = rational(bytes, cursor);
    cursor += 8;
    const groups: IsoGainMapChannel[] = [];
    const channelCount = multiChannel ? 3 : 1;
    for (let i = 0; i < channelCount; i++) {
      if (cursor + 40 > payloadStart + payloadLength) {
        // 结构不完整：宁可返回 undefined，也不要拿半截参数去误导解码器。
        return undefined;
      }
      const channel: IsoGainMapChannel = {
        gainMapMin: rational(bytes, cursor),
        gainMapMax: rational(bytes, cursor + 8),
        gamma: rational(bytes, cursor + 16),
        baseOffset: rational(bytes, cursor + 24),
        alternateOffset: rational(bytes, cursor + 32)
      };
      groups.push(channel);
      cursor += 40;
    }
    return {
      minimumVersion: minimumVersion,
      writerVersion: writerVersion,
      multiChannel: multiChannel,
      useBaseColourSpace: useBaseColourSpace,
      baselineHdrCapacity: baselineHdrCapacity,
      alternateHdrHeadroom: alternateHdrHeadroom,
      channels: groups,
      payloadLength: payloadLength,
      versionOnly: false
    };
  }

  /**
   * 翻译成 Adobe `hdrgm:` 属性串（含命名空间声明），值取自标准字段，与真实文件写法对齐：
   *
   * | ISO 21496-1 | Adobe hdrgm |
   * | --- | --- |
   * | `gain_map_min` | `GainMapMin` |
   * | `gain_map_max` | `GainMapMax` |
   * | `gamma` | `Gamma` |
   * | `base_offset` | `OffsetSDR` |
   * | `alternate_offset` | `OffsetHDR` |
   * | `baseline_hdr_capacity` | `HDRCapacityMin` |
   * | `alternate_hdr_headroom` | `HDRCapacityMax` |
   *
   * `BaseRenditionIsHDR` 恒为 `False`：我们的基础图永远是完整 SDR 图（增益图方案的前提）。
   * 多通道时 `hdrgm` 用逗号分隔的三个值（Adobe 规范写法）。
   *
   * `HDRCapacityMax` 取 `max(alternate_hdr_headroom, gain_map_max)`：真机 OPPO/Pixel 文件里这两个
   * 值相等（`GainMapMax == HDRCapacityMax`），而华为那份 ISO 数据里 2.148445 比 2.169925 小 1%
   * （编码取整）。Adobe 侧语义要求「容量不小于增益图最大值」，所以取两者较大的那个，避免严格
   * 校验器判为自相矛盾。
   */
  static toHdrgmAttributes(metadata: IsoGainMapMetadata): string {
    if (metadata.versionOnly || metadata.channels.length === 0) {
      return '';
    }
    const join = (pick: (channel: IsoGainMapChannel) => number): string => {
      const parts: string[] = [];
      for (const channel of metadata.channels) {
        parts.push(formatAttributeValue(pick(channel)));
      }
      return parts.join(', ');
    };
    let capacityMax = metadata.alternateHdrHeadroom;
    for (const channel of metadata.channels) {
      if (channel.gainMapMax > capacityMax) {
        capacityMax = channel.gainMapMax;
      }
    }
    return ' xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/"'
      + ' hdrgm:Version="1.0"'
      + ' hdrgm:GainMapMin="' + join((c: IsoGainMapChannel): number => c.gainMapMin) + '"'
      + ' hdrgm:GainMapMax="' + join((c: IsoGainMapChannel): number => c.gainMapMax) + '"'
      + ' hdrgm:Gamma="' + join((c: IsoGainMapChannel): number => c.gamma) + '"'
      + ' hdrgm:OffsetSDR="' + join((c: IsoGainMapChannel): number => c.baseOffset) + '"'
      + ' hdrgm:OffsetHDR="' + join((c: IsoGainMapChannel): number => c.alternateOffset) + '"'
      + ' hdrgm:HDRCapacityMin="' + formatAttributeValue(metadata.baselineHdrCapacity) + '"'
      + ' hdrgm:HDRCapacityMax="' + formatAttributeValue(capacityMax) + '"'
      + ' hdrgm:BaseRenditionIsHDR="False"';
  }

  /**
   * 从**增益图 JPEG** 里取出可用的 `hdrgm:` 属性串；取不到返回空串。
   *
   * 只在增益图里找：标准把参数放在增益图（主图那段 APP2 只有版本信息）。
   */
  static attributesFromGainMap(gainMapJpeg: Uint8Array): string {
    const metadata = HdrIsoGainMap.parse(gainMapJpeg, 0, gainMapJpeg.length);
    if (metadata === undefined) {
      return '';
    }
    return HdrIsoGainMap.toHdrgmAttributes(metadata);
  }

  /** 诊断用：一行摘要。 */
  static describe(metadata: IsoGainMapMetadata | undefined): string {
    if (metadata === undefined) {
      return '无 ISO 21496-1 元数据';
    }
    if (metadata.versionOnly) {
      return '只有版本信息（v' + metadata.minimumVersion + '/' + metadata.writerVersion + '，无参数）';
    }
    const c = metadata.channels[0];
    return 'flags=' + (metadata.multiChannel ? '多通道' : '单通道')
      + (metadata.useBaseColourSpace ? '/基准色空间' : '')
      + ' baseline=' + formatAttributeValue(metadata.baselineHdrCapacity)
      + ' headroom=' + formatAttributeValue(metadata.alternateHdrHeadroom)
      + ' min=' + formatAttributeValue(c.gainMapMin)
      + ' max=' + formatAttributeValue(c.gainMapMax)
      + ' gamma=' + formatAttributeValue(c.gamma)
      + ' offsets=' + formatAttributeValue(c.baseOffset) + '/' + formatAttributeValue(c.alternateOffset);
  }

  private static urnBytes(): Uint8Array {
    if (HdrIsoGainMap.urnCache === undefined) {
      const out = new Uint8Array(URN_BYTES);
      for (let i = 0; i < URN_TEXT.length; i++) {
        out[i] = URN_TEXT.charCodeAt(i);
      }
      HdrIsoGainMap.urnCache = out;
    }
    return HdrIsoGainMap.urnCache;
  }

  private static urnCache?: Uint8Array;
}
