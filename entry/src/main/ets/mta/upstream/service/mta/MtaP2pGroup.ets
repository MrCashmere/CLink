/**
 * MtaP2pGroup.ets — MTA 发送端 WiFi Direct 建组
 *
 * 发送端创建 WiFi Direct 群组（DIRECT- 前缀 + 随机口令），订阅 p2pConnectionChange 取 GO IP，
 * 通过 getCurrentGroup() 读取群组 SSID / 口令 / 本机 p2p0 MAC（ownerInfo.deviceAddress），
 * 结束或复位时 removeGroup()。GO IP 缺失时以协议常量兜底。与接收端 MtaP2pConnector 完全独立。
 */

import { wifiManager } from '@kit.ConnectivityKit';
// 羊绒互传适配：仅仲裁系统 P2P 所有权，协议建组参数与协商保持原样。
import { WifiDirectLease } from '../../../../common/WifiDirectLease';
import {
  MtaGroupInfo,
  MtaP2pGroupEventHandlers,
  matchMtaGroupIdentity,
  normalizeMtaP2pMac
} from '../../model/mta/MtaSendModels';
import { MtaConstants } from './MtaConstants';
import { sleepMs } from './MtaBleCommon';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { errorText } from '../../utils/FormatUtil';
import { nativeGetInterfaceMac } from '../NativeBridge';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaP2pGroup', '互传P2P');

/** STA 频段值 → 标签（1=2.4GHz、2=5GHz，其余为未知） */
function staBandLabel(band: number): string {
  if (band === 1) {
    return '2.4GHz';
  }
  if (band === 2) {
    return '5GHz';
  }
  return '未知';
}

/** MTA 发送端 WiFi Direct 群组管理器 */
export class MtaP2pGroup {
  private readonly hostLease: WifiDirectLease = new WifiDirectLease('MTA sender');
  /** 事件回调集合（服务注入） */
  private handlers: MtaP2pGroupEventHandlers | null = null;
  /** 最近一次 p2pConnectionChange 给出的 GO IP */
  private goIp: string = '';
  /** 是否注册了 p2pConnectionChange 事件 */
  private eventsRegistered: boolean = false;
  /**
   * 已注册的 p2pConnectionChange 回调引用：反注册时必须按引用精确移除。
   * 无参 wifiManager.off('p2pConnectionChange') 会移除所有监听者
   * （含接收端 MtaP2pConnector 的监听），导致接收端连接确认信号失效。
   */
  private connectionChangeCallback: ((info: wifiManager.WifiP2pLinkedInfo) => void) | undefined = undefined;
  /**
   * 群组就绪事件等待器：`waitGroupReady` 的事件优先判定据此在 P2P 连接事件到达时被立即唤醒，
   * 无需等满兜底轮询步长（非 null 表示有等待方在等待）。
   */
  private readyWaiter: (() => void) | null = null;

  // ── 事件注册 / 反注册 ──

  /** 注册 p2pConnectionChange 事件 */
  registerEvents(handlers: MtaP2pGroupEventHandlers): void {
    if (this.eventsRegistered) {
      this.unregisterEvents();
    }
    this.handlers = handlers;
    try {
      this.connectionChangeCallback = (info: wifiManager.WifiP2pLinkedInfo): void => {
        this.handleConnection(info);
      };
      wifiManager.on('p2pConnectionChange', this.connectionChangeCallback);
      this.eventsRegistered = true;
    } catch (e) {
      logger.warn('p2pConnectionChange 注册失败: ' + errorText(e));
    }
  }

  /** 反注册 p2pConnectionChange 事件（仅移除本实例的回调） */
  unregisterEvents(): void {
    if (!this.eventsRegistered) {
      return;
    }
    try {
      let callback = this.connectionChangeCallback;
      if (callback !== undefined) {
        wifiManager.off('p2pConnectionChange', callback);
        this.connectionChangeCallback = undefined;
      }
    } catch (e) {
      logger.warn('p2pConnectionChange 反注册失败: ' + errorText(e));
    }
    this.eventsRegistered = false;
    this.handlers = null;
    // 反注册后不再有事件唤醒等待方：立即唤醒一次让其走兜底复查，避免等待方悬挂
    this.notifyGroupReadySignal();
  }

  /** 处理 p2pConnectionChange：更新 GO IP 并上报摘要 */
  private handleConnection(info: wifiManager.WifiP2pLinkedInfo): void {
    if (!this.hostLease.ownsGroup()) { return; }
    let addr = info.groupOwnerAddr;
    if (info.connectState === 1 && addr !== undefined && addr.length > 0 && addr !== '0.0.0.0') {
      this.goIp = addr;
    }
    let stateText = info.connectState === 1 ? 'CONNECTED' : 'DISCONNECTED';
    let summary = `connectState=${stateText} isGroupOwner=${info.isGroupOwner} groupOwnerAddr=${addr}`;
    if (this.handlers !== null) {
      this.handlers.onConnectionChange(summary);
      if (this.goIp.length > 0) {
        this.handlers.onGoIp(this.goIp);
      }
    }
    // P2P 连接事件是「组网就绪」的主判据：到达即唤醒等待方立即复查群组信息
    if (info.connectState === 1) {
      this.notifyGroupReadySignal();
    }
  }

  /** 唤醒群组就绪等待方（幂等；无等待方时为空操作） */
  private notifyGroupReadySignal(): void {
    let waiter = this.readyWaiter;
    if (waiter === null) {
      return;
    }
    this.readyWaiter = null;
    waiter();
  }

  // ── 建组 / 查组 / 删组 ──

  /**
   * 创建 P2P 群组（临时组 netId=-1），失败 reject 错误文本。
   * goBand 必设；freqMhz 为正数时额外设置 goFreq（合法频点优先于频段，用于显式请求 5GHz）。
   */
  createGroup(groupName: string, passphrase: string, goBand: number, freqMhz: number): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      try {
        let config: wifiManager.WifiP2PConfig = {
          deviceAddress: '',
          netId: -1,
          passphrase: passphrase,
          groupName: groupName,
          goBand: goBand
        };
        if (freqMhz > 0) {
          config.goFreq = freqMhz;
        }
        this.hostLease.createGroup(config);
        resolve();
      } catch (e) {
        reject(errorText(e));
      }
    });
  }

  /** 查询当前群组信息，未建组（错误码 2801000）或查询失败返回 null */
  async getCurrentGroup(): Promise<MtaGroupInfo | null> {
    if (!this.hostLease.ownsGroup()) { return null; }
    try {
      let group: wifiManager.WifiP2pGroupInfo = await wifiManager.getCurrentGroup();
      let info = new MtaGroupInfo();
      info.ssid = group.groupName;
      info.psk = group.passphrase;
      info.goIp = group.goIpAddress;
      let owner = group.ownerInfo;
      info.ownerMac = owner === undefined ? '' : owner.deviceAddress;
      let clients = group.clientDevices;
      info.clientCount = clients === undefined ? 0 : clients.length;
      info.frequency = group.frequency;
      if (info.goIp.length === 0) {
        info.goIp = this.goIp;
      }
      return info;
    } catch (e) {
      let obj = e as Record<string, Object>;
      let code = obj['code'];
      if (typeof code === 'number' && code === MtaConstants.GROUP_NOT_FOUND_CODE) {
        return null;
      }
      logger.warn('getCurrentGroup 失败: ' + errorText(e));
      return null;
    }
  }

  /**
   * 读取本机 P2P 设备地址（Native 读网卡硬件地址）：该值即对端可见的群主设备地址，
   * P2pInfo.mac 必须与之一致（小米端会校验，否则 unrecognized network owner）。
   * 鸿蒙对三方应用屏蔽了 ownerInfo.deviceAddress（随机）与 getP2pLocalDevice（全 0），
   * 故改由 Native 读取；依次尝试基接口 p2p0 与当前群组接口，均不可得返回空串。
   * Native 以大写的 `{:02X}` 生成地址，此处统一归一为小写后再返回（接收端比对大小写策略不同，
   * 详见 normalizeMtaP2pMac）。
   */
  async resolveP2pInterfaceMac(): Promise<string> {
    let candidates: Array<string> = ['p2p0'];
    try {
      let group: wifiManager.WifiP2pGroupInfo = await wifiManager.getCurrentGroup();
      if (group.interface.length > 0 && group.interface !== 'p2p0') {
        candidates.push(group.interface);
      }
    } catch (e) {
      logger.warn('getCurrentGroup 失败: ' + errorText(e));
    }
    for (let i = 0; i < candidates.length; i++) {
      let mac = nativeGetInterfaceMac(candidates[i]);
      logger.debug(`本机接口 ${candidates[i]} 硬件地址=${mac.length > 0 ? mac : '不可得'}`);
      if (mac.length > 0 && mac !== '00:00:00:00:00:00') {
        return normalizeMtaP2pMac(mac);
      }
    }
    return '';
  }

  /**
   * 轮询等待「本次会话请求的群组」就绪（就绪组名 == expectedGroupName），超时返回最后一次查询结果。
   *
   * 就绪判定以群组**身份**为准：只判断「存在群组」会把上一次会话尚未拆除完成的残留群组
   * 误判为本次就绪，从而下发残留组的无线凭据、对端无法入组而挂起。身份不匹配（含观测组不可得）
   * 一律视为未就绪并在超时内继续等待；超时仍不匹配时返回的最后观测值**不得被采用**。
   */
  async waitGroupReady(timeoutMs: number, expectedGroupName: string): Promise<MtaGroupInfo | null> {
    let startMs = Date.now();
    // 事件优先：先立即查一次，未就绪则在「P2P 连接事件 / 短兜底步长」唤醒后复查
    let info = await this.getCurrentGroup();
    if (this.isGroupIdentityMatched(info, expectedGroupName)) {
      return info;
    }
    while (Date.now() - startMs < timeoutMs) {
      await this.waitGroupReadySignalOrFallback();
      let current = await this.getCurrentGroup();
      if (this.isGroupIdentityMatched(current, expectedGroupName)) {
        return current;
      }
    }
    return this.getCurrentGroup();
  }

  /**
   * 等待上一会话残留群组消失（有界）：轮询至查询不到群组或超时。
   * 返回 true 表示当前无群组（可安全发起本次建组），false 表示超时仍有残留（交由身份校验兜底）。
   */
  async waitGroupAbsent(timeoutMs: number): Promise<boolean> {
    if (await this.getCurrentGroup() === null) {
      return true;
    }
    let startMs = Date.now();
    while (Date.now() - startMs < timeoutMs) {
      await sleepMs(MtaConstants.GROUP_READY_FALLBACK_POLL_MS);
      if (await this.getCurrentGroup() === null) {
        return true;
      }
    }
    return false;
  }

  /** 群组信息是否即本次请求创建的群组（就绪组名与请求组名一致） */
  private isGroupIdentityMatched(info: MtaGroupInfo | null, expectedGroupName: string): boolean {
    if (info === null) {
      return false;
    }
    return matchMtaGroupIdentity(expectedGroupName, info.ssid).matched;
  }

  /**
   * 等待「群组就绪事件」或兜底步长：P2P 连接事件到达时立即结算，
   * 否则以 `GROUP_READY_FALLBACK_POLL_MS` 短步长兜底，避免固定长步长引入额外等待。
   */
  private waitGroupReadySignalOrFallback(): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      let settled = false;
      let timerId: number = -1;
      let finish = (): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (this.readyWaiter === finish) {
          this.readyWaiter = null;
        }
        clearTimeout(timerId);
        resolve();
      };
      timerId = setTimeout((): void => {
        finish();
      }, MtaConstants.GROUP_READY_FALLBACK_POLL_MS);
      this.readyWaiter = finish;
    });
  }

  /** 删除当前 P2P 群组（本无群组时视为已删除） */
  removeGroup(): Promise<void> {
    return this.hostLease.removeGroup();
  }

  /** 解析可用 GO IP：事件回调值优先，缺失时用默认网关兜底 */
  getGoIp(): string {
    return this.goIp.length > 0 ? this.goIp : MtaConstants.DEFAULT_GO_IP;
  }

  /**
   * 读取本机并发 STA 的频段/频率/链路速率/SSID 快照文本，供发送建组频段取证。
   * 未关联 WiFi 或读取失败时降级为“未知”，异常文本化不抛出。
   */
  getStaBandText(): string {
    try {
      let info = wifiManager.getLinkedInfoSync();
      let bandText = staBandLabel(info.band);
      let freqText = info.frequency > 0 ? `${info.frequency}MHz` : '未知';
      let speedText = info.linkSpeed > 0 ? `${info.linkSpeed}Mbps` : '未知';
      let ssidText = info.ssid.length > 0 ? info.ssid : '未知';
      return `band=${info.band}(${bandText}) frequency=${freqText} linkSpeed=${speedText} ssid=${ssidText}`;
    } catch (e) {
      return `未知（读取失败: ${errorText(e)}）`;
    }
  }

  /** 释放资源（删组、反注册事件） */
  destroy(): void {
    this.removeGroup().catch((): void => {
    });
    this.unregisterEvents();
  }
}
