import { util } from '@kit.ArkTS';

export type ProtocolKind = 'localsend' | 'quickshare' | 'windowsnearby' | 'catshare' | 'mta';
export type TransferState = 'pending' | 'awaiting-pin' | 'running' | 'completed' | 'failed' | 'rejected';
export type TransferDirection = 'send' | 'receive';
export type DiscoverySource = 'mdns' | 'ble' | 'lan' | 'manual';

export interface DeviceEndpoint {
  readonly id: string;
  readonly name: string;
  readonly model: string;
  readonly protocol: ProtocolKind;
  readonly address: string;
  readonly port: number;
  readonly https: boolean;
  readonly fingerprint: string;
  readonly source: DiscoverySource;
  readonly supports5Ghz?: boolean;
  readonly deviceType?: number;
  readonly capabilities?: string[];
  readonly sessionHint?: string;
}

export interface OutgoingFile {
  readonly path: string;
  readonly name: string;
  readonly size: number;
  readonly mime: string;
}

export interface IncomingFile {
  readonly name: string;
  readonly size: number;
  readonly savedPath: string;
  readonly mime?: string;
  /**
   * 应用沙箱内的原始落盘路径（若该文件随后被搬到下载目录，这里仍保留沙箱路径）。
   *
   * 动态图片需要在沙箱内读原文件字节：搬到下载目录后沙箱副本会被删除，而下载目录
   * 的路径应用没有读权限，届时既读不到内容也无法再解析。
   */
  readonly localPath?: string;
  /**
   * Quick Share 在协议收尾后需要由宿主处理图库或下载保存时为 true。
   * LocalSend 不需要该字段（其 staged hook 本身就在搬运前）。
   */
  readonly stagedForSave?: boolean;
}

/** 供网页端（局域网网页传输）下载的本机共享文件描述。 */
export interface WebShareInfo {
  readonly id: string;
  readonly name: string;
  readonly size: number;
}

export interface SessionFileMeta {
  readonly id: string;
  readonly name: string;
  readonly size: number;
  readonly mime?: string;
}

export interface ProtocolInfo {
  readonly label: string;
  readonly badgeColor: string;
}

export class Protocols {
  static info(kind: ProtocolKind): ProtocolInfo {
    switch (kind) {
      case 'localsend':
        return { label: 'LocalSend', badgeColor: '#22C55E' };
      case 'quickshare':
        return { label: 'Quick Share', badgeColor: '#38BDF8' };
      case 'windowsnearby':
        return { label: 'Windows Nearby', badgeColor: '#818CF8' };
      case 'catshare':
      case 'mta':
        return { label: '互传联盟', badgeColor: '#F59E0B' };
    }
    return { label: '设备', badgeColor: '#6B7280' };
  }
}

export class TransferTask {
  readonly id: string = util.generateRandomUUID();
  readonly createdAt: number = Date.now();
  state: TransferState = 'pending';
  progress: number = 0;
  error: string = '';
  pin: string = '';
  gateKey: string = '';
  receivedFiles: IncomingFile[] = [];
  /** 进入终态(completed/failed/rejected)的时间戳；用于聚合页在完成后短暂保留卡片。 */
  completedAt: number = 0;

  readonly device: DeviceEndpoint;
  readonly files: OutgoingFile[];
  readonly direction: TransferDirection;

  constructor(device: DeviceEndpoint, files: OutgoingFile[], direction: TransferDirection) {
    this.device = device;
    this.files = files;
    this.direction = direction;
  }
}

export type TransferEventKind = 'started' | 'progress' | 'pin-request' | 'pin-entry' | 'completed' | 'failed' | 'incoming';

export interface TransferEvent {
  readonly kind: TransferEventKind;
  readonly task: TransferTask;
}

export type TransferListener = (event: TransferEvent) => void;
