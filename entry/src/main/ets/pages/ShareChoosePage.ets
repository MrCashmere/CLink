import { LogCapture as Lg } from '../common/LogCapture';
import fs from '@ohos.file.fs';
import { fileUri } from '@kit.CoreFileKit';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
import { common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { OutgoingFile } from '../model/TransferModels';
import { IconCircleButton } from '../components/IconCircleButton';
import { AppBackground } from '../components/AppBackground';
import { HwColor, HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwPrimary, hwGlassBorder, reloadAppTheme, resolvePageBackground, topBarGlassColor } from '../utils/DesignTokens';
import { cardGlassEffect, toastSystemMaterial, cardGlassBorderColor, cardGlassShadow } from '../utils/SystemMaterial';
import { PermissionHelper } from '../common/PermissionHelper';
import { consumePendingShareUris, nameOfUri } from '../common/ShareHandleUtil';
import { CardSurface } from '../components/CardSurface';
import { AccentColorSentinel } from '../components/MaterialCard';

const SHARE_BT_LOCATION_PERMISSIONS: Permissions[] = [
  'ohos.permission.ACCESS_BLUETOOTH',
  'ohos.permission.APPROXIMATELY_LOCATION',
  'ohos.permission.LOCATION'
];

/**
 * 系统分享选择页。
 *
 * 从系统分享面板选择本应用后进入：展示共享文件的文件名，并提供三个通道
 * （Quick Share / Windows Nearby / LocalSend）。用户点选其中一个后，把共享
 * 文件以路由参数传给对应页面，由该页面自动载入「已选择文件」，即可直接点设备发送。
 */
@Entry
@Component
struct ShareChoosePage {
  /** 主题色变化时触发重建，让 HwColor.primary 与选中态取到新色值 */
  @StorageProp('accentColor') @Watch('onAccentColorChanged') accentColor: string = '';
  /** 页面底色（由 applyAppTheme 发布）。直接读 HwColor.background 登记不上依赖 */
  @StorageProp('pageBackground') pageBackground: string = '';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('immersiveLightEnabled') immersiveLightEnabled: boolean = true;
  @StorageLink('beautifulCards') beautifulCards: boolean = false;
  @StorageLink('classicCards') classicCards: boolean = false;
  @StorageLink('cardShadowBorder') cardShadowBorder: boolean = true;
  @StorageLink('experimentalCards') experimentalCards: boolean = false;
  @StorageLink('fontMode') fontMode: string = 'system';
  @StorageLink('fontFamilyEn') fontFamilyEn: string = 'system';
  @StorageLink('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageLink('fontWeightMode') fontWeightMode: string = 'system';
  @StorageLink('fontWeightValue') fontWeightValue: number = 400;
  @State files: OutgoingFile[] = [];

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

  aboutToAppear(): void {
    const uris = consumePendingShareUris();
    this.files = uris.map((uri: string): OutgoingFile => ({
      path: uri,
      name: nameOfUri(uri),
      size: this.sizeOf(uri),
      mime: 'application/octet-stream'
    }));
  }

  private sizeOf(uri: string): number {
    try {
      return fs.statSync(uri).size;
    } catch (error) {
      // fall through
    }
    try {
      const realPath = new fileUri.FileUri(uri).path;
      return fs.statSync(realPath).size;
    } catch (error) {
      return 0;
    }
  }

  private fileSizeText(size: number): string {
    if (size >= 1024 * 1024) {
      return (size / (1024 * 1024)).toFixed(1) + ' MB';
    }
    if (size >= 1024) {
      return Math.floor(size / 1024) + ' KB';
    }
    return size + ' B';
  }

  private goToChannel(url: string): void {
    if (this.files.length === 0) {
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '没有可发送的文件' });
      return;
    }
    const paths: string[] = [];
    const names: string[] = [];
    const sizes: number[] = [];
    for (const file of this.files) {
      paths.push(file.path);
      names.push(file.name);
      sizes.push(file.size);
    }
    router.replaceUrl({
      url: url,
      params: {
        sharePaths: paths,
        shareNames: names,
        shareSizes: sizes
      }
    }).catch((error: BusinessError): void => {
      Lg.w('ShareChoosePage route ' + url + ' failed: ' + error.message);
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '无法打开：' + error.message });
    });
  }

  private requestSharePermissions(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    PermissionHelper.ensure(ctx, SHARE_BT_LOCATION_PERMISSIONS).catch((): void => undefined);
  }

  private goQuickShare(): void {
    this.requestSharePermissions();
    this.goToChannel('pages/QuickShare');
  }

  private goWindows(): void {
    this.requestSharePermissions();
    this.goToChannel('pages/NearSharing');
  }

  private goLocalSend(): void {
    this.goToChannel('pages/LocalSend');
  }

  @Builder
  channelRow(icon: Resource, title: string, subtitle: string, action: () => void) {
    CardSurface({ radius: HwRadius.control }) {
      Row({ space: 12 }) {
        IconCircleButton({ symbol: icon, buttonSize: 36, iconSize: 18 })
        Column({ space: 2 }) {
          Text(title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily(title))
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text(subtitle)
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily(subtitle))
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
      .onClick(() => action())
    }
  }

  @Builder
  fileListCard() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 6 }) {
        Text('已收到 ' + this.files.length + ' 个文件，请选择传输方式')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.appFontFamily('已收到 个文件，请选择传输方式'))
          .fontColor(hwTextPrimary(this.isDarkMode))
          .width('100%')
        ForEach(this.files, (file: OutgoingFile) => {
          Row({ space: 8 }) {
            Text(file.name)
              .layoutWeight(1)
              .fontSize(13)
              .fontFamily(this.appFontFamily(file.name))
              .fontWeight(this.appFontWeight())
              .fontColor(hwTextPrimary(this.isDarkMode))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.fileSizeText(file.size))
              .fontSize(12)
              .fontFamily(this.appFontFamily(this.fileSizeText(file.size)))
              .fontWeight(this.appFontWeight())
              .fontColor(hwTextSecondary(this.isDarkMode))
          }
          .width('100%')
        }, (file: OutgoingFile): string => file.path + ':' + this.accentColor)
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

  /** 主题色变了：HwColor 是模块级对象，改属性不会触发刷新，靠这里重建页面 */
  onAccentColorChanged(): void {
    reloadAppTheme();
  }

  /** 当前主题色。读 accentColor 建立依赖；直接写 HwColor.primary 切色后不会重新求值 */
  private accentOrPrimary(): string {
    return this.accentColor.length > 0 ? this.accentColor : HwColor.primary;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 主题色依赖：切色时让整页重新求值（零尺寸，不参与布局）
      AccentColorSentinel()
      AppBackground()
      Column() {
        Scroll() {
          Column({ space: 12 }) {
            Blank().height(56 + this.statusBarHeight)
            this.fileListCard()
            Text('选择传输方式')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontFamily(this.appFontFamily('选择传输方式'))
              .fontColor(hwTextPrimary(this.isDarkMode))
              .width('100%')
              .padding({ left: 4 })
            this.channelRow($r('sys.symbol.share'), 'Quick Share', '与安卓设备互传文件', () => this.goQuickShare())
            this.channelRow($r('sys.symbol.pc'), 'Windows Nearby', '与电脑附近共享传输文件', () => this.goWindows())
            this.channelRow($r('sys.symbol.share'), 'LocalSend', '局域网协议互传', () => this.goLocalSend())
            this.channelRow($r('sys.symbol.share'), '互传联盟', 'MTA 附近互传', () => this.goToChannel('pages/Mta'))
          }
          .width('100%')
          .padding({ left: HwSpace.lg, right: HwSpace.lg, top: HwSpace.lg, bottom: 96 })
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
        IconCircleButton({ symbol: $r('sys.symbol.chevron_left'), glass: true, buttonSize: 40, iconSize: 20, onAction: (): void => router.back() })
        Text('系统分享')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontFamily(this.appFontFamily('系统分享'))
          .fontColor(hwTextPrimary(this.isDarkMode))
          .margin({ left: HwSpace.md })
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
  }
}
