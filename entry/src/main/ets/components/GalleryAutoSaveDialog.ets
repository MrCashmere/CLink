import { ComponentContent, UIContext } from '@kit.ArkUI';
import { LogCapture as Lg } from '../common/LogCapture';
import { GalleryAuthorizationSession } from '../quickshare/service/GalleryAuthorizationSession';
import { HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, HwColor } from '../utils/DesignTokens';

interface GalleryDialogParameters {
  onDecision: (granted: boolean) => void;
}

/** 文件已收到后才显示；只有系统 SaveButton 成功回调能够建立授权。 */
@Component
export struct GalleryAutoSaveDialog {
  onDecision: (granted: boolean) => void = (_granted: boolean): void => {};
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageProp('fontMode') fontMode: string = 'system';
  @StorageProp('fontFamilyZh') fontFamilyZh: string = 'system';

  private appFontFamily(): string {
    return this.fontMode === 'custom' && this.fontFamilyZh !== 'system' && this.fontFamilyZh.length > 0
      ? this.fontFamilyZh : 'HarmonyOS Sans';
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.gallery_auto_save_dialog_title'))
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontFamily(this.appFontFamily())
        .fontColor(hwTextPrimary(this.isDarkMode))
        .width('100%')
      Text($r('app.string.gallery_auto_save_dialog_body'))
        .fontSize(14)
        .lineHeight(20)
        .fontFamily(this.appFontFamily())
        .fontColor(hwTextSecondary(this.isDarkMode))
        .width('100%')
      SaveButton({ icon: SaveIconStyle.FULL_FILLED, text: SaveDescription.SAVE_TO_GALLERY,
        buttonType: ButtonType.Capsule })
        .width('100%')
        .height(48)
        .onClick((_event: ClickEvent, result: SaveButtonOnClickResult): void => {
          if (result === SaveButtonOnClickResult.SUCCESS) {
            this.onDecision(true);
          } else {
            this.onDecision(false);
          }
        })
      Button($r('app.string.gallery_auto_save_dialog_cancel'))
        .width('100%')
        .height(38)
        .fontSize(14)
        .fontFamily(this.appFontFamily())
        .fontColor(hwTextSecondary(this.isDarkMode))
        .backgroundColor(Color.Transparent)
        .onClick((): void => { this.onDecision(false); })
    }
    .width(320)
    .padding(HwSpace.xl)
    .borderRadius(HwRadius.card)
    .backgroundColor(HwColor.background)
  }
}

@Builder
function galleryAuthorizationContent(params: GalleryDialogParameters) {
  GalleryAutoSaveDialog({ onDecision: params.onDecision })
}

/** 用主窗口 UIContext 显示，独立接收页也可请求；关闭/切后台时释放等待者。 */
export class GalleryAuthorizationDialogHost {
  private static closePending?: () => void;

  static dismiss(): void { GalleryAuthorizationDialogHost.closePending?.(); }

  static show(uiContext: UIContext): Promise<boolean> {
    if (GalleryAuthorizationDialogHost.closePending !== undefined) { return Promise.resolve(false); }
    return new Promise<boolean>((resolve: (granted: boolean) => void): void => {
      let accepted: boolean = false;
      let settled: boolean = false;
      let opened: boolean = false;
      let closing: boolean = false;
      let content: ComponentContent<GalleryDialogParameters> | undefined = undefined;
      const finish = (): void => {
        if (settled) { return; }
        settled = true;
        GalleryAuthorizationDialogHost.closePending = undefined;
        content?.dispose();
        resolve(accepted);
      };
      const close = (): void => {
        closing = true;
        if (opened && content !== undefined) {
          uiContext.getPromptAction().closeCustomDialog<GalleryDialogParameters>(content)
            .catch((): void => { accepted = false; finish(); });
        }
      };
      const params: GalleryDialogParameters = {
        onDecision: (granted: boolean): void => {
          if (settled || closing) { return; }
          accepted = granted;
          if (granted) { GalleryAuthorizationSession.activate(); }
          close();
        }
      };
      try {
        content = new ComponentContent<GalleryDialogParameters>(uiContext, wrapBuilder(galleryAuthorizationContent), params);
        GalleryAuthorizationDialogHost.closePending = (): void => { accepted = false; close(); };
        uiContext.getPromptAction().openCustomDialog<GalleryDialogParameters>(content, {
          alignment: DialogAlignment.Center,
          autoCancel: true,
          onDidDisappear: (): void => { finish(); }
        }).then((): void => {
          opened = true;
          if (closing) { close(); }
        }).catch((error: Error): void => {
          Lg.w('[GALLERY] authorization dialog failed: ' + error.message);
          accepted = false;
          finish();
        });
      } catch (error) {
        Lg.w('[GALLERY] authorization dialog failed: ' + String(error));
        finish();
      }
    });
  }
}
