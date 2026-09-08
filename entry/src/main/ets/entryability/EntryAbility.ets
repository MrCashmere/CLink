import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { window, uiAppearance } from '@kit.ArkUI';
import { AppSettingsStore } from '../storage/AppSettingsStore';
import { loadCustomFonts } from '../utils/CustomFonts';
import { handleSharedWant } from '../common/ShareHandleUtil';
import { NearbyScanHub } from '../common/NearbyScanHub';
import { AppServices } from '../common/AppServices';
import { LogCapture as Lg } from '../common/LogCapture';

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
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
    }
    try {
      AppSettingsStore.init(this.context);
    } catch (err) {
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
    const cardsFromTop = AppSettingsStore.getBoolean('cardsFromTop', true);
    const customFonts = AppSettingsStore.getStringArray('customFonts', []);
    AppStorage.setOrCreate('backgroundImage', backgroundImage);
    AppStorage.setOrCreate('fontMode', fontMode);
    AppStorage.setOrCreate('fontFamilyEn', fontFamilyEn);
    AppStorage.setOrCreate('fontFamilyZh', fontFamilyZh);
    AppStorage.setOrCreate('fontSizeMode', fontSizeMode);
    AppStorage.setOrCreate('fontSizeValue', fontSizeValue);
    AppStorage.setOrCreate('fontWeightMode', fontWeightMode);
    AppStorage.setOrCreate('fontWeightValue', fontWeightValue);
    AppStorage.setOrCreate('immersiveLightEnabled', immersiveLightEnabled);
    AppStorage.setOrCreate('cardsFromTop', cardsFromTop);
    AppStorage.setOrCreate('customFonts', customFonts);
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
    try {
      const config = this.context.getApplicationContext().resourceManager.getConfigurationSync();
      AppStorage.setOrCreate('isDarkMode', config.colorMode === resourceManager.ColorMode.DARK);
    } catch (err) {
      AppStorage.setOrCreate('isDarkMode', false);
    }
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
    const isDarkMode: boolean = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    AppStorage.setOrCreate('isDarkMode', isDarkMode);
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
    // 回到前台：结束长时任务保活，避免后台通知常驻。
    AppServices.get(this.context).stopContinuousTask().catch((err: Error): void => {
      Lg.w(`羊绒互传 stopContinuousTask failed: ${err.message}`);
    });
  }

  onBackground(): void {
    // 进入后台：若开启「长时任务保活」且接收服务已就绪，则申请持续后台任务，让接收在后台也能长时间运行。
    Lg.i('[KEEPALIVE] EntryAbility.onBackground fired');
    AppServices.get(this.context).startContinuousTask().catch((err: Error): void => {
      Lg.w(`羊绒互传 startContinuousTask failed: ${err.message}`);
    });
  }
}