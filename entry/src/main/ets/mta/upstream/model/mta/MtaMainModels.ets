/**
 * MtaMainModels.ets — MTA 主流程模型与纯函数
 *
 * 仅包含主流程（发送页并入 MTA 设备、发起 MTA 发送）所需的数据视图类型、
 * 阶段文案与可单测纯函数（无系统 API 依赖），供 MtaRepository / SendViewModel /
 * MtaSendAdapter 共用。
 */

import { DiscoveredDevice, TransferFileDescriptor } from '../Types';
import { MtaDiscoveredDevice, MtaSenderStage } from './MtaSendModels';

// ── MTA 来源标识 ──

/** MTA 来源协议标识（用于发送路由分流与列表区分） */
export const MTA_PROTOCOL: string = 'mta';

/** 品牌未知时的回退徽标文案（附近设备列表与传输页设备卡共用） */
const MTA_UNKNOWN_BRAND: string = 'Android';

// ── 发送请求 ──

/** MTA 发送请求（发送页发起，适配器据此编排发送） */
export interface MtaSendRequest {
  /** 对端展示别名 */
  targetAlias: string
  /** 对端设备类型（图标映射） */
  deviceType: string
  /** 对端设备型号（无则空串） */
  deviceModel: string
  /** 品牌徽标文本（品牌名；品牌未知时为固定回退文案） */
  badgeText: string
  /** 目标 MTA 设备的 BLE 标识 */
  bleAddress: string
  /** 目标 MTA 设备的发送者 ID 十六进制 */
  senderIdHex: string
  /** 目标品牌 ID（-1 表示未知） */
  brandId: number
  /** 目标是否支持 5GHz */
  is5Ghz: boolean
  /** 目标信号强度（dBm） */
  rssi: number
  /** 待发送文件 URI 清单（文本发送时为空） */
  fileUris: Array<string>
  /** 待发送文件元数据清单（用于展示） */
  fileDescriptors: Array<TransferFileDescriptor>
  /** 是否以 MTA 原生文本方式发送 */
  isTextSend: boolean
  /** 文本内容（isTextSend 为 true 时有效） */
  textContent: string
  /** 文本发送时本地持久文本文件的路径（可缺省；供详情页按路径读取内容预览） */
  textFilePath?: string
}

/**
 * 构造发送请求（纯函数，供发送页发起与单测使用）。
 * 文本发送时 fileUris 传空数组，仅携带 textContent。
 */
export function buildMtaSendRequest(device: DiscoveredDevice, fileUris: Array<string>,
  fileDescriptors: Array<TransferFileDescriptor>, isTextSend: boolean, textContent: string): MtaSendRequest {
  let brandId: number = device.mtaBrandId !== undefined ? device.mtaBrandId : -1;
  let is5Ghz: boolean = device.mtaIs5Ghz !== undefined ? device.mtaIs5Ghz : false;
  let rssi: number = device.mtaRssi !== undefined ? device.mtaRssi : 0;
  return {
    targetAlias: device.alias,
    deviceType: device.deviceType,
    deviceModel: device.deviceModel,
    badgeText: mtaBrandBadgeText(device.mtaBrandName),
    bleAddress: device.mtaBleAddress !== undefined ? device.mtaBleAddress : device.fingerprint,
    senderIdHex: device.mtaSenderIdHex !== undefined ? device.mtaSenderIdHex : '',
    brandId: brandId,
    is5Ghz: is5Ghz,
    rssi: rssi,
    fileUris: fileUris,
    fileDescriptors: fileDescriptors,
    isTextSend: isTextSend,
    textContent: textContent
  };
}

/** 由发送请求还原 MTA 目标设备（供 MtaSendService 发起发送，可单测） */
export function mtaDeviceFromParams(params: MtaSendRequest): MtaDiscoveredDevice {
  let device = new MtaDiscoveredDevice();
  device.bleAddress = params.bleAddress;
  device.deviceName = params.targetAlias;
  device.senderIdHex = params.senderIdHex;
  device.brandId = params.brandId;
  device.brandName = params.badgeText;
  device.is5Ghz = params.is5Ghz;
  device.rssi = params.rssi;
  return device;
}

// ── 纯函数：MTA 设备 → 统一设备形状 ──

/**
 * 把 MTA 扫描发现的设备映射为统一 `DiscoveredDevice` 形状（纯函数）。
 * fingerprint 取 BLE 设备标识，protocol 固定为 'mta'，无 IP/端口/型号。
 */
export function mtaDeviceToDiscoveredDevice(device: MtaDiscoveredDevice, now: number): DiscoveredDevice {
  let alias = device.deviceName.length > 0 ? device.deviceName : device.bleAddress;
  return {
    alias: alias,
    ip: '',
    port: 0,
    fingerprint: device.bleAddress,
    version: '',
    deviceModel: '',
    deviceType: 'mobile',
    protocol: MTA_PROTOCOL,
    lastSeen: now,
    channels: [],
    mtaBleAddress: device.bleAddress,
    mtaSenderIdHex: device.senderIdHex,
    mtaBrandId: device.brandId,
    mtaBrandName: device.brandName,
    mtaIs5Ghz: device.is5Ghz,
    mtaRssi: device.rssi
  };
}

/** 是否 MTA 来源设备（用于列表变体与发送路由分流） */
export function isMtaDevice(device: DiscoveredDevice): boolean {
  return device.protocol === MTA_PROTOCOL;
}

/**
 * 品牌徽标文本：已知品牌返回品牌名，未知（'未知'/'未知(x)'/空/undefined）返回固定回退文案 `Android`。
 * 附近设备列表与传输页设备卡共用此函数，保证两处徽标文案一致。
 */
export function mtaBrandBadgeText(brandName: string | undefined): string {
  if (brandName === undefined || brandName.length === 0) {
    return MTA_UNKNOWN_BRAND;
  }
  if (brandName.startsWith('未知')) {
    return MTA_UNKNOWN_BRAND;
  }
  return brandName;
}

// ── 纯函数：文本内容提取 ──

/** 合并多段文本内容（去空行后以换行连接）；无有效内容返回空串 */
export function combineTextContents(contents: Array<string>): string {
  let parts: Array<string> = [];
  for (let i = 0; i < contents.length; i++) {
    if (contents[i].length > 0) {
      parts.push(contents[i]);
    }
  }
  return parts.join('\n');
}

// ── 纯函数：阶段文案（会话级展示） ──

/** 发送阶段 → 会话级展示文案（资源承载，随系统语言切换） */
export function mtaSendStageLabel(stage: MtaSenderStage): ResourceStr {
  switch (stage) {
    case MtaSenderStage.IDLE:
      return $r('app.string.mta_send_stage_idle');
    case MtaSenderStage.GATT_CONNECTING:
      return $r('app.string.mta_send_stage_gatt_connecting');
    case MtaSenderStage.WAITING_PEER_READY:
      return $r('app.string.mta_send_stage_waiting_peer_ready');
    case MtaSenderStage.GROUP_CREATING:
      return $r('app.string.mta_send_stage_group_creating');
    case MtaSenderStage.SERVER_STARTING:
      return $r('app.string.mta_send_stage_server_starting');
    case MtaSenderStage.P2P_INFO_WRITTEN:
      return $r('app.string.mta_send_stage_p2p_info_written');
    case MtaSenderStage.WAITING_WS:
      return $r('app.string.mta_send_stage_waiting_ws');
    case MtaSenderStage.NEGOTIATED:
      return $r('app.string.mta_send_stage_negotiated');
    case MtaSenderStage.WAITING_PEER_CONFIRM:
      return $r('app.string.mta_send_stage_waiting_peer_confirm');
    case MtaSenderStage.TRANSFERRING:
      return $r('app.string.mta_send_stage_transferring');
    case MtaSenderStage.COMPLETED:
      return $r('app.string.mta_send_stage_completed');
    case MtaSenderStage.PARTIAL:
      return $r('app.string.mta_send_stage_partial');
    case MtaSenderStage.REJECTED:
      return $r('app.string.mta_send_stage_rejected');
    case MtaSenderStage.FAILED:
      return $r('app.string.mta_send_stage_failed');
    case MtaSenderStage.CANCEL_NOTIFYING:
      return $r('app.string.mta_send_stage_cancel_notifying');
    case MtaSenderStage.CANCELLED:
      return $r('app.string.mta_send_stage_cancelled');
    default:
      return $r('app.string.mta_send_stage_unknown');
  }
}

/** 文本条目固定文件名 */
export const MTA_SHARED_TEXT_FILE_NAME: string = 'sharedText.txt';
