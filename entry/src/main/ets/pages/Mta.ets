import { router } from '@kit.ArkUI';
import { MtaPanel } from '../mta/MtaPanel';
import { AppBackground } from '../components/AppBackground';
import { IconCircleButton } from '../components/IconCircleButton';
import { AccentColorSentinel } from '../components/MaterialCard';
import { HwSpace, hwTextPrimary, reloadAppTheme, resolvePageBackground, topBarGlassColor } from '../utils/DesignTokens';

@Entry
@Component
struct MtaPage {
  @StorageProp('accentColor') @Watch('onAccentColorChanged') accentColor: string = '';
  @StorageProp('pageBackground') pageBackground: string = '';
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  @StorageProp('fontMode') fontMode: string = 'system';
  @StorageProp('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageProp('fontWeightMode') fontWeightMode: string = 'system';
  @StorageProp('fontWeightValue') fontWeightValue: number = 400;

  onAccentColorChanged(): void {
    reloadAppTheme();
  }

  private titleFontFamily(): string {
    return this.fontMode === 'custom' && this.fontFamilyZh !== 'system' && this.fontFamilyZh.length > 0
      ? this.fontFamilyZh : 'HarmonyOS Sans';
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      AccentColorSentinel()
      AppBackground()
      Column() {
        Row() {
          IconCircleButton({
            symbol: $r('sys.symbol.chevron_left'), glass: true, buttonSize: 40, iconSize: 20,
            onAction: (): void => router.back()
          })
          Text('互传联盟')
            .fontSize(20)
            .fontWeight(this.fontWeightMode === 'custom' ? this.fontWeightValue : FontWeight.Bold)
            .fontFamily(this.titleFontFamily())
            .fontColor(hwTextPrimary(this.isDarkMode))
            .margin({ left: HwSpace.md })
          Blank()
        }
        .width('100%')
        .height(56 + this.statusBarHeight)
        .padding({ left: HwSpace.lg, right: HwSpace.lg, top: this.statusBarHeight })
        .backgroundEffect({ radius: 12, color: topBarGlassColor(this.isDarkMode) })

        Scroll() {
          Column() {
            MtaPanel()
          }
          .width('100%')
          .padding({ left: HwSpace.lg, right: HwSpace.lg, top: HwSpace.lg,
            bottom: this.navigationBarHeight + HwSpace.xl })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(resolvePageBackground(this.isDarkMode, this.pageBackground))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .keyboardShortcut(FunctionKey.ESC, [], (): void => router.back())
  }
}
