// ImageThumbnailUtil：生成发送侧预览缩略图（等比缩放至目标框，JPEG 落盘）
// 供 MTA 发送流程在对端确认阶段展示预览用；图片走 ImageSource 解码，
// 视频复用 VideoThumbnailUtil 取帧，二者统一编码为 JPEG。

import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { getLogger } from './Logger';
import { LogDomains } from '../common/LogDomains';
import { generateVideoThumbnail } from './VideoThumbnailUtil';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:ImageThumbnail', '缩略图');

/** JPEG 编码质量（0-100） */
const THUMBNAIL_JPEG_QUALITY: number = 80;

/** 缩略图实际像素尺寸 */
export class ThumbnailSize {
  width: number = 0;
  height: number = 0;
}

/**
 * 按目标框等比缩放（不放大）：返回不超过目标框的整数尺寸。
 * 源尺寸非法时返回 0×0，由调用方短路处理。
 */
function fitIntoBox(srcWidth: number, srcHeight: number, maxWidth: number,
  maxHeight: number): ThumbnailSize {
  let size = new ThumbnailSize();
  if (srcWidth <= 0 || srcHeight <= 0 || maxWidth <= 0 || maxHeight <= 0) {
    return size;
  }
  let scale = Math.min(maxWidth / srcWidth, maxHeight / srcHeight);
  if (scale > 1) {
    scale = 1;
  }
  size.width = Math.max(1, Math.round(srcWidth * scale));
  size.height = Math.max(1, Math.round(srcHeight * scale));
  return size;
}

/** PixelMap 编码为 JPEG 字节并写入目标路径 */
async function writeJpeg(pixelMap: image.PixelMap, targetPath: string): Promise<void> {
  let packer = image.createImagePacker();
  try {
    let options: image.PackingOption = {
      format: 'image/jpeg',
      quality: THUMBNAIL_JPEG_QUALITY
    };
    let bytes = await packer.packToData(pixelMap, options);
    let file = fs.openSync(targetPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, bytes);
    } finally {
      fs.closeSync(file);
    }
  } finally {
    await packer.release();
  }
}

/** 图片源：解码到目标框内并写盘，返回实际尺寸 */
async function writeImageThumbnail(source: string, targetPath: string, maxWidth: number,
  maxHeight: number): Promise<ThumbnailSize | undefined> {
  let file = fs.openSync(source, fs.OpenMode.READ_ONLY);
  try {
    let imageSource = image.createImageSource(file.fd);
    try {
      let src = imageSource.getImageInfoSync(0).size;
      let target = fitIntoBox(src.width, src.height, maxWidth, maxHeight);
      if (target.width === 0 || target.height === 0) {
        return undefined;
      }
      let options: image.DecodingOptions = {
        desiredSize: { width: target.width, height: target.height }
      };
      let pixelMap = await imageSource.createPixelMap(options);
      try {
        let info = pixelMap.getImageInfoSync();
        await writeJpeg(pixelMap, targetPath);
        let size = new ThumbnailSize();
        size.width = info.size.width;
        size.height = info.size.height;
        return size;
      } finally {
        pixelMap.release();
      }
    } finally {
      await imageSource.release();
    }
  } finally {
    fs.closeSync(file);
  }
}

/** 视频源：取首帧并写盘，返回实际尺寸 */
async function writeVideoThumbnail(source: string, targetPath: string, maxWidth: number,
  maxHeight: number): Promise<ThumbnailSize | undefined> {
  let pixelMap = await generateVideoThumbnail(source, maxWidth, maxHeight);
  if (pixelMap === undefined) {
    return undefined;
  }
  try {
    let info = pixelMap.getImageInfoSync();
    await writeJpeg(pixelMap, targetPath);
    let size = new ThumbnailSize();
    size.width = info.size.width;
    size.height = info.size.height;
    return size;
  } finally {
    pixelMap.release();
  }
}

/**
 * 生成发送侧预览缩略图：从图片或视频源等比缩放至目标框内（不放大），
 * 以 JPEG 写入 targetPath，返回实际像素尺寸。
 *
 * 源不可用/解码失败时返回 undefined，调用方据此按「不提供缩略图」降级——
 * 缩略图属可选能力，任何失败都不得中断发送。
 */
export async function writeSendThumbnail(source: string, isVideo: boolean, targetPath: string,
  maxWidth: number, maxHeight: number): Promise<ThumbnailSize | undefined> {
  try {
    let size = isVideo ?
      await writeVideoThumbnail(source, targetPath, maxWidth, maxHeight) :
      await writeImageThumbnail(source, targetPath, maxWidth, maxHeight);
    if (size === undefined) {
      logger.warn('生成发送缩略图失败（源不可用或不可解码），按不提供处理 src=' + source);
    }
    return size;
  } catch (e) {
    logger.warn('生成发送缩略图异常，按不提供处理 src=' + source + ' err=' + e);
    return undefined;
  }
}
