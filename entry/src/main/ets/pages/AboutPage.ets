import { router } from '@kit.ArkUI';
import { bundleManager, common, Want } from '@kit.AbilityKit';
import { HwColor, HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwPrimary, hwSurface, hwGlassBorder, reloadAppTheme, resolvePageBackground, topBarGlassColor, resolvePrimaryColor } from '../utils/DesignTokens';
import { cardGlassEffect, sheetBlurStyle, sheetSystemMaterial, cardGlassBorderColor, cardGlassShadow } from '../utils/SystemMaterial';
import { IconCircleButton } from '../components/IconCircleButton';
import { AppBackground } from '../components/AppBackground';
import { SolutionPanel } from '../components/SolutionPanel';
import { CardSurface } from '../components/CardSurface';
import { AccentColorSentinel, MaterialSheetPanel } from '../components/MaterialCard';

@Entry
@Component
struct AboutPage {
  /** 主题色变化时触发重建，让 HwColor.primary 与选中态取到新色值 */
  @StorageProp('accentColor') @Watch('onAccentColorChanged') accentColor: string = '';
  /** 页面底色（由 applyAppTheme 发布）。直接读 HwColor.background 登记不上依赖 */
  @StorageProp('pageBackground') pageBackground: string = '';
  @StorageLink('fontMode') fontMode: string = 'system';
  @StorageLink('fontFamilyEn') fontFamilyEn: string = 'system';
  @StorageLink('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageLink('fontWeightMode') fontWeightMode: string = 'system';
  @StorageLink('fontWeightValue') fontWeightValue: number = 400;
  @StorageLink('immersiveLightEnabled') immersiveLightEnabled: boolean = true;
  @StorageLink('beautifulCards') beautifulCards: boolean = false;
  @StorageLink('classicCards') classicCards: boolean = false;
  @StorageLink('cardShadowBorder') cardShadowBorder: boolean = true;
  @StorageLink('experimentalCards') experimentalCards: boolean = false;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  @State versionName: string = '';
  @State versionCode: number = 0;
  // 是否显示弹窗（单 sheet，避免多 bindSheet 冲突）。
  @State showSheet: boolean = false;
  // 弹窗模式：1=解决方案，2=开源相关。
  @State sheetMode: number = 0;

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
    this.versionName = this.readVersionName();
    this.versionCode = this.readVersionCode();
  }

  readVersionName(): string {
    try {
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION
      );
      return bundleInfo.versionName;
    } catch (err) {
      return '1.0.0';
    }
  }

  readVersionCode(): number {
    try {
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION
      );
      return bundleInfo.versionCode;
    } catch (err) {
      return 0;
    }
  }

  openUrl(url: string): void {
    if (url.length === 0) {
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url
    };
    context.startAbility(want).catch((err: Error) => {
    });
  }

  @Builder
  solutionRow() {
    Row({ space: 10 }) {
      Text('解决方案')
        .fontFamily(this.appFontFamily('解决方案'))
        .fontWeight(this.appFontWeight())
        .fontSize(15)
        .fontColor(hwTextPrimary(this.isDarkMode))
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.questionmark_circle'))
        .fontSize(16)
        .fontColor([hwTextSecondary(this.isDarkMode)])
    }
    .width('100%')
    .padding(HwSpace.lg)
    .onClick(() => {
      this.sheetMode = 1;
      this.showSheet = true;
    })
  }

  @Builder
  openSourceRow() {
    Row({ space: 10 }) {
      Text('开源相关')
        .fontFamily(this.appFontFamily('开源相关'))
        .fontWeight(this.appFontWeight())
        .fontSize(15)
        .fontColor(hwTextPrimary(this.isDarkMode))
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([hwTextSecondary(this.isDarkMode)])
    }
    .width('100%')
    .padding(HwSpace.lg)
    .onClick(() => {
      this.sheetMode = 2;
      this.showSheet = true;
    })
  }

  @Builder
  feedbackGroupRow() {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text('反馈群')
          .fontFamily(this.appFontFamily('反馈群'))
          .fontWeight(this.appFontWeight())
          .fontSize(15)
          .fontColor(hwTextPrimary(this.isDarkMode))
          .width('100%')
        Text('1106392217')
          .fontFamily(this.appFontFamily('1106392217'))
          .fontWeight(this.appFontWeight())
          .fontSize(13)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([hwTextSecondary(this.isDarkMode)])
    }
    .width('100%')
    .padding(HwSpace.lg)
    .onClick(() => {
      this.openUrl('https://qm.qq.com/q/IlQBomu8ge');
    })
  }

  @Builder
  openSourceCard(title: string, url: string, subtitle: string) {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Text(title)
            .fontFamily(this.appFontFamily(title))
            .fontWeight(this.appFontWeight())
            .fontSize(15)
            .fontColor(hwTextPrimary(this.isDarkMode))
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor([hwTextSecondary(this.isDarkMode)])
        }
        .width('100%')

        Text(url)
          .fontFamily(this.appFontFamily(url))
          .fontWeight(this.appFontWeight())
          .fontSize(13)
          .fontColor(resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(subtitle)
          .fontFamily(this.appFontFamily(subtitle))
          .fontWeight(this.appFontWeight())
          .fontSize(11)
          .fontColor(hwTextSecondary(this.isDarkMode))
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
      .onClick(() => {
        this.openUrl(url);
      })
    }
  }

  @Builder
  openSourceSheet() {
    Column({ space: 12 }) {
      Text('开源相关')
        .fontFamily(this.appFontFamily('开源相关'))
        .fontWeight(this.appFontWeight())
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(hwTextPrimary(this.isDarkMode))
        .width('100%')

      this.openSourceCard('LocalSend', 'https://github.com/localsend/localsend', 'Apache-2.0 license')
      this.openSourceCard('Nearby', 'https://github.com/google/nearby', 'Apache-2.0 license')
      this.openSourceCard('HandySend · MTA 实现', 'https://gitcode.com/springtwr/HandySend', 'Apache-2.0 license · 保留上游 MTA 收发链路')
      Button('查看 MTA 开源许可证').onClick((): void => {
        router.pushUrl({ url: 'pages/MtaLicenses' }).catch((): void => {});
      })
      this.openSourceCard('本项目地址', 'https://github.com/MrCashmere/CLink', 'GNU General Public License version 3.0 (GPL v3)')
    }
    .width('100%')
    .padding({ left: HwSpace.lg, right: HwSpace.lg, top: 16, bottom: 32 })
  }

  @Builder
  sheetContent() {
    // 半模态面板不在「非选择类组件的内容区生效范围」内，
    // 用 MaterialSheetPanel 的 Toggle 承载层铺满整块面板，材质才画得出来
    MaterialSheetPanel() {
      if (this.sheetMode === 1) {
        SolutionPanel()
      } else if (this.sheetMode === 2) {
        this.openSourceSheet()
      }
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
    Stack() {
      // 主题色依赖：切色时让整页重新求值（零尺寸，不参与布局）
      AccentColorSentinel()
      AppBackground()
      Column() {
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
          Text('关于')
            .fontFamily(this.appFontFamily('关于'))
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

        Scroll() {
          Column({ space: 24 }) {
            Column({ space: 10 }) {
              Image($r('app.media.app_icon'))
                .width(96)
                .height(96)
                .borderRadius(24)
                .objectFit(ImageFit.Cover)
              Text('羊绒互传')
                .fontFamily(this.appFontFamily('羊绒互传'))
                .fontWeight(this.appFontWeight())
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor(hwTextPrimary(this.isDarkMode))
              Text(`版本 ${this.versionName}`)
                .fontFamily(this.appFontFamily(`版本 ${this.versionName}`))
                .fontWeight(this.appFontWeight())
                .fontSize(14)
                .fontColor(hwTextSecondary(this.isDarkMode))
              Text(`(${this.versionCode})`)
                .fontFamily(this.appFontFamily(`(${this.versionCode})`))
                .fontWeight(this.appFontWeight())
                .fontSize(12)
                .fontColor(hwTextSecondary(this.isDarkMode))
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .margin({ top: 28 })

            CardSurface({ radius: HwRadius.card }) {
              Column({ space: 0 }) {
                this.solutionRow()
                Divider()
                  .color('#14000000')
                  .margin({ left: HwSpace.lg, right: HwSpace.lg })
                this.openSourceRow()
                Divider()
                  .color('#14000000')
                  .margin({ left: HwSpace.lg, right: HwSpace.lg })
                this.feedbackGroupRow()
              }
              .width('100%')
              .borderRadius(HwRadius.card)
              .backgroundColor(Color.Transparent)
              .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
              .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
              .clip(true)
              .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
            }
          }
          .width('100%')
          .padding({ left: HwSpace.lg, right: HwSpace.lg, bottom: 24 })
        }
        .layoutWeight(1)

        Text('一个基于开源协议实现的本地互传工具')
          .fontFamily(this.appFontFamily('一个基于开源协议实现的本地互传工具'))
          .fontWeight(this.appFontWeight())
          .fontSize(12)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .textAlign(TextAlign.Center)
          .lineHeight(18)
          .width('100%')
          .padding({ left: HwSpace.xl, right: HwSpace.xl, bottom: this.navigationBarHeight + 12 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(resolvePageBackground(this.isDarkMode, this.pageBackground))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet($$this.showSheet, this.sheetContent(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      // 必须显式透明：BindOptions.backgroundColor 默认是 Color.White，
      // 而沉浸光感的视觉层级位于 backgroundColor 之下，白底会把材质整块盖住
      backgroundColor: Color.Transparent,
      blurStyle: sheetBlurStyle(),
      systemMaterial: sheetSystemMaterial(),
      onDisappear: () => {
        this.sheetMode = 0;
      }
    })
    .keyboardShortcut(FunctionKey.ESC, [], () => {
      router.back();
    })
  }
}
