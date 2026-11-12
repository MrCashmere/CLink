import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import fs from '@ohos.file.fs';
import { LogCapture as Lg } from './LogCapture';
import { PendingDynamicPhoto } from './DynamicPhotoBridge';

const textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8');

/**
 * 「待保存的鸿蒙动态照片」登记表。
 *
 * 当应用没有写图库权限（ohos.permission.WRITE_IMAGEVIDEO 为 system_basic，
 * 普通应用通常拿不到）时，photoAccessHelper.applyChanges 会失败；此时把已经解析好、
 * 躺在应用沙箱里的「图片 + 视频」登记进来，由 UI 用 SaveButton 安全控件在用户点击时
 * 完成落库（SaveButton 会授予一次性的临时写权限，无需申请权限）。
 *
 * 登记表放在 AppStorage 里，页面通过 @StorageLink 拿到列表即可渲染。
 */

/** AppStorage 键名。 */
export const PENDING_DYNAMIC_PHOTOS_KEY = 'pendingDynamicPhotos';

/** 登记上限：避免异常情况下无限堆积。 */
const MAX_PENDING = 20;

/** 落盘文件名：登记表必须跨进程重启存活，否则用户还没来得及点保存就丢了。 */
const PENDING_FILE_NAME = 'dynamicPhotoPending.json';

let storeContext: common.Context | undefined = undefined;

function pendingFilePath(): string {
  return storeContext !== undefined ? storeContext.filesDir + '/' + PENDING_FILE_NAME : '';
}

function readRaw(): string {
  try {
    const raw = AppStorage.get<string>(PENDING_DYNAMIC_PHOTOS_KEY);
    return typeof raw === 'string' ? raw : '';
  } catch (error) {
    return '';
  }
}

export class PendingDynamicPhotoStore {
  /**
   * 启动时调用一次：把上次未保存完的登记表读回 AppStorage。
   *
   * 为什么需要：落库必须由用户点一次 SaveButton，用户可能先杀掉应用再回来点 ——
   * 只放在 AppStorage（内存）里的话，那条待保存动态照片就永远消失了。
   */
  static load(context: common.Context): void {
    storeContext = context;
    try {
      const path = pendingFilePath();
      if (path.length === 0 || !fs.accessSync(path)) {
        return;
      }
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const size = fs.statSync(path).size;
        if (size <= 0 || size > 1024 * 1024) {
          return;
        }
        const buffer = new ArrayBuffer(size);
        const read = fs.readSync(file.fd, buffer);
        const bytes = new Uint8Array(buffer.slice(0, read));
        const text = textDecoder.decodeToString(bytes);
        AppStorage.setOrCreate(PENDING_DYNAMIC_PHOTOS_KEY, text);
        Lg.i('[DYNAMIC] pending list restored: ' + text.length + ' bytes');
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      Lg.w('[DYNAMIC] pending list restore failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 解析登记表 JSON 文本。
   *
   * 为什么单独暴露：ArkUI 的状态依赖是「build 里读过这个状态变量才会重画」，
   * UI 组件必须把 `@StorageLink` 拿到的**变量本身**交给本函数解析，
   * 不能绕过去直接读 AppStorage（那样 build 没读到变量，登记了新照片也不会重画）。
   */
  static parse(raw: string): PendingDynamicPhoto[] {
    try {
      if (raw.length === 0) {
        return [];
      }
      const parsed = JSON.parse(raw) as PendingDynamicPhoto[];
      if (!Array.isArray(parsed)) {
        return [];
      }
      return parsed.filter((item: PendingDynamicPhoto): boolean =>
        item !== undefined && item !== null && typeof item.imagePath === 'string'
          && typeof item.videoPath === 'string');
    } catch (error) {
      Lg.w('[DYNAMIC] pending list parse failed: ' + JSON.stringify(error));
      return [];
    }
  }

  /** 读取当前登记的全部待保存动态照片（最新的在前）。 */
  static list(): PendingDynamicPhoto[] {
    return PendingDynamicPhotoStore.parse(readRaw());
  }

  static count(): number {
    return PendingDynamicPhotoStore.list().length;
  }

  /** 登记一条待保存动态照片，返回是否登记成功（同图同视频去重）。 */
  static add(photo: PendingDynamicPhoto): boolean {
    const existing = PendingDynamicPhotoStore.list();
    for (const item of existing) {
      if (item.imagePath === photo.imagePath && item.videoPath === photo.videoPath) {
        return false;
      }
    }
    const next: PendingDynamicPhoto[] = [photo];
    for (const item of existing) {
      if (next.length >= MAX_PENDING) {
        break;
      }
      next.push(item);
    }
    PendingDynamicPhotoStore.write(next);
    return true;
  }

  /** 移除一条（用户已保存或放弃）。 */
  static remove(imagePath: string, videoPath: string): void {
    const next = PendingDynamicPhotoStore.list().filter((item: PendingDynamicPhoto): boolean =>
      !(item.imagePath === imagePath && item.videoPath === videoPath));
    PendingDynamicPhotoStore.write(next);
  }

  static clear(): void {
    PendingDynamicPhotoStore.write([]);
  }

  private static write(items: PendingDynamicPhoto[]): void {
    const json = JSON.stringify(items);
    try {
      AppStorage.setOrCreate(PENDING_DYNAMIC_PHOTOS_KEY, json);
    } catch (error) {
      Lg.w('[DYNAMIC] pending list write failed: ' + JSON.stringify(error));
    }
    const path = pendingFilePath();
    if (path.length === 0) {
      return;
    }
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, json);
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      Lg.w('[DYNAMIC] pending list persist failed: ' + JSON.stringify(error));
    }
  }
}
