/**
 * MtaBleCommon.ets — MTA 收发两端共用辅助
 *
 * 集中接收端与发送端重复的逻辑：字节/文本转换纯函数、延时辅助、
 * Rust 日志排空，以及蓝牙权限、开关查询，避免两份实现漂移。
 */

import { access, constant } from '@kit.ConnectivityKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { errorText } from '../../utils/FormatUtil';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { parseRustLogLine } from '../../model/mta/MtaSendModels';
import {
  MtaBluetoothObservation,
  MtaBluetoothStatus,
  mapMtaBluetoothObservation
} from '../../model/mta/MtaDiscoveryModels';
import { nativePollDebugLogWithLevels } from '../NativeBridge';
import { requestBluetoothPermission } from '../PermissionService';
import { preferencesRepo } from '../repository/PreferencesRepo';
import { MtaConstants } from './MtaConstants';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaBleCommon', '互传BLE');

/**
 * 注册蓝牙开关事件并返回回调引用（反注册时必须按引用精确移除：
 * 无参 access.off('stateChange') 会移除所有监听者，误伤收发另一端）。
 * 注册失败返回 undefined。
 */
export function registerBluetoothStateEvent(
  onStateChange: (stateText: string) => void
): ((state: access.BluetoothState) => void) | undefined {
  try {
    let callback = (state: access.BluetoothState): void => {
      onStateChange(bluetoothStateText(state));
    };
    access.on('stateChange', callback);
    return callback;
  } catch (e) {
    logger.warn('stateChange 注册失败: ' + errorText(e));
    return undefined;
  }
}

/** 按引用反注册蓝牙开关事件（仅移除传入的回调；未注册时无操作） */
export function unregisterBluetoothStateEvent(
  callback: ((state: access.BluetoothState) => void) | undefined
): void {
  if (callback === undefined) {
    return;
  }
  try {
    access.off('stateChange', callback);
  } catch (e) {
    logger.warn('stateChange 反注册失败: ' + errorText(e));
  }
}

/** 复制 Uint8Array 到独立 ArrayBuffer（BLE API 要求 ArrayBuffer 入参） */
export function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  let buffer = new ArrayBuffer(bytes.length);
  let view = new Uint8Array(buffer);
  view.set(bytes, 0);
  return buffer;
}

/** 计算 UTF-8 文本字节数（代理对按 4 字节计） */
export function utf8ByteLength(text: string): number {
  let bytes = 0;
  for (let i = 0; i < text.length; i++) {
    let code = text.charCodeAt(i);
    if (code < 0x80) {
      bytes += 1;
    } else if (code < 0x800) {
      bytes += 2;
    } else if (code >= 0xd800 && code <= 0xdbff) {
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

/** 延时辅助（Promise 定时） */
export function sleepMs(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/**
 * 排空 Rust 日志缓冲并追加 MTA 相关行（解析 `level|message` 前缀，按原始级别展示）。
 * appendLog 为服务侧日志追加入口，onWarn 在轮询失败时上报。
 */
export function drainRustLog(appendLog: (source: string, message: string, level: string) => void,
  onWarn: (message: string) => void): void {
  try {
    let lines = nativePollDebugLogWithLevels();
    for (let i = 0; i < lines.length; i++) {
      let parsed = parseRustLogLine(lines[i]);
      if (parsed.message.includes('MTA')) {
        appendLog('Rust', parsed.message, parsed.level);
      }
    }
  } catch (e) {
    onWarn('轮询 Rust 日志失败: ' + String(e));
  }
}

/** 蓝牙开关状态枚举 → 文本 */
export function bluetoothStateText(state: access.BluetoothState): string {
  switch (state) {
    case access.BluetoothState.STATE_OFF:
      return '关闭';
    case access.BluetoothState.STATE_TURNING_ON:
      return '正在开启';
    case access.BluetoothState.STATE_ON:
      return '开启';
    case access.BluetoothState.STATE_TURNING_OFF:
      return '正在关闭';
    case access.BluetoothState.STATE_BLE_TURNING_ON:
      return 'BLE 正在开启';
    case access.BluetoothState.STATE_BLE_ON:
      return 'BLE 模式';
    case access.BluetoothState.STATE_BLE_TURNING_OFF:
      return 'BLE 正在关闭';
    default:
      return '未知';
  }
}

/** GATT 连接状态枚举 → 文本 */
export function profileStateText(state: constant.ProfileConnectionState): string {
  switch (state) {
    case constant.ProfileConnectionState.STATE_DISCONNECTED:
      return '已断开';
    case constant.ProfileConnectionState.STATE_CONNECTING:
      return '连接中';
    case constant.ProfileConnectionState.STATE_CONNECTED:
      return '已连接';
    case constant.ProfileConnectionState.STATE_DISCONNECTING:
      return '断开中';
    default:
      return '未知';
  }
}

/** UTF-8 字节数组解码为文本（容错非法序列） */
export function decodeUtf8(bytes: Uint8Array): string {
  try {
    return new util.TextDecoder().decodeToString(bytes);
  } catch (e) {
    return '';
  }
}

/**
 * 扫描响应名称区实际承载的广播名称：编码后不超过 16 字节时原样返回，
 * 超出时截到 15 字节以内的字符边界（末字节留给 \t 截断标记）。
 */
export function mtaBroadcastName(deviceName: string): string {
  // TextEncoder.encodeInto 对空字符串返回 undefined
  if (deviceName.length === 0) {
    return '';
  }
  let encoded = new util.TextEncoder().encodeInto(deviceName);
  if (encoded.length <= MtaConstants.DEVICE_NAME_MAX_BYTES) {
    return deviceName;
  }
  let take = MtaConstants.DEVICE_NAME_MAX_BYTES - 1;
  // 截断处落在 UTF-8 续字节（0b10xxxxxx）上则回退，避免产生半个字符
  while (take > 0 && (encoded[take] & 0xc0) === 0x80) {
    take--;
  }
  return decodeUtf8(encoded.slice(0, take));
}

/**
 * 运行时申请 ACCESS_BLUETOOTH 权限，返回是否授予。
 * 经 PermissionService 串行链统一申请，避免与启动阶段的通知权限弹窗冲突。
 */
export function ensureBluetoothPermission(context: common.Context): Promise<boolean> {
  return requestBluetoothPermission(context);
}

/** 查询蓝牙开关状态文本 */
export function queryBluetoothStateText(): string {
  try {
    return bluetoothStateText(access.getState());
  } catch (e) {
    return '查询失败';
  }
}

/** 蓝牙是否已开启 */
export function isBluetoothEnabled(): boolean {
  try {
    let state = access.getState();
    return state === access.BluetoothState.STATE_ON || state === access.BluetoothState.STATE_BLE_ON;
  } catch (e) {
    return false;
  }
}

/**
 * 观测本机蓝牙开关状态：把系统原始状态收敛为「明确开启/明确关闭/中间态/查询失败」四类。
 * 正在开启、正在关闭等中间态与查询异常都归为「查询失败/不可判定」一侧，不并入明确关闭。
 */
export function observeMtaBluetoothState(): MtaBluetoothObservation {
  try {
    let state = access.getState();
    if (state === access.BluetoothState.STATE_ON || state === access.BluetoothState.STATE_BLE_ON) {
      return MtaBluetoothObservation.ON;
    }
    if (state === access.BluetoothState.STATE_OFF) {
      return MtaBluetoothObservation.OFF;
    }
    return MtaBluetoothObservation.TRANSITIONAL;
  } catch (e) {
    return MtaBluetoothObservation.UNAVAILABLE;
  }
}

/**
 * 查询蓝牙开关三态（已开启 / 已关闭 / 不可确定）。
 * 查询异常与中间态一律返回「不可确定」，不得折叠为「已关闭」——状态不可得不能等同于关闭。
 * 既有 isBluetoothEnabled 保留原二值语义，供不区分「不可得」的旧调用方使用。
 */
export function queryMtaBluetoothStatus(): MtaBluetoothStatus {
  return mapMtaBluetoothObservation(observeMtaBluetoothState());
}

/** 弹系统对话框开启蓝牙 */
export function enableBluetoothSystem(): void {
  access.enableBluetooth();
}

/** 本机 MTA 设备 ID（16 字节十六进制）的 Preferences 键 */
const KEY_MTA_DEVICE_ID: string = 'mtaDeviceId';

/** 设备 ID 十六进制是否可用（须为 16 字节 = 32 个十六进制字符） */
export function isValidMtaDeviceIdHex(hex: string): boolean {
  if (hex.length !== MtaConstants.SENDER_ID_LENGTH * 2) {
    return false;
  }
  for (let i = 0; i < hex.length; i++) {
    let c = hex.charCodeAt(i);
    let isDigit = c >= 0x30 && c <= 0x39;
    let isLower = c >= 0x61 && c <= 0x66;
    let isUpper = c >= 0x41 && c <= 0x46;
    if (!isDigit && !isLower && !isUpper) {
      return false;
    }
  }
  return true;
}

/** 字节数组 → 小写十六进制文本 */
function bytesToLowerHex(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    let h = bytes[i].toString(16);
    out += h.length === 1 ? '0' + h : h;
  }
  return out;
}

/**
 * 取本机 MTA 设备 ID 十六进制（32 字符）；首次调用生成 16 字节随机并持久化，之后各会话复用。
 *
 * 对齐厂商行为：真机实测小米（Redmi）的设备 ID 跨会话稳定，第三方 EasyShare 则不稳定——稳定性是
 * 厂商实现选择。本机选择持久化（与小米一致），使对端把我们在各会话间视为同一台设备；该 ID 同时用于
 * 接收广播与发送侧标识，保证对外身份一致。
 */
export function loadOrCreateMtaDeviceIdHex(): string {
  let existing = preferencesRepo.getString(KEY_MTA_DEVICE_ID, '');
  if (isValidMtaDeviceIdHex(existing)) {
    return existing.toLowerCase();
  }
  let bytes = new Uint8Array(MtaConstants.SENDER_ID_LENGTH);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = Math.floor(Math.random() * 256);
  }
  let hex = bytesToLowerHex(bytes);
  preferencesRepo.setString(KEY_MTA_DEVICE_ID, hex);
  return hex;
}
