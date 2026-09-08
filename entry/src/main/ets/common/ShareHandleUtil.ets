import { LogCapture as Lg } from '../common/LogCapture';
import { Want } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { OutgoingFile } from '../model/TransferModels';

/**
 * 系统分享接入工具。
 *
 * 通过 module.json5 中 EntryAbility 的 skills（entity.system.share）接收系统分享面板
 * 的隐式 Want。当用户从系统分享面板选择本应用时，EntryAbility 的 onCreate/onNewWant
 * 被回调，这里负责从 want 中提取共享文件 URI 并暂存到 AppStorage，供 ShareChoosePage
 * 读取。导航动作由常驻的 MainPage 通过 @StorageLink 监听 shareRequestCounter 触发，
 * 以同时覆盖冷启动（aboutToAppear）与热启动（onNewWant -> AppStorage Watch）两种情况。
 *
 * 注意：共享 URI 是临时的只读授权，ShareChoosePage 应在选定传输通道后尽快把文件
 * 拷贝到应用自己的目录，避免授权失效。
 */

/** AppStorage 里暂存待处理共享文件 URI 数组的键。 */
export const SHARE_URIS_KEY: string = 'pendingShareUris';
/** AppStorage 里递增的分享请求计数器，用于触发页面导航（即使是同一批次重复分享）。 */
export const SHARE_COUNTER_KEY: string = 'shareRequestCounter';

/** 判断 want 是否来自系统分享面板。 */
export function isShareWant(want: Want): boolean {
  try {
    const action = want.action ?? '';
    if (action === 'ohos.want.action.sendData' || action === 'ohos.want.action.viewData') {
      return true;
    }
    if (Array.isArray(want.entities) && want.entities.indexOf('entity.system.share') >= 0) {
      return true;
    }
  } catch (error) {
    return false;
  }
  return false;
}

/** 判断字符串是否像共享文件 URI（file/datashare/content 开头的 uri）。 */
function isUriLike(value: string): boolean {
  return value.startsWith('file://') || value.startsWith('datashare://')
    || value.startsWith('content://') || value.startsWith('file:///')
    || (value.indexOf('://') > 0 && value.indexOf('/') > value.indexOf('://'));
}

/** 把 ESObject 参数值中所有像 URI 的字符串收集进 result。 */
function collectUriValues(value: ESObject, add: (uri: string) => void): void {
  if (Array.isArray(value)) {
    const items: ESObject[] = value as ESObject[];
    for (let i = 0; i < items.length; i++) {
      const item: ESObject = items[i];
      if (typeof item === 'string') {
        const uri: string = item as string;
        if (isUriLike(uri)) {
          add(uri);
        }
      }
    }
    return;
  }
  if (typeof value === 'string') {
    const uri: string = value as string;
    if (isUriLike(uri)) {
      add(uri);
    }
  }
}

/** 从 want 中提取共享文件 URI 数组（兼容单/多文件、多参数键）。 */
export function extractSharedUris(want: Want): string[] {
  const result: string[] = [];
  const seen = new Set<string>();
  const add = (uri: string): void => {
    if (uri.length > 0 && !seen.has(uri)) {
      seen.add(uri);
      result.push(uri);
    }
  };
  try {
    const params = want.parameters ?? {};
    // 已知的、文档化的参数键。
    const knownKeys: string[] = [
      'ohos.extra.param.key.content_uris',
      'ohos.extra.param.key.uri',
      'share.abc.uri',
      'key_want_uri'
    ];
    for (const key of knownKeys) {
      collectUriValues(params[key] as ESObject, add);
    }
    // 兜底：遍历所有参数值，收集任何像 URI 的字符串，覆盖未知键名。
    Object.keys(params).forEach((key: string): void => {
      collectUriValues(params[key] as ESObject, add);
    });
    if (typeof want.uri === 'string' && isUriLike(want.uri)) {
      add(want.uri);
    }
  } catch (error) {
    Lg.w('ShareHandleUtil extractSharedUris error: ' + JSON.stringify(error));
  }
  return result;
}

/**
 * 处理来自系统分享面板的 Want：提取 URI 暂存到 AppStorage，并递增计数器触发
 * MainPage 导航到 ShareChoosePage。若 want 非分享意图则忽略。
 */
export function handleSharedWant(want: Want): void {
  if (!isShareWant(want)) {
    return;
  }
  const uris = extractSharedUris(want);
  if (uris.length === 0) {
    Lg.w('ShareHandleUtil: share want without uri, ignoring');
    return;
  }
  AppStorage.setOrCreate(SHARE_URIS_KEY, uris);
  const counter: number = AppStorage.get<number>(SHARE_COUNTER_KEY) ?? 0;
  AppStorage.setOrCreate(SHARE_COUNTER_KEY, counter + 1);
  Lg.i('ShareHandleUtil: captured ' + uris.length + ' shared uri(s)');
}

/** 是否存在待处理的共享 URI。 */
export function hasPendingShare(): boolean {
  const uris = AppStorage.get<string[]>(SHARE_URIS_KEY);
  return uris !== undefined && uris.length > 0;
}

/** 读取但不消费待处理共享 URI（ShareChoosePage 显示用）。 */
export function peekPendingShareUris(): string[] {
  const raw = AppStorage.get<string[]>(SHARE_URIS_KEY);
  return raw === undefined ? [] : raw;
}

/** 读取并清空待处理共享 URI。 */
export function consumePendingShareUris(): string[] {
  const raw = AppStorage.get<string[]>(SHARE_URIS_KEY);
  AppStorage.setOrCreate(SHARE_URIS_KEY, []);
  return raw === undefined ? [] : raw;
}

/** 取 URI 的展示文件名。 */
export function nameOfUri(uri: string): string {
  const parts = uri.split('/');
  const last = parts[parts.length - 1] ?? 'file';
  try {
    return decodeURIComponent(last);
  } catch (error) {
    return last;
  }
}

/**
 * 从路由参数中读取系统分享载入的共享文件，组装成 OutgoingFile[]。
 * ShareChoosePage 选择通道后，用 router.replaceUrl 携带 sharePaths/shareNames/
 * shareSizes 参数跳转，目标页面 aboutToAppear 时调用本函数载入已选择文件。
 * 无参数或参数异常时返回空数组。
 */
export function sharedFilesFromParams(): OutgoingFile[] {
  const files: OutgoingFile[] = [];
  try {
    const params = router.getParams() as Record<string, Object>;
    if (params === undefined) {
      return files;
    }
    const pathValue = params['sharePaths'];
    if (!Array.isArray(pathValue)) {
      return files;
    }
    const paths = pathValue as string[];
    const nameValue = params['shareNames'];
    const sizeValue = params['shareSizes'];
    const names: string[] = Array.isArray(nameValue) ? (nameValue as string[]) : [];
    const sizes: number[] = Array.isArray(sizeValue) ? (sizeValue as number[]) : [];
    for (let i = 0; i < paths.length; i++) {
      const path = paths[i];
      files.push({
        path: path,
        name: i < names.length ? names[i] : nameOfUri(path),
        size: i < sizes.length ? Number(sizes[i] ?? 0) : 0,
        mime: 'application/octet-stream'
      });
    }
  } catch (error) {
    Lg.w('ShareHandleUtil sharedFilesFromParams error: ' + JSON.stringify(error));
  }
  return files;
}
