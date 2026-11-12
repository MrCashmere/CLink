/**
 * 动图视频的 MP4 处理：**把 `moov` 搬到 `mdat` 前面**（faststart），不改一帧像素。
 *
 * 为什么要做（2026-09-10）：修好增益图参数后，**Google 相册认了动图，但 OPPO 相册还是不认**。
 * 把各家真实动图视频的顶层盒子顺序摆出来看：
 *
 * | 来源 | 盒子顺序 |
 * | --- | --- |
 * | OPPO 自家动图（网上样本） | `ftyp moov free mdat`（**moov 在前**） |
 * | 小米自家动图（网上样本） | `ftyp moov free mdat`（**moov 在前**） |
 * | 我们从鸿蒙动态照片提取的视频 | `ftyp free mdat moov`（moov 在最后） |
 * | Pixel 自家动图 | `ftyp mdat moov`（moov 在最后，Google 自己不在乎） |
 *
 * moov 在末尾的 MP4 是**合法**的（播放器能 seek 到尾部再解），Google 相册也确实认；但国产相册
 * （ColorOS 这类）很可能**只前向解析**：读到 `mdat` 就当作媒体数据往下走，见到 moov 在最后就
 * 认为「这不是一个能直接播放的视频」。把顺序摆成与他们自家文件一致，是最省事也最可靠的兼容手段。
 *
 * 变换本身是**纯字节搬运**：把 `moov` 整体移到 `mdat` 之前，同时把 `moov` 里
 * `stco`/`co64`（chunk 偏移表，值都是**文件绝对偏移**）里的每个偏移加上 `moov` 的字节数。
 *
 * 安全边界（宁可原样返回，也不冒险破坏视频）：
 *  - 没有 `moov` / 没有 `mdat` → 原样返回；
 *  - 已经是 moov 在前 → 原样返回（幂等）；
 *  - 分片 MP4（有 `moof`/`mfra`，偏移语义不同）→ 原样返回；
 *  - 找不到 `stco`/`co64` → 原样返回；
 *  - **任何一个 chunk 偏移不落在 `mdat` 内** → 原样返回（说明还有别的数据源，盲移必然写坏）。
 */

/** MP4 顶层盒子。 */
export interface Mp4Box {
  readonly type: string;
  readonly start: number;
  /** 整个盒子的字节数（含头部）。 */
  readonly size: number;
  /** 头部字节数：8 = 普通，16 = 64 位 largesize。 */
  readonly header: number;
}

export interface Mp4FaststartResult {
  readonly bytes: Uint8Array;
  /** 是否真的搬动过。 */
  readonly moved: boolean;
  /** 原因：`already-faststart` / `moved` / `no-moov` / `no-mdat` / `fragmented` / `no-chunk-offsets` / `offset-outside-mdat` … */
  readonly reason: string;
  /** 视频时长（微秒）；解析不出来为 -1。 */
  readonly durationUs: number;
}

/** 可以继续往下钻的容器盒子（只有这些盒子内部还是盒子）。 */
const CONTAINER_TYPES: string[] = [
  'moov', 'trak', 'mdia', 'minf', 'stbl', 'edts', 'mvex', 'udta', 'dinf', 'meta', 'ipro'
];

function readU32(bytes: Uint8Array, at: number): number {
  return (((bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3]) >>> 0);
}

function readU64(bytes: Uint8Array, at: number): number {
  // 视频文件不会到 2^53，用 Number 足够；分两次读避免大整数 API 差异。
  const high = readU32(bytes, at);
  const low = readU32(bytes, at + 4);
  return high * 4294967296 + low;
}

function fourCc(bytes: Uint8Array, at: number): string {
  let out = '';
  for (let i = 0; i < 4; i++) {
    const code = bytes[at + i];
    // 只接受可打印 ASCII：二进制数据被误当盒子类型时能立刻看出来。
    if (code < 0x20 || code > 0x7e) {
      return '';
    }
    out += String.fromCharCode(code);
  }
  return out;
}

export class HdrMp4 {
  /** 列出顶层盒子；遇到尺寸自相矛盾的盒子就停在那里（返回已解析的部分）。 */
  static topLevelBoxes(bytes: Uint8Array): Mp4Box[] {
    const out: Mp4Box[] = [];
    let at = 0;
    let guard = 0;
    while (at + 8 <= bytes.length && guard < 256) {
      guard++;
      let size = readU32(bytes, at);
      const type = fourCc(bytes, at + 4);
      let header = 8;
      if (size === 1) {
        if (at + 16 > bytes.length) {
          break;
        }
        size = readU64(bytes, at + 8);
        header = 16;
      } else if (size === 0) {
        size = bytes.length - at;
      }
      if (type.length === 0 || size < header || at + size > bytes.length) {
        break;
      }
      out.push({ type: type, start: at, size: size, header: header });
      at += size;
    }
    return out;
  }

  /** `mvhd` 里的时长（微秒）；解析不出来返回 -1。 */
  static durationUs(bytes: Uint8Array): number {
    const boxes = HdrMp4.topLevelBoxes(bytes);
    let moov: Mp4Box | undefined = undefined;
    for (const box of boxes) {
      if (box.type === 'moov') {
        moov = box;
        break;
      }
    }
    if (moov === undefined) {
      return -1;
    }
    const children = HdrMp4.childBoxes(bytes, moov);
    for (const child of children) {
      if (child.type !== 'mvhd') {
        continue;
      }
      const version = bytes[child.start + child.header];
      if (version === 1) {
        const timescale = readU32(bytes, child.start + child.header + 20);
        const duration = readU64(bytes, child.start + child.header + 24);
        return timescale === 0 ? -1 : Math.round(duration / timescale * 1000000);
      }
      const timescale = readU32(bytes, child.start + child.header + 12);
      const duration = readU32(bytes, child.start + child.header + 16);
      return timescale === 0 ? -1 : Math.round(duration / timescale * 1000000);
    }
    return -1;
  }

  /** 某个盒子的直接子盒子（`meta` 是 FullBox，子盒子从 +4 开始）。 */
  static childBoxes(bytes: Uint8Array, parent: Mp4Box): Mp4Box[] {
    const out: Mp4Box[] = [];
    let at = parent.start + parent.header;
    if (parent.type === 'meta') {
      at += 4;
    }
    const end = parent.start + parent.size;
    let guard = 0;
    while (at + 8 <= end && guard < 4096) {
      guard++;
      let size = readU32(bytes, at);
      const type = fourCc(bytes, at + 4);
      let header = 8;
      if (size === 1) {
        if (at + 16 > end) {
          break;
        }
        size = readU64(bytes, at + 8);
        header = 16;
      } else if (size === 0) {
        size = end - at;
      }
      if (type.length === 0 || size < header || at + size > end) {
        break;
      }
      out.push({ type: type, start: at, size: size, header: header });
      at += size;
    }
    return out;
  }

  /**
   * 把 `moov` 移到 `mdat` 之前（faststart），并同步平移 chunk 偏移表。
   *
   * 见文件头注释里的安全边界：只要有一点不确定就**原样返回**（`moved: false` + `reason`）。
   */
  static makeFaststart(video: Uint8Array): Mp4FaststartResult {
    const durationUs = HdrMp4.durationUs(video);
    const boxes = HdrMp4.topLevelBoxes(video);
    let moov: Mp4Box | undefined = undefined;
    let mdat: Mp4Box | undefined = undefined;
    for (const box of boxes) {
      if (box.type === 'moov' && moov === undefined) {
        moov = box;
      }
      if (box.type === 'mdat' && mdat === undefined) {
        mdat = box;
      }
      if (box.type === 'moof' || box.type === 'mfra') {
        return { bytes: video, moved: false, reason: 'fragmented', durationUs: durationUs };
      }
    }
    if (moov === undefined) {
      return { bytes: video, moved: false, reason: 'no-moov', durationUs: durationUs };
    }
    if (mdat === undefined) {
      return { bytes: video, moved: false, reason: 'no-mdat', durationUs: durationUs };
    }
    if (moov.start < mdat.start) {
      return { bytes: video, moved: false, reason: 'already-faststart', durationUs: durationUs };
    }

    // 收集 moov 里所有 chunk 偏移表（stco = 32 位，co64 = 64 位）。
    const offsets: ChunkOffsetTable[] = [];
    HdrMp4.collectChunkOffsets(video, moov, offsets);
    if (offsets.length === 0) {
      return { bytes: video, moved: false, reason: 'no-chunk-offsets', durationUs: durationUs };
    }
    const mdatStart = mdat.start;
    const mdatEnd = mdat.start + mdat.size;
    let total = 0;
    for (const table of offsets) {
      for (const value of table.values) {
        if (value < mdatStart || value >= mdatEnd) {
          return { bytes: video, moved: false, reason: 'offset-outside-mdat', durationUs: durationUs };
        }
        total++;
      }
    }
    if (total === 0) {
      return { bytes: video, moved: false, reason: 'no-chunk-offsets', durationUs: durationUs };
    }

    const shift = moov.size;
    // moov 的新位置 = 「mdat 之前所有盒子」的字节数之和（moov 就插在 mdat 前面）。
    let newMoovStart = 0;
    for (const box of boxes) {
      if (box.start >= mdat.start) {
        break;
      }
      newMoovStart += box.size;
    }
    const out = new Uint8Array(video.length);
    // 1) 重排：mdat 之前的所有盒子（原序）+ moov + mdat + mdat 之后除 moov 之外的盒子（原序）
    let at = 0;
    for (const box of boxes) {
      if (box.type === 'moov') {
        continue;
      }
      if (box.start === mdat.start) {
        out.set(video.subarray(moov.start, moov.start + moov.size), at);
        at += moov.size;
      }
      out.set(video.subarray(box.start, box.start + box.size), at);
      at += box.size;
    }
    if (at !== video.length) {
      // 有未解析的尾巴（`topLevelBoxes` 提前停下）：原样返回，别拼出一个残缺文件。
      return { bytes: video, moved: false, reason: 'trailing-unparsed', durationUs: durationUs };
    }
    // 2) 平移 chunk 偏移（它们指向 mdat 内部，mdat 整体右移了 shift 字节）。
    //    ⚠️ 偏移表本身随 moov 一起搬了家：写入位置要按**新**的 moov 起点换算，
    //    否则会把字节写进文件里别的数据段（写坏视频）。
    const moovShift = newMoovStart - moov.start;
    for (const table of offsets) {
      for (let i = 0; i < table.values.length; i++) {
        const value = table.values[i] + shift;
        const entryAt = table.entriesAt + moovShift + i * table.entryWidth;
        if (table.entryWidth === 8) {
          const high = Math.floor(value / 4294967296);
          const low = value % 4294967296;
          out[entryAt] = (high >>> 24) & 0xff;
          out[entryAt + 1] = (high >>> 16) & 0xff;
          out[entryAt + 2] = (high >>> 8) & 0xff;
          out[entryAt + 3] = high & 0xff;
          out[entryAt + 4] = (low >>> 24) & 0xff;
          out[entryAt + 5] = (low >>> 16) & 0xff;
          out[entryAt + 6] = (low >>> 8) & 0xff;
          out[entryAt + 7] = low & 0xff;
        } else {
          out[entryAt] = (value >>> 24) & 0xff;
          out[entryAt + 1] = (value >>> 16) & 0xff;
          out[entryAt + 2] = (value >>> 8) & 0xff;
          out[entryAt + 3] = value & 0xff;
        }
      }
    }
    return { bytes: out, moved: true, reason: 'moved', durationUs: durationUs };
  }

  /** 诊断用：盒子顺序摘要。 */
  static describe(bytes: Uint8Array): string {
    const boxes = HdrMp4.topLevelBoxes(bytes);
    const parts: string[] = [];
    for (const box of boxes) {
      parts.push(box.type + '(' + box.size + ')');
    }
    const duration = HdrMp4.durationUs(bytes);
    return parts.join(' ')
      + (duration >= 0 ? ' 时长=' + (duration / 1000000).toFixed(3) + 's' : ' 时长=?');
  }

  /** 递归收集 stco/co64（只在容器盒子里钻，避免把码流数据当盒子）。 */
  private static collectChunkOffsets(bytes: Uint8Array, parent: Mp4Box, out: ChunkOffsetTable[]): void {
    for (const child of HdrMp4.childBoxes(bytes, parent)) {
      if (child.type === 'stco' || child.type === 'co64') {
        const entryWidth = child.type === 'co64' ? 8 : 4;
        const count = readU32(bytes, child.start + child.header + 4);
        const entriesAt = child.start + child.header + 8;
        if (entriesAt + count * entryWidth > child.start + child.size) {
          continue;
        }
        const values: number[] = [];
        for (let i = 0; i < count; i++) {
          values.push(entryWidth === 8
            ? readU64(bytes, entriesAt + i * entryWidth)
            : readU32(bytes, entriesAt + i * entryWidth));
        }
        out.push({ entriesAt: entriesAt, entryWidth: entryWidth, values: values });
        continue;
      }
      if (CONTAINER_TYPES.indexOf(child.type) >= 0) {
        HdrMp4.collectChunkOffsets(bytes, child, out);
      }
    }
  }
}

/** 一张 chunk 偏移表在文件里的位置与内容（用于平移）。 */
interface ChunkOffsetTable {
  readonly entriesAt: number;
  readonly entryWidth: number;
  readonly values: number[];
}
