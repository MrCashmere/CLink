import promptAction from '@ohos.promptAction';
import { LogCapture as Lg } from '../common/LogCapture';
import { PENDING_DYNAMIC_PHOTOS_KEY, PendingDynamicPhotoStore } from '../common/DynamicPhotoStore';
import { toastSystemMaterial } from '../utils/SystemMaterial';
import { PendingDynamicPhotoDialog } from './PendingDynamicPhotoDialog';

/**
 * 「收到动态照片 → 提示保存到图库」的全局触发器（无可见 UI）。
 *
 * 为什么挂在主页根部而不是聚合页的卡片里：卡片只在「聚合」页签挂载时才存在，
 * 用户停在「记录 / 设置」页签时收到动态照片就完全不会有提示。
 *
 * 为什么必须直接读 `this.pendingJson`：ArkUI 只把「build 里读过的状态变量」当作依赖，
 * 早期版本在 build 里绕过状态变量、直接去读 AppStorage，结果 @Watch 会响、界面不刷新，
 * 用户看到的就是「解析成功了但什么提示都没有」。
 */
@Component
export struct PendingDynamicPhotoWatcher {
  @StorageLink(PENDING_DYNAMIC_PHOTOS_KEY) @Watch('onPendingChanged') pendingJson: string = '[]';
  /** 上一次看到的待保存数量，用于判断「新增了」。 */
  private lastPendingCount: number = 0;
  /** 提示框是否已打开：避免同一时刻重复 open()。 */
  private promptOpen: boolean = false;
  private promptDialog: CustomDialogController = new CustomDialogController({
    builder: PendingDynamicPhotoDialog({
      onClosed: (): void => {
        this.promptOpen = false;
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center
  });

  /**
   * 新收到一条待保存动态照片时弹出保存提示。
   *
   * 延迟 1 秒：接收完成后紧接着会自动弹系统「保存到下载目录」的文件选择器，
   * 立刻弹框会被那个模态窗口挡住。
   */
  onPendingChanged(): void {
    const count = PendingDynamicPhotoStore.parse(this.pendingJson).length;
    if (count > this.lastPendingCount) {
      setTimeout((): void => {
        this.openPrompt();
      }, 1000);
    }
    this.lastPendingCount = count;
  }

  private openPrompt(): void {
    if (this.promptOpen || PendingDynamicPhotoStore.parse(this.pendingJson).length === 0) {
      return;
    }
    try {
      Lg.i('[DYNAMIC] open save prompt dialog items='
        + PendingDynamicPhotoStore.parse(this.pendingJson).length);
      this.promptOpen = true;
      this.promptDialog.open();
    } catch (error) {
      this.promptOpen = false;
      Lg.w('[DYNAMIC] save prompt dialog failed: ' + JSON.stringify(error));
      try {
        promptAction.showToast({
          systemMaterial: toastSystemMaterial(),
          message: '动态照片已解析完成，请在「聚合」页顶部卡片点「保存到图库」',
          duration: 5000
        });
      } catch (toastError) {
        Lg.w('[DYNAMIC] pending toast failed: ' + JSON.stringify(toastError));
      }
    }
  }

  build() {
    // 无可见内容：只负责监听登记表变化并弹出提示框（Visibility.None 不影响布局）。
    Row()
      .width(0)
      .height(0)
      .visibility(Visibility.None)
  }
}
