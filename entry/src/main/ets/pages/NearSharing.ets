import { LogCapture as Lg } from '../common/LogCapture';
import { fileUri } from '@kit.CoreFileKit';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DeviceEndpoint, IncomingFile, OutgoingFile } from '../model/TransferModels';
import { DeviceList } from '../view/DeviceList';
import { IconCircleButton } from '../components/IconCircleButton';
import { AppBackground } from '../components/AppBackground';
import { HwColor, HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwPrimary, hwPrimaryButton, hwGlassSurface, hwGlassBorder } from '../utils/DesignTokens';
import { isApi26OrAbove, immersiveMaterialModifier, legacyMaterialModifier } from '../utils/SystemMaterial';
import { SettingsStore } from '../common/SettingsStore';
import { sharedFilesFromParams } from '../common/ShareHandleUtil';
import { FilePickerHelper } from '../common/FilePickerHelper';
import { NearbyScanHub } from '../common/NearbyScanHub';
import { WindowsNearbyOutgoingFile } from '../windowsnearby/WindowsNearbySender';

@Entry
@Component
struct NearSharing {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('immersiveLightEnabled') immersiveLightEnabled: boolean = true;
  @StorageLink('fontMode') fontMode: string = 'system';
  @StorageLink('fontFamilyEn') fontFamilyEn: string = 'system';
  @StorageLink('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageLink('fontWeightMode') fontWeightMode: string = 'system';
  @StorageLink('fontWeightValue') fontWeightValue: number = 400;
  @State devices: DeviceEndpoint[] = [];
  @State manualDevices: DeviceEndpoint[] = [];
  @State selectedFiles: OutgoingFile[] = [];
  @State receivedFiles: IncomingFile[] = [];
  @State progress: number = 0;
  @State incomingPeer: string = '';
  @State jumpedToReceive: boolean = false;
  @State manualIp: string = '';
  @State status: string = '正在开启 Windows Nearby 广播与扫描';
  private hub?: NearbyScanHub;
  private lastWindowsCompleted: boolean = false;
  private readonly onDevicesChanged: () => void = (): void => {
    this.syncDevices();
  };
  private readonly onReceiveChanged: () => void = (): void => {
    this.syncReceiving();
  };

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
    // Windows 发现 / 接收 / 发送均由全局 NearbyScanHub 独占；本页只消费其状态，不再自建
    // 扫描器、接收器或发送器，避免与全局 BLE 单例 / TCP 5040 接收器重复绑定。
    const context = getContext(this) as common.UIAbilityContext;
    // 预热系统文件选择器实例，让首次点击设备卡片不再耗费在构造选择器上，降低点击响应时延。
    FilePickerHelper.warmUp(context);
    this.hub = NearbyScanHub.get(context);
    this.hub.setOnChange(this.onDevicesChanged);
    this.hub.setOnWindowsReceiveChange(this.onReceiveChanged);
    this.hub.ensureStarted();
    // 记录进入页面时的完成状态，避免把既有的「已完成」当成新完成而自动跳转。
    this.lastWindowsCompleted = this.hub.getWindowsReceiveCompleted();
    this.syncDevices();
    this.syncReceiving();
    this.loadShareParams();
    this.maybePromptBtMac(context);
  }

  private maybePromptBtMac(context: common.UIAbilityContext): void {
    SettingsStore.load(context).then((settings) => {
      if (settings.btMac.trim().length > 0) {
        return;
      }
      promptAction.showDialog({
        title: 'Windows Nearby 接收需要蓝牙地址',
        message: 'Windows 是通过蓝牙（RFCOMM）向手机发送文件的，需要手机的真实蓝牙 MAC 地址才能建立连接。\n\n请到「设置 → 关于本机 → 状态信息 → 蓝牙地址」复制本机地址，粘贴到 设置 → Windows Nearby 蓝牙 MAC 地址 中。示例：AA:BB:CC:DD:EE:FF',
        buttons: [
          { text: '稍后', color: HwColor.textSecondary },
          { text: '去填写', color: HwColor.primary }
        ]
      }).then((result: promptAction.ShowDialogSuccessResponse): void => {
        if (result.index === 1) {
          router.pushUrl({ url: 'pages/Settings' }).catch((): void => {
            this.status = '未找到设置页';
          });
        }
      }).catch((): void => undefined);
    });
  }

  aboutToDisappear(): void {
    // 全局扫描 / 接收由应用进程生命周期常开，本页离开只退订监听。
    this.hub?.removeOnChange(this.onDevicesChanged);
    this.hub?.removeOnWindowsReceiveChange(this.onReceiveChanged);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      AppBackground()
      Column() {
        Scroll() {
          Column({ space: 12 }) {
            Blank().height(56 + this.statusBarHeight)
            Text(this.status).fontSize(13).fontFamily(this.appFontFamily(this.status)).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).width('100%')
            this.selectFileCard()
            this.manualSendCard()
            if (this.incomingPeer.length > 0) {
              Text('对端：' + this.incomingPeer).fontSize(13).fontFamily(this.appFontFamily('对端：' + this.incomingPeer)).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).width('100%')
            }
            if (this.progress > 0 && this.progress < 100) {
              Text('接收进度：' + Math.floor(this.progress) + '%').fontSize(13).fontFamily(this.appFontFamily('接收进度：' + Math.floor(this.progress) + '%')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).width('100%')
            }
            if (this.selectedFiles.length > 0) {
              Text('已选择 ' + this.selectedFiles.length + ' 个文件，点击设备发送').fontSize(12).fontFamily(this.appFontFamily('已选择 个文件，点击设备发送')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).width('100%')
            }
            DeviceList({ devices: this.allDisplayDevices(), onSelect: (device: DeviceEndpoint): void => { this.sendOrPick(device); } })
            if (this.allDisplayDevices().length === 0) {
              Text('请在 Windows 设置中打开“附近共享”').fontSize(14).fontFamily(this.appFontFamily('请在 Windows 设置中打开“附近共享”')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).width('100%').textAlign(TextAlign.Center).padding({ top: 24 })
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
        Text('Windows Nearby').fontSize(20).fontWeight(FontWeight.Bold).fontFamily(this.appFontFamily('Windows Nearby')).fontColor(hwTextPrimary(this.isDarkMode)).margin({ left: HwSpace.md })
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

  @Builder
  selectFileCard() {
    Row({ space: 12 }) {
      Text('选择文件').fontSize(16).fontWeight(FontWeight.Medium).fontFamily(this.appFontFamily('选择文件')).fontColor(hwPrimary(this.isDarkMode)).layoutWeight(1)
      Text(this.selectedFiles.length > 0 ? '已选择 ' + this.selectedFiles.length + ' 个文件' : '从系统选择要发送的文件')
        .fontSize(12).fontFamily(this.appFontFamily('从系统选择要发送的文件')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
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
  manualSendCard() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        TextInput({ placeholder: 'Windows IP（如 192.168.0.118）', text: this.manualIp })
          .layoutWeight(1).height(40).fontSize(14)
          .onChange((value: string): void => {
            this.manualIp = value;
          });
        Button('手动连接发送').height(40).fontSize(13).fontFamily(this.appFontFamily('手动连接发送'))
          .backgroundColor(hwPrimaryButton(this.isDarkMode)).fontColor(Color.White)
          .onClick(() => this.connectManualIp());
      }.width('100%')
      Text('手动指定 Windows IP 可跳过 UDP 发现，用于直接传输')
        .fontSize(11).fontFamily(this.appFontFamily('手动指定 Windows IP 可跳过 UDP 发现，用于直接传输')).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).width('100%')
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(this.immersiveLightEnabled && isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  private gotoReceive(): void {
    const files: string[] = [];
    const sizes: number[] = [];
    const paths: string[] = [];
    for (const file of this.receivedFiles) {
      files.push(file.name);
      sizes.push(file.size);
      paths.push(file.savedPath);
    }
    router.pushUrl({
      url: 'pages/NearSharingReceive',
      params: {
        peer: this.incomingPeer,
        files: files,
        sizes: sizes,
        paths: paths
      }
    }).catch((error: BusinessError): void => {
      promptAction.showToast({ message: '打开接收记录失败：' + error.message });
    });
  }
  private syncDevices(): void {
    if (this.hub === undefined) {
      return;
    }
    // 仅在列表有实质变化时才重建 @State，避免每次发现回调都触发整段设备卡片重排版、占用主线程。
    const next = this.hub.getWindowsDevices();
    if (!this.listEquals(this.devices, next)) {
      this.devices = next;
    }
    this.status = '已发现 ' + this.allDisplayDevices().length + ' 台 Windows 设备';
  }

  private listEquals(a: DeviceEndpoint[], b: DeviceEndpoint[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (!this.deviceEquals(a[i], b[i])) {
        return false;
      }
    }
    return true;
  }

  private deviceEquals(a: DeviceEndpoint, b: DeviceEndpoint): boolean {
    return a.id === b.id && a.name === b.name && a.address === b.address &&
      a.port === b.port && a.protocol === b.protocol && a.source === b.source &&
      a.fingerprint === b.fingerprint;
  }

  private syncReceiving(): void {
    if (this.hub === undefined) {
      return;
    }
    this.receivedFiles = this.hub.getWindowsReceiveFiles();
    this.progress = this.hub.getWindowsReceiveProgress();
    this.incomingPeer = this.hub.getWindowsReceivePeer();
    const completed = this.hub.getWindowsReceiveCompleted();
    if (completed && !this.lastWindowsCompleted && !this.jumpedToReceive) {
      this.jumpedToReceive = true;
      this.status = '接收完成，正在打开接收记录';
      this.gotoReceive();
    }
    this.lastWindowsCompleted = completed;
  }

  private allDisplayDevices(): DeviceEndpoint[] {
    return this.devices.concat(this.manualDevices);
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
      let files: OutgoingFile[] = [];
      try {
        files = await this.pickFilesNow();
      } catch (error) {
        // 选择器本身抛错（如权限/系统页面异常）不静默吞掉，给用户明确反馈。
        promptAction.showToast({ message: '选择文件失败：' + ((error as BusinessError).message ?? JSON.stringify(error)) });
        return;
      }
      if (files.length === 0) {
        return; // 用户取消了选择
      }
    }
    this.send(device);
  }

  // 从系统分享选择页跳转过来时，路由参数里携带共享文件，直接载入为已选择文件。
  private loadShareParams(): void {
    const files = sharedFilesFromParams();
    if (files.length > 0) {
      this.selectedFiles = files;
    }
  }

  private send(device: DeviceEndpoint): void {
    // ForEach keyed by device.id reuses the item component, so the `device`
    // captured by onClick is stale. Always resolve the current device by id.
    const current = this.allDisplayDevices().find((item: DeviceEndpoint): boolean => item.id === device.id);
    const target = current !== undefined ? current : device;
    const sender = this.hub?.windowsSender;
    if (this.selectedFiles.length === 0) {
      Lg.w('羊绒互传 WindowsNearby: send blocked: no file selected');
      promptAction.showToast({ message: '请先选择文件' });
      return;
    }
    if (sender === undefined) {
      Lg.w('羊绒互传 WindowsNearby: send blocked: sender not ready');
      promptAction.showToast({ message: 'Windows Nearby 发送器尚未就绪' });
      return;
    }
    if (target.address.length === 0) {
      Lg.w('羊绒互传 WindowsNearby: send blocked: device has no IP (address empty)');
      promptAction.showToast({ message: '等待 UDP 发现获取 Windows IP' });
      return;
    }
    const files: WindowsNearbyOutgoingFile[] = this.selectedFiles.map((file: OutgoingFile): WindowsNearbyOutgoingFile => ({
      path: file.path,
      name: file.name,
      size: file.size
    }));
    sender.send(target.address, target.port > 0 ? target.port : 5040, files).then((): void => {
      promptAction.showToast({ message: 'Windows Nearby 发送已完成' });
      this.selectedFiles = [];
      this.status = '已发现 ' + this.allDisplayDevices().length + ' 台 Windows 设备';
    }).catch((error: Error): void => {
      promptAction.showToast({ message: '发送失败：' + error.message });
    });
  }

  private connectManualIp(): void {
    const ip = this.manualIp.trim();
    const parts = ip.split('.');
    let valid = parts.length === 4;
    if (valid) {
      for (const part of parts) {
        if (part.length === 0 || part.length > 3) {
          valid = false;
          break;
        }
        const n = Number(part);
        if (Number.isNaN(n) || n < 0 || n > 255) {
          valid = false;
          break;
        }
      }
    }
    if (!valid) {
      promptAction.showToast({ message: '请输入合法的 IPv4 地址' });
      return;
    }
    const id = 'manual-' + ip;
    const device: DeviceEndpoint = {
      id: id,
      name: 'Windows（手动 ' + ip + '）',
      model: 'Windows Nearby',
      protocol: 'windowsnearby',
      address: ip,
      port: 5040,
      https: true,
      fingerprint: ip,
      source: 'manual'
    };
    const exists = this.manualDevices.some((item: DeviceEndpoint): boolean => item.id === id);
    if (!exists) {
      this.manualDevices = this.manualDevices.concat([device]);
    }
    this.status = '指定连接：' + ip;
    this.send(device);
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
        Lg.e('Windows Nearby open file failed: ' + JSON.stringify(error));
        promptAction.showToast({ message: '无法打开：' + (error.message ?? ''), duration: 2000 });
      });
    } catch (error) {
      Lg.e('Windows Nearby open file error: ' + JSON.stringify(error));
      promptAction.showToast({ message: '无法打开文件', duration: 2000 });
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
