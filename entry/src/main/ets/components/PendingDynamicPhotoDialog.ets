import { common } from '@kit.AbilityKit';
import promptAction from '@ohos.promptAction';
import { LogCapture as Lg } from '../common/LogCapture';
import { DynamicPhotoBridge, PendingDynamicPhoto } from '../common/DynamicPhotoBridge';
import { PENDING_DYNAMIC_PHOTOS_KEY, PendingDynamicPhotoStore } from '../common/DynamicPhotoStore';
import { HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwPrimary, hwPrimaryButton, reloadAppTheme, HwColor, onAccentColor, resolvePrimaryColor, resolvePrimaryButtonColor } from '../utils/DesignTokens';
import { toastSystemMaterial } from '../utils/SystemMaterial';
import { GalleryAutoSaveService } from '../quickshare/service/GalleryAutoSaveService';

/**
 * 用一次 SaveButton 点击把「图片 + 视频」落成鸿蒙动态照片。
 *
 * 前置条件：必须由 SaveButton 的 onClick(SUCCESS) 调用 —— 那一刻系统才给应用
 * 一次性的临时图库写权限（`ohos.permission.WRITE_IMAGEVIDEO` 是 system_basic，
 * 普通应用申请不到，所以只能用安全控件这条路）。
 */
export async function savePendingDynamicPhoto(
  context: common.UIAbilityContext,
  photo: PendingDynamicPhoto
): Promise<boolean> {
  // 该函数只会由 SaveButton.onClick(SUCCESS) 调用；同一次临时授权也应覆盖普通媒体。
  GalleryAutoSaveService.activateAuthorization();
  const result = await DynamicPhotoBridge.restore(context, photo.imagePath, photo.videoPath, photo.title);
  if (!result.restored) {
    Lg.w('[DYNAMIC] save button pending still: ' + result.error);
    promptAction.showToast({
      systemMaterial: toastSystemMaterial(),
      message: '保存失败：' + result.error
    });
    return false;
  }
  PendingDynamicPhotoStore.remove(photo.imagePath, photo.videoPath);
  promptAction.showToast({
    systemMaterial: toastSystemMaterial(),
    message: '动态照片已保存到图库'
  });
  return true;
}

/**
 * 收到动态图片后自动弹出的「保存到图库」提示框。
 *
 * 为什么需要弹框：解析成功后图片和视频都只在应用沙箱里，必须由用户点一次系统
 * SaveButton 才会进相册；只靠页面顶部卡片的话，用户在别的标签页就完全看不到提示，
 * 会以为「收下来的还是一张普通图片」。
 *
 * 列表直接来自 `@StorageLink(PENDING_DYNAMIC_PHOTOS_KEY)`（而不是 AppStorage.get）：
 * ArkUI 只在 build 里读过状态变量时才把组件标记为脏，绕过变量读会拿到旧值、不刷新。
 */
@CustomDialog
export struct PendingDynamicPhotoDialog {
  /** 主题色变化时触发重建，让 HwColor.primary 与选中态取到新色值 */
  @StorageProp('accentColor') @Watch('onAccentColorChanged') accentColor: string = '';
  /** 页面底色（由 applyAppTheme 发布）。直接读 HwColor.background 登记不上依赖 */
  @StorageProp('pageBackground') pageBackground: string = '';
  controller?: CustomDialogController;
  /** 关闭回调：调用方用它复位「提示框已打开」标记，否则同一时刻只能弹一次。 */
  onClosed?: () => void;
  @StorageLink(PENDING_DYNAMIC_PHOTOS_KEY) pendingJson: string = '[]';
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageProp('fontMode') fontMode: string = 'system';
  @StorageProp('fontFamilyEn') fontFamilyEn: string = 'system';
  @StorageProp('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageProp('fontWeightMode') fontWeightMode: string = 'system';
  @StorageProp('fontWeightValue') fontWeightValue: number = 400;
  @State savingPath: string = '';

  aboutToDisappear(): void {
    const notify: (() => void) | undefined = this.onClosed;
    if (notify !== undefined) {
      notify();
    }
  }

  private items(): PendingDynamicPhoto[] {
    return PendingDynamicPhotoStore.parse(this.pendingJson);
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

  private async save(photo: PendingDynamicPhoto): Promise<void> {
    if (this.savingPath.length > 0) {
      return;
    }
    this.savingPath = photo.imagePath;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      await savePendingDynamicPhoto(context, photo);
      if (PendingDynamicPhotoStore.count() === 0) {
        this.controller?.close();
      }
    } catch (error) {
      Lg.w('[DYNAMIC] save button threw: ' + JSON.stringify(error));
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '保存失败，请重试' });
    } finally {
      this.savingPath = '';
    }
  }

  @Builder
  itemRow(photo: PendingDynamicPhoto) {
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
        Text('来源：' + (photo.vendor.length > 0 ? photo.vendor : '动态图片'))
          .fontSize(11)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('来源：动态图片'))
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
            this.save(photo).catch((): void => undefined);
          } else {
            Lg.w('[DYNAMIC] save button authorization denied result=' + result);
            promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '未获得保存授权' });
          }
        })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
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
    Column({ space: 10 }) {
      Text('动态照片已接收')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontFamily(this.appFontFamily('动态照片已接收'))
        .fontColor(hwTextPrimary(this.isDarkMode))
        .width('100%')
      Text('已解析为「图片 + 视频」。应用没有图库写入权限，需要点一次系统保存按钮才会进相册。')
        .fontSize(12)
        .fontColor(hwTextSecondary(this.isDarkMode))
        .fontFamily(this.appFontFamily('已解析为图片和视频'))
        .fontWeight(this.appFontWeight())
        .width('100%')
      ForEach(this.items(), (photo: PendingDynamicPhoto): void => {
        this.itemRow(photo);
      }, (photo: PendingDynamicPhoto): string => photo.imagePath + '|' + photo.videoPath + ':' + this.accentColor)
      Button('稍后处理')
        .width('100%')
        .height(36)
        .fontSize(14)
        .fontFamily(this.appFontFamily('稍后处理'))
        .fontColor(onAccentColor(this.accentOrPrimary()))
        .backgroundColor(resolvePrimaryButtonColor(this.isDarkMode, this.accentOrPrimary()))
        .onClick(() => {
          this.controller?.close();
        })
      Row() {
        Text('稍后可在「聚合」页顶部的卡片里继续保存')
          .fontSize(11)
          .fontColor(resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()))
          .fontFamily(this.appFontFamily('稍后可在聚合页顶部的卡片里继续保存'))
          .fontWeight(this.appFontWeight())
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .constraintSize({ minWidth: 280, maxWidth: 340 })
    .padding(HwSpace.xl)
    .borderRadius(HwRadius.card)
  }
}
