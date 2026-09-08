/**
 * 接收/发送确认弹窗互斥：多个页面同时订阅了 transfer 事件，
 * 若每个都弹一次 PIN 确认框会出现多个弹窗。用单例守卫保证同一时刻只弹一个。
 */
export class PinDialogGuard {
  private static showing: boolean = false;

  /** 尝试开始显示一次弹窗；若已经有一个在显示则返回 false（调用方应跳过）。 */
  static tryBegin(): boolean {
    if (PinDialogGuard.showing) {
      return false;
    }
    PinDialogGuard.showing = true;
    return true;
  }

  /** 弹窗结束（确认/取消/异常）后必须调用，否则后续弹窗会被永久抑制。 */
  static end(): void {
    PinDialogGuard.showing = false;
  }
}
