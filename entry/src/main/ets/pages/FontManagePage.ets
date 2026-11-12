import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { text } from '@kit.ArkGraphics2D';
import { HwColor, HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwPrimary, hwDanger, hwSurface, hwGlassBorder, reloadAppTheme, resolvePageBackground, topBarGlassColor, resolvePrimaryColor } from '../utils/DesignTokens';
import { cardGlassEffect, sheetBlurStyle, sheetSystemMaterial, dialogSystemMaterial, cardGlassBorderColor, cardGlassShadow } from '../utils/SystemMaterial';
import { IconCircleButton } from '../components/IconCircleButton';
import { AppBackground } from '../components/AppBackground';
import { AppSettingsStore } from '../storage/AppSettingsStore';
import { CardSurface } from '../components/CardSurface';
import { AccentColorSentinel, MaterialCardLayer, MaterialSheetPanel } from '../components/MaterialCard';

@Entry
@Component
struct FontManagePage {
  /** 主题色变化时触发重建，让 HwColor.primary 与选中态取到新色值 */
  @StorageProp('accentColor') @Watch('onAccentColorChanged') accentColor: string = '';
  /** 页面底色（由 applyAppTheme 发布）。直接读 HwColor.background 登记不上依赖 */
  @StorageProp('pageBackground') pageBackground: string = '';
  @StorageLink('immersiveLightEnabled') immersiveLightEnabled: boolean = true;
  @StorageLink('beautifulCards') beautifulCards: boolean = false;
  @StorageLink('classicCards') classicCards: boolean = false;
  @StorageLink('cardShadowBorder') cardShadowBorder: boolean = true;
  @StorageLink('experimentalCards') experimentalCards: boolean = false;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('customFonts') customFonts: string[] = [];
  @StorageLink('fontMode') fontMode: string = 'system';
  @StorageLink('fontFamilyEn') fontFamilyEn: string = 'system';
  @StorageLink('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageLink('fontWeightMode') fontWeightMode: string = 'system';
  @StorageLink('fontWeightValue') fontWeightValue: number = 400;
  @State message: string = '';
  @State renameError: string = '';
  @State renameIndex: number = -1;
  @State renameDraft: string = '';
  @State showRenameSheet: boolean = false;

  private fontDir(): string {
    const context = getContext(this) as common.UIAbilityContext;
    return `${context.filesDir}/custom_fonts`;
  }

  private aliasOf(fileName: string): string {
    const lower = fileName.toLowerCase();
    const ext = lower.endsWith('.ttf') ? '.ttf' : '.otf';
    return fileName.substring(0, fileName.length - ext.length);
  }

  private appFontWeight(): number {
    return this.fontWeightMode === 'custom' ? this.fontWeightValue : 400;
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

  startRename(index: number): void {
    this.renameIndex = index;
    this.renameDraft = this.aliasOf(this.customFonts[index]);
    this.renameError = '';
    this.showRenameSheet = true;
  }

  confirmRename(): void {
    if (this.renameIndex < 0 || this.renameIndex >= this.customFonts.length) {
      return;
    }
    const oldName = this.customFonts[this.renameIndex];
    const oldAlias = this.aliasOf(oldName);
    const oldExt = oldName.toLowerCase().endsWith('.ttf') ? '.ttf' : '.otf';
    let newName = this.renameDraft.trim();
    if (newName.length === 0) {
      this.renameError = '名称不能为空';
      return;
    }
    const lowerNew = newName.toLowerCase();
    if (!lowerNew.endsWith('.ttf') && !lowerNew.endsWith('.otf')) {
      newName = `${newName}${oldExt}`;
    }
    if (newName.includes('/') || newName.includes('\\') || newName.includes(':')) {
      this.renameError = '名称包含非法字符';
      return;
    }
    if (newName === oldName) {
      this.showRenameSheet = false;
      return;
    }
    try {
      const dir = this.fontDir();
      if (fs.accessSync(`${dir}/${newName}`)) {
        this.renameError = '已存在同名字体';
        return;
      }
      const newAlias = this.aliasOf(newName);
      try {
        text.FontCollection.getGlobalInstance().unloadFontSync(oldAlias);
      } catch (err) {
      }
      fs.renameSync(`${dir}/${oldName}`, `${dir}/${newName}`);
      try {
        text.FontCollection.getGlobalInstance().loadFontSyncWithCheck(newAlias, `file://${dir}/${newName}`);
      } catch (err) {
        try {
          fs.renameSync(`${dir}/${newName}`, `${dir}/${oldName}`);
        } catch (ignored) {
        }
        this.renameError = '重命名后字体无效，已还原';
        return;
      }
      const next: string[] = [];
      for (let i = 0; i < this.customFonts.length; i++) {
        next.push(i === this.renameIndex ? newName : this.customFonts[i]);
      }
      this.customFonts = next;
      AppSettingsStore.setStringArray('customFonts', next);
      if (this.fontFamilyEn === oldAlias) {
        this.fontFamilyEn = newAlias;
        AppSettingsStore.setString('fontFamilyEn', newAlias);
      }
      if (this.fontFamilyZh === oldAlias) {
        this.fontFamilyZh = newAlias;
        AppSettingsStore.setString('fontFamilyZh', newAlias);
      }
      this.showRenameSheet = false;
      this.message = '已重命名';
    } catch (err) {
      this.renameError = '重命名失败';
    }
  }

  confirmDelete(index: number): void {
    if (index < 0 || index >= this.customFonts.length) {
      return;
    }
    const alias = this.aliasOf(this.customFonts[index]);
    this.getUIContext().showAlertDialog({
      systemMaterial: dialogSystemMaterial(),
      title: '删除字体',
      message: `确定删除「${alias}」吗？删除后无法恢复。`,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: HwColor.danger,
        action: () => {
          this.deleteFont(index);
        }
      }
    });
  }

  deleteFont(index: number): void {
    try {
      const fileName = this.customFonts[index];
      const alias = this.aliasOf(fileName);
      try {
        text.FontCollection.getGlobalInstance().unloadFontSync(alias);
      } catch (err) {
      }
      try {
        fs.unlinkSync(`${this.fontDir()}/${fileName}`);
      } catch (err) {
      }
      const next: string[] = [];
      for (let i = 0; i < this.customFonts.length; i++) {
        if (i !== index) {
          next.push(this.customFonts[i]);
        }
      }
      this.customFonts = next;
      AppSettingsStore.setStringArray('customFonts', next);
      if (this.fontFamilyEn === alias) {
        this.fontFamilyEn = 'system';
        AppSettingsStore.setString('fontFamilyEn', 'system');
      }
      if (this.fontFamilyZh === alias) {
        this.fontFamilyZh = 'system';
        AppSettingsStore.setString('fontFamilyZh', 'system');
      }
      this.message = '已删除';
    } catch (err) {
      this.message = '删除失败';
    }
  }

  @Builder
  renameSheet() {
    // 半模态面板不在「非选择类组件的内容区生效范围」内，
    // 用 MaterialSheetPanel 的 Toggle 承载层铺满整块面板，材质才画得出来
    MaterialSheetPanel() {
      Column({ space: 16 }) {
      Column({ space: 6 }) {
        Text('重命名字体')
          .fontFamily(this.appFontFamily('重命名字体'))
          .fontWeight(this.appFontWeight())
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(hwTextPrimary(this.isDarkMode))
        Text('输入新名称，扩展名将自动保持 .ttf / .otf')
          .fontFamily(this.appFontFamily('输入新名称，扩展名将自动保持 .ttf / .otf'))
          .fontWeight(this.appFontWeight())
          .fontSize(12)
          .fontColor(hwTextSecondary(this.isDarkMode))
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      TextInput({ placeholder: '输入新字体名', text: this.renameDraft })
        .caretColor(this.accentOrPrimary())
        .width('100%')
        .height(44)
        .fontSize(15)
        .fontColor(hwTextPrimary(this.isDarkMode))
        .placeholderColor(hwTextSecondary(this.isDarkMode))
        .backgroundColor(hwSurface(this.isDarkMode))
        .borderRadius(HwRadius.control)
        .padding({ left: HwSpace.md, right: HwSpace.md })
        .onChange((value: string) => {
          this.renameDraft = value;
        })

      if (this.renameError.length > 0) {
        Text(this.renameError)
          .fontFamily(this.appFontFamily(this.renameError))
          .fontWeight(this.appFontWeight())
          .fontSize(13)
          .fontColor(hwDanger(this.isDarkMode))
          .width('100%')
      }

      Row({ space: 12 }) {
        // 按钮同样走 Toggle 承载层：普通 Button 直接挂 systemMaterial 在真机上不渲染，
        // 包一层 MaterialCardLayer 就与卡片走同一条已验证的路径。
        // 带 layoutWeight 的按钮要把它移到外层 Stack 上（Stack 内 layoutWeight 不生效）。
        Stack() {
          MaterialCardLayer({ layerRadius: HwRadius.pill })
          Button('取消', { type: ButtonType.Capsule, stateEffect: true })
            .width('100%')
            .height(44)
            .fontSize(15)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .backgroundColor(Color.Transparent)
            .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, false))
            .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, false) })
            .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, false))
            .onClick(() => {
              this.showRenameSheet = false;
            })
        }
        .layoutWeight(1)
        .borderRadius(HwRadius.pill)

        Stack() {
          MaterialCardLayer({ layerRadius: HwRadius.pill })
          Button('确定', { type: ButtonType.Capsule, stateEffect: true })
            .width('100%')
            .height(44)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()))
            .backgroundColor(Color.Transparent)
            .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, false))
            .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, false) })
            .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, false))
            .enabled(this.renameDraft.trim().length > 0)
            .opacity(this.renameDraft.trim().length > 0 ? 1 : 0.4)
            .onClick(() => {
              this.confirmRename();
            })
        }
        .layoutWeight(1)
        .borderRadius(HwRadius.pill)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: HwSpace.lg, right: HwSpace.lg, top: 16, bottom: 24 })
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
          Column({ space: 0 }) {
            Blank().height(56 + this.statusBarHeight)
            Column({ space: 12 }) {
              if (this.message.length > 0) {
                Text(this.message)
                  .fontFamily(this.appFontFamily(this.message))
                  .fontWeight(this.appFontWeight())
                  .fontSize(13)
                  .fontColor(resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()))
                  .width('100%')
                  .padding({ left: 4, right: 4 })
              }
              if (this.customFonts.length === 0) {
                Text('暂无上传的字体')
                  .fontFamily(this.appFontFamily('暂无上传的字体'))
                  .fontWeight(this.appFontWeight())
                  .fontSize(14)
                  .fontColor(hwTextSecondary(this.isDarkMode))
                  .width('100%')
                  .padding({ top: HwSpace.xl, bottom: HwSpace.xl })
                  .textAlign(TextAlign.Center)
              }
              ForEach(this.customFonts, (fileName: string, index: number) => {
                CardSurface({ radius: HwRadius.card }) {
                  Row({ space: 12 }) {
                    Column({ space: 2 }) {
                      Text(this.aliasOf(fileName))
                        .fontFamily(this.appFontFamily(this.aliasOf(fileName)))
                        .fontWeight(this.appFontWeight())
                        .fontSize(15)
                        .fontColor(hwTextPrimary(this.isDarkMode))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(fileName)
                        .fontFamily(this.appFontFamily(fileName))
                        .fontWeight(this.appFontWeight())
                        .fontSize(12)
                        .fontColor(hwTextSecondary(this.isDarkMode))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    Stack() {
                      MaterialCardLayer({ layerRadius: HwRadius.pill })
                      Button('改名', { type: ButtonType.Capsule, stateEffect: true })
                        .height(32)
                        .fontSize(13)
                        .fontColor(hwTextPrimary(this.isDarkMode))
                        .backgroundColor(Color.Transparent)
                        .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, false))
                        .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, false) })
                        .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, false))
                        .onClick(() => {
                          this.startRename(index);
                        })
                    }
                    .borderRadius(HwRadius.pill)

                    Stack() {
                      MaterialCardLayer({ layerRadius: HwRadius.pill })
                      Button('删除', { type: ButtonType.Capsule, stateEffect: true })
                        .height(32)
                        .fontSize(13)
                        .fontColor(hwDanger(this.isDarkMode))
                        .backgroundColor(Color.Transparent)
                        .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, false))
                        .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, false) })
                        .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, false))
                        .onClick(() => {
                          this.confirmDelete(index);
                        })
                    }
                    .borderRadius(HwRadius.pill)
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
              }, (fileName: string, index: number) => `${index}_${fileName}_${this.accentColor}`)
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
        Text('管理字体')
          .fontFamily(this.appFontFamily('管理字体'))
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
    .bindSheet($$this.showRenameSheet, this.renameSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      // 必须显式透明：BindOptions.backgroundColor 默认是 Color.White，
      // 而沉浸光感的视觉层级位于 backgroundColor 之下，白底会把材质整块盖住
      backgroundColor: Color.Transparent,
      blurStyle: sheetBlurStyle(),
      systemMaterial: sheetSystemMaterial(),
      onDisappear: () => {
        this.renameIndex = -1;
      }
    })
    .keyboardShortcut(FunctionKey.ESC, [], () => {
      router.back();
    })
  }
}
