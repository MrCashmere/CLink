import { LogCapture as Lg } from '../common/LogCapture';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
import { common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileUri } from '@kit.CoreFileKit';
import { HdsNavigation, HdsNavigationTitleMode, HdsNavigationMenuItemOptions, HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
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
import {
  HwColor,
  HwRadius,
  HwSpace,
  hwTextPrimary,
  hwTextSecondary,
  hwPrimary,
  hwPrimaryButton,
  hwOnline,
  hwDanger,
  hwSurface,
  hwGlassSurface,
  hwGlassBorder
} from '../utils/DesignTokens';
import {
  immersiveMaterialModifier,
  legacyMaterialModifier,
  isApi26OrAbove,
  isSdkAtLeast,
  sheetBlurStyle
} from '../utils/SystemMaterial';
import { IconCircleButton } from '../components/IconCircleButton';
import { AppBackground } from '../components/AppBackground';
import { SolutionPanel } from '../components/SolutionPanel';
import { TransferProgress } from './TransferProgress';
import { AggregatePage } from './AggregatePage';
import { QuickShareTransferHistory, QuickShareTransferHistoryEntry } from '../quickshare/storage/TransferHistory';
import { PinDialogGuard } from '../common/PinDialogGuard';
import {
  WindowsNearbyHistory,
  WindowsNearbyHistoryEntry,
  WindowsNearbyLiveFile,
  WindowsNearbyLiveState,
  EMPTY_WINDOWS_NEARBY_LIVE
} from '../windowsnearby/WindowsNearbyHistory';

// 蓝牙发现 / BLE 扫描所需用户授权权限，仅在点击 Quick Share / Windows 时逐项申请。
const BLUETOOTH_AND_LOCATION_PERMISSIONS: Permissions[] = [
  'ohos.permission.ACCESS_BLUETOOTH',
  'ohos.permission.APPROXIMATELY_LOCATION',
  'ohos.permission.LOCATION'
];

const BOTTOM_BAR_MARGIN: number = 12;
const TITLE_BAR_HEIGHT_FREE: number = 138; // 与 HdsNavigation FREE 模式标题栏高度保持一致，用于内容区预留空白
const TAB_BAR_CONTENT_HEIGHT: number = 56; // 页签图标+文字的可视高度（不含底部安全区）

@Component
export struct MainPage {
  pageInfos: NavPathStack = new NavPathStack();
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
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
  @State quickshareWlanDirect: boolean = false;
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
  @StorageLink('shareRequestCounter') @Watch('onShareRequest') shareRequestCounter: number = 0;
  private services?: AppServices;

  private transferListener: (event: TransferEvent) => void = (event: TransferEvent): void => {
    this.onTransferEvent(event);
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
      this.visible = settings.alwaysVisible;
      this.quickshareWlanDirect = settings.quickshareWlanDirect;
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
    // 启动时不再批量申请运行时权限；改为点击 Quick Share / Windows 时逐项申请。
    const startPromise = services !== undefined ? services.startReceive() : Promise.resolve();
    startPromise.then(() => {
      this.statusText = '等待接收';
      this.localAddress = this.services !== undefined ? this.services.localsend.getLocalAddress() : '';
    }).catch((error: BusinessError) => {
      this.statusText = `启动失败: ${error.message}`;
    });
    this.onShareRequest();
    // 静默刷新一次权限概览（只读检查，不弹窗），让设置页进去就能看到当前状态。
    this.refreshPermissionSummary();
  }

  aboutToDisappear(): void {
    if (this.services !== undefined) {
      this.services.transfer.removeListener(this.transferListener);
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
   * 重启 Quick Share / Windows Nearby / LocalSend 三种协议的广播与接收，
   * 等价于重新打开应用：先拆掉发现/广播/接收器，再按冷启动顺序重新拉起。
   */
  private restartScans(): void {
    if (this.scanRestarting) {
      return;
    }
    this.scanRestarting = true;
    const context = getContext(this) as common.UIAbilityContext;
    Lg.i('[AGGREGATE] 用户请求重启三协议广播');
    promptAction.showToast({ message: '正在重启三种协议的广播…', duration: 1500 });
    NearbyScanHub.get(context).restart().then((): void => {
      this.scanRestarting = false;
      this.localAddress = this.services !== undefined ? this.services.localsend.getLocalAddress() : '';
      this.statusText = '等待接收';
      promptAction.showToast({ message: '广播已重启', duration: 1500 });
    }).catch((error: BusinessError): void => {
      this.scanRestarting = false;
      Lg.w('[AGGREGATE] 重启三协议广播失败: ' + error.message);
      promptAction.showToast({ message: '重启失败，请重试', duration: 2000 });
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
          promptAction.showToast({ message: '权限齐全', duration: 1500 });
          return;
        }
        const names = this.permissionNames(outcome.missing);
        if (outcome.needManualGrant) {
          this.permissionSummary = '仍未授予：' + names + '。请在系统「设置 → 应用 → 羊绒互传 → 权限」中手动开启。';
          promptAction.showToast({ message: '部分权限被拒绝，需在系统设置中开启', duration: 3000 });
        } else {
          this.permissionSummary = '仍未授予：' + names;
          promptAction.showToast({ message: '仍缺少：' + names, duration: 2500 });
        }
      })
      .catch((error: BusinessError): void => {
        this.permissionChecking = false;
        this.permissionSummary = '权限检查失败，请重试';
        Lg.w('permission recheck failed: ' + error.message);
        promptAction.showToast({ message: '权限检查失败，请重试', duration: 2000 });
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

  @Builder
  tabIcon(kind: string, index: number) {
    if (kind === 'transfer') {
      SymbolGlyph($r('sys.symbol.arrow_left_arrow_right'))
        .fontSize(23)
        .fontColor([this.activeTab === index ? hwPrimary(this.isDarkMode) : hwTextSecondary(this.isDarkMode)])
    } else if (kind === 'aggregate') {
      SymbolGlyph(this.activeTab === index ? $r('sys.symbol.square_fill_grid_2x2') : $r('sys.symbol.square_grid_2x2'))
        .fontSize(23)
        .fontColor([this.activeTab === index ? hwPrimary(this.isDarkMode) : hwTextSecondary(this.isDarkMode)])
    } else if (kind === 'record') {
      SymbolGlyph(this.activeTab === index ? $r('sys.symbol.doc_text_fill') : $r('sys.symbol.doc_text'))
        .fontSize(23)
        .fontColor([this.activeTab === index ? hwPrimary(this.isDarkMode) : hwTextSecondary(this.isDarkMode)])
    } else {
      SymbolGlyph($r('sys.symbol.gearshape'))
        .fontSize(23)
        .fontColor([this.activeTab === index ? hwPrimary(this.isDarkMode) : hwTextSecondary(this.isDarkMode)])
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
        .fontColor(this.activeTab === index ? hwPrimary(this.isDarkMode) : hwTextSecondary(this.isDarkMode))
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
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          },
          lightColor: Color.White
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
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          },
          lightColor: Color.White
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
          AggregatePage({ showWebEntry: this.hideTransferPage })
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
        Column({ space: 4 }) {
          Row({ space: 8 }) {
            Text(rec.direction === 'send' ? '↑' : '↓').fontSize(14)
              .fontFamily(this.appFontFamily(rec.direction === 'send' ? '↑' : '↓')).fontWeight(this.appFontWeight())
              .fontColor(rec.direction === 'send' ? hwPrimary(this.isDarkMode) : hwOnline(this.isDarkMode))
            Text(rec.name).layoutWeight(1).fontSize(13).fontFamily(this.appFontFamily(rec.name)).fontWeight(this.appFontWeight()).fontColor(hwTextPrimary(this.isDarkMode))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.byteText(rec.size)).fontSize(12).fontFamily(this.appFontFamily(this.byteText(rec.size))).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
            if (rec.savedPath.length > 0) {
              Button('打开', { type: ButtonType.Capsule }).height(24).fontSize(11).fontFamily(this.appFontFamily('打开'))
                .backgroundColor(hwPrimaryButton(this.isDarkMode)).fontColor(Color.White)
                .onClick(() => this.openFileByPath(rec.savedPath))
            }
          }.width('100%')
          Text((rec.direction === 'send' ? '发送给 ' : '来自 ') + rec.peer + ' · ' + this.quickShareTime(rec.completedAt))
            .fontSize(11).fontFamily(this.appFontFamily((rec.direction === 'send' ? '发送给 ' : '来自 ') + rec.peer + ' · ' + this.quickShareTime(rec.completedAt))).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).width('100%')
        }
        .width('100%')
        .padding(HwSpace.md)
        .borderRadius(HwRadius.control)
        .backgroundColor(hwGlassSurface(this.isDarkMode))
        .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
        .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
        .clip(true)
      }, (rec: QuickShareTransferHistoryEntry): string => rec.id)
    }
    .width('100%')
  }

  @Builder
  windowsNearbyHistory() {
    Column({ space: 12 }) {
      Text('Windows Nearby 记录').fontSize(15).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('Windows Nearby 记录')).fontColor(hwTextPrimary(this.isDarkMode)).width('100%')
      ForEach(this.windowsNearbyRecords, (rec: WindowsNearbyHistoryEntry): void => {
        Column({ space: 4 }) {
          Row({ space: 8 }) {
            Text(rec.direction === 'send' ? '↑' : '↓').fontSize(14)
              .fontFamily(this.appFontFamily(rec.direction === 'send' ? '↑' : '↓')).fontWeight(this.appFontWeight())
              .fontColor(rec.direction === 'send' ? hwPrimary(this.isDarkMode) : hwOnline(this.isDarkMode))
            Text(rec.name).layoutWeight(1).fontSize(13).fontFamily(this.appFontFamily(rec.name)).fontWeight(this.appFontWeight()).fontColor(hwTextPrimary(this.isDarkMode))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.byteText(rec.size)).fontSize(12).fontFamily(this.appFontFamily(this.byteText(rec.size))).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
            Button('打开', { type: ButtonType.Capsule }).height(24).fontSize(11).fontFamily(this.appFontFamily('打开'))
              .backgroundColor(hwPrimaryButton(this.isDarkMode)).fontColor(Color.White)
              .onClick(() => this.openFileByPath(rec.savedPath))
          }.width('100%')
          Text((rec.direction === 'send' ? '发送给 ' : '来自 ') + rec.peer + ' · ' + this.windowsNearbyTime(rec.completedAt))
            .fontSize(11).fontFamily(this.appFontFamily((rec.direction === 'send' ? '发送给 ' : '来自 ') + rec.peer + ' · ' + this.windowsNearbyTime(rec.completedAt))).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).width('100%')
        }
        .width('100%')
        .padding(HwSpace.md)
        .borderRadius(HwRadius.control)
        .backgroundColor(hwGlassSurface(this.isDarkMode))
        .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
        .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
        .clip(true)
      }, (rec: WindowsNearbyHistoryEntry): string => rec.id)
    }
    .width('100%')
  }

  @Builder
  windowsNearbyLiveCard(live: WindowsNearbyLiveState) {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('Windows Nearby 传输').fontSize(15).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('Windows Nearby 传输')).fontColor(hwTextPrimary(this.isDarkMode)).layoutWeight(1)
        if (live.completed) {
          Text('已完成').fontSize(12).fontFamily(this.appFontFamily('已完成')).fontWeight(this.appFontWeight()).fontColor(hwOnline(this.isDarkMode))
        } else if (live.percent > 0) {
          Text('接收中 ' + Math.floor(live.percent) + '%').fontSize(12).fontFamily(this.appFontFamily('接收中 %')).fontWeight(this.appFontWeight()).fontColor(hwPrimary(this.isDarkMode))
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
                .backgroundColor(hwPrimaryButton(this.isDarkMode)).fontColor(Color.White)
                .onClick(() => this.openFileByPath(file.savedPath))
            }.width('100%')
          }, (file: WindowsNearbyLiveFile): string => file.savedPath + ':' + file.name)
        }.width('100%')
      }
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
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
    Column({ space: 8 }) {
      Text('设备名称')
        .fontSize(13)
        .fontColor(hwTextSecondary(this.isDarkMode))
        .fontFamily(this.appFontFamily('设备名称'))
        .fontWeight(this.appFontWeight())
        .width('100%')
      TextInput({ text: this.alias, placeholder: '设备名称' })
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
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  permissionCheckRow() {
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
          .color(hwPrimary(this.isDarkMode))
      } else {
        Button('检查')
          .fontSize(13)
          .fontColor(Color.White)
          .height(32)
          .padding({ left: 14, right: 14 })
          .backgroundColor(hwPrimaryButton(this.isDarkMode))
          .borderRadius(HwRadius.pill)
          .onClick(() => {
            this.runPermissionCheck();
          })
      }
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.control)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  pinRow() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('传输前要求PIN验证')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.appFontFamily('传输前要求PIN验证'))
          .fontColor(hwTextPrimary(this.isDarkMode))
        Text('双方显示相同PIN，确认后传输，防止中间人攻击')
          .fontSize(12)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('双方显示相同PIN，确认后传输，防止中间人攻击'))
          .fontWeight(this.appFontWeight())
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.requirePin })
        .selectedColor(hwPrimary(this.isDarkMode))
        .onChange((value: boolean) => {
          this.requirePin = value;
          this.persistSettings();
        })
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  encryptionRow() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('LocalSend 加密传输 (TLS)')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.appFontFamily('LocalSend 加密传输 (TLS)'))
          .fontColor(hwTextPrimary(this.isDarkMode))
        Text('启用后本机 LocalSend 用 HTTPS 接收；若对端不支持加密则由对端决定连接方式')
          .fontSize(12)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('启用后本机 LocalSend 用 HTTPS 接收；若对端不支持加密则由对端决定连接方式'))
          .fontWeight(this.appFontWeight())
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.encryptionEnabled })
        .selectedColor(hwPrimary(this.isDarkMode))
        .onChange((value: boolean) => {
          this.encryptionEnabled = value;
          this.persistSettings();
        })
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  keepAliveRow() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('长时任务保活')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.appFontFamily('长时任务保活'))
          .fontColor(hwTextPrimary(this.isDarkMode))
        Text('开启后，进入后台也能持续运行以接收对端发送的文件，不再被系统短暂冻结')
          .fontSize(12)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('开启后，进入后台也能持续运行以接收对端发送的文件，不再被系统短暂冻结'))
          .fontWeight(this.appFontWeight())
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.keepAlive })
        .selectedColor(hwPrimary(this.isDarkMode))
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
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  visibleRow() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('本机可见')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.appFontFamily('本机可见'))
          .fontColor(hwTextPrimary(this.isDarkMode))
        Text('持续广播 mDNS / BLE，让附近设备随时发现本机并发送文件')
          .fontSize(12)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('持续广播 mDNS / BLE，让附近设备随时发现本机并发送文件'))
          .fontWeight(this.appFontWeight())
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.visible })
        .selectedColor(hwPrimary(this.isDarkMode))
        .onChange((value: boolean) => {
          this.visible = value;
          if (value) {
            this.services?.refreshAliasFingerprint().then(() => {
              this.services?.localsend.setVisible(true);
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
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  aggregateAsHomeRow() {
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
        .selectedColor(hwPrimary(this.isDarkMode))
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
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  hideTransferRow() {
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
        .selectedColor(hwPrimary(this.isDarkMode))
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
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  wlanDirectRow() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('Quick Share 蓝牙BLE传输优先')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.appFontFamily('Quick Share 蓝牙BLE传输优先'))
          .fontColor(hwTextPrimary(this.isDarkMode))
        Text('开启后仅可通过蓝牙接收文件，无法发送文件，仅在默认模式失效时启用')
          .fontSize(12)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('开启后仅可通过蓝牙接收文件，无法发送文件，仅在默认模式失效时启用'))
          .fontWeight(this.appFontWeight())
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.quickshareWlanDirect })
        .selectedColor(hwPrimary(this.isDarkMode))
        .onChange((value: boolean) => {
          this.quickshareWlanDirect = value;
          this.persistSettings();
        })
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
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
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
    .onClick(() => {
      router.pushUrl({ url: 'pages/AppearanceSettingsPage' }).catch((error: BusinessError): void => {
        Lg.w('Appearance route failed: ' + error.message);
      });
    })
  }

  @Builder
  logRow() {
    Row({ space: 12 }) {
      IconCircleButton({ symbol: $r('sys.symbol.doc_text'), buttonSize: 36, iconSize: 18 })
      Column({ space: 2 }) {
        Text('保存诊断日志')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(hwTextPrimary(this.isDarkMode))
          .fontFamily(this.appFontFamily('保存诊断日志'))
        Text('导出应用内采集的日志到下载文件夹（含 Windows Nearby 广播/扫描）')
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
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
    .onClick(() => {
      const context = getContext(this) as common.UIAbilityContext;
      Lg.i('[SETTINGS] 用户请求保存诊断日志');
      Lg.saveCurrent(context).then((ok: boolean): void => {
        if (ok) {
          promptAction.showToast({ message: '日志已保存到下载文件夹', duration: 2000 });
        } else {
          promptAction.showToast({ message: '已取消保存', duration: 1500 });
        }
      }).catch((): void => {
        promptAction.showToast({ message: '保存失败，请重试', duration: 2000 });
      });
    })
  }

  @Builder
  aboutRow() {
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
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
    .onClick(() => {
      router.pushUrl({ url: 'pages/AboutPage' }).catch((error: BusinessError): void => {
        Lg.w('About route failed: ' + error.message);
      });
    })
  }

  @Builder
  btMacCard() {
    Column({ space: 8 }) {
      Text('Windows Nearby 蓝牙 MAC 地址')
        .fontSize(13)
        .fontColor(hwTextSecondary(this.isDarkMode))
        .fontFamily(this.appFontFamily('Windows Nearby 蓝牙 MAC 地址'))
        .fontWeight(this.appFontWeight())
        .width('100%')
      TextInput({ text: this.btMac, placeholder: 'AA:BB:CC:DD:EE:FF' })
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
      Text('用于接收 Windows 发送的文件。Windows 用该地址通过蓝牙连手机；请在 设置→关于本机→状态信息 中找“蓝牙地址”填写。')
        .fontSize(11)
        .fontColor(hwTextSecondary(this.isDarkMode))
        .fontFamily(this.appFontFamily('用于接收 Windows 发送的文件。Windows 用该地址通过蓝牙连手机；请在 设置→关于本机→状态信息 中找“蓝牙地址”填写。'))
        .fontWeight(this.appFontWeight())
        .width('100%')
        .lineHeight(15)
      if (this.btMac.trim().length === 0) {
        Text('未填写蓝牙 MAC 地址：Windows 只能“扫到”本机但无法连接发送文件。请填入手机真实蓝牙地址后再试。')
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
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  wifiUpgradeRow() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('Windows Nearby 优先 Wi-Fi (TCP) 传输')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(hwTextPrimary(this.isDarkMode))
        Text('开启后，Windows 通过蓝牙发现本机时会把会话自动升级到 Wi-Fi (TCP 5040) 传输大文件；关闭则全程走蓝牙。')
          .fontSize(12)
          .fontColor(hwTextSecondary(this.isDarkMode))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.wifiUpgradeTcp })
        .selectedColor(hwPrimary(this.isDarkMode))
        .onChange((value: boolean) => {
          this.wifiUpgradeTcp = value;
          this.persistSettings();
        })
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  localSendEntry() {
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
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
    .onClick(() => {
      router.pushUrl({ url: 'pages/LocalSend' }).catch((error: BusinessError): void => {
        Lg.w('LocalSend route failed: ' + error.message);
      });
    })
  }
  @Builder
  lanWebEntry() {
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
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
    .onClick(() => {
      router.pushUrl({ url: 'pages/LanWebTransfer' }).catch((error: BusinessError): void => {
        Lg.w('LanWebTransfer route failed: ' + error.message);
      });
    })
  }
  @Builder
  quickShareEntry() {
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
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
    .onClick(() => {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      PermissionHelper.ensure(ctx, BLUETOOTH_AND_LOCATION_PERMISSIONS).catch((): void => undefined);
      router.pushUrl({ url: 'pages/QuickShare' }).catch((error: BusinessError): void => {
        Lg.w('Quick Share route failed: ' + error.message);
      });
    })
  }

  @Builder
  windowsNearbyEntry() {
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
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
    .onClick(() => {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      PermissionHelper.ensure(ctx, BLUETOOTH_AND_LOCATION_PERMISSIONS).catch((): void => undefined);
      router.pushUrl({ url: 'pages/NearSharing' }).catch((error: BusinessError): void => {
        Lg.w('Windows Nearby route failed: ' + error.message);
      });
    })
  }

  build() {
    HdsNavigation(this.pageInfos) {
      Stack({ alignContent: Alignment.TopStart }) {
        AppBackground()
        this.paneTabs()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDarkMode ? HwColor.backgroundDark : HwColor.background)
    .titleBar({
      avoidLayoutSafeArea: true,
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
      blurStyle: sheetBlurStyle()
    })
  }

  @Builder
  solutionSheetContent() {
    SolutionPanel()
  }

  private persistSettings(): void {
    const context = getContext(this) as common.UIAbilityContext;
    SettingsStore.save(context, {
      alias: this.alias.length > 0 ? this.alias : '羊绒互传',
      requirePin: this.requirePin,
      alwaysVisible: this.visible,
      quickshareWlanDirect: this.quickshareWlanDirect,
      btMac: this.btMac,
      wifiUpgradeTcp: this.wifiUpgradeTcp,
      encryptionEnabled: this.encryptionEnabled,
      keepAlive: this.keepAlive,
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
      promptAction.showToast({ message: '文件路径为空', duration: 2000 });
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
        promptAction.showToast({ message: '无法打开：' + (error.message ?? ''), duration: 2000 });
      });
    } catch (error) {
      promptAction.showToast({ message: '无法打开文件', duration: 2000 });
    }
  }

  private windowsNearbyTime(ts: number): string {
    const d = new Date(ts);
    const pad = (v: number): string => v < 10 ? '0' + v : String(v);
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  private onTransferEvent(event: TransferEvent): void {
    this.tasks = this.services !== undefined ? this.services.transfer.listTasks() : [];
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








