/**
 * MtaTransferClient.ets — MTA 接收端传输客户端
 *
 * 负责与发送方建立 WebSocket 连接、完成版本协商、接收 sendRequest 并回 ack，
 * 以及驱动接收下载：下载、解压与落盘全部由 Rust 完成（`nativeMtaReceiveDownload`），
 * 本类仅调用入口、订阅 `mtaReceiveProgress` 事件并消费返回的落盘元数据。
 * WS 使用 skipServerCertVerification 跳过自签名证书校验；消息格式 `type:id:name?json`。
 */

import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import {
  DownloadProgress,
  MtaTransferEventHandlers,
  ReceivedFileEntry,
  ReceiveRequest,
  WsMessage,
  buildStatusPayload,
  buildWsMessage,
  isVersionNegotiationSupported,
  parseSendRequestPayload,
  parseWsMessage
} from '../../model/mta/MtaProtocolModels';
import { MtaConstants } from './MtaConstants';
import {
  nativeCancelTransferLocal,
  nativeMtaReceiveDownload,
  offBridgeEvent,
  onBridgeEvent
} from '../NativeBridge';
import { NativeEvent, NativeMtaReceiveProgressEvent } from '../../model/NativeTypes';
import { getMimeForFileName } from '../../utils/MimeUtils';
import { ProgressReportThrottle, resolveMaxActualBytes } from '../../utils/MtaProgressUtil';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { errorText } from '../../utils/FormatUtil';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaTransfer', '互传传输');

/** 下载并保存结果（由 Rust 返回的落盘元数据构造） */
export class DownloadResult {
  /** 已保存文件的完整路径 */
  savedFiles: Array<string> = [];
  /** 逐文件条目（文件名 + 解压后大小），与 savedFiles 一一对应 */
  files: Array<ReceivedFileEntry> = [];
  /** 落盘的条目数 */
  entryCount: number = 0;
  /** 落盘总字节数 */
  totalBytes: number = 0;
  /** 有效条目时间的文件数（无有效条目时间时为 0） */
  restoredTimeCount: number = 0;
}

/** Rust 返回的单个落盘条目元数据 */
class ReceivedEntryMeta {
  /** 文件名（仅文件名） */
  name: string = '';
  /** 解压后字节数 */
  size: number = 0;
  /** 条目修改时间（Unix 毫秒；不可用为 0） */
  modifiedUnixMs: number = 0;
  /** 落盘后的完整路径（重名时带 `(n)` 后缀） */
  savedPath: string = '';
}

/** MTA 接收端传输客户端（WS 协商 + Rust 主导下载/解压/落盘） */
export class MtaTransferClient {
  /** WebSocket 实例 */
  private ws: webSocket.WebSocket | null = null;
  private cancelConnect?: () => void;
  /** 事件回调 */
  private handlers: MtaTransferEventHandlers | null = null;
  /** 当前下载任务 ID（取消时据此触发 Rust 取消令牌） */
  private activeTaskId: string = '';
  /** 接收进度上报节流器（完成事件不受最小间隔限制） */
  private progressThrottle: ProgressReportThrottle =
    new ProgressReportThrottle(MtaConstants.PROGRESS_THROTTLE_MS);
  /** 是否已订阅接收进度事件 */
  private progressSubscribed: boolean = false;
  /** 最近一次接收进度事件的网络读入字节累计（完成态收敛用） */
  private lastNetworkBytes: number = 0;
  /** 接收进度事件处理器（保持引用以便退订） */
  private receiveProgressHandler: (event: NativeEvent) => void = (event: NativeEvent): void => {
    if (event.type !== 'mtaReceiveProgress') {
      return;
    }
    let progressEvent = event as NativeMtaReceiveProgressEvent;
    if (this.activeTaskId.length === 0 || progressEvent.taskId !== this.activeTaskId) { return; }
    this.lastNetworkBytes = progressEvent.networkBytes;
    this.reportProgress(progressEvent.receivedBytes, progressEvent.totalBytes, false,
      progressEvent.networkBytes, progressEvent.networkDone);
  };

  /** 注入事件回调 */
  setEventHandlers(handlers: MtaTransferEventHandlers): void {
    this.handlers = handlers;
  }

  // ── 连接 ──

  /** 建立 WS 连接（跳过服务端证书校验），open 事件到达时 resolve；timeoutMs 为本次尝试的超时 */
  connect(url: string, timeoutMs: number): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (this.ws !== null) {
        reject(new Error('WebSocket 已存在，请先关闭'));
        return;
      }
      const ws = webSocket.createWebSocket();
      this.ws = ws;
      let settled = false;
      let opened = false;
      let timer = -1;
      const finish = (error?: Error): void => {
        if (settled) { return; }
        settled = true;
        clearTimeout(timer);
        this.cancelConnect = undefined;
        if (error !== undefined) { reject(error); } else { resolve(); }
      };
      this.cancelConnect = (): void => finish(new Error('WS 连接已取消'));
      timer = setTimeout((): void => finish(new Error('WS 连接超时（' + timeoutMs + 'ms）')), timeoutMs);

      ws.on('open', (err: BusinessError, _value: Object): void => {
        if (this.ws !== ws || settled) { return; }
        if (err !== undefined && err !== null && err.code !== 0) {
          finish(new Error(errorText(err)));
          return;
        }
        opened = true;
        finish();
        this.handlers?.onWsOpen();
      });
      ws.on('message', (err: BusinessError, value: string | ArrayBuffer): void => {
        if (this.ws !== ws || !opened || (err !== undefined && err !== null && err.code !== 0)) { return; }
        this.handleMessage(value);
      });
      ws.on('close', (_err: BusinessError, value: webSocket.CloseResult): void => {
        if (this.ws !== ws) { return; }
        const reason = value !== undefined ? 'code=' + value.code + ' reason=' + value.reason : '未知';
        if (!settled) { finish(new Error('WS 连接已关闭: ' + reason)); }
        else if (opened) { this.handlers?.onWsClosed(reason); }
      });
      const fail = (error: BusinessError): void => {
        if (this.ws !== ws) { return; }
        const detail = errorText(error);
        this.handlers?.onError('WS', '连接错误: ' + detail);
        finish(new Error('WS 连接失败: ' + detail));
      };
      ws.on('error', fail);

      const options: webSocket.WebSocketRequestOptions = { skipServerCertVerification: true };
      ws.connect(url, options).then((ok: boolean): void => {
        if (this.ws === ws && !ok) { finish(new Error('WS 未能发起连接')); }
      }).catch(fail);
    });
  }

  /** 处理收到的 WS 消息：版本协商与 sendRequest */
  private handleMessage(value: string | ArrayBuffer): void {
    let text = typeof value === 'string' ? value : new util.TextDecoder().decodeToString(new Uint8Array(value));
    let message = parseWsMessage(text);
    if (message === undefined) {
      if (this.handlers !== null) {
        this.handlers.onError('WS', '消息格式非法: ' + text);
      }
      return;
    }
    if (message.name === 'versionNegotiation') {
      this.handleVersionNegotiation(message);
    } else if (message.name === 'sendRequest') {
      this.handleSendRequest(message);
    } else {
      // 记录完整原文：发送方（如小米）在收尾时会回送它自己的 status，其 type/reason 是判定其成败的依据
      logger.debug(`收到未处理的 WS 消息 name=${message.name} id=${message.id} 原文=${text}`);
    }
  }

  /** 处理版本协商：校验对端版本后回复 ack（version=1, threadLimit=5），不兼容则报错断开 */
  private handleVersionNegotiation(message: WsMessage): void {
    if (!isVersionNegotiationSupported(message.payload, MtaConstants.PROTOCOL_VERSION)) {
      logger.error(`对端协议版本不兼容: ${message.payload}`);
      if (this.handlers !== null) {
        this.handlers.onError('WS', `对端协议版本不兼容: ${message.payload}`);
      }
      this.close().catch((): void => {
      });
      return;
    }
    let payload = `{"version":${MtaConstants.PROTOCOL_VERSION},"threadLimit":${MtaConstants.THREAD_LIMIT}}`;
    this.send(buildWsMessage('ack', message.id, 'versionNegotiation', payload)).catch((error: Error): void => {
      logger.warn('版本协商确认发送失败: ' + error.message);
    });
    if (this.handlers !== null) {
      this.handlers.onVersionNegotiated(MtaConstants.PROTOCOL_VERSION);
    }
  }

  /**
   * 处理接收请求：立即回复空 ack 让发送端跳出 sendRequest 确认等待（防 10s 超时），
   * 再解析出请求信息回调。用户决策后的第二次确认见 acceptRequest。
   */
  private handleSendRequest(message: WsMessage): void {
    this.send(buildWsMessage('ack', message.id, 'sendRequest', '')).catch((error: Error): void => {
      logger.warn('接收请求确认发送失败: ' + error.message);
    });
    let request: ReceiveRequest | undefined = parseSendRequestPayload(message.payload);
    if (request === undefined) {
      if (this.handlers !== null) {
        this.handlers.onError('WS', 'sendRequest payload 解析失败: ' + message.payload);
      }
      return;
    }
    if (this.handlers !== null) {
      this.handlers.onReceiveRequest(request);
    }
  }

  // ── 主动消息 ──

  /**
   * 接受接收请求：用户决策后回第二次 ack:1:sendRequest（协议确认语义，id 与发送端
   * SEND_REQUEST_ID 对应）。发送端的 sendRequest 确认等待已被首次即时 ack 满足，
   * 本消息到达时处于 status 等待循环、按消息名不匹配被安全忽略；第三方发送端
   * 可能依赖该确认信号，故保留发送。
   */
  async acceptRequest(): Promise<void> {
    await this.send(buildWsMessage('ack', MtaConstants.WS_SEND_REQUEST_ID, 'sendRequest', ''));
  }

  /** 拒绝接收请求：回送拒绝状态（等待写入完成） */
  async rejectRequest(taskId: string): Promise<void> {
    await this.sendStatus(MtaConstants.STATUS_TYPE_REFUSE, MtaConstants.STATUS_REASON_REFUSE, taskId);
  }

  /** 发送传输状态（action:100:status?{taskId,id,type,reason}，等待写入完成；帧号对齐可用第三方实现） */
  async sendStatus(type: number, reason: string, taskId: string): Promise<void> {
    let payload = buildStatusPayload(taskId, type, reason);
    let frame = buildWsMessage('action', MtaConstants.STATUS_MESSAGE_ID_RECEIVER, 'status', payload);
    logger.debug(`回送 status 原文=${frame}`);
    await this.send(frame);
  }

  /** 发送 WS 文本消息并等待写入完成（失败抛出，由调用方决定处理方式） */
  private send(text: string): Promise<void> {
    let ws = this.ws;
    if (ws === null) {
      return Promise.reject(new Error('WS 未连接，无法发送'));
    }
    return ws.send(text).then((ok: boolean): void => {
      if (!ok) { throw new Error('WS 写入未完成'); }
    });
  }

  /** 主动关闭 WS 连接并释放实例 */
  async close(): Promise<void> {
    let ws = this.ws;
    if (ws === null) {
      return;
    }
    this.ws = null;
    this.cancelConnect?.();
    try {
      ws.off('open');
      ws.off('message');
      ws.off('close');
      ws.off('error');
      await ws.close();
    } catch (e) {
      logger.warn('WS 关闭失败: ' + errorText(e));
    }
  }

  // ── Rust 主导的接收下载 ──

  /**
   * 驱动一次接收：调用 Rust 下载入口（下载 + 流式解压 + 直接写 `targetDir`），
   * 运行中订阅 `mtaReceiveProgress` 上报进度，完成后以返回元数据构造结果。
   */
  async receiveToTarget(goIp: string, port: number, taskId: string,
    targetDir: string, declaredTotal: number): Promise<DownloadResult> {
    if (taskId.length === 0 || this.activeTaskId.length > 0) { throw new Error('已有下载任务或任务 ID 无效'); }
    this.activeTaskId = taskId;
    this.progressThrottle.reset();
    this.lastNetworkBytes = 0;
    this.subscribeProgress();
    try {
      // 解压总量上限按对端声明值动态计算（声明值 + 容差，并以总上限封顶）；
      // 单条目上限固定，防止单条 zip bomb
      let maxTotalBytes = resolveMaxActualBytes(declaredTotal);
      let metasJson = await nativeMtaReceiveDownload(goIp, port, taskId, targetDir, declaredTotal,
        MtaConstants.MAX_UNZIP_ENTRY_COUNT, maxTotalBytes, MtaConstants.MAX_UNZIP_ENTRY_BYTES,
        undefined, MtaConstants.DOWNLOAD_CONNECT_TIMEOUT_MS, MtaConstants.DOWNLOAD_STALL_TIMEOUT_MS,
        MtaConstants.DOWNLOAD_HEADER_TIMEOUT_MS);
      // 完成态无条件 100%（分母为声明总大小）；网络字节沿用最后一次事件值，
      // 「网络已收完」在此必然成立（下载+解压已整体结束）
      this.reportProgress(declaredTotal, declaredTotal, true, this.lastNetworkBytes, true);
      return this.buildResult(metasJson);
    } catch (e) {
      throw new Error(String(e));
    } finally {
      this.unsubscribeProgress();
      this.activeTaskId = '';
    }
  }

  /** 订阅接收进度事件（单会话，事件仅来自本次下载） */
  private subscribeProgress(): void {
    if (this.progressSubscribed) {
      return;
    }
    onBridgeEvent('mtaReceiveProgress', this.receiveProgressHandler);
    this.progressSubscribed = true;
  }

  /** 退订接收进度事件 */
  private unsubscribeProgress(): void {
    if (!this.progressSubscribed) {
      return;
    }
    offBridgeEvent('mtaReceiveProgress', this.receiveProgressHandler);
    this.progressSubscribed = false;
  }

  /**
   * 上报接收进度：分子为已解压字节、分母为接收请求声明的原始总大小；
   * 同时透传网络读入字节累计与「网络已收完」标记（速率口径与阶段切换）。
   * 按时间节流；完成事件与阶段切换信号无条件上报（不受节流限制）。
   */
  private reportProgress(receivedBytes: number, total: number, isComplete: boolean,
    networkBytes: number, networkDone: boolean): void {
    if (this.handlers === null) {
      return;
    }
    // 阶段切换信号（网络已收完、仍在解压/落盘）必须及时送达，与完成事件同等优先
    if (!this.progressThrottle.shouldReport(Date.now(), isComplete || networkDone)) {
      return;
    }
    let progress = new DownloadProgress();
    progress.receivedBytes = isComplete ? total : receivedBytes;
    progress.totalBytes = total;
    progress.percent = isComplete ? 100 :
      (total > 0 ? Math.min(100, Math.floor(receivedBytes * 100 / total)) : 0);
    progress.netBytes = networkBytes;
    progress.networkDone = networkDone;
    this.handlers.onProgress(progress);
  }

  /** 由 Rust 返回的落盘元数据构造结果（文件名/大小/类型在 ArkTS 按文件名解析） */
  private buildResult(metasJson: string): DownloadResult {
    let result = new DownloadResult();
    let metas: Array<ReceivedEntryMeta> = this.parseReceivedMetas(metasJson);
    for (let i = 0; i < metas.length; i++) {
      let meta = metas[i];
      result.savedFiles.push(meta.savedPath);
      let entry = new ReceivedFileEntry();
      entry.name = meta.name;
      entry.size = meta.size;
      entry.fileType = getMimeForFileName(meta.name);
      result.files.push(entry);
      result.entryCount = result.entryCount + 1;
      result.totalBytes = result.totalBytes + meta.size;
      if (meta.modifiedUnixMs > 0) {
        result.restoredTimeCount = result.restoredTimeCount + 1;
      }
    }
    return result;
  }

  /** 解析 Rust 返回的落盘元数据 JSON，跳过非法项 */
  private parseReceivedMetas(json: string): Array<ReceivedEntryMeta> {
    let metas: Array<ReceivedEntryMeta> = [];
    try {
      let parsed = JSON.parse(json) as Array<Record<string, Object>>;
      for (let i = 0; i < parsed.length; i++) {
        let name = parsed[i]['name'];
        let savedPath = parsed[i]['savedPath'];
        if (typeof name !== 'string' || name.length === 0 ||
          typeof savedPath !== 'string' || savedPath.length === 0) {
          continue;
        }
        let size = parsed[i]['size'];
        let modified = parsed[i]['modifiedUnixMs'];
        let meta = new ReceivedEntryMeta();
        meta.name = name;
        meta.savedPath = savedPath;
        meta.size = typeof size === 'number' ? size : 0;
        meta.modifiedUnixMs = typeof modified === 'number' ? modified : 0;
        metas.push(meta);
      }
    } catch (e) {
      logger.warn('解析接收落盘元数据失败: ' + errorText(e));
    }
    return metas;
  }

  /** 取消当前下载：经 Rust 取消令牌中断；Rust 负责回滚本次已写入的文件 */
  cancelDownload(): void {
    let taskId = this.activeTaskId;
    if (taskId.length === 0) {
      return;
    }
    try {
      nativeCancelTransferLocal(taskId);
    } catch (e) {
      logger.warn('取消下载失败: ' + errorText(e));
    }
  }
}
