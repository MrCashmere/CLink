import { LogCapture as Lg } from '../common/LogCapture';
import dataPreferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { SecurityUtils } from './SecurityUtils';

const STORE_NAME = 'cashmere_settings';
const DEVICE_ID_KEY = 'localsend_fingerprint';
const MAX_ID_LEN = 64;

export class DeviceIdentity {
  private static cached = '';

  static async load(context: common.Context): Promise<string> {
    if (DeviceIdentity.cached.length > 0) {
      return DeviceIdentity.cached;
    }
    try {
      const store = await dataPreferences.getPreferences(context, STORE_NAME);
      const stored = await store.get(DEVICE_ID_KEY, '') as string;
      const clean = DeviceIdentity.sanitize(stored);
      if (clean.length > 0) {
        DeviceIdentity.cached = clean;
        return clean;
      }
      const fresh = SecurityUtils.createToken();
      const id = DeviceIdentity.sanitize(fresh);
      await store.put(DEVICE_ID_KEY, id);
      await store.flush();
      DeviceIdentity.cached = id;
      return id;
    } catch (error) {
      Lg.w(`DeviceIdentity load failed: ${JSON.stringify(error)}`);
      const fallback = DeviceIdentity.sanitize(SecurityUtils.createToken());
      DeviceIdentity.cached = fallback;
      return fallback;
    }
  }

  private static sanitize(value: string): string {
    const trimmed = value.trim();
    if (trimmed.length < 8 || trimmed.length > MAX_ID_LEN) {
      return '';
    }
    if (!/^[A-Za-z0-9\-_]{8,64}$/.test(trimmed)) {
      return '';
    }
    return trimmed;
  }
}
