/**
 * 权威依据：用户 2026-11-07 接收媒体自动入图库需求；HarmonyOS 用户侧可见文案约束 1.0。
 * 本轮改动：统一协调 LocalSend、Quick Share、Windows Nearby 和旧 NearShare 的媒体入库。
 * 用户侧：本文件不产生界面文案；文件收齐后通过独立授权入口按需提示。
 * 🔴 红线：非图片/视频不得进入图库；动态照片已占用时不得重复创建普通资产。
 */

import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { LogCapture as Lg } from '../../common/LogCapture';
import { SettingsStore } from '../../common/SettingsStore';
import { DynamicPhotoService } from '../../common/DynamicPhotoService';
import { HdrPhotoService } from '../../common/HdrPhotoService';
import {
  GalleryMediaClassification,
  GalleryMediaClassifier
} from '../storage/GalleryMediaClassifier';
import {
  GalleryDownloadFallbackResult,
  GalleryMediaRepository,
  GallerySaveResult
} from '../storage/GalleryMediaRepository';
import { GalleryAuthorizationSession } from './GalleryAuthorizationSession';
import { GalleryAuthorizationRequest } from './GalleryAuthorizationRequest';

export interface GalleryProcessResult {
  readonly handled: boolean;
  readonly savedToGallery: boolean;
  readonly finalPath: string;
  readonly assetUri: string;
  readonly error: string;
}

const MAX_REMEMBERED_GALLERY_URIS: number = 64;

/**
 * 图片/视频接收后的唯一图库入口。
 *
 * 只在媒体收齐后请求或复用 SaveButton 授权；开启设置本身不申请权限。
 */
export class GalleryAutoSaveService {
  private static readonly savedUriBySourcePath: Map<string, string> = new Map<string, string>();

  static enabled(): boolean {
    return SettingsStore.current().saveReceivedMediaToGallery === true;
  }

  static authorizationActive(): boolean {
    return GalleryAuthorizationSession.isActive();
  }

  static activateAuthorization(): void {
    GalleryAuthorizationSession.activate();
  }

  static invalidateAuthorization(reason: string): void {
    GalleryAuthorizationSession.invalidate(reason);
  }

  /** 需要图库保存或照片转换时先留在沙箱，收齐后逐项处理。 */
  static shouldStageForGallery(name: string, mime: string = ''): boolean {
    const kind: string = GalleryMediaClassifier.classify(name, mime).kind;
    if (kind === 'other') { return false; }
    return GalleryAutoSaveService.enabled() || DynamicPhotoService.enabled()
      || (kind === 'image' && HdrPhotoService.enabled());
  }

  /**
   * LocalSend 在文件仍位于应用沙箱、尚未搬到下载目录时调用。
   * 成功时记录 sourcePath -> 图库 URI，供 relocateIncoming 跳过下载副本。
   */
  static async saveStaged(context: common.Context, sourcePath: string,
    name: string, size: number, mime: string = ''): Promise<GalleryProcessResult> {
    if (!GalleryAutoSaveService.enabled()) {
      return GalleryAutoSaveService.notHandled(sourcePath);
    }
    if (DynamicPhotoService.isClaimedByDynamicPhoto(sourcePath)) {
      return {
        handled: true,
        savedToGallery: false,
        finalPath: sourcePath,
        assetUri: '',
        error: ''
      };
    }
    const classification: GalleryMediaClassification = GalleryMediaClassifier.classify(name, mime);
    if (classification.kind === 'other') {
      return GalleryAutoSaveService.notHandled(sourcePath);
    }
    if (size <= 0) {
      return {
        handled: true,
        savedToGallery: false,
        finalPath: sourcePath,
        assetUri: '',
        error: 'empty file'
      };
    }
    const result: GallerySaveResult = await GalleryAutoSaveService.saveWithAuthorization(
      context, sourcePath, classification);
    if (!result.saved) {
      return {
        handled: true,
        savedToGallery: false,
        finalPath: sourcePath,
        assetUri: '',
        error: result.error
      };
    }
    GalleryAutoSaveService.rememberGalleryUri(sourcePath, result.uri);
    return {
      handled: true,
      savedToGallery: true,
      finalPath: result.uri,
      assetUri: result.uri,
      error: ''
    };
  }

  /**
   * Quick Share / Windows Nearby / NearShare 在完整文件已落到沙箱后调用。
   *
   * fallbackToDownload=true 表示协议为了尝试图库而跳过了原有 Download 流程，
   * 因而图库失败时必须由本方法补做下载回退。
   */
  static async processCompleted(context: common.Context, sourcePath: string,
    name: string, size: number,
    fallbackToDownload: boolean, mime: string = ''): Promise<GalleryProcessResult> {
    const classification: GalleryMediaClassification = GalleryMediaClassifier.classify(name, mime);
    if (classification.kind === 'other') {
      return GalleryAutoSaveService.finishWithoutGallery(
        context, sourcePath, name, fallbackToDownload, 'not gallery media');
    }
    if (DynamicPhotoService.wasHandledForGallery(sourcePath)) {
      return {
        handled: true,
        savedToGallery: false,
        finalPath: sourcePath,
        assetUri: '',
        error: ''
      };
    }
    if (DynamicPhotoService.isClaimedByDynamicPhoto(sourcePath)) {
      return GalleryAutoSaveService.finishWithoutGallery(
        context, sourcePath, name, fallbackToDownload, 'waiting for matching motion photo');
    }
    if (!GalleryAutoSaveService.enabled()) {
      return GalleryAutoSaveService.finishWithoutGallery(
        context, sourcePath, name, fallbackToDownload, 'feature disabled');
    }
    if (size <= 0) {
      return GalleryAutoSaveService.finishWithoutGallery(context, sourcePath, name, fallbackToDownload, 'empty file');
    }
    const result: GallerySaveResult = await GalleryAutoSaveService.saveWithAuthorization(
      context, sourcePath, classification);
    if (result.saved) {
      if (GalleryAutoSaveService.isGalleryStagingPath(context, sourcePath)) {
        GalleryAutoSaveService.removeStagingFile(sourcePath);
      }
      return {
        handled: true,
        savedToGallery: true,
        finalPath: result.uri,
        assetUri: result.uri,
        error: ''
      };
    }
    return await GalleryAutoSaveService.finishWithoutGallery(
      context, sourcePath, name, fallbackToDownload, result.error);
  }

  /** 返回某次 saveStaged 对应的图库 URI；读取后立即移除，避免进程内累积。 */
  static galleryUriForSourcePath(sourcePath: string): string {
    const uri: string = GalleryAutoSaveService.savedUriBySourcePath.get(sourcePath) ?? '';
    if (uri.length > 0) {
      GalleryAutoSaveService.savedUriBySourcePath.delete(sourcePath);
    }
    return uri;
  }

  private static async saveWithAuthorization(context: common.Context, sourcePath: string,
    classification: GalleryMediaClassification): Promise<GallerySaveResult> {
    const alreadyAuthorized: boolean = GalleryAuthorizationSession.isActive();
    if (!(await GalleryAuthorizationRequest.request()) || !GalleryAutoSaveService.enabled()) {
      return { saved: false, uri: '', permissionDenied: false, error: 'gallery authorization declined or unavailable' };
    }
    let result: GallerySaveResult = await GalleryMediaRepository.save(context, sourcePath, classification);
    if (result.permissionDenied) {
      GalleryAuthorizationSession.invalidate('permission denied');
      // 已有授权被系统提前收回时，为这次文件续权后重试一次；新授权仍失败则回退，避免反复弹窗。
      if (alreadyAuthorized && await GalleryAuthorizationRequest.request() && GalleryAutoSaveService.enabled()) {
        result = await GalleryMediaRepository.save(context, sourcePath, classification);
        if (result.permissionDenied) { GalleryAuthorizationSession.invalidate('permission denied after renewal'); }
      }
    }
    return result;
  }

  static isSandboxPath(context: common.Context, path: string): boolean {
    return path.length > 0 && GalleryMediaRepository.isSandboxPath(context, path);
  }

  private static async finishWithoutGallery(context: common.Context, sourcePath: string,
    name: string, fallbackToDownload: boolean,
    reason: string): Promise<GalleryProcessResult> {
    if (!fallbackToDownload) {
      return {
        handled: false,
        savedToGallery: false,
        finalPath: sourcePath,
        assetUri: '',
        error: reason
      };
    }
    const fallback: GalleryDownloadFallbackResult = await GalleryMediaRepository.copyToDownload(
      context, sourcePath, GalleryMediaClassifier.safeFileName(name));
    if (fallback.copied && GalleryAutoSaveService.isGalleryStagingPath(context, sourcePath)) {
      GalleryAutoSaveService.removeStagingFile(sourcePath);
    }
    return {
      handled: true,
      savedToGallery: false,
      finalPath: fallback.path,
      assetUri: '',
      error: fallback.copied ? reason : fallback.error
    };
  }

  private static rememberGalleryUri(sourcePath: string, uri: string): void {
    if (GalleryAutoSaveService.savedUriBySourcePath.size >= MAX_REMEMBERED_GALLERY_URIS) {
      const keys: string[] = Array.from(GalleryAutoSaveService.savedUriBySourcePath.keys());
      const oldest: string | undefined = keys[0];
      if (oldest !== undefined) {
        GalleryAutoSaveService.savedUriBySourcePath.delete(oldest);
      }
    }
    GalleryAutoSaveService.savedUriBySourcePath.set(sourcePath, uri);
  }

  private static isGalleryStagingPath(context: common.Context, path: string): boolean {
    return path.startsWith(context.filesDir + '/incoming/quickshare/')
      || path.startsWith(context.filesDir + '/incoming/windowsnearby/')
      || path.startsWith(context.filesDir + '/incoming/mta/');
  }

  private static removeStagingFile(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (error) {
      Lg.w('[GALLERY] remove staging failed: ' + path + ' '
        + (error instanceof Error ? error.message : JSON.stringify(error)));
    }
  }

  private static notHandled(sourcePath: string): GalleryProcessResult {
    return {
      handled: false,
      savedToGallery: false,
      finalPath: sourcePath,
      assetUri: '',
      error: ''
    };
  }
}
