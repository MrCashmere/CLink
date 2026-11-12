/**
 * HDR 探针：把「这张图是不是 HDR / 有没有增益图 / 增益图元数据是什么 / 本机支持哪些 HDR 图片格式」
 * 一次性问清楚，并打一行 `[HDR]` 日志。
 *
 * 本模块只做**探测与日志**，不改文件、不参与发送决策 —— 落地阶段 1 的「先看清事实」部分
 * （见 `docs/HDR_IMAGE.md` §5）。
 *
 * 机型/API 差异很大，所以每一步都单独 try/catch：任何一项不可用都不影响其它项，
 * 失败原因写进 `note` 而不是抛异常。
 */

import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { display } from '@kit.ArkUI';
import hdrCapability from '@ohos.graphics.hdrCapability';
import fs from '@ohos.file.fs';
import { LogCapture as Lg } from './LogCapture';
import { HdrExifPreserve } from './HdrExifPreserve';
import { HdrGainMap, HdrLayerSplit } from './HdrGainMap';

/** 本机对 HDR **图片**格式的支持面（来自 `display.hdrFormats`）。 */
export interface DeviceHdrSupport {
  readonly queried: boolean;
  readonly vividDual: boolean;
  readonly vividSingle: boolean;
  readonly isoDual: boolean;
  readonly isoSingle: boolean;
  readonly allFormats: string;
}

/** 一次探测的完整结果。 */
export interface HdrProbeResult {
  readonly name: string;
  readonly size: number;
  /** `ImageInfo.isHdr`：源图是否 HDR。 */
  readonly imageIsHdr: boolean;
  readonly mimeType: string;
  /** 主图尺寸。 */
  readonly mainSize: string;
  /** `Picture.getGainmapPixelmap()` 是否取到增益图。 */
  readonly gainMapAux: boolean;
  readonly gainMapSize: string;
  /** `HdrGainmapMetadata` 摘要（ISO 21496-1 字段）。 */
  readonly gainMapMetadata: string;
  /** 字节级分层结论（容器目录 / 追加式双 JPEG）。 */
  readonly layers: string;
  readonly hasExif: boolean;
  readonly device: DeviceHdrSupport;
  /** 失败/跳过原因（成功为空串）。 */
  readonly note: string;
}

/** 读取整体文件的上限：与 DynamicPhotoBridge 的转换上限保持一致。 */
const MAX_PROBE_BYTES = 96 * 1024 * 1024;

function emptySupport(): DeviceHdrSupport {
  return {
    queried: false, vividDual: false, vividSingle: false,
    isoDual: false, isoSingle: false, allFormats: ''
  };
}

export class HdrPhotoProbe {
  /** 查本机支持的 HDR 图片格式（直接用 `hdrCapability.HDRFormat` 枚举比较，避免数值硬编码）。 */
  static deviceSupport(): DeviceHdrSupport {
    try {
      const formats: hdrCapability.HDRFormat[] = display.getDefaultDisplaySync().hdrFormats;
      const present: string[] = [];
      if (formats.indexOf(hdrCapability.HDRFormat.VIDEO_HLG) >= 0) {
        present.push('VIDEO_HLG');
      }
      if (formats.indexOf(hdrCapability.HDRFormat.VIDEO_HDR10) >= 0) {
        present.push('VIDEO_HDR10');
      }
      if (formats.indexOf(hdrCapability.HDRFormat.VIDEO_HDR_VIVID) >= 0) {
        present.push('VIDEO_HDR_VIVID');
      }
      if (formats.indexOf(hdrCapability.HDRFormat.IMAGE_HDR_VIVID_DUAL) >= 0) {
        present.push('IMAGE_HDR_VIVID_DUAL');
      }
      if (formats.indexOf(hdrCapability.HDRFormat.IMAGE_HDR_VIVID_SINGLE) >= 0) {
        present.push('IMAGE_HDR_VIVID_SINGLE');
      }
      if (formats.indexOf(hdrCapability.HDRFormat.IMAGE_HDR_ISO_DUAL) >= 0) {
        present.push('IMAGE_HDR_ISO_DUAL');
      }
      if (formats.indexOf(hdrCapability.HDRFormat.IMAGE_HDR_ISO_SINGLE) >= 0) {
        present.push('IMAGE_HDR_ISO_SINGLE');
      }
      return {
        queried: true,
        vividDual: formats.indexOf(hdrCapability.HDRFormat.IMAGE_HDR_VIVID_DUAL) >= 0,
        vividSingle: formats.indexOf(hdrCapability.HDRFormat.IMAGE_HDR_VIVID_SINGLE) >= 0,
        isoDual: formats.indexOf(hdrCapability.HDRFormat.IMAGE_HDR_ISO_DUAL) >= 0,
        isoSingle: formats.indexOf(hdrCapability.HDRFormat.IMAGE_HDR_ISO_SINGLE) >= 0,
        allFormats: present.join('|')
      };
    } catch (error) {
      Lg.w('[HDR] hdrFormats query failed: '
        + (error instanceof Error ? error.message : JSON.stringify(error)));
      return emptySupport();
    }
  }

  /**
   * `HdrGainmapMetadata` → 一行摘要（只取判定必需的字段，避免日志过长）。
   *
   * 字段名以 SDK 为准（`@ohos.multimedia.image.d.ts` 的 `HdrGainmapMetadata` / `GainmapChannel`）：
   * 单通道参数在 `channels[]` 里，不是顶层的 `gainmapMax/gainmapMin/gamma`。
   */
  static summarizeMetadata(meta: image.HdrGainmapMetadata): string {
    try {
      const channels = meta.channels !== undefined ? meta.channels : [];
      let channelText = '';
      if (channels.length > 0) {
        const first = channels[0];
        channelText = ' max=' + first.gainmapMax + ' min=' + first.gainmapMin
          + ' gamma=' + first.gamma;
      }
      return 'v' + meta.miniVersion + '/' + meta.writerVersion
        + ' ch=' + meta.gainmapChannelCount
        + ' base=' + meta.baseHeadroom + ' alt=' + meta.alternateHeadroom
        + channelText;
    } catch (error) {
      return 'unreadable';
    }
  }

  /** 探测一个文件：系统 API（isHdr / 增益图 / 元数据）+ 字节级分层。 */
  static async probeFile(context: common.Context, path: string, name: string, size: number): Promise<HdrProbeResult> {
    const support = HdrPhotoProbe.deviceSupport();
    let imageIsHdr = false;
    let mimeType = '';
    let mainSize = '';
    let gainMapAux = false;
    let gainMapSize = '';
    let gainMapMetadata = '';
    const notes: string[] = [];

    // 1) image kit：isHdr + 增益图 + 元数据
    let source: image.ImageSource | undefined = undefined;
    try {
      source = image.createImageSource(path);
      const info = await source.getImageInfo();
      imageIsHdr = info.isHdr === true;
      mimeType = info.mimeType;
      mainSize = info.size.width + 'x' + info.size.height;
    } catch (error) {
      notes.push('imageInfo:' + (error instanceof Error ? error.message : JSON.stringify(error)));
    }
    if (source !== undefined) {
      let picture: image.Picture | undefined = undefined;
      try {
        const options: image.DecodingOptionsForPicture = {
          desiredAuxiliaryPictures: [image.AuxiliaryPictureType.GAINMAP]
        };
        picture = await source.createPicture(options);
        const gainmap = picture.getGainmapPixelmap();
        if (gainmap !== null) {
          gainMapAux = true;
          // PixelMap.getImageInfo() 在本 SDK 是异步的（`Promise<ImageInfo>`），必须 await。
          const gainInfo = await gainmap.getImageInfo();
          gainMapSize = gainInfo.size.width + 'x' + gainInfo.size.height;
          try {
            const raw: image.HdrMetadataValue = gainmap.getMetadata(image.HdrMetadataKey.HDR_GAINMAP_METADATA);
            gainMapMetadata = HdrPhotoProbe.summarizeMetadata(raw as image.HdrGainmapMetadata);
          } catch (metaError) {
            gainMapMetadata = 'meta:' + (metaError instanceof Error ? metaError.message : JSON.stringify(metaError));
          }
        }
      } catch (error) {
        // 7600201 = 没有增益图 / 主图 allocator 非 DMA，属预期情况之一
        notes.push('picture:' + (error instanceof Error ? error.message : JSON.stringify(error)));
      } finally {
        if (picture !== undefined) {
          try {
            picture.release();
          } catch (releaseError) {
          }
        }
      }
      try {
        source.release();
      } catch (releaseError) {
      }
    }

    // 2) 字节级分层（容器目录 / 追加式双 JPEG）——决定能不能走「不重编码」路线
    let layersText = '';
    let hasExif = false;
    let split: HdrLayerSplit | undefined = undefined;
    if (size > 0 && size <= MAX_PROBE_BYTES) {
      try {
        const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
        try {
          const buffer = new ArrayBuffer(size);
          const read = await fs.read(file.fd, buffer);
          const bytes = read === size ? new Uint8Array(buffer) : new Uint8Array(buffer.slice(0, Math.max(read, 0)));
          split = HdrGainMap.detectLayers(bytes, name, bytes.length);
          layersText = HdrGainMap.describe(split, name);
          hasExif = HdrExifPreserve.exifPayload(bytes, bytes.length) !== undefined;
        } finally {
          fs.closeSync(file);
        }
      } catch (error) {
        notes.push('bytes:' + (error instanceof Error ? error.message : JSON.stringify(error)));
      }
    } else {
      notes.push('bytes:size-over-limit(' + size + ')');
    }

    const result: HdrProbeResult = {
      name: name, size: size,
      imageIsHdr: imageIsHdr, mimeType: mimeType, mainSize: mainSize,
      gainMapAux: gainMapAux, gainMapSize: gainMapSize, gainMapMetadata: gainMapMetadata,
      layers: layersText, hasExif: hasExif, device: support,
      note: notes.join('; ')
    };
    HdrPhotoProbe.log(result);
    return result;
  }

  /** 一行日志：把「源是不是 HDR / 有没有增益图 / 本机支持面」写清楚，便于事后定位。 */
  static log(result: HdrProbeResult): void {
    Lg.i('[HDR] probe ' + result.name + ' size=' + result.size
      + ' isHdr=' + result.imageIsHdr + ' mime=' + result.mimeType + ' main=' + result.mainSize
      + ' gainmapAux=' + result.gainMapAux + (result.gainMapSize.length > 0 ? '(' + result.gainMapSize + ')' : '')
      + (result.gainMapMetadata.length > 0 ? ' meta[' + result.gainMapMetadata + ']' : '')
      + ' exif=' + result.hasExif
      + ' device[vividDual=' + result.device.vividDual + ' vividSingle=' + result.device.vividSingle
      + ' isoDual=' + result.device.isoDual + ' isoSingle=' + result.device.isoSingle
      + ' formats=' + result.device.allFormats + ']'
      + (result.layers.length > 0 ? ' | ' + result.layers : '')
      + (result.note.length > 0 ? ' | note=' + result.note : ''));
  }
}
