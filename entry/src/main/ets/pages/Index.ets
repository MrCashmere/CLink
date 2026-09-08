import { common } from '@kit.AbilityKit';
import { MainPage } from '../view/MainPage';
import { NearbyScanHub } from '../common/NearbyScanHub';

@Entry
@Component
struct Index {
  onPageShow(): void {
    // 从独立的 QuickShare / NearSharing 页面返回时，这些页面会按各自逻辑停止全局 BLE
    // 扫描（BLE 是全局单例），这里重新断言全局三协议扫描，避免 Windows BLE 发现被覆盖后
    // 无法恢复。仅接收扫描在应用进程生命周期内常开，此处只做恢复。
    const context = getContext(this) as common.UIAbilityContext;
    NearbyScanHub.get(context).ensureActive();
  }

  build() {
    Column() {
      MainPage()
    }
    .width('100%')
    .height('100%')
  }
}
