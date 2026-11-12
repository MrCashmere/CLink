import { LogCapture as Lg } from '../common/LogCapture';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
import pasteboard from '@ohos.pasteboard';
import { fileUri } from '@kit.CoreFileKit';
import { AppServices } from '../common/AppServices';
import { SettingsStore } from '../common/SettingsStore';
import { FilePickerHelper } from '../common/FilePickerHelper';
import { IncomingFile, OutgoingFile, TransferEvent, WebShareInfo } from '../model/TransferModels';
import { IconCircleButton } from '../components/IconCircleButton';
import { AppBackground } from '../components/AppBackground';
import { HwColor, HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwPrimary, hwPrimaryButton, hwSurface, hwOnline, hwDanger, hwGlassBorder, reloadAppTheme, resolvePageBackground, onAccentColor, topBarGlassColor, resolvePrimaryColor, resolvePrimaryButtonColor } from '../utils/DesignTokens';
import { cardGlassEffect, toastSystemMaterial, cardGlassBorderColor, cardGlassShadow } from '../utils/SystemMaterial';
import { CardSurface } from '../components/CardSurface';
import { AccentColorSentinel } from '../components/MaterialCard';

@Entry
@Component
struct LanWebTransferPage {
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
  @State deviceName: string = '羊绒互传';
  @State linkText: string = '';
  @State addressEmpty: boolean = false;
  @State receivedFiles: IncomingFile[] = [];
  @State sharedFiles: WebShareInfo[] = [];
  private services?: AppServices;

  private readonly transferListener: (event: TransferEvent) => void = (event: TransferEvent): void => {
    if (event.kind === 'incoming' || event.kind === 'completed' || event.kind === 'failed') {
      this.syncReceivedFiles();
    }
  };

  /** 热点地址一探到就改写链接（本页没有定时刷新，全靠这个回调摆脱 10.x 蜂窝地址）。 */
  private readonly hotspotAddressListener: (address: string) => void = (address: string): void => {
    this.refreshLink();
  };

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    this.services = AppServices.get(context);
    this.services.transfer.addListener(this.transferListener);
    this.services.onHotspotAddressChange(this.hotspotAddressListener);
    // 读取设备别名（用于网页端显示设备名）。
    SettingsStore.load(context).then((settings): void => {
      this.deviceName = settings.alias.length > 0 ? settings.alias : '羊绒互传';
    }).catch((): void => undefined);
    this.refreshLink();
    this.syncReceivedFiles();
    this.refreshSharedFiles();
  }

  aboutToDisappear(): void {
    this.services?.transfer.removeListener(this.transferListener);
    this.services?.offHotspotAddressChange(this.hotspotAddressListener);
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

  private refreshLink(): void {
    if (this.services === undefined) {
      return;
    }
    const link = this.services.localsendWebLink();
    this.addressEmpty = link.address.length === 0;
    this.linkText = this.addressEmpty ? '' : link.scheme + '://' + link.address + ':' + link.port;
  }

  private copyLink(): void {
    if (this.linkText.length === 0) {
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '尚未获取到局域网地址，请检查网络', duration: 2000 });
      return;
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.linkText);
      pasteboard.getSystemPasteboard().setData(data).then((): void => {
        promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '链接已复制', duration: 1500 });
      }).catch((error: BusinessError): void => {
        Lg.w('LanWeb copy link failed: ' + error.message);
        promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '复制失败：' + error.message, duration: 2000 });
      });
    } catch (error) {
      Lg.w('LanWeb copy link error: ' + JSON.stringify(error));
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '复制失败，请重试', duration: 2000 });
    }
  }

  /** 从 TransferManager 保留的 receive 任务中聚合已接收文件（去重）。 */
  private syncReceivedFiles(): void {
    if (this.services === undefined) {
      return;
    }
    const seen = new Set<string>();
    const all: IncomingFile[] = [];
    const tasks = this.services.transfer.listTasks();
    for (let i = 0; i < tasks.length; i++) {
      const task = tasks[i];
      if (task.direction !== 'receive' || task.device.protocol !== 'localsend') {
        continue;
      }
      const files = task.receivedFiles;
      for (let j = 0; j < files.length; j++) {
        const file = files[j];
        const key = file.savedPath + ':' + file.name;
        if (!seen.has(key)) {
          seen.add(key);
          all.push(file);
        }
      }
    }
    this.receivedFiles = all.slice();
  }

  /** 选择本机文件并注册为「网页端可下载」共享。 */
  private pickShareFiles(): void {
    const context = getContext(this) as common.UIAbilityContext;
    FilePickerHelper.pick(context).then((files: OutgoingFile[]): void => {
      if (files.length === 0) {
        return; // 用户取消
      }
      for (const file of files) {
        this.services?.transfer.shareFileForWeb(file.path, file.name, file.size);
      }
      this.refreshSharedFiles();
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '已开放 ' + files.length + ' 个文件供网页端下载', duration: 2000 });
    }).catch((error: BusinessError): void => {
      Lg.w('LanWeb pick share file failed: ' + error.message);
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '选择文件失败：' + error.message, duration: 2000 });
    });
  }

  private refreshSharedFiles(): void {
    this.sharedFiles = this.services?.transfer.listWebShares() ?? [];
  }

  private removeShare(id: string): void {
    this.services?.transfer.removeWebShare(id);
    this.refreshSharedFiles();
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
        Lg.e('LanWeb open file failed: ' + JSON.stringify(error));
        promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '无法打开：' + (error.message ?? ''), duration: 2000 });
      });
    } catch (error) {
      Lg.e('LanWeb open file error: ' + JSON.stringify(error));
      promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: '无法打开文件', duration: 2000 });
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
          Column({ space: 12 }) {
            Blank().height(56 + this.statusBarHeight)
            this.statusCard()
            this.linkCard()
            this.shareCard()
            this.howToCard()
            if (this.receivedFiles.length > 0) {
              this.receivedFilesCard()
            }
          }
          .width('100%')
          .padding({ left: HwSpace.lg, right: HwSpace.lg, top: HwSpace.lg, bottom: 96 })
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
        IconCircleButton({ symbol: $r('sys.symbol.chevron_left'), glass: true, buttonSize: 40, iconSize: 20, onAction: (): void => router.back() })
        Text('局域网网页传输').fontSize(20).fontWeight(FontWeight.Bold).fontFamily(this.appFontFamily('局域网网页传输')).fontColor(hwTextPrimary(this.isDarkMode)).margin({ left: HwSpace.md })
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
  linkCard() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 10 }) {
        Text('局域网访问链接')
          .fontSize(12)
          .fontFamily(this.appFontFamily('局域网访问链接'))
          .fontWeight(this.appFontWeight())
          .fontColor(hwTextSecondary(this.isDarkMode))
          .width('100%')
        if (this.addressEmpty) {
          Text('未获取到局域网地址，请确认已连接 Wi-Fi 并重试')
            .fontSize(15)
            .fontFamily(this.appFontFamily('未获取到局域网地址，请确认已连接 Wi-Fi 并重试'))
            .fontWeight(this.appFontWeight())
            .fontColor(hwTextPrimary(this.isDarkMode))
            .width('100%')
        } else {
          Row({ space: 10 }) {
            Text(this.linkText)
              .fontSize(15)
              .fontFamily(this.appFontFamily(this.linkText))
              .fontWeight(this.appFontWeight())
              .fontColor(resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Button('复制', { type: ButtonType.Capsule })
              .height(34)
              .fontSize(13)
              .fontFamily(this.appFontFamily('复制'))
              .fontColor(onAccentColor(this.accentOrPrimary()))
              .padding({ left: 16, right: 16 })
              .backgroundColor(resolvePrimaryButtonColor(this.isDarkMode, this.accentOrPrimary()))
              .onClick(() => this.copyLink())
          }
          .width('100%')
        }
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

  @Builder
  shareCard() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 10 }) {
        Row({ space: 12 }) {
          IconCircleButton({ symbol: $r('sys.symbol.share'), buttonSize: 40, iconSize: 19 })
          Column({ space: 2 }) {
            Text('发送文件到网页端')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontFamily(this.appFontFamily('发送文件到网页端'))
              .fontColor(hwTextPrimary(this.isDarkMode))
            Text('选择本机文件后，网页端可下载')
              .fontSize(12)
              .fontColor(hwTextSecondary(this.isDarkMode))
              .fontFamily(this.appFontFamily('选择本机文件后，网页端可下载'))
              .fontWeight(this.appFontWeight())
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor([hwTextSecondary(this.isDarkMode)])
        }
        .width('100%')
        .onClick(() => this.pickShareFiles())

        if (this.sharedFiles.length > 0) {
          Column({ space: 6 }) {
            ForEach(this.sharedFiles, (file: WebShareInfo): void => {
              Row({ space: 8 }) {
                Text(file.name).layoutWeight(1).fontSize(13).fontFamily(this.appFontFamily(file.name)).fontWeight(this.appFontWeight()).fontColor(hwTextPrimary(this.isDarkMode))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.fileSizeText(file.size)).fontSize(12).fontFamily(this.appFontFamily(this.fileSizeText(file.size))).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
                Button('停止', { type: ButtonType.Capsule }).height(26).fontSize(12).fontFamily(this.appFontFamily('停止'))
                  // 中性底：这是「次级按钮」，不该跟着主题色走，也不能直接读模块级 HwColor
                  .backgroundColor(hwSurface(this.isDarkMode))
                  .fontColor(hwTextSecondary(this.isDarkMode))
                  .onClick(() => this.removeShare(file.id))
              }.width('100%')
            }, (file: WebShareInfo): string => file.id + ':' + this.accentColor)
          }
          .width('100%')
          .padding({ top: 4 })
        } else {
          Text('尚未选择文件。点击上方选择要共享给网页端下载的文件。')
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('尚未选择文件。点击上方选择要共享给网页端下载的文件。'))
            .fontWeight(this.appFontWeight())
            .width('100%')
        }
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

  @Builder
  statusCard() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        IconCircleButton({ symbol: $r('sys.symbol.wifi'), buttonSize: 40, iconSize: 19 })
        Column({ space: 2 }) {
          Text(this.deviceName)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily(this.deviceName))
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text('等待对端浏览器通过链接发送文件')
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('等待对端浏览器通过链接发送文件'))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('接收中')
          .fontSize(12)
          .fontColor(hwOnline(this.isDarkMode))
          .fontFamily(this.appFontFamily('接收中'))
          .fontWeight(this.appFontWeight())
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

  @Builder
  howToCard() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 6 }) {
        Text('使用说明')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.appFontFamily('使用说明'))
          .fontColor(hwTextPrimary(this.isDarkMode))
          .width('100%')
        Text('1. 在「同一局域网」内的电脑/手机上打开上面的链接。')
          .fontSize(13)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('1. 在「同一局域网」内的电脑/手机上打开上面的链接。'))
          .fontWeight(this.appFontWeight())
          .width('100%')
        Text('2. 在对端浏览器内选择文件（可多选），点击「发送到本机」。')
          .fontSize(13)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('2. 在对端浏览器内选择文件（可多选），点击「发送到本机」。'))
          .fontWeight(this.appFontWeight())
          .width('100%')
        Text('3. 保持本应用在前台，收到请求后点击「确认」即可接收。')
          .fontSize(13)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('3. 保持本应用在前台，收到请求后点击「确认」即可接收。'))
          .fontWeight(this.appFontWeight())
          .width('100%')
        Text('4. 安装了 VMware 的 Windows 电脑可能会因为 IP 冲突无法使用热点连接到本设备的局域网网页')
          .fontSize(13)
          .fontColor(hwDanger(this.isDarkMode))
          .fontFamily(this.appFontFamily('4. 安装了 VMware 的 Windows 电脑可能会因为 IP 冲突无法使用热点连接到本设备的局域网网页'))
          .fontWeight(FontWeight.Bold)
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
    }
  }

  @Builder
  receivedFilesCard() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 6 }) {
        Text('已接收 ' + this.receivedFiles.length + ' 个文件').fontSize(14).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('已接收 个文件')).fontColor(hwTextPrimary(this.isDarkMode))
        ForEach(this.receivedFiles, (file: IncomingFile): void => {
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
}
