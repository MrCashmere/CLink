// 羊绒互传修改：系统扫描使用独立租约，避免其它协议启停时移除本协议回调。
import { SharedBleScanLease } from '../../../../common/SharedBleScan';
/**
 * MtaBleClient.ets — MTA 发送端 BLE 客户端
 *
 * 发送端在 MTA 协议中承担 BLE 扫描 + GATT Client 角色：
 * - 按 MTA 主广播 serviceUuid 过滤扫描接收端广播，解析扫描响应中的发送者 ID / 设备名
 *   与品牌 UUID 中的 5GHz 标识 / 品牌 ID，按 deviceId 去重并按 RSSI 变化限流上报；
 * - 作为 GATT Client 连接对端 GATT Server，读 CHAR_STATUS 取 DeviceInfo，写 CHAR_P2P 回 P2pInfo。
 * 本服务只采集/转发数据，不持有页面状态；错误统一文本化上抛。
 */

import { ble, access, constant } from '@kit.ConnectivityKit';
import { util } from '@kit.ArkTS';
import { DeviceInfoJson, bytesToHex, parseDeviceInfo } from '../../model/mta/MtaProtocolModels';
import {
  MtaAdvParseResult,
  MtaBleClientEventHandlers,
  MtaDeviceIdentityMemo,
  MtaDiscoveredDevice,
  formatMtaP2pWriteDiagnostic,
  parseMtaAdvServiceData,
  resolveMtaP2pWriteModeText,
  stabilizeMtaAdvIdentity
} from '../../model/mta/MtaSendModels';
import { MtaConstants } from './MtaConstants';
import {
  decodeUtf8,
  profileStateText,
  registerBluetoothStateEvent,
  sleepMs,
  toArrayBuffer,
  unregisterBluetoothStateEvent
} from './MtaBleCommon';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { errorText } from '../../utils/FormatUtil';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaBleClient', '互传蓝牙');

/** 扫描解析签名映射的条目上限（有界，超出即清空以限制内存与日志量） */
const SCAN_SIGNATURE_MAX_ENTRIES: number = 512;

/**
 * 扫描上报心跳间隔（毫秒）：RSSI 未变化时也按此间隔补一次上报。
 * 上层按「最近一次上报时刻」判定设备存活（TTL 30s），若仅在 RSSI 变化时上报，
 * RSSI 恒定的设备会停止刷新存活时刻而被误判离线，故需心跳；取值须明显小于上层 TTL。
 */
const SCAN_REPORT_HEARTBEAT_MS: number = 10000;

/** 设备上报时刻表条目上限（有界，超出即清空以限制内存） */
const SCAN_REPORT_TIME_MAX_ENTRIES: number = 512;

/** 设备身份记忆表条目上限（有界，超出即清空以限制内存） */
const SCAN_IDENTITY_MAX_ENTRIES: number = 512;

/**
 * 判定某次连接尝试是否需要重扫对端地址（纯函数，「先用后扫」）：
 * 优先使用点击时记录的广播地址直连；仅当记录地址为空、或已进入失败重试（尝试次数 > 1）时才重扫。
 * 成功路径不引入固定重扫等待，失败路径仍保留对「地址高频轮换机型」的重扫回退。
 */
export function shouldRescanPeerAddress(recordedAddress: string, attempt: number): boolean {
  return recordedAddress.trim().length === 0 || attempt > 1;
}

/** 单条扫描结果的解析诊断产物：设备视图 + 原始广播 + 异常 + 去重签名 */
class ScanParseResult {
  /** 解析出的设备视图 */
  device: MtaDiscoveredDevice = new MtaDiscoveredDevice();
  /** 5GHz 标记原始字节值（主广播解析；-1 表示未解析到） */
  is5GhzFlagByte: number = -1;
  /** 支持 5GHz 的判定依据（按标记字节最低有效位 bit0） */
  is5GhzBasis: string = '';
  /** 原始 serviceData 描述（`UUID=字节hex`，多个以逗号连接） */
  rawServiceData: string = '';
  /** 厂商数据描述（`公司ID=字节hex`，多个以逗号连接；无则为“无”） */
  rawManufacturerData: string = '';
  /** 广播携带的 service UUID 列表（逗号连接；无则为“无”） */
  advServiceUuids: string = '';
  /** 原始广播报文 hex（含全部 AD 结构，含本实现未解析的元素） */
  rawPacketHex: string = '';
  /** 异常描述（空表示未发现异常） */
  abnormal: string = '';
  /** 解析签名（含原始字节与解析字段，不含 RSSI，用于日志去重） */
  signature: string = '';
}

/**
 * 解码扫描响应中的设备名字段。
 * 按对端实现的口径：名称区以**首个 0x00** 为终止（其后为填充）；名称被截断时末字节为
 * \t 标记，二者都在解码前剔除，再按 UTF-8 解码（非法序列按容错处理，不因此丢弃设备）。
 */
function decodeNameField(bytes: Uint8Array): string {
  let end = bytes.length;
  for (let i = 0; i < bytes.length; i++) {
    if (bytes[i] === MtaConstants.NAME_FIELD_PAD_BYTE) {
      end = i;
      break;
    }
  }
  if (end > 0 && bytes[end - 1] === MtaConstants.NAME_FIELD_TRUNCATION_MARK) {
    end--;
  }
  return decodeUtf8(bytes.slice(0, end));
}

/** MTA 发送端 BLE 客户端 */
export class MtaBleClient {
  private scanLease: SharedBleScanLease = new SharedBleScanLease();
  /** 事件回调集合（服务注入） */
  private handlers: MtaBleClientEventHandlers | null = null;
  // ── 扫描 ──
  /** 是否扫描中 */
  private scanning: boolean = false;
  /** 已发现设备按 deviceId 去重（值为最近一次 RSSI） */
  private scanDeviceRssi: Map<string, number> = new Map();
  /** 已上报设备的最近上报时刻（deviceId → 毫秒），用于心跳补报；与 scanDeviceRssi 同步维护 */
  private scanDeviceReportMs: Map<string, number> = new Map();
  /** 已记录解析签名的设备（deviceId → 签名），用于诊断日志去重；与 scanDeviceRssi 分离 */
  private scanDeviceSignature: Map<string, string> = new Map();
  /**
   * 设备身份记忆（deviceId → 已见最完整的身份/品牌/名称/5GHz）：
   * 主广播段与扫描响应段可能分次到达，据此跨回调稳定同一设备的身份与能力，
   * 避免上层把同一设备当作新设备（列表出现多个条目、徽标在条目间跳变）。
   */
  private scanDeviceIdentity: Map<string, MtaDeviceIdentityMemo> = new Map();
  // ── GATT Client ──
  /** GATT Client 实例 */
  private gattClient: ble.GattClientDevice | null = null;
  /** GATT Client 目标设备标识 */
  private gattClientTarget: string = '';
  /** GATT Client 是否已连接 */
  private gattClientConnected: boolean = false;
  /** 协商后的 MTU（0 表示尚未协商，未协商时为默认 23 字节） */
  private negotiatedMtu: number = 0;
  /** 最近一次读取到的对端 DeviceInfo 原始文本（供写回后复读比对；未读取时为空串） */
  private lastDeviceInfoRawText: string = '';
  // ── 事件注册 / 反注册 ──

  /**
   * 已注册的蓝牙开关回调引用：反注册时必须按引用精确移除。
   * 无参 access.off('stateChange') 会移除所有监听者（含接收端实例），
   * 导致对端再也收不到蓝牙开关事件。
   */
  private stateChangeCallback: ((state: access.BluetoothState) => void) | undefined = undefined;

  /** 注册蓝牙开关事件；重复注册时先反注册旧回调 */
  registerEvents(handlers: MtaBleClientEventHandlers): void {
    this.unregisterEvents();
    this.handlers = handlers;
    this.stateChangeCallback = registerBluetoothStateEvent((stateText: string): void => {
      if (this.handlers !== null) {
        this.handlers.onBluetoothStateChange(stateText);
      }
    });
  }

  /** 反注册蓝牙开关事件（仅移除本实例的回调） */
  unregisterEvents(): void {
    unregisterBluetoothStateEvent(this.stateChangeCallback);
    this.stateChangeCallback = undefined;
    this.handlers = null;
  }

  // ── 扫描 ──

  /** 启动 BLE 扫描：按 MTA 主广播 serviceUuid 过滤，均衡功耗（扫描期间常驻）+ 激进匹配 */
  startScan(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (this.scanning) {
        resolve();
        return;
      }
      try {
        let filter: ble.ScanFilter = { serviceUuid: MtaConstants.ADV_SERVICE_UUID };
        let filters: Array<ble.ScanFilter> = [filter];
        let options: ble.ScanOptions = {
          dutyMode: ble.ScanDuty.SCAN_MODE_BALANCED,
          matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE
        };
        this.scanLease.on('BLEDeviceFind', (results: Array<ble.ScanResult>) => {
          this.handleScanResults(results);
        });
        this.scanLease.start(filters, options);
        this.scanDeviceRssi = new Map();
        this.scanDeviceReportMs = new Map();
        this.scanDeviceSignature = new Map();
        this.scanDeviceIdentity = new Map();
        this.scanning = true;
        if (this.handlers !== null) {
          this.handlers.onScanStateChange(true, '扫描已启动');
        }
        resolve();
      } catch (e) {
        // 失败回滚：反注册可能已注册的 BLEDeviceFind 监听，避免失败重试累积监听器
        this.scanning = false;
        try {
          this.scanLease.off('BLEDeviceFind');
        } catch (_e) {
          // 忽略清理异常，不覆盖原始起扫错误
        }
        reject(errorText(e));
      }
    });
  }

  /** 停止 BLE 扫描并反注册回调 */
  stopScan(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (!this.scanning) {
        resolve();
        return;
      }
      try {
        this.scanLease.stop();
        this.scanLease.off('BLEDeviceFind');
        this.scanning = false;
        if (this.handlers !== null) {
          this.handlers.onScanStateChange(false, '扫描已停止');
        }
        resolve();
      } catch (e) {
        reject(errorText(e));
      }
    });
  }

  /** 批量处理扫描结果：RSSI 变化或到达上报心跳间隔时上报（相同 RSSI 的重复结果不重报） */
  private handleScanResults(results: Array<ble.ScanResult>): void {
    for (let i = 0; i < results.length; i++) {
      let parsed = this.parseScanResult(results[i]);
      let device = parsed.device;
      let prevRssi = this.scanDeviceRssi.get(device.bleAddress);
      let lastReportMs = this.scanDeviceReportMs.get(device.bleAddress);
      let nowMs = Date.now();
      // 心跳补报：RSSI 未变化也按间隔上报一次，保证上层设备存活时刻持续刷新（不被 TTL 误剔除）
      let rssiChanged = prevRssi === undefined || prevRssi !== device.rssi;
      let heartbeatDue = lastReportMs === undefined || nowMs - lastReportMs >= SCAN_REPORT_HEARTBEAT_MS;
      if (rssiChanged || heartbeatDue) {
        this.scanDeviceRssi.set(device.bleAddress, device.rssi);
        this.rememberReportTime(device.bleAddress, nowMs);
        if (this.handlers !== null) {
          this.handlers.onDeviceFound(device);
        }
      }
      // 日志去重独立于上报去重：仅设备首见或解析签名变化时记录，RSSI 抖动不重记
      let prevSignature = this.scanDeviceSignature.get(device.bleAddress);
      if (prevSignature === undefined || prevSignature !== parsed.signature) {
        this.recordScanSignature(device.bleAddress, parsed.signature);
        this.logScanDiagnostics(parsed);
      }
    }
  }

  /** 记录设备最近一次上报时刻（有界：超出上限且为新设备时清空重记） */
  private rememberReportTime(deviceId: string, nowMs: number): void {
    if (this.scanDeviceReportMs.size >= SCAN_REPORT_TIME_MAX_ENTRIES && !this.scanDeviceReportMs.has(deviceId)) {
      this.scanDeviceReportMs.clear();
    }
    this.scanDeviceReportMs.set(deviceId, nowMs);
  }

  /**
   * 重置上报去重状态：使当前仍在广播的设备在下一轮扫描结果中全部重新上报。
   * 供「用户主动刷新」使用——无需停/起扫描（无射频空档、不清空列表）即可让上层重新收集到新鲜数据。
   */
  resetReportDedupe(): void {
    this.scanDeviceRssi.clear();
    this.scanDeviceReportMs.clear();
  }

  /** 记录设备解析签名（有界：超出上限且为新设备时清空重记） */
  private recordScanSignature(deviceId: string, signature: string): void {
    if (this.scanDeviceSignature.size >= SCAN_SIGNATURE_MAX_ENTRIES && !this.scanDeviceSignature.has(deviceId)) {
      this.scanDeviceSignature.clear();
    }
    this.scanDeviceSignature.set(deviceId, signature);
  }

  /** 输出单条广播的诊断日志：解析结果、serviceData、厂商数据/服务 UUID/原始报文，异常单独记录 */
  private logScanDiagnostics(parsed: ScanParseResult): void {
    let device = parsed.device;
    // 5GHz 标记原始字节单独输出，与判定依据并列，便于核对「原值—判定」是否一致
    let flagText = '不可得';
    if (parsed.is5GhzFlagByte >= 0) {
      let hex = parsed.is5GhzFlagByte.toString(16);
      flagText = `0x${hex.length < 2 ? '0' + hex : hex}`;
    }
    logger.debug(`广播解析 deviceId=${device.bleAddress} name=${device.deviceName}` +
      ` brandId=${device.brandId} brand=${device.brandName} is5Ghz=${device.is5Ghz}` +
      ` 5GHz标记=${flagText} 判定依据=${parsed.is5GhzBasis}` +
      ` senderId=${device.senderIdHex} rssi=${device.rssi} raw=[${parsed.rawServiceData}]` +
      ` mfg=[${parsed.rawManufacturerData}] uuids=[${parsed.advServiceUuids}] adv=[${parsed.rawPacketHex}]`);
    if (parsed.abnormal.length > 0) {
      logger.debug(`广播解析异常 deviceId=${device.bleAddress} rssi=${device.rssi} ${parsed.abnormal}`);
    }
  }

  /** 取（或按需创建）某地址的设备身份记忆；表满且为新地址时清空以限制内存 */
  private identityMemoFor(deviceId: string): MtaDeviceIdentityMemo {
    let memo = this.scanDeviceIdentity.get(deviceId);
    if (memo === undefined) {
      if (this.scanDeviceIdentity.size >= SCAN_IDENTITY_MAX_ENTRIES) {
        this.scanDeviceIdentity.clear();
      }
      memo = new MtaDeviceIdentityMemo();
      this.scanDeviceIdentity.set(deviceId, memo);
    }
    return memo;
  }

  /** 解析单条扫描结果：MTA serviceData 按值长度分类解析设备名/发送者 ID/品牌/5GHz，并采集原始广播与异常 */
  private parseScanResult(result: ble.ScanResult): ScanParseResult {
    let parsed = new ScanParseResult();
    let device = parsed.device;
    device.bleAddress = result.deviceId;
    device.deviceName = result.deviceName;
    device.rssi = result.rssi;

    let anomalies: Array<string> = [];
    let map = result.serviceDataMap;
    let adv: MtaAdvParseResult;
    if (map === undefined) {
      adv = new MtaAdvParseResult();
      anomalies.push('serviceDataMap 缺失');
    } else {
      adv = parseMtaAdvServiceData(map);
    }
    // 跨回调稳定身份：分次到达时用已见值补齐本次缺失的身份/品牌/名称/5GHz，
    // 使同一设备始终映射到同一身份（否则列表会出现两个条目、徽标在两者间跳变）
    stabilizeMtaAdvIdentity(this.identityMemoFor(device.bleAddress), adv);
    device.senderIdHex = adv.senderIdHex;
    device.brandId = adv.brandId;
    device.brandName = adv.brandName;
    device.is5Ghz = adv.is5Ghz;
    parsed.is5GhzFlagByte = adv.is5GhzFlagByte;
    parsed.is5GhzBasis = adv.is5GhzBasis;
    // 扫描响应携带名字字段时覆盖系统设备名；字段解析为空则保留系统名
    if (adv.nameBytes.length > 0) {
      let parsedName = decodeNameField(adv.nameBytes);
      if (parsedName.length > 0) {
        device.deviceName = parsedName;
      } else {
        anomalies.push('扫描响应设备名字段解析为空');
      }
    }

    parsed.rawServiceData = adv.rawServiceData;
    // 厂商数据 / 服务 UUID / 原始报文：品牌与能力判定可能依赖 serviceData 之外的元素
    //（对照实现会构造并读取厂商数据侧的能力包），故一并采集；原始报文含全部 AD 结构，
    // 便于与可被识别的对端做字节级比对
    let mfgParts: Array<string> = [];
    let mfgMap = result.manufacturerDataMap;
    if (mfgMap !== undefined) {
      mfgMap.forEach((value: Uint8Array, id: number): void => {
        mfgParts.push(`${id}=${bytesToHex(value)}`);
      });
    }
    parsed.rawManufacturerData = mfgParts.length > 0 ? mfgParts.join(', ') : '无';
    let uuidList: Array<string> = result.serviceUuids !== undefined ? result.serviceUuids : [];
    parsed.advServiceUuids = uuidList.length > 0 ? uuidList.join(', ') : '无';
    parsed.rawPacketHex = bytesToHex(new Uint8Array(result.data));
    parsed.abnormal = adv.anomalies.concat(anomalies).join('; ');
    // 签名覆盖原始 serviceData、厂商数据与解析字段（不含 RSSI），用于日志去重
    parsed.signature =
      `${parsed.rawServiceData}|mfg=${parsed.rawManufacturerData}|name=${device.deviceName}` +
        `|brandId=${device.brandId}|is5Ghz=${device.is5Ghz}` +
        `|senderId=${device.senderIdHex}|abnormal=${parsed.abnormal}`;
    return parsed;
  }

  // ── GATT Client ──

  /** 连接对端 GATT Server：创建 Client → 订阅连接状态事件 → connect */
  connectGattClient(deviceId: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (this.gattClient !== null) {
        reject('已存在 GATT Client 连接，请先断开');
        return;
      }
      let client: ble.GattClientDevice | null = null;
      try {
        client = ble.createGattClientDevice(deviceId);
        const c: ble.GattClientDevice = client;
        this.gattClient = c;
        this.gattClientTarget = deviceId;
        this.gattClientConnected = false;
        this.negotiatedMtu = 0;
        this.lastDeviceInfoRawText = '';
        c.on('BLEConnectionStateChange', (state: ble.BLEConnectionChangeState) => {
          if (state.state === constant.ProfileConnectionState.STATE_CONNECTED) {
            this.gattClientConnected = true;
          } else if (state.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
            this.gattClientConnected = false;
          }
          if (this.handlers !== null) {
            this.handlers.onGattConnectionChange(profileStateText(state.state));
          }
        });
        c.on('BLEMtuChange', (mtu: number) => {
          this.negotiatedMtu = mtu;
          if (this.handlers !== null) {
            this.handlers.onMtuChange(mtu);
          }
        });
        c.connect();
        resolve();
      } catch (e) {
        // 连接中途失败时复位状态并释放 GATT Client，避免句柄泄漏后
        // 残留的 gattClient 阻断后续重连
        this.gattClient = null;
        this.gattClientTarget = '';
        this.gattClientConnected = false;
        this.negotiatedMtu = 0;
        if (client !== null) {
          try {
            client.close();
          } catch (closeErr) {
            logger.warn('GATT Client 关闭失败: ' + errorText(closeErr));
          }
        }
        reject(errorText(e));
      }
    });
  }

  /** 等待 GATT 连接就绪：先立即检查，随后轮询兜底，超时返回 false */
  async waitGattConnected(timeoutMs: number): Promise<boolean> {
    if (this.gattClientConnected) {
      return true;
    }
    let waited = 0;
    while (waited < timeoutMs) {
      await this.sleepMs(MtaConstants.GATT_CONNECT_POLL_MS);
      waited += MtaConstants.GATT_CONNECT_POLL_MS;
      if (this.gattClientConnected) {
        return true;
      }
    }
    // 超时边界补一次判定：连接事件常恰好在超时附近到达，直接返回 false 会让上层拆掉刚建立的
    // 链路，反而触发一次完整重连（实测第 1 次判定超时后约 40ms 即连上）
    await this.sleepMs(MtaConstants.GATT_CONNECT_FINAL_GRACE_MS);
    return this.gattClientConnected;
  }

  /**
   * 按 senderId 短扫以取回目标设备的当前广播地址。
   *
   * 部分对端（如部分中兴/小米机型）的 BLE 广播地址高频轮换，扫描时记录的地址在点击发送时
   * 往往已失效，直接连接会超时；连接前重扫可拿到当前地址。命中即停扫返回地址，超时未命中返回 null。
   */
  resolveFreshAddress(senderIdHex: string, timeoutMs: number): Promise<string | null> {
    return new Promise<string | null>((resolve: (value: string | null) => void) => {
      let target = senderIdHex.trim().toLowerCase();
      if (target.length === 0) {
        resolve(null);
        return;
      }
      let settled = false;
      let timerId = -1;
      // 结算：停扫、反注册并返回结果（幂等）
      let settle = (address: string | null): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timerId);
        try {
          // 发送期间仅本处扫描，移除该事件全部监听即可
          this.scanLease.off('BLEDeviceFind');
        } catch (e) {
          logger.warn('重扫反注册失败: ' + errorText(e));
        }
        try {
          this.scanLease.stop();
        } catch (e) {
          // 未在扫描时停止会抛错，忽略
        }
        resolve(address);
      };
      let finder = (results: Array<ble.ScanResult>): void => {
        for (let i = 0; i < results.length; i++) {
          let parsed = this.parseScanResult(results[i]);
          if (parsed.device.senderIdHex.trim().toLowerCase() === target) {
            settle(parsed.device.bleAddress);
            return;
          }
        }
      };
      timerId = setTimeout((): void => {
        settle(null);
      }, timeoutMs);
      try {
        let filter: ble.ScanFilter = { serviceUuid: MtaConstants.ADV_SERVICE_UUID };
        let options: ble.ScanOptions = {
          dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
          matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE
        };
        this.scanLease.on('BLEDeviceFind', finder);
        this.scanLease.start([filter], options);
      } catch (e) {
        logger.warn('重扫启动失败: ' + errorText(e));
        settle(null);
      }
    });
  }

  /** 请求协商 MTU（需已连接）；协商结果经 BLEMtuChange 事件回填 */
  private requestMtu(client: ble.GattClientDevice): void {
    try {
      client.setBLEMtuSize(MtaConstants.GATT_MTU_SIZE);
    } catch (e) {
      logger.warn('setBLEMtuSize 失败: ' + errorText(e));
    }
  }

  /** 等待 MTU 协商完成，超时则返回当前值（未协商时为默认 23） */
  async waitMtuNegotiated(timeoutMs: number): Promise<number> {
    let waited = 0;
    while (waited < timeoutMs) {
      if (this.negotiatedMtu > 0) {
        return this.negotiatedMtu;
      }
      await this.sleepMs(MtaConstants.GATT_MTU_POLL_MS);
      waited += MtaConstants.GATT_MTU_POLL_MS;
    }
    return this.negotiatedMtu > 0 ? this.negotiatedMtu : MtaConstants.BLE_DEFAULT_MTU;
  }

  /**
   * 确保 MTU 已协商（幂等）。读写长特征值前调用：
   * 默认 MTU=23 时长特征值需分片读取，部分对端（如荣耀）不按 offset 返回，
   * 会导致读到重复前缀而解析失败。
   */
  async ensureMtuNegotiated(): Promise<number> {
    if (this.negotiatedMtu > 0) {
      return this.negotiatedMtu;
    }
    let client = this.gattClient;
    if (client === null) {
      throw new Error('GATT Client 未连接，无法协商 MTU');
    }
    this.requestMtu(client);
    return await this.waitMtuNegotiated(MtaConstants.GATT_MTU_TIMEOUT_MS);
  }

  /** 为 GATT 异步操作包装超时：超时抛文本错误，避免对端协议栈无响应时 Promise 永久挂起 */
  private withGattTimeout<T>(operation: Promise<T>, timeoutMs: number, label: string): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      let settled = false;
      let timerId = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        reject(new Error(`${label}超时（${timeoutMs}ms）`));
      }, timeoutMs);
      // 挂接底层 promise：迟到的结果被忽略，迟到的异常也有接收方，不会成为 unhandled rejection
      operation.then((value: T): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timerId);
        resolve(value);
      }).catch((e: Object): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timerId);
        reject(e);
      });
    });
  }

  /** 读取对端 CHAR_STATUS 返回的 DeviceInfo 原始文本（失败抛文本错误；不解析、不触发回调） */
  async readRemoteDeviceInfoText(): Promise<string> {
    let client = this.gattClient;
    if (client === null) {
      throw new Error('GATT Client 未连接，请先连接');
    }
    // 连接已断开时快速失败：避免对端已断开后仍走服务发现重试（逐次读超时）造成长时间阻塞
    if (!this.gattClientConnected) {
      throw new Error('GATT 连接已断开');
    }
    // 先协商 MTU，保证长特征值（DeviceInfo）单包读回，避免分片重复
    await this.ensureMtuNegotiated();
    let targetChar = await this.findCharacteristic(client, MtaConstants.CHAR_STATUS_UUID);
    let result: ble.BLECharacteristic = await this.withGattTimeout(
      client.readCharacteristicValue(targetChar), MtaConstants.GATT_READ_TIMEOUT_MS, '读取 DeviceInfo');
    let raw = decodeUtf8(new Uint8Array(result.characteristicValue));
    if (raw.length === 0) {
      throw new Error('对端 CHAR_STATUS 返回为空');
    }
    return raw;
  }

  /** 读取对端 CHAR_STATUS 返回的 DeviceInfo（失败抛文本错误）；原始文本经 getLastDeviceInfoRawText 取用 */
  async readRemoteDeviceInfo(): Promise<DeviceInfoJson> {
    let raw = await this.readRemoteDeviceInfoText();
    this.lastDeviceInfoRawText = raw;
    // 打印对端 DeviceInfo 原文：含本实现未解析的厂商扩展字段（如部分小米机型的 G/M/P），
    // 用于排查握手字段缺失导致的兼容问题
    logger.debug(`对端 DeviceInfo 原文: ${raw}`);
    let info = parseDeviceInfo(raw);
    if (info === undefined) {
      throw new Error('DeviceInfo 解析失败: ' + raw);
    }
    if (this.handlers !== null) {
      this.handlers.onRemoteDeviceInfo(info);
    }
    return info;
  }

  /** 取最近一次 readRemoteDeviceInfo 读到的原始文本（未读取时为空串，供写回后复读比对） */
  getLastDeviceInfoRawText(): string {
    return this.lastDeviceInfoRawText;
  }

  /**
   * 向对端 CHAR_P2P 写入 P2pInfo JSON（先确保 MTU 已协商），返回是否使用了无响应写。
   *
   * 写方式按对端写特征能力选择：对端声明支持无响应写（`writeNoResponse`）则用无响应写
   *（`WRITE_NO_RESPONSE`，ATT Write Command），否则用带响应写（`WRITE`，ATT Write Request）。
   * 依据：中兴 GATT Server 对 `CHAR_P2P` 写请求不回 `sendResponse`，对其用带响应写会一直等到
   * 超时，必须用无响应写；小米等会回写响应，用带响应写并等待写结果。写回执不作为成功判据，
   * 无响应写的「成功」仅代表本地已发出。
   * 写失败后不做同一连接内的重试，由上层按失败收尾。
   */
  async writeRemoteP2pInfo(p2pInfoJson: string): Promise<boolean> {
    let client = this.gattClient;
    if (client === null) {
      throw new Error('GATT Client 未连接，请先连接');
    }
    // 协商 MTU：写 P2pInfo 需 ≥ 259 字节单包能力（读路径已确保协商）
    let mtu = await this.ensureMtuNegotiated();
    let bytes = new util.TextEncoder().encodeInto(p2pInfoJson);
    if (bytes.length > mtu - 3) {
      throw new Error(`P2pInfo 长度 ${bytes.length} 超过单次可写上限 ${mtu - 3}（MTU=${mtu}）`);
    }
    let targetChar = await this.findCharacteristic(client, MtaConstants.CHAR_P2P_UUID);
    let props: ble.GattProperties | undefined = targetChar.properties;
    let propsText = '未提供';
    // 按对端写特征能力选择写模式：声明支持无响应写 → 无响应写，否则带响应写
    let writeNoResponseSupported = props !== undefined && props.writeNoResponse === true;
    if (props !== undefined) {
      propsText = `write=${props.write === true} writeNoResponse=${props.writeNoResponse === true}`;
    }
    logger.debug(`对端 CHAR_P2P 属性 ${propsText} 写方式=${resolveMtaP2pWriteModeText(writeNoResponseSupported)}` +
      ` 目标特征=${MtaConstants.CHAR_P2P_UUID} 长度=${bytes.length} MTU=${mtu}`);
    targetChar.characteristicValue = toArrayBuffer(bytes);
    let writeStartMs = Date.now();
    try {
      if (writeNoResponseSupported) {
        // 无响应写（ATT Write Command）：对端不回 ATT 响应，本地调用返回即视为「已发出」
        await this.withGattTimeout(client.writeCharacteristicValue(targetChar, ble.GattWriteType.WRITE_NO_RESPONSE),
          MtaConstants.GATT_WRITE_TIMEOUT_MS, '写入 P2pInfo');
      } else {
        // 带响应写（ATT Write Request）：等待对端 ATT 响应（写回调）返回
        await this.withGattTimeout(client.writeCharacteristicValue(targetChar, ble.GattWriteType.WRITE),
          MtaConstants.GATT_WRITE_TIMEOUT_MS, '写入 P2pInfo');
      }
      logger.debug(formatMtaP2pWriteDiagnostic(writeNoResponseSupported, MtaConstants.CHAR_P2P_UUID, mtu,
        bytes.length, Date.now() - writeStartMs, true, ''));
    } catch (e) {
      // 不在同一 client 上重试：上一笔 ATT 事务未结束时协议栈会以「The operation is busy」
      // 拒绝后续操作（实测回退写必然失败并掩盖真实原因），故只上抛可读原因
      let reason = errorText(e);
      logger.debug(formatMtaP2pWriteDiagnostic(writeNoResponseSupported, MtaConstants.CHAR_P2P_UUID, mtu,
        bytes.length, Date.now() - writeStartMs, false, reason));
      throw new Error(
        `写入 CHAR_P2P 失败(${resolveMtaP2pWriteModeText(writeNoResponseSupported)}): ` + reason);
    }
    return writeNoResponseSupported;
  }

  /** 在 GATT 服务中定位指定特征；服务发现偶发失败时重试，仍失败抛文本错误 */
  private async findCharacteristic(client: ble.GattClientDevice,
    characteristicUuid: string): Promise<ble.BLECharacteristic> {
    let lastReason = `未找到 GATT 服务或特征 ${characteristicUuid}`;
    for (let attempt = 1; attempt <= MtaConstants.GATT_DISCOVERY_MAX_ATTEMPTS; attempt++) {
      try {
        // 服务发现视作读操作，共用读超时（getServices 也可能永久挂起）
        let services: Array<ble.GattService> = await this.withGattTimeout(client.getServices(),
          MtaConstants.GATT_READ_TIMEOUT_MS, '服务发现');
        let target = this.pickCharacteristic(services, characteristicUuid);
        if (target !== undefined) {
          return target;
        }
      } catch (e) {
        lastReason = '服务发现失败: ' + errorText(e);
      }
      if (attempt < MtaConstants.GATT_DISCOVERY_MAX_ATTEMPTS) {
        await this.sleepMs(MtaConstants.GATT_DISCOVERY_RETRY_DELAY_MS);
      }
    }
    throw new Error(lastReason);
  }

  /** 在服务列表中定位指定特征，缺失返回 undefined */
  private pickCharacteristic(services: Array<ble.GattService>,
    characteristicUuid: string): ble.BLECharacteristic | undefined {
    for (let i = 0; i < services.length; i++) {
      if (services[i].serviceUuid.toLowerCase() !== MtaConstants.GATT_SERVICE_UUID) {
        continue;
      }
      let characteristics = services[i].characteristics;
      for (let j = 0; j < characteristics.length; j++) {
        if (characteristics[j].characteristicUuid.toLowerCase() === characteristicUuid) {
          return characteristics[j];
        }
      }
    }
    return undefined;
  }

  /** 断开并释放 GATT Client 实例 */
  disconnectGattClient(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let client = this.gattClient;
      if (client === null) {
        resolve();
        return;
      }
      this.gattClient = null;
      this.gattClientConnected = false;
      this.gattClientTarget = '';
      this.negotiatedMtu = 0;
      try {
        client.off('BLEConnectionStateChange');
        client.off('BLEMtuChange');
        client.disconnect();
        client.close();
        resolve();
      } catch (e) {
        reject(errorText(e));
      }
    });
  }

  /** 延时辅助（共用实现见 MtaBleCommon） */
  private sleepMs(ms: number): Promise<void> {
    return sleepMs(ms);
  }

  // ── 资源释放 ──

  /** 页面退出时释放全部资源（扫描/GATT Client/事件） */
  destroy(): void {
    this.stopScan().catch((): void => {
    });
    this.disconnectGattClient().catch((): void => {
    });
    this.unregisterEvents();
  }
}
