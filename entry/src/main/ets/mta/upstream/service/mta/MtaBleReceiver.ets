// 羊绒互传修改：独立广播租约串行启停，原始广播数据与 GATT 流程保持不变。
import { ScopedBleAdvertiser } from '../../../ScopedBleAdvertiser';
/**
 * MtaBleReceiver.ets — MTA 接收端 BLE 服务
 *
 * 提供接收端所需能力：MTA 格式广播（主广播 + 扫描响应）、
 * GATT Server（服务 00009955 + CHAR_STATUS 读 / CHAR_P2P 写）、蓝牙开关事件订阅。
 * 本服务只采集/转发数据，不持有页面状态。
 */

import { ble, access, constant } from '@kit.ConnectivityKit';
import { util } from '@kit.ArkTS';
import { MtaBleEventHandlers, bytesToHex, extractJsonText } from '../../model/mta/MtaProtocolModels';
import { MtaConstants } from './MtaConstants';
import {
  decodeUtf8,
  loadOrCreateMtaDeviceIdHex,
  mtaBroadcastName,
  profileStateText,
  registerBluetoothStateEvent,
  toArrayBuffer,
  unregisterBluetoothStateEvent
} from './MtaBleCommon';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { errorText } from '../../utils/FormatUtil';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaBleReceiver', '互传蓝牙');

/** 将设备名编码为扫描响应中的 16 字节字段（右侧补 0x00；名称被截断到 15 字节时以 \t 标记截断） */
function encodeNameField(deviceName: string): Uint8Array {
  // 名称区按协议右侧补零：扫描端以首个 0x00 作为名称终止符，真机广播实测亦为 0x00 填充；
  // 仅当名称被截断时，紧随其后的字节才写 \t 截断标记（不作填充）
  let field = new Uint8Array(MtaConstants.SCAN_RSP_NAME_LENGTH);
  field.fill(MtaConstants.NAME_FIELD_PAD_BYTE);
  // TextEncoder.encodeInto 对空字符串返回 undefined，空名直接返回全零字段
  if (deviceName.length === 0) {
    return field;
  }
  // 编码口径与「本机信息」展示共用 mtaBroadcastName
  let name = mtaBroadcastName(deviceName);
  let encoded = new util.TextEncoder().encodeInto(name);
  field.set(encoded, 0);
  if (name !== deviceName) {
    field[encoded.length] = MtaConstants.NAME_FIELD_TRUNCATION_MARK;
  }
  return field;
}

/**
 * MTA 接收端 BLE 服务。
 * 所有 Promise 方法失败时 reject 文本描述（调用方直接记入日志）。
 */
export class MtaBleReceiver {
  /** 事件回调集合（服务注入） */
  private handlers: MtaBleEventHandlers | null = null;
  // ── 广播 ──
  /** 是否正在广播 */
  private advertising: boolean = false;
  private advertiser: ScopedBleAdvertiser = new ScopedBleAdvertiser();
  /** 随机发送者 ID（16 字节，长度见 SENDER_ID_LENGTH） */
  private senderId: Uint8Array = new Uint8Array(MtaConstants.SENDER_ID_LENGTH);
  /** 发送者 ID 是否已生成（广播重启时复用，避免对端识别为新设备） */
  private senderIdInitialized: boolean = false;
  /** 当前广播使用的品牌标识（主广播 UUID 的品牌字节来源，默认第三方） */
  private brandId: number = MtaConstants.BRAND_ID_THIRD_PARTY;
  /** 最近一次构造的主广播字节 */
  private mainAdvBytes: Uint8Array = new Uint8Array(0);
  /** 最近一次构造的扫描响应字节 */
  private scanRspBytes: Uint8Array = new Uint8Array(0);
  // ── GATT Server ──
  /** GATT Server 实例 */
  private gattServer: ble.GattServer | null = null;
  /** 是否运行中 */
  private gattRunning: boolean = false;
  /** DeviceInfo JSON 文本 */
  private deviceInfoJson: string = '';
  /** DeviceInfo JSON 的 UTF-8 字节（读请求按 offset 切片返回） */
  private deviceInfoBytes: Uint8Array = new Uint8Array(0);
  /** 已连接客户端地址 */
  private connectedClientId: string = '';
  /** prepared write 会话缓冲 */
  private writeBuffer: Uint8Array = new Uint8Array(0);
  private writeBufferOwner: string = '';
  /** 最近一次写请求的目标特征 UUID（诊断用；空串表示尚无写请求） */
  private lastWriteTargetUuid: string = '';
  // ── 事件注册 / 反注册 ──

  /**
   * 已注册的蓝牙开关回调引用：反注册时必须按引用精确移除。
   * 无参 access.off('stateChange') 会移除所有监听者（含发现端实例），
   * 导致发现侧再也收不到蓝牙开关事件。
   */
  private stateChangeCallback: ((state: access.BluetoothState) => void) | undefined = undefined;

  /** 注册蓝牙开关事件；重复注册时先反注册旧回调 */
  registerEvents(handlers: MtaBleEventHandlers): void {
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

  // ── 广播 ──

  /** 是否正在广播 */
  isAdvertising(): boolean {
    return this.advertising;
  }

  /** 发送者 ID 的十六进制文本 */
  getSenderIdHex(): string {
    return bytesToHex(this.senderId);
  }

  /** 初始化本机 MTA 设备 ID（持久化、跨会话稳定）：由十六进制文本还原字节 */
  private initSenderId(): void {
    let hex = loadOrCreateMtaDeviceIdHex();
    let id = new Uint8Array(MtaConstants.SENDER_ID_LENGTH);
    for (let i = 0; i < id.length; i++) {
      id[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
    }
    this.senderId = id;
  }

  /**
   * 构造主广播数据：serviceUuid + 6 字节 serviceData（设备 ID 前 6 字节）。
   *
   * 厂商扫描端从合并扫描记录偏移 25..31 读到本段，与扫描响应尾段拼接还原完整
   * 16 字节设备 ID。曾尝试把 MTA UUID 改以"零长度 serviceData"承载以对齐小米互传
   * 的固定字节偏移，实测系统会直接丢弃值为空的 serviceData 条目（新报文里只剩两条
   * serviceData），反而丢掉了 128 位 service UUID 列表、导致对端扫描过滤器匹配不到
   * 本机，故保留原方案。
   */
  private buildMainAdvData(): ble.AdvertiseData {
    let bytes = new Uint8Array(MtaConstants.ADV_DATA_LENGTH);
    bytes.set(this.senderId.slice(0, MtaConstants.ADV_DATA_LENGTH));
    this.mainAdvBytes = bytes;
    let serviceData: ble.ServiceData = {
      // 品牌字节随当前模拟品牌动态生成；默认第三方时与 ADV_DATA_UUID 一致
      serviceUuid: MtaConstants.mainAdvDataUuidForBrand(this.brandId),
      serviceValue: toArrayBuffer(bytes)
    };
    let data: ble.AdvertiseData = {
      serviceUuids: [MtaConstants.ADV_SERVICE_UUID],
      manufactureData: [],
      serviceData: [serviceData]
    };
    return data;
  }

  /** 构造扫描响应数据：27 字节 serviceData（设备 ID 尾段 + 设备名 + 0x01） */
  private buildScanRspData(deviceName: string): ble.AdvertiseData {
    let bytes = new Uint8Array(MtaConstants.SCAN_RSP_LENGTH);
    // [0..10) 承载设备 ID 第 6..16 字节：厂商扫描端从合并记录偏移 35..45 读到本段，
    // 与主广播前 6 字节拼接还原完整 16 字节设备 ID
    let idTailFrom = MtaConstants.SENDER_ID_LENGTH - MtaConstants.SCAN_RSP_ID_TAIL_LENGTH;
    bytes.set(this.senderId.slice(idTailFrom, MtaConstants.SENDER_ID_LENGTH),
      MtaConstants.SCAN_RSP_ID_TAIL_OFFSET);
    bytes.set(encodeNameField(deviceName), MtaConstants.SCAN_RSP_NAME_OFFSET);
    bytes[MtaConstants.SCAN_RSP_LENGTH - 1] = MtaConstants.SCAN_RSP_TAIL_FLAG;
    this.scanRspBytes = bytes;
    let serviceData: ble.ServiceData = {
      serviceUuid: MtaConstants.SCAN_RSP_UUID,
      serviceValue: toArrayBuffer(bytes)
    };
    let data: ble.AdvertiseData = {
      serviceUuids: [],
      manufactureData: [],
      serviceData: [serviceData]
    };
    return data;
  }

  /** 启动 MTA 格式广播（主广播 + 扫描响应），返回构造出的字节预览 */
  startAdvertising(deviceName: string, brandId: number): Promise<string> {
    return new Promise<string>(async (resolve, reject) => {
      if (this.advertising) {
        resolve('广播已在运行');
        return;
      }
      // 记录本次广播的品牌，供主广播 UUID 生成使用
      this.brandId = brandId;
      try {
        // 发送者 ID 仅首次生成，后续广播重启复用，保持对端设备标识稳定
        if (!this.senderIdInitialized) {
          this.initSenderId();
          this.senderIdInitialized = true;
        }
        let setting: ble.AdvertiseSetting = {
          interval: 160,
          txPower: 1,
          connectable: true
        };
        let mainData = this.buildMainAdvData();
        let rspData = this.buildScanRspData(deviceName);
        // 主广播与扫描响应必须分两个 AdvertiseData 投递：系统不会在两者之间挪动 AD 元素，
        // 且每个 AdvertiseData 硬上限 31 字节（把两条 serviceData 一并交给主广播实测报 2902054）
        await this.advertiser.start(setting, mainData, rspData);
        this.advertising = true;
        // 诊断日志：记录实际发出的广播字节与参数，便于核对品牌字节与填充
        let brandHex = (this.brandId & 0xff).toString(16);
        let brandByte = brandHex.length === 1 ? '0' + brandHex : brandHex;
        logger.debug(`广播已启动 主广播hex=${bytesToHex(this.mainAdvBytes)}` +
          ` 主广播serviceUuid=${MtaConstants.mainAdvDataUuidForBrand(this.brandId)}` +
          ` 扫描响应hex=${bytesToHex(this.scanRspBytes)}` + ` 扫描响应serviceUuid=${MtaConstants.SCAN_RSP_UUID}` +
          ` 品牌字节=0x${brandByte} interval=160 txPower=1 connectable=true` +
          ` 发送者ID=${this.getSenderIdHex()} 设备名=${deviceName}`);
        if (this.handlers !== null) {
          this.handlers.onAdvertiseStateChange(true, '广播已启动 interval=160 txPower=1 connectable=true');
        }
        let preview = `主广播(${this.mainAdvBytes.length}B) 发送者ID=${this.getSenderIdHex()}\n` +
          `扫描响应(${this.scanRspBytes.length}B) 设备名=${deviceName}`;
        resolve(preview);
      } catch (e) {
        // 异常路径清理可能已建立的广播句柄，避免残留导致后续无法重新广播
        try {
          await this.advertiser.stop();
        } catch (_e) {
        }
        this.advertising = false;
        reject(errorText(e));
      }
    });
  }

  /** 停止本实例广播，等待尚未返回句柄的启动后再释放。 */
  async stopAdvertising(): Promise<void> {
    let failure = '';
    try { await this.advertiser.stop(); } catch (e) { failure = errorText(e); }
    this.advertising = false;
    if (this.handlers !== null) {
      this.handlers.onAdvertiseStateChange(false, failure.length > 0 ? '广播已停止(异常)' : '广播已停止');
    }
    if (failure.length > 0) { throw new Error(failure); }
  }

  // ── GATT Server ──

  /** GATT Server 是否运行中 */
  isGattRunning(): boolean {
    return this.gattRunning;
  }

  /** 已连接客户端地址 */
  getConnectedClientId(): string {
    return this.connectedClientId;
  }

  /** 最近一次写请求的目标特征 UUID（空串表示尚无写请求；供发送伴随外设的对端行为记录使用） */
  getLastWriteTargetUuid(): string {
    return this.lastWriteTargetUuid;
  }

  /** 启动 GATT Server：注册服务与两个特征值，订阅读写/连接事件 */
  startGattServer(deviceInfoJson: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (this.gattServer !== null) {
        reject('GATT Server 已在运行');
        return;
      }
      let server: ble.GattServer | null = null;
      try {
        this.deviceInfoJson = deviceInfoJson;
        this.deviceInfoBytes = new util.TextEncoder().encodeInto(deviceInfoJson);
        this.writeBuffer = new Uint8Array(0);
        this.writeBufferOwner = '';
        this.connectedClientId = '';

        server = ble.createGattServer();
        const s: ble.GattServer = server;
        let statusChar: ble.BLECharacteristic = {
          serviceUuid: MtaConstants.GATT_SERVICE_UUID,
          characteristicUuid: MtaConstants.CHAR_STATUS_UUID,
          characteristicValue: toArrayBuffer(this.deviceInfoBytes),
          descriptors: [],
          properties: { read: true }
        };
        let p2pChar: ble.BLECharacteristic = {
          serviceUuid: MtaConstants.GATT_SERVICE_UUID,
          characteristicUuid: MtaConstants.CHAR_P2P_UUID,
          characteristicValue: new ArrayBuffer(0),
          descriptors: [],
          properties: { write: true, writeNoResponse: true }
        };
        let service: ble.GattService = {
          serviceUuid: MtaConstants.GATT_SERVICE_UUID,
          isPrimary: true,
          characteristics: [statusChar, p2pChar]
        };
        server.addService(service);

        server.on('characteristicRead', (req: ble.CharacteristicReadRequest) => {
          this.handleCharacteristicRead(s, req);
        });
        server.on('characteristicWrite', (req: ble.CharacteristicWriteRequest) => {
          this.handleCharacteristicWrite(s, req);
        });
        server.on('connectionStateChange', (state: ble.BLEConnectionChangeState) => {
          this.handleGattConnection(state);
        });

        this.gattServer = server;
        this.gattRunning = true;
        resolve();
      } catch (e) {
        // 注册中途失败时释放已创建的 GATT Server，避免句柄泄漏
        if (server !== null) {
          try {
            server.close();
          } catch (closeErr) {
            logger.warn('GATT Server 关闭失败: ' + errorText(closeErr));
          }
        }
        reject(errorText(e));
      }
    });
  }

  /** 处理 CHAR_STATUS 读请求：按 offset 切片返回 DeviceInfo JSON */
  private handleCharacteristicRead(server: ble.GattServer, req: ble.CharacteristicReadRequest): void {
    if (this.handlers !== null) {
      this.handlers.onGattReadRequest(req.deviceId, req.offset);
    }
    let start = req.offset > 0 ? req.offset : 0;
    let slice: Uint8Array = start >= this.deviceInfoBytes.length ?
      new Uint8Array(0) : this.deviceInfoBytes.slice(start);
    let resp: ble.ServerResponse = {
      deviceId: req.deviceId,
      transId: req.transId,
      status: 0,
      offset: req.offset,
      value: toArrayBuffer(slice)
    };
    try {
      server.sendResponse(resp);
    } catch (e) {
      logger.warn('sendResponse(读) 失败: ' + errorText(e));
    }
  }

  /** 处理 CHAR_P2P 写请求：prepared write 按 offset 累积，提交时提取 JSON 并上报 */
  private handleCharacteristicWrite(server: ble.GattServer, req: ble.CharacteristicWriteRequest): void {
    // 记录写目标特征（诊断用）：供发送伴随外设的对端行为记录取回
    this.lastWriteTargetUuid = req.characteristicUuid;
    if (req.deviceId !== this.writeBufferOwner) {
      // 换了写入方：丢弃其他客户端残留的半截缓冲，避免跨会话污染
      this.writeBufferOwner = req.deviceId;
      this.writeBuffer = new Uint8Array(0);
    }
    let value = new Uint8Array(req.value);
    if (req.isPrepared) {
      // 分片写入：按 offset 累积到会话缓冲
      this.accumulateWrite(req.offset, value);
      if (this.handlers !== null) {
        this.handlers.onGattWriteProgress(req.deviceId, req.offset, this.writeBuffer.length, true);
      }
    } else {
      // 普通写入（单包）或 prepared write 的提交请求
      if (value.length > 0) {
        this.accumulateWrite(req.offset, value);
      }
      let payload = extractJsonText(decodeUtf8(this.writeBuffer));
      if (this.handlers !== null) {
        this.handlers.onGattWriteProgress(req.deviceId, req.offset, this.writeBuffer.length, false);
        this.handlers.onP2pInfoReceived(req.deviceId, payload);
      }
      this.writeBuffer = new Uint8Array(0);
    }
    if (req.needRsp) {
      let resp: ble.ServerResponse = {
        deviceId: req.deviceId,
        transId: req.transId,
        status: 0,
        offset: req.offset,
        value: toArrayBuffer(new Uint8Array(0))
      };
      try {
        server.sendResponse(resp);
      } catch (e) {
        logger.warn('sendResponse(写) 失败: ' + errorText(e));
      }
    }
  }

  /** 按 offset 累积写分片，超过缓冲上限则忽略该分片 */
  private accumulateWrite(offset: number, value: Uint8Array): void {
    if (offset < 0) {
      return;
    }
    let needed = offset + value.length;
    if (needed > MtaConstants.MAX_WRITE_BUFFER) {
      logger.warn(`写入超出缓冲上限 ${MtaConstants.MAX_WRITE_BUFFER} 字节，已忽略 offset=${offset} len=${value.length}`);
      return;
    }
    let size = needed > this.writeBuffer.length ? needed : this.writeBuffer.length;
    let next = new Uint8Array(size);
    next.set(this.writeBuffer, 0);
    next.set(value, offset);
    this.writeBuffer = next;
  }

  /** 处理 GATT 连接状态变化 */
  private handleGattConnection(state: ble.BLEConnectionChangeState): void {
    if (state.state === constant.ProfileConnectionState.STATE_CONNECTED) {
      this.connectedClientId = state.deviceId;
    } else if (state.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
      this.connectedClientId = '';
      // 断开时丢弃半截写入缓冲，防止下个会话读到上个客户端的残留数据
      this.writeBuffer = new Uint8Array(0);
      this.writeBufferOwner = '';
    }
    if (this.handlers !== null) {
      this.handlers.onGattConnectionChange(state.deviceId, profileStateText(state.state));
    }
  }

  /** 停止 GATT Server：移除服务、反注册回调并清空写缓冲 */
  stopGattServer(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let server = this.gattServer;
      if (server === null) {
        resolve();
        return;
      }
      this.gattServer = null;
      this.gattRunning = false;
      try {
        server.off('characteristicRead');
        server.off('characteristicWrite');
        server.off('connectionStateChange');
        server.removeService(MtaConstants.GATT_SERVICE_UUID);
        server.close();
        this.writeBuffer = new Uint8Array(0);
        this.writeBufferOwner = '';
        this.connectedClientId = '';
        resolve();
      } catch (e) {
        reject(errorText(e));
      }
    });
  }
}
