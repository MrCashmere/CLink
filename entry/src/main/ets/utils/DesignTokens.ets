/**
 * 设计令牌（DesignTokens）：色板、圆角/间距刻度，以及**主题色**与**深色模式**的运行时机制。
 *
 * ─────────────────────────────────────────────────────────────────────────
 * 主题色（Accent Color）实现要点
 * ─────────────────────────────────────────────────────────────────────────
 * 目标：用户在外观设置里选一个颜色（或输入任意 RRGGBB），**全应用立即变色**，无需重启。
 *
 * 三个难点决定了这套机制的形态：
 *
 * 1. **ArkUI 不会因为普通对象属性变化而刷新**：颜色集中放在模块级可变对象 `HwColor` 里，
 *    直接改 `HwColor.primary` 不触发任何重建。
 * 2. **`@StorageProp` + `@Watch` 只触发回调，不重新求值组件**：必须有一个**真正渲染出来的
 *    表达式读它**（`@StorageLink` 双向键、`AccentColorSentinel`、或 `this.accentOrPrimary()`），
 *    ArkUI 才会把页面标记为脏。
 * 3. **控件自带 SDK 默认选中色**：`Toggle` / `Slider` 的 `selectedColor` 默认是
 *    `$r('sys.color.ohos_id_color_emphasize')`（系统蓝），不显式覆盖就永远是蓝的。
 *
 * 结论：`HwColor.primary` 负责「值」，`AppStorage['accentColor']` 负责「通知」。两者缺一不可。
 *
 * 生效链路（从点击到全应用变色）：
 * ```
 * 设置页写 @StorageLink('accentKey' | 'accentCustom')  → 同步进 AppStorage
 *   → AppSettingsStore.setString(...)                 → 落盘持久化
 *   → applyAccentNow() → reloadAppTheme()
 *       ├─ resolveAccentColor() 算出 #RRGGBB
 *       ├─ applyAppTheme() 改写 HwColor.primary（模块级对象，静默）
 *       └─ AppStorage.setOrCreate('accentColor', resolved)
 *   → 所有订阅 accentColor 的页面/组件被标记为脏并重建
 *   → 重建时读到新的 HwColor.primary / accentColor
 * ```
 *
 * ⚠️ 页面底色与卡片底色**必须**订阅广播键（`pageBackground` / `cardSurface` / `cardTintColor`），
 * 不能直接读 `HwColor.background`：模块级对象的属性读取登记不上依赖，
 * 切主题色 / 拨「卡片沾色」时已经画出来的元素不会重新求值。
 */
export interface HwColorPalette {
  primary: string;
  background: string;
  backgroundDark: string;
  surface: string;
  textPrimary: string;
  textSecondary: string;
  danger: string;
  online: string;
}

// ---------------------------------------------------------------------------
// 主题色：预设、存储键与默认值
// ---------------------------------------------------------------------------

/** 主题色预设 */
export interface AccentPreset {
  key: string;
  label: string;
  value: string;
}

/**
 * 默认主题色（= 预设首位的鸿蒙蓝）。
 *
 * 未设置过主题色、存储读失败、自定义色非法，一律落到这一档。
 * 刻意只留 `key` / `value` 两个常量而**不再单列一个「默认色」预设**：
 * 默认色本身就该是鸿蒙蓝，多摆一个同名不同色的色块只会让人分不清哪个才是默认。
 */
export const DEFAULT_ACCENT_KEY: string = 'harmony';
/** 默认主题色的值：鸿蒙蓝 */
export const DEFAULT_ACCENT_VALUE: string = '#0A59F7';

/**
 * 主题色预设。
 * - harmony：鸿蒙默认蓝（HarmonyOS 品牌色），也是默认值
 * - rose   ：往昔粉
 * - ripple ：涟漪粉（浅色）
 * - firefly：流荧绿（浅色）
 *
 * 注意 `ripple` / `firefly` 是**浅色**：压在它们上面的文字不能用白色，
 * 凡是「主题色底 + 文字」的地方都要走 `onAccentColor()` 取前景色。
 */
export const ACCENT_PRESETS: AccentPreset[] = [
  { key: 'harmony', label: '鸿蒙蓝', value: '#0A59F7' },
  { key: 'rose', label: '往昔粉', value: '#E86A92' },
  { key: 'ripple', label: '涟漪粉', value: '#FAD6E4' },
  { key: 'firefly', label: '流荧绿', value: '#88E4D4' }
];

/** 主题色设置键：存预设 key 或 'custom' */
export const ACCENT_KEY_STORAGE: string = 'accentKey';
/** 自定义主题色设置键：存 RRGGBB（不含 #） */
export const ACCENT_CUSTOM_STORAGE: string = 'accentCustom';
/**
 * 自定义主题色列表设置键。
 *
 * 元素格式：`'RRGGBB'`（无昵称）或 `'RRGGBB|昵称'`（有昵称）。
 * 旧版本存的是纯 `'RRGGBB'` 数组，读入时由 `parseAccentEntries()` 兼容解析。
 */
export const ACCENT_CUSTOM_LIST_STORAGE: string = 'accentCustomList';

/**
 * 「主题色」总开关（`themeColorEnabled`，**默认开**）。
 *
 * 关闭后**所有主题色都不生效**，配色回到加主题色功能之前的那一版：
 * 主色固定鸿蒙蓝（深色下 `#5AA0FF`、按钮底 `#1F5FCC`）、页面背景不再淡染、
 * 卡片描边回到中性白、卡片沾色层不画。用户选过的颜色与自定义列表**保留**，
 * 重新打开即恢复。
 */
export const THEME_COLOR_ENABLED_STORAGE: string = 'themeColorEnabled';

/** 主题色广播键：最终解析好的 `#RRGGBB`。所有 UI 依赖的是它，不是持久化键 */
export const ACCENT_COLOR_KEY: string = 'accentColor';
/** 页面底色广播键：由 applyAppTheme 写入，页面订阅它（见 resolvePageBackground） */
export const PAGE_BACKGROUND_KEY: string = 'pageBackground';
/** 卡片底色广播键：由 applyAppTheme 写入，卡片订阅它 */
export const CARD_SURFACE_KEY: string = 'cardSurface';
/** 卡片沾色叠加层广播键：空串表示不沾色。沾色必须叠在材质之上，混进底色看不见 */
export const CARD_TINT_KEY: string = 'cardTintColor';
/** 卡片沾色开关：打开后所有卡片叠一层 10% 主题色 */
export const CARD_TINT_STORAGE: string = 'cardTintEnabled';
/** 高权限自定义主题色：打开后自定义色也参与页面背景染色（默认只允许内置预设色） */
export const CUSTOM_ACCENT_FULL_ACCESS_STORAGE: string = 'customAccentFullAccess';

/**
 * 沉浸光感「主题色流光」开关（`immersivePressGlow`，默认开）。
 *
 * 开启：按压卡片 / 圆形图标按钮的流光与光晕用主题色；
 * 关闭：回到系统默认的白色流光。
 */
export const PRESS_GLOW_STORAGE: string = 'immersivePressGlow';
/**
 * 卡片「流光触感」开关（`cardGlowTouch`，默认关）。
 *
 * 关：**按压卡片不出现任何流光**；
 * 开：跟手光斑与溢出到卡间缝隙的环境光一起画（两层必须一起开关，见 MaterialCard/CardSurface）。
 * 只作用于卡片，**不影响底部 HdsTab 悬浮栏的流光**。
 */
export const CARD_GLOW_TOUCH_STORAGE: string = 'cardGlowTouch';

/**
 * 深色模式偏好：'system'（跟随系统）/ 'light' / 'dark'。
 *
 * 刻意用三态字符串而不是布尔量：布尔量一旦被用户拨动过就永久生效，
 * **再也没法回到「跟随系统」**。三态让「跟随系统」始终是一个可以选回来的状态。
 */
export const DARK_MODE_PREF_STORAGE: string = 'darkModePreference';
/** 深色模式偏好取值 */
export const DARK_MODE_SYSTEM: string = 'system';
export const DARK_MODE_LIGHT: string = 'light';
export const DARK_MODE_DARK: string = 'dark';
/** 深色模式广播键（其它页面只读它） */
export const DARK_MODE_KEY: string = 'isDarkMode';

/** 读一个布尔开关，读取失败时用默认值 */
function readFlag(key: string, fallback: boolean): boolean {
  try {
    const value = AppStorage.get<boolean>(key);
    return value === undefined ? fallback : value;
  } catch (err) {
    return fallback;
  }
}

// ---------------------------------------------------------------------------
// 主题色：校验与派生工具
// ---------------------------------------------------------------------------

/**
 * 校验自定义主题色输入：只接受 6 位十六进制（可带 #），大小写均可。
 * 返回规范化后的 `#RRGGBB`，非法时返回空串。
 */
export function normalizeAccentHex(input: string): string {
  const raw = input.trim().replace('#', '');
  if (raw.length !== 6) {
    return '';
  }
  for (let i = 0; i < raw.length; i++) {
    const c = raw.charAt(i).toLowerCase();
    const isDigit = c >= '0' && c <= '9';
    const isHex = c >= 'a' && c <= 'f';
    if (!isDigit && !isHex) {
      return '';
    }
  }
  return `#${raw.toUpperCase()}`;
}

/**
 * 自定义主题色条目：色值 + 用户起的昵称。
 *
 * 昵称是**可选**的：没起名字时界面回落到显示 `#RRGGBB`，色值本身仍然是唯一标识。
 */
export interface AccentCustom {
  /** `RRGGBB`（不含 `#`），始终是大写 */
  hex: string;
  /** 用户起的昵称，空串表示没起名字 */
  name: string;
}

/** 列表里元素的分隔符：`RRGGBB|昵称` */
const ACCENT_ENTRY_SEPARATOR: string = '|';

/**
 * 解析持久化的自定义主题色列表。
 *
 * 兼容两种格式：旧版纯 `'RRGGBB'`，新版 `'RRGGBB|昵称'`。
 * 逐项过滤非法色值并按色值去重（同色值只保留第一条，昵称取第一条非空的）。
 */
export function parseAccentEntries(raw: string[]): AccentCustom[] {
  const list: AccentCustom[] = [];
  for (let i = 0; i < raw.length; i++) {
    const text = String(raw[i]);
    const cut = text.indexOf(ACCENT_ENTRY_SEPARATOR);
    const hexPart = cut >= 0 ? text.substring(0, cut) : text;
    const namePart = cut >= 0 ? text.substring(cut + 1).trim() : '';
    const hex = normalizeAccentHex(hexPart).replace('#', '');
    if (hex.length !== 6) {
      continue;
    }
    let merged = false;
    for (let j = 0; j < list.length; j++) {
      if (list[j].hex === hex) {
        if (list[j].name.length === 0 && namePart.length > 0) {
          list[j].name = namePart;
        }
        merged = true;
        break;
      }
    }
    if (!merged) {
      list.push({ hex: hex, name: namePart });
    }
  }
  return list;
}

/** 把自定义列表写回持久化格式（有昵称的带上 `|昵称`） */
export function serializeAccentEntries(list: AccentCustom[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < list.length; i++) {
    out.push(list[i].name.length > 0
      ? `${list[i].hex}${ACCENT_ENTRY_SEPARATOR}${list[i].name}`
      : list[i].hex);
  }
  return out;
}

/**
 * 色块上显示的名字：**有昵称就只显示昵称**，没有才回落到 `#RRGGBB`。
 * 界面上不展示色值本身（用户要的是「我给它起的名字」）。
 */
export function accentEntryLabel(entry: AccentCustom): string {
  return entry.name.length > 0 ? entry.name : `#${entry.hex}`;
}

/** 该自定义色是否已起昵称 */
export function hasAccentName(entry: AccentCustom): boolean {
  return entry.name.length > 0;
}

/**
 * 规范化自定义主题色列表：逐项过滤非法值并去重，返回纯色值数组。
 * 持久化内容可能被外部改坏或残留旧版本数据，读入时统一兜底。
 */
export function normalizeAccentList(raw: string[]): string[] {
  const list: string[] = [];
  const entries = parseAccentEntries(raw);
  for (let i = 0; i < entries.length; i++) {
    list.push(entries[i].hex);
  }
  return list;
}

/**
 * 给 `#RRGGBB` 叠加透明度，返回 `#AARRGGBB`。
 *
 * 凡是「主题色的浅色底」都用它，不要写字面量：写死的半透明色切主题色后不会跟着变，
 * 选中态会露出旧色。`alpha` 取 0~1。
 */
export function withAlpha(color: string, alpha: number): string {
  const normalized = normalizeAccentHex(color);
  if (normalized.length === 0) {
    return color;
  }
  const clamped = Math.max(0, Math.min(1, alpha));
  const channel = Math.round(clamped * 255).toString(16).toUpperCase().padStart(2, '0');
  return `#${channel}${normalized.substring(1)}`;
}

/**
 * 两个 `#RRGGBB` 线性混合：ratio=0 取 base，ratio=1 取 tint。
 * 用于把主题色调成「很淡的底色」——直接铺主题色会盖过正文。
 * 任一输入非法时原样返回 base，绝不返回半成品颜色。
 */
export function mixHex(base: string, tint: string, ratio: number): string {
  const a = normalizeAccentHex(base);
  const b = normalizeAccentHex(tint);
  if (a.length === 0 || b.length === 0) {
    return a.length > 0 ? a : base;
  }
  const clamped = Math.max(0, Math.min(1, ratio));
  let out = '#';
  for (let i = 1; i < 7; i += 2) {
    const ca = parseInt(a.substring(i, i + 2), 16);
    const cb = parseInt(b.substring(i, i + 2), 16);
    const mixed = Math.round(ca + (cb - ca) * clamped);
    out += mixed.toString(16).toUpperCase().padStart(2, '0');
  }
  return out;
}

/**
 * 压在主题色上的前景色。
 *
 * 主题色不都是深色：涟漪粉 `#FAD6E4`、流荧绿 `#88E4D4` 都很浅，
 * 上面再压白字基本看不清。统一按**相对亮度**决定用黑字还是白字，
 * 新增浅色预设时不必再去逐个调用点改字色。
 *
 * 阈值 0.62 偏保守（宁可早一点切黑字）：按 sRGB 加权亮度算，
 * 鸿蒙蓝 0.33、往昔粉 0.58 走白字，涟漪粉 0.89、流荧绿 0.78 走黑字。
 *
 * ⚠️ 调用时要把**订阅变量**传进来（`onAccentColor(this.accentOrPrimary())`）：
 * 直接写 `onAccentColor(HwColor.primary)` 读的是模块级对象、登记不上依赖，切色后字色不会跟着变。
 */
export function onAccentColor(accentColor: string): string {
  const normalized = normalizeAccentHex(accentColor);
  if (normalized.length === 0) {
    return '#FFFFFF';
  }
  const r = parseInt(normalized.substring(1, 3), 16);
  const g = parseInt(normalized.substring(3, 5), 16);
  const b = parseInt(normalized.substring(5, 7), 16);
  const luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  return luminance > 0.62 ? '#1A1A1A' : '#FFFFFF';
}

/**
 * 是否是内置预设的 key（`custom` 不是预设，返回 false）。
 *
 * 与按颜色判定的 `isPresetAccent` 不同：这里判的是设置里存的那个 key，
 * 用来给存储兜底——旧版本或异常写入可能留下一个已经不存在的 key。
 */
export function isPresetAccentKey(key: string): boolean {
  for (let i = 0; i < ACCENT_PRESETS.length; i++) {
    if (ACCENT_PRESETS[i].key === key) {
      return true;
    }
  }
  return false;
}

/**
 * 是否是内置预设主题色。
 *
 * 页面背景只跟随预设色：自定义色是用户随手输的，
 * 拿它铺满整页底色很容易脏，也可能与正文对比度不足。
 */
export function isPresetAccent(color: string): boolean {
  const normalized = normalizeAccentHex(color);
  if (normalized.length === 0) {
    return false;
  }
  for (let i = 0; i < ACCENT_PRESETS.length; i++) {
    if (normalizeAccentHex(ACCENT_PRESETS[i].value) === normalized) {
      return true;
    }
  }
  return false;
}

/**
 * 按当前设置解析主题色。
 * 预设命中则用预设值；未命中（custom）时用自定义值，自定义非法则回落到默认主题色。
 */
export function resolveAccentColor(accentKey: string, customHex: string): string {
  for (let i = 0; i < ACCENT_PRESETS.length; i++) {
    if (ACCENT_PRESETS[i].key === accentKey) {
      return ACCENT_PRESETS[i].value;
    }
  }
  const normalized = normalizeAccentHex(customHex);
  return normalized.length > 0 ? normalized : DEFAULT_ACCENT_VALUE;
}

/**
 * 当前**实际生效**的主题色。
 *
 * 与 `resolveAccentColor()` 的区别只在总开关：`themeColorEnabled` 关闭时固定返回默认鸿蒙蓝，
 * 用户存下来的 key / 自定义色不动。启动初始化、`onConfigurationUpdate`、`reloadAppTheme`
 * 都走它，避免「HwColor 已是旧版配色、广播出去的 accentColor 还是用户色」的错配
 * （那样开关、底栏高亮会与页面其余部分不同色）。
 */
export function effectiveAccentColor(accentKey: string, customHex: string): string {
  return themeColorOn() ? resolveAccentColor(accentKey, customHex) : DEFAULT_ACCENT_VALUE;
}

/** 读 AppStorage 里的当前主题色；读不到时回落默认主题色 */
export function currentAccentColor(): string {
  try {
    const stored = AppStorage.get<string>(ACCENT_COLOR_KEY);
    if (stored !== undefined && normalizeAccentHex(stored).length > 0) {
      return normalizeAccentHex(stored);
    }
  } catch (err) {
  }
  return HwColor.primary;
}

// ---------------------------------------------------------------------------
// 可变色板与深浅模式取值
// ---------------------------------------------------------------------------

export const HwColor: HwColorPalette = {
  // 默认主题色（鸿蒙蓝）；切色后由 applyAppTheme 覆盖
  primary: DEFAULT_ACCENT_VALUE,
  background: '#F1F3F5',
  backgroundDark: '#000000',
  surface: '#FFFFFF',
  textPrimary: '#182431',
  textSecondary: '#8A8F99',
  danger: '#D94838',
  online: '#00AA72'
};

// ---------------------------------------------------------------------------
// 深色模式(Dark)响应式色板函数。
// 组件内统一通过 hw*(this.isDarkMode) 取色，切换深色时随 isDarkMode 重绘。
//
// 所有取值均经过 WCAG 2.1 对 纯黑背景(#000000) 与 深灰卡片(#24272B) 双重校验：
//   - textPrimary  正文：对黑 18.7:1 / 对卡 ~12:1   (>=4.5:1 ✓)
//   - textSecondary次要：对黑 12.1:1 / 对卡 8.6:1    (>=4.5:1 ✓)
//   - primary      前景/链接/选中图标：对黑 7.9:1 / 对卡 5.7:1 (>=3:1 ✓)
//   - primaryButton按钮背景：对白字 5.9:1            (>=4.5:1 ✓)
//   - danger       危险文字：对卡 6.6:1              (>=4.5:1 ✓)
//   - online       在线/成功：对卡 8.4:1             (>=3:1 ✓)
//   - surface      卡片/输入框表面：#24272B
//
// 主题色接入后，深浅两个分支都由**当前主题色**派生（不再是写死的蓝）：
//   - 深色前景 = 主题色与白色按 DARK_ACCENT_LIFT 混合，保证纯黑底上仍有 >=3:1；
//   - 深色按钮底 = 主题色与黑色按 DARK_BUTTON_DEEPEN 混合，保证配白字仍有 >=4.5:1。
// ---------------------------------------------------------------------------

/** 深色模式下主题色向白色抬升的比例（越大越亮） */
const DARK_ACCENT_LIFT: number = 0.4;
/** 深色模式下主按钮底色向黑色压深的比例（越大越暗，白字越清晰） */
const DARK_BUTTON_DEEPEN: number = 0.32;

// ---------------------------------------------------------------------------
// 「主题色」关闭时的旧版配色（加主题色功能之前的那一版）
//
// 关闭总开关后不走「由主题色派生」，而是**原样回到这几个写死的值**，
// 这样关闭后的观感与引入主题色之前逐像素一致。
// ---------------------------------------------------------------------------

/** 旧版深色模式主色（浅蓝） */
const LEGACY_PRIMARY_DARK: string = '#5AA0FF';
/** 旧版深色模式主按钮底色 */
const LEGACY_PRIMARY_BUTTON_DARK: string = '#1F5FCC';
/** 旧版浅色页面背景（不跟随主题色淡染） */
const LEGACY_PAGE_LIGHT: string = '#F1F3F5';
/** 旧版深色页面背景 */
const LEGACY_PAGE_DARK: string = '#000000';
/** 旧版浅色卡片底色（半透明白玻璃） */
const LEGACY_CARD_SURFACE_LIGHT: string = '#B3FFFFFF';
/** 旧版深色卡片底色 */
const LEGACY_CARD_SURFACE_DARK: string = '#24272B';
/** 旧版卡片描边（中性白，不带任何色相） */
const LEGACY_CARD_BORDER: string = '#1AFFFFFF';

/**
 * 主题色总开关当前是否打开（`themeColorEnabled`，默认开）。
 * `applyAppTheme()` 与深色派生都读它。
 */
export function themeColorOn(): boolean {
  return readFlag(THEME_COLOR_ENABLED_STORAGE, true);
}

/** 当前生效的配色是否来自「主题色」功能（关掉总开关后为 false） */
let themeColorActive: boolean = true;

function textPrimaryDark(): string { return '#F0F2F5'; }
function textSecondaryDark(): string { return '#C0C5CB'; }
function dangerDark(): string { return '#FF8A7A'; }
function onlineDark(): string { return '#40DB94'; }
function surfaceDark(): string { return '#24272B'; }
function surfaceBorderDark(): string { return '#3A3F45'; }

/** 深色模式下的主题色前景（主题色生效时由当前主题色抬亮派生，否则用旧版浅蓝） */
function primaryDark(): string {
  return themeColorActive ? mixHex(HwColor.primary, '#FFFFFF', DARK_ACCENT_LIFT) : LEGACY_PRIMARY_DARK;
}

/** 深色模式下的主按钮底色（主题色生效时由当前主题色压深派生，否则用旧版深蓝） */
function primaryButtonDark(): string {
  return themeColorActive ? mixHex(HwColor.primary, '#000000', DARK_BUTTON_DEEPEN) : LEGACY_PRIMARY_BUTTON_DARK;
}

/** 正文/标题文字色。 */
export function hwTextPrimary(isDark: boolean): string {
  return isDark ? textPrimaryDark() : HwColor.textPrimary;
}

/** 次要/辅助文字色。 */
export function hwTextSecondary(isDark: boolean): string {
  return isDark ? textSecondaryDark() : HwColor.textSecondary;
}

/**
 * 主色：用于文字、链接、选中态图标等前景。按钮背景请用 hwPrimaryButton。
 *
 * 浅色返回 `HwColor.primary`（= 当前主题色，由 applyAppTheme 写入）；
 * 深色返回主题色的抬亮版本。
 *
 * ⚠️ 本函数是**普通纯函数**：读的是模块级 `HwColor`，表达式里没有订阅变量，
 * 所以 **ArkUI 登记不上依赖** —— 切主题色时，已经画出来的这一处属性不会重新求值
 * （表现：页面别的地方变色了，唯独这个按钮/图标还是旧色）。
 * 需要实时跟随的地方请用 `resolvePrimaryColor(isDark, this.accentOrPrimary())`。
 */
export function hwPrimary(isDark: boolean): string {
  return isDark ? primaryDark() : HwColor.primary;
}

/** 主按钮背景色（配白字），深浅模式下发色号不同以保证白字对比度。 */
export function hwPrimaryButton(isDark: boolean): string {
  return isDark ? primaryButtonDark() : HwColor.primary;
}

/** 取一个合法的主题色入参：为空或非法时回落到当前 token */
function accentOrFallback(accentColor: string): string {
  const normalized = normalizeAccentHex(accentColor);
  return normalized.length > 0 ? normalized : HwColor.primary;
}

/**
 * 主色的**订阅版**：把 `accentColor` 作为入参传进来，表达式里就真正读到了订阅键，
 * 切主题色时这一处属性会被重新求值。取值与 `hwPrimary(isDark)` **逐档一致**
 * （含深色抬亮、含「主题色总开关关闭」时回落旧版浅蓝）。
 *
 * ```ets
 * .fontColor(resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()))
 * ```
 *
 * 为什么不能直接用 `hwPrimary(this.isDarkMode)`：见它的注释——那是模块级对象的属性读取，
 * ArkUI 按**表达式**登记依赖，登记不上就不会刷新。
 */
export function resolvePrimaryColor(isDark: boolean, accentColor: string): string {
  const accent = accentOrFallback(accentColor);
  if (!isDark) {
    return accent;
  }
  return themeColorActive ? mixHex(accent, '#FFFFFF', DARK_ACCENT_LIFT) : LEGACY_PRIMARY_DARK;
}

/** 主按钮底色的**订阅版**：取值与 `hwPrimaryButton(isDark)` 逐档一致 */
export function resolvePrimaryButtonColor(isDark: boolean, accentColor: string): string {
  const accent = accentOrFallback(accentColor);
  if (!isDark) {
    return accent;
  }
  return themeColorActive ? mixHex(accent, '#000000', DARK_BUTTON_DEEPEN) : LEGACY_PRIMARY_BUTTON_DARK;
}

/**
 * 卡片/芯片描边色的**订阅版**：浅色是「主题色 10%」，深色是固定的中性边框。
 * 取值与 `hwGlassBorder(isDark)` 逐档一致。
 */
export function resolveGlassBorderColor(isDark: boolean, accentColor: string): string {
  if (isDark) {
    return surfaceBorderDark();
  }
  return withAlpha(accentOrFallback(accentColor), 0.1);
}

/** 危险/错误文字色。 */
export function hwDanger(isDark: boolean): string {
  return isDark ? dangerDark() : HwColor.danger;
}

/** 在线/成功态颜色（图标文字）。 */
export function hwOnline(isDark: boolean): string {
  return isDark ? onlineDark() : HwColor.online;
}

/** 卡片、输入框等内容表面色。 */
export function hwSurface(isDark: boolean): string {
  return isDark ? surfaceDark() : HwColor.surface;
}

/** 玻璃卡片表面色（深浅模式分支）。 */
export function hwGlassSurface(isDark: boolean): string {
  return isDark ? surfaceDark() : HwGlassCardColor.surface;
}

/** 卡片边框色。 */
export function hwGlassBorder(isDark: boolean): string {
  return isDark ? surfaceBorderDark() : HwGlassCardColor.border;
}

export interface HwRadiusScale {
  card: number;
  control: number;
  pill: number;
}

export const HwRadius: HwRadiusScale = {
  card: 24,
  control: 16,
  pill: 999
};

export interface HwSpaceScale {
  xs: number;
  sm: number;
  md: number;
  lg: number;
  xl: number;
}

export const HwSpace: HwSpaceScale = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24
};

export interface HwGlassCardPalette {
  surface: string;
  border: string;
}

/** 浅色玻璃卡片（浅色模式使用）。真实值由 applyAppTheme 按深浅/主题色派生。 */
export const HwGlassCardColor: HwGlassCardPalette = {
  surface: '#B3FFFFFF',
  // 占位值（默认主题色 10% 透明），真实值由 applyAppTheme 派生
  border: '#1A0A59F7'
};

// ---------------------------------------------------------------------------
// 顶部栏毛玻璃色（主页标题栏 + 二级页面顶部返回栏 + 顶栏玻璃按钮）
// ---------------------------------------------------------------------------

/**
 * 浅色模式：白玻璃（40% 白）。压在浅色页面/内容上是一层通透的磨砂白。
 */
export const TOP_BAR_GLASS_LIGHT: string = '#66FFFFFF';
/**
 * 深色模式：**压暗**的黑玻璃。
 *
 * 为什么不能用浅色那一档的深色近亲（`#6624282B`）：那个颜色比深色页面**更亮**
 * （`#24282B` 压在纯黑页面上仍然发灰），滚上来的内容也会把它顶成一块浅板。
 * 深色模式要的是「比页面更深一档的烟熏玻璃」——纯黑底 + 60% 不透明，
 * 配合 blurRadius 得到「压暗」的观感，且无论底下滚过什么内容都保持暗色。
 */
export const TOP_BAR_GLASS_DARK: string = '#99000000';

/** 顶部栏毛玻璃色：按深浅模式取色。所有顶栏（含 HDS 标题栏背景）统一走它。 */
export function topBarGlassColor(isDark: boolean): string {
  return isDark ? TOP_BAR_GLASS_DARK : TOP_BAR_GLASS_LIGHT;
}

/**
 * 顶栏上「圆形玻璃按钮」（`IconCircleButton` 的 `glass` 形态）的底色。
 *
 * 刻意**不直接复用** `topBarGlassColor()`：深色模式下如果按钮和栏底同色，
 * 两者会糊在一起、看不出这里有个按钮，所以按钮保留一层略亮的玻璃。
 * 浅色模式则与栏底同色（本来就是白玻璃 + 细描边）。
 */
export const TOP_BAR_BUTTON_GLASS_DARK: string = '#6624282B';

export function topBarButtonGlassColor(isDark: boolean): string {
  return isDark ? TOP_BAR_BUTTON_GLASS_DARK : TOP_BAR_GLASS_LIGHT;
}

// ---------------------------------------------------------------------------
// 应用主题：把主题色 + 深浅模式写进可变 token，并广播订阅键
// ---------------------------------------------------------------------------

/** 浅色模式页面底色基数（未跟随主题色时） */
const PAGE_BASE_LIGHT: string = '#F1F3F5';
/** 深色模式页面底色基数 */
const PAGE_BASE_DARK: string = '#000000';
/** 浅色背景混入主题色的比例（刻意很淡：直接铺主题色会压过正文） */
const PAGE_TINT_LIGHT: number = 0.12;
/** 深色背景混入主题色的比例 */
const PAGE_TINT_DARK: number = 0.18;

/**
 * 应用主题：把暗/浅色值写入 DesignTokens 的可变 token。
 *
 * ⚠️ **第二个参数一定要传当前主题色**：省略时背景染色会被重置回默认值
 * （函数内部靠 `accentColor` 判断「要不要跟随主题色」）。
 * 容易漏的两处：切换深色模式时、`onConfigurationUpdate`（系统深浅色变化）里。
 */
export function applyAppTheme(isDark: boolean, accentColor: string = ''): void {
  // 总开关关闭 → 整条主题色链路停用，配色逐项回到旧版（见 LEGACY_* 常量）
  themeColorActive = themeColorOn();
  if (!themeColorActive) {
    HwColor.primary = DEFAULT_ACCENT_VALUE;
    HwColor.background = isDark ? LEGACY_PAGE_DARK : LEGACY_PAGE_LIGHT;
    HwColor.backgroundDark = LEGACY_PAGE_DARK;
    HwColor.surface = isDark ? surfaceDark() : '#FFFFFF';
    HwColor.textPrimary = isDark ? textPrimaryDark() : '#182431';
    HwColor.textSecondary = isDark ? textSecondaryDark() : '#8A8F99';
    HwGlassCardColor.surface = isDark ? LEGACY_CARD_SURFACE_DARK : LEGACY_CARD_SURFACE_LIGHT;
    HwGlassCardColor.border = LEGACY_CARD_BORDER;
    AppStorage.setOrCreate(PAGE_BACKGROUND_KEY, HwColor.background);
    AppStorage.setOrCreate(CARD_SURFACE_KEY, HwGlassCardColor.surface);
    // 沾色层同样停用：它是「主题色的 10% 叠加」
    AppStorage.setOrCreate(CARD_TINT_KEY, '');
    return;
  }
  if (accentColor.length > 0) {
    HwColor.primary = normalizeAccentHex(accentColor).length > 0
      ? normalizeAccentHex(accentColor) : HwColor.primary;
  }
  // 默认背景跟随**预设**主题色，且刻意压得很淡：
  // 浅色 = 主题色与页面底色按 12% 混合，深色 = 与深底按 18% 混合。
  // 页面用的是 `isDarkMode ? backgroundDark : background`，所以两个都要跟着染。
  // 默认只让内置预设色参与；打开「高权限自定义主题色」后自定义色也放行。
  const fullAccess = readFlag(CUSTOM_ACCENT_FULL_ACCESS_STORAGE, false);
  const followed = accentColor.length > 0 && (isPresetAccent(accentColor) || fullAccess);
  const tintedLight = followed ? mixHex(PAGE_BASE_LIGHT, accentColor, PAGE_TINT_LIGHT) : PAGE_BASE_LIGHT;
  const tintedDark = followed ? mixHex(PAGE_BASE_DARK, accentColor, PAGE_TINT_DARK) : PAGE_BASE_DARK;
  HwColor.background = isDark ? tintedDark : tintedLight;
  HwColor.backgroundDark = tintedDark;
  // 深色模式的表面/文字保持既有 WCAG 校验过的取值。
  HwColor.surface = isDark ? surfaceDark() : '#FFFFFF';
  HwColor.textPrimary = isDark ? textPrimaryDark() : '#182431';
  HwColor.textSecondary = isDark ? textSecondaryDark() : '#8A8F99';
  // 卡片底色留 70% 透明度：沉浸光感不可用时要降级为毛玻璃（backgroundBlurStyle），
  // 不透明的底色会把模糊整个盖住，等于没有降级效果。
  // 刻意**不把沾色混进这里**：材质生效时外壳底色是透明的，混进去的颜色根本不会被画出来；
  // 沾色改为叠在材质之上的一层（见 CARD_TINT_KEY 与 CardSurface）。
  HwGlassCardColor.surface = isDark ? '#B326364F' : '#B3E8F0F8';
  // 卡片描边跟主题色走，不要写死某个蓝
  HwGlassCardColor.border = withAlpha(HwColor.primary, 0.1);

  // 发布广播键。页面与卡片必须订阅它们而不是直接读 HwColor：
  // ArkUI 按表达式记录依赖，模块级对象的属性读取不会被登记，
  // 拨「卡片沾色」或切主题色时已经画出来的元素不会重新求值。
  AppStorage.setOrCreate(PAGE_BACKGROUND_KEY, HwColor.background);
  AppStorage.setOrCreate(CARD_SURFACE_KEY, HwGlassCardColor.surface);
  AppStorage.setOrCreate(CARD_TINT_KEY,
    accentColor.length > 0 && readFlag(CARD_TINT_STORAGE, false)
      ? withAlpha(accentColor, 0.1) : '');
}

/**
 * 按已保存的设置重建主题并广播。
 *
 * 主题色切换要「实时生效」：HwColor 是模块级对象，直接改属性不会触发刷新，
 * 所以这里把新值写进 AppStorage 的 accentColor，页面订阅它并重建，颜色立即切换。
 *
 * **总开关关闭时广播的是旧版默认色**（鸿蒙蓝）：订阅 accentColor 的开关、底栏高亮、
 * 流光都会跟着回到旧版观感；用户选过的 `accentKey` / `accentCustom` 与自定义列表
 * 原样保留在存储里，重新打开开关即恢复。
 *
 * 注意这里为什么不会死循环：@Watch 回调里再次 reloadAppTheme() 时算出的值相同，
 * `setOrCreate` 写入等值不会触发变更通知。
 */
export function reloadAppTheme(): void {
  let isDark = false;
  let accentKey = DEFAULT_ACCENT_KEY;
  let accentCustom = '';
  try {
    isDark = AppStorage.get<boolean>(DARK_MODE_KEY) === true;
  } catch (err) {
    isDark = false;
  }
  try {
    const stored = AppStorage.get<string>(ACCENT_KEY_STORAGE);
    if (stored !== undefined && stored.length > 0) {
      accentKey = stored;
    }
    const custom = AppStorage.get<string>(ACCENT_CUSTOM_STORAGE);
    if (custom !== undefined) {
      accentCustom = custom;
    }
  } catch (err) {
    // 存储不可用时用默认预设
  }
  const resolved = effectiveAccentColor(accentKey, accentCustom);
  applyAppTheme(isDark, resolved);
  AppStorage.setOrCreate(ACCENT_COLOR_KEY, resolved);
}

/**
 * 页面底色。**所有页面统一走这个函数，不要直接读 `HwColor.background`。**
 *
 * 为什么要绕一层函数：ArkUI 的局部更新按**表达式**记录依赖，而 `HwColor` 是模块级对象
 * ——读它的属性不会被登记。直接写 `this.isDarkMode ? HwColor.backgroundDark : HwColor.background`
 * 只登记了 `isDarkMode`，于是切换主题色时底色不会重新求值，已打开的页面会停在旧色上。
 * 把 `pageBackground` 作为入参传进来，调用点就真正读到了这个订阅键，依赖才登记得上。
 *
 * 两个参数都必须是调用方声明的订阅变量（`@StorageProp` / `@StorageLink`），
 * 传字面量或普通字段没有意义。
 */
export function resolvePageBackground(isDark: boolean, background: string): string {
  if (background.length > 0) {
    return background;
  }
  // 兜底：applyAppTheme 尚未跑过时（理论上不会）退回当前 token
  return isDark ? HwColor.backgroundDark : HwColor.background;
}
