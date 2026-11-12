import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import promptAction from '@ohos.promptAction';
import { DeviceEndpoint, OutgoingFile, TransferTask, IncomingFile } from '../model/TransferModels';
import { AppServices } from '../common/AppServices';
import { SettingsStore } from '../common/SettingsStore';
import { PinDialogGuard } from '../common/PinDialogGuard';
import { LogCapture } from '../common/LogCapture';
import { dialogSystemMaterial } from '../utils/SystemMaterial';
import { HwColor } from '../utils/DesignTokens';
import { MtaSendService } from './upstream/service/mta/MtaSendService';
import { MtaDiscoveredDevice, MtaSendFile, SenderState, MtaSenderStage, MtaSendEventHandlers, mtaDeviceIdentityKey } from './upstream/model/mta/MtaSendModels';
import { ReceiverState, ReceiverStage, ReceiveRequest, ReceivedFileEntry } from './upstream/model/mta/MtaProtocolModels';
import { MtaGalleryService } from './MtaGalleryService';
import { preferencesRepo } from './upstream/service/repository/PreferencesRepo';
import { configureMtaSendDirs } from './upstream/service/repository/SendRepository';
import { configureMtaTextDirectory } from './upstream/service/repository/ReceiveTargets';
import { listMtaReceiveHistory } from './upstream/service/repository/ReceiveHistoryService';
import { getMtaSimulatedBrand, setMtaHostForeground } from './upstream/service/repository/SettingsRepository';
import { setMtaPermissionContext } from './upstream/service/PermissionService';
import { onMtaHostChange } from './upstream/service/repository/AppCore';
import { configureMtaReceiveHost, acceptMtaHostRequest, rejectMtaHostRequest, cancelMtaHostReceive } from './upstream/service/transfer/adapters/MtaReceiveAdapter';
import { startMtaDiscoveryScan, stopMtaDiscoveryScan, rescanMtaDiscovery, getMtaDiscoveredDevices,
  startMtaReceiveIfEnabled, stopMtaReceive, refreshMtaReceiveIdentity, pauseMtaDiscoveryForSend,
  resumeMtaDiscoveryAfterSend, suspendMtaReceiveForSend, resumeMtaReceiveAfterSend } from './upstream/service/repository/MtaRepository';
import { deviceInfo } from '@kit.BasicServicesKit';
import { utf8ByteLength } from './upstream/service/mta/MtaBleCommon';
import { mtaSendStageLabel } from './upstream/model/mta/MtaMainModels';

export interface MtaRecord {
  id: string;
  name: string;
  peer: string;
  size: number;
  direction: string;
  savedPath: string;
  completedAt: number;
}

/** 宿主只消费状态与命令；BLE/GATT、ECDH、P2P、WS/TLS、ZIP 均由上游实现。 */
export class MtaService {
  private static instance?: MtaService;
  private context: common.UIAbilityContext;
  private sender?: MtaSendService;
  private listeners: Set<() => void> = new Set<() => void>();
  private peers: Map<string, MtaDiscoveredDevice> = new Map<string, MtaDiscoveredDevice>();
  private active: boolean = false;
  private sending: boolean = false;
  private operation: Promise<void> = Promise.resolve();
  private receiveTaskId: string = '';
  private confirmTask: string = '';
  private sendTask?: TransferTask;
  private senderSnapshot: SenderState = new SenderState();
  private receiverSnapshot: ReceiverState = new ReceiverState();
  private errorText: string = '';
  private sendGeneration: number = 0;
  private teardownTimer: number = -1;

  private constructor(context: common.UIAbilityContext) {
    this.context = context;
    preferencesRepo.init(context);
    setMtaPermissionContext(context);
    const sendDir = context.filesDir + '/mta_send_text';
    const thumbDir = context.cacheDir + '/mta_thumbnails';
    const recvDir = context.filesDir + '/mta_receive_text';
    for (const dir of [sendDir, thumbDir, recvDir]) { if (!fs.accessSync(dir)) { fs.mkdirSync(dir, true); } }
    configureMtaSendDirs(sendDir, thumbDir);
    configureMtaTextDirectory(recvDir);
    onMtaHostChange((): void => this.notify());
    configureMtaReceiveHost((state: ReceiverState): void => {
      try { this.receiveChanged(state); } catch (error) { this.fault('接收状态更新失败：' + String(error)); }
    }, (savedPath: string): void => {
      try { if (this.receiveTaskId.length > 0) {
        const stat = fs.statSync(savedPath);
        this.transfer().addReceivedFile(this.receiveTaskId, { name: 'sharedText.txt', size: stat.size, savedPath: savedPath });
        // 文本接受不进入下载状态机；以上游实际落盘通知收束宿主任务。
        this.transfer().finishTask(this.receiveTaskId, true);
        this.receiveTaskId = '';
      } } catch (error) { LogCapture.w('[MTA] 文本元数据更新失败：' + String(error)); }
    }, {
      receiveDirectory: (original: string): string => MtaGalleryService.receiveDirectory(this.context, original),
      finishReceived: (paths: string[], files: ReceivedFileEntry[]): Promise<string[]> =>
        MtaGalleryService.finishReceived(this.context, paths, files)
    });
  }

  static get(context: common.UIAbilityContext): MtaService {
    if (MtaService.instance === undefined) { MtaService.instance = new MtaService(context); }
    return MtaService.instance;
  }
  addListener(listener: () => void): void { this.listeners.add(listener); }
  removeListener(listener: () => void): void { this.listeners.delete(listener); }
  private notify(): void {
    this.listeners.forEach((listener: () => void): void => {
      try { listener(); } catch (error) { LogCapture.w('[MTA] UI 回调失败：' + String(error)); }
    });
  }
  private fault(message: string): void { this.errorText = message; LogCapture.w('[MTA] ' + message); this.notify(); }
  private transfer() { return AppServices.get(this.context).transfer; }
  enabled(): boolean { return preferencesRepo.getString('enabled', 'true') === 'true'; }
  async setEnabled(enabled: boolean): Promise<void> {
    preferencesRepo.setString('enabled', String(enabled));
    if (enabled) { this.start(); } else { await this.stop(); }
    this.notify();
  }
  brandId(): number { return getMtaSimulatedBrand(); }
  async setBrand(brandId: number): Promise<void> {
    preferencesRepo.setString('simulatedBrand', String(brandId));
    if (this.active && !this.sending) { refreshMtaReceiveIdentity(); }
    this.notify();
  }
  start(): void {
    if (!this.enabled() || deviceInfo.sdkApiVersion < 23) { return; }
    this.active = true;
    setMtaHostForeground(true);
    this.queueStart();
  }
  private queueStart(): void {
    this.operation = this.operation.then(async (): Promise<void> => {
      if (!this.active || this.sending || !this.enabled()) { return; }
      await SettingsStore.load(this.context);
      if (!this.active || this.sending) { return; }
      startMtaDiscoveryScan();
      startMtaReceiveIfEnabled(this.context);
      this.errorText = '';
      this.notify();
    }).catch((error: Error): void => this.fault(error.message ?? String(error)));
  }
  async stop(): Promise<void> {
    this.active = false;
    setMtaHostForeground(false);
    await this.operation;
    if (this.active) { return; }
    stopMtaDiscoveryScan();
    stopMtaReceive();
    this.notify();
  }
  refreshDiscovery(): void {
    if (this.active && !this.sending) { rescanMtaDiscovery(); }
  }
  async refresh(): Promise<void> {
    this.start();
    await this.operation;
    if (!this.sending && this.active) { rescanMtaDiscovery(); refreshMtaReceiveIdentity(); }
  }
  devices(): DeviceEndpoint[] {
    const devices: DeviceEndpoint[] = [];
    this.peers.clear();
    if (!this.enabled() || deviceInfo.sdkApiVersion < 23) { return devices; }
    for (const discovered of getMtaDiscoveredDevices()) {
      const peer = new MtaDiscoveredDevice();
      peer.bleAddress = discovered.mtaBleAddress ?? discovered.fingerprint;
      peer.deviceName = discovered.alias; peer.senderIdHex = discovered.mtaSenderIdHex ?? '';
      peer.brandId = discovered.mtaBrandId ?? -1; peer.brandName = discovered.mtaBrandName ?? 'Android';
      peer.is5Ghz = discovered.mtaIs5Ghz ?? false; peer.rssi = discovered.mtaRssi ?? 0;
      this.peers.set(mtaDeviceIdentityKey(peer), peer);
    }
    this.peers.forEach((peer: MtaDiscoveredDevice, key: string): void => { devices.push({
      id: 'mta:' + key, name: peer.deviceName || peer.bleAddress, model: peer.brandName,
      protocol: 'mta', address: peer.bleAddress, port: 0, https: true,
      fingerprint: peer.senderIdHex, source: 'ble', supports5Ghz: peer.is5Ghz
    }); });
    return devices;
  }
  status(): string {
    if (deviceInfo.sdkApiVersion < 23) { return '互传联盟需要 HarmonyOS 6.1（API 23）及以上'; }
    if (!this.enabled()) { return '互传联盟已关闭'; }
    if (this.errorText.length > 0) { return this.errorText; }
    if (this.sending) {
      const label: ResourceStr = mtaSendStageLabel(this.senderSnapshot.stage);
      return '发送：' + (typeof label === 'string' ? label : this.context.resourceManager.getStringSync(label.id));
    }
    if (this.receiverSnapshot.stage === ReceiverStage.REQUEST_RECEIVED) { return '等待确认接收'; }
    if (this.receiverSnapshot.stage === ReceiverStage.DOWNLOADING) { return '正在接收文件'; }
    return this.receiverSnapshot.serviceRunning ? '正在扫描 · 可接收互传联盟文件' : '等待蓝牙与 WLAN 就绪';
  }
  isBusy(): boolean {
    const stage = this.receiverSnapshot.stage;
    return this.sending || this.receiveTaskId.length > 0 || (stage !== ReceiverStage.IDLE &&
      stage !== ReceiverStage.SERVICE_RUNNING && stage !== ReceiverStage.COMPLETED && stage !== ReceiverStage.FAILED);
  }
  records(): MtaRecord[] {
    const records = this.sendRecords();
    for (const entry of listMtaReceiveHistory()) {
      records.push({ id: entry.id, name: entry.fileName, peer: entry.senderAlias, size: entry.fileSize,
        direction: 'receive', savedPath: entry.path, completedAt: entry.timestamp });
    }
    return records.sort((a: MtaRecord, b: MtaRecord): number => b.completedAt - a.completedAt);
  }
  private sendRecords(): MtaRecord[] {
    try {
      const records: MtaRecord[] = JSON.parse(preferencesRepo.getString('sendHistory', '[]')) as MtaRecord[];
      return Array.isArray(records) ? records : [];
    } catch (error) { LogCapture.w('[MTA] 读取发送历史失败：' + String(error)); return []; }
  }
  private destroySender(): void {
    if (this.teardownTimer >= 0) { clearTimeout(this.teardownTimer); this.teardownTimer = -1; }
    const previous = this.sender;
    this.sender = undefined;
    if (previous !== undefined) { previous.setSessionEndListener(null); previous.destroy(); }
  }
  private otherWirelessTransferActive(): boolean {
    return this.transfer().listTasks().some((task: TransferTask): boolean =>
      task.device.protocol === 'quickshare' && task.completedAt === 0);
  }
  private scheduleSenderTeardown(sender: MtaSendService, generation: number): void {
    this.teardownTimer = setTimeout((): void => {
      this.teardownTimer = -1;
      if (generation !== this.sendGeneration || this.sender !== sender) { return; }
      // 上游 destroy() 会删除 P2P 组；接收中或其它无线传输期间不得删除它们的当前群组。
      if (this.isBusy() || this.otherWirelessTransferActive()) { this.scheduleSenderTeardown(sender, generation); return; }
      this.destroySender();
    }, 5000);
  }
  async send(device: DeviceEndpoint, files: OutgoingFile[], text?: string): Promise<void> {
    const clickedMs = Date.now();
    if (deviceInfo.sdkApiVersion < 23) { throw new Error('互传联盟需要 API 23 及以上'); }
    if (!this.enabled()) { throw new Error('请先开启互传联盟'); }
    if (this.isBusy()) { throw new Error('互传联盟正在传输，请稍后再试'); }
    if (this.otherWirelessTransferActive()) { throw new Error('另一个无线传输正在进行，请完成后再发送'); }
    if (files.length === 0 && (text === undefined || text.length === 0)) { throw new Error('请先选择文件或输入文本'); }
    this.devices();
    const peer = this.peers.get(device.id.slice(4));
    if (peer === undefined) { throw new Error('设备已离线，请刷新后重试'); }
    this.sending = true;
    this.sendTask = undefined;
    this.senderSnapshot = new SenderState();
    const generation = ++this.sendGeneration;
    let suspended = false;
    let released = false;
    const releaseAccounting = (): void => {
      if (!suspended || released) { return; }
      released = true;
      resumeMtaReceiveAfterSend().catch((error: Error): void => this.fault(error.message));
      if (this.active) { resumeMtaDiscoveryAfterSend(); }
    };
    try {
      await this.operation;
      this.destroySender();
      pauseMtaDiscoveryForSend();
      suspended = true;
      const gate = suspendMtaReceiveForSend();
      const sender = new MtaSendService();
      this.sender = sender;
      const hooks = new MtaSendEventHandlers();
      hooks.onStateChange = (state: SenderState): void => {
        if (generation !== this.sendGeneration) { return; }
        try { this.sendChanged(state); } catch (error) { this.fault('发送状态更新失败：' + String(error)); }
      };
      sender.setEventHandlers(hooks);
      sender.init(this.context);
      sender.setPeripheralReleaseGate(gate);
      sender.setUserClickMs(clickedMs);
      sender.setSessionEndListener((): void => {
        releaseAccounting();
        if (generation !== this.sendGeneration) { return; }
        this.sending = false;
        // 与上游发送适配器相同：先让链路完成收尾，五秒后回收日志及订阅；新发送先撤销旧回收。
        this.scheduleSenderTeardown(sender, generation);
        this.notify();
      });
      const outgoing: MtaSendFile[] = files.map((file: OutgoingFile): MtaSendFile => {
        const item = new MtaSendFile();
        item.uri = file.path; item.displayName = file.name; item.sizeBytes = file.size;
        return item;
      });
      const displayed: OutgoingFile[] = files.length > 0 ? files : [{ path: '', name: 'sharedText.txt', size: utf8ByteLength(text ?? ''), mime: 'text/plain' }];
      this.sendTask = this.transfer().manualTask(device, displayed, 'send', 'mta');
      await sender.sendToDevice(peer, outgoing, text);
    } catch (error) {
      this.sending = false;
      if (this.sendTask !== undefined) { this.transfer().finishTask(this.sendTask.id, false, String(error)); }
      this.destroySender();
      releaseAccounting();
      throw new Error(String(error));
    }
  }
  async cancelSend(): Promise<void> { await this.sender?.cancelSend(); }
  cancelReceive(): void { cancelMtaHostReceive(); }
  private sendChanged(state: SenderState): void {
    this.senderSnapshot = state;
    const task = this.sendTask;
    if (task !== undefined && task.completedAt === 0) {
      this.transfer().setTaskProgress(task.id, state.progress.percent);
      if (state.stage === MtaSenderStage.COMPLETED) {
        this.transfer().finishTask(task.id, true);
        try {
          const history = this.sendRecords();
          for (let index = 0; index < task.files.length; index++) {
            const file = task.files[index];
            history.unshift({ id: task.id + ':' + index, name: file.name, peer: task.device.name,
              size: file.size, direction: 'send', savedPath: '', completedAt: Date.now() });
          }
          preferencesRepo.setString('sendHistory', JSON.stringify(history.slice(0, 500)));
        } catch (error) { LogCapture.w('[MTA] 保存发送历史失败：' + String(error)); }
      } else if (state.stage === MtaSenderStage.FAILED || state.stage === MtaSenderStage.REJECTED ||
        state.stage === MtaSenderStage.CANCELLED || state.stage === MtaSenderStage.PARTIAL) {
        this.transfer().finishTask(task.id, false, state.lastError || this.stageLabel(state.stage));
      }
    }
    this.notify();
  }
  private stageLabel(stage: MtaSenderStage): string {
    if (stage === MtaSenderStage.PARTIAL) { return '对方仅接收了部分文件'; }
    if (stage === MtaSenderStage.REJECTED) { return '对方拒绝接收'; }
    return '传输已取消';
  }
  private receiveChanged(state: ReceiverState): void {
    this.receiverSnapshot = state;
    const request = state.receiveRequest;
    if (state.stage === ReceiverStage.REQUEST_RECEIVED && request !== undefined && this.confirmTask !== request.taskId) {
      this.confirmTask = request.taskId;
      void this.confirmReceive(request);
    }
    if (this.receiveTaskId.length > 0) {
      if (state.stage === ReceiverStage.DOWNLOADING) { this.transfer().setTaskProgress(this.receiveTaskId, state.progress.percent); }
      if (state.stage === ReceiverStage.COMPLETED) {
        for (let i = 0; i < state.savedFiles.length; i++) {
          const meta = state.receivedFiles[i];
          const file: IncomingFile = { name: meta?.name ?? state.savedFiles[i].split('/').pop() ?? '',
            size: meta?.size ?? 0, savedPath: state.savedFiles[i], localPath: state.savedFiles[i] };
          this.transfer().addReceivedFile(this.receiveTaskId, file);
        }
        this.transfer().finishTask(this.receiveTaskId, true); this.receiveTaskId = '';
      } else if (state.stage === ReceiverStage.FAILED || state.stage === ReceiverStage.IDLE || state.stage === ReceiverStage.SERVICE_RUNNING) {
        this.transfer().finishTask(this.receiveTaskId, false, state.lastError || '接收已结束'); this.receiveTaskId = '';
      }
    }
    if (state.stage === ReceiverStage.SERVICE_RUNNING || state.stage === ReceiverStage.IDLE) { this.confirmTask = ''; }
    this.notify();
  }
  private async confirmReceive(request: ReceiveRequest): Promise<void> {
    if (!PinDialogGuard.tryBegin()) { rejectMtaHostRequest(); return; }
    try {
      const result = await promptAction.showDialog({
        systemMaterial: dialogSystemMaterial(), title: '互传联盟接收请求',
        message: '「' + request.senderName + '」想发送 ' + (request.textContent.length > 0 ? '文本：\n' + request.textContent.slice(0, 300) :
          request.fileCount + ' 个文件（' + request.totalSize + ' 字节）'),
        buttons: [{ text: '拒绝', color: HwColor.textSecondary }, { text: '接收', color: HwColor.primary }]
      });
      if (this.receiverSnapshot.receiveRequest !== request || this.receiverSnapshot.stage !== ReceiverStage.REQUEST_RECEIVED) { return; }
      if (result.index !== 1) { rejectMtaHostRequest(); return; }
      const device: DeviceEndpoint = { id: 'mta:receive:' + request.taskId, name: request.senderName,
        model: '互传联盟', protocol: 'mta', address: '', port: 0, https: true, fingerprint: request.senderId, source: 'ble' };
      const task = this.transfer().manualTask(device, [{ path: '', name: request.fileName || 'sharedText.txt',
        size: request.totalSize, mime: 'application/octet-stream' }], 'receive', 'mta');
      this.receiveTaskId = task.id;
      acceptMtaHostRequest(request.textContent.length > 0);
    } catch (error) {
      this.fault(String(error));
      rejectMtaHostRequest();
    } finally { PinDialogGuard.end(); }
  }
}
