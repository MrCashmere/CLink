import wifiManager from '@ohos.wifiManager';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogCapture } from './LogCapture';

/** 宿主的 P2P 所有权；不修改任何协议凭据、报文或协商顺序。 */
export class WifiDirectLease {
  private static owner?: WifiDirectLease;
  private closing?: Promise<void>;
  private cleanupRequested: boolean = false;

  private readonly label: string;

  constructor(label: string) { this.label = label; }

  ownsGroup(): boolean { return WifiDirectLease.owner === this; }

  private acquire(): void {
    const owner = WifiDirectLease.owner;
    if (owner !== undefined && owner.cleanupRequested && owner.closing === undefined) {
      owner.removeGroup().catch((error: Error): void => LogCapture.w('[P2P] retry cleanup: ' + error.message));
    }
    if (this.closing !== undefined || (WifiDirectLease.owner !== undefined && !this.ownsGroup())) {
      throw new Error('Wi-Fi Direct 正由其他会话使用或正在释放，请稍后重试');
    }
    WifiDirectLease.owner = this;
    this.cleanupRequested = false;
  }

  createGroup(config: wifiManager.WifiP2PConfig): void {
    this.acquire();
    try { wifiManager.createGroup(config); }
    catch (error) { this.removeGroup().catch((): void => undefined); throw error as Error; }
  }

  connect(config: wifiManager.WifiP2PConfig): void {
    this.acquire();
    try { wifiManager.p2pConnect(config); }
    catch (error) { this.removeGroup().catch((): void => undefined); throw error as Error; }
  }

  cancelConnect(): void {
    if (this.ownsGroup()) { wifiManager.p2pCancelConnect(); }
  }

  removeGroup(): Promise<void> {
    if (!this.ownsGroup()) { return Promise.resolve(); }
    if (this.closing !== undefined) { return this.closing; }
    this.cleanupRequested = true;
    this.closing = this.removeOwnedGroup().finally((): void => { this.closing = undefined; });
    return this.closing;
  }

  private async removeOwnedGroup(): Promise<void> {
    try { wifiManager.p2pCancelConnect(); } catch (_) {}
    try { wifiManager.removeGroup(); } catch (error) {
      LogCapture.w('[P2P] ' + this.label + ' remove requested: ' + String(error));
    }
    // removeGroup 只提交删除请求；保持所有权到平台确认无群组，避免旧删除落到新连接上。
    for (let attempt = 0; attempt < 30; attempt++) {
      await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 200); });
      try {
        const group = await wifiManager.getCurrentGroup();
        if (group.groupName.length > 0) { continue; }
      } catch (error) {
        const code = (error as BusinessError).code;
        if (String(code) !== '2801000') { continue; }
        // 2801000 是通用操作失败，不能单凭这个错误断言群组消失。
        try {
          const link = await wifiManager.getP2pLinkedInfo();
          if (link.connectState !== wifiManager.P2pConnectState.DISCONNECTED) { continue; }
        } catch (_) { continue; }
      }
      if (this.ownsGroup()) { WifiDirectLease.owner = undefined; }
      return;
    }
    // 无法确认释放时保留所有权；本实例可以重试清理，其他实例不能误删它的群组。
    throw new Error('Wi-Fi Direct 群组尚未释放，请稍后重试');
  }
}
