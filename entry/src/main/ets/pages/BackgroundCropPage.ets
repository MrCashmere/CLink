import { router, display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { HwColor, hwTextPrimary, hwTextSecondary, hwPrimary, hwDanger, reloadAppTheme, resolvePageBackground, topBarGlassColor, resolvePrimaryColor } from '../utils/DesignTokens';
import { IconCircleButton } from '../components/IconCircleButton';
import { AppSettingsStore } from '../storage/AppSettingsStore';
import { AccentColorSentinel } from '../components/MaterialCard';

const MIN_CROP_WIDTH: number = 80;

@Entry
@Component
struct BackgroundCropPage {
  /** 主题色变化时触发重建，让 HwColor.primary 与选中态取到新色值 */
  @StorageProp('accentColor') @Watch('onAccentColorChanged') accentColor: string = '';
  /** 页面底色（由 applyAppTheme 发布）。直接读 HwColor.background 登记不上依赖 */
  @StorageProp('pageBackground') pageBackground: string = '';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('fontMode') fontMode: string = 'system';
  @StorageLink('fontFamilyEn') fontFamilyEn: string = 'system';
  @StorageLink('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageLink('fontWeightMode') fontWeightMode: string = 'system';
  @StorageLink('fontWeightValue') fontWeightValue: number = 400;
  @State sourceUri: string = '';

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
  @State errorMessage: string = '';
  @State saving: boolean = false;
  @State imageWidth: number = 0;
  @State imageHeight: number = 0;
  @State areaWidth: number = 0;
  @State areaHeight: number = 0;
  @State cropX: number = 0;
  @State cropY: number = 0;
  @State cropWidth: number = 0;
  private cropAspectRatio: number = 1;
  private displayScale: number = 1;
  private displayX: number = 0;
  private displayY: number = 0;
  private displayWidth: number = 0;
  private displayHeight: number = 0;
  private workingUri: string = '';
  private uriSourceValid: boolean = false;
  private resolvedFd: number = -1;
  private gestureStartX: number = 0;
  private gestureStartY: number = 0;
  private gestureStartWidth: number = 0;

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    this.sourceUri = String(params['sourceUri'] ?? '');
    const screen = display.getDefaultDisplaySync();
    if (screen.width > 0 && screen.height > 0) {
      this.cropAspectRatio = screen.width / screen.height;
    }
    this.resolveImageInfo();
  }

  private async resolveImageInfo(): Promise<void> {
    const candidates: string[] = [];
    if (this.sourceUri.startsWith('file://')) {
      candidates.push(this.sourceUri, this.sourceUri.slice('file://'.length));
    } else {
      candidates.push(this.sourceUri);
    }
    for (let i = 0; i < candidates.length; i++) {
      try {
        const source = image.createImageSource(candidates[i]);
        if (source === undefined) {
          continue;
        }
        const info = await source.getImageInfo();
        this.imageWidth = info.size.width;
        this.imageHeight = info.size.height;
        this.workingUri = candidates[i];
        this.uriSourceValid = true;
        source.release();
        this.onImageInfoReady();
        return;
      } catch (err) {
      }
    }
    try {
      const file = await fs.open(this.sourceUri, fs.OpenMode.READ_ONLY);
      const source = image.createImageSource(file.fd);
      if (source === undefined) {
        await fs.close(file.fd);
      } else {
        const info = await source.getImageInfo();
        this.imageWidth = info.size.width;
        this.imageHeight = info.size.height;
        this.resolvedFd = file.fd;
        this.uriSourceValid = false;
        source.release();
        this.onImageInfoReady();
        return;
      }
    } catch (err) {
    }
    this.errorMessage = '无法读取图片，请重新选择';
  }

  private openCropSource(): image.ImageSource {
    if (this.uriSourceValid && this.workingUri.length > 0) {
      const source = image.createImageSource(this.workingUri);
      if (source !== undefined) {
        return source;
      }
    }
    return image.createImageSource(this.resolvedFd);
  }

  private async closeResolvedSource(): Promise<void> {
    if (this.resolvedFd >= 0) {
      try {
        await fs.close(this.resolvedFd);
      } catch (err) {
      }
      this.resolvedFd = -1;
    }
  }

  private async cleanupOldBackgrounds(context: common.UIAbilityContext, keepPath: string): Promise<void> {
    try {
      const names = await fs.listFile(context.filesDir);
      for (let i = 0; i < names.length; i++) {
        const name = names[i];
        if (!name.startsWith('background_image')) {
          continue;
        }
        const fullPath = `${context.filesDir}/${name}`;
        if (fullPath === keepPath) {
          continue;
        }
        try {
          await fs.unlink(fullPath);
        } catch (err) {
        }
      }
    } catch (err) {
    }
  }

  private cropHeight(): number {
    return this.cropWidth / this.cropAspectRatio;
  }

  private resetCrop(): void {
    if (this.imageWidth <= 0 || this.imageHeight <= 0 ||
      this.areaWidth <= 0 || this.areaHeight <= 0) {
      return;
    }
    this.displayScale = Math.min(this.areaWidth / this.imageWidth,
      this.areaHeight / this.imageHeight);
    this.displayWidth = this.imageWidth * this.displayScale;
    this.displayHeight = this.imageHeight * this.displayScale;
    this.displayX = (this.areaWidth - this.displayWidth) / 2;
    this.displayY = (this.areaHeight - this.displayHeight) / 2;
    const maxWidth = Math.min(this.displayWidth, this.displayHeight * this.cropAspectRatio);
    this.cropWidth = Math.max(MIN_CROP_WIDTH, maxWidth);
    this.cropX = this.displayX + (this.displayWidth - this.cropWidth) / 2;
    this.cropY = this.displayY +
      (this.displayHeight - this.cropWidth / this.cropAspectRatio) / 2;
  }

  private maxCropWidth(): number {
    return Math.min(this.displayWidth, this.displayHeight * this.cropAspectRatio);
  }

  private onImageInfoReady(): void {
    if (this.areaWidth > 0 && this.areaHeight > 0) {
      this.resetCrop();
    }
  }

  onPreviewAreaChange(oldValue: Area, newValue: Area): void {
    const rawWidth = newValue.width;
    const rawHeight = newValue.height;
    const width = typeof rawWidth === 'number' ? rawWidth : parseFloat(String(rawWidth));
    const height = typeof rawHeight === 'number' ? rawHeight : parseFloat(String(rawHeight));
    if (Number.isNaN(width) || Number.isNaN(height) || width <= 0 || height <= 0) {
      return;
    }
    this.areaWidth = width;
    this.areaHeight = height;
    this.resetCrop();
  }

  onCropBoxGestureStart(event: GestureEvent): void {
    this.gestureStartX = this.cropX;
    this.gestureStartY = this.cropY;
  }

  onCropBoxGestureUpdate(event: GestureEvent): void {
    const maxX = this.displayX + this.displayWidth - this.cropWidth;
    const maxY = this.displayY + this.displayHeight - this.cropHeight();
    this.cropX = Math.min(Math.max(this.gestureStartX + event.offsetX, this.displayX),
      Math.max(maxX, this.displayX));
    this.cropY = Math.min(Math.max(this.gestureStartY + event.offsetY, this.displayY),
      Math.max(maxY, this.displayY));
  }

  onHandleGestureStart(event: GestureEvent): void {
    this.gestureStartWidth = this.cropWidth;
  }

  onHandleGestureUpdate(event: GestureEvent): void {
    const maxWidth = this.maxCropWidth();
    const minWidth = Math.min(MIN_CROP_WIDTH, maxWidth);
    this.cropWidth = Math.min(Math.max(this.gestureStartWidth + event.offsetX, minWidth),
      maxWidth);
    const cropHeight = this.cropHeight();
    if (this.cropX + this.cropWidth > this.displayX + this.displayWidth) {
      this.cropX = this.displayX + this.displayWidth - this.cropWidth;
    }
    if (this.cropY + cropHeight > this.displayY + this.displayHeight) {
      this.cropY = this.displayY + this.displayHeight - cropHeight;
    }
  }

  private async confirmCrop(): Promise<void> {
    if (this.saving || this.cropWidth <= 0) {
      return;
    }
    this.saving = true;
    this.errorMessage = '';
    try {
      const scale = this.displayScale;
      const ix = Math.max(0, Math.round((this.cropX - this.displayX) / scale));
      const iy = Math.max(0, Math.round((this.cropY - this.displayY) / scale));
      const iw = Math.max(1, Math.min(Math.round(this.cropWidth / scale),
        this.imageWidth - ix));
      const ih = Math.max(1, Math.min(Math.round(this.cropHeight() / scale),
        this.imageHeight - iy));
      const source = this.openCropSource();
      if (source === undefined) {
        throw new Error('无法读取图片');
      }
      const pixelMap = await source.createPixelMap();
      const cropSize: image.Size = { width: iw, height: ih };
      const cropRegion: image.Region = { size: cropSize, x: ix, y: iy };
      await pixelMap.crop(cropRegion);
      const packer = image.createImagePacker();
      const data = await packer.packToData(pixelMap, {
        format: 'image/jpeg',
        quality: 95
      });
      const context = getContext(this) as common.UIAbilityContext;
      const destPath = `${context.filesDir}/background_image_${Date.now()}`;
      const file = await fs.open(destPath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      await fs.write(file.fd, data);
      await fs.close(file.fd);
      await this.cleanupOldBackgrounds(context, destPath);
      const uri = `file://${destPath}`;
      AppSettingsStore.setString('backgroundImage', uri);
      AppStorage.setOrCreate('backgroundImage', uri);
      // 上传/更换背景后自动开启「更优美的卡片」；用户主动关闭过则不再自动打开。
      if (!AppSettingsStore.getBoolean('beautifulCardsUserSet', false)) {
        AppSettingsStore.setBoolean('beautifulCards', true);
        AppStorage.setOrCreate('beautifulCards', true);
      }
      await this.closeResolvedSource();
      router.back();
    } catch (err) {
      this.errorMessage = err instanceof Error ? err.message : '裁剪保存失败';
      await this.closeResolvedSource();
    } finally {
      this.saving = false;
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
    Column() {
      // 主题色依赖：切色时让整页重新求值（零尺寸，不参与布局）
      AccentColorSentinel()
      Row({ space: 12 }) {
        IconCircleButton({
          symbol: $r('sys.symbol.chevron_left'),
          glass: true,
          onAction: () => {
            router.back();
          }
        })
        Text('裁剪背景')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontFamily(this.appFontFamily('裁剪背景'))
          .fontColor(hwTextPrimary(this.isDarkMode))
          .layoutWeight(1)
        Text(this.saving ? '保存中...' : '完成')
          .fontSize(16)
          .fontFamily(this.appFontFamily(this.saving ? '保存中...' : '完成'))
          .fontWeight(this.saving ? FontWeight.Medium : this.appFontWeight())
          .fontColor(this.saving ? hwTextSecondary(this.isDarkMode) : resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()))
          .padding({ left: 10, right: 10 })
          .onClick(() => {
            this.confirmCrop();
          })
      }
      .width('100%')
      .height(56 + this.statusBarHeight)
      .padding({ left: 16, right: 16, top: this.statusBarHeight })
      .backgroundEffect({ radius: 12, color: topBarGlassColor(this.isDarkMode) })

      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(13)
          .fontFamily(this.appFontFamily(this.errorMessage))
          .fontWeight(this.appFontWeight())
          .fontColor(hwDanger(this.isDarkMode))
          .padding(8)
      }

      Stack({ alignContent: Alignment.TopStart }) {
        Image(this.sourceUri)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)

        Column()
          .width('100%')
          .height(this.cropY)
          .backgroundColor('#66000000')

        Column()
          .width('100%')
          .height(Math.max(0, this.areaHeight - this.cropY - this.cropHeight()))
          .position({ x: 0, y: this.cropY + this.cropHeight() })
          .backgroundColor('#66000000')

        Column()
          .width(this.cropX)
          .height(this.cropHeight())
          .position({ x: 0, y: this.cropY })
          .backgroundColor('#66000000')

        Column()
          .width(Math.max(0, this.areaWidth - this.cropX - this.cropWidth))
          .height(this.cropHeight())
          .position({ x: this.cropX + this.cropWidth, y: this.cropY })
          .backgroundColor('#66000000')

        Column()
          .width(this.cropWidth)
          .height(this.cropHeight())
          .position({ x: this.cropX, y: this.cropY })
          .border({ width: 2, color: Color.White })
          .gesture(
            PanGesture({ fingers: 1, distance: 1 })
              .onActionStart((event: GestureEvent) => {
                this.onCropBoxGestureStart(event);
              })
              .onActionUpdate((event: GestureEvent) => {
                this.onCropBoxGestureUpdate(event);
              })
          )

        Column()
          .width(32)
          .height(32)
          .borderRadius(16)
          .backgroundColor(Color.White)
          .border({ width: 3, color: this.accentOrPrimary() })
          .position({
            x: this.cropX + this.cropWidth - 16,
            y: this.cropY + this.cropHeight() - 16
          })
          .gesture(
            PanGesture({ fingers: 1, distance: 1 })
              .onActionStart((event: GestureEvent) => {
                this.onHandleGestureStart(event);
              })
              .onActionUpdate((event: GestureEvent) => {
                this.onHandleGestureUpdate(event);
              })
          )
      }
      .width('100%')
      .layoutWeight(1)
      .clip(true)
      .onAreaChange((oldValue: Area, newValue: Area) => {
        this.onPreviewAreaChange(oldValue, newValue);
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(resolvePageBackground(this.isDarkMode, this.pageBackground))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    .keyboardShortcut(FunctionKey.ESC, [], () => {
      router.back();
    })
  }
}
