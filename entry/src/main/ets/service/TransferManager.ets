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
import { DynamicPhotoService, IncomingFileLike } from '../common/DynamicPhotoService';
import { GalleryAutoSaveService } from '../quickshare/service/GalleryAutoSaveService';
import { PeerDecision } from '../common/PeerLivePhotoFormat';
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
  private readonly pinEntryTimers: Map<string, number> = new Map();
  private readonly listeners: Set<TransferListener> = new Set();
  private readonly progressLogBuckets: Map<string, number> = new Map();
  private readonly activeReceiveKeys: Map<ProtocolKind, string> = new Map();
  private readonly protocolFacades: Map<'quickshare' | 'windowsnearby', GsFacade> = new Map();
  /** 已在沙箱阶段处理过的接收文件（key 见 stageKey），避免搬到下载目录后再白跑一次解析。 */
  private readonly stagedKeys: Set<string> = new Set();
  private localsendServer?: LocalSendServer;
  private cleanupTimer: number = -1;
  private started = false;
  private serverStart?: Promise<void>;
  private serverGeneration: number = 0;

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
    const requestedGeneration = this.serverGeneration;
    while (this.serverStart !== undefined) {
      await this.serverStart;
      if (requestedGeneration !== this.serverGeneration && !this.started) { return; }
    }
    if (this.started) {
      return;
    }
    const generation: number = ++this.serverGeneration;
    const server: LocalSendServer = new LocalSendServer(this.context);
    this.localsendServer = server;
    server.setHandler(this);
    const operation: Promise<void> = server.start();
    this.serverStart = operation;
    try {
      await operation;
      if (generation !== this.serverGeneration) {
        server.stop();
        return;
      }
      this.started = true;
      this.startCleanupTimer();
    } catch (error) {
      server.stop();
      if (this.localsendServer === server) {
        this.localsendServer = undefined;
        this.started = false;
      }
      throw error as Error;
    } finally {
      if (this.serverStart === operation) {
        this.serverStart = undefined;
      }
    }
  }

  stopServer(): void {
    this.serverGeneration += 1;
    this.started = false;
    for (const id of Array.from(this.pinEntryResolvers.keys())) {
      this.submitPinEntry(id, null);
    }
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
      // 动态图片传输(Beta)：按**对端平台**决定封装格式 —— Apple 实况照片 / Android 标准动态照片 /
      // 「图片 + 视频」拆分；认不出对端时用设置里的「默认通用动态图片格式」。
      const decision: PeerDecision = DynamicPhotoService.resolveFormatFor(device);
      const effectiveFiles: OutgoingFile[] = await DynamicPhotoService.prepareOutgoing(this.context, files, decision);
      if (device.protocol === 'localsend') {
        const hooks: SendHooks = {
          onProgress: onProgress,
          onPinRequired: (): Promise<string | null> => this.requestPinEntry(task.id)
        };
        await new LocalSendClient(this.context).send(device, effectiveFiles, hooks);
      } else if (device.protocol === 'quickshare') {
        const hooks: GsSendHooks = { onPin: onPin, onProgress: onProgress };
        await this.facadeFor('quickshare').send(device, effectiveFiles, hooks);
      } else {
        const hooks: GsSendHooks = { onPin: onPin, onProgress: onProgress };
        await this.facadeFor('windowsnearby').send(device, effectiveFiles, hooks);
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
    return new Promise<string | null>((resolve: (pin: string | null) => void): void => {
      this.pinEntryResolvers.set(taskId, resolve);
      this.pinEntryTimers.set(taskId, setTimeout((): void => {
        this.submitPinEntry(taskId, null);
      }, 90000));
      this.emit('pin-entry', task);
    });
  }

  /** UI 提交发送侧 PIN 录入结果（entered===null 表示取消）。 */
  submitPinEntry(taskId: string, entered: string | null): boolean {
    const resolver = this.pinEntryResolvers.get(taskId);
    if (resolver === undefined) {
      return false;
    }
    this.pinEntryResolvers.delete(taskId);
    const timer: number | undefined = this.pinEntryTimers.get(taskId);
    if (timer !== undefined) {
      clearTimeout(timer);
      this.pinEntryTimers.delete(taskId);
    }
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
    this.settleDynamicPhoto(sessionId, file);
  }

  /**
   * 文件刚落到应用沙箱、还没被搬到下载目录时调用（见 LocalSendIncomingHandler.onFileStaged）。
   *
   * 动态图片必须在这一刻处理：搬运到下载目录后沙箱副本会被删除，而下载目录路径应用没有
   * 读权限，之后再想解析原文件就已经读不到字节了（这正是此前「接收到的动图没有变成鸿蒙
   * 动态照片」的直接原因之一）。
   */
  async onFileStaged(sessionId: string, file: IncomingFile): Promise<void> {
    // 不论动态图片开关是否打开，都要记录“这个文件在沙箱阶段处理过”，
    // 防止 onFileReceived 在文件搬走后重复解析。
    this.stagedKeys.add(TransferManager.stageKey(sessionId, file.name, file.size));
    const self: IncomingFileLike = TransferManager.toDynamicFile(file);
    const task = this.taskForSession(sessionId);
    const batch: IncomingFileLike[] = (task !== undefined ? task.receivedFiles : []).map(
      (item: IncomingFile): IncomingFileLike => TransferManager.toDynamicFile(item));
    batch.push(self);

    // HDR 与动态照片开关独立；始终在文件搬出沙箱前逐项处理。
    await DynamicPhotoService.settleReceivedFile(this.context, self, batch, 'localsend:' + sessionId);

    if (GalleryAutoSaveService.enabled()
      && !DynamicPhotoService.isClaimedByDynamicPhoto(self.savedPath)) {
      const result = await GalleryAutoSaveService.saveStaged(
        this.context, self.savedPath, file.name, file.size, file.mime ?? '');
      Lg.i('[GALLERY] staged save handled=' + result.handled
        + ' gallery=' + result.savedToGallery
        + ' name=' + file.name
        + ' uri=' + result.assetUri
        + ' error=' + result.error);
    } else if (DynamicPhotoService.isClaimedByDynamicPhoto(self.savedPath)) {
      Lg.i('[GALLERY] staged skipped (dynamic photo claims file): ' + file.name);
    }
  }

  /**
   * 动态图片传输(Beta)：文件落盘后尝试把它（及其配对视频）还原成鸿蒙动态照片。
   * 不阻塞接收流程（异步执行，失败只记日志）。
   */
  private settleDynamicPhoto(sessionId: string, file: IncomingFile): void {
    if (!DynamicPhotoService.enabled()) {
      return;
    }
    if (this.stagedKeys.has(TransferManager.stageKey(sessionId, file.name, file.size))) {
      // 这个文件在落盘时已经（在沙箱内）处理过了：下载目录里的副本读不了，不必重来。
      Lg.i('[DYNAMIC] already staged, skip post-relocate settle: ' + file.name);
      return;
    }
    const task = this.taskForSession(sessionId);
    const batch: IncomingFile[] = task !== undefined ? task.receivedFiles.concat([file]) : [file];
    const files: IncomingFileLike[] = batch.map((item: IncomingFile): IncomingFileLike =>
      TransferManager.toDynamicFile(item));
    const self: IncomingFileLike = TransferManager.toDynamicFile(file);
    Lg.i('[DYNAMIC] settle after save: ' + file.name + ' path=' + self.savedPath);
    DynamicPhotoService.settleReceivedFile(this.context, self, files, 'localsend:' + sessionId).catch((error: Error): void => {
      Lg.w('[DYNAMIC] settle (localsend) failed: ' + error.message);
    });
  }

  /** 优先用沙箱内的原始路径（下载目录里的副本应用读不了）。 */
  private static toDynamicFile(file: IncomingFile): IncomingFileLike {
    const local = file.localPath !== undefined ? file.localPath : '';
    return {
      name: file.name,
      size: file.size,
      savedPath: local.length > 0 ? local : file.savedPath
    };
  }

  private static stageKey(sessionId: string, name: string, size: number): string {
    return sessionId + '|' + name + '|' + size;
  }

  /** 会话结束（进度到 100 或任务终态）时给等待配对的动态图片最后一次机会。 */
  static settleDynamicBatch(context: common.Context, files: IncomingFile[], scope: string): void {
    if (!DynamicPhotoService.enabled() || files.length === 0) {
      return;
    }
    const batch: IncomingFileLike[] = files.map((item: IncomingFile): IncomingFileLike =>
      TransferManager.toDynamicFile(item));
    DynamicPhotoService.settleBatch(context, batch, scope).catch((error: Error): void => {
      Lg.w('[DYNAMIC] settleBatch failed: ' + error.message);
    });
  }

  onProgress(sessionId: string, progress: number): void {
    this.emitReceiveProgress(sessionId, progress);
  }

  onSessionFailed(sessionId: string, error: string): void {
    const task: TransferTask | undefined = this.taskForSession(sessionId);
    if (task !== undefined) {
      this.finishTask(task.id, false, error);
      this.sessionTasks.delete(sessionId);
    }
  }

  private buildGsReceiveHooks(kind: 'quickshare' | 'windowsnearby'): GsReceiveHooks {
    const manager = this;
    return {
      onIncomingSession: (key: string, peerName: string, files: SessionFileMeta[], pin: string): Promise<boolean> => {
        manager.activeReceiveKeys.set(kind, key);
        return manager.registerIncomingTask(key, kind, peerName, files, pin);
      },
      onFileReceived: (file: IncomingFile): Promise<void> => {
        const key = manager.activeReceiveKeys.get(kind) ?? '';
        manager.emitIncomingFile(key, file);
        return Promise.resolve();
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
      if (percent >= 100 && task.receivedFiles.length >= task.files.length) {
        task.state = 'completed';
        task.completedAt = Date.now();
        this.sessionTasks.delete(sessionKey);
        this.emit('completed', task);
        // 动态图片传输(Beta)：会话结束，给「先到图片、后到视频」的配对最后一次机会。
        TransferManager.settleDynamicBatch(this.context, task.receivedFiles, 'localsend:' + sessionKey);
        const stagedPrefix = sessionKey + '|';
        for (const key of Array.from(this.stagedKeys.keys())) {
          if (key.startsWith(stagedPrefix)) { this.stagedKeys.delete(key); }
        }
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

