import { common } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import promptAction from '@ohos.promptAction';
import { MtaService, MtaRecord } from './MtaService';
import { AppServices } from '../common/AppServices';
import { FilePickerHelper } from '../common/FilePickerHelper';
import { sharedFilesFromParams } from '../common/ShareHandleUtil';
import { DeviceEndpoint, OutgoingFile, TransferTask, TransferEvent } from '../model/TransferModels';
import { AccentColorSentinel } from '../components/MaterialCard';
import { CardSurface } from '../components/CardSurface';
import { DeviceList } from '../view/DeviceList';
import { HwColor, HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwSurface, resolvePrimaryColor, onAccentColor, reloadAppTheme, withAlpha } from '../utils/DesignTokens';
import { cardGlassEffect, cardGlassBorderColor, cardGlassShadow, toastSystemMaterial } from '../utils/SystemMaterial';

/** MTA 独立页内容，只依赖 MtaService 命令接口。 */
@Component
export struct MtaPanel {
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageProp('accentColor') @Watch('onAccentColorChanged') accentColor: string = '';
  @StorageProp('beautifulCards') beautifulCards: boolean = false;
  @StorageProp('classicCards') classicCards: boolean = false;
  @StorageProp('cardShadowBorder') cardShadowBorder: boolean = true;
  @StorageProp('experimentalCards') experimentalCards: boolean = false;
  @StorageProp('fontMode') fontMode: string = 'system';
  @StorageProp('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageProp('fontFamilyEn') fontFamilyEn: string = 'system';
  @StorageProp('fontWeightMode') fontWeightMode: string = 'system';
  @StorageProp('fontWeightValue') fontWeightValue: number = 400;
  @State statusText: string = '';
  @State mtaEnabled: boolean = true;
  @State mtaBusy: boolean = false;
  @State devices: DeviceEndpoint[] = [];
  @State files: OutgoingFile[] = [];
  @State textContent: string = '';
  @State tasks: TransferTask[] = [];
  @State history: MtaRecord[] = [];
  @State brandIndex: number = 0;
  private service?: MtaService;
  private context?: common.UIAbilityContext;
  private brands: number[] = [255, 30, 10, 20, 140, 42, 11, 70, 50];
  private changed: () => void = (): void => this.sync();
  private transferChanged: (event: TransferEvent) => void = (event: TransferEvent): void => {
    if (event.task.device.protocol === 'mta') { this.sync(); }
  };

  aboutToAppear(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      this.context = context;
      this.service = MtaService.get(context);
      this.service.addListener(this.changed);
      AppServices.get(context).transfer.addListener(this.transferChanged);
      this.service.start();
      this.files = sharedFilesFromParams();
      this.sync();
    } catch (error) { this.statusText = '互传联盟初始化失败：' + String(error); }
  }
  aboutToDisappear(): void {
    this.service?.removeListener(this.changed);
    if (this.context !== undefined) { AppServices.get(this.context).transfer.removeListener(this.transferChanged); }
  }
  private sync(): void {
    if (this.service === undefined || this.context === undefined) { return; }
    this.statusText = this.service.status();
    this.devices = this.service.devices();
    this.mtaEnabled = this.service.enabled();
    this.mtaBusy = this.service.isBusy();
    this.history = this.service.records();
    this.brandIndex = Math.max(0, this.brands.indexOf(this.service.brandId()));
    this.tasks = AppServices.get(this.context).transfer.listTasks().filter((task: TransferTask): boolean =>
      task.device.protocol === 'mta' && (task.completedAt === 0 || Date.now() - task.completedAt < 10000));
  }
  onAccentColorChanged(): void { reloadAppTheme(); }
  private appFontFamily(content: string): string {
    if (this.fontMode !== 'custom') { return 'HarmonyOS Sans'; }
    let family = this.fontFamilyEn;
    for (let i = 0; i < content.length; i++) {
      const code = content.charCodeAt(i);
      if (code >= 0x4E00 && code <= 0x9FFF) { family = this.fontFamilyZh; break; }
    }
    return family === 'system' || family.length === 0 ? 'HarmonyOS Sans' : family;
  }
  private appFontWeight(fallback: number = 400): number {
    return this.fontWeightMode === 'custom' ? this.fontWeightValue : fallback;
  }
  private accentOrPrimary(): string { return this.accentColor.length > 0 ? this.accentColor : HwColor.primary; }
  private accent(): string { return resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()); }
  private toast(message: string): void { promptAction.showToast({ systemMaterial: toastSystemMaterial(), message: message }); }
  private async pick(): Promise<void> {
    try { if (this.context !== undefined) { this.files = await FilePickerHelper.pick(this.context); } }
    catch (error) { this.toast('选择文件失败：' + String(error)); }
  }
  private async sendTo(device: DeviceEndpoint): Promise<void> {
    try {
      if (this.files.length === 0 && this.textContent.trim().length === 0) { await this.pick(); }
      if (this.files.length === 0 && this.textContent.trim().length === 0) { return; }
      await this.service?.send(device, this.files, this.files.length === 0 ? this.textContent : undefined);
    } catch (error) { this.toast(String(error)); }
  }
  private async refresh(): Promise<void> {
    try { await this.service?.refresh(); this.sync(); }
    catch (error) { this.toast('刷新失败：' + String(error)); }
  }
  private sizeText(bytes: number): string {
    if (bytes >= 1024 * 1024) { return (bytes / 1024 / 1024).toFixed(1) + ' MB'; }
    return bytes >= 1024 ? (bytes / 1024).toFixed(1) + ' KB' : bytes + ' B';
  }
  private async openRecord(record: MtaRecord): Promise<void> {
    if (record.savedPath.length === 0 || this.context === undefined) { return; }
    try {
      await this.context.startAbility({ action: 'ohos.want.action.viewData', flags: 1,
        uri: record.savedPath.startsWith('file://') ? record.savedPath : fileUri.getUriFromPath(record.savedPath) });
    } catch (error) { this.toast('无法打开文件：' + String(error)); }
  }
  @Builder
  sectionTitle(title: string) {
    Text(title).fontSize(17).fontWeight(this.appFontWeight(500))
      .fontFamily(this.appFontFamily(title)).fontColor(hwTextPrimary(this.isDarkMode))
  }

  @Builder
  taskRow(task: TransferTask) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text((task.direction === 'send' ? '发送至 ' : '接收自 ') + task.device.name).layoutWeight(1)
          .fontSize(14).fontWeight(this.appFontWeight()).fontFamily(this.appFontFamily('传输设备'))
          .fontColor(hwTextPrimary(this.isDarkMode)).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(task.state === 'completed' ? '已完成' : task.state === 'failed' ? '失败' : Math.floor(task.progress) + '%')
          .fontSize(13).fontWeight(this.appFontWeight()).fontFamily(this.appFontFamily('传输状态'))
          .fontColor(hwTextSecondary(this.isDarkMode))
      }.width('100%')
      Progress({ value: task.progress, total: 100, type: ProgressType.Linear }).color(this.accent()).width('100%')
      if (task.error.length > 0) {
        Text(task.error).fontSize(12).fontWeight(this.appFontWeight()).fontFamily(this.appFontFamily(task.error))
          .fontColor(hwTextSecondary(this.isDarkMode))
      }
      if (task.completedAt === 0) {
        Button('取消传输').fontSize(14).fontWeight(this.appFontWeight()).fontFamily(this.appFontFamily('取消传输'))
          .fontColor(this.accent()).backgroundColor(withAlpha(this.accent(), 0.10))
          .height(36).borderRadius(HwRadius.pill)
          .onClick((): void => {
            if (task.direction === 'send') { this.service?.cancelSend().catch((error: Error): void => this.toast(error.message)); }
            else { this.service?.cancelReceive(); }
          })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: HwSpace.md }) {
      AccentColorSentinel()
      CardSurface({ radius: HwRadius.card }) {
        Column({ space: HwSpace.md }) {
          Row({ space: HwSpace.md }) {
            Column({ space: HwSpace.xs }) {
              this.sectionTitle('互传服务')
              Text(this.statusText).fontSize(12).fontWeight(this.appFontWeight()).fontFamily(this.appFontFamily(this.statusText))
                .fontColor(hwTextSecondary(this.isDarkMode))
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.mtaEnabled })
              .selectedColor(resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary())).enabled(!this.mtaBusy)
              .onChange((enabled: boolean): void => {
                this.service?.setEnabled(enabled).catch((error: Error): void => this.toast(error.message));
              })
          }.width('100%')
          Text('请开启蓝牙与 WLAN，并在对方设备上打开互传。').fontSize(13)
            .fontWeight(this.appFontWeight()).fontFamily(this.appFontFamily('请开启蓝牙与 WLAN'))
            .fontColor(hwTextSecondary(this.isDarkMode)).width('100%')
          Button('刷新附近设备').fontSize(14).fontWeight(this.appFontWeight()).fontFamily(this.appFontFamily('刷新附近设备'))
            .fontColor(this.accent()).backgroundColor(withAlpha(this.accent(), 0.10))
            .height(40).width('100%').borderRadius(HwRadius.control)
            .enabled(this.mtaEnabled && !this.mtaBusy).onClick((): void => { void this.refresh(); })
        }.width('100%').alignItems(HorizontalAlign.Start).padding(HwSpace.lg).borderRadius(HwRadius.card)
          .backgroundColor(Color.Transparent)
          .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
          .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
          .clip(true).shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
      }

      if (this.tasks.length > 0) {
        CardSurface({ radius: HwRadius.card }) {
          Column({ space: HwSpace.md }) {
            this.sectionTitle('传输任务')
            ForEach(this.tasks, (task: TransferTask): void => { this.taskRow(task) },
              (task: TransferTask): string => task.id + ':' + task.progress + ':' + task.state)
          }.width('100%').alignItems(HorizontalAlign.Start).padding(HwSpace.lg).borderRadius(HwRadius.card)
            .backgroundColor(Color.Transparent)
            .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
            .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
            .clip(true).shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
        }
      }

      CardSurface({ radius: HwRadius.card }) {
        Column({ space: HwSpace.md }) {
          this.sectionTitle('发送内容')
          Row({ space: HwSpace.sm }) {
            Button('选择文件').fontSize(14).fontWeight(this.appFontWeight()).fontFamily(this.appFontFamily('选择文件'))
              .backgroundColor(this.accent()).fontColor(onAccentColor(this.accent())).height(36)
              .borderRadius(HwRadius.pill).enabled(!this.mtaBusy).onClick((): void => { void this.pick(); })
            Text(this.files.length + ' 个文件').fontSize(13).fontWeight(this.appFontWeight())
              .fontFamily(this.appFontFamily('个文件')).fontColor(hwTextSecondary(this.isDarkMode)).layoutWeight(1)
            if (this.files.length > 0) {
              Button('清空').fontSize(14).fontWeight(this.appFontWeight()).fontFamily(this.appFontFamily('清空'))
                .fontColor(this.accent()).backgroundColor(Color.Transparent).height(36)
                .enabled(!this.mtaBusy).onClick((): void => { this.files = []; })
            }
          }.width('100%')
          ForEach(this.files, (file: OutgoingFile): void => {
            Text(file.name + ' · ' + this.sizeText(file.size)).fontSize(13).fontWeight(this.appFontWeight())
              .fontFamily(this.appFontFamily(file.name)).fontColor(hwTextSecondary(this.isDarkMode))
              .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          }, (file: OutgoingFile): string => file.path)
          TextArea({ text: this.textContent, placeholder: '也可以输入文本，然后点击附近设备发送' })
            .height(104).fontSize(14).fontWeight(this.appFontWeight()).fontFamily(this.appFontFamily('发送文本'))
            .fontColor(hwTextPrimary(this.isDarkMode)).placeholderColor(hwTextSecondary(this.isDarkMode))
            .caretColor(this.accent()).backgroundColor(withAlpha(this.accent(), this.isDarkMode ? 0.12 : 0.06))
            .borderRadius(HwRadius.control).enabled(!this.mtaBusy && this.files.length === 0)
            .onChange((text: string): void => { this.textContent = text; })
        }.width('100%').alignItems(HorizontalAlign.Start).padding(HwSpace.lg).borderRadius(HwRadius.card)
          .backgroundColor(Color.Transparent)
          .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
          .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
          .clip(true).shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
      }

      Text('附近设备（共 ' + this.devices.length + ' 台）').fontSize(14).fontWeight(this.appFontWeight(500))
        .fontFamily(this.appFontFamily('附近设备')).fontColor(hwTextPrimary(this.isDarkMode))
        .width('100%').padding({ left: HwSpace.xs, top: HwSpace.xs })
      if (this.mtaEnabled && this.devices.length > 0) {
        DeviceList({ devices: this.devices, onSelect: (device: DeviceEndpoint): void => { void this.sendTo(device); } })
      } else {
        CardSurface({ radius: HwRadius.card }) {
          Text(this.mtaEnabled ? '暂未发现互传联盟设备' : '开启互传服务后可发现附近设备')
            .fontSize(14).fontWeight(this.appFontWeight()).fontFamily(this.appFontFamily('附近设备'))
            .fontColor(hwTextSecondary(this.isDarkMode)).textAlign(TextAlign.Center)
            .width('100%').padding(HwSpace.xl).borderRadius(HwRadius.card).backgroundColor(Color.Transparent)
            .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
            .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
            .clip(true).shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
        }
      }

      CardSurface({ radius: HwRadius.card }) {
        Column({ space: HwSpace.md }) {
          this.sectionTitle('对外品牌')
          Select([{ value: '第三方' }, { value: '小米' }, { value: 'OPPO' }, { value: 'vivo' }, { value: '荣耀' },
            { value: '一加' }, { value: '真我' }, { value: '三星' }, { value: '魅族' }])
            .selected(this.brandIndex).enabled(!this.mtaBusy).width('100%')
            .font({ size: 15, weight: this.appFontWeight(), family: this.appFontFamily('对外品牌') })
            .fontColor(hwTextPrimary(this.isDarkMode)).optionFontColor(hwTextPrimary(this.isDarkMode))
            .optionBgColor(hwSurface(this.isDarkMode))
            .optionFont({ size: 15, weight: this.appFontWeight(), family: this.appFontFamily('对外品牌') })
            .selectedOptionBgColor(withAlpha(this.accent(), 0.12)).selectedOptionFontColor(this.accent())
            .backgroundColor(withAlpha(this.accent(), this.isDarkMode ? 0.12 : 0.06)).borderRadius(HwRadius.control)
            .onSelect((index: number): void => {
              this.service?.setBrand(this.brands[index]).catch((error: Error): void => this.toast(error.message));
            })
          Text('品牌显示效果取决于对方设备。').fontSize(12).fontWeight(this.appFontWeight())
            .fontFamily(this.appFontFamily('品牌显示效果取决于对方设备')).fontColor(hwTextSecondary(this.isDarkMode))
        }.width('100%').alignItems(HorizontalAlign.Start).padding(HwSpace.lg).borderRadius(HwRadius.card)
          .backgroundColor(Color.Transparent)
          .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
          .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
          .clip(true).shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
      }

      if (this.history.length > 0) {
        CardSurface({ radius: HwRadius.card }) {
          Column({ space: HwSpace.md }) {
            this.sectionTitle('互传记录')
            ForEach(this.history.slice(0, 50), (record: MtaRecord): void => {
              Column({ space: HwSpace.xs }) {
                Text(record.name).fontSize(14).fontWeight(this.appFontWeight()).fontFamily(this.appFontFamily(record.name))
                  .fontColor(hwTextPrimary(this.isDarkMode)).width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text((record.direction === 'send' ? '发送至 ' : '接收自 ') + record.peer + ' · ' + this.sizeText(record.size))
                  .fontSize(12).fontWeight(this.appFontWeight()).fontFamily(this.appFontFamily('互传记录'))
                  .fontColor(hwTextSecondary(this.isDarkMode))
              }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: HwSpace.xs, bottom: HwSpace.xs })
                .onClick((): void => { void this.openRecord(record); })
            }, (record: MtaRecord): string => record.id)
          }.width('100%').alignItems(HorizontalAlign.Start).padding(HwSpace.lg).borderRadius(HwRadius.card)
            .backgroundColor(Color.Transparent)
            .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
            .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
            .clip(true).shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
        }
      }
    }.width('100%')
  }
}
