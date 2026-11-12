import { IncomingFile, SessionFileMeta } from '../../model/TransferModels';

export type QuickShareListener<T> = (event: T) => void;

/** App 级 Quick Share 接收事件（由 AppServices 兜底记录/持久化，页面按 kind 消费）。 */
export interface QuickShareServiceEvent {
  readonly kind: 'incoming' | 'file' | 'progress' | 'transport';
  readonly key?: string;
  readonly peerName?: string;
  readonly files?: SessionFileMeta[];
  readonly pin?: string;
  readonly file?: IncomingFile;
  readonly peer?: string;
  readonly percent?: number;
  /** kind==='transport' 时的人类可读说明（升级成功/失败/留在原通道）。 */
  readonly detail?: string;
}

/** 页面注册的接收确认回调：返回 true 表示接受会话（进行文件落盘），false 表示拒绝。 */
export type IncomingSessionHandler = (peerName: string, files: SessionFileMeta[], pin: string) => Promise<boolean>;

export class QuickShareEventEmitter<T> {
  private readonly listeners: Set<QuickShareListener<T>> = new Set<QuickShareListener<T>>();

  on(listener: QuickShareListener<T>): void { this.listeners.add(listener); }
  off(listener: QuickShareListener<T>): void { this.listeners.delete(listener); }
  emit(event: T): void { this.listeners.forEach((listener: QuickShareListener<T>): void => listener(event)); }
  clear(): void { this.listeners.clear(); }
}
