import { router } from '@kit.ArkUI';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { text } from '@kit.ArkGraphics2D';
import { ACCENT_CUSTOM_LIST_STORAGE, ACCENT_CUSTOM_STORAGE, ACCENT_KEY_STORAGE, ACCENT_PRESETS, AccentCustom, AccentPreset, accentEntryLabel, applyAppTheme, CARD_GLOW_TOUCH_STORAGE, CARD_TINT_STORAGE, CUSTOM_ACCENT_FULL_ACCESS_STORAGE, DARK_MODE_DARK, DARK_MODE_LIGHT, DARK_MODE_PREF_STORAGE, DARK_MODE_SYSTEM, DEFAULT_ACCENT_KEY, HwColor, HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwPrimary, hwDanger, hwGlassBorder, normalizeAccentHex, onAccentColor, parseAccentEntries, PRESS_GLOW_STORAGE, reloadAppTheme, resolveAccentColor, resolvePageBackground, serializeAccentEntries, THEME_COLOR_ENABLED_STORAGE, withAlpha, topBarGlassColor, resolvePrimaryColor } from '../utils/DesignTokens';
import {
  cardGlassEffect,
  cardGlassBorderColor,
  cardGlassShadow,
  dialogSystemMaterial,
  isApi26OrAbove,
  materialDiagnostics,
  menuSystemMaterial,
  sheetBlurStyle
} from '../utils/SystemMaterial';
import { loadCustomFonts } from '../utils/CustomFonts';
import { IconCircleButton } from '../components/IconCircleButton';
import { AppBackground } from '../components/AppBackground';
import { AppSettingsStore } from '../storage/AppSettingsStore';
import { CardSurface } from '../components/CardSurface';
import { AccentColorSentinel, MaterialCardLayer, MaterialSheetPanel } from '../components/MaterialCard';

@Entry
@Component
struct AppearanceSettingsPage {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  /** 主题色变化时触发重建，让 HwColor.primary 的新值生效 */
  @StorageProp('accentColor') @Watch('onAccentColorChanged') accentColor: string = '';
  /** 页面底色（由 applyAppTheme 发布）。订阅它而不是读 HwColor 属性（模块级对象登记不上依赖） */
  @StorageProp('pageBackground') pageBackground: string = '';
  /** 深色模式偏好（三态）：跟随系统 / 浅色 / 深色 */
  @StorageLink('darkModePreference') darkModePref: string = DARK_MODE_SYSTEM;
  @StorageLink('backgroundImage') wallpaperImage: string = '';
  @StorageLink('fontMode') fontMode: string = 'system';
  @StorageLink('fontFamilyEn') fontFamilyEn: string = 'system';
  @StorageLink('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageLink('fontSizeMode') fontSizeMode: string = 'system';
  @StorageLink('fontSizeValue') fontSizeValue: number = 16;
  @StorageLink('fontWeightMode') fontWeightMode: string = 'system';
  @StorageLink('fontWeightValue') fontWeightValue: number = 400;
  @StorageLink('immersiveLightEnabled') immersiveLightEnabled: boolean = true;
  @StorageLink('beautifulCards') beautifulCards: boolean = false;
  @StorageLink('classicCards') classicCards: boolean = false;
  @StorageLink('cardShadowBorder') cardShadowBorder: boolean = true;
  /** 兼容键：「沉浸光感卡片（实验性）」已并入「全局沉浸光感」，仅保留读写以免老配置丢失 */
  @StorageLink('experimentalCards') experimentalCards: boolean = false;
  @StorageLink('cardsFromTop') cardsFromTop: boolean = true;
  @StorageLink('customFonts') customFonts: string[] = [];
  /** 卡片沾色：打开后所有卡片叠一层 10% 主题色 */
  @StorageLink('cardTintEnabled') cardTintEnabled: boolean = false;
  /** 高权限自定义主题色：打开后自定义色也参与页面背景染色 */
  @StorageLink('customAccentFullAccess') customAccentFullAccess: boolean = false;
  /** 主题色流光：按压卡片的流光/光晕用主题色，关闭回到系统默认白光 */
  @StorageLink('immersivePressGlow') pressGlowEnabled: boolean = true;
  /** 卡片流光触感：打开后按压卡片才出现流光（关闭则按压卡片不出现任何光） */
  @StorageLink('cardGlowTouch') cardGlowTouch: boolean = false;
  /** 主题色：预设 key（harmony/rose/ripple/firefly/custom） */
  @StorageLink('accentKey') accentKey: string = DEFAULT_ACCENT_KEY;
  /** 自定义主题色（RRGGBB，不含 #） */
  @StorageLink('accentCustom') accentCustom: string = '';
  /** 「主题色」总开关（默认开）：关闭后所有主题色不生效，配色回到旧版 */
  @StorageLink('themeColorEnabled') themeColorEnabled: boolean = true;
  /** 用户新增的自定义主题色（色值 + 昵称），顺序即展示顺序 */
  @State accentList: AccentCustom[] = [];
  /** 自定义主题色的输入弹窗（新增 / 编辑共用） */
  @State showAccentSheet: boolean = false;
  /** 编辑中的色值（空串 = 当前是「新增」模式；非空 = 长按色块进来的编辑模式） */
  @State editingAccentHex: string = '';
  /** 色值输入框草稿与校验提示 */
  @State accentDraft: string = '';
  /** 昵称输入框草稿（界面上只显示昵称，不显示色值） */
  @State accentNameDraft: string = '';
  @State accentError: string = '';
  @State backgroundMessage: string = '';
  @State fontMessage: string = '';
  @State systemFonts: string[] = [];
  // 临时开关：是否在字体选择器中显示系统字体。仅本次会话有效，不持久化。
  @State showSystemFonts: boolean = false;

  /** 主题色变了：HwColor 是模块级对象，改属性不会触发刷新，靠这里重建页面 */
  onAccentColorChanged(): void {
    reloadAppTheme();
  }

  /**
   * 当前主题色。
   * 读 `accentColor` 建立依赖：直接写 `HwColor.primary` 在切主题色后不会重新求值，
   * 开关、选中态会停留在旧色。
   */
  private accentOrPrimary(): string {
    return this.accentColor.length > 0 ? this.accentColor : HwColor.primary;
  }

  aboutToAppear(): void {
    this.loadCustomFonts();
    this.loadAccentList();
    this.refreshAvailableFonts();
    this.applyFontSizeScale();
  }

  onPageShow(): void {
    this.refreshAvailableFonts();
  }

  private appFontFamily(content: string): string {
    if (this.fontMode !== 'custom') {
      return 'HarmonyOS Sans';
    }
    const family = this.hasCjk(content) ? this.fontFamilyZh : this.fontFamilyEn;
    return family === 'system' || family.length === 0 ? 'HarmonyOS Sans' : family;
  }

  private hasCjk(content: string): boolean {
    for (let i = 0; i < content.length; i++) {
      const code = content.charCodeAt(i);
      if (code >= 0x4E00 && code <= 0x9FFF) {
        return true;
      }
    }
    return false;
  }

  private appFontWeight(): number {
    return this.fontWeightMode === 'custom' ? this.fontWeightValue : 400;
  }

  private fontDir(): string {
    const context = getContext(this) as common.UIAbilityContext;
    return `${context.filesDir}/custom_fonts`;
  }

  private aliasOf(fileName: string): string {
    const lower = fileName.toLowerCase();
    const ext = lower.endsWith('.ttf') ? '.ttf' : '.otf';
    return fileName.substring(0, fileName.length - ext.length);
  }

  loadCustomFonts(): void {
    const context = getContext(this) as common.UIAbilityContext;
    loadCustomFonts(context.filesDir, this.customFonts);
  }

  private applyFontSizeScale(): void {
    try {
      const appContext = (getContext(this) as common.UIAbilityContext).getApplicationContext();
      let scale: number = 1;
      if (this.fontSizeMode === 'custom') {
        scale = this.fontSizeValue / 16;
      }
      appContext.setFontSizeScale(scale);
    } catch (err) {
    }
  }

  async refreshAvailableFonts(): Promise<void> {
    const names: string[] = [];
    try {
      const systemFonts = await text.getSystemFontFullNamesByType(text.SystemFontType.ALL);
      for (let i = 0; i < systemFonts.length; i++) {
        const family = systemFonts[i];
        if (names.indexOf(family) < 0) {
          names.push(family);
        }
      }
    } catch (err) {
    }
    this.systemFonts = names;
  }

  async pickBackgroundImage(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const imagePicker = new photoAccessHelper.PhotoViewPicker();
      const result = await imagePicker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      });
      if (result.photoUris.length === 0) {
        return;
      }
      const sourceUri = result.photoUris[0];
      const tempPath = `${context.filesDir}/background_source`;
      let cropUri = sourceUri;
      try {
        try {
          fs.unlinkSync(tempPath);
        } catch (ignored) {
        }
        await fs.copyFile(sourceUri, tempPath);
        cropUri = `file://${tempPath}`;
      } catch (copyErr) {
      }
      router.pushUrl({
        url: 'pages/BackgroundCropPage',
        params: { sourceUri: cropUri }
      });
    } catch (err) {
      this.backgroundMessage = '选择图片失败';
    }
  }

  clearBackground(): void {
    this.wallpaperImage = '';
    AppSettingsStore.delete('backgroundImage');
    this.backgroundMessage = '背景已清空';
  }

  showClearBackgroundDialog(): void {
    this.getUIContext().showAlertDialog({
      systemMaterial: dialogSystemMaterial(),
      title: '清空背景',
      message: '确定要清空当前自定义背景吗？清空后无法恢复。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: hwDanger(this.isDarkMode),
        action: () => {
          this.clearBackground();
        }
      }
    });
  }

  async uploadFont(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const documentPicker = new picker.DocumentViewPicker(context);
      const result = await documentPicker.select({
        maxSelectNumber: 1,
        fileSuffixFilters: ['.ttf', '.otf']
      });
      if (result.length === 0) {
        return;
      }
      const sourceUri = result[0];
      let srcFile: fs.File | undefined = undefined;
      let fileName = '';
      try {
        srcFile = fs.openSync(sourceUri, fs.OpenMode.READ_ONLY);
        fileName = srcFile.name;
      } catch (openErr) {
        this.fontMessage = '无法读取所选字体文件';
        return;
      }
      if (fileName.length === 0) {
        try {
          const rawName = sourceUri.split('/').pop() ?? '';
          fileName = decodeURIComponent(rawName);
        } catch (nameErr) {
          this.fontMessage = '无法识别字体文件名';
          return;
        }
      }
      if (srcFile === undefined) {
        this.fontMessage = '无法读取所选字体文件';
        return;
      }
      const lowerName = fileName.toLowerCase();
      if (!lowerName.endsWith('.ttf') && !lowerName.endsWith('.otf')) {
        fs.closeSync(srcFile);
        this.fontMessage = '仅支持 ttf / otf 字体文件';
        return;
      }
      const dir = this.fontDir();
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
      const ext = lowerName.endsWith('.ttf') ? '.ttf' : '.otf';
      const base = fileName.substring(0, fileName.length - 4);
      let targetName = fileName;
      let index = 1;
      while (fs.accessSync(`${dir}/${targetName}`)) {
        targetName = `${base}_${index}${ext}`;
        index++;
      }
      const targetPath = `${dir}/${targetName}`;
      const dstFile = fs.openSync(targetPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        const buffer = new ArrayBuffer(1024 * 1024);
        while (true) {
          const readLen = fs.readSync(srcFile.fd, buffer);
          if (readLen <= 0) {
            break;
          }
          fs.writeSync(dstFile.fd, buffer, { length: readLen });
        }
      } finally {
        fs.closeSync(dstFile);
        fs.closeSync(srcFile);
      }
      const alias = targetName.substring(0, targetName.length - 4);
      try {
        text.FontCollection.getGlobalInstance().loadFontSyncWithCheck(alias, `file://${targetPath}`);
      } catch (verifyErr) {
        try {
          fs.unlinkSync(targetPath);
        } catch (ignored) {
        }
        this.fontMessage = '字体文件无效，请上传有效的 ttf / otf 文件';
        return;
      }
      const nextFonts: string[] = this.customFonts.slice();
      nextFonts.push(targetName);
      this.customFonts = nextFonts;
      AppSettingsStore.setStringArray('customFonts', nextFonts);
      this.refreshAvailableFonts();
      this.fontMessage = '字体上传成功';
    } catch (err) {
      this.fontMessage = '上传字体失败';
    }
  }

  setFontMode(mode: string): void {
    this.fontMode = mode;
    AppSettingsStore.setString('fontMode', mode);
  }

  setFontFamily(isEnglish: boolean, family: string): void {
    if (isEnglish) {
      this.fontFamilyEn = family;
      AppSettingsStore.setString('fontFamilyEn', family);
    } else {
      this.fontFamilyZh = family;
      AppSettingsStore.setString('fontFamilyZh', family);
    }
  }

  setFontSizeMode(mode: string): void {
    this.fontSizeMode = mode;
    AppSettingsStore.setString('fontSizeMode', mode);
    this.applyFontSizeScale();
  }

  setFontWeightMode(mode: string): void {
    this.fontWeightMode = mode;
    AppSettingsStore.setString('fontWeightMode', mode);
  }

  onFontSizeChange(value: number): void {
    const rounded = Math.round(value);
    this.fontSizeValue = rounded;
    AppSettingsStore.setNumber('fontSizeValue', rounded);
    this.applyFontSizeScale();
  }

  onFontWeightChange(value: number): void {
    const weight = Math.round(value / 100) * 100;
    this.fontWeightValue = weight;
    AppSettingsStore.setNumber('fontWeightValue', weight);
  }

  setCardsFromTop(isOn: boolean): void {
    this.cardsFromTop = isOn;
    AppSettingsStore.setBoolean('cardsFromTop', isOn);
  }

  /** 「更优美的卡片」开关：卡片改用 backgroundEffect 玻璃质感。用户手动设置后不再自动开启。 */
  setBeautifulCards(isOn: boolean): void {
    this.beautifulCards = isOn;
    AppSettingsStore.setBoolean('beautifulCards', isOn);
    AppSettingsStore.setBoolean('beautifulCardsUserSet', true);
  }

  /** 「卡片阴影描边」开关：仅「更优美的卡片」关闭时生效。 */
  setCardShadowBorder(isOn: boolean): void {
    this.cardShadowBorder = isOn;
    AppSettingsStore.setBoolean('cardShadowBorder', isOn);
  }

  /** 「经典卡片样式」开关：仅「更优美的卡片」关闭时生效。 */
  setClassicCards(isOn: boolean): void {
    this.classicCards = isOn;
    AppSettingsStore.setBoolean('classicCards', isOn);
  }

  /**
   * 「沉浸光感卡片（实验性）」开关（兼容保留）。
   *
   * 卡片表面现在**始终**由 Toggle 承载层接管（见 components/CardSurface.ets），
   * 该开关已并入「全局沉浸光感」，不再参与判定；这里只把值写回存储，避免老配置丢失。
   */
  setExperimentalCards(isOn: boolean): void {
    this.experimentalCards = isOn;
    AppSettingsStore.setBoolean('experimentalCards', isOn);
  }

  // ==================== 主题色 ====================

  /**
   * 读入自定义主题色列表（色值 + 昵称）。
   *
   * 兼容两件旧数据：
   *   - 更早版本只有一个 `accentCustom`、没有列表 → 补进列表，否则升级后原有那个自定义色会消失；
   *   - 旧列表元素是纯 `'RRGGBB'` → `parseAccentEntries()` 按无昵称解析。
   */
  private loadAccentList(): void {
    const stored = AppSettingsStore.getStringArray(ACCENT_CUSTOM_LIST_STORAGE, []);
    const list = parseAccentEntries(stored);
    const current = normalizeAccentHex(this.accentCustom).replace('#', '');
    let hasCurrent = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].hex === current) {
        hasCurrent = true;
        break;
      }
    }
    if (current.length === 6 && !hasCurrent) {
      list.push({ hex: current, name: '' });
      AppSettingsStore.setStringArray(ACCENT_CUSTOM_LIST_STORAGE, serializeAccentEntries(list));
    }
    this.accentList = list;
  }

  /** 选择预设主题色并立即生效 */
  private selectAccentPreset(key: string): void {
    this.accentKey = key;
    AppSettingsStore.setString(ACCENT_KEY_STORAGE, key);
    this.applyAccentNow();
  }

  /**
   * 新增 / 保存一个自定义主题色（带昵称）。
   *
   * 同一弹窗承担两种模式：
   *   - `editingAccentHex` 为空 → **新增**：追加到列表末尾（也就是「新增」按钮前面）并立即选中；
   *   - 非空 → **编辑**（长按色块进入）：就地改色值与昵称。
   * 只接受 6 位十六进制；非法输入不入列表也不改主题，避免把配色改成不可读的颜色。
   */
  private saveCustomAccent(): void {
    const normalized = normalizeAccentHex(this.accentDraft);
    if (normalized.length === 0) {
      this.accentError = '请输入 6 位十六进制颜色，例如 1A2B3C';
      return;
    }
    this.accentError = '';
    const hex = normalized.replace('#', '');
    const name = this.accentNameDraft.trim();
    const editing = this.editingAccentHex;
    const next: AccentCustom[] = [];
    for (let i = 0; i < this.accentList.length; i++) {
      next.push({ hex: this.accentList[i].hex, name: this.accentList[i].name });
    }
    if (editing.length > 0) {
      // 编辑：先把原项摘掉，再按新色值落位（避免「改成已存在的色值」留下重复项）
      const wasSelected = this.isCustomSelected(editing);
      for (let i = next.length - 1; i >= 0; i--) {
        if (next[i].hex === editing) {
          next.splice(i, 1);
          break;
        }
      }
      let merged = false;
      for (let i = 0; i < next.length; i++) {
        if (next[i].hex === hex) {
          if (name.length > 0) {
            next[i].name = name;
          }
          merged = true;
          break;
        }
      }
      if (!merged) {
        next.push({ hex: hex, name: name });
      }
      this.persistAccentList(next);
      this.accentDraft = '';
      this.accentNameDraft = '';
      this.editingAccentHex = '';
      this.showAccentSheet = false;
      // 只有「改的正好是当前选中色」才跟着换选中值；
      // 编辑一个没被选中的色不该把选中态抢过来
      if (wasSelected) {
        this.selectCustomAccent(hex);
      }
      return;
    }
    // 新增
    let exists = false;
    for (let i = 0; i < next.length; i++) {
      if (next[i].hex === hex) {
        if (name.length > 0) {
          next[i].name = name;
        }
        exists = true;
        break;
      }
    }
    if (!exists) {
      next.push({ hex: hex, name: name });
    }
    this.persistAccentList(next);
    this.accentDraft = '';
    this.accentNameDraft = '';
    this.showAccentSheet = false;
    this.selectCustomAccent(hex);
  }

  /** 写回自定义列表（持久化格式：`RRGGBB` 或 `RRGGBB|昵称`） */
  private persistAccentList(list: AccentCustom[]): void {
    this.accentList = list;
    AppSettingsStore.setStringArray(ACCENT_CUSTOM_LIST_STORAGE, serializeAccentEntries(list));
  }

  /** 打开「新增」弹窗 */
  private startAddAccent(): void {
    this.editingAccentHex = '';
    this.accentDraft = '';
    this.accentNameDraft = '';
    this.accentError = '';
    this.showAccentSheet = true;
  }

  /**
   * 打开「编辑」弹窗（**长按自定义色块**触发；内置预设不响应）。
   * 色值输入框只用于改值，昵称则是用户真正看到的标签。
   */
  private startEditAccent(hex: string): void {
    const name = this.accentNameOf(hex);
    this.editingAccentHex = hex;
    this.accentDraft = hex;
    this.accentNameDraft = name;
    this.accentError = '';
    this.showAccentSheet = true;
  }

  /** 取某个自定义色的昵称（没有则空串） */
  private accentNameOf(hex: string): string {
    for (let i = 0; i < this.accentList.length; i++) {
      if (this.accentList[i].hex === hex) {
        return this.accentList[i].name;
      }
    }
    return '';
  }

  /** 选中列表里的某个自定义主题色 */
  private selectCustomAccent(hex: string): void {
    this.accentKey = 'custom';
    this.accentCustom = hex;
    AppSettingsStore.setString(ACCENT_KEY_STORAGE, 'custom');
    AppSettingsStore.setString(ACCENT_CUSTOM_STORAGE, hex);
    this.applyAccentNow();
  }

  /** 该自定义色当前是否被选中 */
  private isCustomSelected(hex: string): boolean {
    return this.accentKey === 'custom' && this.accentCustom.toUpperCase() === hex.toUpperCase();
  }

  /**
   * 删除一个自定义主题色。
   * 删掉的正好是当前选中色时，回落到第一个预设色——否则 `accentCustom` 会指向
   * 一个已经不在列表里的值，界面看上去「选中态凭空消失」。
   */
  private removeCustomAccent(hex: string): void {
    const wasSelected = this.isCustomSelected(hex);
    const next: AccentCustom[] = [];
    for (let i = 0; i < this.accentList.length; i++) {
      if (this.accentList[i].hex !== hex) {
        next.push({ hex: this.accentList[i].hex, name: this.accentList[i].name });
      }
    }
    if (next.length === this.accentList.length) {
      return;
    }
    this.persistAccentList(next);
    if (wasSelected) {
      this.selectAccentPreset(ACCENT_PRESETS[0].key);
    }
  }

  /**
   * 「主题色」总开关。
   *
   * 关闭后所有主题色都不生效、配色回到加主题色功能之前的那一版
   * （`applyAppTheme` 里走 `LEGACY_*` 那一支），用户选过的颜色与自定义列表保留。
   */
  private setThemeColorEnabled(enabled: boolean): void {
    AppSettingsStore.setBoolean(THEME_COLOR_ENABLED_STORAGE, enabled);
    AppStorage.setOrCreate(THEME_COLOR_ENABLED_STORAGE, enabled);
    reloadAppTheme();
  }

  /**
   * 主题色实时生效。
   *
   * `accentKey` / `accentCustom` 已是 @StorageLink，赋值即同步进 AppStorage；
   * 再广播 `accentColor`，各页面的 @Watch 会重建并读到新色值。
   * 只改 HwColor 属性不会触发刷新，所以必须走这条广播链。
   */
  private applyAccentNow(): void {
    AppStorage.setOrCreate(ACCENT_KEY_STORAGE, this.accentKey);
    AppStorage.setOrCreate(ACCENT_CUSTOM_STORAGE, this.accentCustom);
    reloadAppTheme();
  }

  /** 当前选中色，用于选择器上的对勾与色块 */
  private currentAccent(): string {
    return resolveAccentColor(this.accentKey, this.accentCustom);
  }

  /**
   * 卡片沾色开关。
   *
   * 这个开关只改派生 token、不改主题色本身，不能指望 `accentColor` 变化来触发刷新：
   * applyAppTheme 会把沾色层颜色发布到 `cardTintColor`，订阅了它的卡片才会跟着更新。
   */
  private setCardTint(enabled: boolean): void {
    AppSettingsStore.setBoolean(CARD_TINT_STORAGE, enabled);
    AppStorage.setOrCreate(CARD_TINT_STORAGE, enabled);
    reloadAppTheme();
  }

  /** 高权限自定义主题色开关：只是把「只跟随预设色」的门槛去掉，淡染算法不变 */
  private setCustomAccentFullAccess(enabled: boolean): void {
    AppSettingsStore.setBoolean(CUSTOM_ACCENT_FULL_ACCESS_STORAGE, enabled);
    AppStorage.setOrCreate(CUSTOM_ACCENT_FULL_ACCESS_STORAGE, enabled);
    reloadAppTheme();
  }

  /** 主题色流光开关：只影响流光取色，卡片与圆形按钮订阅了它，写一次即可重绘 */
  private setPressGlow(enabled: boolean): void {
    AppSettingsStore.setBoolean(PRESS_GLOW_STORAGE, enabled);
    AppStorage.setOrCreate(PRESS_GLOW_STORAGE, enabled);
  }

  /** 卡片流光触感开关：只改卡片上画不画流光，**与底栏流光无关** */
  private setCardGlowTouch(enabled: boolean): void {
    AppSettingsStore.setBoolean(CARD_GLOW_TOUCH_STORAGE, enabled);
    AppStorage.setOrCreate(CARD_GLOW_TOUCH_STORAGE, enabled);
  }

  // ==================== 深色模式（三态） ====================

  /** 读系统当前深浅色（偏好为「跟随系统」时用） */
  private systemDarkMode(): boolean {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const config = ctx.getApplicationContext().resourceManager.getConfigurationSync();
      return config.colorMode === resourceManager.ColorMode.DARK;
    } catch (err) {
      return false;
    }
  }

  /**
   * 切换深色模式偏好。
   *
   * 三态：`system` 跟随系统、`light` / `dark` 固定。
   * 必须同时把平台配色一起下发，否则系统控件（弹窗、输入法等）会和自绘颜色一深一浅；
   * **跟随系统时要下发 `COLOR_MODE_NOT_SET`**，下发明确值会被钉死在当前深浅色上。
   */
  private setDarkModePref(pref: string): void {
    this.darkModePref = pref;
    AppSettingsStore.setString(DARK_MODE_PREF_STORAGE, pref);
    AppStorage.setOrCreate(DARK_MODE_PREF_STORAGE, pref);
    const enabled = pref === DARK_MODE_DARK ? true
      : (pref === DARK_MODE_LIGHT ? false : this.systemDarkMode());
    this.applyDarkMode(enabled, pref);
  }

  private applyDarkMode(enabled: boolean, pref: string): void {
    // 必须把当前主题色一并传入：背景色是按主题色染的，只传 isDark 会把染色重置回默认。
    applyAppTheme(enabled, this.currentAccent());
    // isDarkMode 是 @StorageLink，赋值会同步写回 AppStorage，其余订阅该键的页面随即重建。
    this.isDarkMode = enabled;
    AppStorage.setOrCreate(ACCENT_KEY_STORAGE, this.accentKey);
    AppStorage.setOrCreate(ACCENT_CUSTOM_STORAGE, this.accentCustom);
    AppStorage.setOrCreate('accentColor', this.accentColor);
    try {
      const mode = pref === DARK_MODE_DARK
        ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : (pref === DARK_MODE_LIGHT
          ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
          : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      (getContext(this) as common.UIAbilityContext).getApplicationContext().setColorMode(mode);
    } catch (err) {
    }
  }

  // ==================== 主题色 / 深色模式 的 UI 片段 ====================

  /**
   * 深色模式三态芯片。
   * 结构与选中态芯片的标准写法一致：自绘底色 + 材质承载层 + 文字穿透。
   */
  @Builder
  darkModeChip(mode: string, label: string) {
    Stack() {
      Row()
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        .borderRadius(HwRadius.pill)
        .backgroundColor(this.darkModePref === mode
          ? this.accentOrPrimary() : withAlpha(HwColor.textPrimary, 0.06))

      // 小尺寸芯片关掉材质自带投影
      MaterialCardLayer({ layerRadius: HwRadius.pill, layerShadow: false })

      Text(label)
        .fontFamily(this.appFontFamily(label))
        .fontWeight(this.appFontWeight())
        .fontSize(13)
        // 主题色底上的字色按深浅自动取黑/白（浅色主题色上白字看不清）
        .fontColor(this.darkModePref === mode
          ? onAccentColor(this.accentOrPrimary()) : HwColor.textPrimary)
        .padding({ left: 16, right: 16, top: 7, bottom: 7 })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')
    }
    .onClick((): void => {
      this.setDarkModePref(mode);
    })
  }

  /**
   * 一个主题色色块。
   *
   * 预设色块与自定义色块完全同构（圆点 + 名称），差别有两处：
   *   - 自定义色 `removable` 为 true：右上角叠一个删除角标，且**长按可编辑**（改色值 / 改昵称）；
   *   - 标签只显示**昵称**（没起名字才回落 `#RRGGBB`），界面上不展示色值本身。
   * 内置预设不响应长按。
   *
   * 角标是卡片的**兄弟节点**而不是子节点：ArkUI 的点击会向父级冒泡，
   * 做成子节点的话点删除会连带触发一次选中。
   */
  @Builder
  accentSwatch(key: string, color: string, label: string, selected: boolean, removable: boolean) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Stack() {
        // 与卡片同源的 Toggle 承载层：小尺寸芯片关掉材质自带投影
        MaterialCardLayer({ layerRadius: HwRadius.control, layerShadow: false })
        Column({ space: 6 }) {
          Stack({ alignContent: Alignment.Center }) {
            Circle()
              .width(34)
              .height(34)
              .fill(color)
            if (selected) {
              // 对勾压在这个色块自己的颜色上：浅色主题色（涟漪粉 / 流荧绿）上白勾看不见，
              // 按亮度自动切黑勾
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(16)
                .fontColor([onAccentColor(color)])
            }
          }
          .width(34)
          .height(34)

          Text(label)
            .fontFamily(this.appFontFamily(label))
            .fontWeight(this.appFontWeight())
            .fontSize(12)
            .fontColor(selected ? this.accentOrPrimary() : hwTextSecondary(this.isDarkMode))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width(64)
        .padding(8)
        .borderRadius(HwRadius.control)
        .backgroundColor(Color.Transparent)
        .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
        .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
        .clip(true)
        .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
        .onClick((): void => {
          if (removable) {
            this.selectCustomAccent(key);
          } else {
            this.selectAccentPreset(key);
          }
        })
      }
      .width(64)
      .borderRadius(HwRadius.control)
      // 长按编辑：只对自定义色挂手势，内置预设不响应
      .gesture(
        LongPressGesture()
          .onAction((): void => {
            if (removable) {
              this.startEditAccent(key);
            }
          })
      )

      if (removable) {
        // 删除角标：半透明黑底保证在浅色/深色材质上都看得清
        Stack({ alignContent: Alignment.Center }) {
          Circle()
            .width(20)
            .height(20)
            .fill('#99000000')
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(11)
            .fontColor([Color.White])
        }
        .width(20)
        .height(20)
        .margin({ top: 4, right: 4 })
        .onClick((): void => {
          this.removeCustomAccent(key);
        })
      }
    }
    .margin({ right: HwSpace.md, bottom: HwSpace.md })
  }

  /** 「新增自定义色」按钮：与色块同尺寸同排版，只把圆点换成加号 */
  @Builder
  addAccentSwatch() {
    Stack() {
      MaterialCardLayer({ layerRadius: HwRadius.control, layerShadow: false })
      Column({ space: 6 }) {
        Stack({ alignContent: Alignment.Center }) {
          Circle()
            .width(34)
            .height(34)
            .fill('#14000000')
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(18)
            .fontColor([hwTextSecondary(this.isDarkMode)])
        }
        .width(34)
        .height(34)

        Text('自定义')
          .fontFamily(this.appFontFamily('自定义'))
          .fontWeight(this.appFontWeight())
          .fontSize(12)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .maxLines(1)
      }
      .width(64)
      .padding(8)
      .borderRadius(HwRadius.control)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
      .onClick((): void => {
        this.startAddAccent();
      })
    }
    .width(64)
    .borderRadius(HwRadius.control)
    .margin({ right: HwSpace.md, bottom: HwSpace.md })
  }

  /**
   * 自定义主题色的输入弹窗（底部面板），沿用全站一致的沉浸光感材质。
   *
   * 同一个面板承担「新增」与「编辑」两种模式（由 `editingAccentHex` 区分）：
   * 色值 + **昵称** 两个输入框，昵称就是色块上显示的名字。
   */
  @Builder
  accentInputSheet() {
    MaterialSheetPanel() {
      Column({ space: 0 }) {
        Row({ space: 12 }) {
          Text(this.editingAccentHex.length > 0 ? '编辑主题色' : '自定义主题色')
            .fontFamily(this.appFontFamily(this.editingAccentHex.length > 0 ? '编辑主题色' : '自定义主题色'))
            .fontWeight(this.appFontWeight())
            .fontSize(16)
            .fontColor(hwTextPrimary(this.isDarkMode))
            .layoutWeight(1)
          IconCircleButton({
            symbol: $r('sys.symbol.xmark'),
            buttonSize: 36,
            iconSize: 18,
            onAction: (): void => {
              this.showAccentSheet = false;
            }
          })
        }
        .width('100%')
        .height(56)
        .alignItems(VerticalAlign.Center)
        .padding({ left: HwSpace.lg, right: HwSpace.lg })

        Column({ space: HwSpace.md }) {
          // 昵称：色块上显示的就是它，所以放在色值前面
          Text('昵称（显示在色块上，留空则显示色值）')
            .fontFamily(this.appFontFamily('昵称（显示在色块上，留空则显示色值）'))
            .fontWeight(this.appFontWeight())
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .width('100%')
          TextInput({ text: this.accentNameDraft, placeholder: '例如：我的主题色' })
            .caretColor(this.accentOrPrimary())
            .width('100%')
            .height(44)
            .fontSize(15)
            .maxLength(12)
            .backgroundColor(Color.Transparent)
            .padding({ left: HwSpace.md, right: HwSpace.md })
            .fontColor(hwTextPrimary(this.isDarkMode))
            .placeholderColor(hwTextSecondary(this.isDarkMode))
            .onChange((value: string) => {
              this.accentNameDraft = value;
            })

          Text('色值：6 位十六进制（RRGGBB），例如 1A2B3C')
            .fontFamily(this.appFontFamily('色值：6 位十六进制（RRGGBB），例如 1A2B3C'))
            .fontWeight(this.appFontWeight())
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .width('100%')
            .margin({ top: HwSpace.xs })

          Row({ space: HwSpace.sm }) {
            TextInput({ text: this.accentDraft, placeholder: 'RRGGBB' })
              .layoutWeight(1)
              .height(44)
              .fontSize(15)
              .maxLength(7)
              .backgroundColor(Color.Transparent)
              .padding({ left: HwSpace.md, right: HwSpace.md })
              .fontColor(hwTextPrimary(this.isDarkMode))
              .placeholderColor(hwTextSecondary(this.isDarkMode))
              .caretColor(this.accentOrPrimary())
              .onChange((value: string) => {
                this.accentDraft = value;
                this.accentError = '';
              })
            // 实时预览：非法时回落到当前主题色，避免闪成透明
            Circle()
              .width(28)
              .height(28)
              .fill(normalizeAccentHex(this.accentDraft).length > 0
                ? normalizeAccentHex(this.accentDraft) : this.currentAccent())
          }
          .width('100%')

          if (this.accentError.length > 0) {
            Text(this.accentError)
              .fontFamily(this.appFontFamily(this.accentError))
              .fontWeight(this.appFontWeight())
              .fontSize(12)
              .fontColor(hwDanger(this.isDarkMode))
              .width('100%')
          }

          Stack() {
            // 材质承载层：普通 Button 直接挂 systemMaterial 在真机上不渲染，
            // 这里统一走已验证的 Toggle 承载路径。
            MaterialCardLayer({ layerRadius: HwRadius.pill })
            Button(this.editingAccentHex.length > 0 ? '保存' : '添加到主题色',
              { type: ButtonType.Capsule, stateEffect: false })
              .width('100%')
              .height(44)
              .fontSize(15)
              .fontColor(this.accentOrPrimary())
              .backgroundColor(Color.Transparent)
              .onClick((): void => {
                this.saveCustomAccent();
              })
          }
        }
        .width('100%')
        .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: HwSpace.lg })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  fontModeMenu(): MenuElement[] {
    return [
      {
        value: '跟随系统',
        action: () => {
          this.setFontMode('system');
        }
      },
      {
        value: '自定义字体',
        action: () => {
          this.setFontMode('custom');
        }
      }
    ];
  }

  fontFamilyMenu(isEnglish: boolean): MenuElement[] {
    const items: MenuElement[] = [
      {
        value: '跟随系统',
        action: () => {
          this.setFontFamily(isEnglish, 'system');
        }
      }
    ];
    const added: string[] = [];
    // 已上传字体始终显示。
    for (let i = 0; i < this.customFonts.length; i++) {
      const alias = this.aliasOf(this.customFonts[i]);
      if (added.indexOf(alias) < 0) {
        added.push(alias);
        items.push({
          value: alias,
          action: () => {
            this.setFontFamily(isEnglish, alias);
          }
        });
      }
    }
    // 仅当“显示系统字体”开关打开时追加系统字体。
    if (this.showSystemFonts) {
      for (let i = 0; i < this.systemFonts.length; i++) {
        const family = this.systemFonts[i];
        if (added.indexOf(family) < 0) {
          added.push(family);
          items.push({
            value: family,
            action: () => {
              this.setFontFamily(isEnglish, family);
            }
          });
        }
      }
    }
    return items;
  }

  fontSizeModeMenu(): MenuElement[] {
    return [
      {
        value: '跟随系统',
        action: () => {
          this.setFontSizeMode('system');
        }
      },
      {
        value: '自定义',
        action: () => {
          this.setFontSizeMode('custom');
        }
      }
    ];
  }

  fontWeightModeMenu(): MenuElement[] {
    return [
      {
        value: '跟随系统',
        action: () => {
          this.setFontWeightMode('system');
        }
      },
      {
        value: '自定义',
        action: () => {
          this.setFontWeightMode('custom');
        }
      }
    ];
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 主题色依赖：切色时让整页重新求值（零尺寸，不参与布局）
      AccentColorSentinel()
      AppBackground()
      // 自定义主题色输入弹窗：挂在零尺寸容器上，不影响布局
      Column()
        .width(0)
        .height(0)
        .bindSheet($$this.showAccentSheet, this.accentInputSheet(), {
          height: SheetSize.MEDIUM,
          dragBar: true,
          showClose: false,
          // 必须显式透明：BindOptions.backgroundColor 默认是 Color.White，
          // 而沉浸光感的视觉层级位于 backgroundColor 之下，白底会把材质整块盖住
          backgroundColor: Color.Transparent,
          blurStyle: sheetBlurStyle()
        })
      Column() {
        Scroll() {
          Column({ space: 0 }) {
            Blank().height(56 + this.statusBarHeight)
            Column({ space: 12 }) {
              if (this.backgroundMessage.length > 0) {
                Text(this.backgroundMessage)
                  .fontFamily(this.appFontFamily(this.backgroundMessage))
                  .fontWeight(this.appFontWeight())
                  .fontSize(13)
                  .fontColor(resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()))
                  .width('100%')
                  .padding({ left: 4, right: 4 })
              }
              if (this.fontMessage.length > 0) {
                Text(this.fontMessage)
                  .fontFamily(this.appFontFamily(this.fontMessage))
                  .fontWeight(this.appFontWeight())
                  .fontSize(13)
                  .fontColor(resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()))
                  .width('100%')
                  .padding({ left: 4, right: 4 })
              }

              CardSurface({ radius: HwRadius.card }) {
                Row({ space: 12 }) {
                  Column({ space: 4 }) {
                    Text('更优美的卡片')
                      .fontFamily(this.appFontFamily('更优美的卡片'))
                      .fontWeight(this.appFontWeight())
                      .fontSize(15)
                      .fontColor(hwTextPrimary(this.isDarkMode))
                    Text('毛玻璃质感，更通透')
                      .fontFamily(this.appFontFamily('毛玻璃质感，更通透'))
                      .fontWeight(this.appFontWeight())
                      .fontSize(12)
                      .fontColor(hwTextSecondary(this.isDarkMode))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.beautifulCards })
                    .selectedColor(this.accentOrPrimary())
                    .onChange((isOn: boolean) => {
                      this.setBeautifulCards(isOn);
                    })
                }
                .width('100%')
                .padding(HwSpace.lg)
                .borderRadius(HwRadius.card)
                .backgroundColor(Color.Transparent)
                .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                .clip(true)
                .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
              }

              // 「卡片阴影描边」/「经典卡片样式」只在「更优美的卡片」关闭时显示：
              // 开启「更优美的卡片」时二者自动关闭并隐藏。
              if (!this.beautifulCards) {
                CardSurface({ radius: HwRadius.card }) {
                  Row({ space: 12 }) {
                    Column({ space: 4 }) {
                      Text('卡片阴影描边')
                        .fontFamily(this.appFontFamily('卡片阴影描边'))
                        .fontWeight(this.appFontWeight())
                        .fontSize(15)
                        .fontColor(hwTextPrimary(this.isDarkMode))
                      Text('加投影和描边，更显眼')
                        .fontFamily(this.appFontFamily('加投影和描边，更显眼'))
                        .fontWeight(this.appFontWeight())
                        .fontSize(12)
                        .fontColor(hwTextSecondary(this.isDarkMode))
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    Toggle({ type: ToggleType.Switch, isOn: this.cardShadowBorder })
                      .selectedColor(this.accentOrPrimary())
                      .onChange((isOn: boolean) => {
                        this.setCardShadowBorder(isOn);
                      })
                  }
                  .width('100%')
                  .padding(HwSpace.lg)
                  .borderRadius(HwRadius.card)
                  .backgroundColor(Color.Transparent)
                  .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                  .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                  .clip(true)
                  .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
                }

                CardSurface({ radius: HwRadius.card }) {
                  Row({ space: 12 }) {
                    Column({ space: 4 }) {
                      Text('经典卡片样式')
                        .fontFamily(this.appFontFamily('经典卡片样式'))
                        .fontWeight(this.appFontWeight())
                        .fontSize(15)
                        .fontColor(hwTextPrimary(this.isDarkMode))
                      Text('恢复旧版玻璃样式')
                        .fontFamily(this.appFontFamily('恢复旧版玻璃样式'))
                        .fontWeight(this.appFontWeight())
                        .fontSize(12)
                        .fontColor(hwTextSecondary(this.isDarkMode))
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    Toggle({ type: ToggleType.Switch, isOn: this.classicCards })
                      .selectedColor(this.accentOrPrimary())
                      .onChange((isOn: boolean) => {
                        this.setClassicCards(isOn);
                      })
                  }
                  .width('100%')
                  .padding(HwSpace.lg)
                  .borderRadius(HwRadius.card)
                  .backgroundColor(Color.Transparent)
                  .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                  .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                  .clip(true)
                  .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
                }
              }

              // ==================== 深色模式（三态） ====================
              CardSurface({ radius: HwRadius.card }) {
                Column({ space: HwSpace.md }) {
                  Column({ space: 4 }) {
                    Text('外观模式')
                      .fontFamily(this.appFontFamily('外观模式'))
                      .fontWeight(this.appFontWeight())
                      .fontSize(15)
                      .fontColor(hwTextPrimary(this.isDarkMode))
                    Text('跟随系统时，系统切换深浅色应用会自动跟随')
                      .fontFamily(this.appFontFamily('跟随系统时，系统切换深浅色应用会自动跟随'))
                      .fontWeight(this.appFontWeight())
                      .fontSize(12)
                      .fontColor(hwTextSecondary(this.isDarkMode))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .width('100%')

                  Row({ space: HwSpace.sm }) {
                    this.darkModeChip(DARK_MODE_SYSTEM, '跟随系统')
                    this.darkModeChip(DARK_MODE_LIGHT, '浅色')
                    this.darkModeChip(DARK_MODE_DARK, '深色')
                  }
                  .width('100%')
                }
                .width('100%')
                .padding(HwSpace.lg)
                .borderRadius(HwRadius.card)
                .backgroundColor(Color.Transparent)
                .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                .clip(true)
                .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
              }

              // ==================== 主题色 ====================
              CardSurface({ radius: HwRadius.card }) {
                Column({ space: HwSpace.md }) {
                  Row({ space: 12 }) {
                    Column({ space: 4 }) {
                      Text('主题色')
                        .fontFamily(this.appFontFamily('主题色'))
                        .fontWeight(this.appFontWeight())
                        .fontSize(15)
                        .fontColor(hwTextPrimary(this.isDarkMode))
                      Text('影响开关、选中态、链接与高亮文字等全局配色')
                        .fontFamily(this.appFontFamily('影响开关、选中态、链接与高亮文字等全局配色'))
                        .fontWeight(this.appFontWeight())
                        .fontSize(12)
                        .fontColor(hwTextSecondary(this.isDarkMode))
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    Toggle({ type: ToggleType.Switch, isOn: this.themeColorEnabled })
                      .selectedColor(this.accentOrPrimary())
                      .onChange((isOn: boolean) => {
                        this.setThemeColorEnabled(isOn);
                      })
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)

                  if (!this.themeColorEnabled) {
                    // 关掉总开关后配色回到旧版，色块与延伸开关一起收起，
                    // 避免「选了没反应」的困惑；用户的选择仍然保留在存储里
                    Text('已关闭：配色回到默认样式，你选过的颜色会保留，重新打开即恢复')
                      .fontFamily(this.appFontFamily('已关闭：配色回到默认样式，你选过的颜色会保留，重新打开即恢复'))
                      .fontWeight(this.appFontWeight())
                      .fontSize(12)
                      .fontColor(hwTextSecondary(this.isDarkMode))
                      .width('100%')
                  } else {
                    // 色块统一走「材质承载层 + 自绘玻璃」：与页面卡片同一套沉浸光感载体。
                    // 换行排列——预设在前，用户新增的自定义色在后，末尾固定是「新增」按钮。
                    Flex({ wrap: FlexWrap.Wrap }) {
                      // key 必须带上选中态：ForEach 复用同 key 的项，键不变就不会重建子节点，
                      // 对号会一直停在上一个被点的色块上。
                      ForEach(ACCENT_PRESETS, (preset: AccentPreset) => {
                        this.accentSwatch(preset.key, preset.value, preset.label,
                          this.accentKey === preset.key, false)
                      }, (preset: AccentPreset) => `preset_${preset.key}_${this.accentKey === preset.key ? 1 : 0}_${this.accentColor}`)

                      // 自定义色只显示**昵称**（没起名字才回落色值），长按可编辑
                      ForEach(this.accentList, (entry: AccentCustom) => {
                        this.accentSwatch(entry.hex, `#${entry.hex}`, accentEntryLabel(entry),
                          this.isCustomSelected(entry.hex), true)
                      }, (entry: AccentCustom) =>
                      `custom_${entry.hex}_${entry.name}_${this.isCustomSelected(entry.hex) ? 1 : 0}_${this.accentColor}`)

                      this.addAccentSwatch()
                    }
                    .width('100%')
                  }
                }
                .width('100%')
                .padding(HwSpace.lg)
                .borderRadius(HwRadius.card)
                .backgroundColor(Color.Transparent)
                .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                .clip(true)
                .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
              }

              // ==================== 沉浸光感 ====================
              // 内容区布局容器（Column/Row）不在沉浸光感生效范围内，卡片统一改用
              // Toggle（ToggleType.Button）承载材质（见 components/CardSurface.ets）。
              CardSurface({ radius: HwRadius.card }) {
                Column({ space: HwSpace.md }) {
                  Row({ space: 12 }) {
                    Column({ space: 4 }) {
                      Text('全局沉浸光感')
                        .fontFamily(this.appFontFamily('全局沉浸光感'))
                        .fontWeight(this.appFontWeight())
                        .fontSize(15)
                        .fontColor(hwTextPrimary(this.isDarkMode))
                      Text('开启后使用沉浸光感材质，关闭后回退为毛玻璃效果')
                        .fontFamily(this.appFontFamily('开启后使用沉浸光感材质，关闭后回退为毛玻璃效果'))
                        .fontWeight(this.appFontWeight())
                        .fontSize(12)
                        .fontColor(hwTextSecondary(this.isDarkMode))
                      // 诊断行：把各段判定条件摊开，便于真机排查「为什么没生效」。
                      // 两个入参必须是订阅值，否则这行不会随切色/拨开关刷新。
                      if (this.immersiveLightEnabled && isApi26OrAbove()) {
                        Text(materialDiagnostics(this.pressGlowEnabled, this.accentColor))
                          .fontFamily('HarmonyOS Sans')
                          .fontWeight(this.appFontWeight())
                          .fontSize(11)
                          .fontColor(hwTextSecondary(this.isDarkMode))
                          .maxLines(2)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    Toggle({ type: ToggleType.Switch, isOn: this.immersiveLightEnabled })
                      .selectedColor(this.accentOrPrimary())
                      .onChange((isOn: boolean) => {
                        this.immersiveLightEnabled = isOn;
                        AppSettingsStore.setBoolean('immersiveLightEnabled', isOn);
                      })
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)

                  Divider()
                    .color(withAlpha(HwColor.textPrimary, 0.08))

                  Row({ space: 12 }) {
                    Column({ space: 4 }) {
                      Text('主题色流光')
                        .fontFamily(this.appFontFamily('主题色流光'))
                        .fontWeight(this.appFontWeight())
                        .fontSize(15)
                        .fontColor(hwTextPrimary(this.isDarkMode))
                      Text('按压流光与光晕改用主题色；关闭后为系统默认白光')
                        .fontFamily(this.appFontFamily('按压流光与光晕改用主题色；关闭后为系统默认白光'))
                        .fontWeight(this.appFontWeight())
                        .fontSize(12)
                        .fontColor(hwTextSecondary(this.isDarkMode))
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    Toggle({ type: ToggleType.Switch, isOn: this.pressGlowEnabled })
                      .selectedColor(this.accentOrPrimary())
                      .onChange((isOn: boolean) => {
                        this.setPressGlow(isOn);
                      })
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)

                  Divider()
                    .color(withAlpha(HwColor.textPrimary, 0.08))

                  Row({ space: 12 }) {
                    Column({ space: 4 }) {
                      Text('卡片流光触感')
                        .fontFamily(this.appFontFamily('卡片流光触感'))
                        .fontWeight(this.appFontWeight())
                        .fontSize(15)
                        .fontColor(hwTextPrimary(this.isDarkMode))
                      Text('开启后按压卡片才出现流光；关闭则按压卡片不出现任何光。不影响底部标签栏')
                        .fontFamily(this.appFontFamily('开启后按压卡片才出现流光；关闭则按压卡片不出现任何光。不影响底部标签栏'))
                        .fontWeight(this.appFontWeight())
                        .fontSize(12)
                        .fontColor(hwTextSecondary(this.isDarkMode))
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    Toggle({ type: ToggleType.Switch, isOn: this.cardGlowTouch })
                      .selectedColor(this.accentOrPrimary())
                      .onChange((isOn: boolean) => {
                        this.setCardGlowTouch(isOn);
                      })
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)
                }
                .width('100%')
                .padding(HwSpace.lg)
                .borderRadius(HwRadius.card)
                .backgroundColor(Color.Transparent)
                .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                .clip(true)
                .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
              }

              // ==================== 主题色的延伸选项 ====================
              // 两个开关都只改主题色派生出来的 token，所以主题色关闭时一并收起
              if (this.themeColorEnabled) {
                CardSurface({ radius: HwRadius.card }) {
                  Column({ space: HwSpace.md }) {
                    Row({ space: 12 }) {
                      Column({ space: 4 }) {
                        Text('卡片沾色')
                          .fontFamily(this.appFontFamily('卡片沾色'))
                          .fontWeight(this.appFontWeight())
                          .fontSize(15)
                          .fontColor(hwTextPrimary(this.isDarkMode))
                        Text('开启后所有卡片叠一层 10% 主题色')
                          .fontFamily(this.appFontFamily('开启后所有卡片叠一层 10% 主题色'))
                          .fontWeight(this.appFontWeight())
                          .fontSize(12)
                          .fontColor(hwTextSecondary(this.isDarkMode))
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      Toggle({ type: ToggleType.Switch, isOn: this.cardTintEnabled })
                        .selectedColor(this.accentOrPrimary())
                        .onChange((isOn: boolean) => {
                          this.setCardTint(isOn);
                        })
                    }
                    .width('100%')
                    .alignItems(VerticalAlign.Center)

                    Divider()
                      .color(withAlpha(HwColor.textPrimary, 0.08))

                    Row({ space: 12 }) {
                      Column({ space: 4 }) {
                        Text('高权限自定义主题色')
                          .fontFamily(this.appFontFamily('高权限自定义主题色'))
                          .fontWeight(this.appFontWeight())
                          .fontSize(15)
                          .fontColor(hwTextPrimary(this.isDarkMode))
                        Text('默认只有内置主题色会染到页面背景；开启后自定义颜色也会')
                          .fontFamily(this.appFontFamily('默认只有内置主题色会染到页面背景；开启后自定义颜色也会'))
                          .fontWeight(this.appFontWeight())
                          .fontSize(12)
                          .fontColor(hwTextSecondary(this.isDarkMode))
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      Toggle({ type: ToggleType.Switch, isOn: this.customAccentFullAccess })
                        .selectedColor(this.accentOrPrimary())
                        .onChange((isOn: boolean) => {
                          this.setCustomAccentFullAccess(isOn);
                        })
                    }
                    .width('100%')
                    .alignItems(VerticalAlign.Center)
                  }
                  .width('100%')
                  .padding(HwSpace.lg)
                  .borderRadius(HwRadius.card)
                  .backgroundColor(Color.Transparent)
                  .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                  .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                  .clip(true)
                  .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
                }
              }

              CardSurface({ radius: HwRadius.card }) {
                Row({ space: 12 }) {
                  Column({ space: 4 }) {
                    Text('所有页面卡片从顶部开始排列')
                      .fontFamily(this.appFontFamily('所有页面卡片从顶部开始排列'))
                      .fontWeight(this.appFontWeight())
                      .fontSize(15)
                      .fontColor(hwTextPrimary(this.isDarkMode))
                    Text('首页三个页面内容从顶部开始排列，自动避让顶部标题栏')
                      .fontFamily(this.appFontFamily('首页三个页面内容从顶部开始排列，自动避让顶部标题栏'))
                      .fontWeight(this.appFontWeight())
                      .fontSize(12)
                      .fontColor(hwTextSecondary(this.isDarkMode))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.cardsFromTop })
                    .selectedColor(this.accentOrPrimary())
                    .onChange((isOn: boolean) => {
                      this.setCardsFromTop(isOn);
                    })
                }
                .width('100%')
                .padding(HwSpace.lg)
                .borderRadius(HwRadius.card)
                .backgroundColor(Color.Transparent)
                .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                .clip(true)
                .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
              }

              CardSurface({ radius: HwRadius.card }) {
                Row({ space: 12 }) {
                  Column({ space: 4 }) {
                    Text('更换字体')
                      .fontFamily(this.appFontFamily('更换字体'))
                      .fontWeight(this.appFontWeight())
                      .fontSize(15)
                      .fontColor(hwTextPrimary(this.isDarkMode))
                    Text(this.fontMode === 'custom' ? '自定义字体' : '跟随系统')
                      .fontFamily(this.appFontFamily(this.fontMode === 'custom' ? '自定义字体' : '跟随系统'))
                      .fontWeight(this.appFontWeight())
                      .fontSize(12)
                      .fontColor(hwTextSecondary(this.isDarkMode))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(16)
                    .fontColor([hwTextSecondary(this.isDarkMode)])
                }
                .width('100%')
                .padding(HwSpace.lg)
                .borderRadius(HwRadius.card)
                .backgroundColor(Color.Transparent)
                .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                .clip(true)
                .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
                .bindMenu(this.fontModeMenu(), { systemMaterial: menuSystemMaterial() })
              }

              if (this.fontMode === 'custom') {
                CardSurface({ radius: HwRadius.card }) {
                  Row({ space: 12 }) {
                    Column({ space: 4 }) {
                      Text('显示系统字体')
                        .fontFamily(this.appFontFamily('显示系统字体'))
                        .fontWeight(this.appFontWeight())
                        .fontSize(15)
                        .fontColor(hwTextPrimary(this.isDarkMode))
                      Text('开启后在字体列表中选择系统字体')
                        .fontFamily(this.appFontFamily('开启后在字体列表中选择系统字体'))
                        .fontWeight(this.appFontWeight())
                        .fontSize(12)
                        .fontColor(hwTextSecondary(this.isDarkMode))
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    Toggle({ type: ToggleType.Switch, isOn: this.showSystemFonts })
                      .selectedColor(this.accentOrPrimary())
                      .onChange((isOn: boolean) => {
                        this.showSystemFonts = isOn;
                      })
                  }
                  .width('100%')
                  .padding(HwSpace.lg)
                  .borderRadius(HwRadius.card)
                  .backgroundColor(Color.Transparent)
                  .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                  .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                  .clip(true)
                  .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
                }

                CardSurface({ radius: HwRadius.card }) {
                  Row({ space: 12 }) {
                    Column({ space: 4 }) {
                      Text('英文/数字字体')
                        .fontFamily(this.appFontFamily('英文/数字字体'))
                        .fontWeight(this.appFontWeight())
                        .fontSize(15)
                        .fontColor(hwTextPrimary(this.isDarkMode))
                      Text(this.fontFamilyEn === 'system' ? '跟随系统' : this.fontFamilyEn)
                        .fontFamily(this.appFontFamily(this.fontFamilyEn === 'system' ? '跟随系统' : this.fontFamilyEn))
                        .fontWeight(this.appFontWeight())
                        .fontSize(12)
                        .fontColor(hwTextSecondary(this.isDarkMode))
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    SymbolGlyph($r('sys.symbol.chevron_right'))
                      .fontSize(16)
                      .fontColor([hwTextSecondary(this.isDarkMode)])
                  }
                  .width('100%')
                  .padding(HwSpace.lg)
                  .borderRadius(HwRadius.card)
                  .backgroundColor(Color.Transparent)
                  .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                  .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                  .clip(true)
                  .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
                  .bindMenu(this.fontFamilyMenu(true), { systemMaterial: menuSystemMaterial() })
                }

                CardSurface({ radius: HwRadius.card }) {
                  Row({ space: 12 }) {
                    Column({ space: 4 }) {
                      Text('中文字体')
                        .fontFamily(this.appFontFamily('中文字体'))
                        .fontWeight(this.appFontWeight())
                        .fontSize(15)
                        .fontColor(hwTextPrimary(this.isDarkMode))
                      Text(this.fontFamilyZh === 'system' ? '跟随系统' : this.fontFamilyZh)
                        .fontFamily(this.appFontFamily(this.fontFamilyZh === 'system' ? '跟随系统' : this.fontFamilyZh))
                        .fontWeight(this.appFontWeight())
                        .fontSize(12)
                        .fontColor(hwTextSecondary(this.isDarkMode))
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    SymbolGlyph($r('sys.symbol.chevron_right'))
                      .fontSize(16)
                      .fontColor([hwTextSecondary(this.isDarkMode)])
                  }
                  .width('100%')
                  .padding(HwSpace.lg)
                  .borderRadius(HwRadius.card)
                  .backgroundColor(Color.Transparent)
                  .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                  .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                  .clip(true)
                  .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
                  .bindMenu(this.fontFamilyMenu(false), { systemMaterial: menuSystemMaterial() })
                }
              }

              if (this.fontMode === 'custom') {
                CardSurface({ radius: HwRadius.card }) {
                  Row({ space: 12 }) {
                    Column({ space: 4 }) {
                      Text('上传字体')
                        .fontFamily(this.appFontFamily('上传字体'))
                        .fontWeight(this.appFontWeight())
                        .fontSize(15)
                        .fontColor(hwTextPrimary(this.isDarkMode))
                      Text(`支持 ttf / otf，已上传 ${this.customFonts.length} 个`)
                        .fontFamily(this.appFontFamily(`支持 ttf / otf，已上传 ${this.customFonts.length} 个`))
                        .fontWeight(this.appFontWeight())
                        .fontSize(12)
                        .fontColor(hwTextSecondary(this.isDarkMode))
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    SymbolGlyph($r('sys.symbol.plus'))
                      .fontSize(18)
                      .fontColor([resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary())])
                  }
                  .width('100%')
                  .padding(HwSpace.lg)
                  .borderRadius(HwRadius.card)
                  .backgroundColor(Color.Transparent)
                  .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                  .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                  .clip(true)
                  .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
                  .onClick(() => {
                    this.uploadFont();
                  })
                }
              }

              if (this.customFonts.length > 0) {
                CardSurface({ radius: HwRadius.card }) {
                  Row({ space: 12 }) {
                    Column({ space: 4 }) {
                      Text('管理字体')
                        .fontFamily(this.appFontFamily('管理字体'))
                        .fontWeight(this.appFontWeight())
                        .fontSize(15)
                        .fontColor(hwTextPrimary(this.isDarkMode))
                      Text(`改名、删除已上传的 ${this.customFonts.length} 个字体`)
                        .fontFamily(this.appFontFamily(`改名、删除已上传的 ${this.customFonts.length} 个字体`))
                        .fontWeight(this.appFontWeight())
                        .fontSize(12)
                        .fontColor(hwTextSecondary(this.isDarkMode))
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    SymbolGlyph($r('sys.symbol.chevron_right'))
                      .fontSize(16)
                      .fontColor([hwTextSecondary(this.isDarkMode)])
                  }
                  .width('100%')
                  .padding(HwSpace.lg)
                  .borderRadius(HwRadius.card)
                  .backgroundColor(Color.Transparent)
                  .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                  .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                  .clip(true)
                  .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
                  .onClick(() => {
                    router.pushUrl({ url: 'pages/FontManagePage' });
                  })
                }
              }

              CardSurface({ radius: HwRadius.card }) {
                Row({ space: 12 }) {
                  Column({ space: 4 }) {
                    Text('字体大小')
                      .fontFamily(this.appFontFamily('字体大小'))
                      .fontWeight(this.appFontWeight())
                      .fontSize(15)
                      .fontColor(hwTextPrimary(this.isDarkMode))
                    Text(this.fontSizeMode === 'custom' ? `自定义(${this.fontSizeValue})` : '跟随系统')
                      .fontFamily(this.appFontFamily(this.fontSizeMode === 'custom' ? `自定义(${this.fontSizeValue})` : '跟随系统'))
                      .fontWeight(this.appFontWeight())
                      .fontSize(12)
                      .fontColor(hwTextSecondary(this.isDarkMode))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(16)
                    .fontColor([hwTextSecondary(this.isDarkMode)])
                }
                .width('100%')
                .padding(HwSpace.lg)
                .borderRadius(HwRadius.card)
                .backgroundColor(Color.Transparent)
                .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                .clip(true)
                .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
                .bindMenu(this.fontSizeModeMenu(), { systemMaterial: menuSystemMaterial() })
              }

              if (this.fontSizeMode === 'custom') {
                CardSurface({ radius: HwRadius.card }) {
                  Row({ space: 12 }) {
                    Text('字体大小')
                      .fontFamily(this.appFontFamily('字体大小'))
                      .fontWeight(this.appFontWeight())
                      .fontSize(15)
                      .fontColor(hwTextPrimary(this.isDarkMode))
                    Slider({
                      value: this.fontSizeValue,
                      min: 12,
                      max: 28,
                      step: 1,
                      style: SliderStyle.OutSet
                    })
                      .selectedColor(this.accentOrPrimary())
                      .trackColor('#1A000000')
                      .blockColor(Color.White)
                      .layoutWeight(1)
                      .showSteps(true)
                      .onChange((value: number) => {
                        this.onFontSizeChange(value);
                      })
                    Text(`${this.fontSizeValue}`)
                      .fontFamily(this.appFontFamily(`${this.fontSizeValue}`))
                      .fontWeight(this.appFontWeight())
                      .fontSize(14)
                      .fontColor(hwTextSecondary(this.isDarkMode))
                  }
                  .width('100%')
                  .padding(HwSpace.lg)
                  .borderRadius(HwRadius.card)
                  .backgroundColor(Color.Transparent)
                  .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                  .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                  .clip(true)
                  .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
                }
              }

              CardSurface({ radius: HwRadius.card }) {
                Row({ space: 12 }) {
                  Column({ space: 4 }) {
                    Text('字体粗细')
                      .fontFamily(this.appFontFamily('字体粗细'))
                      .fontWeight(this.appFontWeight())
                      .fontSize(15)
                      .fontColor(hwTextPrimary(this.isDarkMode))
                    Text(this.fontWeightMode === 'custom' ? `自定义(${this.fontWeightValue})` : '跟随系统')
                      .fontFamily(this.appFontFamily(this.fontWeightMode === 'custom' ? `自定义(${this.fontWeightValue})` : '跟随系统'))
                      .fontWeight(this.appFontWeight())
                      .fontSize(12)
                      .fontColor(hwTextSecondary(this.isDarkMode))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(16)
                    .fontColor([hwTextSecondary(this.isDarkMode)])
                }
                .width('100%')
                .padding(HwSpace.lg)
                .borderRadius(HwRadius.card)
                .backgroundColor(Color.Transparent)
                .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                .clip(true)
                .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
                .bindMenu(this.fontWeightModeMenu(), { systemMaterial: menuSystemMaterial() })
              }

              if (this.fontWeightMode === 'custom') {
                CardSurface({ radius: HwRadius.card }) {
                  Row({ space: 12 }) {
                    Text('字体粗细')
                      .fontFamily(this.appFontFamily('字体粗细'))
                      .fontWeight(this.appFontWeight())
                      .fontSize(15)
                      .fontColor(hwTextPrimary(this.isDarkMode))
                    Slider({
                      value: this.fontWeightValue,
                      min: 100,
                      max: 900,
                      step: 100,
                      style: SliderStyle.OutSet
                    })
                      .selectedColor(this.accentOrPrimary())
                      .trackColor('#1A000000')
                      .blockColor(Color.White)
                      .layoutWeight(1)
                      .showSteps(true)
                      .onChange((value: number) => {
                        this.onFontWeightChange(value);
                      })
                    Text(`${this.fontWeightValue}`)
                      .fontFamily(this.appFontFamily(`${this.fontWeightValue}`))
                      .fontWeight(this.appFontWeight())
                      .fontSize(14)
                      .fontColor(hwTextSecondary(this.isDarkMode))
                  }
                  .width('100%')
                  .padding(HwSpace.lg)
                  .borderRadius(HwRadius.card)
                  .backgroundColor(Color.Transparent)
                  .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                  .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                  .clip(true)
                  .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
                }
              }

              CardSurface({ radius: HwRadius.card }) {
                Row({ space: 12 }) {
                  Column({ space: 4 }) {
                    Text('更换背景')
                      .fontFamily(this.appFontFamily('更换背景'))
                      .fontWeight(this.appFontWeight())
                      .fontSize(15)
                      .fontColor(hwTextPrimary(this.isDarkMode))
                    Text(this.wallpaperImage.length > 0 ? '已设置背景' : '未设置背景')
                      .fontFamily(this.appFontFamily(this.wallpaperImage.length > 0 ? '已设置背景' : '未设置背景'))
                      .fontWeight(this.appFontWeight())
                      .fontSize(12)
                      .fontColor(hwTextSecondary(this.isDarkMode))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  SymbolGlyph($r('sys.symbol.picture'))
                    .fontSize(18)
                    .fontColor([hwTextSecondary(this.isDarkMode)])
                }
                .width('100%')
                .padding(HwSpace.lg)
                .borderRadius(HwRadius.card)
                .backgroundColor(Color.Transparent)
                .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                .clip(true)
                .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
                .onClick(() => {
                  this.pickBackgroundImage();
                })
              }

              CardSurface({ radius: HwRadius.card }) {
                Row({ space: 12 }) {
                  Text('清空背景')
                    .fontFamily(this.appFontFamily('清空背景'))
                    .fontWeight(this.appFontWeight())
                    .fontSize(15)
                    .fontColor(hwDanger(this.isDarkMode))
                    .layoutWeight(1)
                  SymbolGlyph($r('sys.symbol.trash'))
                    .fontSize(18)
                    .fontColor([hwDanger(this.isDarkMode)])
                }
                .width('100%')
                .padding(HwSpace.lg)
                .borderRadius(HwRadius.card)
                .backgroundColor(Color.Transparent)
                .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
                .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
                .clip(true)
                .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
                .onClick(() => {
                  this.showClearBackgroundDialog();
                })
              }
            }
            .width('100%')
            .padding({ left: HwSpace.lg, right: HwSpace.lg, top: HwSpace.lg, bottom: HwSpace.xl })
          }
          .width('100%')
        }
        .width('100%')
        .height('100%')
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)

      Row() {
        IconCircleButton({
          symbol: $r('sys.symbol.chevron_left'),
          glass: true,
          buttonSize: 40,
          iconSize: 20,
          onAction: () => {
            router.back();
          }
        })
        Text('外观设置')
          .fontFamily(this.appFontFamily('外观设置'))
          .fontWeight(this.appFontWeight())
          .margin({ left: HwSpace.md })
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(hwTextPrimary(this.isDarkMode))
        Blank()
      }
      .width('100%')
      .height(56 + this.statusBarHeight)
      .padding({ left: 16, right: 16, top: this.statusBarHeight })
      .backgroundEffect({ radius: 12, color: topBarGlassColor(this.isDarkMode) })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(resolvePageBackground(this.isDarkMode, this.pageBackground))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .keyboardShortcut(FunctionKey.ESC, [], () => {
      router.back();
    })
  }
}