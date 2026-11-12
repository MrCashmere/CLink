import { LogCapture as Lg } from '../common/LogCapture';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
import { common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileUri } from '@kit.CoreFileKit';
import { HdsNavigation, HdsNavigationTitleMode, HdsNavigationMenuItemOptions, HdsTabs, HdsTabsController, SystemMaterialParams, TitleBarStyleOptions, hdsMaterial, ScrollEffectType } from '@kit.UIDesignKit';
import { AppServices } from '../common/AppServices';
import { NearbyScanHub } from '../common/NearbyScanHub';
import { SettingsStore } from '../common/SettingsStore';
import { PermissionHelper, PermissionCheckOutcome } from '../common/PermissionHelper';
import { hasPendingShare } from '../common/ShareHandleUtil';
import {
  IncomingFile,
  OutgoingFile,
  TransferEvent,
  TransferTask
} from '../model/TransferModels';
import { HwColor, HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwPrimary, hwPrimaryButton, hwOnline, hwDanger, hwSurface, hwGlassBorder, withAlpha, reloadAppTheme, resolvePageBackground, onAccentColor, topBarGlassColor, resolvePrimaryColor, resolvePrimaryButtonColor, resolveGlassBorderColor } from '../utils/DesignTokens';
import { cardGlassEffect, isSdkAtLeast, pressLightColor, sheetBlurStyle, sheetSystemMaterial, cardGlassBorderColor, cardGlassShadow } from '../utils/SystemMaterial';
import { IconCircleButton } from '../components/IconCircleButton';
import { AppBackground } from '../components/AppBackground';
import { SolutionPanel } from '../components/SolutionPanel';
import { TransferProgress } from './TransferProgress';
import { AggregatePage } from './AggregatePage';
import { PendingDynamicPhotoWatcher } from '../components/PendingDynamicPhotoWatcher';
import { QuickShareTransferHistory, QuickShareTransferHistoryEntry } from '../quickshare/storage/TransferHistory';
import { PinDialogGuard } from '../common/PinDialogGuard';
import {
  WindowsNearbyHistory,
  WindowsNearbyHistoryEntry,
  WindowsNearbyLiveFile,
  WindowsNearbyLiveState,
  EMPTY_WINDOWS_NEARBY_LIVE
} from '../windowsnearby/WindowsNearbyHistory';
import { toastSystemMaterial, dialogSystemMaterial } from '../utils/SystemMaterial';
import { CardSurface } from '../components/CardSurface';
import { AccentColorSentinel, MaterialSheetPanel } from '../components/MaterialCard';
import { parseTransportMode } from '../quickshare/model/TransportPolicy';
import { GalleryAutoSaveSettingRow } from '../components/GalleryAutoSaveSettingRow';

// 蓝牙发现 / BLE 扫描所需用户授权权限，仅在点击 Quick Share / Windows 时逐项申请。
const BLUETOOTH_AND_LOCATION_PERMISSIONS: Permissions[] = [
  'ohos.permission.ACCESS_BLUETOOTH',
  'ohos.permission.APPROXIMATELY_LOCATION',
  'ohos.permission.LOCATION'
];

const BOTTOM_BAR_MARGIN: number = 12;
const TITLE_BAR_HEIGHT_FREE: number = 138; // 与 HdsNavigation FREE 模式标题栏高度保持一致，用于内容区预留空白
const TAB_BAR_CONTENT_HEIGHT: number = 56;  // 页签图标+文字的可视高度（不含底部安全区）

/**
 * HDS 沉浸光感参数（`SystemMaterialParams`，`@since 6.1.0(23)`）。
 *
 * ⚠️ **必须做版本判断，否则低版本设备会闪退。**
 * `hdsMaterial` 这个命名空间本身是 API 23 才有的：在 API 20~22 的系统上
 * `hdsMaterial` 是 `undefined`，而 `hdsMaterial.MaterialType.ADAPTIVE` 这种**成员读取**
 * 会直接抛 `TypeError`。它又是在 `build()` 期间求值的——一旦抛出，整个页面渲染失败，
 * 表现为**进入主页即闪退**（`hdsMaterial` 的 import 本身不报错，所以编译期看不出来）。
 *
 * 本项目最低支持 API 20（`compatibleSdkVersion 6.0.0(20)`），因此统一走这个工厂：
 * 低于 23 返回 `undefined`，调用方据此**不写** `systemMaterialEffect`（等价于不启用材质）。
 */
function hdsAdaptiveMaterialParams(): SystemMaterialParams | undefined {
  if (!isSdkAtLeast(23)) {
    return undefined;
  }
  const params: SystemMaterialParams = {
    materialType: hdsMaterial.MaterialType.ADAPTIVE,
    materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
  };
  return params;
}

@Component
export struct MainPage {
  /** 主题色变化时触发重建，让 HwColor.primary 与选中态取到新色值 */
  @StorageProp('accentColor') @Watch('onAccentColorChanged') accentColor: string = '';
  /** 页面底色（由 applyAppTheme 发布）。直接读 HwColor.background 登记不上依赖 */
  @StorageProp('pageBackground') pageBackground: string = '';
  pageInfos: NavPathStack = new NavPathStack();
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  /**
   * 主题色流光开关。
   *
   * 底部 HdsTab 悬浮栏那圈流光（`barFloatingStyle.lightColor`）默认是白的，
   * 只有读到这个订阅键，拨开关 / 切主题色时底栏才会重新求值、换色。
   */
  @StorageProp('immersivePressGlow') pressGlowSwitch: boolean = true;
  @StorageLink('immersiveLightEnabled') immersiveLightEnabled: boolean = true;
  @StorageLink('beautifulCards') beautifulCards: boolean = false;
  @StorageLink('classicCards') classicCards: boolean = false;
  @StorageLink('cardShadowBorder') cardShadowBorder: boolean = true;
  @StorageLink('experimentalCards') experimentalCards: boolean = false;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  @StorageLink('cardsFromTop') cardsFromTop: boolean = true;
  @StorageLink('fontMode') fontMode: string = 'system';
  @StorageLink('fontFamilyEn') fontFamilyEn: string = 'system';
  @StorageLink('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageLink('fontWeightMode') fontWeightMode: string = 'system';
  @StorageLink('fontWeightValue') fontWeightValue: number = 400;
  private tabsController: HdsTabsController = new HdsTabsController();
  private transferScroller: Scroller = new Scroller();
  private aggregateScroller: Scroller = new Scroller();
  private recordScroller: Scroller = new Scroller();
  private settingsScroller: Scroller = new Scroller();
  @State activeTab: number = 0;
  @State tasks: TransferTask[] = [];
  @State quickShareRecords: QuickShareTransferHistoryEntry[] = [];
  @State windowsNearbyRecords: WindowsNearbyHistoryEntry[] = [];
  @StorageLink('windowsNearbyLive') @Watch('onWindowsNearbyLiveChanged') windowsNearbyLive: string = EMPTY_WINDOWS_NEARBY_LIVE;
  @State visible: boolean = true;
  @State requirePin: boolean = true;
  @State encryptionEnabled: boolean = true;
  @State keepAlive: boolean = true;
  /**
   * 动态图片传输(Beta)。用 @StorageLink 而非 @State：EntryAbility 启动时会预加载设置并写入
   * AppStorage，接收侧（DynamicPhotoService）随时可能读取，这里保持与之一致。
   */
  @StorageLink('dynamicPhotoEnabled') dynamicPhotoEnabled: boolean = false;
  /**
   * 「默认通用动态图片格式」：认不出对端品牌时动态图片按哪种格式发送
   * （'apple' = Apple 实况照片，'android' = Android 标准动态照片）。
   * 仅「动态图片传输(Beta)」打开时在设置页显示。
   */
  @StorageLink('defaultLivePhotoFormat') defaultLivePhotoFormat: string = 'android';
  /**
   * 「HDR照片转换为HDR Vivid格式」（默认关）。开着时发送带增益图的 HDR 照片会按
   * HDR Vivid / ISO 21496-1 的「基础 SDR 图 + 增益图」双 JPEG 形态重排，见 HdrPhotoService。
   */
  @StorageLink('hdrVividEnabled') hdrVividEnabled: boolean = false;
  /** 「照片EXIF信息保留」（默认开）。关掉后 HDR 改写会删掉 EXIF（隐私模式）。 */
  @StorageLink('photoExifKeep') photoExifKeep: boolean = true;
  /** 「HDR转换优先重编码」（默认关）：打开后不走系统 API，直接走无损换壳。仅 HDR 开关打开时显示。 */
  @StorageLink('hdrSkipSystemReencode') hdrSkipSystemReencode: boolean = false;
  /** 「动态图片/HDR图片不保存至下载文件夹」（默认关）。 */
  @StorageLink('skipDownloadCopyForGalleryPhotos') skipDownloadCopyForGalleryPhotos: boolean = false;
  private readonly fallbackApple: string = 'apple';
  private readonly fallbackAndroid: string = 'android';
  @State quickshareWlanDirect: boolean = false;
  /** Quick Share 传输方式（三态）：auto 自动探测 / lan 仅局域网 / direct WLAN 直连优先。 */
  @State quickshareTransport: string = 'auto';
  @State localAddress: string = '';
  @State alias: string = '羊绒互传';
  @State btMac: string = '';
  @State wifiUpgradeTcp: boolean = false;
  @State aggregateAsHome: boolean = true;
  @State hideTransferPage: boolean = false;
  @State statusText: string = '正在初始化…';
  @State permissionChecking: boolean = false;
  @State permissionSummary: string = '检查蓝牙与位置权限是否已授予';
  @State permissionMissingCount: number = 0;
  /** 聚合页标题栏「解决方案」弹窗开关。 */
  @State showSolutionSheet: boolean = false;
  /** 聚合页标题栏「刷新」是否正在重启三协议广播。 */
  @State scanRestarting: boolean = false;
  @State showPinEntrySheet: boolean = false;
  @State pinEntryTaskId: string = '';
  @State pinEntryValue: string = '';
  @StorageLink('shareRequestCounter') @Watch('onShareRequest') shareRequestCounter: number = 0;
  private services?: AppServices;

  private transferListener: (event: TransferEvent) => void = (event: TransferEvent): void => {
    this.onTransferEvent(event);
  };

  /** 热点地址探测命中后立即刷新标题栏地址，省掉等待下一个刷新周期的那几秒。 */
  private hotspotAddressListener: (address: string) => void = (address: string): void => {
    this.localAddress = address;
  };

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    this.services = AppServices.get(context);
    this.services.transfer.addListener(this.transferListener);
    // 先同步取一次缓存设置，让首页/隐藏传输的初始页签立即生效，避免首帧闪到「传输」页。
    const initialSettings = SettingsStore.current();
    this.aggregateAsHome = initialSettings.aggregateAsHome === true;
    this.hideTransferPage = this.aggregateAsHome && initialSettings.hideTransferPage === true;
    this.activeTab = this.aggregateAsHome ? this.aggregateTabIndex() : 0;
    SettingsStore.load(context).then((settings) => {
      this.alias = settings.alias;
      this.requirePin = settings.requirePin;
      this.encryptionEnabled = settings.encryptionEnabled !== false;
      this.keepAlive = settings.keepAlive !== false;
      this.dynamicPhotoEnabled = settings.dynamicPhotoEnabled === true;
      this.defaultLivePhotoFormat = settings.defaultLivePhotoFormat !== undefined
        && settings.defaultLivePhotoFormat.length > 0
        ? settings.defaultLivePhotoFormat
        : this.fallbackAndroid;
      this.hdrVividEnabled = settings.hdrVividEnabled === true;
      this.photoExifKeep = settings.photoExifKeep !== false;
      this.hdrSkipSystemReencode = settings.hdrSkipSystemReencode === true;
      this.skipDownloadCopyForGalleryPhotos = settings.skipDownloadCopyForGalleryPhotos === true;
      this.visible = settings.alwaysVisible;
      this.quickshareWlanDirect = settings.quickshareWlanDirect;
      this.quickshareTransport = settings.quickshareTransport ?? (settings.quickshareWlanDirect ? 'direct' : 'auto');
      this.btMac = settings.btMac;
      this.wifiUpgradeTcp = settings.wifiUpgradeTcp;
      this.aggregateAsHome = settings.aggregateAsHome === true;
      this.hideTransferPage = this.aggregateAsHome && settings.hideTransferPage === true;
      this.activeTab = this.aggregateAsHome ? this.aggregateTabIndex() : 0;
    });
    QuickShareTransferHistory.load(context).then((): void => {
      this.quickShareRecords = QuickShareTransferHistory.list();
    }).catch((): void => undefined);
    WindowsNearbyHistory.load(context).then((): void => {
      this.windowsNearbyRecords = WindowsNearbyHistory.list();
    }).catch((): void => undefined);
    const services = this.services;
    if (services !== undefined) {
      // 开热点时系统枚举只给蜂窝地址（10.x），这里订阅探测结果，探到 192.168.43.1 立刻改写。
      services.onHotspotAddressChange(this.hotspotAddressListener);
      // 先取一次：热点开着时即时答案（192.168.43.1）此刻就有，不必等任何异步。
      this.localAddress = services.displayAddress();
    }
    // 启动时不再批量申请运行时权限；改为点击 Quick Share / Windows 时逐项申请。
    const startPromise = services !== undefined ? services.startReceive() : Promise.resolve();
    startPromise.then(() => {
      this.statusText = '等待接收';
      this.localAddress = this.services !== undefined ? this.services.displayAddress() : '';
    }).catch((error: BusinessError) => {
      this.statusText = `启动失败: ${error.message}`;
    });
    this.onShareRequest();
    // 静默刷新一次权限概览（只读检查，不弹窗），让设置页进去就能看到当前状态。
    this.refreshPermissionSummary();
  }

  aboutToDisappear(): void {
    this.finishPinEntry(false);
    if (this.services !== undefined) {
      this.services.transfer.removeListener(this.transferListener);
      this.services.offHotspotAddressChange(this.hotspotAddressListener);
    }
  }

  // 系统分享入口：mainAbility 通过 skills(entity.system.share) 收到共享文件后写入
  // AppStorage。这里在冷启动（aboutToAppear）与热启动（AppStorage Watch）两处触发，
  // 有未处理的共享文件时进入选择页。
  private onShareRequest(): void {
    if (hasPendingShare()) {
      router.pushUrl({ url: 'pages/ShareChoosePage' }).catch((error: BusinessError): void => {
        Lg.w('MainPage route ShareChoosePage failed: ' + error.message);
      });
    }
  }

  private subTitleText(): string {
    const addressText = this.localAddress.length > 0 ? ` · ${this.localAddress}` : '';
    return `${this.statusText}${addressText}`;
  }

  /**
   * 聚合页标题栏右上角按钮：左「刷新」右「解决方案」，仅在聚合页签展示。
   * HdsNavigation 的 menu 会把每个 item 渲染成标题栏右上角的圆形图标按钮。
   */
  private aggregateMenus(): HdsNavigationMenuItemOptions[] {
    if (this.activeTab !== this.aggregateTabIndex()) {
      return [];
    }
    const menus: HdsNavigationMenuItemOptions[] = [
      {
        content: {
          icon: $r('sys.symbol.arrow_clockwise'),
          label: '重启广播',
          isEnabled: !this.scanRestarting,
          action: (): void => {
            this.restartScans();
          }
        }
      },
      {
        content: {
          icon: $r('sys.symbol.questionmark_circle'),
          label: '解决方案',
          action: (): void => {
            this.showSolutionSheet = true;
          }
        }
      }
    ];
    return menus;
  }

  /**
   * 重启发现与广播，保留正在进行的收发连接及接收监听。
   */
  private restartScans(): void {
    if (this.scanRestarting) {
      return;
    }
    this.scanRestarting = true;
    const context = getContext(this) as common.UIAbilityContext;
    Lg.i('[AGGREGATE] 用户请求重启三协议广播');
    promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '正在重启全部协议的广播…', duration: 1500 });
    NearbyScanHub.get(context).restart().then((): void => {
      this.scanRestarting = false;
      this.localAddress = this.services !== undefined ? this.services.displayAddress() : '';
      this.statusText = '等待接收';
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '广播已重启', duration: 1500 });
    }).catch((error: BusinessError): void => {
      this.scanRestarting = false;
      Lg.w('[AGGREGATE] 重启三协议广播失败: ' + error.message);
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '重启失败，请重试', duration: 2000 });
    });
  }

  /** 权限的中文名，用于权限自检结果文案。 */
  private permissionLabel(permission: Permissions): string {
    if (permission === 'ohos.permission.ACCESS_BLUETOOTH') {
      return '蓝牙';
    }
    if (permission === 'ohos.permission.APPROXIMATELY_LOCATION') {
      return '模糊位置';
    }
    if (permission === 'ohos.permission.LOCATION') {
      return '精确位置';
    }
    return permission;
  }

  private permissionNames(permissions: Permissions[]): string {
    const labels: string[] = permissions.map((item: Permissions): string => this.permissionLabel(item));
    return labels.join('、');
  }

  /** 只读检查，不触发任何弹窗；用于进入设置页时展示当前权限状态。 */
  private refreshPermissionSummary(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const missing: Permissions[] = PermissionHelper.missing(context, BLUETOOTH_AND_LOCATION_PERMISSIONS);
    this.permissionMissingCount = missing.length;
    this.permissionSummary = missing.length === 0
      ? '蓝牙与位置权限均已授予'
      : '未授予：' + this.permissionNames(missing);
  }

  /**
   * 权限自检：逐项检查蓝牙/位置权限，未授予的重新弹窗申请；
   * 若系统因用户此前永久拒绝而不再弹窗，则拉起「设置内授权」弹窗。
   */
  private runPermissionCheck(): void {
    if (this.permissionChecking) {
      return;
    }
    this.permissionChecking = true;
    this.permissionSummary = '正在检查权限…';
    const context = getContext(this) as common.UIAbilityContext;
    Lg.i('[SETTINGS] 用户触发权限自检');
    PermissionHelper.recheck(context, BLUETOOTH_AND_LOCATION_PERMISSIONS)
      .then((outcome: PermissionCheckOutcome): void => {
        this.permissionChecking = false;
        this.permissionMissingCount = outcome.missing.length;
        if (outcome.missing.length === 0) {
          this.permissionSummary = '蓝牙与位置权限均已授予';
          promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '权限齐全', duration: 1500 });
          return;
        }
        const names = this.permissionNames(outcome.missing);
        if (outcome.needManualGrant) {
          this.permissionSummary = '仍未授予：' + names + '。请在系统「设置 → 应用 → 羊绒互传 → 权限」中手动开启。';
          promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '部分权限被拒绝，需在系统设置中开启', duration: 3000 });
        } else {
          this.permissionSummary = '仍未授予：' + names;
          promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '仍缺少：' + names, duration: 2500 });
        }
      })
      .catch((error: BusinessError): void => {
        this.permissionChecking = false;
        this.permissionSummary = '权限检查失败，请重试';
        Lg.w('permission recheck failed: ' + error.message);
        promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '权限检查失败，请重试', duration: 2000 });
      });
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

  private byteText(size: number): string {
    if (size >= 1024 * 1024) {
      return (size / (1024 * 1024)).toFixed(1) + ' MB';
    }
    if (size >= 1024) {
      return Math.floor(size / 1024) + ' KB';
    }
    return size + ' B';
  }

  private quickShareTime(ts: number): string {
    const d = new Date(ts);
    const pad = (v: number): string => v < 10 ? '0' + v : String(v);
    return pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  private aggregateTabIndex(): number {
    return this.hideTransferPage ? 0 : 1;
  }

  private recordTabIndex(): number {
    return this.hideTransferPage ? 1 : 2;
  }

  private settingsTabIndex(): number {
    return this.hideTransferPage ? 2 : 3;
  }

  private tabLabel(kind: string): string {
    if (kind === 'transfer') {
      return '传输';
    } else if (kind === 'aggregate') {
      return '聚合';
    } else if (kind === 'record') {
      return '记录';
    }
    return '设置';
  }

  // API >= 23 走悬浮页签栏（barFloatingStyle），底部小白条由 barBottomMargin 避让。
  // API < 23 没有 barFloatingStyle，只能退回 barOverlap(false) 的贴底页签栏；而
  // HdsNavigation 上的 ignoreLayoutSafeArea(BOTTOM) 会让内容区一直铺到屏幕底部，
  // 页签栏因此直接压在导航条/小白条上。这里把底部安全区高度补进页签栏自身：
  // 栏背景（含毛玻璃）继续铺到屏幕底部，图标与文字整体上移避让小白条。
  private legacyTabBarInset(): number {
    return isSdkAtLeast(23) ? 0 : this.navigationBarHeight;
  }

  // 低版本贴底页签栏总高度 = 可视内容高度 + 底部安全区。
  // 不显式设置 barHeight 时 Tabs 会按默认 56vp 裁掉补出来的安全区。
  private legacyTabBarHeight(): number {
    return TAB_BAR_CONTENT_HEIGHT + this.legacyTabBarInset();
  }

  /**
   * 底栏选中态的颜色。
   *
   * **必须读 `this.accentColor`（订阅变量），不能写 `HwColor.primary`。**
   * 后者是模块级对象的属性，ArkUI 按表达式登记依赖时读不到它，切主题色后
   * 底栏高亮会一直停在上一套配色——这正是「换主题色后底栏高亮不实时更换」的原因。
   */
  private tabSelectedColor(): string {
    return this.accentColor.length > 0 ? this.accentColor : resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary());
  }

  /** 底栏未选中图标/文字色 */
  private tabInactiveColor(): string {
    return hwTextSecondary(this.isDarkMode);
  }

  /**
   * 底部 HdsTab 悬浮栏的流光颜色。
   *
   * 这个光由 HdsTabs 自己画（`barFloatingStyle.lightColor`），不归应用的材质管，
   * 所以必须单独下发一次；关掉「主题色流光」时回到系统默认白光。
   * 同样必须由调用方在渲染期读订阅变量——函数内部读 AppStorage 登记不上依赖。
   */
  private tabLightColor(): ResourceColor {
    const light: string = pressLightColor(this.pressGlowSwitch, this.accentColor);
    return light.length > 0 ? light : Color.White;
  }

  @Builder
  tabIcon(kind: string, index: number) {
    if (kind === 'transfer') {
      SymbolGlyph($r('sys.symbol.arrow_left_arrow_right'))
        .fontSize(23)
        .fontColor([this.activeTab === index ? this.tabSelectedColor() : this.tabInactiveColor()])
    } else if (kind === 'aggregate') {
      SymbolGlyph(this.activeTab === index ? $r('sys.symbol.square_fill_grid_2x2') : $r('sys.symbol.square_grid_2x2'))
        .fontSize(23)
        .fontColor([this.activeTab === index ? this.tabSelectedColor() : this.tabInactiveColor()])
    } else if (kind === 'record') {
      SymbolGlyph(this.activeTab === index ? $r('sys.symbol.doc_text_fill') : $r('sys.symbol.doc_text'))
        .fontSize(23)
        .fontColor([this.activeTab === index ? this.tabSelectedColor() : this.tabInactiveColor()])
    } else {
      SymbolGlyph($r('sys.symbol.gearshape'))
        .fontSize(23)
        .fontColor([this.activeTab === index ? this.tabSelectedColor() : this.tabInactiveColor()])
    }
  }

  @Builder
  tabItem(kind: string, index: number) {
    Column({ space: 4 }) {
      this.tabIcon(kind, index)
      Text(this.tabLabel(kind))
        .fontSize(11)
        .fontFamily(this.appFontFamily(this.tabLabel(kind)))
        .fontWeight(this.appFontWeight())
        .fontColor(this.activeTab === index ? this.tabSelectedColor() : this.tabInactiveColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(TAB_BAR_CONTENT_HEIGHT + this.legacyTabBarInset())
    .padding({ bottom: this.legacyTabBarInset() })
    .justifyContent(FlexAlign.Center)
  }

  private onTabChanged(index: number): void {
    this.activeTab = index;
    // 标题栏(FREE 模式)与三个 Scroll 绑定：任一个滚动都会导致标题栏折叠。
    // 切换页签时统一回到顶部，避免标题栏停留在上一页的折叠状态。
    try {
      this.transferScroller.scrollEdge(Edge.Top);
    } catch (err) {
    }
    try {
      this.aggregateScroller.scrollEdge(Edge.Top);
    } catch (err) {
    }
    try {
      this.recordScroller.scrollEdge(Edge.Top);
    } catch (err) {
    }
    try {
      this.settingsScroller.scrollEdge(Edge.Top);
    } catch (err) {
    }
    // 切到设置页时静默刷新权限概览：用户可能刚从系统设置里改过授权。
    if (index === this.settingsTabIndex()) {
      this.refreshPermissionSummary();
    }
  }

  @Builder
  paneTabs() {
    if (this.hideTransferPage) {
      // 隐藏「传输」页：仅挂载 聚合/记录/设置 三个页签。
      // 注意：不要在同一个 HdsTabs 内部用 if 增删 TabContent，否则切换时索引会错位、
      // 悬浮高亮会歪。这里直接切换成“3 页签”的独立 HdsTabs 实例，保证索引即物理位置。
      if (isSdkAtLeast(23)) {
        HdsTabs({ controller: this.tabsController, index: this.activeTab }) {
          TabContent() { this.aggregatePane() }.tabBar(this.tabItem('aggregate', 0))
          TabContent() { this.recordPane() }.tabBar(this.tabItem('record', 1))
          TabContent() { this.settingsPane() }.tabBar(this.tabItem('settings', 2))
        }
        .width('100%')
        .height('100%')
        .barPosition(BarPosition.End)
        .barOverlap(true)
        .scrollable(false)
        .onChange((index: number) => {
          this.onTabChanged(index);
        })
        .barFloatingStyle({
          barBottomMargin: BOTTOM_BAR_MARGIN + this.navigationBarHeight,
          barSideMargin: 16,
          gradientMask: {
            maskColor: '#00000000',
            maskHeight: 1
          },
          // 材质参数走统一的版本安全工厂（API < 23 时为 undefined）
          systemMaterialEffect: hdsAdaptiveMaterialParams(),
          // 底栏流光：默认白，开了「主题色流光」就跟着主题色走
          lightColor: this.tabLightColor()
        })
      } else {
        HdsTabs({ controller: this.tabsController, index: this.activeTab }) {
          TabContent() { this.aggregatePane() }.tabBar(this.tabItem('aggregate', 0))
          TabContent() { this.recordPane() }.tabBar(this.tabItem('record', 1))
          TabContent() { this.settingsPane() }.tabBar(this.tabItem('settings', 2))
        }
        .width('100%')
        .height('100%')
        .barPosition(BarPosition.End)
        .barHeight(this.legacyTabBarHeight())
        .barOverlap(false)
        .scrollable(false)
        .onChange((index: number) => {
          this.onTabChanged(index);
        })
        .barBackgroundBlurStyle(BlurStyle.Thin)
      }
    } else {
      // 完整四页签：传输/聚合/记录/设置。
      if (isSdkAtLeast(23)) {
        HdsTabs({ controller: this.tabsController, index: this.activeTab }) {
          TabContent() { this.transferPane() }.tabBar(this.tabItem('transfer', 0))
          TabContent() { this.aggregatePane() }.tabBar(this.tabItem('aggregate', 1))
          TabContent() { this.recordPane() }.tabBar(this.tabItem('record', 2))
          TabContent() { this.settingsPane() }.tabBar(this.tabItem('settings', 3))
        }
        .width('100%')
        .height('100%')
        .barPosition(BarPosition.End)
        .barOverlap(true)
        .scrollable(false)
        .onChange((index: number) => {
          this.onTabChanged(index);
        })
        .barFloatingStyle({
          barBottomMargin: BOTTOM_BAR_MARGIN + this.navigationBarHeight,
          barSideMargin: 16,
          gradientMask: {
            maskColor: '#00000000',
            maskHeight: 1
          },
          // 材质参数走统一的版本安全工厂（API < 23 时为 undefined）
          systemMaterialEffect: hdsAdaptiveMaterialParams(),
          // 底栏流光：默认白，开了「主题色流光」就跟着主题色走
          lightColor: this.tabLightColor()
        })
      } else {
        HdsTabs({ controller: this.tabsController, index: this.activeTab }) {
          TabContent() { this.transferPane() }.tabBar(this.tabItem('transfer', 0))
          TabContent() { this.aggregatePane() }.tabBar(this.tabItem('aggregate', 1))
          TabContent() { this.recordPane() }.tabBar(this.tabItem('record', 2))
          TabContent() { this.settingsPane() }.tabBar(this.tabItem('settings', 3))
        }
        .width('100%')
        .height('100%')
        .barPosition(BarPosition.End)
        .barHeight(this.legacyTabBarHeight())
        .barOverlap(false)
        .scrollable(false)
        .onChange((index: number) => {
          this.onTabChanged(index);
        })
        .barBackgroundBlurStyle(BlurStyle.Thin)
      }
    }
  }

  @Builder
  transferPane() {
    Scroll(this.transferScroller) {
      Column({ space: 12 }) {
        Blank().height(TITLE_BAR_HEIGHT_FREE + this.statusBarHeight)
        if (this.hasWindowsNearbyLiveContent()) {
          this.windowsNearbyLiveCard(this.parseLiveState())
        }
        this.quickShareEntry()
        this.windowsNearbyEntry()
        this.localSendEntry()
        this.mtaEntry()
        this.lanWebEntry()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 96 })
    }
    .width('100%')
    .height('100%')
    .align(this.cardsFromTop ? Alignment.Top : Alignment.Center)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  aggregatePane() {
    Scroll(this.aggregateScroller) {
      Column() {
        // 仅在聚合页聚焦时挂载：确保进入时启动三种协议扫描、离开时停止。
        if (this.activeTab === this.aggregateTabIndex()) {
          AggregatePage()
        }
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .align(this.cardsFromTop ? Alignment.Top : Alignment.Center)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  recordPane() {
    Scroll(this.recordScroller) {
      Column({ space: 12 }) {
        Blank().height(TITLE_BAR_HEIGHT_FREE + this.statusBarHeight)
        this.sectionTitle('LocalSend 记录')
        TransferProgress({ tasks: this.tasks })
        if (this.quickShareRecords.length > 0) {
          this.quickShareHistory()
        }
        if (this.windowsNearbyRecords.length > 0) {
          this.windowsNearbyHistory()
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 96 })
    }
    .width('100%')
    .height('100%')
    .align(this.cardsFromTop ? Alignment.Top : Alignment.Center)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  quickShareHistory() {
    Column({ space: 12 }) {
      Text('Quick Share 记录').fontSize(15).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('Quick Share 记录')).fontColor(hwTextPrimary(this.isDarkMode)).width('100%')
      ForEach(this.quickShareRecords, (rec: QuickShareTransferHistoryEntry): void => {
        CardSurface({ radius: HwRadius.control }) {
          Column({ space: 4 }) {
            Row({ space: 8 }) {
              Text(rec.direction === 'send' ? '↑' : '↓').fontSize(14)
                .fontFamily(this.appFontFamily(rec.direction === 'send' ? '↑' : '↓')).fontWeight(this.appFontWeight())
                .fontColor(rec.direction === 'send' ? resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()) : hwOnline(this.isDarkMode))
              Text(rec.name).layoutWeight(1).fontSize(13).fontFamily(this.appFontFamily(rec.name)).fontWeight(this.appFontWeight()).fontColor(hwTextPrimary(this.isDarkMode))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.byteText(rec.size)).fontSize(12).fontFamily(this.appFontFamily(this.byteText(rec.size))).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
              if (rec.savedPath.length > 0) {
                Button('打开', { type: ButtonType.Capsule }).height(24).fontSize(11).fontFamily(this.appFontFamily('打开'))
                  .backgroundColor(resolvePrimaryButtonColor(this.isDarkMode, this.accentOrPrimary())).fontColor(onAccentColor(this.accentOrPrimary()))
                  .onClick(() => this.openFileByPath(rec.savedPath))
              }
            }.width('100%')
            Text((rec.direction === 'send' ? '发送给 ' : '来自 ') + rec.peer + ' · ' + this.quickShareTime(rec.completedAt))
              .fontSize(11).fontFamily(this.appFontFamily((rec.direction === 'send' ? '发送给 ' : '来自 ') + rec.peer + ' · ' + this.quickShareTime(rec.completedAt))).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).width('100%')
          }
          .width('100%')
          .padding(HwSpace.md)
          .borderRadius(HwRadius.control)
          .backgroundColor(Color.Transparent)
          .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
          .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
          .clip(true)
          .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
        }
      }, (rec: QuickShareTransferHistoryEntry): string => rec.id + ':' + this.accentColor)
    }
    .width('100%')
  }

  @Builder
  windowsNearbyHistory() {
    Column({ space: 12 }) {
      Text('Windows Nearby 记录').fontSize(15).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('Windows Nearby 记录')).fontColor(hwTextPrimary(this.isDarkMode)).width('100%')
      ForEach(this.windowsNearbyRecords, (rec: WindowsNearbyHistoryEntry): void => {
        CardSurface({ radius: HwRadius.control }) {
          Column({ space: 4 }) {
            Row({ space: 8 }) {
              Text(rec.direction === 'send' ? '↑' : '↓').fontSize(14)
                .fontFamily(this.appFontFamily(rec.direction === 'send' ? '↑' : '↓')).fontWeight(this.appFontWeight())
                .fontColor(rec.direction === 'send' ? resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()) : hwOnline(this.isDarkMode))
              Text(rec.name).layoutWeight(1).fontSize(13).fontFamily(this.appFontFamily(rec.name)).fontWeight(this.appFontWeight()).fontColor(hwTextPrimary(this.isDarkMode))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.byteText(rec.size)).fontSize(12).fontFamily(this.appFontFamily(this.byteText(rec.size))).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
              Button('打开', { type: ButtonType.Capsule }).height(24).fontSize(11).fontFamily(this.appFontFamily('打开'))
                .backgroundColor(resolvePrimaryButtonColor(this.isDarkMode, this.accentOrPrimary())).fontColor(onAccentColor(this.accentOrPrimary()))
                .onClick(() => this.openFileByPath(rec.savedPath))
            }.width('100%')
            Text((rec.direction === 'send' ? '发送给 ' : '来自 ') + rec.peer + ' · ' + this.windowsNearbyTime(rec.completedAt))
              .fontSize(11).fontFamily(this.appFontFamily((rec.direction === 'send' ? '发送给 ' : '来自 ') + rec.peer + ' · ' + this.windowsNearbyTime(rec.completedAt))).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).width('100%')
          }
          .width('100%')
          .padding(HwSpace.md)
          .borderRadius(HwRadius.control)
          .backgroundColor(Color.Transparent)
          .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
          .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
          .clip(true)
          .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
        }
      }, (rec: WindowsNearbyHistoryEntry): string => rec.id + ':' + this.accentColor)
    }
    .width('100%')
  }

  @Builder
  windowsNearbyLiveCard(live: WindowsNearbyLiveState) {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text('Windows Nearby 传输').fontSize(15).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('Windows Nearby 传输')).fontColor(hwTextPrimary(this.isDarkMode)).layoutWeight(1)
          if (live.completed) {
            Text('已完成').fontSize(12).fontFamily(this.appFontFamily('已完成')).fontWeight(this.appFontWeight()).fontColor(hwOnline(this.isDarkMode))
          } else if (live.percent > 0) {
            Text('接收中 ' + Math.floor(live.percent) + '%').fontSize(12).fontFamily(this.appFontFamily('接收中 %')).fontWeight(this.appFontWeight()).fontColor(resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()))
          } else {
            Text('接收中').fontSize(12).fontFamily(this.appFontFamily('接收中')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
          }
        }.width('100%')
        if (live.peer.length > 0) {
          Text('来自 ' + live.peer).fontSize(13).fontFamily(this.appFontFamily('来自 ' + live.peer)).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).width('100%')
        }
        if (live.percent > 0 && live.percent < 100) {
          Progress({ value: live.percent, total: 100, type: ProgressType.Linear })
            .width('100%')
            .margin({ top: 4 })
        }
        if (live.files.length > 0) {
          Column({ space: 6 }) {
            ForEach(live.files.slice(), (file: WindowsNearbyLiveFile): void => {
              Row({ space: 8 }) {
                Text(file.name).layoutWeight(1).fontSize(13).fontFamily(this.appFontFamily(file.name)).fontWeight(this.appFontWeight()).fontColor(hwTextPrimary(this.isDarkMode))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.byteText(file.size)).fontSize(12).fontFamily(this.appFontFamily(this.byteText(file.size))).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
                Button('打开', { type: ButtonType.Capsule }).height(26).fontSize(12).fontFamily(this.appFontFamily('打开'))
                  .backgroundColor(resolvePrimaryButtonColor(this.isDarkMode, this.accentOrPrimary())).fontColor(onAccentColor(this.accentOrPrimary()))
                  .onClick(() => this.openFileByPath(file.savedPath))
              }.width('100%')
            }, (file: WindowsNearbyLiveFile): string => file.savedPath + ':' + file.name + ':' + this.accentColor)
          }.width('100%')
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
  }

  @Builder
  settingsPane() {
    Scroll(this.settingsScroller) {
      Column({ space: 12 }) {
        Blank().height(TITLE_BAR_HEIGHT_FREE + this.statusBarHeight)
        Column({ space: 12 }) {
          this.aliasCard()
          this.permissionCheckRow()
          this.pinRow()
          this.encryptionRow()
          this.keepAliveRow()
          this.dynamicPhotoRow()
          // 只在「动态图片传输(Beta)」打开时显示：关掉功能时这个选项没有作用。
          if (this.dynamicPhotoEnabled) {
            this.fallbackLivePhotoFormatRow()
          }
          // HDR 与 EXIF 两个开关独立于「动态图片传输」，各自的默认值不同（HDR 默认关、EXIF 默认开）。
          this.hdrVividRow()
          // 「HDR转换优先重编码」只在 HDR 转换打开时显示（关掉时它没有任何作用）。
          if (this.hdrVividEnabled) {
            this.hdrPreferReencodeRow()
          }
          this.exifKeepRow()
          this.skipDownloadCopyRow()
          GalleryAutoSaveSettingRow()
          this.visibleRow()
          this.wlanDirectRow()
          this.btMacCard()
          this.wifiUpgradeRow()
          this.aggregateAsHomeRow()
          if (this.aggregateAsHome) {
            this.hideTransferRow()
          }
          this.appearanceRow()
          this.logRow()
          this.aboutRow()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 96 })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .align(this.cardsFromTop ? Alignment.Top : Alignment.Center)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  aliasCard() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 8 }) {
        Text('设备名称')
          .fontSize(13)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('设备名称'))
          .fontWeight(this.appFontWeight())
          .width('100%')
        TextInput({ text: this.alias, placeholder: '设备名称' })
          .caretColor(this.accentOrPrimary())
          .width('100%')
          .height(44)
          .fontSize(15)
          .fontColor(hwTextPrimary(this.isDarkMode))
          .backgroundColor(hwSurface(this.isDarkMode))
          .borderRadius(HwRadius.control)
          .onChange((value: string) => {
            this.alias = value;
            this.persistSettings();
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

  @Builder
  permissionCheckRow() {
    CardSurface({ radius: HwRadius.control }) {
      Row({ space: 12 }) {
        IconCircleButton({ symbol: $r('sys.symbol.checkmark_shield'), buttonSize: 36, iconSize: 18 })
        Column({ space: 2 }) {
          Text('检查权限')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(hwTextPrimary(this.isDarkMode))
            .fontFamily(this.appFontFamily('检查权限'))
          Text(this.permissionSummary)
            .fontSize(12)
            .fontColor(this.permissionMissingCount > 0 ? hwDanger(this.isDarkMode) : hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily(this.permissionSummary))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        if (this.permissionChecking) {
          LoadingProgress()
            .width(22)
            .height(22)
            .color(resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()))
        } else {
          Button('检查')
            .fontSize(13)
            // 主题色实底上的字色按亮度自动取黑/白（浅色主题色上白字会看不清），
            // 并且读的是订阅变量，切色时这一处会跟着重算
            .fontColor(onAccentColor(this.accentOrPrimary()))
            .height(32)
            .padding({ left: 14, right: 14 })
            .backgroundColor(resolvePrimaryButtonColor(this.isDarkMode, this.accentOrPrimary()))
            .borderRadius(HwRadius.pill)
            .onClick(() => {
              this.runPermissionCheck();
            })
        }
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.control)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
    }
  }

  @Builder
  pinRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text($r('app.string.settings_verify_title'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily('传输前要求PIN验证'))
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text($r('app.string.settings_verify_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('双方显示相同PIN，确认后传输，防止中间人攻击'))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.requirePin })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.requirePin = value;
            this.persistSettings();
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

  @Builder
  encryptionRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text($r('app.string.settings_encryption_title'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily('LocalSend 加密传输 (TLS)'))
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text($r('app.string.settings_encryption_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('启用后本机 LocalSend 用 HTTPS 接收；若对端不支持加密则由对端决定连接方式'))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.encryptionEnabled })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.encryptionEnabled = value;
            this.persistSettings();
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

  @Builder
  keepAliveRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text($r('app.string.settings_background_title'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily('长时任务保活'))
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text($r('app.string.settings_background_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('开启后，进入后台也能持续运行以接收对端发送的文件，不再被系统短暂冻结'))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.keepAlive })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.keepAlive = value;
            if (value) {
              // 打开保活即在前台申请通知授权，保证连续任务的通知能显示。
              this.services?.ensureKeepAliveNotificationPermission().catch((): void => undefined);
            } else {
              this.services?.stopContinuousTask().catch((): void => undefined);
            }
            this.persistSettings();
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

  /**
   * 「Beta」小标：本轮新增的实验性设置项统一用它。
   *
   * 抽成一个 @Builder 而不是每行各写一份样式：新增项会持续加入，样式必须完全一致
   * （字号/内边距/圆角/配色），否则设置页看起来会像两个不同版本拼起来的。
   */
  @Builder
  betaBadge() {
    Text('Beta')
      .fontSize(10)
      .fontWeight(FontWeight.Medium)
      .fontFamily(this.appFontFamily('Beta'))
      // 主题色底上的字色按深浅自动取黑/白
      .fontColor(onAccentColor(this.accentOrPrimary()))
      .padding({ left: 6, right: 6, top: 1, bottom: 1 })
      .borderRadius(6)
      .backgroundColor(resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()))
  }

  @Builder
  dynamicPhotoRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text($r('app.string.settings_dynamic_title'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontFamily(this.appFontFamily('动态图片传输'))
              .fontColor(hwTextPrimary(this.isDarkMode))
            this.betaBadge()
          }
          Text($r('app.string.settings_dynamic_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('发送时自动识别动态图片'))
            .fontWeight(this.appFontWeight())
            .lineHeight(16)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.dynamicPhotoEnabled })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.dynamicPhotoEnabled = value;
            this.persistSettings();
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

  /**
   * 「HDR照片转换为HDR Vivid格式」开关（默认关）。
   *
   * 为什么默认关：这是**改写文件字节**的能力（重排成双 JPEG + 重建 MPF），收益是 HDR 观感，
   * 代价是发送侧多一次文件改写；且各端相册对 HDR 的还原效果尚未在真机全量验证
   * （见 docs/HDR_IMAGE.md §6）。关着时发送链路一个字节都不改。
   */
  @Builder
  hdrVividRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text($r('app.string.settings_hdr_title'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontFamily(this.appFontFamily('HDR照片转换为HDR Vivid格式'))
              .fontColor(hwTextPrimary(this.isDarkMode))
            this.betaBadge()
          }
          Text($r('app.string.settings_hdr_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('发送带增益图'))
            .fontWeight(this.appFontWeight())
            .lineHeight(16)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.hdrVividEnabled })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.hdrVividEnabled = value;
            this.persistSettings();
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

  /** 「照片EXIF信息保留」开关（默认开）。关掉即隐私模式：改写时删除 EXIF。 */
  @Builder
  exifKeepRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text($r('app.string.settings_exif_title'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontFamily(this.appFontFamily('照片EXIF信息保留'))
              .fontColor(hwTextPrimary(this.isDarkMode))
            this.betaBadge()
          }
          Text($r('app.string.settings_exif_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('转换 HDR 照片时保留原始 EXIF'))
            .fontWeight(this.appFontWeight())
            .lineHeight(16)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.photoExifKeep })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.photoExifKeep = value;
            this.persistSettings();
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

  /**
   * 「HDR转换优先重编码」（默认关，仅「HDR照片转换为HDR Vivid格式」打开时显示）。
   *
   * 按产品确认的行为：**打开后不走系统 API 重编码**，直接用无损换壳；关闭时先尝试系统 API，
   * 产物若把增益图拍平会自动丢弃并退回无损换壳。文案按真实行为写，避免标签字面歧义。
   */
  @Builder
  hdrPreferReencodeRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text($r('app.string.settings_hdr_original_title'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontFamily(this.appFontFamily('HDR转换优先重编码'))
              .fontColor(hwTextPrimary(this.isDarkMode))
            this.betaBadge()
          }
          Text($r('app.string.settings_hdr_original_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('打开后不再走系统 API 重编码'))
            .fontWeight(this.appFontWeight())
            .lineHeight(16)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.hdrSkipSystemReencode })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.hdrSkipSystemReencode = value;
            this.persistSettings();
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

  /** 「动态图片/HDR图片不保存至下载文件夹」（默认关）。 */
  @Builder
  skipDownloadCopyRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text($r('app.string.settings_dynamic_download_title'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontFamily(this.appFontFamily('动态图片/HDR图片不保存至下载文件夹'))
              .fontColor(hwTextPrimary(this.isDarkMode))
            this.betaBadge()
          }
          Text($r('app.string.settings_dynamic_download_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('接收到的动态照片（含 HDR）已经保存进相册时'))
            .fontWeight(this.appFontWeight())
            .lineHeight(16)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.skipDownloadCopyForGalleryPhotos })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.skipDownloadCopyForGalleryPhotos = value;
            this.persistSettings();
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

  /**
   * 「默认通用动态图片格式」：认不出对端品牌时按哪种格式发送动态图片。
   *
   * 只在「动态图片传输(Beta)」打开时显示 —— 关掉该功能时这个选项没有任何作用。
   */
  @Builder
  fallbackLivePhotoFormatRow() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 10 }) {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text($r('app.string.settings_dynamic_format_title'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontFamily(this.appFontFamily('默认通用动态图片格式'))
              .fontColor(hwTextPrimary(this.isDarkMode))
            this.betaBadge()
          }
          Text($r('app.string.settings_dynamic_format_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('识别不出对端品牌时'))
            .fontWeight(this.appFontWeight())
            .lineHeight(16)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        Row({ space: 10 }) {
          this.fallbackFormatChip('Apple 实况照片', this.fallbackApple)
          this.fallbackFormatChip('Android 标准动态照片', this.fallbackAndroid)
          Blank()
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
  }

  /** 二选一胶囊：选中态用主色实底 + 白字（与设置页其它按钮一致），未选中为描边淡底。 */
  @Builder
  fallbackFormatChip(label: string, value: string) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.defaultLivePhotoFormat === value ? FontWeight.Medium : FontWeight.Regular)
      .fontFamily(this.appFontFamily(label))
      .fontColor(this.defaultLivePhotoFormat === value ? Color.White : hwTextSecondary(this.isDarkMode))
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .borderRadius(HwRadius.pill)
      .backgroundColor(this.defaultLivePhotoFormat === value
        ? resolvePrimaryButtonColor(this.isDarkMode, this.accentOrPrimary())
        : Color.Transparent)
      .border({
        width: 1,
        color: this.defaultLivePhotoFormat === value
          ? resolvePrimaryButtonColor(this.isDarkMode, this.accentOrPrimary())
          : resolveGlassBorderColor(this.isDarkMode, this.accentOrPrimary())
      })
      .onClick(() => {
        if (this.defaultLivePhotoFormat !== value) {
          this.defaultLivePhotoFormat = value;
          this.persistSettings();
        }
      })
  }

  @Builder
  visibleRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text('LocalSend 可见性')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily('LocalSend 可见性'))
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text($r('app.string.settings_visible_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('让附近的 LocalSend 设备发现本机。'))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.visible })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.visible = value;
            if (value) {
              this.services?.refreshAliasFingerprint().then(() => {
                if (this.visible) { this.services?.localsend.setVisible(true); }
              });
            } else {
              this.services?.localsend.setVisible(false);
            }
            this.persistSettings();
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

  @Builder
  aggregateAsHomeRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text('以「聚合」页为首页')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily('以「聚合」页为首页'))
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text('打开软件时默认进入「聚合」页')
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('打开软件时默认进入「聚合」页'))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.aggregateAsHome })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.aggregateAsHome = value;
            if (!value) {
              this.hideTransferPage = false;
            }
            // 保持停留在设置页（聚合首页不影响页签数量，索引不变）。
            this.activeTab = this.settingsTabIndex();
            this.persistSettings();
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

  @Builder
  hideTransferRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text('隐藏「传输」页')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily('隐藏「传输」页'))
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text('隐藏后底栏不再显示「传输」页')
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('隐藏后底栏不再显示「传输」页'))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.hideTransferPage })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.hideTransferPage = value;
            // 页签数量随「传输」页隐藏而变化，把当前页签保持到依然存在的「设置」页。
            this.activeTab = this.settingsTabIndex();
            this.persistSettings();
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

  /**
   * 传输方式三态芯片（与外观设置页的 darkModeChip 同构：自绘底色 + 主题色选中）。
   * 用芯片而不是开关：auto/lan/direct 是三个并列语义，开关只能表达两态。
   */
  @Builder
  transportChip(mode: string, label: string) {
    Text(label)
      .fontSize(13)
      .fontFamily(this.appFontFamily(label))
      .fontWeight(this.appFontWeight())
      .fontColor(this.quickshareTransport === mode
        ? onAccentColor(this.accentOrPrimary()) : hwTextPrimary(this.isDarkMode))
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .borderRadius(HwRadius.pill)
      .backgroundColor(this.quickshareTransport === mode
        ? this.accentOrPrimary() : withAlpha(HwColor.textPrimary, 0.06))
      .border({ width: 1, color: this.quickshareTransport === mode
        ? Color.Transparent : resolveGlassBorderColor(this.isDarkMode, this.accentOrPrimary()) })
      .onClick((): void => {
        this.quickshareTransport = mode;
        this.quickshareWlanDirect = mode === 'direct';
        this.persistSettings();
      })
  }

  @Builder
  wlanDirectRow() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: HwSpace.md }) {
        Column({ space: 4 }) {
          Text('Quick Share 传输方式')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily('Quick Share 传输方式'))
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text($r('app.string.settings_transport_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('自动：发送前探测对端是否可达，不可达才走蓝牙引导 + WLAN 直连；仅局域网：不建立 WLAN 直连；WLAN 直连：优先蓝牙引导 + Wi-Fi Direct'))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        Row({ space: HwSpace.sm }) {
          this.transportChip('auto', '自动')
          this.transportChip('lan', '仅局域网')
          this.transportChip('direct', 'WLAN 直连')
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
  }


  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(17)
      .fontWeight(FontWeight.Medium)
      .fontColor(hwTextPrimary(this.isDarkMode))
      .width('100%')
      .margin({ top: 8 })
      .fontFamily(this.appFontFamily(title))
  }

  @Builder
  appearanceRow() {
    CardSurface({ radius: HwRadius.control }) {
      Row({ space: 12 }) {
        IconCircleButton({ symbol: $r('sys.symbol.paintpalette'), buttonSize: 36, iconSize: 18 })
        Column({ space: 2 }) {
          Text('外观设置')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(hwTextPrimary(this.isDarkMode))
            .fontFamily(this.appFontFamily('外观设置'))
          Text('字体、字号、字重与背景图')
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('字体、字号、字重与背景图'))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([hwTextSecondary(this.isDarkMode)])
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.control)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
      .onClick(() => {
        router.pushUrl({ url: 'pages/AppearanceSettingsPage' }).catch((error: BusinessError): void => {
          Lg.w('Appearance route failed: ' + error.message);
        });
      })
    }
  }

  @Builder
  logRow() {
    CardSurface({ radius: HwRadius.control }) {
      Row({ space: 12 }) {
        IconCircleButton({ symbol: $r('sys.symbol.doc_text'), buttonSize: 36, iconSize: 18 })
        Column({ space: 2 }) {
          Text('保存诊断日志')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(hwTextPrimary(this.isDarkMode))
            .fontFamily(this.appFontFamily('保存诊断日志'))
          Text($r('app.string.settings_logs_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('导出应用内采集的日志到下载文件夹'))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([hwTextSecondary(this.isDarkMode)])
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.control)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
      .onClick(() => {
        const context = getContext(this) as common.UIAbilityContext;
        Lg.i('[SETTINGS] 用户请求保存诊断日志');
        Lg.saveCurrent(context).then((ok: boolean): void => {
          if (ok) {
            promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '日志已保存到下载文件夹', duration: 2000 });
          } else {
            promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '已取消保存', duration: 1500 });
          }
        }).catch((): void => {
          promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '保存失败，请重试', duration: 2000 });
        });
      })
    }
  }

  @Builder
  aboutRow() {
    CardSurface({ radius: HwRadius.control }) {
      Row({ space: 12 }) {
        IconCircleButton({ symbol: $r('sys.symbol.info_circle'), buttonSize: 36, iconSize: 18 })
        Column({ space: 2 }) {
          Text('关于')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(hwTextPrimary(this.isDarkMode))
            .fontFamily(this.appFontFamily('关于'))
          Text('版本信息、开源与版权说明')
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('版本信息、开源与版权说明'))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([hwTextSecondary(this.isDarkMode)])
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.control)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
      .onClick(() => {
        router.pushUrl({ url: 'pages/AboutPage' }).catch((error: BusinessError): void => {
          Lg.w('About route failed: ' + error.message);
        });
      })
    }
  }

  @Builder
  btMacCard() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 8 }) {
        Text($r('app.string.settings_bt_title'))
          .fontSize(13)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('Windows Nearby 蓝牙 MAC 地址'))
          .fontWeight(this.appFontWeight())
          .width('100%')
        TextInput({ text: this.btMac, placeholder: 'AA:BB:CC:DD:EE:FF' })
          .caretColor(this.accentOrPrimary())
          .width('100%')
          .height(44)
          .fontSize(15)
          .fontColor(hwTextPrimary(this.isDarkMode))
          .backgroundColor(hwSurface(this.isDarkMode))
          .borderRadius(HwRadius.control)
          .onChange((value: string) => {
            this.btMac = value;
            this.persistSettings();
          })
        Text($r('app.string.settings_bt_description'))
          .fontSize(11)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('用于接收 Windows 发送的文件。Windows 用该地址通过蓝牙连手机；请在 设置→关于本机→状态信息 中找“蓝牙地址”填写。'))
          .fontWeight(this.appFontWeight())
          .width('100%')
          .lineHeight(15)
        if (this.btMac.trim().length === 0) {
          Text($r('app.string.settings_bt_missing'))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(hwDanger(this.isDarkMode))
            .fontFamily(this.appFontFamily('未填写蓝牙 MAC 地址：Windows 只能“扫到”本机但无法连接发送文件。请填入手机真实蓝牙地址后再试。'))
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
  }

  @Builder
  wifiUpgradeRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text($r('app.string.settings_wifi_title'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text($r('app.string.settings_wifi_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.wifiUpgradeTcp })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.wifiUpgradeTcp = value;
            this.persistSettings();
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

  @Builder
  localSendEntry() {
    CardSurface({ radius: HwRadius.control }) {
      Row({ space: 12 }) {
        IconCircleButton({ symbol: $r('sys.symbol.share'), buttonSize: 36, iconSize: 18 })
        Column({ space: 2 }) {
          Text('LocalSend')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily('LocalSend'))
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text('局域网协议互传，独立扫描设备')
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('局域网协议互传，独立扫描设备'))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([hwTextSecondary(this.isDarkMode)])
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.control)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
      .onClick(() => {
        router.pushUrl({ url: 'pages/LocalSend' }).catch((error: BusinessError): void => {
          Lg.w('LocalSend route failed: ' + error.message);
        });
      })
    }
  }

  @Builder
  mtaEntry() {
    CardSurface({ radius: HwRadius.control }) {
      Row({ space: 12 }) {
        IconCircleButton({ symbol: $r('sys.symbol.share'), buttonSize: 36, iconSize: 18 })
        Column({ space: 4 }) {
          Text('互传联盟').fontSize(16).fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily('互传联盟')).fontColor(hwTextPrimary(this.isDarkMode))
          Text('MTA · 蓝牙发现与 WLAN 直连互传').fontSize(12).fontColor(hwTextSecondary(this.isDarkMode))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([hwTextSecondary(this.isDarkMode)])
      }.width('100%').padding(HwSpace.lg).borderRadius(HwRadius.control)
        .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
        .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
        .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
        .onClick((): void => { router.pushUrl({ url: 'pages/Mta' }).catch((error: Error): void => Lg.w(error.message)); })
    }
  }
  @Builder
  lanWebEntry() {
    CardSurface({ radius: HwRadius.control }) {
      Row({ space: 12 }) {
        IconCircleButton({ symbol: $r('sys.symbol.wifi'), buttonSize: 36, iconSize: 18 })
        Column({ space: 2 }) {
          Text('局域网网页传输')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily('局域网网页传输'))
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text('生成链接，对端在浏览器发送、接收文件')
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('生成链接，对端在浏览器发送、接收文件'))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([hwTextSecondary(this.isDarkMode)])
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.control)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
      .onClick(() => {
        router.pushUrl({ url: 'pages/LanWebTransfer' }).catch((error: BusinessError): void => {
          Lg.w('LanWebTransfer route failed: ' + error.message);
        });
      })
    }
  }
  @Builder
  quickShareEntry() {
    CardSurface({ radius: HwRadius.control }) {
      Row({ space: 12 }) {
        IconCircleButton({ symbol: $r('sys.symbol.share'), buttonSize: 36, iconSize: 18 })
        Column({ space: 2 }) {
          Text('Quick Share')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily('Quick Share'))
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text('与安卓互传文件')
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('与安卓互传文件'))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([hwTextSecondary(this.isDarkMode)])
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.control)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
      .onClick(() => {
        const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
        PermissionHelper.ensure(ctx, BLUETOOTH_AND_LOCATION_PERMISSIONS).catch((): void => undefined);
        router.pushUrl({ url: 'pages/QuickShare' }).catch((error: BusinessError): void => {
          Lg.w('Quick Share route failed: ' + error.message);
        });
      })
    }
  }

  @Builder
  windowsNearbyEntry() {
    CardSurface({ radius: HwRadius.control }) {
      Row({ space: 12 }) {
        IconCircleButton({ symbol: $r('sys.symbol.pc'), buttonSize: 36, iconSize: 18 })
        Column({ space: 2 }) {
          Text('Windows')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily('Windows'))
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text('打开 Windows Nearby Sharing')
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('打开 Windows Nearby Sharing'))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([hwTextSecondary(this.isDarkMode)])
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.control)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
      .onClick(() => {
        const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
        PermissionHelper.ensure(ctx, BLUETOOTH_AND_LOCATION_PERMISSIONS).catch((): void => undefined);
        router.pushUrl({ url: 'pages/NearSharing' }).catch((error: BusinessError): void => {
          Lg.w('Windows Nearby route failed: ' + error.message);
        });
      })
    }
  }

  /** 主题色变了：HwColor 是模块级对象，改属性不会触发刷新，靠这里重建页面 */
  onAccentColorChanged(): void {
    reloadAppTheme();
  }

  /** 当前主题色。读 accentColor 建立依赖；直接写 HwColor.primary 切色后不会重新求值 */
  private accentOrPrimary(): string {
    return this.accentColor.length > 0 ? this.accentColor : HwColor.primary;
  }

  /**
   * HDS 标题栏样式（`titleBar` 的 `style` 参数类型是 `TitleBarStyleOptions`）。
   *
   * 拆成方法而不是内联字面量，是为了**按系统版本决定要不要下发 `systemMaterialEffect`**：
   * 该字段（以及它用到的 `hdsMaterial` 命名空间）是 API 23 才有的，
   * 在 API 20~22 上求值会抛异常、导致主页渲染失败（详见 `hdsAdaptiveMaterialParams` 注释）。
   *
   * HDS 标题栏的材质与背景是分层的：
   * - `systemMaterialEffect` 作用于标题栏按钮（返回键、右侧两个菜单按钮）的沉浸光感；
   * - `scrollEffectStyle` 负责标题栏自身背景，收回去（折叠）后与二级页面顶部返回栏一致
   *   （同一套 `topBarGlassColor`：浅色白玻璃 / 深色压暗黑玻璃）。
   *
   * ⚠️ 类型必须写 `TitleBarStyleOptions`：
   * `HdsNavigationTitleStyle` 是**另一个**接口（只有 `backgroundStyle` / `contentStyle`），
   * 用它会导致「对象字面量没有对应类型」+「属性不存在」一串编译错误。
   */
  private navigationTitleStyle(): TitleBarStyleOptions {
    const style: TitleBarStyleOptions = {
      scrollEffectOpts: {
        enableScrollEffect: true,
        scrollEffectType: ScrollEffectType.COMMON_BLUR
      },
      scrollEffectStyle: {
        backgroundStyle: {
          backgroundColor: topBarGlassColor(this.isDarkMode),
          // blurRadius 同样是 API 23 起的字段；低版本会被忽略（不报错），保留即可
          blurRadius: 12
        }
      }
    };
    const material: SystemMaterialParams | undefined = hdsAdaptiveMaterialParams();
    if (material !== undefined) {
      style.systemMaterialEffect = material;
    }
    return style;
  }

  build() {
    HdsNavigation(this.pageInfos) {
      Stack({ alignContent: Alignment.TopStart }) {
        // 主题色依赖：切色时让整页重新求值（零尺寸，不参与布局）
        AccentColorSentinel()
        AppBackground()
        this.paneTabs()
        // 全局兜底提示：无论当前停在哪个页签，收到动态照片都会弹「保存到图库」提示框
        // （卡片只在「聚合」页挂载，用户停在别的页签时不会出现）。
        PendingDynamicPhotoWatcher()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .bindSheet($$this.showPinEntrySheet, this.pinEntrySheetContent(), {
        height: SheetSize.MEDIUM,
        dragBar: true,
        showClose: true,
        onDisappear: (): void => this.finishPinEntry(false)
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(resolvePageBackground(this.isDarkMode, this.pageBackground))
    .titleBar({
      avoidLayoutSafeArea: true,
      style: this.navigationTitleStyle(),
      content: {
        title: {
          mainTitle: '羊绒互传',
          subTitle: this.subTitleText()
        },
        menu: {
          value: this.aggregateMenus()
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.FREE)
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideToolBar(true, true)
    .bindToScrollable([this.transferScroller, this.aggregateScroller, this.recordScroller, this.settingsScroller])
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
    .bindSheet($$this.showSolutionSheet, this.solutionSheetContent(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      // 必须显式透明：BindOptions.backgroundColor 默认是 Color.White，
      // 而沉浸光感的视觉层级位于 backgroundColor 之下，白底会把材质整块盖住
      backgroundColor: Color.Transparent,
      blurStyle: sheetBlurStyle(),
      systemMaterial: sheetSystemMaterial()
    })
  }

  @Builder
  solutionSheetContent() {
    // 半模态面板同样不在「非选择类组件的内容区生效范围」内，
    // 用 MaterialSheetPanel 的 Toggle 承载层铺满整块面板，材质才画得出来
    MaterialSheetPanel() {
      SolutionPanel()
    }
  }

  @Builder
  pinEntrySheetContent() {
    Column({ space: 16 }) {
      Text('输入对端接收 PIN').fontSize(20).fontWeight(FontWeight.Medium)
        .fontColor(hwTextPrimary(this.isDarkMode))
      Text('请输入接收设备上设置的 PIN，确认后继续发送。')
        .fontSize(14).fontColor(hwTextSecondary(this.isDarkMode))
      TextInput({ text: this.pinEntryValue, placeholder: '接收 PIN' })
        .caretColor(this.accentOrPrimary())
        .height(48).maxLength(32)
        .onChange((entered: string): void => { this.pinEntryValue = entered; })
      Row({ space: 12 }) {
        Button('取消', { type: ButtonType.Capsule }).layoutWeight(1)
          .onClick((): void => this.finishPinEntry(false))
        Button('继续发送', { type: ButtonType.Capsule }).layoutWeight(1)
          .enabled(this.pinEntryValue.trim().length > 0)
          .backgroundColor(resolvePrimaryButtonColor(this.isDarkMode, this.accentOrPrimary()))
          .onClick((): void => this.finishPinEntry(true))
      }.width('100%')
    }.width('100%').padding(24)
  }

  private finishPinEntry(accepted: boolean): void {
    const taskId: string = this.pinEntryTaskId;
    const entered: string = this.pinEntryValue.trim();
    this.showPinEntrySheet = false;
    this.pinEntryTaskId = '';
    this.pinEntryValue = '';
    if (taskId.length > 0) {
      PinDialogGuard.end();
      this.services?.transfer.submitPinEntry(taskId, accepted && entered.length > 0 ? entered : null);
    }
  }

  private persistSettings(): void {
    const context = getContext(this) as common.UIAbilityContext;
    SettingsStore.save(context, {
      alias: this.alias.length > 0 ? this.alias : '羊绒互传',
      requirePin: this.requirePin,
      alwaysVisible: this.visible,
      quickshareWlanDirect: this.quickshareTransport === 'direct',
      quickshareTransport: parseTransportMode(this.quickshareTransport),
      btMac: this.btMac,
      wifiUpgradeTcp: this.wifiUpgradeTcp,
      encryptionEnabled: this.encryptionEnabled,
      keepAlive: this.keepAlive,
      dynamicPhotoEnabled: this.dynamicPhotoEnabled,
      defaultLivePhotoFormat: this.defaultLivePhotoFormat,
      hdrVividEnabled: this.hdrVividEnabled,
      photoExifKeep: this.photoExifKeep,
      hdrSkipSystemReencode: this.hdrSkipSystemReencode,
      skipDownloadCopyForGalleryPhotos: this.skipDownloadCopyForGalleryPhotos,
      aggregateAsHome: this.aggregateAsHome,
      hideTransferPage: this.aggregateAsHome && this.hideTransferPage
    });
  }

  private onWindowsNearbyLiveChanged(): void {
    const context = getContext(this) as common.UIAbilityContext;
    WindowsNearbyHistory.load(context).then((): void => {
      this.windowsNearbyRecords = WindowsNearbyHistory.list();
    }).catch((): void => undefined);
  }

  private parseLiveState(): WindowsNearbyLiveState {
    const raw = this.windowsNearbyLive;
    if (typeof raw === 'string' && raw.length > 0) {
      try {
        const value = JSON.parse(raw) as WindowsNearbyLiveState;
        if (value !== undefined && value !== null) {
          return value;
        }
      } catch (error) {
        // ignore invalid JSON
      }
    }
    return JSON.parse(EMPTY_WINDOWS_NEARBY_LIVE) as WindowsNearbyLiveState;
  }

  private hasWindowsNearbyLiveContent(): boolean {
    const live = this.parseLiveState();
    return live.peer.length > 0 || live.percent > 0 || live.files.length > 0;
  }

  private openFileByPath(path: string): void {
    if (path.length === 0) {
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '文件路径为空', duration: 2000 });
      return;
    }
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const uri: string = path.startsWith('file://') ? path : fileUri.getUriFromPath(path);
      ctx.startAbility({
        action: 'ohos.want.action.viewData',
        uri,
        flags: 1,
        parameters: { 'ohos.aafwk.param.bundleName': 'com.cashmere.link' }
      }).catch((error: BusinessError): void => {
        promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '无法打开：' + (error.message ?? ''), duration: 2000 });
      });
    } catch (error) {
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '无法打开文件', duration: 2000 });
    }
  }

  private windowsNearbyTime(ts: number): string {
    const d = new Date(ts);
    const pad = (v: number): string => v < 10 ? '0' + v : String(v);
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  private onTransferEvent(event: TransferEvent): void {
    this.tasks = this.services !== undefined ? this.services.transfer.listTasks() : [];
    if (event.kind === 'pin-entry') {
      if (this.pinEntryTaskId.length > 0 || !PinDialogGuard.tryBegin()) {
        this.services?.transfer.submitPinEntry(event.task.id, null);
      } else {
        this.pinEntryTaskId = event.task.id;
        this.pinEntryValue = '';
        this.showPinEntrySheet = true;
      }
    }
    if (this.pinEntryTaskId === event.task.id && event.task.state !== 'awaiting-pin') {
      this.finishPinEntry(false);
    }
    if (event.kind === 'pin-request') {
      this.showPinDialog(event.task);
    }
    // 接收完成提示：统一收敛到主页，弹「接收完成」对话框（含文件名与「打开」），
    // 并对 receivedFiles 为空的情况用 task.files 兜底，避免显示“已接收 0 个文件”。
    //
    // 首次接收时「保存位置」dialog 会以 modal UIExtension 占据前台，直接在此弹「接收完成」
    // 框会被 ArkUI 以 “prohibited add child ... modalUiextension count is : 1” 抑制/遮挡，
    // 导致看不到结束提醒（文件其实已落盘）。这延迟到 modal 完全退出后再弹，保证一定可见。
    if (event.kind === 'completed' && event.task.direction === 'receive' && event.task.device.protocol === 'localsend') {
      setTimeout((): void => {
        this.showReceiveCompletedDialog(event.task);
      }, 420);
    }
    if (event.kind === 'failed' && event.task.direction === 'send') {
      const reason = event.task.error.length > 0 ? event.task.error : '未知错误';
      promptAction.showDialog({
        systemMaterial: dialogSystemMaterial(),
        title: '发送失败',
        message: '向「' + event.task.device.name + '」发送失败：' + reason + '\n\n已保留所选文件，点击设备即可重试。',
        buttons: [{ text: '知道了', color: HwColor.primary }]
      }).catch((dialogError: BusinessError): void => {
        Lg.w('send-fail dialog failed: ' + dialogError.message);
      });
    }
  }

  private showReceiveCompletedDialog(task: TransferTask): void {
    const incoming = task.receivedFiles;
    const names: string[] = incoming.length > 0
      ? incoming.map((file: IncomingFile): string => file.name)
      : task.files.map((file: OutgoingFile): string => file.name);
    const count = incoming.length > 0 ? incoming.length : task.files.length;
    const firstPath = incoming.length > 0 ? (incoming[0]?.savedPath ?? '') : '';
    const dirName = firstPath.length > 0 ? firstPath.substring(0, firstPath.lastIndexOf('/')) : '应用目录';
    const title = '接收完成';
    const message = '已接收 ' + count + ' 个文件' +
      (names.length > 0 ? '：' + names.join('、') : '') +
      (firstPath.length > 0 ? '\n已保存（' + dirName + '）' : '');
    if (firstPath.length > 0) {
      promptAction.showDialog({
        systemMaterial: dialogSystemMaterial(),
        title,
        message,
        buttons: [
          { text: '打开', color: HwColor.primary },
          { text: '确认', color: HwColor.textSecondary }
        ]
      }).then((result: promptAction.ShowDialogSuccessResponse): void => {
        if (result.index === 0) {
          this.openFileByPath(firstPath);
        }
      }).catch((dialogError: BusinessError): void => {
        Lg.w('receive-complete dialog failed: ' + dialogError.message);
      });
    } else {
      promptAction.showDialog({
        systemMaterial: dialogSystemMaterial(),
        title,
        message,
        buttons: [{ text: '确认', color: HwColor.primary }]
      }).catch((dialogError: BusinessError): void => {
        Lg.w('receive-complete dialog failed: ' + dialogError.message);
      });
    }
  }

  private showPinDialog(task: TransferTask): void {
    if (!PinDialogGuard.tryBegin()) {
      return;
    }
    promptAction.showDialog({
      systemMaterial: dialogSystemMaterial(),
      title: task.direction === 'receive' ? '接收请求' : '发送确认',
      message: task.direction === 'receive'
        ? (task.pin.length > 0
          ? `收到来自「${task.device.name}」的传输请求，共 ${task.files.length} 个文件。\n双方 PIN：${task.pin}\n请核对对端 PIN 一致后确认接收。`
          : `收到来自「${task.device.name}」的传输请求，共 ${task.files.length} 个文件。是否接收？`)
        : `正在发送给「${task.device.name}」。请确认双方设备显示的 PIN 均为 ${task.pin}，确认后开始传输。`,
      buttons: [
        { text: '拒绝', color: HwColor.textSecondary },
        { text: '确认', color: HwColor.primary }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      PinDialogGuard.end();
      this.services?.transfer.confirmPin(task.id, result.index === 1);
    }).catch(() => {
      PinDialogGuard.end();
      this.services?.transfer.confirmPin(task.id, false);
    });
  }

}








