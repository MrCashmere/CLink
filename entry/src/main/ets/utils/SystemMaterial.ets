import { deviceInfo } from '@kit.BasicServicesKit';
import { uiMaterial } from '@kit.ArkUI';
import { PRESS_GLOW_STORAGE } from './DesignTokens';

/**
 * 系统级沉浸光感（systemMaterial / uiMaterial）适配层。
 *
 * 参考：@ohos.arkui.uiMaterial（起始版本 26.0.0）、CommonMethod#systemMaterial。
 * HarmonyOS 7.0（API 26.0.0）起，应用可以在 entry module 的 module.json5 中配置
 * metadata「ohos.arkui.UIMaterial.state = enable」开启应用级沉浸式系统材质。
 *
 * ─────────────────────────────────────────────────────────────────────────
 * 一、应用级状态
 * ─────────────────────────────────────────────────────────────────────────
 * `uiMaterial.getMaterialInfo().state` 读的就是 module.json5 里的 metadata：
 *   - default：普通组件可主动设置材质
 *   - enable ：更多系统组件自动使用材质，普通组件仍可主动设置
 *   - disable：关闭整个应用的沉浸材质，**主动设置的材质也一并失效**
 * 本工程显式配置为 enable。若这里读到 DISABLE，材质不会渲染——这不是代码能绕过的，
 * 必须先改 module.json5 并重新构建安装。
 *
 * ⚠️ 历史坑（已移除）：旧实现把「state === DISABLE」当成「本应用不能渲染」，
 * 直接返回 `Material.empty`，又把这个状态用作降级条件——等于应用自己把光感关掉，是自锁。
 * 现在 **MaterialState 只用于诊断展示**，材质只要构造成功就下发，画不画由系统按生效范围决定。
 *
 * ─────────────────────────────────────────────────────────────────────────
 * 二、生效范围（targetSdkVersion >= 26.0.0 时的系统行为变更）
 * ─────────────────────────────────────────────────────────────────────────
 *   - 弹窗类组件与弹窗类接口（AlertDialog、CustomDialog、bindSheet、Popup、Tips、菜单、
 *     Toast、PromptAction 等），以及
 *   - 按钮与选择类组件（Button / Select / Toggle / Slider / ChipGroup / SegmentButton）
 * 可以在页面内**全部区域**生效；其他组件（含 Column/Row 等布局容器）仅在
 * Navigation/NavDestination 标题栏、或横向 Tab 中 barPosition 为 BarPosition.End 的
 * 底部悬浮 TabBar 中生效。在其他区域设置 systemMaterial 不生效（系统日志：
 * "Material inactive: out of scope. Use component in navigation title bar or Tabbar."）。
 *
 * 因此内容区卡片不能把 systemMaterial 直接挂在 Column/Row 上，必须由 **Toggle 承载**
 * （见 components/CardSurface.ets 与 components/MaterialCard.ets）。
 * 各 ToggleType 的差异（官方原文）：
 *   - Checkbox：当前未适配沉浸光感效果，设置后无效果；
 *   - Switch  ：材质参数仅作为开启标记，实际使用组件内部预设视觉参数，只覆盖开关本体那片区域；
 *   - Button  ：效果与 Button 组件相同，影响背景色、边框、阴影。
 * 卡片要的是「覆盖整块矩形」，所以统一用 `ToggleType.Button`。
 *
 * ─────────────────────────────────────────────────────────────────────────
 * 三、四条层级规则（官方《沉浸光感常见问题》，每条都踩过）
 * ─────────────────────────────────────────────────────────────────────────
 *   1. 材质的视觉层级位于组件的 `backgroundColor`、`backgroundBlurStyle` 之下
 *      → 承载层必须显式 `Color.Transparent`，否则底色会把材质盖住；
 *   2. `systemMaterial` 要放在其他样式属性（背景色、边框、阴影）**之后**设置
 *      → 承载层用 `attributeModifier` 挂在属性链最末；
 *   3. 材质**不采样同一 Stack 里的兄弟节点**（采样的是组件背后的窗口内容）
 *      → 流光只能压在材质**之上**，塞到材质底下会完全看不见；
 *   4. `bindSheet` 的 `backgroundColor` 默认是 `Color.White`，不显式透明材质同样被盖住。
 */

/** 首个提供 uiMaterial 的系统 API 版本（HarmonyOS 7.0 / API 26.0.0）。 */
const IMMERSIVE_MIN_API: number = 26;

// ---------------------------------------------------------------------------
// 运行环境判定（带缓存，避免每个卡片都调用一次系统接口）。
// ---------------------------------------------------------------------------

let sdkApiVersionCache: number = -1;

function sdkApiVersion(): number {
  if (sdkApiVersionCache < 0) {
    try {
      sdkApiVersionCache = deviceInfo.sdkApiVersion;
    } catch (err) {
      sdkApiVersionCache = 0;
    }
  }
  return sdkApiVersionCache;
}

/**
 * 当前运行系统 API 是否 >= 指定版本。
 * API 26.0.0 起系统 API 版本格式为 sdkApiVersion.sdkMinorApiVersion.sdkPatchApiVersion。
 */
export function isSdkAtLeast(minVersion: number): boolean {
  return sdkApiVersion() >= minVersion;
}

/** 当前运行系统 API 是否 >= 26（提供 uiMaterial 的最低版本）。 */
export function isApi26OrAbove(): boolean {
  return isSdkAtLeast(IMMERSIVE_MIN_API);
}

/**
 * 应用内「沉浸光感」总开关（AppStorage，默认开启）。
 *
 * 关闭后所有材质下发与流光一并停止，全部回退为毛玻璃——这就是「全局沉浸光感」设置项。
 */
export function immersiveLightOn(): boolean {
  try {
    return AppStorage.get<boolean>('immersiveLightEnabled') !== false;
  } catch (err) {
    return true;
  }
}

/**
 * 「主题色流光」开关（`immersivePressGlow`，默认开启）。
 *
 * 只给诊断用；渲染路径请用下面的纯函数 `pressLightColor`。
 */
export function themedLightOn(): boolean {
  try {
    return AppStorage.get<boolean>(PRESS_GLOW_STORAGE) !== false;
  } catch (err) {
    return true;
  }
}

/**
 * 系统材质状态：只读一次并缓存（它是安装包里写死的配置，运行期不会变化）。
 *
 * ⚠️ API < 26 的系统上 `uiMaterial` 命名空间**不存在**，`uiMaterial.getMaterialInfo()`
 * 这种成员读取会抛 TypeError；这里整段包在 try/catch 里，低版本返回 null（走降级）。
 */
let materialStateCache: uiMaterial.MaterialState | null = null;
let materialStateResolved: boolean = false;
let materialStateError: string = '';

export function systemMaterialState(): uiMaterial.MaterialState | null {
  if (!materialStateResolved) {
    materialStateResolved = true;
    try {
      materialStateCache = uiMaterial.getMaterialInfo().state;
    } catch (err) {
      materialStateCache = null;
      materialStateError = String((err as Error)?.message ?? err);
    }
  }
  return materialStateCache;
}

/** getMaterialInfo() 调用失败时的错误信息，空串表示没失败过。 */
export function systemMaterialError(): string {
  systemMaterialState();
  return materialStateError;
}

/**
 * 系统材质总开关是否为 DISABLE。
 *
 * **仅用于诊断展示，不用于降级判断。**
 * disable 时确实画不出材质，但那是配置问题（要改 module.json5 重装），
 * 而不是应用该主动放弃渲染的理由。
 *
 * 低版本（API < 26）没有 `uiMaterial.MaterialState`，这里先做版本判断，
 * 保证**任何版本上调用都不会抛异常**。
 */
export function isSystemMaterialDisabled(): boolean {
  if (!isApi26OrAbove()) {
    return false;
  }
  return systemMaterialState() === uiMaterial.MaterialState.DISABLE;
}

// ---------------------------------------------------------------------------
// 材质对象（惰性构造 + 分档缓存，不要在 build / 高频回调里反复 new）
// ---------------------------------------------------------------------------

let materialError: string = '';
let materialCache: uiMaterial.Material | null = null;
let materialResolved: boolean = false;
let flatMaterialCache: uiMaterial.Material | null = null;
let flatMaterialResolved: boolean = false;
/**
 * 可交互材质按**流光颜色**缓存。
 *
 * 流光颜色随主题色变，一个固定变量装不下；这里用 Map 以颜色为键缓存，
 * 空串代表「系统默认白光」。颜色种类有限（预设 + 用户自定义），不会无限增长。
 */
const interactiveMaterials: Map<string, uiMaterial.Material | null> = new Map();

/**
 * 材质厚薄档位，集中一处便于按真机观感调档。
 *
 * **必须惰性求值，不能写成模块级常量。**
 * `export const MATERIAL_STYLE = uiMaterial.ImmersiveStyle.THIN` 这行会在**模块加载期**
 * 就解引用 `uiMaterial`；而 uiMaterial 是 API 26 才有的接口，在低版本设备上是 undefined，
 * 取 `.THIN` 抛出的 TypeError 发生在**任何 try/catch 之外**——结果不是没有光感，
 * 而是整个模块加载失败、**应用启动即闪退**。
 *
 * 调档只用类型断言、不写类型标注：带类型标注的写法在低版本 SDK 上会出现类型不相容的编译错误。
 */
function materialStyle(): uiMaterial.ImmersiveStyle {
  return uiMaterial.ImmersiveStyle.THIN as uiMaterial.ImmersiveStyle;
}

/**
 * 材质构造。
 *
 * 刻意**不传 materialColor**：材质的通透感来自它自身的滤镜，额外赋色会把卡片叠成灰色。
 *
 * 注意 `interactive` 与 `lightEffect` 的取舍：实测（HarmonyOS 7.0.0.105 / API 26）单独给
 * 静态承载层加 `interactive: true` + `lightEffect: {}` 会让材质**完全不渲染**，
 * 所以卡片承载层走静态材质；`interactive` 只给确实需要流光跟随的小元件（圆形按钮）用。
 *
 * @param interactive 是否开启交互形变 + 手指流光（类 HdsTab 的灵动反馈）
 * @param withShadow 是否保留材质自带的投影（默认 true；小尺寸芯片传 false）
 * @param lightColor 流光颜色；空串表示不指定，用系统默认的白光
 */
function buildImmersiveMaterial(interactive: boolean = false,
  withShadow: boolean = true,
  lightColor: string = ''): uiMaterial.Material | null {
  try {
    if (interactive) {
      // 《沉浸式系统材质视效》：interactive 开启按压弹性形变；
      // lightEffect 传入有效对象即启用流光跟随，颜色默认 Color.White。
      // 必须**先声明成带类型标注的常量再赋值**，直接写
      // `lightEffect: lightColor.length > 0 ? { color: lightColor } : {}`
      // 会被 ArkTS 判成「无类型对象字面量」而编译不过。
      const lightOptions: uiMaterial.LightEffectOptions = {};
      if (lightColor.length > 0) {
        lightOptions.color = lightColor;
      }
      return new uiMaterial.ImmersiveMaterial({
        style: materialStyle(),
        interactive: true,
        lightEffect: lightOptions
      });
    }
    if (!withShadow) {
      // applyShadow 默认 true，材质会自带一层投影。小尺寸芯片上这层投影
      // 会显得像「背后顶了一层影子」，所以单独开一档不带阴影的。
      return new uiMaterial.ImmersiveMaterial({
        style: materialStyle(),
        applyShadow: false
      });
    }
    // 静态材质只传 style，避免可选字段影响材质本身。
    return new uiMaterial.ImmersiveMaterial({
      style: materialStyle()
    });
  } catch (err) {
    materialError = String((err as Error)?.message ?? err);
    return null;
  }
}

/**
 * 沉浸光感材质（惰性构造）。
 *
 * 构造失败返回 null，调用方统一降级为毛玻璃——**绝不返回 Material.empty**，
 * 那等于「显式不画」，会把失败伪装成静默失效。
 *
 * @param interactive 传 true 取「可交互」材质（按压形变 + 流光），按钮类用
 * @param withShadow 是否保留材质自带投影
 * @param lightColor 流光颜色，空串 = 系统默认白光
 */
export function getImmersiveMaterial(interactive: boolean = false,
  withShadow: boolean = true,
  lightColor: string = ''): uiMaterial.Material | null {
  if (!isApi26OrAbove()) {
    return null;
  }
  if (!withShadow && !interactive) {
    if (!flatMaterialResolved) {
      flatMaterialResolved = true;
      flatMaterialCache = buildImmersiveMaterial(false, false);
    }
    return flatMaterialCache;
  }
  if (interactive) {
    const cached: uiMaterial.Material | null | undefined = interactiveMaterials.get(lightColor);
    if (cached !== undefined) {
      return cached;
    }
    const built: uiMaterial.Material | null = buildImmersiveMaterial(true, withShadow, lightColor);
    interactiveMaterials.set(lightColor, built);
    return built;
  }
  if (!materialResolved) {
    materialResolved = true;
    materialCache = buildImmersiveMaterial();
  }
  return materialCache;
}

/** 材质构造失败时的错误信息，空串表示没失败过。 */
export function immersiveMaterialError(): string {
  return materialError;
}

/**
 * 按「开关 + 主题色」算出流光颜色，空串 = 不指定颜色、用系统默认白光。
 *
 * **刻意做成纯函数、由调用方把订阅值传进来**，和 `resolvePageBackground` 同一个理由：
 * ArkUI 的局部更新按表达式记录依赖，函数里直接 `AppStorage.get(...)` 是登记不上的，
 * 拨开关或切主题色时已经画出来的按钮/卡片不会重新求值，流光会停在旧颜色上。
 * 材质承载层、卡片光晕、底部 HdsTab 都走它，保证三处流光永远同色。
 */
export function pressLightColor(themedLight: boolean, accentColor: string): string {
  if (!themedLight || accentColor.length === 0) {
    return '';
  }
  return accentColor;
}

/**
 * 应用侧沉浸光感是否应当启用：API >= 26、应用内开关开启、材质构造成功。
 * 刻意不看 MaterialState——它曾导致应用自己把光感降级掉（自锁）。
 */
export function immersiveMaterialActive(): boolean {
  return isApi26OrAbove() && immersiveLightOn() && getImmersiveMaterial() !== null;
}

/** 承载层是否处于「已挂上材质」状态，用于诊断与开发期排查。 */
export function materialCarrierActive(): boolean {
  return immersiveMaterialActive();
}

/**
 * 把沉浸光感材质挂在承载组件上。
 *
 * @param instance 承载组件的属性实例
 * @param fallbackBlur 材质不可用时是否补一层毛玻璃兜底
 * @param interactive 是否启用交互形变 + 手指流光。
 *                    注意：**流光只在组件自身收到触摸时触发**，启用时承载层不能设
 *                    `hitTestBehavior(HitTestMode.None)`。
 * @param withShadow 是否保留材质自带投影
 * @param lightColor 流光颜色，空串 = 系统默认白光。**必须由调用方在渲染期读订阅变量后传进来**。
 */
export function applyMaterialCarrier(instance: CommonAttribute,
  fallbackBlur: boolean = true,
  interactive: boolean = false,
  withShadow: boolean = true,
  lightColor: string = ''): void {
  // 流光颜色只对可交互材质有意义：静态材质根本没有 lightEffect 通道。
  const themed: string = interactive ? lightColor : '';
  const material: uiMaterial.Material | null = getImmersiveMaterial(interactive, withShadow, themed);
  if (immersiveLightOn() && material !== null) {
    instance.systemMaterial(material);
  } else if (fallbackBlur) {
    instance.backgroundBlurStyle(BlurStyle.Thin);
  }
}

/**
 * 给文本按钮（`Button('确定')` 这类胶囊按钮）挂上沉浸光感。
 *
 * **必须用静态材质。** `ImmersiveMaterial({ style, interactive: true, lightEffect: {} })`
 * 这个组合实测在 API 26 上会让材质**完全不渲染**；按钮请包一层 Toggle 承载层
 * （`MaterialCardLayer`）再调本函数。
 */
export function applyButtonMaterial(instance: CommonAttribute, fallbackBlur: boolean = true): void {
  applyMaterialCarrier(instance, fallbackBlur, false);
}

// ---------------------------------------------------------------------------
// 弹窗类：Toast / 菜单 / 弹出框 / 半模态面板（这些都在「页面内全部区域」生效范围内）
// ---------------------------------------------------------------------------

/** 沉浸光感使用场景。 */
export enum MaterialScene {
  /** 底部半模态面板（bindSheet）。 */
  SHEET = 0,
  /** 即时反馈 Toast（promptAction.showToast）。 */
  TOAST = 1,
  /** 菜单（bindMenu / bindContextMenu / Select 下拉菜单）。 */
  MENU = 2,
  /** 弹出框（AlertDialog、CustomDialog、promptAction.showDialog、各类 Picker 弹窗）。 */
  DIALOG = 3
}

/**
 * 各场景的材质厚薄：
 *   - 弹出框：ULTRA_THICK；
 *   - 即时反馈（Toast）、菜单、半模态面板：THICK
 *     （半模态面积较大，取 THICK 控制功耗）。
 */
function styleOf(scene: MaterialScene): uiMaterial.ImmersiveStyle {
  return scene === MaterialScene.DIALOG
    ? uiMaterial.ImmersiveStyle.ULTRA_THICK as uiMaterial.ImmersiveStyle
    : uiMaterial.ImmersiveStyle.THICK as uiMaterial.ImmersiveStyle;
}

/** 弹窗类材质按场景缓存（与卡片材质分开：厚薄档位不同）。 */
const sceneMaterialCache: Map<MaterialScene, uiMaterial.Material | null> =
  new Map<MaterialScene, uiMaterial.Material | null>();

function sceneMaterial(scene: MaterialScene): uiMaterial.Material | null {
  if (!isApi26OrAbove() || !immersiveLightOn()) {
    return null;
  }
  const cached: uiMaterial.Material | null | undefined = sceneMaterialCache.get(scene);
  if (cached !== undefined) {
    return cached;
  }
  let built: uiMaterial.Material | null = null;
  try {
    built = new uiMaterial.ImmersiveMaterial({
      style: styleOf(scene),
      applyShadow: true
    });
  } catch (err) {
    materialError = String((err as Error)?.message ?? err);
    built = null;
  }
  sceneMaterialCache.set(scene, built);
  return built;
}

/** 即时反馈（Toast）的 systemMaterial 参数。 */
export function toastSystemMaterial(): uiMaterial.Material | undefined {
  const material: uiMaterial.Material | null = sceneMaterial(MaterialScene.TOAST);
  return material === null ? undefined : material;
}

/** 菜单（Menu / bindMenu / ContextMenu）的 systemMaterial 参数。 */
export function menuSystemMaterial(): uiMaterial.Material | undefined {
  const material: uiMaterial.Material | null = sceneMaterial(MaterialScene.MENU);
  return material === null ? undefined : material;
}

/** 弹出框（AlertDialog / CustomDialog / showDialog / 各类 Picker 弹窗）的 systemMaterial 参数。 */
export function dialogSystemMaterial(): uiMaterial.Material | undefined {
  const material: uiMaterial.Material | null = sceneMaterial(MaterialScene.DIALOG);
  return material === null ? undefined : material;
}

/** bindSheet 的 systemMaterial 参数；不可用时返回 undefined。 */
export function sheetSystemMaterial(): uiMaterial.Material | undefined {
  const material: uiMaterial.Material | null = sceneMaterial(MaterialScene.SHEET);
  return material === null ? undefined : material;
}

/**
 * bindSheet 的 blurStyle 参数。
 * 沉浸光感可用时不设置模糊（交给系统材质），否则回退旧毛玻璃。
 */
export function sheetBlurStyle(): BlurStyle | undefined {
  return immersiveMaterialActive() ? undefined : BlurStyle.Thin;
}

// ---------------------------------------------------------------------------
// 卡片表面：内容区卡片由 Toggle 承载材质（见 components/CardSurface.ets）。
// 材质生效时，卡片自身的毛玻璃与描边/阴影必须**全部让位**，否则会盖住材质。
// ---------------------------------------------------------------------------

/** 「更优美的卡片」开启态：轻微毛玻璃（与二级页面顶部返回栏一致）。 */
const CARD_GLASS_RADIUS: number = 8;
const CARD_GLASS_LIGHT: string = '#66FFFFFF';
const CARD_GLASS_DARK: string = '#6624282B';

/** 「更优美的卡片」关闭态：模糊更强、叠加色更淡 = 高透明毛玻璃。 */
const CARD_TRANSLUCENT_RADIUS: number = 24;
const CARD_TRANSLUCENT_LIGHT: string = '#4DFFFFFF';
const CARD_TRANSLUCENT_DARK: string = '#4D24282B';

/** 「经典卡片样式」：旧的玻璃卡片（半透明白 / 不透明深灰底 + 常规模糊）。 */
const CARD_CLASSIC_RADIUS: number = 12;
const CARD_CLASSIC_LIGHT: string = '#B3FFFFFF';
const CARD_CLASSIC_DARK: string = '#24272B';

/** 描边色：常规玻璃描边 / 「卡片阴影描边」开启时的实描边。 */
const CARD_BORDER_GLASS_LIGHT: string = '#1AFFFFFF';
const CARD_BORDER_GLASS_DARK: string = '#3A3F45';
const CARD_BORDER_STRONG_LIGHT: string = '#33000000';
const CARD_BORDER_STRONG_DARK: string = '#4DFFFFFF';

/** 沉浸光感卡片模式下，卡片自身的毛玻璃参数全部置为「无效果」（外观交给系统材质）。 */
const CARD_GLASS_NONE: BackgroundEffectOptions = { radius: 0, color: Color.Transparent };
const CARD_BORDER_NONE: string = '#00000000';
const CARD_SHADOW_NONE: ShadowOptions = { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 };

/** 材质背板的兜底底色（无模糊）：材质未生效时卡片也不会变成全透明。 */
const CARD_SURFACE_TINT_LIGHT: string = '#14FFFFFF';
const CARD_SURFACE_TINT_DARK: string = '#1F24282B';

/**
 * 内容区卡片是否由系统材质接管表面。
 *
 * 三个条件同时成立才为真：系统 API >= 26、应用内「沉浸光感」开关开启、
 * 材质对象构造成功。为真时：
 *   - `CardSurface` 用 Toggle 承载层下发材质；
 *   - `cardGlassEffect` / `cardGlassBorderColor` / `cardGlassShadow` 返回「无效果」，
 *     避免自绘的毛玻璃/描边/阴影叠在材质之上。
 *
 * ⚠️ 本函数直接读 `AppStorage`，登记不上节点级依赖；页面切换开关时的重建由
 * 页面上的 `@StorageLink('immersiveLightEnabled')` / `@StorageProp('accentColor')` 负责。
 */
export function immersiveCardsActive(): boolean {
  return immersiveMaterialActive();
}

/**
 * 卡片背景玻璃参数（三种外观，只用一个 backgroundEffect 表达）。
 *
 * backgroundBlurStyle 与 backgroundEffect 作用在同一个背景滤镜上、后写的生效，
 * 同时使用会互相覆盖，因此卡片只用 backgroundEffect。
 *
 * - 「更优美的卡片」开启：轻微毛玻璃；
 * - 「经典卡片样式」开启：旧玻璃卡片（半透明白底 / 不透明深灰底 + 常规模糊）；
 * - 都关闭：高透明毛玻璃（更弥散、更透）；
 * - 沉浸光感生效：无效果（外观交给系统材质）。
 *
 * @param beautiful 是否开启「更优美的卡片」
 * @param classic 是否开启「经典卡片样式」
 * @param isDark 是否深色模式
 * @param experimental 兼容参数：旧版「沉浸光感卡片（实验性）」开关，现已并入全局沉浸光感，保留以免调用点改动
 */
export function cardGlassEffect(beautiful: boolean, classic: boolean, isDark: boolean,
  experimental: boolean): BackgroundEffectOptions {
  if (immersiveCardsActive()) {
    return CARD_GLASS_NONE;
  }
  if (beautiful) {
    return { radius: CARD_GLASS_RADIUS, color: isDark ? CARD_GLASS_DARK : CARD_GLASS_LIGHT };
  }
  if (classic) {
    return { radius: CARD_CLASSIC_RADIUS, color: isDark ? CARD_CLASSIC_DARK : CARD_CLASSIC_LIGHT };
  }
  return {
    radius: CARD_TRANSLUCENT_RADIUS,
    color: isDark ? CARD_TRANSLUCENT_DARK : CARD_TRANSLUCENT_LIGHT
  };
}

/**
 * 卡片描边色。
 * 「卡片阴影描边」开启（且未开「更优美的卡片」）时用更实的描边，
 * 让卡片在默认纯色背景上也能看清边界；其余情况沿用常规玻璃描边。
 * 沉浸光感生效时返回全透明（描边由系统材质负责）。
 */
export function cardGlassBorderColor(beautiful: boolean, shadowBorder: boolean, isDark: boolean,
  experimental: boolean): string {
  if (immersiveCardsActive()) {
    return CARD_BORDER_NONE;
  }
  if (!beautiful && shadowBorder) {
    return isDark ? CARD_BORDER_STRONG_DARK : CARD_BORDER_STRONG_LIGHT;
  }
  return isDark ? CARD_BORDER_GLASS_DARK : CARD_BORDER_GLASS_LIGHT;
}

/**
 * 卡片阴影。
 * 「卡片阴影描边」开启（且未开「更优美的卡片」）时加一层柔和投影；其余情况不投影。
 * 沉浸光感生效时不投影（材质自带阴影）。
 */
export function cardGlassShadow(beautiful: boolean, shadowBorder: boolean, isDark: boolean,
  experimental: boolean): ShadowOptions {
  if (immersiveCardsActive()) {
    return CARD_SHADOW_NONE;
  }
  if (!beautiful && shadowBorder) {
    return { radius: 16, color: isDark ? '#80000000' : '#26000000', offsetX: 0, offsetY: 4 };
  }
  return { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 };
}

/**
 * 材质背板的兜底底色（无模糊，只叠加一层很淡的底色）。
 *
 * 沉浸光感是否真正生效由系统按组件类型/算力决定，一旦没生效、而卡片自身又已经把
 * 毛玻璃置为无效果，卡片就会变成全透明。这里给承载层留一层 5%~8% 的底色，
 * 保证任何情况下卡片都看得见；材质生效时这层底色只是轻微叠加，不影响材质观感。
 */
export function cardMaterialSurfaceEffect(isDark: boolean): BackgroundEffectOptions {
  return { radius: 0, color: isDark ? CARD_SURFACE_TINT_DARK : CARD_SURFACE_TINT_LIGHT };
}

/**
 * 诊断文案：把沉浸光感的各段判定条件摊开，便于真机排查「为什么没生效」。
 *
 * 形如：`API=26 材质=已构造 状态=非DISABLE 开关=开 流光=#0A59F7 承载=下发材质`。
 *
 * 两个入参同样是「订阅值传进来」的写法：直接在函数里读 AppStorage 的话，
 * 设置页那行诊断文字不会随切色/拨开关刷新（它会停在上一档，看着像没生效）。
 *
 * 低版本（API < 26）提前返回：`uiMaterial.MaterialState` 在那时不存在，
 * 读到就会抛异常——本函数在页面 build 期间被调用，抛出即整页渲染失败。
 */
export function materialDiagnostics(themedLight: boolean = true, accentColor: string = ''): string {
  const api: number = sdkApiVersion();
  if (!isApi26OrAbove()) {
    return `API=${api} 材质=不可用（需 API 26 及以上） 开关=${immersiveLightOn() ? '开' : '关'} 承载=降级毛玻璃`;
  }
  const state: uiMaterial.MaterialState | null = systemMaterialState();
  const stateText: string = state === null
    ? 'null(接口不可用)'
    : (state === uiMaterial.MaterialState.DISABLE ? 'DISABLE(全局关闭)' : '非DISABLE');
  const material: uiMaterial.Material | null = getImmersiveMaterial();
  const materialText: string = material === null ? '构造失败' : '已构造';
  const light: string = pressLightColor(themedLight, accentColor);
  const lightText: string = light.length > 0 ? `流光=${light}` : '流光=系统白光';
  const err: string = systemMaterialError().length > 0 ? systemMaterialError() : immersiveMaterialError();
  const errText: string = err.length > 0 ? ` 错误=${err}` : '';
  return `API=${api} 材质=${materialText} 状态=${stateText} 开关=${immersiveLightOn() ? '开' : '关'} ${lightText} 承载=${materialCarrierActive() ? '下发材质' : '降级毛玻璃'}${errText}`;
}
