// 从 HandySend NativeBridge 提取 MTA 包装；宿主仅装配 MTA 原生库。
import {
  registerEventListener as nativeRegisterEventListener, cancelTransfer, pollDebugLog,
  nativeGetInterfaceMac as nativeGetInterfaceMacFn,
  nativeMtaFetchThumbnail as nativeMtaFetchThumbnailFn,
  nativeMtaStartServer as nativeMtaStartServerFn, nativeMtaStopServer as nativeMtaStopServerFn,
  nativeMtaRejectPeer as nativeMtaRejectPeerFn, nativeMtaReceiveDownload as nativeMtaReceiveDownloadFn
} from 'libmta_core.so';
import { NativeEvent, NativeMtaServerConfig, parseNativeEvent } from '../model/NativeTypes';
import { readJsonField } from '../utils/JsonGuard';
import { getLogger } from '../utils/Logger';
const logger = getLogger(6, 'MTA:NativeBridge', 'MTA');
const nativeEventHandlers: Map<string, Array<(event: NativeEvent) => void>> = new Map();

// NAPI 事件回调是否已注册
let nativeEventListenerRegistered = false;

/**
 * 订阅桥接层事件。
 * @param eventType 事件类型（如 'prepareUpload' / 'sessionEnd' / 'deviceFound'）
 * @param handler 事件处理器，接收类型化事件对象
 */
export function onBridgeEvent(eventType: string, handler: (event: NativeEvent) => void): void {
  let list = nativeEventHandlers.get(eventType);
  if (list === undefined) {
    list = [];
    nativeEventHandlers.set(eventType, list);
  }
  list.push(handler);
  ensureNativeEventListener();
}

/**
 * 取消订阅桥接层事件。
 * @param eventType 事件类型
 * @param handler 之前注册的处理器
 */
export function offBridgeEvent(eventType: string, handler: (event: NativeEvent) => void): void {
  let list = nativeEventHandlers.get(eventType);
  if (list !== undefined) {
    let idx = list.indexOf(handler);
    if (idx >= 0) {
      list.splice(idx, 1);
    }
  }
}

/**
 * 惰性注册 NAPI 事件回调（首次订阅时）。
 * 收到 Rust 事件 JSON（{"type":"...","payload":{...}}）后解析并按类型分发。
 */
function ensureNativeEventListener(): void {
  if (nativeEventListenerRegistered) {
    return;
  }
  nativeRegisterEventListener((err: Error | null, eventJson: string) => {
    if (err !== null) {
      logger.error('原生事件回调异常: ' + String(err));
      return;
    }
    dispatchNativeEvent(eventJson);
  });
  nativeEventListenerRegistered = true;
}

/**
 * 解析并分发一个原生事件 JSON 到订阅者。
 */
function dispatchNativeEvent(eventJson: string): void {
  let event: NativeEvent | undefined = parseNativeEvent(eventJson);
  if (event === undefined) {
    return;
  }
  let list = nativeEventHandlers.get(event.type);
  if (list === undefined) {
    return;
  }
  // 拷贝列表，避免处理器内部订阅/退订影响遍历
  let snapshot: Array<(event: NativeEvent) => void> = [];
  for (let i = 0; i < list.length; i++) {
    snapshot.push(list[i]);
  }
  for (let j = 0; j < snapshot.length; j++) {
    try {
      snapshot[j](event);
    } catch (e) {
      logger.error('原生事件处理异常: ' + String(e));
    }
  }
}


export function nativeCancelTransferLocal(sessionId: string): void {
  cancelTransfer(sessionId);
}

export function nativePollDebugLogWithLevels(): Array<string> {
  return pollDebugLog();
}

export function nativeGetInterfaceMac(interfaceName: string): string {
  try {
    return nativeGetInterfaceMacFn(interfaceName);
  } catch (e) {
    return '';
  }
}

export async function nativeMtaFetchThumbnail(goIp: string, port: number, taskId: string,
  targetDir: string, maxBytes: number): Promise<string> {
  ensureNativeEventListener();
  try {
    return await nativeMtaFetchThumbnailFn(goIp, port, taskId, targetDir, undefined, maxBytes);
  } catch (e) {
    return '';
  }
}

export async function nativeMtaStartServer(config: NativeMtaServerConfig): Promise<number> {
  ensureNativeEventListener();
  let resultJson: string = await nativeMtaStartServerFn(JSON.stringify(config));
  let parsed: Object = JSON.parse(resultJson);
  let portValue: Object | undefined = readJsonField(parsed, 'port');
  return typeof portValue === 'number' ? portValue : 0;
}

export async function nativeMtaStopServer(): Promise<void> {
  nativeMtaStopServerFn();
}

export function nativeMtaRejectPeer(): void {
  nativeMtaRejectPeerFn();
}

export async function nativeMtaReceiveDownload(goIp: string, port: number, taskId: string,
  targetDir: string, totalBytes: number, maxEntries: number, maxTotalBytes: number,
  maxEntryBytes: number, cancelTokenId?: string, connectTimeoutMs?: number,
  stallTimeoutMs?: number, headerTimeoutMs?: number): Promise<string> {
  ensureNativeEventListener();
  return await nativeMtaReceiveDownloadFn(goIp, port, taskId, targetDir, totalBytes, maxEntries,
    maxTotalBytes, maxEntryBytes, cancelTokenId, connectTimeoutMs, stallTimeoutMs, headerTimeoutMs);
}
