import { LogCapture as Lg } from '../common/LogCapture';
import dataPreferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';

/** One persisted Windows Nearby transfer record (receive or send). */
export interface WindowsNearbyHistoryEntry {
  readonly id: string;
  readonly name: string;
  readonly size: number;
  readonly direction: 'send' | 'receive';
  readonly peer: string;
  readonly completedAt: number;
  /** Real file system path so the home page can offer an "open" action. */
  readonly savedPath: string;
}

/** A single file inside a live Windows Nearby transfer. */
export interface WindowsNearbyLiveFile {
  readonly name: string;
  readonly size: number;
  readonly savedPath: string;
}

/**
 * Live transfer state shared between the Windows Nearby page and the home page
 * via AppStorage. Stored as a JSON string to keep the cross-page contract simple
 * and safe to parse in ArkTS.
 */
export interface WindowsNearbyLiveState {
  readonly peer: string;
  readonly percent: number;
  readonly completed: boolean;
  readonly files: ReadonlyArray<WindowsNearbyLiveFile>;
}

export const WINDOWS_NEARBY_LIVE_KEY: string = 'windowsNearbyLive';
export const EMPTY_WINDOWS_NEARBY_LIVE: string = '{"peer":"","percent":0,"completed":false,"files":[]}';

const STORE_NAME: string = 'cashmere_windowsnearby_history';
const MAX_ENTRIES: number = 200;

/**
 * Persistent Windows Nearby transfer history (Preferences-backed). Survives app
 * restarts and is shown on the home page's record tab.
 */
export class WindowsNearbyHistory {
  private static entries: WindowsNearbyHistoryEntry[] = [];
  private static loaded: boolean = false;
  private static loading?: Promise<void>;
  private static writes: Promise<void> = Promise.resolve();

  static async load(context: common.Context): Promise<void> {
    if (WindowsNearbyHistory.loaded) {
      return;
    }
    if (WindowsNearbyHistory.loading === undefined) {
      WindowsNearbyHistory.loading = WindowsNearbyHistory.readStore(context);
    }
    await WindowsNearbyHistory.loading;
  }

  private static async readStore(context: common.Context): Promise<void> {
    try {
      const store = await dataPreferences.getPreferences(context, STORE_NAME);
      const raw = await store.get('entries', '[]');
      let parsed: WindowsNearbyHistoryEntry[] = [];
      if (typeof raw === 'string' && raw.length > 0) {
        const value = JSON.parse(raw) as WindowsNearbyHistoryEntry[];
        if (Array.isArray(value)) {
          parsed = value;
        }
      }
      WindowsNearbyHistory.entries = parsed;
    } catch (error) {
      Lg.w('WindowsNearbyHistory load failed: ' + JSON.stringify(error));
      WindowsNearbyHistory.entries = [];
    }
    WindowsNearbyHistory.loaded = true;
  }

  static async add(context: common.Context, entry: WindowsNearbyHistoryEntry): Promise<void> {
    WindowsNearbyHistory.writes = WindowsNearbyHistory.writes.then((): Promise<void> =>
      WindowsNearbyHistory.addStored(context, entry));
    await WindowsNearbyHistory.writes;
  }

  private static async addStored(context: common.Context, entry: WindowsNearbyHistoryEntry): Promise<void> {
    await WindowsNearbyHistory.load(context);
    WindowsNearbyHistory.entries = [entry].concat(WindowsNearbyHistory.entries).slice(0, MAX_ENTRIES);
    try {
      const store = await dataPreferences.getPreferences(context, STORE_NAME);
      await store.put('entries', JSON.stringify(WindowsNearbyHistory.entries));
      await store.flush();
    } catch (error) {
      Lg.w('WindowsNearbyHistory add failed: ' + JSON.stringify(error));
    }
  }

  static list(): WindowsNearbyHistoryEntry[] {
    return WindowsNearbyHistory.entries.slice();
  }

  static async clear(context: common.Context): Promise<void> {
    WindowsNearbyHistory.writes = WindowsNearbyHistory.writes.then((): Promise<void> =>
      WindowsNearbyHistory.clearStored(context));
    await WindowsNearbyHistory.writes;
  }

  private static async clearStored(context: common.Context): Promise<void> {
    await WindowsNearbyHistory.load(context);
    WindowsNearbyHistory.entries = [];
    try {
      const store = await dataPreferences.getPreferences(context, STORE_NAME);
      await store.delete('entries');
      await store.flush();
    } catch (error) {
      Lg.w('WindowsNearbyHistory clear failed: ' + JSON.stringify(error));
    }
  }
}
