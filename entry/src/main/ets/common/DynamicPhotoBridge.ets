import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileUri } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';
import { nativeExtractLivp } from 'libmta_core.so';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogCapture as Lg } from './LogCapture';
import { DynamicPhotoProbe, DynamicPhotoFormat, DynamicPhotoBytes } from './DynamicPhotoFormat';
import { HdrGainMap } from './HdrGainMap';
import { ByteUtils, readFileRange, isSandboxPath } from './ByteUtils';

/**
 * 动态图片 ↔ 鸿蒙动态照片的桥接。
 *
 * 发送方向（拆分）：
 *   1. 探测文件是否动态图片（XMP / SEF trailer / livp ZIP 等）；
 *   2. 把「图片段」与「视频段」分别落到应用缓存目录，变成一个普通图片 + 一个普通 MP4；
 *   3. 两个文件用相同 basename + `.dp` 标记配对，交给原有协议与接收端逻辑传输。
 *
 * 接收方向（还原）：
 *   1. 探测收到的图片是否为「非鸿蒙格式」动态图片（Google / 三星 / Apple / 国产厂商 / livp）；
 *   2. 提取其图片段与视频段，写入沙箱；
 *   3. 调用系统 photoAccessHelper，用 PhotoSubtype.MOVING_PHOTO 创建鸿蒙动态照片；
 *   4. 若应用没有写图库权限（ohos.permission.WRITE_IMAGEVIDEO 为 system_basic，普通应用通常
 *      拿不到），则登记到「待保存」列表，由 UI 用 SaveButton 安全控件在用户点击时完成保存。
 */

/** 拆分后用于配对视频文件的标记段：`IMG_0001.dp.mp4` 与 `IMG_0001.dp.jpg` 配对。 */
export const DYNAMIC_PHOTO_PAIR_MARKER = '.dp';

/** 发送侧拆分结果。 */
export interface DynamicPhotoSendResult {
  /** 是否需要按「图片 + 视频」两个文件发送。 */
  readonly split: boolean;
  readonly imagePath: string;
  readonly imageName: string;
  readonly imageSize: number;
  /** 拆出来的视频绝对路径；未拆分时为空串。 */
  readonly videoPath: string;
  readonly videoName: string;
  readonly videoSize: number;
  /** 探测结果，便于日志与 UI 展示（未拆分时为 none）。 */
  readonly probe: DynamicPhotoProbe;
}

/** 接收侧还原结果。 */
export interface DynamicPhotoRestoreResult {
  readonly restored: boolean;
  /** 已直接写入系统图库时，为新建资产的 uri。 */
  readonly assetUri: string;
  /** 需要用户点击 SaveButton 完成保存时为 true（此时 imagePath/videoPath 指向沙箱内的图片与视频）。 */
  readonly pendingSave: boolean;
  readonly imagePath: string;
  readonly videoPath: string;
  readonly probe: DynamicPhotoProbe;
  /** 失败原因（人类可读，用于日志/提示）。 */
  readonly error: string;
}

/** 待保存的动态照片（等待 UI 用 SaveButton 落库）。 */
export interface PendingDynamicPhoto {
  readonly title: string;
  readonly imagePath: string;
  readonly videoPath: string;
  readonly vendor: string;
  readonly createdAt: number;
}

/** 同批次收到的候选文件（用于把图片与它的视频配对）。 */
export interface ReceivedCandidate {
  readonly name: string;
  readonly path: string;
  readonly size: number;
}

/** 接收侧探测结果：探测结论 + 可能来自同批次配对的视频。 */
export interface ReceivedDynamicPhoto {
  readonly probe: DynamicPhotoProbe;
  readonly videoPath: string;
  readonly videoName: string;
  readonly videoSize: number;
}

const TAIL_BYTES = 256 * 1024;
const HEAD_BYTES = 256 * 1024;
/** 写出对端格式时允许整体读入内存的单个文件上限（图片/视频分别判断）。 */
const MAX_IN_MEMORY_BYTES = 96 * 1024 * 1024;

function failure(error: string): DynamicPhotoRestoreResult {
  const probe: DynamicPhotoProbe = {
    kind: 'none',
    imageFormat: 'unknown',
    imageOffset: 0,
    imageLength: -1,
    videoOffset: -1,
    videoLength: -1,
    imageExtension: '',
    videoExtension: '',
    vendor: ''
  };
  return {
    restored: false,
    assetUri: '',
    pendingSave: false,
    imagePath: '',
    videoPath: '',
    probe: probe,
    error: error
  };
}

interface ExtractedLivp {
  imageName: string;
  imageSize: number;
  videoName: string;
  videoSize: number;
}

export class DynamicPhotoBridge {
  private static splitSequence: number = 0;
  // ---------------------------------------------------------------------
  // 探测
  // ---------------------------------------------------------------------

  /** 读取文件头尾并探测是否为动态图片（不改动磁盘）。 */
  static async probePath(path: string, name: string, size: number): Promise<DynamicPhotoProbe> {
    const fallback: DynamicPhotoProbe = {
      kind: 'none',
      imageFormat: 'unknown',
      imageOffset: 0,
      imageLength: size,
      videoOffset: -1,
      videoLength: -1,
      imageExtension: DynamicPhotoFormat.extensionOf(name),
      videoExtension: '',
      vendor: ''
    };
    let fd = -1;
    try {
      const fileSize = size > 0 ? size : (await fs.stat(path)).size;
      fd = fs.openSync(path, fs.OpenMode.READ_ONLY).fd;
      const headLength = Math.min(fileSize, HEAD_BYTES);
      const head = await readFileRange(fd, 0, headLength);
      if (head.length === 0) {
        return fallback;
      }
      const tailLength = Math.min(fileSize, TAIL_BYTES);
      const tailStart = fileSize - tailLength;
      const tail = await readFileRange(fd, tailStart, tailLength);
      const probe = DynamicPhotoFormat.probe(name, head, tail.length > 0 ? tail : head,
        tail.length > 0 ? tailStart : 0, fileSize);
      // 解析层看不到视频头部时（视频比尾部窗口大得多）只能给出候选起点，这里定向复核。
      return await DynamicPhotoBridge.verifyVideoStart(fd, probe, fileSize, headLength, tailStart, name);
    } catch (error) {
      Lg.w('[DYNAMIC] probe failed: ' + (error instanceof Error ? error.message : JSON.stringify(error)));
      return fallback;
    } finally {
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (closeError) {
        }
      }
    }
  }

  /**
   * 定向复核「视频段起点」这个候选偏移：只读候选点附近的一小段字节，确认那里真的是
   * 一段 MP4 的开头（size + 'ftyp' + 可打印 brand + 后续是已知顶层 box）。
   *
   * 为什么必须复核：容器目录只声明各段长度，视频段的起点是算出来的。当视频远大于
   * 256KB 的尾部读取窗口时，解析层根本看不到视频头部，此时算出来的偏移必须回到磁盘上
   * 验一次 —— 否则一个算错的偏移会被原样当成视频段切出去。
   *
   * 复核不过时会在候选点附近做一次有界搜索（容差 ±2MB），仍然找不到就把整个探测结果
   * 降级为「不是动态图片」，避免产生错误的图片/视频切分。
   */
  private static async verifyVideoStart(
    fd: number,
    probe: DynamicPhotoProbe,
    fileSize: number,
    headLength: number,
    tailStart: number,
    name: string
  ): Promise<DynamicPhotoProbe> {
    if (probe.kind === 'none' || probe.videoOffset < 0) {
      return probe;
    }
    const offset = probe.videoOffset;
    // 已读窗口内（头部或尾部缓冲）的候选点，解析层已经用同一套判据复核过。
    if (offset < headLength || offset >= tailStart) {
      return probe;
    }
    const window = await readFileRange(fd, offset, Math.min(64, fileSize - offset));
    if (DynamicPhotoFormat.isMp4StartAt(window, offset, offset, fileSize)) {
      Lg.i('[DYNAMIC] video start verified at ' + offset + ' (' + name + ')');
      return probe;
    }
    const repaired = await DynamicPhotoBridge.findVideoStartNear(fd, offset, fileSize, headLength);
    if (repaired > 0) {
      Lg.i('[DYNAMIC] video start repaired ' + offset + ' -> ' + repaired + ' (' + name + ')');
      return {
        kind: probe.kind,
        imageFormat: probe.imageFormat,
        imageOffset: probe.imageOffset,
        imageLength: repaired,
        videoOffset: repaired,
        videoLength: fileSize - repaired,
        imageExtension: probe.imageExtension,
        videoExtension: 'mp4',
        vendor: probe.vendor
      };
    }
    Lg.w('[DYNAMIC] video start rejected at ' + offset + ' (' + name + '): no MP4 header nearby');
    return {
      kind: 'none',
      imageFormat: probe.imageFormat,
      imageOffset: 0,
      imageLength: fileSize,
      videoOffset: -1,
      videoLength: -1,
      imageExtension: DynamicPhotoFormat.extensionOf(name),
      videoExtension: '',
      vendor: ''
    };
  }

  /**
   * 以 `anchor` 为中心，在 ±2MB 内按块搜索最近的「MP4 起点」。
   * 分块读取（每块 64KB）而不是一次性读入，避免对大文件造成大内存占用。
   */
  private static async findVideoStartNear(fd: number, anchor: number, fileSize: number, headLength: number): Promise<number> {
    const reach = 2 * 1024 * 1024;
    const chunk = 64 * 1024;
    const lower = Math.max(headLength, anchor - reach);
    const upper = Math.min(fileSize, anchor + reach);
    const start = Math.max(lower, 0);
    if (upper - start < 16) {
      return -1;
    }
    let position = start;
    let best = -1;
    let bestDistance = Number.MAX_SAFE_INTEGER;
    while (position < upper) {
      const length = Math.min(chunk + 16, upper - position);
      const bytes = await readFileRange(fd, position, length);
      if (bytes.length < 16) {
        break;
      }
      for (let i = 0; i + 16 <= bytes.length; i++) {
        const absolute = position + i;
        if (!DynamicPhotoFormat.isMp4StartAt(bytes, position, absolute, fileSize)) {
          continue;
        }
        const distance = absolute > anchor ? absolute - anchor : anchor - absolute;
        if (distance < bestDistance) {
          bestDistance = distance;
          best = absolute;
        }
      }
      if (best >= 0 && best + chunk < position) {
        // 已经越过锚点且找到了更近的候选，再往后只会更远。
        break;
      }
      position += chunk;
    }
    return best;
  }

  // ---------------------------------------------------------------------
  // 发送方向：拆成 图片 + 视频
  // ---------------------------------------------------------------------

  /**
   * 若 `path` 是动态图片，则把图片段与视频段拆分到应用缓存目录（`cacheDir/dynamicphoto`），
   * 返回拆分结果；否则返回 split=false 且原样返回入参。
   */
  static async splitForSend(
    context: common.Context,
    path: string,
    name: string,
    size: number
  ): Promise<DynamicPhotoSendResult> {
    const probe = await DynamicPhotoBridge.probePath(path, name, size);
    const unchanged: DynamicPhotoSendResult = {
      split: false,
      imagePath: path,
      imageName: name,
      imageSize: size,
      videoPath: '',
      videoName: '',
      videoSize: 0,
      probe: probe
    };
    if (probe.kind === 'none') {
      return unchanged;
    }
    try {
      const dir = DynamicPhotoBridge.workDir(context);
      const base = DynamicPhotoBridge.cleanBaseName(name);
      const stamp = Date.now().toString(36) + '-' + (++DynamicPhotoBridge.splitSequence).toString(36);
      if (probe.kind === 'harmony-livp') {
        return await DynamicPhotoBridge.splitLivp(path, dir, base, probe);
      }
      return await DynamicPhotoBridge.splitEmbedded(path, name, size, dir, base, stamp, probe);
    } catch (error) {
      const message = error instanceof Error ? error.message : JSON.stringify(error);
      Lg.w('[DYNAMIC] split failed for ' + name + ': ' + message);
      return unchanged;
    }
  }

  /** 内嵌式（XMP / SEF trailer）：图片段可能带尾部视频，需要另存一份干净图片。 */
  private static async splitEmbedded(
    path: string,
    name: string,
    size: number,
    dir: string,
    base: string,
    stamp: string,
    probe: DynamicPhotoProbe
  ): Promise<DynamicPhotoSendResult> {
    if (probe.videoOffset < 0 || probe.videoLength <= 0) {
      return {
        split: false, imagePath: path, imageName: name, imageSize: size,
        videoPath: '', videoName: '', videoSize: 0, probe: probe
      };
    }
    const imageName = base + DYNAMIC_PHOTO_PAIR_MARKER + '.' + probe.imageExtension;
    const videoName = base + DYNAMIC_PHOTO_PAIR_MARKER + '.mp4';
    const imagePath = dir + '/' + stamp + '-' + imageName;
    const videoPath = dir + '/' + stamp + '-' + videoName;
    const imageEnd = probe.imageLength > 0 ? probe.imageLength : probe.videoOffset;
    const copied = await DynamicPhotoBridge.writeImageSegment(path, imagePath, imageEnd, probe.videoOffset);
    if (copied <= 0) {
      throw new Error('image segment copy failed');
    }
    const videoBytes = await DynamicPhotoBridge.copyRange(path, videoPath, probe.videoOffset, probe.videoLength);
    if (videoBytes <= 0) {
      throw new Error('video segment copy failed');
    }
    return {
      split: true,
      imagePath: imagePath,
      imageName: imageName,
      imageSize: copied,
      videoPath: videoPath,
      videoName: videoName,
      videoSize: videoBytes,
      probe: probe
    };
  }

  /** 解压 LIVP 的两份素材，支持视频条目位于 ZIP 后部及 Deflate 存储。 */
  private static async splitLivp(
    path: string, dir: string, base: string, probe: DynamicPhotoProbe
  ): Promise<DynamicPhotoSendResult> {
    const source = fs.openSync(path, fs.OpenMode.READ_ONLY);
    let target: string = '';
    try {
      target = fs.mkdtempSync(dir + '/livp-XXXXXX');
      const pair = JSON.parse(await nativeExtractLivp(source.fd, target)) as ExtractedLivp;
      const prefix = base + DYNAMIC_PHOTO_PAIR_MARKER + '.';
      return {
        split: true,
        imagePath: target + '/' + pair.imageName,
        imageName: prefix + DynamicPhotoFormat.extensionOf(pair.imageName),
        imageSize: pair.imageSize,
        videoPath: target + '/' + pair.videoName,
        videoName: prefix + DynamicPhotoFormat.extensionOf(pair.videoName),
        videoSize: pair.videoSize,
        probe: probe
      };
    } catch (error) {
      if (target.length > 0) { try { fs.rmdirSync(target); } catch (_error) {} }
      throw error as Error;
    } finally {
      fs.closeSync(source);
    }
  }

  /** 把整个文件（前 `size` 字节）复制到 `destination`，返回写入字节数。 */
  static async copyFile(source: string, destination: string, size: number): Promise<number> {
    return await DynamicPhotoBridge.copyRange(source, destination, 0, size);
  }

  /** 「主图 + 增益图」合并的内存上限；超过就退回普通裁剪（只丢 HDR，不影响文件可用性）。 */
  private static readonly MAX_GAINMAP_MERGE_BYTES = 64 * 1024 * 1024;

  /**
   * 写出动态图片的「图片半段」（`[0, imageEnd)`），并把紧随其后的 **HDR 增益图**一起带上。
   *
   * 为什么必须带：Ultra HDR 的动态照片是三段——主图 / **增益图** / 视频。图片段与视频段之间
   * 那段 JPEG 就是增益图。早期实现只拷 `[0, imageEnd)`，直接把它丢掉了：
   *  - HDR 信息在「拆分」这一步就没了（真机实测：OPPO 发到鸿蒙，相册不显示 HDR）；
   *  - 残留的 XMP 目录还声明着 `Item:Semantic="GainMap"`（以及 MotionPhoto）却找不到对应字节，
   *    属**悬空声明** —— 按目录切分的读取器会读到文件外。
   *
   * 现在把主图与增益图合成一张**自洽的 Ultra HDR JPEG**（容器目录重建为 Primary + GainMap、
   * 重建 MPF），视频另行单独发送/保存。合并失败一律退回普通裁剪（绝不因为 HDR 而拆不出文件）。
   */
  private static async writeImageSegment(
    path: string, imagePath: string, imageEnd: number, nextStart: number
  ): Promise<number> {
    const gap = nextStart - imageEnd;
    const mergeable = gap > 2 && imageEnd > 0
      && imageEnd + gap <= DynamicPhotoBridge.MAX_GAINMAP_MERGE_BYTES;
    if (!mergeable) {
      if (gap > 2) {
        Lg.w('[HDR] gainmap merge skipped: gap=' + gap + ' imageEnd=' + imageEnd);
      }
      return await DynamicPhotoBridge.copyRange(path, imagePath, 0, imageEnd);
    }
    let fd = -1;
    try {
      fd = fs.openSync(path, fs.OpenMode.READ_ONLY).fd;
      const head = await readFileRange(fd, imageEnd, 2);
      if (head.length < 2 || head[0] !== 0xff || head[1] !== 0xd8) {
        // 中间那段不是 JPEG（不是增益图）：按原样裁到图片段结尾。
        return await DynamicPhotoBridge.copyRange(path, imagePath, 0, imageEnd);
      }
      const base = await readFileRange(fd, 0, imageEnd);
      const gainMap = await readFileRange(fd, imageEnd, gap);
      const merged = HdrGainMap.writeDualJpegWithGainMap(base, gainMap, []);
      if (merged === undefined) {
        Lg.w('[HDR] gainmap merge failed, keep plain image segment: ' + imagePath);
        return await DynamicPhotoBridge.copyRange(path, imagePath, 0, imageEnd);
      }
      const opened = fs.openSync(imagePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        await fs.write(opened.fd, ByteUtils.toArrayBuffer(merged.bytes));
      } finally {
        fs.closeSync(opened);
      }
      Lg.i('[HDR] image half keeps gainmap: base=' + merged.baseLength
        + ' gainmap=' + merged.gainMapLength + ' xmp=' + merged.xmpAction);
      return merged.bytes.length;
    } catch (error) {
      Lg.w('[HDR] gainmap merge error, keep plain image segment: '
        + (error instanceof Error ? error.message : JSON.stringify(error)));
      return await DynamicPhotoBridge.copyRange(path, imagePath, 0, imageEnd);
    } finally {
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (closeError) {
        }
      }
    }
  }

  /** 从 `source` 的 [offset, offset+length) 区间拷贝到 `destination`，返回写入字节数。 */
  private static async copyRange(source: string, destination: string, offset: number, length: number): Promise<number> {
    let fd = -1;
    try {
      fd = fs.openSync(source, fs.OpenMode.READ_ONLY).fd;
      return await DynamicPhotoBridge.copyFdRange(fd, destination, offset, length);
    } finally {
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (closeError) {
        }
      }
    }
  }

  /** 从已打开的 fd 拷贝一段区间到 `destination`，返回写入字节数。 */
  private static async copyFdRange(fd: number, destination: string, offset: number, length: number): Promise<number> {
    const opened = fs.openSync(destination, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    let written = 0;
    try {
      const chunk = 1024 * 1024;
      let position = offset;
      let remaining = length;
      while (remaining > 0) {
        const take = Math.min(chunk, remaining);
        const bytes = await readFileRange(fd, position, take);
        if (bytes.length === 0) {
          break;
        }
        let sent = 0;
        while (sent < bytes.length) {
          const count = await fs.write(opened.fd, ByteUtils.toArrayBuffer(bytes.subarray(sent)));
          if (count <= 0 || count > bytes.length - sent) { throw new Error('动态照片片段写入不完整'); }
          sent += count;
        }
        written += sent;
        position += bytes.length;
        remaining -= bytes.length;
      }
    } finally {
      fs.closeSync(opened);
    }
    return written;
  }

  // ---------------------------------------------------------------------
  // 接收方向：还原成鸿蒙动态照片
  // ---------------------------------------------------------------------

  /**
   * 判断「本机已保存的图片」是否动态图片；返回探测结果与「候选视频路径」
   * （同批次收到的 `.dp.mp4` 或 Apple Live Photo 的 `.MOV` 同名视频）。
   */
  static async probeReceived(
    imagePath: string,
    imageName: string,
    imageSize: number,
    candidates: ReceivedCandidate[]
  ): Promise<ReceivedDynamicPhoto> {
    const probe = await DynamicPhotoBridge.probePath(imagePath, imageName, imageSize);
    if (probe.kind === 'harmony-livp' || (probe.kind !== 'none' && probe.videoOffset >= 0)) {
      return { probe: probe, videoPath: '', videoName: '', videoSize: 0 };
    }
    const key = await DynamicPhotoBridge.pairToken(imagePath, imageName, imageSize, false);
    if (key.length > 0) {
      let matched: ReceivedCandidate | undefined = undefined;
      for (const candidate of candidates) {
        if (!DynamicPhotoFormat.isVideoExtension(DynamicPhotoFormat.extensionOf(candidate.name))
          || await DynamicPhotoBridge.pairToken(candidate.path, candidate.name, candidate.size, true) !== key) {
          continue;
        }
        // 重复标识时无法知道要用哪一份；保留原始文件。
        if (matched !== undefined && matched.path !== candidate.path) {
          return { probe: probe, videoPath: '', videoName: '', videoSize: 0 };
        }
        matched = candidate;
      }
      if (matched !== undefined) {
        const apple = key.startsWith('apple:');
        return {
          probe: {
            kind: apple ? 'apple-live' : 'vendor-motion',
            imageFormat: probe.imageFormat,
            imageOffset: 0,
            imageLength: probe.imageLength,
            videoOffset: -1,
            videoLength: -1,
            imageExtension: probe.imageExtension,
            videoExtension: DynamicPhotoFormat.extensionOf(matched.name),
            vendor: apple ? 'Apple' : 'Generic'
          },
          videoPath: matched.path,
          videoName: matched.name,
          videoSize: matched.size
        };
      }
    }
    return { probe: probe, videoPath: '', videoName: '', videoSize: 0 };
  }

  /** .dp 是本应用写出的显式配对标记；Apple 必须两侧都读出同一个资产标识。 */
  static async pairToken(path: string, name: string, size: number, isVideo: boolean): Promise<string> {
    const base = DynamicPhotoFormat.baseNameOf(name).toLowerCase();
    if (base.endsWith(DYNAMIC_PHOTO_PAIR_MARKER)) {
      return 'dp:' + DynamicPhotoFormat.stripPairMarker(base);
    }
    const extension = DynamicPhotoFormat.extensionOf(name);
    if (isVideo && extension !== 'mov') {
      return '';
    }
    const info = await DynamicPhotoBridge.headTailOf(path, size);
    if (info === undefined) {
      return '';
    }
    const id = isVideo ? DynamicPhotoFormat.readMovContentIdentifier(info.holder, info.fileSize)
      : DynamicPhotoFormat.readImageContentIdentifier(info, info.fileSize, extension);
    return id.length >= 32 ? 'apple:' + id.trim().toUpperCase() : '';
  }

  /** 读文件头尾（各 256KB）拼成稀疏视图，供 Isobmff/MOV/EXIF 解析使用。 */
  static async headTailOf(path: string, size: number): Promise<DynamicPhotoBytes | undefined> {
    let fd = -1;
    try {
      const fileSize = size > 0 ? size : (await fs.stat(path)).size;
      fd = fs.openSync(path, fs.OpenMode.READ_ONLY).fd;
      const headLength = Math.min(fileSize, HEAD_BYTES);
      const head = await readFileRange(fd, 0, headLength);
      if (head.length === 0) {
        return undefined;
      }
      const tailLength = Math.min(fileSize, TAIL_BYTES);
      const tailStart = fileSize - tailLength;
      const tail = await readFileRange(fd, tailStart, tailLength);
      const holder = DynamicPhotoFormat.makeView(head, 0, tail.length > 0 ? tail : head,
        tail.length > 0 ? tailStart : 0);
      return { holder: holder, fileSize: fileSize, head: head, tail: tail, tailStart: tailStart };
    } catch (error) {
      Lg.w('[DYNAMIC] headTailOf failed: ' + (error instanceof Error ? error.message : JSON.stringify(error)));
      return undefined;
    } finally {
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (closeError) {
        }
      }
    }
  }

  /**
   * 把「图片 + 视频」还原为鸿蒙动态照片并写入系统图库。
   * 权限不足时返回 pendingSave=true（由 UI 用 SaveButton 完成保存）。
   */
  static async restore(
    context: common.Context,
    imagePath: string,
    videoPath: string,
    title: string
  ): Promise<DynamicPhotoRestoreResult> {
    try {
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      const extension = DynamicPhotoFormat.extensionOf(imagePath);
      const assetRequest = photoAccessHelper.MediaAssetChangeRequest.createAssetRequest(
        context,
        photoAccessHelper.PhotoType.IMAGE,
        extension.length > 0 ? extension : 'jpg',
        { title: title, subtype: photoAccessHelper.PhotoSubtype.MOVING_PHOTO });
      assetRequest.addResource(photoAccessHelper.ResourceType.IMAGE_RESOURCE, DynamicPhotoBridge.sandboxUri(imagePath));
      assetRequest.addResource(photoAccessHelper.ResourceType.VIDEO_RESOURCE, DynamicPhotoBridge.sandboxUri(videoPath));
      await helper.applyChanges(assetRequest);
      const uri = assetRequest.getAsset().uri;
      Lg.i('[DYNAMIC] moving photo saved uri=' + uri + ' title=' + title);
      return {
        restored: true,
        assetUri: uri,
        pendingSave: false,
        imagePath: imagePath,
        videoPath: videoPath,
        probe: DynamicPhotoBridge.emptyProbe(),
        error: ''
      };
    } catch (error) {
      const business = error as BusinessError;
      const code = business !== undefined && business.code !== undefined ? business.code : -1;
      const message = error instanceof Error ? error.message : JSON.stringify(error);
      Lg.w('[DYNAMIC] applyChanges failed code=' + code + ' msg=' + message);
      // 201 权限不足 / 13900012(10) 等：退化为「待用户点击保存」。
      return {
        restored: false,
        assetUri: '',
        pendingSave: true,
        imagePath: imagePath,
        videoPath: videoPath,
        probe: DynamicPhotoBridge.emptyProbe(),
        error: 'code=' + code + ' ' + message
      };
    }
  }

  /**
   * 沙箱路径转成 `addResource` 需要的沙箱 URI。
   *
   * 文档要求的形态是 `file://<bundleName>/data/storage/...`（`fileUri.getUriFromPath` 的产物）；
   * 早期实现直接拼成 `file:///data/storage/...`（三斜杠、缺 bundleName），系统会当作非法 URI。
   */
  static sandboxUri(path: string): string {
    if (path.startsWith('file://')) {
      return path;
    }
    try {
      return fileUri.getUriFromPath(path);
    } catch (error) {
      return 'file://' + (path.startsWith('/') ? path : '/' + path);
    }
  }

  /** 目标路径是否位于应用沙箱（addResource 只接受沙箱 URI）。 */
  static inSandbox(path: string): boolean {
    return isSandboxPath(path);
  }

  /**
   * 整体读入一个文件（写出动态图片格式时要在内存里重组字节）。
   *
   * 上限 `MAX_IN_MEMORY_BYTES`：超过就放弃转换、退回「图片 + 视频」拆分 ——
   * 手机内存经不起把几百 MB 的视频整个读进来。
   */
  static async readWholeFile(path: string, maxBytes: number): Promise<Uint8Array | undefined> {
    try {
      const size = fs.statSync(path).size;
      if (size <= 0 || size > maxBytes) {
        Lg.w('[DYNAMIC] readWholeFile skip ' + path + ' size=' + size + ' max=' + maxBytes);
        return undefined;
      }
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const buffer = new ArrayBuffer(size);
        const read = await fs.read(file.fd, buffer);
        const bytes = new Uint8Array(buffer);
        return read === size ? bytes : bytes.slice(0, Math.max(read, 0));
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      Lg.w('[DYNAMIC] readWholeFile failed ' + path + ': '
        + (error instanceof Error ? error.message : JSON.stringify(error)));
      return undefined;
    }
  }

  /** 把内存里的字节写成文件（覆盖）。 */
  static writeWholeFile(path: string, bytes: Uint8Array): number {
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, bytes.buffer);
        return bytes.length;
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      Lg.w('[DYNAMIC] writeWholeFile failed ' + path + ': '
        + (error instanceof Error ? error.message : JSON.stringify(error)));
      return 0;
    }
  }

  private static emptyProbe(): DynamicPhotoProbe {
    return {
      kind: 'none',
      imageFormat: 'unknown',
      imageOffset: 0,
      imageLength: -1,
      videoOffset: -1,
      videoLength: -1,
      imageExtension: '',
      videoExtension: '',
      vendor: ''
    };
  }

  // ---------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------

  /** 拆分产物的工作目录（应用缓存，避免污染用户目录）。 */
  static workDir(context: common.Context): string {
    const dir = context.cacheDir + '/dynamicphoto';
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    return dir;
  }

  /**
   * 「待用户点保存」的动态照片素材目录。
   *
   * 与 workDir 的区别：workDir 在 cacheDir，系统可能在应用后台时清理掉；而待保存素材要一直
   * 等到用户点 SaveButton（可能是几分钟后），因此必须落在 filesDir 这种持久目录里。
   */
  static pendingDir(context: common.Context): string {
    const dir = context.filesDir + '/dynamicphoto-pending';
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    return dir;
  }

  /** 清理动态图片临时文件（按修改时间，保留最近 maxAgeMs 内产生的）。 */
  static cleanupWorkDir(context: common.Context, maxAgeMs: number = 24 * 60 * 60 * 1000): number {
    const dir = context.cacheDir + '/dynamicphoto';
    let removed = 0;
    try {
      if (!fs.accessSync(dir)) {
        return 0;
      }
      const names = fs.listFileSync(dir);
      const now = Date.now();
      for (const item of names) {
        const full = dir + '/' + item;
        try {
          const stat = fs.statSync(full);
          if (now - stat.mtime * 1000 > maxAgeMs) {
            if (stat.isDirectory()) { fs.rmdirSync(full); }
            else { fs.unlinkSync(full); }
            removed += 1;
          }
        } catch (itemError) {
        }
      }
    } catch (error) {
      Lg.w('[DYNAMIC] cleanup failed: ' + JSON.stringify(error));
    }
    return removed;
  }

  /** 文件名去掉非法字符，并去掉扩展名与配对标记，作为拆分产物的 basename。 */
  private static cleanBaseName(name: string): string {
    const base = DynamicPhotoFormat.baseNameOf(name);
    const sanitized = base.replace(/[\\/:*?"<>|]/g, '_').trim();
    const trimmed = DynamicPhotoFormat.stripPairMarker(sanitized);
    return trimmed.length > 0 ? trimmed : 'dynamicphoto';
  }
}
