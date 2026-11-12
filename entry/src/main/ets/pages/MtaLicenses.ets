import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { AppBackground } from '../components/AppBackground';
import { IconCircleButton } from '../components/IconCircleButton';
import { CardSurface } from '../components/CardSurface';
import { AccentColorSentinel } from '../components/MaterialCard';
import { HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, reloadAppTheme, resolvePageBackground, topBarGlassColor } from '../utils/DesignTokens';
import { cardGlassEffect, cardGlassBorderColor, cardGlassShadow } from '../utils/SystemMaterial';

@Entry
@Component
struct MtaLicensesPage {
  @StorageProp('accentColor') @Watch('onAccentColorChanged') accentColor: string = '';
  @StorageProp('pageBackground') pageBackground: string = '';
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  @StorageProp('beautifulCards') beautifulCards: boolean = false;
  @StorageProp('classicCards') classicCards: boolean = false;
  @StorageProp('cardShadowBorder') cardShadowBorder: boolean = true;
  @StorageProp('experimentalCards') experimentalCards: boolean = false;
  @StorageProp('fontMode') fontMode: string = 'system';
  @StorageProp('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageProp('fontFamilyEn') fontFamilyEn: string = 'system';
  @StorageProp('fontWeightMode') fontWeightMode: string = 'system';
  @StorageProp('fontWeightValue') fontWeightValue: number = 400;
  @State licenseText: string = '正在读取许可证…';

  onAccentColorChanged(): void { reloadAppTheme(); }

  private appFontFamily(content: string): string {
    if (this.fontMode !== 'custom') { return 'HarmonyOS Sans'; }
    let family = this.fontFamilyEn;
    for (let i = 0; i < content.length; i++) {
      const code = content.charCodeAt(i);
      if (code >= 0x4E00 && code <= 0x9FFF) { family = this.fontFamilyZh; break; }
    }
    return family === 'system' || family.length === 0 ? 'HarmonyOS Sans' : family;
  }

  private appFontWeight(fallback: number = 400): number {
    return this.fontWeightMode === 'custom' ? this.fontWeightValue : fallback;
  }

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const paths: string[] = ['HandySend-Apache-2.0.txt', 'EasyShare-MIT.txt', 'LocalSend-Apache-2.0.txt'];
    Promise.all(paths.map((file: string): Promise<Uint8Array> =>
      context.resourceManager.getRawFileContent('licenses/' + file))).then((documents: Uint8Array[]): void => {
      this.licenseText = documents.map((bytes: Uint8Array, index: number): string =>
        paths[index] + '\n\n' + new util.TextDecoder().decodeToString(bytes)).join('\n\n────────────\n\n');
    }).catch((error: Error): void => { this.licenseText = '读取失败：' + error.message; });
  }

  @Builder
  sourceCard() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: HwSpace.md }) {
        Text('项目与来源').fontSize(17).fontWeight(this.appFontWeight(500))
          .fontFamily(this.appFontFamily('项目与来源')).fontColor(hwTextPrimary(this.isDarkMode))
        Text('HandySend · Apache-2.0').fontSize(15).fontWeight(this.appFontWeight())
          .fontFamily(this.appFontFamily('HandySend')).fontColor(hwTextPrimary(this.isDarkMode))
        Text('https://gitcode.com/springtwr/HandySend').fontSize(13).fontWeight(this.appFontWeight())
          .fontFamily(this.appFontFamily('HandySend')).fontColor(hwTextSecondary(this.isDarkMode))
          .width('100%').copyOption(CopyOptions.LocalDevice).wordBreak(WordBreak.BREAK_WORD)
        Text('本项目保留上游 MTA 实现，通过宿主适配层接入。图标来自 EasyShare / CatShare，MIT，Copyright 2025 Midori Kochiya。')
          .fontSize(13).fontWeight(this.appFontWeight()).fontFamily(this.appFontFamily('本项目保留上游实现'))
          .fontColor(hwTextSecondary(this.isDarkMode)).lineHeight(20).width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start).padding(HwSpace.lg).borderRadius(HwRadius.card)
        .backgroundColor(Color.Transparent)
        .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
        .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
        .clip(true).shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
    }
  }

  @Builder
  licenseCard() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: HwSpace.md }) {
        Text('许可证正文').fontSize(17).fontWeight(this.appFontWeight(500))
          .fontFamily(this.appFontFamily('许可证正文')).fontColor(hwTextPrimary(this.isDarkMode))
        Text(this.licenseText).fontSize(13).fontWeight(this.appFontWeight())
          .fontFamily(this.appFontFamily(this.licenseText)).fontColor(hwTextPrimary(this.isDarkMode))
          .width('100%').lineHeight(20).wordBreak(WordBreak.BREAK_WORD).copyOption(CopyOptions.LocalDevice)
      }.width('100%').alignItems(HorizontalAlign.Start).padding(HwSpace.lg).borderRadius(HwRadius.card)
        .backgroundColor(Color.Transparent)
        .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
        .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
        .clip(true).shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
    }
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
          Text('MTA 开源许可').fontSize(20).fontWeight(this.appFontWeight(700))
            .fontFamily(this.appFontFamily('MTA 开源许可')).fontColor(hwTextPrimary(this.isDarkMode))
            .margin({ left: HwSpace.md })
          Blank()
        }
        .width('100%')
        .height(56 + this.statusBarHeight)
        .padding({ left: HwSpace.lg, right: HwSpace.lg, top: this.statusBarHeight })
        .backgroundEffect({ radius: 12, color: topBarGlassColor(this.isDarkMode) })

        Scroll() {
          Column({ space: HwSpace.md }) {
            this.sourceCard()
            this.licenseCard()
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
