import { SettingsStore } from '../../common/SettingsStore';
import { GalleryAuthorizationSession } from './GalleryAuthorizationSession';

/** 接收完成后才申请授权；同时到达的文件共用一个提示，业务层不持有 UI 对象。 */
export class GalleryAuthorizationRequest {
  private static presenter?: () => Promise<boolean>;
  private static dismiss?: () => void;
  private static foreground: boolean = false;
  private static pending?: Promise<boolean>;
  private static resolvePending?: (granted: boolean) => void;
  private static generation: number = 0;
  private static timer: number = -1;

  private static clearTimer(): void {
    if (GalleryAuthorizationRequest.timer !== -1) {
      clearTimeout(GalleryAuthorizationRequest.timer);
      GalleryAuthorizationRequest.timer = -1;
    }
  }

  static configure(presenter?: () => Promise<boolean>, dismiss?: () => void): void {
    GalleryAuthorizationRequest.cancelPending();
    GalleryAuthorizationRequest.presenter = presenter;
    GalleryAuthorizationRequest.dismiss = dismiss;
  }

  static setForeground(foreground: boolean): void {
    GalleryAuthorizationRequest.foreground = foreground;
    if (!foreground) { GalleryAuthorizationRequest.cancelPending(); }
  }

  static cancelPending(): void {
    GalleryAuthorizationRequest.generation++;
    GalleryAuthorizationRequest.clearTimer();
    const resolve = GalleryAuthorizationRequest.resolvePending;
    GalleryAuthorizationRequest.resolvePending = undefined;
    GalleryAuthorizationRequest.pending = undefined;
    if (resolve !== undefined) { resolve(false); }
    GalleryAuthorizationRequest.dismiss?.();
  }

  static request(): Promise<boolean> {
    if (SettingsStore.current().saveReceivedMediaToGallery !== true) { return Promise.resolve(false); }
    if (GalleryAuthorizationSession.isActive()) { return Promise.resolve(true); }
    if (GalleryAuthorizationRequest.pending !== undefined) { return GalleryAuthorizationRequest.pending; }
    const presenter = GalleryAuthorizationRequest.presenter;
    if (!GalleryAuthorizationRequest.foreground || presenter === undefined) { return Promise.resolve(false); }
    const generation: number = ++GalleryAuthorizationRequest.generation;
    const pending = new Promise<boolean>((resolve: (granted: boolean) => void): void => {
      GalleryAuthorizationRequest.resolvePending = resolve;
      GalleryAuthorizationRequest.timer = setTimeout((): void => {
        if (generation === GalleryAuthorizationRequest.generation) { GalleryAuthorizationRequest.cancelPending(); }
      }, 60000);
      Promise.resolve().then((): Promise<boolean> => {
        return generation === GalleryAuthorizationRequest.generation ? presenter() : Promise.resolve(false);
      }).then((granted: boolean): void => {
        GalleryAuthorizationRequest.complete(generation, granted);
      }).catch((): void => { GalleryAuthorizationRequest.complete(generation, false); });
    });
    GalleryAuthorizationRequest.pending = pending;
    return pending;
  }

  private static complete(generation: number, granted: boolean): void {
    if (generation !== GalleryAuthorizationRequest.generation) { return; }
    GalleryAuthorizationRequest.clearTimer();
    const resolve = GalleryAuthorizationRequest.resolvePending;
    GalleryAuthorizationRequest.resolvePending = undefined;
    GalleryAuthorizationRequest.pending = undefined;
    resolve?.(granted && GalleryAuthorizationSession.isActive()
      && SettingsStore.current().saveReceivedMediaToGallery === true);
  }
}
