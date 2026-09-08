import { deviceInfo } from '@kit.BasicServicesKit';

/**
 * 当前运行系统 API 是否 >= 指定版本。
 */
export function isSdkAtLeast(minVersion: number): boolean {
  try {
    return deviceInfo.sdkApiVersion >= minVersion;
  } catch (err) {
    return false;
  }
}

/**
 * 当前运行系统 API 是否 >= 26。
 *
 * 注意：沉浸光感（systemMaterial / uiMaterial）全部为 API 26（@since 26）新增接口，
 * 在 API 24 SDK 下不存在，因此本文件已移除所有 uiMaterial / systemMaterial 调用，
 * 统一回退到旧毛玻璃样式（backgroundBlurStyle(Thin)）。
 */
export function isApi26OrAbove(): boolean {
  return isSdkAtLeast(26);
}

/**
 * 沉浸光感修饰器（API 24 兼容版）。
 * 原实现会在 API >= 26 且开启时调用 systemMaterial(uiMaterial.Material)，此为
 * @since 26 接口，无法用 API 24 SDK 编译。现统一使用 API 12 起可用的
 * backgroundBlurStyle(BlurStyle.Thin) 旧毛玻璃效果。
 */
export class ImmersiveMaterialModifier implements AttributeModifier<CommonAttribute> {
  applyNormalAttribute(instance: CommonAttribute): void {
    instance.backgroundBlurStyle(BlurStyle.Thin);
  }
}

export const immersiveMaterialModifier: ImmersiveMaterialModifier = new ImmersiveMaterialModifier();

/**
 * 旧毛玻璃修饰器（低版本渲染效果）。
 */
export class LegacyMaterialModifier implements AttributeModifier<CommonAttribute> {
  applyNormalAttribute(instance: CommonAttribute): void {
    instance.backgroundBlurStyle(BlurStyle.Thin);
  }
}

export const legacyMaterialModifier: LegacyMaterialModifier = new LegacyMaterialModifier();

/**
 * 底部面板（bindSheet/blurStyle）使用旧毛玻璃模糊。
 * @since 24 及更高均可用（BlurStyle.Thin）。
 */
export function sheetBlurStyle(): BlurStyle | undefined {
  return BlurStyle.Thin;
}
