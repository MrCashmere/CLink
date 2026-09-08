// 浅色模式色板（保持与既有取色点兼容）。
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

export const HwColor: HwColorPalette = {
  primary: '#0A59F7',
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
// ---------------------------------------------------------------------------

function textPrimaryDark(): string { return '#F0F2F5'; }
function textSecondaryDark(): string { return '#C0C5CB'; }
function primaryDark(): string { return '#5AA0FF'; }
function primaryButtonDark(): string { return '#1F5FCC'; }
function dangerDark(): string { return '#FF8A7A'; }
function onlineDark(): string { return '#40DB94'; }
function surfaceDark(): string { return '#24272B'; }
function surfaceBorderDark(): string { return '#3A3F45'; }

/** 正文/标题文字色。 */
export function hwTextPrimary(isDark: boolean): string {
  return isDark ? textPrimaryDark() : HwColor.textPrimary;
}

/** 次要/辅助文字色。 */
export function hwTextSecondary(isDark: boolean): string {
  return isDark ? textSecondaryDark() : HwColor.textSecondary;
}

/** 主色：用于文字、链接、选中态图标等前景。按钮背景请用 hwPrimaryButton。 */
export function hwPrimary(isDark: boolean): string {
  return isDark ? primaryDark() : HwColor.primary;
}

/** 主按钮背景色（配白字），深浅模式下发色号不同以保证白字对比度。 */
export function hwPrimaryButton(isDark: boolean): string {
  return isDark ? primaryButtonDark() : HwColor.primary;
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

/** 浅色玻璃卡片（浅色模式使用，保持现状）。 */
export const HwGlassCardColor: HwGlassCardPalette = {
  surface: '#B3FFFFFF',
  border: '#1AFFFFFF'
};
