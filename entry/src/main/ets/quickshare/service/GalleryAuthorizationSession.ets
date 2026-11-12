/**
 * 权威依据：HarmonyOS SaveButton 临时媒体库授权契约；用户 2026-11-07 需求。
 * 本轮改动：用进程内、有限时长的会话记录一次成功授权，供后续媒体文件复用。
 * 用户侧：授权状态由设置行和授权对话框用功能文案说明，不显示 API 名。
 * 🔴 红线：不得把授权状态持久化，不得声称跨进程或永久有效。
 */

import { LogCapture as Lg } from '../../common/LogCapture';

export const GALLERY_AUTHORIZATION_ACTIVE_KEY: string = 'galleryAuthorizationActive';

/**
 * SaveButton 的临时媒体库授权只存在进程内。
 *
 * SDK 对 API 20+ 的公开契约是 1 分钟。这里采用 55 秒，给 createAsset 前的准备留余量；
 * 已经取得的图库写句柄仍然可以继续写完。
 */
const SAFE_AUTHORIZATION_WINDOW_MS: number = 55 * 1000;

export class GalleryAuthorizationSession {
  private static expiresAtMs: number = 0;
  private static expiryTimer: number = -1;

  static activate(): void {
    GalleryAuthorizationSession.clearTimer();
    GalleryAuthorizationSession.expiresAtMs = Date.now() + SAFE_AUTHORIZATION_WINDOW_MS;
    AppStorage.setOrCreate(GALLERY_AUTHORIZATION_ACTIVE_KEY, true);
    GalleryAuthorizationSession.expiryTimer = setTimeout((): void => {
      GalleryAuthorizationSession.invalidate('expired');
    }, SAFE_AUTHORIZATION_WINDOW_MS);
    Lg.i('[GALLERY] authorization active for ' + SAFE_AUTHORIZATION_WINDOW_MS + 'ms');
  }

  static isActive(): boolean {
    return Date.now() < GalleryAuthorizationSession.expiresAtMs;
  }

  static invalidate(reason: string): void {
    GalleryAuthorizationSession.clearTimer();
    GalleryAuthorizationSession.expiresAtMs = 0;
    AppStorage.setOrCreate(GALLERY_AUTHORIZATION_ACTIVE_KEY, false);
    if (reason.length > 0) {
      Lg.i('[GALLERY] authorization invalidated: ' + reason);
    }
  }

  static resetForAppStart(): void {
    GalleryAuthorizationSession.expiresAtMs = 0;
    GalleryAuthorizationSession.clearTimer();
    AppStorage.setOrCreate(GALLERY_AUTHORIZATION_ACTIVE_KEY, false);
  }

  static remainingMs(): number {
    const remaining: number = GalleryAuthorizationSession.expiresAtMs - Date.now();
    return remaining > 0 ? remaining : 0;
  }

  private static clearTimer(): void {
    if (GalleryAuthorizationSession.expiryTimer >= 0) {
      clearTimeout(GalleryAuthorizationSession.expiryTimer);
      GalleryAuthorizationSession.expiryTimer = -1;
    }
  }
}
