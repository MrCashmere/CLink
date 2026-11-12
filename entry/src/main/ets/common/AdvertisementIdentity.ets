import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { LogCapture as Lg } from './LogCapture';
import { SecurityUtils } from './SecurityUtils';

const STORE_NAME = 'cashmere_advertisement';
const KEY_NEARBY_ENDPOINT_ID = 'nearby_endpoint_id';
const KEY_LOCALSEND_SUFFIX = 'localsend_instance_suffix';

/**
 * mDNS 广播身份（跨启动固定）。
 *
 * 为什么必须持久化：系统 mdns 守护进程会保留每一次 `addLocalService` 注册，而且这些注册
 * 比 App 进程活得更久。旧实现每次进 Quick Share 页面 / 重启扫描枢纽 / 重新启动 App 都会
 * 用一个**新的随机实例名**再注册一次，于是链路上同时存在十几个只属于本机的 Nearby 实例：
 * PC 官方 Quick Share 日志里出现了 **19 个「羊绒互传」目标**（device_id 各不相同），
 * 线缆上实测仍有 15 个 Nearby 实例在应答，其中一个还留在旧端口 33427 上。
 *
 * 固定实例名后，重复注册会被守护进程以 `Service instance duplicated`(2204007) 拒绝，
 * 因此不会再新增端点；对端列表里始终只有一个本机条目。
 */
export class AdvertisementIdentity {
  private static nearbyId = '';
  private static localSendSuffix = '';
  private static store?: preferences.Preferences;

  private static prefs(context: common.Context): preferences.Preferences {
    if (AdvertisementIdentity.store === undefined) {
      AdvertisementIdentity.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
    }
    return AdvertisementIdentity.store;
  }

  private static loadOrCreate(context: common.Context, key: string, length: number): string {
    try {
      const store = AdvertisementIdentity.prefs(context);
      const saved = store.getSync(key, '') as string;
      if (typeof saved === 'string' && saved.length === length) {
        return saved;
      }
      const fresh = SecurityUtils.createToken().slice(0, length);
      store.putSync(key, fresh);
      store.flushSync();
      Lg.i('[ADVID] generated advertisement identity ' + key + '=' + fresh);
      return fresh;
    } catch (error) {
      Lg.w('[ADVID] advertisement identity persistence failed: ' + JSON.stringify(error));
      return SecurityUtils.createToken().slice(0, length);
    }
  }

  /** Quick Share mDNS 服务名里的 4 字符 endpoint id。 */
  static nearbyEndpointId(context: common.Context): string {
    if (AdvertisementIdentity.nearbyId.length === 0) {
      AdvertisementIdentity.nearbyId =
        AdvertisementIdentity.loadOrCreate(context, KEY_NEARBY_ENDPOINT_ID, 4);
    }
    return AdvertisementIdentity.nearbyId;
  }

  /** LocalSend 广播实例名 `yangrong-<suffix>` 的后缀。 */
  static localSendInstanceSuffix(context: common.Context): string {
    if (AdvertisementIdentity.localSendSuffix.length === 0) {
      AdvertisementIdentity.localSendSuffix =
        AdvertisementIdentity.loadOrCreate(context, KEY_LOCALSEND_SUFFIX, 6);
    }
    return AdvertisementIdentity.localSendSuffix;
  }
}
