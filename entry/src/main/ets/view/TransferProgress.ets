import { LogCapture as Lg } from '../common/LogCapture';
import { TransferTask } from '../model/TransferModels';
import { fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwPrimary, hwPrimaryButton, hwDanger, hwOnline, hwGlassSurface, hwGlassBorder } from '../utils/DesignTokens';
import {
  immersiveMaterialModifier,
  legacyMaterialModifier,
  isApi26OrAbove
} from '../utils/SystemMaterial';

@Component
export struct TransferProgress {
  @Prop tasks: TransferTask[] = [];
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('fontMode') fontMode: string = 'system';
  @StorageLink('fontFamilyEn') fontFamilyEn: string = 'system';
  @StorageLink('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageLink('fontWeightMode') fontWeightMode: string = 'system';
  @StorageLink('fontWeightValue') fontWeightValue: number = 400;

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

  private byteText(size: number): string {
    if (size >= 1024 * 1024) {
      return (size / (1024 * 1024)).toFixed(1) + ' MB';
    }
    if (size >= 1024) {
      return Math.floor(size / 1024) + ' KB';
    }
    return size + ' B';
  }

  build() {
    Column({ space: 12 }) {
      if (this.tasks.length === 0) {
        Text('暂无传输任务')
          .fontSize(13)
          .fontFamily(this.appFontFamily('暂无传输任务'))
          .fontWeight(this.appFontWeight())
          .fontColor(hwTextSecondary(this.isDarkMode))
          .width('100%')
          .padding({ top: 8, bottom: 8 })
      }
      ForEach(this.tasks, (task: TransferTask) => {
        Column({ space: 4 }) {
          Row({ space: 8 }) {
            Text(task.direction === 'send' ? '↑' : '↓').fontSize(14)
              .fontFamily(this.appFontFamily(task.direction === 'send' ? '↑' : '↓')).fontWeight(this.appFontWeight())
              .fontColor(task.direction === 'send' ? hwPrimary(this.isDarkMode) : hwOnline(this.isDarkMode))
            Text(this.fileName(task)).layoutWeight(1).fontSize(13).fontFamily(this.appFontFamily(this.fileName(task))).fontWeight(this.appFontWeight()).fontColor(hwTextPrimary(this.isDarkMode))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.byteText(this.fileSize(task))).fontSize(12).fontFamily(this.appFontFamily(this.byteText(this.fileSize(task)))).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode))
            if (this.firstSavedPath(task).length > 0) {
              Button('打开', { type: ButtonType.Capsule }).height(24).fontSize(11).fontFamily(this.appFontFamily('打开'))
                .backgroundColor(hwPrimaryButton(this.isDarkMode)).fontColor(Color.White)
                .onClick(() => this.openFile(task))
            }
          }.width('100%')
          Text(`${this.stateLabel(task)}${task.progress > 0 ? ' · ' + Math.floor(task.progress) + '%' : ''} · ${task.device.name}`)
            .fontSize(11).fontFamily(this.appFontFamily(`${this.stateLabel(task)} · ${task.device.name}`)).fontWeight(this.appFontWeight()).fontColor(hwTextSecondary(this.isDarkMode)).width('100%')
          if (task.error.length > 0) {
            Text(task.error)
              .fontSize(11)
              .fontFamily(this.appFontFamily(task.error))
              .fontWeight(this.appFontWeight())
              .fontColor(hwDanger(this.isDarkMode))
              .width('100%')
          }
        }
        .width('100%')
        .padding(HwSpace.md)
        .borderRadius(HwRadius.control)
        .backgroundColor(hwGlassSurface(this.isDarkMode))
        .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
        .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
        .clip(true)
      }, (task: TransferTask) => task.id + ':' + task.state + ':' + Math.round(task.progress))
    }
    .width('100%')
  }

  private fileName(task: TransferTask): string {
    if (task.files.length === 0) {
      return task.direction === 'send' ? '发送' : '接收';
    }
    if (task.files.length > 1) {
      return task.files[0].name + ` 等 ${task.files.length} 个文件`;
    }
    return task.files[0].name;
  }

  private firstSavedPath(task: TransferTask): string {
    if (task.receivedFiles.length > 0) {
      return task.receivedFiles[0].savedPath ?? '';
    }
    return '';
  }

  private openFile(task: TransferTask): void {
    const path = this.firstSavedPath(task);
    if (path.length === 0) {
      return;
    }
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const uri: string = path.startsWith('file://') ? path : fileUri.getUriFromPath(path);
      ctx.startAbility({
        action: 'ohos.want.action.viewData',
        uri,
        flags: 1,
        parameters: { 'ohos.aafwk.param.bundleName': 'com.cashmere.link' }
      }).catch((error: BusinessError): void => {
        Lg.w('LocalSend open file failed: ' + error.message);
      });
    } catch (error) {
      Lg.w('LocalSend open file error: ' + (error as Error).message);
    }
  }

  private fileSize(task: TransferTask): number {
    let total = 0;
    for (let i = 0; i < task.files.length; i++) {
      total += task.files[i].size;
    }
    return total;
  }

  private stateLabel(task: TransferTask): string {
    switch (task.state) {
      case 'pending':
        return '等待中';
      case 'awaiting-pin':
        return '等待PIN确认';
      case 'running':
        return '传输中';
      case 'completed':
        return '已完成';
      case 'rejected':
        return '已拒绝';
      case 'failed':
        return '失败';
    }
  }
}
