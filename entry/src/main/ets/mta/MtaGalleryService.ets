import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { DynamicPhotoService, IncomingFileLike } from '../common/DynamicPhotoService';
import { HdrPhotoService } from '../common/HdrPhotoService';
import { LogCapture as Lg } from '../common/LogCapture';
import { GalleryAutoSaveService } from '../quickshare/service/GalleryAutoSaveService';
import { ReceivedFileEntry } from './upstream/model/mta/MtaProtocolModels';

/** 宿主的落盘策略；上游接收编排只调用适配器，不依赖图库实现。 */
export class MtaGalleryService {
  static receiveDirectory(context: common.Context, original: string): string {
    if (!GalleryAutoSaveService.enabled() && !DynamicPhotoService.enabled() && !HdrPhotoService.enabled()) {
      return original;
    }
    const root: string = context.filesDir + '/incoming/mta';
    if (!fs.accessSync(root)) { fs.mkdirSync(root, true); }
    // ZIP 内可能包含同名文件；每批独占目录，避免和上一次待保存素材相互覆盖。
    return fs.mkdtempSync(root + '/batch-XXXXXX');
  }

  static async finishReceived(context: common.Context, paths: string[], metas: ReceivedFileEntry[]): Promise<string[]> {
    const firstPath = paths[0] ?? '';
    const scope = 'mta:' + firstPath.substring(0, firstPath.lastIndexOf('/'));
    const batch: IncomingFileLike[] = paths.map((path: string, index: number): IncomingFileLike => ({
      name: metas[index]?.name ?? path.substring(path.lastIndexOf('/') + 1),
      size: metas[index]?.size ?? 0,
      savedPath: path
    }));
    // 全部动态照片先判归属，再处理普通媒体，避免先删掉另一个素材的源文件。
    for (const file of batch) {
      if (!file.savedPath.startsWith(context.filesDir + '/incoming/mta/')) { continue; }
      if (DynamicPhotoService.wasHandledForGallery(file.savedPath)) { continue; }
      try { await DynamicPhotoService.settleReceivedFile(context, file, batch, scope); }
      catch (error) { Lg.w('[GALLERY] mta dynamic settle failed: ' + String(error)); }
    }
    const resolved: string[] = [];
    for (let index = 0; index < batch.length; index++) {
      const file: IncomingFileLike = batch[index];
      let finalPath: string = file.savedPath;
      if (finalPath.startsWith(context.filesDir + '/incoming/mta/')) {
        try {
          const result = await GalleryAutoSaveService.processCompleted(context, finalPath,
            file.name, file.size, true, metas[index]?.fileType ?? '');
          finalPath = result.finalPath;
          Lg.i('[GALLERY] mta gallery=' + result.savedToGallery + ' final=' + finalPath + ' error=' + result.error);
        } catch (error) { Lg.w('[GALLERY] mta save failed; source retained: ' + String(error)); }
      }
      resolved.push(finalPath);
    }
    await DynamicPhotoService.settleBatch(context, batch, scope);
    return resolved;
  }
}
