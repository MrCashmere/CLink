/**
 * HDR 图片的发送侧编排（阶段 1：**不重编码**）。
 *
 * 对应 `docs/HDR_IMAGE.md` 的决策与阶段 1：
 *  - HDR 走「增益图（双层）」：基础层是完整 SDR 图，HDR 是附加层 → 只有一端支持 HDR 时两端都正常；
 *  - EXIF 走「不重编码」：字节级搬排，基础图的 EXIF 原样保留；
 *  - 对端是老设备 / Windows 时**只发基础层**（剥掉增益图并同步删掉容器目录声明）。
 *
 * 本模块是纯编排：真正的字节逻辑在 `HdrGainMap` / `HdrExifPreserve`（都有 Node 回归）。
 * 接收端只在完整文件仍位于应用沙箱时，用校验成功的转换产物替换源路径。
 */

import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import fs from '@ohos.file.fs';
import { LogCapture as Lg } from './LogCapture';
import { SettingsStore } from './SettingsStore';
import { HdrExifPreserve } from './HdrExifPreserve';
import { HdrGainMap, HdrLayerSplit, HdrExtraLayer } from './HdrGainMap';
import { HdrPhotoProbe, HdrProbeResult } from './HdrPhotoProbe';
import { HdrMp4 } from './HdrMp4';

/** 发送前的目标形态。 */
export type HdrTarget = 'keep' | 'dual-jpeg' | 'base-only' | 'vivid';

/** 一个待发送文件（与 `model/TransferModels.OutgoingFile` 同形，避免此处依赖 model 层）。 */
export interface HdrOutgoingFile {
  readonly path: string;
  readonly name: string;
  readonly size: number;
  readonly mime: string;
}

/** 重排结果。 */
export interface HdrRewriteResult {
  readonly files: HdrOutgoingFile[];
  readonly action: string;
  readonly note: string;
}

const MAX_REWRITE_BYTES = 96 * 1024 * 1024;

/** 工作目录（缓存，避免污染用户目录；与动态照片用的目录区分开）。 */
function workDir(context: common.Context): string {
  const dir = context.cacheDir + '/hdrphoto';
  if (!fs.accessSync(dir)) {
    fs.mkdirSync(dir, true);
  }
  return dir;
}

export class HdrPhotoService {
  /** 接收端统一转换；只处理确有增益图的照片，保留内嵌视频。 */
  static async prepareForLocal(context: common.Context, path: string,
    name: string, size: number): Promise<string | undefined> {
    if (!HdrPhotoService.enabled() || size <= 0 || size > MAX_REWRITE_BYTES) { return undefined; }
    let source: fs.File | undefined = undefined;
    try {
      source = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const buffer = new ArrayBuffer(size);
      const count: number = await fs.read(source.fd, buffer);
      if (count !== size) { return undefined; }
      const layers: HdrLayerSplit = HdrGainMap.detectLayers(new Uint8Array(buffer), name, size);
      if (layers.gainMap === undefined) { return undefined; }
      // 系统打包器只保存图片；视频或厂商尾部只能无损重排，不能随重编码丢掉。
      let hasTrailing: boolean = false;
      for (const layer of layers.layers) {
        if (layer.end > layers.gainMap.end) { hasTrailing = true; }
      }
      if (!hasTrailing && !HdrPhotoService.skipSystemReencode()) {
        const reencoded: string | undefined = await HdrPhotoService.reencodeForLocal(context, path, name, size);
        if (reencoded !== undefined) { return reencoded; }
      }
      return await HdrPhotoService.toVividForLocal(context, path, name, size);
    } catch (error) {
      Lg.w('[HDR] receive conversion failed; keep original: ' + name + ' ' + String(error));
      return undefined;
    } finally {
      if (source !== undefined) { try { fs.closeSync(source); } catch (error) {} }
    }
  }

  /** 保持接收源路径不变，供图库与下载两种去向读取转换结果。 */
  static async convertReceivedInPlace(context: common.Context, path: string, name: string): Promise<void> {
    if (!HdrPhotoService.enabled() || !/\.(jpe?g|jpe)$/i.test(name)) { return; }
    if (!path.startsWith(context.filesDir + '/') && !path.startsWith(context.cacheDir + '/')) { return; }
    let converted: string | undefined = undefined;
    try {
      converted = await HdrPhotoService.prepareForLocal(context, path, name, fs.statSync(path).size);
      if (converted === undefined) { return; }
      // 原子替换已收齐的沙箱文件；失败时源文件仍在，继续按原方式保存。
      fs.renameSync(converted, path);
      Lg.i('[HDR] received photo converted: ' + name);
    } catch (error) {
      Lg.w('[HDR] replace failed; keep received original: ' + name + ' ' + String(error));
    } finally {
      if (converted !== undefined) {
        try { if (fs.accessSync(converted)) { fs.unlinkSync(converted); } } catch (error) {}
      }
    }
  }

  /**
   * 设置页「HDR照片转换为HDR Vivid格式」开关（**默认关**）。
   *
   * 关掉时本模块整个不介入发送链路（一个字节都不改）。
   */
  static enabled(): boolean {
    return SettingsStore.current().hdrVividEnabled === true;
  }

  /**
   * 设置页「照片EXIF信息保留」开关（**默认开**）。
   *
   * 关掉时改写会**删掉 EXIF**（拍摄时间/GPS/机型等隐私信息），只保留 ICC 等显示必需段。
   * EXIF 里的厂商 MakerNote 是 Apple 实况照片配对（tag 0x0011）等能力的载体，
   * 所以关掉它意味着「放弃这些元数据能力」——这是用户显式选择，日志会写出来。
   */
  static exifKeepEnabled(): boolean {
    return SettingsStore.current().photoExifKeep !== false;
  }

  /**
   * UI 标签「转换时保留原始画质」对应的行为开关（**默认关**）。
   *
   * 打开后**不再尝试系统 API 重编码**，直接走无损换壳（APP2 ISO 21496-1 URN + MPF 0x50000、
   * 像素字节原样）。真机实测（Mate 80 Pro Max）系统 `packToFile` 会把 JPEG 增益图丢掉，
   * 所以这条「优先」路径在本机只会白跑一趟；关着时先试一次、产物丢增益图就自动丢弃并退回无损。
   */
  static skipSystemReencode(): boolean {
    return SettingsStore.current().hdrSkipSystemReencode === true;
  }

  /**
   * 发送侧：把「HDR 图片（基础图 + 增益图）+ 视频」合成**一个**对端认得的 HDR 动态照片。
   *
   * 为什么需要它：真机实测（发到 OPPO）发现 HDR 是在发送这一步丢的 —— 只做普通的
   * `writeAndroidMotionPhoto` 时，XMP 容器目录里只剩 `Primary + MotionPhoto`、也没有
   * `hdrgm:Version`：增益图字节虽然还在（被算进 Primary 的长度里），但**没有任何声明**，
   * 对端自然按 SDR 显示（当天日志 `hdr=0`）。
   *
   * 这里按**真实 OPPO/小米文件的形态**写：一个 XMP 里三个容器项
   * （Primary + GainMap + MotionPhoto）+ `hdrgm:Version="1.0"` + **动图声明与厂商私有字段**
   * （`descriptionAttributes`），MPF 重建为「基础图 + 增益图」两条（增益图属性仍用 0x0，
   * 与真实 OPPO 文件一致），视频接在增益图之后。字节仍然零重编码。
   *
   * 补充踩坑（第二处）：早期这里只传 `LivePhotoWriter.buildMotionPhotoVendorAttributes()`
   * （纯厂商字段），于是 HDR 动态照片的 XMP 里**没有 `GCamera:MotionPhoto="1"` /
   * `GCamera:MicroVideo*`** —— 容器目录里有 MotionPhoto 项，但缺「这是动图」的显式声明，
   * Google 相册不按动态照片处理（真机实测：OPPO 相册看不到动态效果）。现在改传
   * `LivePhotoWriter.buildMotionPhotoAttributes()`，与普通动态照片路径共用同一份属性。
   *
   * @param descriptionAttributes `LivePhotoWriter.buildMotionPhotoAttributes()` 的产物
   *        （`GCamera` 动图声明 + 按对端方言给的厂商字段），拼进 HDR 的 rdf:Description。
   */
  static async composeHdrMotionPhoto(
    context: common.Context,
    imagePath: string,
    imageName: string,
    imageSize: number,
    videoBytes: Uint8Array,
    descriptionAttributes: string
  ): Promise<HdrOutgoingFile | undefined> {
    if (imageSize <= 0 || imageSize + videoBytes.length > MAX_REWRITE_BYTES) {
      return undefined;
    }
    let imageBytes: Uint8Array | undefined = undefined;
    try {
      const file = fs.openSync(imagePath, fs.OpenMode.READ_ONLY);
      try {
        const buffer = new ArrayBuffer(imageSize);
        const read = await fs.read(file.fd, buffer);
        imageBytes = read === imageSize ? new Uint8Array(buffer)
          : new Uint8Array(buffer.slice(0, Math.max(read, 0)));
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      Lg.w('[HDR] compose read failed: ' + imageName + ' '
        + (error instanceof Error ? error.message : JSON.stringify(error)));
      return undefined;
    }
    if (imageBytes === undefined) {
      return undefined;
    }
    const split: HdrLayerSplit = HdrGainMap.detectLayers(imageBytes, imageName, imageBytes.length);
    if (split.gainMap === undefined) {
      // 没有增益图：交给原来的普通封装路径（不是 HDR 照片）。
      return undefined;
    }
    const base = HdrPhotoService.exifKeepEnabled()
      ? imageBytes.slice(0, split.base !== undefined ? split.base.end : imageBytes.length)
      : HdrExifPreserve.dropSegments(
        imageBytes.slice(0, split.base !== undefined ? split.base.end : imageBytes.length), ['EXIF']);
    const gainMap = imageBytes.slice(split.gainMap.start, split.gainMap.end);
    // 追加前把视频的 `moov` 搬到前面（faststart）：OPPO / 小米自家动图视频都是这个布局，
    // 我们从鸿蒙动态照片提取出来的视频是 `moov` 在末尾 —— 真机实测「Google 相册认、OPPO 相册不认」。
    const layout = HdrMp4.makeFaststart(videoBytes);
    const embeddedVideo = layout.bytes;
    const extras: HdrExtraLayer[] = [{
      semantic: 'MotionPhoto', mime: 'video/mp4', bytes: embeddedVideo
    }];
    const written = HdrGainMap.writeDualJpegWithGainMap(base, gainMap, extras, descriptionAttributes);
    if (written === undefined) {
      Lg.w('[HDR] compose failed (writer): ' + imageName);
      return undefined;
    }
    const bytes = written.bytes;
    const problems = HdrGainMap.verifyDualJpeg(bytes, HdrGainMap.detectLayers(bytes, imageName, bytes.length));
    if (problems.length > 0) {
      Lg.w('[HDR] compose self-check failed, keep plain motion photo: ' + problems.join(','));
      return undefined;
    }
    const dir = workDir(context);
    const outName = HdrPhotoService.baseName(imageName) + '-hdr.jpg';
    const outPath = dir + '/' + Date.now().toString(36) + '-mp-' + outName;
    const size = HdrPhotoService.write(outPath, bytes);
    if (size <= 0) {
      return undefined;
    }
    Lg.i('[HDR] hdr motion photo written: ' + outName + ' ' + size + ' bytes base='
      + written.baseLength + ' gainmap=' + written.gainMapLength + ' video=' + embeddedVideo.length
      + ' videoLayout=' + layout.reason
      // 增益图参数来源：真机事故（下载到 OPPO 上「没有 HDR」）就是这里曾经只写 Version 没有参数。
      + ' gainmapMeta=' + written.gainMapMetadata);
    if (written.gainMapMetadata === 'none') {
      Lg.w('[HDR] 警告：增益图没有任何参数（既无 hdrgm 也无 ISO 21496-1），对端可能按 SDR 显示：'
        + imageName);
    }
    return { path: outPath, name: outName, size: size, mime: 'image/jpeg' };
  }

  /** 探测（仅日志，不改文件）；供发送前与「设置页诊断」调用。 */
  static async probe(context: common.Context, path: string, name: string, size: number): Promise<HdrProbeResult> {
    return HdrPhotoProbe.probeFile(context, path, name, size);
  }

  /**
   * 发送侧入口：按「设置开关 + 对端是否 HDR 感知」决定目标形态并改写。
   *
   * 返回 undefined = 不改动（开关关着 / 没有增益图 / 失败），调用方继续用原文件。
   * 只有「带增益图的照片」（Apple 增益图照片、Android Ultra HDR）会被改写；
   * 纯 SDR 照片与 HEIC 不处理（纯 SDR → HDR 需要 VPE 的 C API，见 docs/HDR_IMAGE.md §2.4）。
   */
  static async rewriteForSend(
    context: common.Context,
    path: string,
    name: string,
    size: number,
    peerHdrAware: boolean,
    harmonyPeer: boolean = false
  ): Promise<HdrRewriteResult | undefined> {
    if (!HdrPhotoService.enabled()) {
      return undefined;
    }
    const target: HdrTarget = HdrPhotoService.targetForPeer(peerHdrAware, harmonyPeer);
    return await HdrPhotoService.rewriteForTarget(context, path, name, size, target);
  }

  /**
   * 接收侧入口（**系统 API 重编码**）：把收到的 HDR 照片用系统 image kit 重新打包成
   * 鸿蒙认的 HDR 文件，返回新文件路径；任何一步失败返回 undefined（调用方退回原文件）。
   *
   * 为什么除了「无损换壳」还要这条路：华为/鸿蒙认 HDR 的判据（APP2 ISO 21496-1 URN +
   * MPF attribute 0x50000）我们已经能无损对齐，但真机在增益图后还有一段相机私有的
   * HDR Vivid 元数据块，我们造不出来 —— 若它同样是判据的一部分，就只能让**系统自己**重写：
   * 解码成 `Picture`（带 GAINMAP 辅助图）→ `packToFile(picture, { desiredDynamicRange: AUTO,
   * needsPackProperties: true })`。这条路会重编码像素，所以有画质/体积代价（用户已确认接受）。
   *
   * `desiredDynamicRange` 在本 SDK 只有 `AUTO`/`SDR` 两个值：AUTO 让打包器按 Picture 自身的
   * HDR 意图决定；显式写 SDR 会把 HDR 拍平，所以这里用 AUTO。
   *
   * 打包前后各打一行 `[HDR] probe …`，直接对比 `isHdr` / `gainmapAux` 是否从 false 变 true ——
   * 这是判断「系统认不认」的唯一硬证据。
   */
  static async reencodeForLocal(
    context: common.Context,
    path: string,
    name: string,
    size: number
  ): Promise<string | undefined> {
    if (size <= 0 || size > MAX_REWRITE_BYTES) {
      return undefined;
    }
    const dir = workDir(context);
    const outName = HdrPhotoService.baseName(name) + '-hdr.jpg';
    const outPath = dir + '/' + Date.now().toString(36) + '-' + outName;
    let source: image.ImageSource | undefined = undefined;
    let picture: image.Picture | undefined = undefined;
    let packer: image.ImagePacker | undefined = undefined;
    let outFile: fs.File | undefined = undefined;
    try {
      source = image.createImageSource(path);
      if (source === undefined) {
        Lg.w('[HDR] reencode: createImageSource failed for ' + name);
        return undefined;
      }
      const decodeOptions: image.DecodingOptionsForPicture = {
        desiredAuxiliaryPictures: [image.AuxiliaryPictureType.GAINMAP]
      };
      picture = await source.createPicture(decodeOptions);
      if (picture === undefined) {
        Lg.w('[HDR] reencode: createPicture failed for ' + name);
        return undefined;
      }
      // 诊断：解码出来的 Picture 到底有没有把增益图带出来（没有的话打包必然写不出 HDR）。
      let auxPresent = false;
      try {
        const aux = picture.getGainmapPixelmap();
        auxPresent = aux !== null && aux !== undefined;
      } catch (auxError) {
        auxPresent = false;
      }
      const info = await source.getImageInfo();
      Lg.i('[HDR] reencode decode: ' + name + ' isHdr=' + (info.isHdr === true)
        + ' gainmapAux=' + auxPresent);
      packer = image.createImagePacker();
      outFile = fs.openSync(outPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const packOptions: image.PackingOption = {
        format: 'image/jpeg',
        quality: 100,
        desiredDynamicRange: image.PackingDynamicRange.AUTO,
        needsPackProperties: true
      };
      await packer.packToFile(picture, outFile.fd, packOptions);
      const produced = fs.statSync(outFile.fd).size;
      if (produced <= 0) {
        Lg.w('[HDR] reencode: empty output for ' + name);
        return undefined;
      }
      // **必须校验**：真机实测（Mate 80 Pro Max）packToFile 会把增益图丢掉 —— 输出是纯 SDR 且更大
      // （日志：`isHdr=false gainmapAux=false … layers=1`）。这种产物比原图更差，直接丢弃，
      // 交给无损换壳；绝不能让「重编码」把 HDR 悄悄拍平。
      let keepsGainMap = false;
      try {
        const producedBytes = new Uint8Array(produced);
        const fdRead = fs.openSync(outPath, fs.OpenMode.READ_ONLY);
        try {
          const buffer = new ArrayBuffer(produced);
          const read = await fs.read(fdRead.fd, buffer);
          const slice = read === produced ? new Uint8Array(buffer)
            : new Uint8Array(buffer.slice(0, Math.max(read, 0)));
          producedBytes.set(slice, 0);
        } finally {
          fs.closeSync(fdRead);
        }
        const after = HdrGainMap.detectLayers(producedBytes, outName, producedBytes.length);
        keepsGainMap = after.gainMap !== undefined;
        Lg.i('[HDR] reencode output layers: ' + HdrGainMap.describe(after, outName));
      } catch (checkError) {
        Lg.w('[HDR] reencode output check failed: '
          + (checkError instanceof Error ? checkError.message : JSON.stringify(checkError)));
        keepsGainMap = false;
      }
      if (!keepsGainMap) {
        Lg.w('[HDR] reencode dropped the gainmap (system packer wrote SDR), discard: ' + outName
          + ' ' + produced + ' bytes');
        try {
          fs.unlinkSync(outPath);
        } catch (unlinkError) {
        }
        return undefined;
      }
      Lg.i('[HDR] reencoded for local gallery: ' + name + ' -> ' + outName + ' ' + produced
        + ' bytes (source ' + size + ')');
      return outPath;
    } catch (error) {
      Lg.w('[HDR] reencode failed for ' + name + ': '
        + (error instanceof Error ? error.message : JSON.stringify(error)));
      return undefined;
    } finally {
      if (outFile !== undefined) {
        try {
          fs.closeSync(outFile);
        } catch (closeError) {
        }
      }
      if (packer !== undefined) {
        try {
          packer.release();
        } catch (releaseError) {
        }
      }
      if (picture !== undefined) {
        try {
          picture.release();
        } catch (releaseError) {
        }
      }
      if (source !== undefined) {
        try {
          source.release();
        } catch (releaseError) {
        }
      }
    }
  }

  /**
   * 接收侧入口：把收到的 HDR 照片（带增益图）转成**本机（鸿蒙）认的形态**，返回新文件路径。
   *
   * 落库前的这一步是必须的：OPPO/Apple/Google 的 Ultra HDR 写的是 XMP（`hdrgm`/`Container`）
   * + MPF attribute 0x0，而鸿蒙认的是 APP2 的 ISO 21496-1 URN + MPF attribute 0x50000
   * （真机 Mate 80 Pro Max 实测）。两者数据相同、只是外壳不同，所以转换是**零重编码**的。
   *
   * 返回 undefined = 不改动（开关关着 / 没有增益图 / 自检不过），调用方继续用原文件。
   */
  static async toVividForLocal(
    context: common.Context,
    path: string,
    name: string,
    size: number
  ): Promise<string | undefined> {
    if (!HdrPhotoService.enabled()) {
      return undefined;
    }
    const result = await HdrPhotoService.rewriteForTarget(context, path, name, size, 'vivid');
    if (result === undefined || result.files.length === 0) {
      return undefined;
    }
    Lg.i('[HDR] converted for local gallery (vivid): ' + name + ' -> ' + result.files[0].name);
    return result.files[0].path;
  }

  /**
   * 按目标形态重排一个文件。
   *
   * - `keep`：原样返回（调用方继续走原逻辑）；
   * - `dual-jpeg`：把「基础图 + 增益图」重排成标准双 JPEG（基础图字节原样，只补容器目录）；
   * - `base-only`：剥掉增益图（并删掉目录声明）。
   *
   * 返回 undefined 表示「不改动」（不是 JPEG、没有增益图、超过内存上限、或某步失败）——
   * 调用方应继续用原文件，绝不因为改写失败而影响发送。
   */
  static async rewriteForTarget(
    context: common.Context,
    path: string,
    name: string,
    size: number,
    target: HdrTarget
  ): Promise<HdrRewriteResult | undefined> {
    if (target === 'keep' || size <= 0 || size > MAX_REWRITE_BYTES) {
      return undefined;
    }
    let bytes: Uint8Array | undefined = undefined;
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const buffer = new ArrayBuffer(size);
        const read = await fs.read(file.fd, buffer);
        bytes = read === size ? new Uint8Array(buffer) : new Uint8Array(buffer.slice(0, Math.max(read, 0)));
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      Lg.w('[HDR] read failed: ' + name + ' '
        + (error instanceof Error ? error.message : JSON.stringify(error)));
      return undefined;
    }
    if (bytes === undefined) {
      return undefined;
    }
    const split: HdrLayerSplit = HdrGainMap.detectLayers(bytes, name, bytes.length);
    Lg.i('[HDR] rewrite ' + name + ' target=' + target + ' | ' + HdrGainMap.describe(split, name));
    if (split.gainMap === undefined) {
      // 没有增益图：没有可搬的 HDR 附加层（纯 SDR 或 HEIC 等本轮不处理的容器）。
      Lg.i('[HDR] no gainmap layer, keep original: ' + name + ' reason=' + split.reason);
      return undefined;
    }
    const base = HdrPhotoService.exifKeepEnabled()
      ? bytes.slice(0, split.base !== undefined ? split.base.end : bytes.length)
      // 「照片EXIF信息保留」关掉时删掉 EXIF（隐私模式）：只动元数据段，像素字节不变。
      : HdrExifPreserve.dropSegments(
        bytes.slice(0, split.base !== undefined ? split.base.end : bytes.length), ['EXIF']);
    if (!HdrPhotoService.exifKeepEnabled()) {
      Lg.i('[HDR] exif stripped on request: ' + name);
    }
    const gainMap = bytes.slice(split.gainMap.start, split.gainMap.end);
    // 增益图**之后**的附加段必须原样跟着走。真机 Ultra HDR 动态照片是三段共存
    // （Primary + GainMap + MotionPhoto，样本 `pixel-ultrahdr.jpg`），只搬前两段会把视频丢掉：
    // 动态照片退化成静态图，而且 XMP 目录声明的段与实际字节不再一致。
    const extras: HdrExtraLayer[] = [];
    let preservePrimaryLength: number = 0;
    for (const layer of split.layers) {
      if (layer.start < split.gainMap.end) {
        continue;
      }
      if (layer.kind === 'video' && layer.semantic === 'MotionPhoto') {
        extras.push({
          semantic: 'MotionPhoto', mime: 'video/mp4',
          bytes: bytes.slice(layer.start, layer.end)
        });
        continue;
      }
      // 本地 Vivid 转换保留厂商尾部的全部字节，并锁定附加层的原始绝对位置。
      // 例如 OPPO 普通 HDR 照片的水印数据；不能因它存在而跳过 HDR，也不能丢弃。
      if (target === 'vivid' && layer.kind === 'other' && split.base !== undefined) {
        preservePrimaryLength = split.base.end;
        extras.push({ semantic: layer.semantic, mime: 'application/octet-stream',
          bytes: bytes.slice(layer.start, layer.end) });
        continue;
      }
      // 其它目标无法保证附加数据位置不变，继续保留原图。
      Lg.w('[HDR] unknown trailing layer, keep original: ' + name
        + ' kind=' + layer.kind + ' semantic=' + layer.semantic);
      return undefined;
    }
    if (extras.length > 0 && target === 'base-only') {
      // 只发基础层时不能顺手把视频扔掉：这种「没拆开的动态照片」交给动态照片链路自己处理。
      Lg.i('[HDR] base-only skipped (file carries trailing motion photo): ' + name);
      return undefined;
    }
    const dir = workDir(context);
    const stamp = Date.now().toString(36);
    const outName = HdrPhotoService.baseName(name) + '.jpg';
    const outPath = dir + '/' + stamp + '-' + outName;

    if (target === 'base-only') {
      const written = HdrGainMap.writeBaseOnlyJpeg(base);
      if (written === undefined) {
        return undefined;
      }
      const size2 = HdrPhotoService.write(outPath, written.bytes);
      if (size2 <= 0) {
        return undefined;
      }
      const keptExif = HdrExifPreserve.exifPayload(written.bytes) !== undefined;
      Lg.i('[HDR] base-only written: ' + outName + ' ' + size2 + ' bytes exif=' + keptExif
        + ' xmp=' + written.xmpAction);
      return {
        files: [{ path: outPath, name: outName, size: size2, mime: 'image/jpeg' }],
        action: 'base-only',
        note: 'gainmap stripped, exif preserved'
      };
    }

    // 华为/鸿蒙形态（HDR Vivid）：APP2 ISO URN + MPF attribute 0x50000，不带 XMP。
    if (target === 'vivid') {
      const vivid = HdrGainMap.writeVividJpeg(base, gainMap, extras, preservePrimaryLength);
      if (vivid === undefined) {
        return undefined;
      }
      const vividBytes = vivid.bytes;
      const vividProblems = HdrGainMap.verifyVividJpeg(vividBytes,
        HdrGainMap.detectLayers(vividBytes, outName, vividBytes.length));
      if (vividProblems.length > 0) {
        Lg.w('[HDR] vivid self-check failed, keep original: ' + vividProblems.join(','));
        return undefined;
      }
      const vividSize = HdrPhotoService.write(outPath, vividBytes);
      if (vividSize <= 0) {
        return undefined;
      }
      Lg.i('[HDR] vivid (harmony) written: ' + outName + ' ' + vividSize + ' bytes base='
        + vivid.baseLength + ' gainmap=' + vivid.gainMapLength + ' trailing=' + vivid.trailingLength
        + ' exif=' + (HdrExifPreserve.exifPayload(vividBytes, vivid.baseLength) !== undefined));
      return {
        files: [{ path: outPath, name: outName, size: vividSize, mime: 'image/jpeg' }],
        action: 'vivid',
        note: 'iso-21496 urn + mpf gainmap attribute, no xmp'
      };
    }

    const written = HdrGainMap.writeDualJpegWithGainMap(base, gainMap, extras);
    if (written === undefined) {
      return undefined;
    }
    // 写出的字节里已经**包含**按新布局重建的 MPF（writeDualJpegWithGainMap 内部先删旧 MPF
    // 再重建），这里不能再删一遍——删掉后自检必然报 mpf-missing，整个功能会静默退回原图。
    const cleaned = written.bytes;
    const problems = HdrGainMap.verifyDualJpeg(cleaned, HdrGainMap.detectLayers(cleaned, outName, cleaned.length));
    if (problems.length > 0) {
      Lg.w('[HDR] dual-jpeg self-check failed, keep original: ' + problems.join(','));
      return undefined;
    }
    const size2 = HdrPhotoService.write(outPath, cleaned);
    if (size2 <= 0) {
      return undefined;
    }
    Lg.i('[HDR] dual-jpeg written: ' + outName + ' ' + size2 + ' bytes base=' + written.baseLength
      + ' gainmap=' + written.gainMapLength + ' trailing=' + written.trailingLength
      + ' xmp=' + written.xmpAction + ' gainmapMeta=' + written.gainMapMetadata
      + ' exif=' + (HdrExifPreserve.exifPayload(cleaned, written.baseLength) !== undefined));
    if (written.gainMapMetadata === 'none') {
      Lg.w('[HDR] 警告：增益图没有任何参数（既无 hdrgm 也无 ISO 21496-1），对端可能按 SDR 显示：' + outName);
    }
    return {
      files: [{ path: outPath, name: outName, size: size2, mime: 'image/jpeg' }],
      action: 'dual-jpeg',
      note: 'base + gainmap, exif preserved'
    };
  }

  /**
   * 依对端能力给出目标形态。
   *
   * - 华为/鸿蒙 → `vivid`（APP2 ISO URN + MPF attribute 0x50000，不带 XMP；真机实测的鸿蒙判据）；
   * - 其它 HDR 感知端（Apple / Android 新机）→ `dual-jpeg`（XMP `hdrgm`/`Container` + MPF）；
   * - 电脑/未知 → `base-only`（只发基础 SDR 层）。
   */
  static targetForPeer(hdrAware: boolean, harmonyPeer: boolean = false): HdrTarget {
    if (!hdrAware) {
      return 'base-only';
    }
    return harmonyPeer ? 'vivid' : 'dual-jpeg';
  }

  private static baseName(name: string): string {
    const dot = name.lastIndexOf('.');
    const base = dot > 0 ? name.substring(0, dot) : name;
    let cleaned = '';
    for (let i = 0; i < base.length; i++) {
      const ch = base.charAt(i);
      const ok = (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
        || ch === '_' || ch === '-';
      cleaned += ok ? ch : '_';
    }
    return cleaned.length > 0 ? cleaned : 'hdr';
  }

  private static write(path: string, bytes: Uint8Array): number {
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, bytes.buffer);
        return bytes.length;
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      Lg.w('[HDR] write failed: ' + path + ' '
        + (error instanceof Error ? error.message : JSON.stringify(error)));
      return 0;
    }
  }
}
