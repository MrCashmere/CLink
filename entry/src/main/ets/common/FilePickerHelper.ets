import { common } from '@kit.AbilityKit';
import { picker, fileUri } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';
import { OutgoingFile } from '../model/TransferModels';

/**
 * 文件选择辅助：把「点击设备卡片 → 弹出系统选择器 → 解析所选文件」这段路径上的主线程
 * 开销降到最低。
 *
 * - 复用同一个 DocumentViewPicker：此前每次点击设备卡片都 new 一个全新的系统选择器，
 *   构造本身有主线程开销，直接推高「应用内点击响应时延」（DevEco 自动上架体验体检）。
 *   这里按应用级缓存单个实例，点击路径上只调用 select()。
 * - 文件大小解析改为异步 fs.stat：此前用同步 fs.statSync + fileUri 解析，多个文件会
 *   在主线程上串行做阻塞 I/O，选择器返回后界面会卡顿；异步化后主线程不被阻塞。
 */
export class FilePickerHelper {
  private static pickerInstance?: picker.DocumentViewPicker;
  /** 同一时刻只允许一个系统选择器在弹；防止连点/重复点击在同一实例上并发叠加 select()。 */
  private static selecting: boolean = false;

  /** 按应用级缓存一个 DocumentViewPicker（首次按传入 context 创建）。 */
  static getPicker(context: common.Context): picker.DocumentViewPicker {
    if (FilePickerHelper.pickerInstance === undefined) {
      FilePickerHelper.pickerInstance = new picker.DocumentViewPicker(context);
    }
    return FilePickerHelper.pickerInstance;
  }

  /**
   * 预热：提前构造系统选择器实例（不弹出），让用户在页面刚打开时的首次点击落到"已构造
   * 的选择器"上，点击路径只剩 select()，减少主线程在点击瞬间的工作。
   */
  static warmUp(context: common.Context): void {
    try {
      FilePickerHelper.getPicker(context);
    } catch (error) {
      // 预热失败不阻塞页面：真正点击时 pick() 会重新构造，并在需要时向调用方反馈错误。
    }
  }

  /** 让出当前事件循环，等到主线程渲染出此次点击的反馈帧后再继续。 */
  private static nextTick(): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 0);
    });
  }

  /** 弹出系统文件选择器，并把选中的 URI 会话解析为 OutgoingFile[]（异步、不阻塞主线程）。 */
  static async pick(context: common.Context): Promise<OutgoingFile[]> {
    // 防连点：前一次选择还没结束（选择器仍在屏上或被弹出的间隙）时，直接返回空结果，
    // 避免同一个 DocumentViewPicker 上并发叠加多个 select()（会让选择器越弹越慢）。
    if (FilePickerHelper.selecting) {
      return [];
    }
    FilePickerHelper.selecting = true;
    try {
      // 关键：先让本次 onClick 事件处理完毕、应用渲染出点击反馈帧，再打开系统选择器。
      // 否则选择器（尤其首次冷启动）的同步初始化会阻塞主线程，把"应用内点击响应时延"
      // 抬高到标准(250ms)之上。延时约一个事件循环，用户几乎无感知。
      await FilePickerHelper.nextTick();
      const uris: string[] = await FilePickerHelper.getPicker(context).select(new picker.DocumentSelectOptions());
      const files: OutgoingFile[] = [];
      for (const uri of uris) {
        files.push({
          path: uri,
          name: FilePickerHelper.nameOf(uri),
          size: await FilePickerHelper.sizeOf(uri),
          mime: 'application/octet-stream'
        });
      }
      // 用户取消（未选任何文件）：复用的选择器反复 open/取消会累积系统内部状态，导致下一次弹出
      // 明显变慢。这里丢弃缓存实例，下次点击重新构造，保证每个"点击→取消"循环从干净状态开始。
      if (uris.length === 0) {
        FilePickerHelper.pickerInstance = undefined;
      }
      return files;
    } catch (error) {
      // 选择器报错同样丢弃实例，避免继续复用处于异常状态的实例。
      FilePickerHelper.pickerInstance = undefined;
      throw error as Error;
    } finally {
      FilePickerHelper.selecting = false;
    }
  }

  /** 从 content/file URI 提取文件名（含 de-encode）。 */
  static nameOf(uri: string): string {
    const parts = uri.split('/');
    const last = parts[parts.length - 1] ?? 'file';
    try {
      return decodeURIComponent(last);
    } catch (error) {
      return last;
    }
  }

  /** 异步取文件大小：先直接 stat URI，失败再回退到 fileUri 解出的真实路径。 */
  static async sizeOf(uri: string): Promise<number> {
    try {
      return (await fs.stat(uri)).size;
    } catch (error) {
      // fall through
    }
    try {
      const realPath = new fileUri.FileUri(uri).path;
      return (await fs.stat(realPath)).size;
    } catch (error) {
      return 0;
    }
  }
}
