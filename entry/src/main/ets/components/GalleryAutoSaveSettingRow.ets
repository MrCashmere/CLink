/** 开关只记录保存偏好；收到媒体时由统一服务按需请求授权。 */

import { common } from '@kit.AbilityKit';
import { LogCapture as Lg } from '../common/LogCapture';
import { SettingsStore } from '../common/SettingsStore';
import { GalleryAutoSaveService } from '../quickshare/service/GalleryAutoSaveService';
import {
  HwRadius,
  HwSpace,
  hwTextPrimary,
  hwTextSecondary,
  HwColor
} from '../utils/DesignTokens';
import { cardGlassBorderColor, cardGlassEffect, cardGlassShadow } from '../utils/SystemMaterial';
import { CardSurface } from './CardSurface';
import { GalleryAuthorizationRequest } from '../quickshare/service/GalleryAuthorizationRequest';

/** 两套设置页共用同一个持久化开关。 */
@Component
export struct GalleryAutoSaveSettingRow {
  @StorageProp('accentColor') accentColor: string = '';
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('saveReceivedMediaToGallery') galleryEnabled: boolean = false;
  @StorageLink('immersiveLightEnabled') immersiveLightEnabled: boolean = true;
  @StorageLink('beautifulCards') beautifulCards: boolean = false;
  @StorageLink('classicCards') classicCards: boolean = false;
  @StorageLink('cardShadowBorder') cardShadowBorder: boolean = true;
  @StorageLink('experimentalCards') experimentalCards: boolean = false;
  @StorageProp('fontMode') fontMode: string = 'system';
  @StorageProp('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageProp('fontWeightMode') fontWeightMode: string = 'system';
  @StorageProp('fontWeightValue') fontWeightValue: number = 400;
  private appFontFamily(): string {
    if (this.fontMode !== 'custom') {
      return 'HarmonyOS Sans';
    }
    const family: string = this.fontFamilyZh;
    return family === 'system' || family.length === 0 ? 'HarmonyOS Sans' : family;
  }

  private appFontWeight(): number {
    return this.fontWeightMode === 'custom' ? this.fontWeightValue : 400;
  }

  private accentOrPrimary(): string {
    return this.accentColor.length > 0 ? this.accentColor : HwColor.primary;
  }

  private persist(value: boolean): void {
    AppStorage.setOrCreate('saveReceivedMediaToGallery', value);
    if (!value) {
      GalleryAutoSaveService.invalidateAuthorization('feature disabled by user');
      GalleryAuthorizationRequest.cancelPending();
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    SettingsStore.setSaveReceivedMediaToGallery(context, value).catch((error: Error): void => {
      Lg.w('[GALLERY] persist setting failed: ' + error.message);
    });
  }

  build() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 8 }) {
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text($r('app.string.gallery_auto_save_title'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontFamily(this.appFontFamily())
              .fontColor(hwTextPrimary(this.isDarkMode))
            Text($r('app.string.gallery_auto_save_description'))
              .fontSize(12)
              .lineHeight(17)
              .fontColor(hwTextSecondary(this.isDarkMode))
              .fontFamily(this.appFontFamily())
              .fontWeight(this.appFontWeight())
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.galleryEnabled })
            .selectedColor(this.accentOrPrimary())
            .onChange((value: boolean): void => {
              this.galleryEnabled = value;
              this.persist(value);
            })
        }
        .width('100%')

      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.card)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards,
        this.isDarkMode, this.experimentalCards))
      .border({
        width: 1,
        color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder,
          this.isDarkMode, this.experimentalCards)
      })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder,
        this.isDarkMode, this.experimentalCards))
    }
  }
}
