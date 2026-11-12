/**
 * MtaP2pConnector.ets — MTA 接收端 P2P 连接
 *
 * p2pConnect 路线：以全 0 设备地址 + 随机地址类型 + 临时组（netId=-1）注入
 * 解密出的 groupName（SSID）与 passphrase（PSK），可静默加入发送方创建的
 * 匿名 autonomous GO，且不影响已连 WiFi（多网络并行）。连接成功以
 * p2pConnectionChange connectState=1 确认，GO IP 取事件 groupOwnerAddr，
 * 缺失时以 192.168.49.1 兜底。
 */

import { wifiManager } from '@kit.ConnectivityKit';
// 羊绒互传适配：接收端与其他协议共享系统 P2P 所有权。
import { WifiDirectLease } from '../../../../common/WifiDirectLease';
import { connection } from '@kit.NetworkKit';
import { MtaP2pEventHandlers } from '../../model/mta/MtaProtocolModels';
import { MtaConstants } from './MtaConstants';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { errorText } from '../../utils/FormatUtil';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaP2pConnector', '互传P2P');

/** 将 IpInfo 的十进制整数 IPv4 转为点分十进制文本（0 → "0.0.0.0"） */
function ipNumberToText(n: number): string {
  let v = n >>> 0;
  let b0 = (v >> 24) & 0xff;
  let b1 = (v >> 16) & 0xff;
  let b2 = (v >> 8) & 0xff;
  let b3 = v & 0xff;
  return `${b0}.${b1}.${b2}.${b3}`;
}

/** P2P 连接结果 */
export class P2pConnectResult {
  /** 是否已确认连接成功 */
  connected: boolean = false;
  /** 可用 GO 网关地址（含兜底值） */
  goIp: string = '';
  /** 结果描述 */
  detail: string = '';
}

/** MTA 接收端 P2P 连接器 */
export class MtaP2pConnector {
  private readonly hostLease: WifiDirectLease = new WifiDirectLease('MTA receiver');
  /** 最近一次事件回调的 GO IP */
  private goIp: string = '';
  /** 事件回调集合 */
  private handlers: MtaP2pEventHandlers | null = null;
  /** 等待连接事件的 resolver */
  private waitResolver: ((ok: boolean) => void) | null = null;
  /** 连接等待超时定时器 */
  private timerId: number = -1;
  /** 连接确认轮询定时器 */
  private pollTimerId: number = -1;
  // ── 事件注册 / 反注册 ──

  /**
   * 已注册的 p2pConnectionChange 回调引用：反注册时必须按引用精确移除。
   * 无参 wifiManager.off('p2pConnectionChange') 会移除所有监听者
   * （含发送端 MtaP2pGroup 的监听），导致发送端 GO IP 事件失效。
   */
  private connectionChangeCallback: ((info: wifiManager.WifiP2pLinkedInfo) => void) | undefined = undefined;
  /** 已注册的 p2pStateChange 回调引用（按引用反注册，理由同上） */
  private stateChangeCallback: ((state: number) => void) | undefined = undefined;

  /** 注册 P2P 事件（连接确认以 p2pConnectionChange 为准） */
  registerEvents(handlers: MtaP2pEventHandlers): void {
    if (this.handlers !== null) {
      this.unregisterEvents();
    }
    this.handlers = handlers;
    try {
      this.connectionChangeCallback = (info: wifiManager.WifiP2pLinkedInfo): void => {
        this.handleP2pConnection(info);
      };
      wifiManager.on('p2pConnectionChange', this.connectionChangeCallback);
    } catch (e) {
      logger.warn('p2pConnectionChange 注册失败: ' + errorText(e));
    }
    try {
      this.stateChangeCallback = (state: number): void => {
        if (this.handlers !== null) {
          this.handlers.onP2pStateChange(`state=${state}`);
        }
      };
      wifiManager.on('p2pStateChange', this.stateChangeCallback);
    } catch (e) {
      logger.warn('p2pStateChange 注册失败: ' + errorText(e));
    }
  }

  /** 反注册 P2P 事件（仅移除本实例的回调） */
  unregisterEvents(): void {
    try {
      let connCallback = this.connectionChangeCallback;
      if (connCallback !== undefined) {
        wifiManager.off('p2pConnectionChange', connCallback);
        this.connectionChangeCallback = undefined;
      }
    } catch (e) {
      logger.warn('p2pConnectionChange 反注册失败: ' + errorText(e));
    }
    try {
      let stateCallback = this.stateChangeCallback;
      if (stateCallback !== undefined) {
        wifiManager.off('p2pStateChange', stateCallback);
        this.stateChangeCallback = undefined;
      }
    } catch (e) {
      logger.warn('p2pStateChange 反注册失败: ' + errorText(e));
    }
    this.handlers = null;
  }

  /** 处理 p2pConnectionChange：主确认信号，记录 GO IP 并在连上时结束等待 */
  private handleP2pConnection(info: wifiManager.WifiP2pLinkedInfo): void {
    if (!this.hostLease.ownsGroup()) { return; }
    let stateText = info.connectState === 1 ? 'CONNECTED' : 'DISCONNECTED';
    let addr = info.groupOwnerAddr;
    if (info.connectState === 1) {
      if (addr !== undefined && addr.length > 0 && addr !== '0.0.0.0') {
        this.goIp = addr;
      }
    }
    let summary = `connectState=${stateText} isGroupOwner=${info.isGroupOwner} groupOwnerAddr=${addr}`;
    if (this.handlers !== null) {
      this.handlers.onP2pConnectionChange(summary);
    }
    if (info.connectState === 1 && this.waitResolver !== null) {
      this.finishWait(true);
    }
  }

  /** 查询 P2P 链路状态：getP2pLinkedInfo connectState=1 视为已连接，查询失败返回 false */
  private async checkP2pLinked(): Promise<boolean> {
    try {
      let info = await wifiManager.getP2pLinkedInfo();
      return this.hostLease.ownsGroup() && info.connectState === 1;
    } catch (e) {
      return false;
    }
  }

  /** 轮询触发：若 P2P 链路已连上则结束等待（事件未达时的兜底路径） */
  private tryResolve(): void {
    if (this.waitResolver === null) {
      return;
    }
    this.checkP2pLinked().then((linked: boolean): void => {
      if (linked && this.waitResolver !== null) {
        this.finishWait(true);
      }
    });
  }

  /** 结束等待：清理定时器、回调 GO IP 并 resolve */
  private finishWait(ok: boolean): void {
    let resolver = this.waitResolver;
    this.waitResolver = null;
    this.clearWaitTimer();
    if (ok && this.handlers !== null) {
      this.handlers.onGoIp(this.resolveGoIp());
      this.reportGroupFrequency();
    }
    if (resolver !== null) {
      resolver(ok);
    }
  }

  /** 读取对端群组实际频点（MHz）：查询失败或频点无效返回 0（失败容忍，不阻塞流程） */
  private async readGroupFrequency(): Promise<number> {
    if (!this.hostLease.ownsGroup()) { return 0; }
    try {
      let group = await wifiManager.getCurrentGroup();
      return group.frequency > 0 ? group.frequency : 0;
    } catch (e) {
      logger.warn('读取对端群组频点失败: ' + errorText(e));
      return 0;
    }
  }

  /** 连接确认后读取对端群组实际频点并经回调上报 */
  private reportGroupFrequency(): void {
    this.readGroupFrequency().then((freq: number): void => {
      if (this.handlers !== null) {
        this.handlers.onGroupFrequency(freq);
      }
    }).catch((e: Object): void => {
      logger.warn('上报群组频点异常: ' + String(e));
    });
  }

  /** 清除连接等待与轮询定时器 */
  private clearWaitTimer(): void {
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    if (this.pollTimerId >= 0) {
      clearInterval(this.pollTimerId);
      this.pollTimerId = -1;
    }
  }

  /** 等待 P2P 连接确认：先立即检测，随后轮询兜底，超时返回 false */
  private waitConnected(timeoutMs: number): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      this.waitResolver = resolve;
      this.clearWaitTimer();
      this.tryResolve();
      this.pollTimerId = setInterval(() => {
        this.tryResolve();
      }, MtaConstants.P2P_POLL_INTERVAL_MS);
      this.timerId = setTimeout(() => {
        this.finishWait(false);
      }, timeoutMs);
    });
  }

  /** 解析可用 GO IP：事件回调值优先，缺失时用默认网关兜底 */
  private resolveGoIp(): string {
    return this.goIp.length > 0 ? this.goIp : MtaConstants.DEFAULT_GO_IP;
  }

  /**
   * 发起 p2pConnect 加入发送方群组：全 0 设备地址 + 随机地址类型 + 临时组
   * （netId=-1），注入解密出的 groupName（SSID）与 passphrase（PSK），
   * 等待 p2pConnectionChange 确认。超时仍返回兜底 GO IP，由调用方决定是否继续。
   */
  async connectAndWait(ssid: string, psk: string, timeoutMs: number): Promise<P2pConnectResult> {
    let result = new P2pConnectResult();
    if (ssid.length === 0) {
      result.detail = 'SSID 为空，无法发起 P2P 连接';
      return result;
    }
    let config: wifiManager.WifiP2PConfig = {
      deviceAddress: '00:00:00:00:00:00',
      deviceAddressType: wifiManager.DeviceAddressType.RANDOM_DEVICE_ADDRESS,
      netId: -1,
      passphrase: psk,
      groupName: ssid,
      goBand: wifiManager.GroupOwnerBand.GO_BAND_AUTO
    };
    this.goIp = '';
    let wait = this.waitConnected(timeoutMs);
    try {
      this.hostLease.connect(config);
    } catch (e) {
      this.finishWait(false);
      result.detail = 'p2pConnect 发起失败: ' + errorText(e);
      return result;
    }
    let ok = await wait;
    result.connected = ok;
    result.goIp = this.resolveGoIp();
    if (ok) {
      result.detail = `p2pConnect 成功加入 ${ssid}，GO IP=${result.goIp}`;
    } else {
      result.detail = `未在 ${timeoutMs}ms 内确认 P2P 连接（${ssid}），使用兜底 GO IP=${result.goIp}`;
    }
    return result;
  }

  /** 当前是否已连接 WiFi */
  isWifiConnected(): boolean {
    try {
      return wifiManager.isConnected();
    } catch (e) {
      logger.warn('isConnected 查询失败: ' + errorText(e));
      return false;
    }
  }

  /** 当前网络状态摘要（本机 IP / 网关 / WiFi 是否连接），用于诊断 WS 不可达 */
  getNetworkInfoText(): string {
    let parts: Array<string> = [];
    try {
      let ip = wifiManager.getIpInfo();
      parts.push(`ip=${ipNumberToText(ip.ipAddress)} gw=${ipNumberToText(ip.gateway)}`);
    } catch (e) {
      parts.push('getIpInfo 失败: ' + errorText(e));
    }
    parts.push(`wifiConnected=${this.isWifiConnected()}`);
    return parts.join(' ');
  }

  /** 当前已连 WiFi 的 SSID（查询失败/未连返回空串）；p2pConnect 不改变 STA 关联，用于多网络并行诊断 */
  getLinkedSsidText(): string {
    try {
      return wifiManager.getLinkedInfoSync().ssid;
    } catch (e) {
      return '';
    }
  }

  /**
   * 汇总网络并存快照：本机 IP/网关、默认网络、getAllNets 条目（接口名/链路地址/是否疑似 P2P）。
   * 单个条目查询失败不影响其余，全部异步异常文本化，不抛出。
   */
  async getNetworkSummary(): Promise<string> {
    let parts: Array<string> = [];
    try {
      let ip = wifiManager.getIpInfo();
      parts.push(`本机 ip=${ipNumberToText(ip.ipAddress)} gw=${ipNumberToText(ip.gateway)}`);
    } catch (e) {
      parts.push('getIpInfo 失败: ' + errorText(e));
    }
    try {
      let defaultNet = await connection.getDefaultNet();
      parts.push(`默认网络 netId=${defaultNet.netId}`);
    } catch (e) {
      parts.push('getDefaultNet 失败: ' + errorText(e));
    }
    try {
      let nets = await connection.getAllNets();
      let netTexts: Array<string> = [];
      for (let i = 0; i < nets.length; i++) {
        let net = nets[i];
        try {
          let props = await connection.getConnectionProperties(net);
          let addrs: Array<string> = [];
          let la = props.linkAddresses;
          if (la !== undefined) {
            for (let j = 0; j < la.length; j++) {
              let a = la[j].address;
              if (a !== undefined) {
                addrs.push(a.address);
              }
            }
          }
          let iface = props.interfaceName !== undefined ? props.interfaceName : '';
          netTexts.push(`net=${net.netId} if=${iface} addr=[${addrs.join(',')}] ` +
            `疑似P2P=${this.isLikelyP2p(iface, addrs)}`);
        } catch (e) {
          netTexts.push(`net=${net.netId} 属性查询失败`);
        }
      }
      parts.push(`网络列表(${nets.length} 条): ${netTexts.join(' | ')}`);
    } catch (e) {
      parts.push('getAllNets 失败: ' + errorText(e));
    }
    return parts.join('；');
  }

  /** 判断某网络是否疑似 P2P（接口名含 p2p，或链路地址落在默认 P2P 网段） */
  private isLikelyP2p(iface: string, addrs: Array<string>): boolean {
    if (iface.length > 0 && iface.toLowerCase().includes('p2p')) {
      return true;
    }
    let dot = MtaConstants.DEFAULT_GO_IP.lastIndexOf('.');
    let prefix = dot > 0 ? MtaConstants.DEFAULT_GO_IP.substring(0, dot + 1) : '';
    if (prefix.length === 0) {
      return false;
    }
    for (let i = 0; i < addrs.length; i++) {
      if (addrs[i].startsWith(prefix)) {
        return true;
      }
    }
    return false;
  }

  /** 断开连接：中止进行中的 P2P 连接并退出群组 */
  async disconnect(): Promise<string> {
    this.finishWait(false);
    let steps: Array<string> = [];
    try {
      this.hostLease.cancelConnect();
    } catch (e) {
      // 无进行中的连接时抛错属预期，不记失败步骤
    }
    try {
      await this.hostLease.removeGroup();
      steps.push('已退出 P2P 群组');
    } catch (e) {
      // 本无群组（2801000）视为已退出，其余失败如实记录
      let obj = e as Record<string, Object>;
      let code = obj['code'];
      if (typeof code === 'number' && code === MtaConstants.GROUP_NOT_FOUND_CODE) {
        // 已无群组，无需处理
      } else if (typeof code === 'string' && code === `${MtaConstants.GROUP_NOT_FOUND_CODE}`) {
        // 已无群组，无需处理
      } else {
        steps.push('退出 P2P 群组失败: ' + errorText(e));
      }
    }
    this.goIp = '';
    return steps.length > 0 ? steps.join('；') : '无待清理的连接';
  }
}
