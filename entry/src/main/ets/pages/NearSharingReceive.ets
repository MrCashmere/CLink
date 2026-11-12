import { LogCapture as Lg } from '../common/LogCapture';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileUri } from '@kit.CoreFileKit';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
import { IconCircleButton } from '../components/IconCircleButton';
import { AppBackground } from '../components/AppBackground';
import { HwColor, HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwPrimaryButton, hwGlassBorder, reloadAppTheme, resolvePageBackground, onAccentColor, topBarGlassColor, resolvePrimaryButtonColor } from '../utils/DesignTokens';
import { cardGlassEffect, toastSystemMaterial, dialogSystemMaterial, cardGlassBorderColor, cardGlassShadow } from '../utils/SystemMaterial';
import { IncomingFile, SessionFileMeta } from '../model/TransferModels';
import { createGsFacade, GsFacade, GsReceiveHooks, GS_NEARSHARE_PORT } from '../protocol/gs/GsFacade';
import { DynamicPhotoService, IncomingFileLike } from '../common/DynamicPhotoService';
import { GalleryAutoSaveService } from '../quickshare/service/GalleryAutoSaveService';
import { CardSurface } from '../components/CardSurface';
import { AccentColorSentinel } from '../components/MaterialCard';

@Entry
@Component
struct NearSharingReceivePage {
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
  @State statusText: string = '正在初始化接收';
  @State peerName: string = '';
  @State incomingFiles: IncomingFile[] = [];
  @State progress: number = 0;
  private facade?: GsFacade;
  private loadedFromParams = false;
  private receiveScope: string = '';

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
    this.loadParams();
    if (this.loadedFromParams) {
      this.statusText = '已接收 ' + this.incomingFiles.length + ' 个文件';
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    this.facade = createGsFacade('windowsnearby', context);
    const hooks: GsReceiveHooks = {
      onIncomingSession: (key: string, peerName: string, files: SessionFileMeta[], pin: string): Promise<boolean> => {
        return this.onIncomingSession(key, peerName, files, pin);
      },
      onFileReceived: async (file: IncomingFile): Promise<void> => {
        await this.handleIncomingFile(file);
      },
      onSessionFailed: (key: string, reason: string): void => {
        if (this.receiveScope === 'nearshare:' + key) {
          this.statusText = '接收失败：' + reason;
          DynamicPhotoService.settleBatch(context, [], this.receiveScope).catch((): void => undefined);
        }
      },
      onProgress: (percent: number): void => {
        this.progress = percent;
        this.statusText = '接收中 ' + Math.floor(percent) + '%';
        if (percent >= 100) {
          this.statusText = '接收完成';
          DynamicPhotoService.settleBatch(context, [], this.receiveScope).catch((): void => undefined);
        }
      }
    };
    this.facade.startReceive(GS_NEARSHARE_PORT, hooks).then((): void => {
      this.statusText = '正在等待 Windows 发送（端口 ' + GS_NEARSHARE_PORT + '）';
    }).catch((error: BusinessError): void => {
      this.statusText = '接收启动失败：' + error.message;
    });
  }

  private async handleIncomingFile(file: IncomingFile): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    const savedPath: string = file.savedPath ?? '';
    let resolved: IncomingFile = file;
    const dynamicSelf: IncomingFileLike = {
      name: file.name,
      size: file.size,
      savedPath: savedPath
    };
    const dynamicBatch: IncomingFileLike[] =
      this.incomingFiles.concat([file]).map(
        (item: IncomingFile): IncomingFileLike => ({
          name: item.name,
          size: item.size,
          savedPath: item.savedPath ?? ''
        })
      );
    try {
      await DynamicPhotoService.settleReceivedFile(context, dynamicSelf, dynamicBatch, this.receiveScope);
    } catch (error) {
      Lg.w('[DYNAMIC] settle (nearshare) failed: '
        + (error instanceof Error ? error.message : JSON.stringify(error)));
    }
    if (!DynamicPhotoService.isClaimedByDynamicPhoto(savedPath)
      && GalleryAutoSaveService.isSandboxPath(context, savedPath)) {
      try {
        const processed = await GalleryAutoSaveService.processCompleted(
          context, savedPath, file.name, file.size, false, file.mime ?? '');
        if (processed.finalPath.length > 0) {
          resolved = {
            name: file.name,
            size: file.size,
            savedPath: processed.finalPath
          };
        }
        Lg.i('[GALLERY] nearshare handled=' + processed.handled
          + ' gallery=' + processed.savedToGallery
          + ' name=' + file.name
          + ' final=' + processed.finalPath
          + ' error=' + processed.error);
      } catch (error) {
        Lg.w('[GALLERY] nearshare save failed: '
          + (error instanceof Error ? error.message : JSON.stringify(error)));
      }
    }
    this.statusText = '已接收：' + resolved.name;
    this.incomingFiles = this.incomingFiles.concat([resolved]);
  }

  aboutToDisappear(): void {
    // 注意：本页只消费全局 NearbyScanHub 的状态，绝不自建 WindowsNearbyBleController。
    // 鸿蒙 BLE 广播/扫描是全局单例，页面自建控制器会在 start() 时顶掉 Hub 的广播、
    // stop() 时停掉全局广播，导致「完成一次传输后第二次 Windows 搜不到手机」。
    this.facade?.stopReceive();
    this.facade = undefined;
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
            Text(this.statusText).fontSize(14).fontFamily(this.appFontFamily(this.statusText)).fontWeight(this.appFontWeight()).fontColor(hwTextPrimary(this.isDarkMode)).width('100%')
            if (this.peerName.length > 0) {
              Text('对端：' + this.peerName).fontSize(13).fontFamily(this.appFontFamily('对端：' + this.peerName)).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).width('100%')
            }
            if (this.progress > 0 && this.progress < 100) {
              Text('进度：' + Math.floor(this.progress) + '%').fontSize(13).fontFamily(this.appFontFamily('进度：' + Math.floor(this.progress) + '%')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).width('100%')
            }
            if (this.incomingFiles.length > 0) {
              this.receivedFilesCard()
            }
          }
          .width('100%')
          .padding({ left: HwSpace.lg, right: HwSpace.lg, top: HwSpace.lg, bottom: 48 })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)

      Row() {
        IconCircleButton({ symbol: $r('sys.symbol.chevron_left'), glass: true, buttonSize: 40, iconSize: 20, onAction: (): void => router.back() })
        Text('Windows Nearby 接收').fontSize(20).fontWeight(FontWeight.Bold).fontFamily(this.appFontFamily('Windows Nearby 接收')).fontColor(hwTextPrimary(this.isDarkMode)).margin({ left: HwSpace.md })
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

  @Builder
  receivedFilesCard() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 6 }) {
        Text('已接收文件（' + this.incomingFiles.length + '）').fontSize(14).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('已接收文件')).fontColor(hwTextPrimary(this.isDarkMode))
        ForEach(this.incomingFiles, (file: IncomingFile): void => {
          Column({ space: 4 }) {
            Row({ space: 8 }) {
              Text(file.name).layoutWeight(1).fontSize(13).fontFamily(this.appFontFamily(file.name)).fontWeight(this.appFontWeight()).fontColor(hwTextPrimary(this.isDarkMode))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.fileSizeText(file.size)).fontSize(12).fontFamily(this.appFontFamily(this.fileSizeText(file.size))).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
              Button('打开', { type: ButtonType.Capsule }).height(26).fontSize(12).fontFamily(this.appFontFamily('打开'))
                .backgroundColor(resolvePrimaryButtonColor(this.isDarkMode, this.accentOrPrimary())).fontColor(onAccentColor(this.accentOrPrimary()))
                .onClick(() => this.openFile(file))
            }.width('100%')
            Text(file.savedPath).fontSize(11).fontFamily(this.appFontFamily(file.savedPath)).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          }.width('100%')
        }, (file: IncomingFile): string => file.savedPath + ':' + file.name + ':' + this.accentColor)
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

  private loadParams(): void {
    try {
      const params = router.getParams() as Record<string, Object>;
      if (params === undefined) {
        return;
      }
      const peerValue = params['peer'];
      if (typeof peerValue === 'string' && peerValue.length > 0) {
        this.peerName = peerValue as string;
      }
      const nameArray = params['files'] as Object;
      const sizeArray = params['sizes'] as Object;
      const pathArray = params['paths'] as Object;
      if (Array.isArray(nameArray) && nameArray.length > 0) {
        const names = nameArray as string[];
        this.incomingFiles = [];
        for (let i = 0; i < names.length; i++) {
          const name = names[i];
          const size = Array.isArray(sizeArray) ? Number((sizeArray as number[])[i] ?? 0) : 0;
          const savedPath = Array.isArray(pathArray) ? String((pathArray as string[])[i] ?? '') : '';
          this.incomingFiles = this.incomingFiles.concat([{ name: name, size: size, savedPath: savedPath }]);
        }
        this.loadedFromParams = true;
        if (this.progress <= 0) {
          this.progress = 100;
        }
        this.statusText = '已接收 ' + this.incomingFiles.length + ' 个文件';
      }
    } catch (error) {
      Lg.w('NearSharingReceive loadParams failed: ' + JSON.stringify(error));
    }
  }
  private onIncomingSession(key: string, peerName: string, files: SessionFileMeta[], pin: string): Promise<boolean> {
    return promptAction.showDialog({
      systemMaterial: dialogSystemMaterial(),
      title: 'Windows Nearby 接收请求',
      message: `「${peerName}」想发送 ${files.length} 个文件。双方 PIN：${pin}\n是否接收？`,
      buttons: [
        { text: '拒绝', color: HwColor.textSecondary },
        { text: '接收', color: HwColor.primary }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): boolean => {
      if (result.index === 1) {
        this.receiveScope = 'nearshare:' + key;
        this.incomingFiles = [];
        this.peerName = peerName;
        this.progress = 0;
        this.statusText = '开始接收';
        return true;
      }
      return false;
    }).catch((): boolean => false);
  }

  private openFile(file: IncomingFile): void {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const uri: string = file.savedPath.startsWith('file://') ? file.savedPath : fileUri.getUriFromPath(file.savedPath);
      ctx.startAbility({
        action: 'ohos.want.action.viewData',
        uri,
        flags: 1,
        parameters: { 'ohos.aafwk.param.bundleName': 'com.cashmere.link' }
      }).catch((error: BusinessError): void => {
        Lg.e('Windows Nearby receive open file failed: ' + JSON.stringify(error));
        promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '无法打开：' + (error.message ?? ''), duration: 2000 });
      });
    } catch (error) {
      Lg.e('Windows Nearby receive open file error: ' + JSON.stringify(error));
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '无法打开文件', duration: 2000 });
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
}
