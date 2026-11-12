import { common } from '@kit.AbilityKit';
import promptAction from '@ohos.promptAction';
import { LogCapture as Lg } from '../common/LogCapture';
import { PendingDynamicPhoto } from '../common/DynamicPhotoBridge';
import { PENDING_DYNAMIC_PHOTOS_KEY, PendingDynamicPhotoStore } from '../common/DynamicPhotoStore';
import { HwColor, HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwPrimary, hwDanger, onAccentColor, reloadAppTheme, resolvePrimaryColor } from '../utils/DesignTokens';
import { toastSystemMaterial, cardGlassEffect, cardGlassBorderColor, cardGlassShadow } from '../utils/SystemMaterial';
import { CardSurface } from './CardSurface';
import { savePendingDynamicPhoto } from './PendingDynamicPhotoDialog';

/**
 * 「已解析、待保存到图库」的鸿蒙动态照片卡片。
 *
 * 动态图片传输(Beta) 在接收侧解析出非鸿蒙格式动态图片后，会尝试直接用系统 API 落库；
 * 当应用没有 `ohos.permission.WRITE_IMAGEVIDEO`（system_basic，普通应用通常拿不到）时，
 * 落库会失败并把「沙箱内的图片 + 视频」登记到 PendingDynamicPhotoStore。
 *
 * 这里用 **SaveButton 安全控件** 提供落库入口：用户点击时系统授予一次性临时写权限，
 * 应用即可通过 MediaAssetChangeRequest 创建 MOVING_PHOTO 资产，无需申请敏感权限。
 *
 * 通过 AppStorage 键 `pendingDynamicPhotos` 与 DynamicPhotoService 解耦：
 * 接收流程写入 JSON 字符串 → 本卡片自动刷新。
 *
 * 注意（踩过的坑）：`build()` 必须直接读 `this.pendingJson` 这个状态变量才会被重画。
 * 早期版本在 build 里绕过去调用 `PendingDynamicPhotoStore.list()`（内部读 AppStorage），
 * ArkUI 收集不到依赖，于是「收到动态照片后卡片根本不出现」——@Watch 会响、界面不刷新。
 */
@Component
export struct PendingDynamicPhotoCard {
  /** 主题色变化时触发重建，让 HwColor.primary 与选中态取到新色值 */
  @StorageProp('accentColor') @Watch('onAccentColorChanged') accentColor: string = '';
  /** 页面底色（由 applyAppTheme 发布）。直接读 HwColor.background 登记不上依赖 */
  @StorageProp('pageBackground') pageBackground: string = '';
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('immersiveLightEnabled') immersiveLightEnabled: boolean = true;
  @StorageLink('beautifulCards') beautifulCards: boolean = false;
  @StorageLink('classicCards') classicCards: boolean = false;
  @StorageLink('cardShadowBorder') cardShadowBorder: boolean = true;
  @StorageLink('experimentalCards') experimentalCards: boolean = false;
  @StorageProp('fontMode') fontMode: string = 'system';
  @StorageProp('fontFamilyEn') fontFamilyEn: string = 'system';
  @StorageProp('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageProp('fontWeightMode') fontWeightMode: string = 'system';
  @StorageProp('fontWeightValue') fontWeightValue: number = 400;
  @StorageLink(PENDING_DYNAMIC_PHOTOS_KEY) pendingJson: string = '[]';
  @State savingPath: string = '';

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

  /** 待保存列表：必须基于状态变量 `pendingJson` 解析，build 才会跟着刷新。 */
  private items(): PendingDynamicPhoto[] {
    return PendingDynamicPhotoStore.parse(this.pendingJson);
  }

  /** SaveButton 点击回调：拿到一次性临时权限后创建 MOVING_PHOTO 资产。 */
  private async saveAt(photo: PendingDynamicPhoto): Promise<void> {
    if (this.savingPath.length > 0) {
      return;
    }
    this.savingPath = photo.imagePath;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      await savePendingDynamicPhoto(context, photo);
    } catch (error) {
      Lg.w('[DYNAMIC] save button threw: ' + JSON.stringify(error));
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '保存失败，请重试' });
    } finally {
      this.savingPath = '';
    }
  }

  @Builder
  pendingRow(photo: PendingDynamicPhoto, index: number) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(photo.title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.appFontFamily(photo.title))
          .fontColor(hwTextPrimary(this.isDarkMode))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text('来源：' + (photo.vendor.length > 0 ? photo.vendor : '动态图片') + ' · 已解析为图片 + 视频，待保存到图库')
          .fontSize(11)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('来源：动态图片 · 已解析为图片 + 视频，待保存到图库'))
          .fontWeight(this.appFontWeight())
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SaveButton({
        icon: SaveIconStyle.FULL_FILLED,
        text: SaveDescription.SAVE_TO_GALLERY,
        buttonType: ButtonType.Capsule
      })
        .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
          if (result === SaveButtonOnClickResult.SUCCESS) {
            this.saveAt(photo).catch((): void => undefined);
          } else {
            Lg.w('[DYNAMIC] save button authorization denied result=' + result);
          }
        })

      Text('忽略')
        .fontSize(12)
        .fontColor(hwDanger(this.isDarkMode))
        .fontFamily(this.appFontFamily('忽略'))
        .fontWeight(this.appFontWeight())
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .onClick(() => {
          PendingDynamicPhotoStore.remove(photo.imagePath, photo.videoPath);
        })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
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
    if (this.items().length > 0) {
      CardSurface({ radius: HwRadius.card }) {
        Column({ space: 4 }) {
          Row({ space: 8 }) {
            Text('动态照片待保存')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontFamily(this.appFontFamily('动态照片待保存'))
              .fontColor(hwTextPrimary(this.isDarkMode))
            Text(String(this.items().length))
              .fontSize(11)
              // 主题色底上的字色按深浅自动取黑/白（浅色主题色上白字看不清）
              .fontColor(onAccentColor(this.accentOrPrimary()))
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .borderRadius(6)
              .backgroundColor(resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()))
            Blank()
          }
          .width('100%')
          Text('接收到的动态图片已解析完成。点击系统保存按钮即可写入相册（首次会请求授权）。')
            .fontSize(11)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('接收到的动态图片已解析完成'))
            .fontWeight(this.appFontWeight())
            .width('100%')
          ForEach(this.items(), (photo: PendingDynamicPhoto, index: number) => {
            this.pendingRow(photo, index)
          }, (photo: PendingDynamicPhoto): string => photo.imagePath + '|' + photo.videoPath + ':' + this.accentColor)
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
  }
}
