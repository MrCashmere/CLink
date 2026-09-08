import { LogCapture as Lg } from '../common/LogCapture';
import { common } from '@kit.AbilityKit';
import { CertificateStore } from '../common/CertificateStore';
import { PinGate } from '../common/PinGate';
import {
  DeviceEndpoint,
  IncomingFile,
  OutgoingFile,
  ProtocolKind,
  SessionFileMeta,
  TransferDirection,
  TransferEvent,
  TransferEventKind,
  TransferListener,
  TransferTask,
  WebShareInfo
} from '../model/TransferModels';
import { LocalSendClient, SendHooks } from '../protocol/localsend/LocalSendClient';
import {
  IncomingSessionRequest,
  LocalSendIncomingHandler,
  LocalSendServer
} from '../protocol/localsend/LocalSendServer';
import {
  createGsFacade,
  GsFacade,
  GsReceiveHooks,
  GsSendHooks,
  GS_NEARSHARE_PORT,
  GS_QUICKSHARE_PORT
} from '../protocol/gs/GsFacade';

const CLEANUP_INTERVAL_MS = 60000;
const TASK_TTL_MS = 30 * 60 * 1000;
const MAX_TASKS = 100;
const MAX_PROGRESS_BUCKETS = 200;

function messageOf(error: Error | Object): string {
  if (error instanceof Error) {
    return error.message;
  }
  return JSON.stringify(error);
}

export class TransferManager implements LocalSendIncomingHandler {
  private readonly tasks: Map<string, TransferTask> = new Map();
  private readonly sessionTasks: Map<string, string> = new Map();
  private readonly pinEntryResolvers: Map<string, (pin: string | null) => void> = new Map();
  private readonly listeners: Set<TransferListener> = new Set();
  private readonly progressLogBuckets: Map<string, number> = new Map();
  private readonly activeReceiveKeys: Map<ProtocolKind, string> = new Map();
  private readonly protocolFacades: Map<'quickshare' | 'windowsnearby', GsFacade> = new Map();
  private localsendServer?: LocalSendServer;
  private cleanupTimer: number = -1;
  private started = false;

  private readonly context: common.Context;
  private readonly certs: CertificateStore;

  constructor(context: common.Context, certs: CertificateStore) {
    this.context = context;
    this.certs = certs;
  }

  addListener(listener: TransferListener): void {
    this.listeners.add(listener);
  }

  removeListener(listener: TransferListener): void {
    this.listeners.delete(listener);
  }

  listTasks(): TransferTask[] {
    return Array.from(this.tasks.values());
  }

  getTask(taskId: string): TransferTask | undefined {
    return this.tasks.get(taskId);
  }

  /** 局域网网页传输：注册一个本机文件供网页端下载，返回共享 id（空串表示失败）。 */
  shareFileForWeb(path: string, name: string, size: number): string {
    return this.localsendServer?.addShare(path, name, size) ?? '';
  }

  /** 局域网网页传输：当前可下载的共享文件列表。 */
  listWebShares(): WebShareInfo[] {
    return this.localsendServer?.listShares() ?? [];
  }

  /** 局域网网页传输：停止共享某个文件。 */
  removeWebShare(id: string): boolean {
    return this.localsendServer?.removeShare(id) ?? false;
  }

  async startServer(): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    this.localsendServer = new LocalSendServer(this.context);
    this.localsendServer.setHandler(this);
    await this.localsendServer.start();
    // Quick Share/Windows Nearby 接收由各自独立页面负责，不再由全局服务占用端口。
    this.startCleanupTimer();
  }

  stopServer(): void {
    if (!this.started) {
      return;
    }
    this.started = false;
    this.stopCleanupTimer();
    this.localsendServer?.stop();
    this.localsendServer = undefined;
    this.protocolFacades.forEach((facade: GsFacade) => facade.stopReceive());
    this.protocolFacades.clear();
  }

  private facadeFor(kind: 'quickshare' | 'windowsnearby'): GsFacade {
    const existing = this.protocolFacades.get(kind);
    if (existing !== undefined) {
      return existing;
    }
    const facade = createGsFacade(kind, this.context);
    this.protocolFacades.set(kind, facade);
    return facade;
  }

  async send(device: DeviceEndpoint, files: OutgoingFile[]): Promise<TransferTask> {
    const task = new TransferTask(device, files, 'send');
    task.gateKey = task.id;
    this.tasks.set(task.id, task);
    this.maybePruneTasks();
    Lg.i('[TRANSFER] send: task=' + task.id + ' protocol=' + device.protocol + ' peer=' + device.name + ' files=' + files.length + ' (set into map)');
    this.emit('started', task);
    const onPin = async (pin: string): Promise<boolean> => {
      task.pin = pin;
      task.state = 'awaiting-pin';
      this.emit('pin-request', task);
      return PinGate.request(task.gateKey);
    };
    const onProgress = (percent: number): void => {
      task.state = 'running';
      task.progress = percent;
      this.emit('progress', task);
    };
    task.state = 'running';
    try {
      if (device.protocol === 'localsend') {
        const hooks: SendHooks = {
          onProgress: onProgress,
          onPinRequired: (): Promise<string | null> => this.requestPinEntry(task.id)
        };
        await new LocalSendClient(this.context).send(device, files, hooks);
      } else if (device.protocol === 'quickshare') {
        const hooks: GsSendHooks = { onPin: onPin, onProgress: onProgress };
        await this.facadeFor('quickshare').send(device, files, hooks);
      } else {
        const hooks: GsSendHooks = { onPin: onPin, onProgress: onProgress };
        await this.facadeFor('windowsnearby').send(device, files, hooks);
      }
      task.state = 'completed';
      task.progress = 100;
      task.completedAt = Date.now();
      this.emit('completed', task);
    } catch (error) {
      task.state = 'failed';
      task.completedAt = Date.now();
      task.error = messageOf(error as Error);
      Lg.e('羊绒互传 transfer failed: ' + task.error);
      this.emit('failed', task);
    }
    return task;
  }

  confirmPin(taskId: string, accepted: boolean): boolean {
    const task = this.tasks.get(taskId);
    if (task === undefined) {
      return false;
    }
    const gateKey = task.gateKey.length > 0 ? task.gateKey : task.id;
    const resolved = PinGate.resolve(gateKey, accepted);
    if (resolved) {
      task.state = accepted ? 'running' : 'rejected';
      if (!accepted) {
        task.completedAt = Date.now();
      }
      this.emit(accepted ? 'progress' : 'failed', task);
    }
    return resolved;
  }

  /** 供不走 send() 的发送路径（如聚合页的 Quick Share / Windows Nearby 直发）登记一个
   *  进行中任务，便于播放进度条 / 出现在 listTasks() 中。返回任务 id。 */
  manualTask(device: DeviceEndpoint, files: OutgoingFile[], direction: TransferDirection, protocol: ProtocolKind): TransferTask {
    const task = new TransferTask(device, files, direction);
    task.gateKey = task.id;
    task.state = 'running';
    this.tasks.set(task.id, task);
    this.maybePruneTasks();
    this.emit('started', task);
    return task;
  }

  /** 手动进度更新（发送侧分块进度打到 0-100）。 */
  setTaskProgress(taskId: string, percent: number): void {
    const task = this.tasks.get(taskId);
    if (task === undefined) {
      return;
    }
    task.state = 'running';
    task.progress = percent;
    this.emit('progress', task);
  }

  /** 手动结束任务（ok=true 视为已完成，否则失败）。 */
  finishTask(taskId: string, ok: boolean, error: string = ''): void {
    const task = this.tasks.get(taskId);
    if (task === undefined) {
      return;
    }
    task.state = ok ? 'completed' : 'failed';
    task.progress = ok ? 100 : task.progress;
    task.completedAt = Date.now();
    task.error = error;
    this.emit(ok ? 'completed' : 'failed', task);
  }

  /** 本地端作为发送方、对端要求 PIN 时：挂起任务并请求 UI 录入 PIN（LocalSend 官方语义）。 */
  private requestPinEntry(taskId: string): Promise<string | null> {
    const task = this.tasks.get(taskId);
    if (task === undefined) {
      return Promise.resolve(null);
    }
    task.state = 'awaiting-pin';
    this.emit('pin-entry', task);
    return new Promise<string | null>((resolve: (pin: string | null) => void): void => {
      this.pinEntryResolvers.set(taskId, resolve);
    });
  }

  /** UI 提交发送侧 PIN 录入结果（entered===null 表示取消）。 */
  submitPinEntry(taskId: string, entered: string | null): boolean {
    const resolver = this.pinEntryResolvers.get(taskId);
    if (resolver === undefined) {
      return false;
    }
    this.pinEntryResolvers.delete(taskId);
    resolver(entered);
    return true;
  }

  private emit(kind: TransferEventKind, task: TransferTask): void {
    const event: TransferEvent = { kind, task };
    this.listeners.forEach((listener: TransferListener) => listener(event));
  }

  private registerIncomingTask(
    gateKey: string,
    protocol: ProtocolKind,
    peerName: string,
    files: SessionFileMeta[],
    pin: string
  ): Promise<boolean> {
    const device: DeviceEndpoint = {
      id: `incoming:${gateKey}`,
      name: peerName,
      model: 'peer',
      protocol,
      address: '',
      port: 0,
      https: false,
      fingerprint: '',
      source: 'manual'
    };
    const outgoing = files.map((meta: SessionFileMeta): OutgoingFile => ({
      path: '',
      name: meta.name,
      size: meta.size,
      mime: meta.mime ?? 'application/octet-stream'
    }));
    const task = new TransferTask(device, outgoing, 'receive');
    task.gateKey = gateKey;
    task.pin = pin;
    task.state = 'awaiting-pin';
    this.tasks.set(task.id, task);
    this.sessionTasks.set(gateKey, task.id);
    this.maybePruneTasks();
    this.emit('pin-request', task);
    Lg.i('羊绒互传 receive: task ' + task.id + ' registered for ' + peerName + ' files=' + files.length + ' (awaiting user confirmation)');
    // 无论是否配置 requirePin，接收都必须经用户在弹窗里确认（接受/拒绝）后才放行，
    // 防止“对端一发就静默接收”导致无弹窗问题。settings.requirePin 只影响发送侧
    // 是否要求对端展示/输入 PIN（见 LocalSendClient / LocalSendServer.checkPin），
    // 不决定接收侧是否要本机确认。
    return PinGate.request(gateKey).then((accepted: boolean): boolean => {
      this.settleIncomingSession(gateKey, accepted);
      return accepted;
    });
  }

  /**
   * 供 Quick Share / Windows Nearby 接收路径（其确认与落盘由各自流程负责）登记一个仅用于
   * 传输卡片展示的进行中接收任务。跳过 PIN 弹窗（外部已处理确认），返回任务 id；
   * 随后用 setTaskProgress / addReceivedFile / finishTask 更新卡片状态。
   */
  trackIncoming(protocol: 'quickshare' | 'windowsnearby', sessionKey: string, peerName: string, files: SessionFileMeta[]): string {
    const device: DeviceEndpoint = {
      id: 'incoming:' + sessionKey,
      name: peerName,
      model: 'peer',
      protocol,
      address: '',
      port: 0,
      https: false,
      fingerprint: '',
      source: 'manual'
    };
    const outgoing = files.map((meta: SessionFileMeta): OutgoingFile => ({
      path: '',
      name: meta.name,
      size: meta.size,
      mime: meta.mime ?? 'application/octet-stream'
    }));
    const task = new TransferTask(device, outgoing, 'receive');
    task.gateKey = sessionKey;
    task.state = 'running';
    this.tasks.set(task.id, task);
    this.sessionTasks.set(sessionKey, task.id);
    this.maybePruneTasks();
    this.emit('started', task);
    Lg.i('羊绒互传 receive: card-tracked task ' + task.id + ' for ' + peerName + ' (' + protocol + ') files=' + files.length);
    return task.id;
  }

  /** 把已接收文件追加到指定接收任务（用于卡片/完成提示）。 */
  addReceivedFile(taskId: string, file: IncomingFile): void {
    const task = this.tasks.get(taskId);
    if (task === undefined) {
      return;
    }
    task.receivedFiles.push(file);
    this.emit('incoming', task);
  }

  private settleIncomingSession(gateKey: string, accepted: boolean): void {
    const task = this.taskForSession(gateKey);
    if (task === undefined || task.state !== 'awaiting-pin') {
      return;
    }
    task.state = accepted ? 'running' : 'rejected';
    if (!accepted) {
      task.completedAt = Date.now();
      this.sessionTasks.delete(gateKey);
    }
    this.emit(accepted ? 'progress' : 'failed', task);
  }

  private taskForSession(sessionKey: string): TransferTask | undefined {
    const taskId = this.sessionTasks.get(sessionKey);
    if (taskId === undefined) {
      return undefined;
    }
    return this.tasks.get(taskId);
  }

  onSessionRequested(request: IncomingSessionRequest): Promise<boolean> {
    return this.registerIncomingTask(request.sessionId, 'localsend', request.peerName, request.files, request.pin);
  }

  onSessionResolved(sessionId: string, accepted: boolean): void {
    this.settleIncomingSession(sessionId, accepted);
  }

  onFileReceived(sessionId: string, file: IncomingFile): void {
    Lg.i('羊绒互传 receive: file saved ' + file.name + ' (' + file.size + ' bytes) -> ' + file.savedPath);
    this.emitIncomingFile(sessionId, file);
  }

  onProgress(sessionId: string, progress: number): void {
    this.emitReceiveProgress(sessionId, progress);
  }

  private buildGsReceiveHooks(kind: 'quickshare' | 'windowsnearby'): GsReceiveHooks {
    const manager = this;
    return {
      onIncomingSession: (key: string, peerName: string, files: SessionFileMeta[], pin: string): Promise<boolean> => {
        manager.activeReceiveKeys.set(kind, key);
        return manager.registerIncomingTask(key, kind, peerName, files, pin);
      },
      onFileReceived: (file: IncomingFile): void => {
        const key = manager.activeReceiveKeys.get(kind) ?? '';
        manager.emitIncomingFile(key, file);
      },
      onProgress: (percent: number): void => {
        const key = manager.activeReceiveKeys.get(kind) ?? '';
        manager.emitReceiveProgress(key, percent);
      }
    };
  }

  private emitIncomingFile(sessionKey: string, file: IncomingFile): void {
    const task = this.taskForSession(sessionKey);
    if (task !== undefined) {
      task.receivedFiles.push(file);
      this.emit('incoming', task);
    }
  }

  private emitReceiveProgress(sessionKey: string, percent: number): void {
    const bucket = Math.floor(percent / 10) * 10;
    const lastBucket = this.progressLogBuckets.get(sessionKey) ?? -1;
    if (percent <= 0 || percent >= 100 || bucket !== lastBucket) {
      Lg.i('羊绒互传 receive: progress ' + percent + '%');
      this.progressLogBuckets.set(sessionKey, bucket);
    }
    const task = this.taskForSession(sessionKey);
    if (task !== undefined) {
      task.progress = percent;
      this.emit('progress', task);
      if (percent >= 100) {
        task.state = 'completed';
        task.completedAt = Date.now();
        this.sessionTasks.delete(sessionKey);
        this.emit('completed', task);
      }
    }
  }

  private startCleanupTimer(): void {
    this.stopCleanupTimer();
    this.cleanupTimer = setInterval((): void => {
      this.pruneTransfers();
    }, CLEANUP_INTERVAL_MS);
  }

  private stopCleanupTimer(): void {
    if (this.cleanupTimer !== -1) {
      clearInterval(this.cleanupTimer);
      this.cleanupTimer = -1;
    }
  }

  private pruneTransfers(): void {
    const now = Date.now();
    const sessionKeys = Array.from(this.sessionTasks.keys());
    for (const key of sessionKeys) {
      const taskId = this.sessionTasks.get(key);
      if (taskId === undefined || !this.tasks.has(taskId)) {
        this.sessionTasks.delete(key);
      }
    }
    if (this.progressLogBuckets.size > MAX_PROGRESS_BUCKETS) {
      this.progressLogBuckets.clear();
    }
    const ids = Array.from(this.tasks.keys());
    for (const id of ids) {
      const task = this.tasks.get(id);
      if (task === undefined) {
        continue;
      }
      const terminal = task.state === 'completed' || task.state === 'failed' || task.state === 'rejected';
      if (terminal && now - task.createdAt > TASK_TTL_MS) {
        this.tasks.delete(id);
      }
    }
  }

  private maybePruneTasks(): void {
    if (this.tasks.size <= MAX_TASKS) {
      return;
    }
    const terminal: TransferTask[] = [];
    this.tasks.forEach((task: TransferTask) => {
      if (task.state === 'completed' || task.state === 'failed' || task.state === 'rejected') {
        terminal.push(task);
      }
    });
    terminal.sort((a: TransferTask, b: TransferTask): number => a.createdAt - b.createdAt);
    let index = 0;
    while (this.tasks.size > MAX_TASKS && index < terminal.length) {
      const candidate = terminal[index];
      if (this.tasks.has(candidate.id)) {
        this.tasks.delete(candidate.id);
      }
      index += 1;
    }
  }
}

