import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/**
 * 外观设置存储。
 * 采用同步 preferences，与 miha 项目保持一致，用于持久化字体、字号、
 * 字重、背景图、卡片排列等外观相关设置。
 */
const STORE_NAME = 'cashmere_appearance';

export class AppSettingsStore {
  private static prefs: preferences.Preferences | null = null;

  static init(context: common.UIAbilityContext): void {
    if (AppSettingsStore.prefs === null) {
      AppSettingsStore.prefs = preferences.getPreferencesSync(context, {
        name: STORE_NAME
      });
    }
  }

  private static store(): preferences.Preferences {
    if (AppSettingsStore.prefs === null) {
      throw new Error('settings store not initialized');
    }
    return AppSettingsStore.prefs;
  }

  static has(key: string): boolean {
    return AppSettingsStore.store().hasSync(key);
  }

  static getAll(): Record<string, Object> {
    return AppSettingsStore.store().getAllSync() as Record<string, Object>;
  }

  static getBoolean(key: string, defaultValue: boolean): boolean {
    const value = AppSettingsStore.store().getSync(key, defaultValue);
    return typeof value === 'boolean' ? value : defaultValue;
  }

  static getString(key: string, defaultValue: string): string {
    const value = AppSettingsStore.store().getSync(key, defaultValue);
    return typeof value === 'string' ? value : defaultValue;
  }

  static getNumber(key: string, defaultValue: number): number {
    const value = AppSettingsStore.store().getSync(key, defaultValue);
    return typeof value === 'number' ? value : defaultValue;
  }

  static getStringArray(key: string, defaultValue: string[]): string[] {
    const raw = AppSettingsStore.getString(key, '');
    if (raw.length === 0) {
      return defaultValue.slice();
    }
    try {
      const parsed = JSON.parse(raw) as Object;
      if (parsed instanceof Array) {
        return parsed.map((item: Object) => String(item));
      }
    } catch (err) {
    }
    return defaultValue.slice();
  }

  static setBoolean(key: string, value: boolean): void {
    AppSettingsStore.store().putSync(key, value);
    AppSettingsStore.store().flushSync();
  }

  static setString(key: string, value: string): void {
    AppSettingsStore.store().putSync(key, value);
    AppSettingsStore.store().flushSync();
  }

  static setNumber(key: string, value: number): void {
    AppSettingsStore.store().putSync(key, value);
    AppSettingsStore.store().flushSync();
  }

  static setStringArray(key: string, value: string[]): void {
    AppSettingsStore.setString(key, JSON.stringify(value));
  }

  static delete(key: string): void {
    AppSettingsStore.store().deleteSync(key);
    AppSettingsStore.store().flushSync();
  }
}
