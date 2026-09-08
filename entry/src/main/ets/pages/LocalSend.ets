import { LogCapture as Lg } from '../common/LogCapture';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
import { fileUri } from '@kit.CoreFileKit';
import { AppServices } from '../common/AppServices';
import { FilePickerHelper } from '../common/FilePickerHelper';
import { DeviceEndpoint, IncomingFile, OutgoingFile, TransferEvent, TransferTask } from '../model/TransferModels';
import { DeviceList } from '../view/DeviceList';
import { IconCircleButton } from '../components/IconCircleButton';
import { AppBackground } from '../components/AppBackground';
import { HwColor, HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwPrimary, hwPrimaryButton, hwSurface, hwGlassSurface, hwGlassBorder } from '../utils/DesignTokens';
import { isApi26OrAbove, immersiveMaterialModifier, legacyMaterialModifier } from '../utils/SystemMaterial';
import { PinDialogGuard } from '../common/PinDialogGuard';
import { SettingsStore } from '../common/SettingsStore';
import { sharedFilesFromParams } from '../common/ShareHandleUtil';

@Entry
@Component
struct LocalSendPage {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('immersiveLightEnabled') immersiveLightEnabled: boolean = true;
  @StorageLink('fontMode') fontMode: string = 'system';
  @StorageLink('fontFamilyEn') fontFamilyEn: string = 'system';
  @StorageLink('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageLink('fontWeightMode') fontWeightMode: string = 'system';
  @StorageLink('fontWeightValue') fontWeightValue: number = 400;
  @State devices: DeviceEndpoint[] = [];
  @State selectedFiles: OutgoingFile[] = [];
  @State receivedFiles: IncomingFile[] = [];
  @State statusText: string = '正在扫描 LocalSend 设备';
  @State lastPeerName: string = '';
  @State pinEntryTaskId: string = '';
  @State pinEntryValue: string = '';
  private services?: AppServices;
  private readonly deviceListener: (device: DeviceEndpoint) => void = (device: DeviceEndpoint): void => {
    if (device.protocol !== 'localsend') {
      return;
    }
    // 保持卡片顺序稳定：已存在的设备原地更新（不挪位置），新设备才追加到末尾。
    const index = this.devices.findIndex((item: DeviceEndpoint): boolean => item.id === device.id);
    if (index >= 0) {
      // 设备信息无实质变化时不再重建数组，避免每次扫描回调都触发整段设备卡片重排版。
      if (!this.deviceEquals(this.devices[index], device)) {
        this.devices = this.devices.map((item: DeviceEndpoint, i: number): DeviceEndpoint => i === index ? device : item);
      }
    } else {
      this.devices = this.devices.concat([device]);
    }
    this.statusText = '已发现 ' + this.devices.length + ' 台 LocalSend 设备';
  };

  private deviceEquals(a: DeviceEndpoint, b: DeviceEndpoint): boolean {
    return a.id === b.id && a.name === b.name && a.address === b.address &&
      a.port === b.port && a.protocol === b.protocol && a.source === b.source &&
      a.fingerprint === b.fingerprint;
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
  private readonly transferListener: (event: TransferEvent) => void = (event: TransferEvent): void => {
    this.onTransferEvent(event);
    // 可能在本页未打开时（如主页）接收了文件：仅靠实时事件会漏掉，统一从
    // TransferManager 保留的 receive 任务里聚合（去重），保证页面总能显示已接收列表与数量。
    if (event.kind === 'incoming' || event.kind === 'completed') {
      this.lastPeerName = event.task.device.name;
      this.syncReceivedFiles();
    }
  };

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    // 预热系统文件选择器实例，让首次点击设备卡片不再耗费在构造选择器上，降低点击响应时延。
    FilePickerHelper.warmUp(context);
    this.services = AppServices.get(context);
    this.services.localsend.addListener(this.deviceListener);
    this.services.transfer.addListener(this.transferListener);
    // 进入页面即回填历史接收（含在本页未打开时已完成接收的文件），避免列表/计数为空。
    this.syncReceivedFiles();
    this.loadShareParams();
    this.showHttpsNotice();
    // 等待首页的接收/服务端启动完成，确保 UDP/mDNS 使用真实端口后再扫描，
    // 避免 LocalSend 页抢在 startReceive 完成前开始扫描。
    this.services.startReceive().then((): void => {
      this.services?.startLocalSendScanning();
      if (this.statusText.indexOf('已发现') < 0 && this.statusText.indexOf('已接收') < 0) {
        this.statusText = '正在扫描 LocalSend 设备';
      }
    }).catch((error: BusinessError): void => {
      this.statusText = '启动失败: ' + error.message;
    });
  }

  private showHttpsNotice(): void {
    const context = getContext(this) as common.UIAbilityContext;
    SettingsStore.load(context).then((settings) => {
      if (settings.localSendNoticeShown) {
        return;
      }
      settings.localSendNoticeShown = true;
      SettingsStore.save(context, settings).catch((): void => undefined);
      this.promptHttpsNotice();
    }).catch((): void => undefined);
  }

  private promptHttpsNotice(): void {
    promptAction.showDialog({
      title: 'LocalSend 传输说明',
      message: '发送到启用加密(HTTPS)的 LocalSend 对端已支持；本机接收暂用明文，接收加密将在后续支持。',
      buttons: [
        { text: '知道了', color: HwColor.primary }
      ]
    }).catch((): void => undefined);
  }

  onPageHide(): void {
    this.stopLocalSendScan();
  }

  aboutToDisappear(): void {
    this.stopLocalSendScan();
    // 退出页面不保存本次接收记录（仅本页 @State，主页记录由 TransferManager 保留）。
    this.receivedFiles = [];
    this.services?.localsend.removeListener(this.deviceListener);
    this.services?.transfer.removeListener(this.transferListener);
  }

  private stopLocalSendScan(): void {
    this.services?.stopLocalSendScanning();
  }

  /** 从 TransferManager 保留的 receive 任务中聚合已接收文件（去重），回填本页列表与计数。 */
  private syncReceivedFiles(): void {
    if (this.services === undefined) {
      return;
    }
    const seen = new Set<string>();
    const all: IncomingFile[] = [];
    const tasks = this.services.transfer.listTasks();
    for (let i = 0; i < tasks.length; i++) {
      const task = tasks[i];
      if (task.direction !== 'receive') {
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
    if (all.length > 0) {
      this.receivedFiles = all.slice();
      this.statusText = '已接收：' + all.map((file: IncomingFile): string => file.name).join('、');
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      AppBackground()
      Column() {
        Scroll() {
          Column({ space: 12 }) {
            Blank().height(56 + this.statusBarHeight)
            this.statusCard()
            this.selectFileCard()
            if (this.pinEntryTaskId.length > 0) {
              this.pinEntryCard()
            }
            if (this.selectedFiles.length > 0) {
              Text('已选择 ' + this.selectedFiles.length + ' 个文件，点击下方设备即可发送')
                .fontSize(12).fontFamily(this.appFontFamily('已选择 个文件，点击下方设备即可发送')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).width('100%').padding({ left: 4, right: 4, bottom: 8 })
            }
            Text('附近设备').fontSize(14).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('附近设备')).fontColor(hwTextPrimary(this.isDarkMode)).width('100%').padding({ left: 4 })
            DeviceList({
              devices: this.devices,
              onSelect: (device: DeviceEndpoint): void => {
                this.sendOrPick(device).catch((error: Error): void => promptAction.showToast({ message: error.message }));
              }
            })
            if (this.devices.length === 0) {
              Text('请打开对端 LocalSend，并保持双方在同一网络').fontSize(14).fontFamily(this.appFontFamily('请打开对端 LocalSend，并保持双方在同一网络')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
                .width('100%').textAlign(TextAlign.Center).padding({ top: 24 });
            }
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
        IconCircleButton({ symbol: $r('sys.symbol.chevron_left'), buttonSize: 40, iconSize: 20, onAction: (): void => router.back() })
        Text('LocalSend').fontSize(20).fontWeight(FontWeight.Bold).fontFamily(this.appFontFamily('LocalSend')).fontColor(hwTextPrimary(this.isDarkMode)).margin({ left: HwSpace.md })
        Blank()
      }
      .width('100%')
      .height(56 + this.statusBarHeight)
      .padding({ left: 16, right: 16, top: this.statusBarHeight })
      .backgroundEffect({ radius: 12, color: '#66FFFFFF' })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDarkMode ? HwColor.backgroundDark : HwColor.background)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  statusCard() {
    Column({ space: 4 }) {
      Text('状态').fontSize(12).fontFamily(this.appFontFamily('状态')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
      Text(this.statusText).fontSize(14).fontFamily(this.appFontFamily(this.statusText)).fontWeight(this.appFontWeight()).fontColor(hwTextPrimary(this.isDarkMode))
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(this.immersiveLightEnabled && isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  selectFileCard() {
    Row({ space: 12 }) {
      Text('选择文件').fontSize(16).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('选择文件')).fontColor(hwPrimary(this.isDarkMode)).layoutWeight(1)
      Text(this.selectedFiles.length > 0 ? '已选择 ' + this.selectedFiles.length + ' 个文件' : '从系统中选择要发送的文件')
        .fontSize(12).fontFamily(this.appFontFamily('从系统中选择要发送的文件')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([hwTextSecondary(this.isDarkMode)])
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(this.immersiveLightEnabled && isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
    .onClick(() => this.pickFiles())
  }

  @Builder
  pinEntryCard() {
    Column({ space: 8 }) {
      Text('对端要求 PIN')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontFamily(this.appFontFamily('对端要求 PIN'))
        .fontColor(hwTextPrimary(this.isDarkMode))
        .width('100%')
      Text('请输入对端设置的接收 PIN 继续发送（LocalSend 官方语义）。')
        .fontSize(12)
        .fontColor(hwTextSecondary(this.isDarkMode))
        .fontFamily(this.appFontFamily('请输入对端设置的接收 PIN 继续发送（LocalSend 官方语义）。'))
        .fontWeight(this.appFontWeight())
        .width('100%')
      TextInput({ text: this.pinEntryValue, placeholder: '对端接收 PIN' })
        .width('100%')
        .height(44)
        .fontSize(15)
        .fontColor(hwTextPrimary(this.isDarkMode))
        .backgroundColor(hwSurface(this.isDarkMode))
        .borderRadius(HwRadius.control)
        .onChange((value: string) => {
          this.pinEntryValue = value;
        })
      Row({ space: 12 }) {
        Button('取消', { type: ButtonType.Capsule })
          .layoutWeight(1)
          .backgroundColor(HwColor.background)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .onClick(() => this.cancelPinEntry())
        Button('确认发送', { type: ButtonType.Capsule })
          .layoutWeight(1)
          .backgroundColor(hwPrimaryButton(this.isDarkMode))
          .fontColor(Color.White)
          .onClick(() => this.confirmPinEntry())
      }
      .width('100%')
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(this.immersiveLightEnabled && isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  private confirmPinEntry(): void {
    const taskId = this.pinEntryTaskId;
    const value = this.pinEntryValue;
    this.pinEntryTaskId = '';
    this.pinEntryValue = '';
    this.services?.transfer.submitPinEntry(taskId, value.trim().length > 0 ? value.trim() : null);
  }

  private cancelPinEntry(): void {
    const taskId = this.pinEntryTaskId;
    this.pinEntryTaskId = '';
    this.pinEntryValue = '';
    this.services?.transfer.submitPinEntry(taskId, null);
  }

  @Builder
  receivedFilesCard() {
    Column({ space: 6 }) {
      Text('已接收 ' + this.receivedFiles.length + ' 个文件').fontSize(14).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('已接收 个文件')).fontColor(hwTextPrimary(this.isDarkMode))
      ForEach(this.receivedFiles, (file: IncomingFile): void => {
        Column({ space: 4 }) {
          Row({ space: 8 }) {
            Text(file.name).layoutWeight(1).fontSize(13).fontFamily(this.appFontFamily(file.name)).fontWeight(this.appFontWeight()).fontColor(hwTextPrimary(this.isDarkMode))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.fileSizeText(file.size)).fontSize(12).fontFamily(this.appFontFamily(this.fileSizeText(file.size))).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
            Button('打开', { type: ButtonType.Capsule }).height(26).fontSize(12).fontFamily(this.appFontFamily('打开'))
              .backgroundColor(hwPrimaryButton(this.isDarkMode)).fontColor(Color.White)
              .onClick(() => this.openFile(file))
          }.width('100%')
          Text(file.savedPath).fontSize(11).fontFamily(this.appFontFamily(file.savedPath)).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }.width('100%')
      }, (file: IncomingFile): string => file.savedPath + ':' + file.name)
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(this.immersiveLightEnabled && isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  private pickFiles(): void {
    this.pickFilesNow().catch((error: BusinessError): void => promptAction.showToast({ message: '选择文件失败：' + error.message }));
  }

  private pickFilesNow(): Promise<OutgoingFile[]> {
    const context = getContext(this) as common.UIAbilityContext;
    // 复用单例 DocumentViewPicker + 异步 fs.stat：不重复构造系统选择器、不阻塞主线程。
    return FilePickerHelper.pick(context).then((files: OutgoingFile[]): OutgoingFile[] => {
      this.selectedFiles = files;
      return files;
    });
  }

  private async sendOrPick(device: DeviceEndpoint): Promise<void> {
    if (this.selectedFiles.length === 0) {
      // 未选择文件时点击设备卡片：先弹出文件选择，选定后自动发送给该设备。
      const files: OutgoingFile[] = await this.pickFilesNow().catch((): OutgoingFile[] => []);
      if (files.length === 0) {
        return; // 用户取消了选择
      }
    }
    await this.send(device);
  }

  // 从系统分享选择页跳转过来时，路由参数里携带共享文件，直接载入为已选择文件。
  private loadShareParams(): void {
    const files = sharedFilesFromParams();
    if (files.length > 0) {
      this.selectedFiles = files;
    }
  }

  private async send(device: DeviceEndpoint): Promise<void> {
    if (this.selectedFiles.length === 0) {
      throw new Error('请先选择文件');
    }
    if (this.services === undefined) {
      throw new Error('传输服务尚未就绪');
    }
    await this.services.transfer.send(device, this.selectedFiles);
    this.selectedFiles = [];
    promptAction.showToast({ message: 'LocalSend 传输已完成' });
  }

  private onTransferEvent(event: TransferEvent): void {
    if (event.kind === 'pin-request') {
      this.showPinDialog(event.task);
    }
    if (event.kind === 'pin-entry') {
      this.pinEntryTaskId = event.task.id;
      this.pinEntryValue = '';
    }
    if (event.kind === 'failed' && event.task.direction === 'send') {
      this.selectedFiles = event.task.files;
      promptAction.showToast({ message: '发送失败：' + event.task.error });
    }
    // 接收完成的「接收完成」弹窗统一由 MainPage 处理（含“打开”），这里不再重复弹
    // toast/dialog，避免同一 completed 事件在主页与 LocalSend 页各弹一次。
  }

  private showPinDialog(task: TransferTask): void {
    if (!PinDialogGuard.tryBegin()) {
      return;
    }
    promptAction.showDialog({
      title: task.direction === 'receive' ? '接收请求' : 'LocalSend 发送确认',
      message: task.direction === 'receive'
        ? (task.pin.length > 0
          ? `收到来自「${task.device.name}」的传输请求，共 ${task.files.length} 个文件。\n双方 PIN：${task.pin}\n请核对对端 PIN 一致后确认接收。`
          : `收到来自「${task.device.name}」的传输请求，共 ${task.files.length} 个文件。是否接收？`)
        : `正在发送给「${task.device.name}」。请确认双方设备显示的 PIN 均为 ${task.pin}，确认后开始传输。`,
      buttons: [
        { text: '取消', color: HwColor.textSecondary },
        { text: '确认', color: HwColor.primary }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      PinDialogGuard.end();
      this.services?.transfer.confirmPin(task.id, result.index === 1);
    }).catch((): void => {
      PinDialogGuard.end();
      this.services?.transfer.confirmPin(task.id, false);
    });
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
        Lg.e('LocalSend open file failed: ' + JSON.stringify(error));
        promptAction.showToast({ message: '无法打开：' + (error.message ?? ''), duration: 2000 });
      });
    } catch (error) {
      Lg.e('LocalSend open file error: ' + JSON.stringify(error));
      promptAction.showToast({ message: '无法打开文件', duration: 2000 });
    }
  }
}
