import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
class MtaHostPreferences {
  private store?: preferences.Preferences;
  init(context: common.Context): void {
    this.store = preferences.getPreferencesSync(context, { name: 'handysend_mta' });
  }
  getString(key: string, fallback: string): string {
    const stored = this.store?.getSync(key, fallback);
    return typeof stored === 'string' ? stored : fallback;
  }
  setString(key: string, text: string): void {
    if (this.store === undefined) { throw new Error('MTA 存储尚未初始化'); }
    this.store.putSync(key, text);
    this.store.flushSync();
  }
}
export const preferencesRepo: MtaHostPreferences = new MtaHostPreferences();
