import { AbilityConstant, common, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { window, uiAppearance } from '@kit.ArkUI';
import { AppSettingsStore } from '../storage/AppSettingsStore';
import { SettingsStore, LinkSettings } from '../common/SettingsStore';
import { loadCustomFonts } from '../utils/CustomFonts';
import { handleSharedWant } from '../common/ShareHandleUtil';
import { NearbyScanHub } from '../common/NearbyScanHub';
import { MtaService } from '../mta/MtaService';
import { AppServices } from '../common/AppServices';
import { LogCapture as Lg } from '../common/LogCapture';
import { PendingDynamicPhotoStore } from '../common/DynamicPhotoStore';
import { GalleryAuthorizationSession } from '../quickshare/service/GalleryAuthorizationSession';
import { GalleryAuthorizationRequest } from '../quickshare/service/GalleryAuthorizationRequest';
import { GalleryAuthorizationDialogHost } from '../components/GalleryAutoSaveDialog';
import { ACCENT_COLOR_KEY, ACCENT_CUSTOM_STORAGE, ACCENT_KEY_STORAGE, applyAppTheme, CARD_GLOW_TOUCH_STORAGE, CARD_TINT_STORAGE, CUSTOM_ACCENT_FULL_ACCESS_STORAGE, DARK_MODE_DARK, DARK_MODE_KEY, DARK_MODE_LIGHT, DARK_MODE_PREF_STORAGE, DARK_MODE_SYSTEM, DEFAULT_ACCENT_KEY, isPresetAccentKey, PRESS_GLOW_STORAGE, resolveAccentColor, THEME_COLOR_ENABLED_STORAGE, effectiveAccentColor } from '../utils/DesignTokens';

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 尽早初始化应用内日志采集，让后续所有 Lg.* 调用都能落盘。
    try {
      Lg.init(this.context);
    } catch (err) {
    }
    Lg.i('APP', 'EntryAbility.onCreate bundle=' + this.context.abilityInfo.bundleName);
    handleSharedWant(want);
    try {
      AppSettingsStore.init(this.context);
    } catch (err) {
    }
    // 临时图库授权只存在当前进程；Ability 重建时也必须从“未授权”开始。
    GalleryAuthorizationSession.resetForAppStart();
    // 深色模式偏好（三态：跟随系统 / 浅色 / 深色）：必须在首屏渲染前解析出来，
    // 并把平台配色一起下发——setColorMode() 管系统控件（弹窗、输入法、滚动条），
    // applyAppTheme() 管自绘颜色，只做后者会出现「自绘是浅色、系统弹窗是深色」的错配。
    // ⚠️ 必须放在 AppSettingsStore.init() 之后：偏好是从 preferences 里读的。
    const darkModePref = EntryAbility.resolveDarkModePref();
    AppStorage.setOrCreate(DARK_MODE_PREF_STORAGE, darkModePref);
    try {
      this.context.getApplicationContext().setColorMode(EntryAbility.resolveColorMode(darkModePref));
    } catch (err) {
    }
    // 提前加载连接/传输设置：接收侧可能在 startReceive 完成前就收到文件，
    // 而「动态图片传输(Beta)」等开关的判定依赖 SettingsStore 已加载（否则会读到默认值）。
    AppStorage.setOrCreate('saveReceivedMediaToGallery', false);
    SettingsStore.load(this.context).then((settings: LinkSettings): void => {
      AppStorage.setOrCreate('dynamicPhotoEnabled', settings.dynamicPhotoEnabled === true);
      AppStorage.setOrCreate('defaultLivePhotoFormat',
        settings.defaultLivePhotoFormat !== undefined && settings.defaultLivePhotoFormat.length > 0
          ? settings.defaultLivePhotoFormat
          : 'android');
      AppStorage.setOrCreate('hdrVividEnabled', settings.hdrVividEnabled === true);
      AppStorage.setOrCreate('photoExifKeep', settings.photoExifKeep !== false);
      AppStorage.setOrCreate('hdrSkipSystemReencode', settings.hdrSkipSystemReencode === true);
      AppStorage.setOrCreate('skipDownloadCopyForGalleryPhotos',
        settings.skipDownloadCopyForGalleryPhotos === true);
      AppStorage.setOrCreate('saveReceivedMediaToGallery',
        settings.saveReceivedMediaToGallery === true);
      Lg.i('APP', 'SettingsStore loaded dynamicPhotoEnabled=' + (settings.dynamicPhotoEnabled === true)
        + ' defaultLivePhotoFormat=' + (settings.defaultLivePhotoFormat ?? 'android')
        + ' hdrVividEnabled=' + (settings.hdrVividEnabled === true)
        + ' photoExifKeep=' + (settings.photoExifKeep !== false));
    }).catch((err: Error): void => {
      Lg.w('羊绒互传 SettingsStore preload failed: ' + err.message);
    });
    // 待保存的动态照片登记表：落库需要用户点一次 SaveButton，重启后必须还能看到那条记录。
    try {
      PendingDynamicPhotoStore.load(this.context);
    } catch (err) {
      Lg.w('羊绒互传 pending dynamic photo restore failed');
    }
    // 外观设置：字体、字号、字重、背景图、卡片排列、沉浸光感。
    const backgroundImage = AppSettingsStore.getString('backgroundImage', '');
    const fontMode = AppSettingsStore.getString('fontMode', 'system');
    const fontFamilyEn = AppSettingsStore.getString('fontFamilyEn', 'system');
    const fontFamilyZh = AppSettingsStore.getString('fontFamilyZh', 'system');
    const fontSizeMode = AppSettingsStore.getString('fontSizeMode', 'system');
    const fontSizeValue = AppSettingsStore.getNumber('fontSizeValue', 16);
    const fontWeightMode = AppSettingsStore.getString('fontWeightMode', 'system');
    const fontWeightValue = AppSettingsStore.getNumber('fontWeightValue', 400);
    const immersiveLightEnabled = AppSettingsStore.getBoolean('immersiveLightEnabled', true);
    // 「更优美的卡片」默认关闭：检测到已设置背景图且用户未主动改过开关时自动打开。
    const beautifulCardsUserSet = AppSettingsStore.getBoolean('beautifulCardsUserSet', false);
    const beautifulCards = beautifulCardsUserSet
      ? AppSettingsStore.getBoolean('beautifulCards', false)
      : backgroundImage.length > 0;
    // 卡片外观：阴影描边（默认开）、经典卡片样式（默认关）。
    const cardShadowBorder = AppSettingsStore.getBoolean('cardShadowBorder', true);
    const classicCards = AppSettingsStore.getBoolean('classicCards', false);
    // 兼容键：「沉浸光感卡片（实验性）」已并入「全局沉浸光感」（卡片改用 Toggle 承载层，
    // 见 components/CardSurface.ets），旧键保留读取以免老用户的开关值丢失，但不再参与判定。
    const experimentalCards = AppSettingsStore.getBoolean('experimentalCards', false);
    const cardsFromTop = AppSettingsStore.getBoolean('cardsFromTop', true);
    const customFonts = AppSettingsStore.getStringArray('customFonts', []);
    // 主题色的两个延伸开关必须在 applyAppTheme 之前落进 AppStorage：
    // applyAppTheme 会读它们来决定卡片沾色层与页面背景是否跟随主题色。
    const cardTintEnabled = AppSettingsStore.getBoolean(CARD_TINT_STORAGE, false);
    const customAccentFullAccess = AppSettingsStore.getBoolean(CUSTOM_ACCENT_FULL_ACCESS_STORAGE, false);
    // 「主题色」总开关（默认开）：关闭后 applyAppTheme 走旧版配色那一支
    const themeColorEnabled = AppSettingsStore.getBoolean(THEME_COLOR_ENABLED_STORAGE, true);
    const pressGlow = AppSettingsStore.getBoolean(PRESS_GLOW_STORAGE, true);
    const cardGlowTouch = AppSettingsStore.getBoolean(CARD_GLOW_TOUCH_STORAGE, false);
    AppStorage.setOrCreate('backgroundImage', backgroundImage);
    AppStorage.setOrCreate('fontMode', fontMode);
    AppStorage.setOrCreate('fontFamilyEn', fontFamilyEn);
    AppStorage.setOrCreate('fontFamilyZh', fontFamilyZh);
    AppStorage.setOrCreate('fontSizeMode', fontSizeMode);
    AppStorage.setOrCreate('fontSizeValue', fontSizeValue);
    AppStorage.setOrCreate('fontWeightMode', fontWeightMode);
    AppStorage.setOrCreate('fontWeightValue', fontWeightValue);
    AppStorage.setOrCreate('immersiveLightEnabled', immersiveLightEnabled);
    AppStorage.setOrCreate('beautifulCards', beautifulCards);
    AppStorage.setOrCreate('cardShadowBorder', cardShadowBorder);
    AppStorage.setOrCreate('classicCards', classicCards);
    AppStorage.setOrCreate('experimentalCards', experimentalCards);
    AppStorage.setOrCreate('cardsFromTop', cardsFromTop);
    AppStorage.setOrCreate('customFonts', customFonts);
    AppStorage.setOrCreate(CARD_TINT_STORAGE, cardTintEnabled);
    AppStorage.setOrCreate(CUSTOM_ACCENT_FULL_ACCESS_STORAGE, customAccentFullAccess);
    AppStorage.setOrCreate(THEME_COLOR_ENABLED_STORAGE, themeColorEnabled);
    AppStorage.setOrCreate(PRESS_GLOW_STORAGE, pressGlow);
    AppStorage.setOrCreate(CARD_GLOW_TOUCH_STORAGE, cardGlowTouch);
    // 应用全局字号缩放。
    try {
      let fontSizeScale: number = 1;
      if (fontSizeMode === 'custom') {
        fontSizeScale = fontSizeValue / 16;
      } else {
        try {
          fontSizeScale = uiAppearance.getFontScale();
        } catch (err) {
          fontSizeScale = 1;
        }
      }
      this.context.getApplicationContext().setFontSizeScale(fontSizeScale);
    } catch (err) {
    }
    // 深色模式的实际取值：偏好为「跟随系统」时读系统，其余按偏好。
    const darkModeEnabled = EntryAbility.resolveDarkMode(this.context, darkModePref);
    AppStorage.setOrCreate(DARK_MODE_KEY, darkModeEnabled);
    // 主题色：持久化键要先建好（页面的 @StorageLink 才有初值），
    // 解析出颜色后写 accentColor 并调 applyAppTheme——不在这里做的话首屏会用默认蓝，
    // 切到别的页面才变色。
    const accentKey = EntryAbility.resolveAccentKey();
    const accentCustom = AppSettingsStore.getString(ACCENT_CUSTOM_STORAGE, '');
    const accentColor = effectiveAccentColor(accentKey, accentCustom);
    AppStorage.setOrCreate(ACCENT_KEY_STORAGE, accentKey);
    AppStorage.setOrCreate(ACCENT_CUSTOM_STORAGE, accentCustom);
    AppStorage.setOrCreate(ACCENT_COLOR_KEY, accentColor);
    applyAppTheme(darkModeEnabled, accentColor);
    Lg.i('APP', 'theme applied accent=' + accentColor + ' key=' + accentKey
      + ' darkPref=' + darkModePref + ' dark=' + darkModeEnabled
      + ' cardTint=' + cardTintEnabled + ' fullAccess=' + customAccentFullAccess
      + ' pressGlow=' + pressGlow + ' cardGlowTouch=' + cardGlowTouch);
  }

  /**
   * 读主题色设置里的 key，顺带兜底：
   * 旧版本或异常写入可能留下一个已经不存在的预设 key，这时回落默认预设并写回存储。
   */
  private static resolveAccentKey(): string {
    const stored = AppSettingsStore.getString(ACCENT_KEY_STORAGE, DEFAULT_ACCENT_KEY);
    if (stored === 'custom' || isPresetAccentKey(stored)) {
      return stored;
    }
    AppSettingsStore.setString(ACCENT_KEY_STORAGE, DEFAULT_ACCENT_KEY);
    return DEFAULT_ACCENT_KEY;
  }

  /**
   * 读深色模式偏好，顺带把旧布尔键迁移成三态字符串。
   *
   * 旧版本只有一个布尔 `isDarkMode`（且它是从系统配置算出来的，不是用户偏好），
   * 这里不做迁移：没有偏好记录时一律「跟随系统」，行为与改动前一致。
   */
  private static resolveDarkModePref(): string {
    try {
      const stored = AppSettingsStore.getString(DARK_MODE_PREF_STORAGE, '');
      if (stored === DARK_MODE_SYSTEM || stored === DARK_MODE_LIGHT || stored === DARK_MODE_DARK) {
        return stored;
      }
    } catch (err) {
    }
    return DARK_MODE_SYSTEM;
  }

  /** 偏好为「跟随系统」时读系统，其余按偏好取值 */
  private static resolveDarkMode(context: common.UIAbilityContext, pref: string): boolean {
    if (pref === DARK_MODE_DARK) {
      return true;
    }
    if (pref === DARK_MODE_LIGHT) {
      return false;
    }
    return EntryAbility.systemDarkMode(context);
  }

  /** 读系统当前的深色模式 */
  private static systemDarkMode(context: common.UIAbilityContext): boolean {
    try {
      const config = context.getApplicationContext().resourceManager.getConfigurationSync();
      return config.colorMode === resourceManager.ColorMode.DARK;
    } catch (err) {
      return false;
    }
  }

  /**
   * 跟随系统时下发 NOT_SET 把配色权交还系统；选了明确值才固定。
   * 只要下发过 COLOR_MODE_DARK / COLOR_MODE_LIGHT，系统再切深浅色应用也不会跟。
   */
  private static resolveColorMode(pref: string): ConfigurationConstant.ColorMode {
    if (pref === DARK_MODE_DARK) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    if (pref === DARK_MODE_LIGHT) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  }

  onDestroy(): void {
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    try {
      const customFonts = AppStorage.get<string[]>('customFonts') as string[];
      loadCustomFonts(this.context.filesDir, customFonts);
    } catch (err) {
    }
    const isDarkMode: boolean = AppStorage.get<boolean>('isDarkMode') === true;
    // 状态栏/导航栏内容色随深浅模式切换：深色模式用浅色文字(接近白)，浅色模式用深色文字。
    // 背景保持透明，由页面通过 expandSafeArea 顶到状态栏并自行铺色。
    const statusContentColor: string = isDarkMode ? '#F0F2F5' : '#182431';
    const mainWindow = windowStage.getMainWindowSync();
    this.mainWindow = mainWindow;
    mainWindow.setWindowLayoutFullScreen(true).catch((err: Error) => {
      Lg.e(`羊绒互传 setWindowLayoutFullScreen failed: ${err.message}`);
    });
    mainWindow.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000',
      statusBarContentColor: statusContentColor,
      navigationBarContentColor: statusContentColor
    }).catch((err: Error) => {
      Lg.e(`羊绒互传 setWindowSystemBarProperties failed: ${err.message}`);
    });
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        Lg.e(`羊绒互传 load failed: ${JSON.stringify(err)}`);
        return;
      }
      this.publishWindowInsets(mainWindow);
      GalleryAuthorizationRequest.configure(
        (): Promise<boolean> => GalleryAuthorizationDialogHost.show(mainWindow.getUIContext()),
        (): void => GalleryAuthorizationDialogHost.dismiss());
      mainWindow.on('avoidAreaChange', (data: window.AvoidAreaOptions): void => {
        this.publishWindowInsets(mainWindow);
      });
    });
    // 全局三协议接收扫描：Quick Share / Windows Nearby / LocalSend 的发现与可发现性
    // 在应用进程生命周期内常开（聚合页等任意位置均可接收），三个独立页面逻辑保持不变。
    try {
      NearbyScanHub.get(this.context).start();
    } catch (err) {
      Lg.w(`羊绒互传 NearbyScanHub start failed: ${JSON.stringify(err)}`);
    }
  }

  private publishWindowInsets(win: window.Window): void {
    try {
      const uiContext = win.getUIContext();
      const systemArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const navArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const statusBarHeight = uiContext.px2vp(systemArea.topRect.height);
      const navigationBarHeight = Math.max(
        uiContext.px2vp(systemArea.bottomRect.height),
        uiContext.px2vp(navArea.bottomRect.height)
      );
      AppStorage.setOrCreate('statusBarHeight', statusBarHeight);
      AppStorage.setOrCreate('navigationBarHeight', navigationBarHeight);
    } catch (err) {
      Lg.w('羊绒互传 publishWindowInsets failed');
    }
  }

  onWindowStageDestroy(): void {
    GalleryAuthorizationRequest.configure();
    if (this.mainWindow !== null) {
      // 窗口销毁后对旧引用调 off 会抛 1300002（window is not created or destroyed），
      // 且监听器随窗口销毁自动释放，这里加防御避免未捕获异常导致进程被杀。
      try {
        this.mainWindow.off('avoidAreaChange');
      } catch (err) {
        Lg.w('羊绒互传 off avoidAreaChange failed on destroyed window: ' + JSON.stringify(err));
      }
      this.mainWindow = null;
    }
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    handleSharedWant(want);
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    // ⚠️ 这个回调会被 setColorMode() **同步**触发，所以它内部不能再调 setColorMode()，否则自激。
    // 用户选了明确偏好时以偏好为准；只有「跟随系统」才吃系统下发的配置。
    let pref: string = DARK_MODE_SYSTEM;
    try {
      const stored = AppStorage.get<string>(DARK_MODE_PREF_STORAGE);
      if (stored !== undefined && stored.length > 0) {
        pref = stored;
      }
    } catch (err) {
      pref = DARK_MODE_SYSTEM;
    }
    const systemDark: boolean = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    const isDarkMode: boolean = pref === DARK_MODE_DARK ? true : (pref === DARK_MODE_LIGHT ? false : systemDark);
    AppStorage.setOrCreate(DARK_MODE_KEY, isDarkMode);
    // 深色联动必须把**已保存的主题色**一起传进去：只传 isDark 会把背景染色重置回默认色。
    try {
      const accentColor = effectiveAccentColor(
        AppSettingsStore.getString(ACCENT_KEY_STORAGE, DEFAULT_ACCENT_KEY),
        AppSettingsStore.getString(ACCENT_CUSTOM_STORAGE, ''));
      applyAppTheme(isDarkMode, accentColor);
      AppStorage.setOrCreate(ACCENT_COLOR_KEY, accentColor);
    } catch (err) {
      applyAppTheme(isDarkMode);
    }
    // 主题切换后同步刷新状态栏/导航栏内容色，避免深色模式下状态栏文字仍是深色。
    try {
      if (this.mainWindow !== null) {
        const statusContentColor: string = isDarkMode ? '#F0F2F5' : '#182431';
        this.mainWindow.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000',
          statusBarContentColor: statusContentColor,
          navigationBarContentColor: statusContentColor
        });
      }
    } catch (err) {
      Lg.w('羊绒互传 update system bar color failed: ' + JSON.stringify(err));
    }
  }

  onForeground(): void {
    GalleryAuthorizationRequest.setForeground(true);
    try { MtaService.get(this.context).start(); } catch (error) { Lg.w('[MTA] foreground: ' + String(error)); }
    // 回到前台：结束长时任务保活，避免后台通知常驻。
    AppServices.get(this.context).stopContinuousTask().catch((err: Error): void => {
      Lg.w(`羊绒互传 stopContinuousTask failed: ${err.message}`);
    });
  }

  onBackground(): void {
    GalleryAuthorizationRequest.setForeground(false);
    try {
      MtaService.get(this.context).stop().catch((error: Error): void => Lg.w('[MTA] background: ' + error.message));
    } catch (error) { Lg.w('[MTA] background: ' + String(error)); }
    // 进入后台：若开启「长时任务保活」且接收服务已就绪，则申请持续后台任务，让接收在后台也能长时间运行。
    Lg.i('[KEEPALIVE] EntryAbility.onBackground fired');
    AppServices.get(this.context).startContinuousTask().catch((err: Error): void => {
      Lg.w(`羊绒互传 startContinuousTask failed: ${err.message}`);
    });
  }
}
