import { LogCapture as Lg } from '../../common/LogCapture';
import dataPreferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';

export interface QuickShareTransferHistoryEntry {
  readonly id: string;
  readonly name: string;
  readonly size: number;
  readonly direction: 'send' | 'receive';
  readonly peer: string;
  readonly completedAt: number;
  /** 接收成功的文件保存路径，发送记录或无法打开时为空。 */
  readonly savedPath: string;
}

const STORE_NAME = 'cashmere_quickshare_history';
const MAX_ENTRIES = 200;

/**
 * Persistent Quick Share transfer history (Preferences-backed). Survives app
 * restarts and is shared with the home page's record tab.
 */
export class QuickShareTransferHistory {
  private static entries: QuickShareTransferHistoryEntry[] = [];
  private static loaded: boolean = false;

  static async load(context: common.Context): Promise<void> {
    if (QuickShareTransferHistory.loaded) {
      return;
    }
    QuickShareTransferHistory.loaded = true;
    try {
      const store = await dataPreferences.getPreferences(context, STORE_NAME);
      const raw = await store.get('entries', '[]');
      let parsed: QuickShareTransferHistoryEntry[] = [];
      if (typeof raw === 'string' && raw.length > 0) {
        const value = JSON.parse(raw) as QuickShareTransferHistoryEntry[];
        if (Array.isArray(value)) {
          parsed = value.map((entry: QuickShareTransferHistoryEntry): QuickShareTransferHistoryEntry => ({
            id: entry.id,
            name: entry.name,
            size: entry.size,
            direction: entry.direction,
            peer: entry.peer,
            completedAt: entry.completedAt,
            savedPath: entry.savedPath ?? ''
          }));
        }
      }
      QuickShareTransferHistory.entries = parsed;
    } catch (error) {
      Lg.w('QuickShareTransferHistory load failed: ' + JSON.stringify(error));
      QuickShareTransferHistory.entries = [];
    }
  }

  static async add(context: common.Context, entry: QuickShareTransferHistoryEntry): Promise<void> {
    await QuickShareTransferHistory.load(context);
    QuickShareTransferHistory.entries = [entry].concat(QuickShareTransferHistory.entries).slice(0, MAX_ENTRIES);
    try {
      const store = await dataPreferences.getPreferences(context, STORE_NAME);
      await store.put('entries', JSON.stringify(QuickShareTransferHistory.entries));
      await store.flush();
    } catch (error) {
      Lg.w('QuickShareTransferHistory add failed: ' + JSON.stringify(error));
    }
  }

  static list(): QuickShareTransferHistoryEntry[] {
    return QuickShareTransferHistory.entries.slice();
  }

  static async clear(context: common.Context): Promise<void> {
    QuickShareTransferHistory.entries = [];
    try {
      const store = await dataPreferences.getPreferences(context, STORE_NAME);
      await store.delete('entries');
      await store.flush();
    } catch (error) {
      Lg.w('QuickShareTransferHistory clear failed: ' + JSON.stringify(error));
    }
  }
}
