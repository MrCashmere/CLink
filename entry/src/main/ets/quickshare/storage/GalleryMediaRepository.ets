/**
 * 权威依据：用户 2026-11-07 接收媒体自动入图库需求；HarmonyOS 用户侧可见文案约束 1.0。
 * 本轮改动：封装图库资产创建、写入和下载回退，不自行申请权限。
 * 用户侧：本文件不产生任何界面文案。
 * 🔴 红线：只有已确认的图片/视频资产才能调用图库 API；失败时必须保留可回退源文件。
 */

import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { picker, fileUri } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import fs from '@ohos.file.fs';
import { LogCapture as Lg } from '../../common/LogCapture';
import { GalleryMediaClassification } from './GalleryMediaClassifier';

export interface GallerySaveResult {
  readonly saved: boolean;
  readonly uri: string;
  readonly permissionDenied: boolean;
  readonly error: string;
}

export interface GalleryDownloadFallbackResult {
  readonly path: string;
  readonly copied: boolean;
  readonly error: string;
}

const COPY_CHUNK_BYTES: number = 1024 * 1024;

/**
 * photoAccessHelper 的薄适配层。
 *
 * 调用方必须先通过 SaveButton 成功回调建立授权会话；本类不自行申请任何权限。
 */
export class GalleryMediaRepository {
  static isSandboxPath(context: common.Context, path: string): boolean {
    const normalized: string = path.startsWith('file://') ? GalleryMediaRepository.uriToPath(path) : path;
    return normalized.startsWith(context.filesDir + '/') || normalized.startsWith(context.cacheDir + '/');
  }

  static async supports(context: common.Context,
    classification: GalleryMediaClassification): Promise<boolean> {
    if (classification.kind === 'other' || classification.extension.length === 0) {
      return false;
    }
    try {
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      const photoType: photoAccessHelper.PhotoType = classification.kind === 'video'
        ? photoAccessHelper.PhotoType.VIDEO
        : photoAccessHelper.PhotoType.IMAGE;
      const formats: string[] = await helper.getSupportedPhotoFormats(photoType);
      const target: string = GalleryMediaRepository.normalizeFormat(classification.extension);
      return formats.some((item: string): boolean =>
        GalleryMediaRepository.normalizeFormat(item) === target);
    } catch (error) {
      Lg.w('[GALLERY] getSupportedPhotoFormats failed: '
        + (error instanceof Error ? error.message : JSON.stringify(error)));
      // 查询失败不应阻断保存；最终由系统实际导入结果决定。
      return true;
    }
  }

  static async save(context: common.Context, sourcePath: string,
    classification: GalleryMediaClassification): Promise<GallerySaveResult> {
    if (classification.kind === 'other' || classification.extension.length === 0) {
      return GalleryMediaRepository.failed(false, 'unsupported media');
    }
    if (!GalleryMediaRepository.isSandboxPath(context, sourcePath)) {
      return GalleryMediaRepository.failed(false, 'source is not in sandbox');
    }
    const localPath: string = GalleryMediaRepository.localPath(sourcePath);
    try {
      const stat = fs.statSync(localPath);
      if (stat.size <= 0) {
        return GalleryMediaRepository.failed(false, 'empty file');
      }
      if (!(await GalleryMediaRepository.supports(context, classification))) {
        return GalleryMediaRepository.failed(false,
          'gallery does not support extension ' + classification.extension);
      }
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      const photoType: photoAccessHelper.PhotoType = classification.kind === 'video'
        ? photoAccessHelper.PhotoType.VIDEO
        : photoAccessHelper.PhotoType.IMAGE;
      const change = photoAccessHelper.MediaAssetChangeRequest.createAssetRequest(
        context, photoType, classification.extension, { title: classification.title });
      const resourceType = classification.kind === 'video'
        ? photoAccessHelper.ResourceType.VIDEO_RESOURCE
        : photoAccessHelper.ResourceType.IMAGE_RESOURCE;
      // The resource and asset are applied together; a failed copy must not leave an empty asset.
      change.addResource(resourceType, fileUri.getUriFromPath(localPath));
      await helper.applyChanges(change);
      const uri: string = change.getAsset().uri;
      Lg.i('[GALLERY] saved ' + classification.kind + ' title=' + classification.title
        + ' size=' + stat.size + ' uri=' + uri);
      return { saved: true, uri: uri, permissionDenied: false, error: '' };
    } catch (error) {
      const code: number = GalleryMediaRepository.errorCode(error);
      const permissionDenied: boolean = code === 201 || code === 13900012;
      const message: string = error instanceof Error ? error.message : JSON.stringify(error);
      Lg.w('[GALLERY] save failed code=' + code + ' permissionDenied=' + permissionDenied
        + ' message=' + message);
      return { saved: false, uri: '', permissionDenied: permissionDenied, error: message };
    }
  }

  static async copyToDownload(context: common.Context, sourcePath: string,
    preferredName: string): Promise<GalleryDownloadFallbackResult> {
    const localPath: string = GalleryMediaRepository.localPath(sourcePath);
    let temporaryDirectory: string = '';
    let temporaryPath: string = '';
    try {
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
      options.newFileNames = [preferredName];
      const documentViewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const uris: string[] = await documentViewPicker.save(options);
      if (uris.length === 0) {
        return { path: sourcePath, copied: false, error: 'picker returned no uri' };
      }
      const basePath: string = new fileUri.FileUri(uris[0]).path;
      // OpenMode 没有公开 EXCL 标志。先在本次独占临时目录写完，再用 moveFile(mode=1)
      // 发布；由系统拒绝覆盖，不能用 accessSync + TRUNC 的检查/写入竞争窗口。
      temporaryDirectory = fs.mkdtempSync(context.cacheDir + '/gallery-fallback-XXXXXX');
      temporaryPath = temporaryDirectory + '/payload';
      const copied: number = await GalleryMediaRepository.copyPathToPath(localPath, temporaryPath);
      const expected: number = fs.statSync(localPath).size;
      if (copied !== expected) {
        return { path: sourcePath, copied: false, error: 'download copy size mismatch' };
      }
      const directory: string = basePath.endsWith('/') ? basePath : basePath + '/';
      const dot: number = preferredName.lastIndexOf('.');
      const stem: string = dot > 0 ? preferredName.substring(0, dot) : preferredName;
      const extension: string = dot > 0 ? preferredName.substring(dot) : '';
      for (let index = 0; index < 1000; index++) {
        const target: string = directory + stem + (index === 0 ? '' : ' (' + index + ')') + extension;
        try {
          await fs.moveFile(temporaryPath, target, 1);
          Lg.i('[GALLERY] fallback saved to download: ' + target);
          return { path: target, copied: true, error: '' };
        } catch (error) {
          if (GalleryMediaRepository.errorCode(error) !== 13900015) {
            throw new Error(error instanceof Error ? error.message : JSON.stringify(error));
          }
        }
      }
      return { path: sourcePath, copied: false, error: 'too many filename conflicts' };
    } catch (error) {
      const message: string = error instanceof Error ? error.message : JSON.stringify(error);
      Lg.w('[GALLERY] fallback to download failed: ' + message);
      return { path: sourcePath, copied: false, error: message };
    } finally {
      // 只清理本次创建的临时副本；源文件和已有下载文件不在清理范围内。
      try { if (temporaryPath.length > 0 && fs.accessSync(temporaryPath)) { fs.unlinkSync(temporaryPath); } } catch (error) {}
      try { if (temporaryDirectory.length > 0) { fs.rmdirSync(temporaryDirectory); } } catch (error) {}
    }
  }

  private static async copyPathToPath(sourcePath: string, targetPath: string): Promise<number> {
    const source = fs.openSync(sourcePath, fs.OpenMode.READ_ONLY);
    let targetFd: number = -1;
    try {
      const target = fs.openSync(targetPath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      targetFd = target.fd;
      return await GalleryMediaRepository.copyFds(source.fd, targetFd);
    } finally {
      if (targetFd >= 0) {
        try {
          fs.closeSync(targetFd);
        } catch (closeError) {
        }
      }
      try {
        fs.closeSync(source);
      } catch (sourceCloseError) {
      }
    }
  }

  private static async copyFds(sourceFd: number, targetFd: number): Promise<number> {
    let total: number = 0;
    while (true) {
      const buffer: ArrayBuffer = new ArrayBuffer(COPY_CHUNK_BYTES);
      const read: number = await fs.read(sourceFd, buffer);
      if (read <= 0) {
        break;
      }
      let written: number = 0;
      while (written < read) {
        const count: number = await fs.write(targetFd, buffer.slice(written, read));
        if (count <= 0 || count > read - written) {
          throw new Error('short write');
        }
        written += count;
      }
      total += read;
    }
    return total;
  }

  private static localPath(sourcePath: string): string {
    return sourcePath.startsWith('file://')
      ? GalleryMediaRepository.uriToPath(sourcePath)
      : sourcePath;
  }

  private static uriToPath(uri: string): string {
    try {
      return new fileUri.FileUri(uri).path;
    } catch (error) {
      const stripped: string = uri.substring('file://'.length);
      const slash: number = stripped.indexOf('/');
      return slash >= 0 ? stripped.substring(slash) : stripped;
    }
  }

  private static normalizeFormat(format: string): string {
    const lower: string = format.trim().toLowerCase();
    return lower.startsWith('.') ? lower.substring(1) : lower;
  }

  private static errorCode(error: Object): number {
    const business = error as BusinessError;
    return business !== undefined && business.code !== undefined ? business.code : -1;
  }

  private static failed(permissionDenied: boolean, error: string): GallerySaveResult {
    return { saved: false, uri: '', permissionDenied: permissionDenied, error: error };
  }
}
