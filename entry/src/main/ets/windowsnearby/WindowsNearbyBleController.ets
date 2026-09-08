import { LogCapture as Lg } from '../common/LogCapture';
import ble from '@ohos.bluetooth.ble';
import access from '@ohos.bluetooth.access';
import deviceInfo from '@ohos.deviceInfo';
import { BusinessError } from '@kit.BasicServicesKit';
import { SettingsStore } from '../common/SettingsStore';
import { ByteUtils } from '../common/ByteUtils';

export interface WindowsNearbyPeer {
  readonly id: string;
  readonly name: string;
  readonly deviceId: string;
  readonly sessionHint: string;
  readonly rssi: number;
}

export class WindowsNearbyDeviceListener {
  onPeerFound(peer: WindowsNearbyPeer): void {
    // override in page/listener subclass
  }
}

const GS_CDP_MANUFACTURER_ID = 0x0006;
const MS_CDP_SERVICE_UUID = '0000fdee-0000-1000-8000-00805f9b34fb';
const GS_NEARSHARE_SCENARIO = 0x01;
const GS_CDP_DEVICE_TYPE = 0x08;
const LOG_TAG = '羊绒互传 WindowsNearby';
// 广播自愈：探测到 Windows 对端后立刻重发广播的最小间隔（防抖，避免每 ~100ms 的
// 扫描回调都在 stop/start 广播）。
const ADVERTISE_REASSERT_MIN_GAP_MS = 10000;
// 广播自愈：周期重断言广播的间隔。BLE 广播是一次性启动的，冷启动蓝牙栈未就绪、
// 瞬态失败或被系统挂起后不会自动恢复，导致「app 先开、Windows 后开搜不到，重启
// app 才好」；周期重发（stop+start）让广播在 30s 内自愈。
const ADVERTISE_REASSERT_INTERVAL_MS = 30000;

export class WindowsNearbyBleController {
  private readonly listener: WindowsNearbyDeviceListener;
  private active = false;
  private macHex = '000000000000';
  private readonly peers: Map<string, WindowsNearbyPeer> = new Map();
  private advertisingActive = false;
  private advertiseTimer: number = 0;
  private lastAdvertiseReassert: number = 0;

  constructor(listener: WindowsNearbyDeviceListener) {
    this.listener = listener;
  }

  start(): void {
    if (this.active) { return; }
    this.active = true;
    this.peers.clear();
    this.startScan();
    this.startAdvertisement();
    this.startAdvertiseReassertTimer();
    Lg.i(LOG_TAG + ': active');
  }

  stop(): void {
    if (!this.active) { return; }
    this.active = false;
    this.peers.clear();
    this.stopAdvertiseReassertTimer();
    this.stopScan();
    this.stopAdvertisement();
    Lg.i(LOG_TAG + ': inactive');
  }

  peersSnapshot(): WindowsNearbyPeer[] {
    const result: WindowsNearbyPeer[] = [];
    this.peers.forEach((peer: WindowsNearbyPeer): void => { result.push(peer); });
    return result;
  }

  /**
   * 供 Hub 在传输会话结束后调用：立即重发广播（不走 10s 节流），保证下一次 Windows
   * 会话开始时手机一定处于可发现状态，不必等 30s 周期自愈或重启 app。
   */
  reassertAdvertisement(): void {
    if (!this.active) {
      return;
    }
    this.lastAdvertiseReassert = Date.now();
    this.startAdvertisement();
  }

  private startScan(): void {
    try {
      ble.on('BLEDeviceFind', (results: Array<ble.ScanResult>): void => {
        results.forEach((result: ble.ScanResult): void => this.parseScanResult(result));
      });
      const scanOptions: ble.ScanOptions = {
        interval: 500,
        dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
        matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE
      };
      try {
        ble.startBLEScan([{ manufactureId: GS_CDP_MANUFACTURER_ID }, { serviceUuid: MS_CDP_SERVICE_UUID }], scanOptions);
        Lg.i(LOG_TAG + ': scan started (microsoft 0x0006 + FDEE filter)');
      } catch (error) {
        const filterFailure = error as BusinessError;
        Lg.w(LOG_TAG + ': combined filter failed code=' + filterFailure.code
          + ', message=' + filterFailure.message + ', fallback to FDEE serviceUuid filter');
        try {
          ble.startBLEScan([{ serviceUuid: MS_CDP_SERVICE_UUID }], scanOptions);
          Lg.i(LOG_TAG + ': scan started (FDEE serviceUuid filter)');
        } catch (error2) {
          const fdeeFailure = error2 as BusinessError;
          Lg.w(LOG_TAG + ': FDEE filter also failed code=' + fdeeFailure.code
            + ', message=' + fdeeFailure.message + ', fallback to unfiltered scan');
          ble.startBLEScan([], scanOptions);
          Lg.i(LOG_TAG + ': scan started (unfiltered)');
        }
      }
    } catch (error) {
      const failure = error as BusinessError;
      Lg.w(LOG_TAG + ': scan start failed code=' + failure.code + ', message=' + failure.message);
    }
  }

  private stopScan(): void {
    try {
      ble.stopBLEScan();
    } catch (error) {
      const failure = error as BusinessError;
      Lg.w(LOG_TAG + ': scan stop failed code=' + failure.code + ', message=' + failure.message);
    }
    try {
      ble.off('BLEDeviceFind');
    } catch (error) {
      Lg.w(LOG_TAG + ': BLE callback unregister failed: ' + JSON.stringify(error));
    }
  }

  private parseScanResult(result: ble.ScanResult): void {
    if (this.active === false) { return; }
    const diagnostics = this.describeScanResult(result);
    if (diagnostics.length > 0) {
      Lg.d(LOG_TAG + ': raw ' + diagnostics);
    }
    const cdpValue = this.extractBeaconPayload(result);
    if (cdpValue === undefined || cdpValue.length === 0) {
      Lg.d(LOG_TAG + ': no CDP beacon, device='
        + (result.deviceName !== undefined ? result.deviceName : '') + ' rssi=' + result.rssi);
      return;
    }
    if (cdpValue.length < 10) {
      Lg.w(LOG_TAG + ': CDP beacon too short ' + cdpValue.length);
      return;
    }
    if (cdpValue[0] !== GS_NEARSHARE_SCENARIO) {
      return;
    }
    const version = (cdpValue[2] >>> 5) & 0x07;
    const isFdeePayload = cdpValue.length >= 10
      && (cdpValue[1] === 0x02 || cdpValue[2] === 0x01 || cdpValue[3] === 0x1e);
    if (version !== 1 && !isFdeePayload) {
      return;
    }
    let deviceId: string;
    let deviceName: string;
    let sessionHint: string;
    if (isFdeePayload) {
      // Windows Nearby real broadcast (Windows 10/11):
      // 01 02 01 1e 37 00 02 06 00 b0 b6 32 01 08 58 30 41 32 00
      // Bytes 4-9 are the 6-byte discovery id, not a real MAC/name.
      deviceId = ByteUtils.toHex(cdpValue.slice(4, 10));
      deviceName = '';
      sessionHint = '';
    } else {
      deviceId = ByteUtils.toHex(cdpValue.slice(4, 10));
      let end = cdpValue.length;
      for (let i = 10; i < cdpValue.length; i++) {
        if (cdpValue[i] === 0) {
          end = i;
          break;
        }
      }
      deviceName = ByteUtils.decodeText(cdpValue.slice(10, end));
      sessionHint = end < cdpValue.length ? ByteUtils.decodeText(cdpValue.slice(end + 1)) : '';
    }
    const finalName = deviceName.length > 0 ? deviceName : result.deviceName;
    const peer: WindowsNearbyPeer = {
      id: 'windowsnearby:' + deviceId,
      name: finalName.length > 0 ? finalName : 'Windows 设备',
      deviceId,
      sessionHint,
      rssi: result.rssi
    };
    this.peers.set(peer.id, peer);
    // Only log the device name + a short (non-MAC) id; the beacon payload and the
    // full MAC-derived deviceId are device-identifying and must stay out of logs.
    Lg.i(LOG_TAG + (isFdeePayload ? ': fdee' : ': mfr6')
      + ' name=' + peer.name + ' id=' + peer.deviceId.substring(0, 6));
    this.listener.onPeerFound(peer);
    // Windows 正在附近广播（= 它的「就近共享」已打开），立刻重发自己的广播，让刚
    // 启动扫描的 Windows 能马上看到手机（修复「先开 app、后开 Windows 搜不到」）。
    this.requestAdvertiseReassert();
  }

  private startAdvertisement(): void {
    try {
      if (access.getState() !== access.BluetoothState.STATE_ON) {
        Lg.i(LOG_TAG + ': Bluetooth is off, advertisement skipped');
        return;
      }
      this.stopAdvertisement();
      this.macHex = this.buildStableMac();
      const settings = SettingsStore.current();
      const rawName = settings.alias.length > 0 ? settings.alias : 'CashmereLink';
      const nameBytes = ByteUtils.encodeText(rawName);
      const deviceId = ByteUtils.fromHex(this.macHex.replace(/[-:]/g, '').padEnd(12, '0').slice(0, 12));
      const advSetting: ble.AdvertiseSetting = {
        interval: 160,
        txPower: -4,
        connectable: false
      };

      // 1) 首选：mfr6 CDP beacon 放主广播，FDEE 服务数据 + FDEE 服务 UUID 放扫描响应。
      //    Windows 的 Nearby 扫描器有两种：按微软厂商数据 0x0006 过滤的，和按 FDEE
      //    服务 UUID/服务数据过滤的（本项目扫描器即两者联合过滤）。只发 mfr6 会被
      //    FDEE 过滤的扫描器漏掉 →「部分 Windows 设备搜不到」。真实 Windows 设备同时
      //    携带 mfr6 与 FDEE，这里用主动扫描（active scan）可合并的扫描响应补齐 FDEE，
      //    两种过滤都能命中。注意传统广播总长 ≤31 字节：mfr6 AD（含 flags）= 18+name，
      //    名字最长 13 字节；FDEE 服务数据 AD = 17+name，扫描响应里名字最长 14 字节。
      try {
        const payload = this.buildAdvertisementPayload(this.macHex, 13);
        const advData: ble.AdvertiseData = {
          serviceUuids: [],
          serviceData: [],
          manufactureData: [{
            manufactureId: GS_CDP_MANUFACTURER_ID,
            manufactureValue: ByteUtils.toArrayBuffer(payload)
          }],
          includeDeviceName: false
        };
        const fdee = this.buildFdeeServiceData(deviceId, nameBytes, 14);
        // 扫描响应只放 FDEE 服务数据（AD 0x16 内嵌 16-bit UUID），不放单独的
        // serviceUuids 列表：后者按 16-bit 编码也要 5 字节，默认 12 字节别名会让
        // 扫描响应超 31 字节，导致 dual 广播整体失败。服务数据对按 FDEE 服务 UUID
        // 过滤/解析的扫描器同样可见。
        const scanRt: ble.AdvertiseData = {
          serviceUuids: [],
          serviceData: [{
            serviceUuid: MS_CDP_SERVICE_UUID,
            serviceValue: ByteUtils.toArrayBuffer(fdee)
          }],
          manufactureData: [],
          includeDeviceName: false
        };
        ble.startAdvertising(advSetting, advData, scanRt);
        this.advertisingActive = true;
        Lg.i(LOG_TAG + ': advertise mode=dual(mfr6 adv + FDEE scanRsp) wifiUpgrade='
          + (SettingsStore.current().wifiUpgradeTcp === true ? 'on' : 'off'));
        return;
      } catch (mfrError) {
        const failure = mfrError as BusinessError;
        Lg.w(LOG_TAG + ': dual advertise failed code=' + failure.code
          + ', message=' + failure.message + ', fallback to manufactureData only');
      }

      // 2) 回退：仅 mfr6 CDP beacon（老路径；名字同样按 13 字节截断，避免超限）。
      try {
        const payload = this.buildAdvertisementPayload(this.macHex, 13);
        const advData: ble.AdvertiseData = {
          serviceUuids: [],
          serviceData: [],
          manufactureData: [{
            manufactureId: GS_CDP_MANUFACTURER_ID,
            manufactureValue: ByteUtils.toArrayBuffer(payload)
          }],
          includeDeviceName: false
        };
        ble.startAdvertising(advSetting, advData);
        this.advertisingActive = true;
        Lg.i(LOG_TAG + ': advertise mode=manufactureData wifiUpgrade='
          + (SettingsStore.current().wifiUpgradeTcp === true ? 'on' : 'off'));
        return;
      } catch (mfrError) {
        const failure = mfrError as BusinessError;
        Lg.w(LOG_TAG + ': manufactureData advertise failed code=' + failure.code
          + ', message=' + failure.message + ', fallback to FDEE service data');
      }

      // 3) 回退：仅 FDEE 服务数据（镜像真实 Windows 广播结构）。
      try {
        const fdee = this.buildFdeeServiceData(deviceId, nameBytes, 6);
        const fdeeData: ble.AdvertiseData = {
          serviceUuids: [MS_CDP_SERVICE_UUID],
          serviceData: [{
            serviceUuid: MS_CDP_SERVICE_UUID,
            serviceValue: ByteUtils.toArrayBuffer(fdee)
          }],
          manufactureData: [],
          includeDeviceName: false
        };
        ble.startAdvertising(advSetting, fdeeData);
        this.advertisingActive = true;
        Lg.i(LOG_TAG + ': advertise mode=FDEE');
        return;
      } catch (fdeeError) {
        const failure = fdeeError as BusinessError;
        Lg.w(LOG_TAG + ': FDEE advertise also failed code=' + failure.code
          + ', message=' + failure.message);
      }
    } catch (error) {
      this.advertisingActive = false;
      const failure = error as BusinessError;
      Lg.w(LOG_TAG + ': advertise start failed code=' + failure.code + ', message=' + failure.message);
    }
  }

  /**
   * Deliberately mirrors the real Windows FDEE beacon shape:
   *   01 02 01 1e <6-byte id> 01 08 <name> 00
   * Windows' beacons also append two id-continuation bytes (e.g. b6 32) between
   * the id and the 01 08 tag; replicating the exact header + id + 01 08 + name +
   * terminator keeps it parseable by the same logic Windows uses for its own.
   *
   * maxNameLen bounds the legacy-advertisement budget: the service-data AD is
   * 17 + nameLen bytes (1 len + 1 type 0x16 + 2 UUID + 4 head + 6 id + 2 tail +
   * name + 1 NUL), so with the 31-byte legacy cap the name fits at most 14 bytes
   * in the scan response and 6 bytes next to the FDEE service-UUID list.
   */
  private buildFdeeServiceData(deviceId: Uint8Array, name: Uint8Array, maxNameLen: number = 14): Uint8Array {
    const head = ByteUtils.fromHex('0102011e');
    const tail = ByteUtils.fromHex('0108');
    const shortName = name.length > maxNameLen ? name.slice(0, maxNameLen) : name;
    return ByteUtils.concat([head, deviceId, tail, shortName, new Uint8Array([0])]);
  }

  private stopAdvertisement(): void {
    if (!this.advertisingActive) {
      return;
    }
    this.advertisingActive = false;
    try {
      ble.stopAdvertising();
    } catch (error) {
      Lg.w(LOG_TAG + ': advertise stop failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 周期重断言广播（自愈）。BLE 广播在 `startAdvertisement` 一次性启动，冷启动蓝牙栈
   * 未就绪、startAdvertising 瞬态失败或被系统挂起后不会自动恢复——表现为「app 先开、
   * Windows 后开搜不到，必须重启 app」。每 30s 做一次 stop+start，30s 内自愈；若蓝牙
   * 仍关闭则跳过，等开启后的下一个周期。
   */
  private startAdvertiseReassertTimer(): void {
    if (this.advertiseTimer > 0) {
      return;
    }
    this.advertiseTimer = setInterval((): void => {
      if (this.active) {
        this.startAdvertisement();
      }
    }, ADVERTISE_REASSERT_INTERVAL_MS);
  }

  private stopAdvertiseReassertTimer(): void {
    if (this.advertiseTimer > 0) {
      clearInterval(this.advertiseTimer);
      this.advertiseTimer = 0;
    }
  }

  /**
   * 探测到 Windows 对端 CDP beacon 时的节流重断言：Windows 打开「就近共享」会开始广播
   * 自己的 CDP beacon，我们收到后立即重发自己的广播，让刚启动扫描的 Windows 尽快看到
   * 手机，不必等 30s 周期、更不必重启 app。10s 内最多触发一次，避免高频 stop/start。
   */
  private requestAdvertiseReassert(): void {
    const now = Date.now();
    if (now - this.lastAdvertiseReassert < ADVERTISE_REASSERT_MIN_GAP_MS) {
      return;
    }
    this.lastAdvertiseReassert = now;
    this.startAdvertisement();
  }

  /**
   * Build the Microsoft CDP beacon carried as manufacturer data 0x0006.
   *
   * maxNameLen bounds the legacy advertisement budget: the manufacturer AD is
   * 15 + nameLen bytes (1 len + 1 type 0xFF + 2 company + 4 head + 6 MAC + name
   * + 1 NUL), and with the 31-byte legacy cap (plus 3-byte flags) the name fits
   * at most 13 bytes in the primary advertisement.
   */
  private buildAdvertisementPayload(macHex: string, maxNameLen: number = 13): Uint8Array {
    const settings = SettingsStore.current();
    const rawName = settings.alias.length > 0 ? settings.alias : 'CashmereLink';
    const nameBytes = ByteUtils.encodeText(rawName);
    const name = nameBytes.length > maxNameLen ? nameBytes.slice(0, maxNameLen) : nameBytes;
    // When the "Windows Nearby 优先 Wi-Fi(TCP)" toggle is ON, set the
    // ExtendedDeviceStatus.WiFiDirectHostingAllowed (0x10) flag so Windows sees
    // the phone as a Wi-Fi-capable host and prefers the TCP(5040) endpoint
    // (advertised via DeviceInfo/presence) instead of staying on RFCOMM.
    const deviceStatus = 0x02 | 0x08 | (settings.wifiUpgradeTcp === true ? 0x10 : 0);
    const head = new Uint8Array([
      GS_NEARSHARE_SCENARIO,
      GS_CDP_DEVICE_TYPE,
      (1 << 5) | 0x01,
      deviceStatus
    ]);
    const mac = ByteUtils.fromHex(macHex.replace(/[-:]/g, '').padEnd(12, '0').slice(0, 12));
    // Microsoft CDP beacons put the BR/EDR address in the manufacturer data with
    // the six bytes REVERSED. Reference clients (Windows and the Android port)
    // reverse the 6-byte address when parsing (see BLeBeacon/ReadPhysicalAddress).
    // Sending canonical order makes the Android reference parse a scrambled
    // address and connect to a non-existent device -> "Bluetooth Socket Exception".
    const macReversed = mac.slice().reverse();
    // The Android parser reads the name as (length - position - 1) bytes, so a
    // trailing NUL keeps the full name (without it the last char is dropped).
    return ByteUtils.concat([head, macReversed, name, new Uint8Array([0])]);
  }

  private buildStableMac(): string {
    // Prefer the real Bluetooth (BR/EDR) MAC the user configured in Settings,
    // because Windows discovers the phone as a Bluetooth device and connects via
    // RFCOMM using this address. A made-up address would break that connection.
    const configured = SettingsStore.current().btMac.trim().replace(/[-:]/g, '').toUpperCase();
    if (configured.length === 12 && /^[0-9A-F]{12}$/.test(configured)) {
      return configured.match(/.{1,2}/g)?.join(':') ?? '00:00:00:00:00:00';
    }
    const seed = deviceInfo.marketName + deviceInfo.productModel + 'windowsnearby';
    let hex = '';
    for (let i = 0; i < seed.length; i++) {
      hex += (seed.charCodeAt(i) & 0xff).toString(16).padStart(2, '0');
    }
    if (hex.length < 12) {
      hex = (hex + '00000000000000000000').slice(0, 12);
    }
    const fake = hex.slice(0, 12).match(/.{1,2}/g)?.join(':') ?? '00:00:00:00:00:00';
    Lg.w(LOG_TAG
      + ': btMac 未填写，正在使用伪造蓝牙地址 ' + fake
      + ' —— Windows Nearby 无法据此通过 RFCOMM 连入，发送文件会“无反应”。'
      + '请在 设置 → Windows Nearby 蓝牙 MAC 地址 中填写手机真实蓝牙地址（非空 12 位十六进制）。');
    return fake;
  }

  private describeScanResult(result: ble.ScanResult): string {
    const dev = result.deviceName !== undefined ? result.deviceName : '';
    // Do NOT log raw advertising/manufacturer/service payloads: those carry the
    // peer's Bluetooth MAC and service UUIDs (device-identifying). Keep only the
    // advertised device name + RSSI for compact, non-identifying diagnostics.
    return 'dev=' + dev + ' rssi=' + result.rssi;
  }

  private extractBeaconPayload(result: ble.ScanResult): Uint8Array | undefined {
    if (result.manufacturerDataMap !== undefined) {
      const mfr = result.manufacturerDataMap.get(GS_CDP_MANUFACTURER_ID);
      if (mfr !== undefined && mfr.length > 0) {
        return mfr;
      }
    }
    if (result.serviceDataMap !== undefined) {
      const fdeeValues: Uint8Array[] = [];
      result.serviceDataMap.forEach((value: Uint8Array, key: string): void => {
        const lowerKey = key.toLowerCase();
        if (lowerKey.indexOf('fdee') >= 0) {
          fdeeValues.push(value);
        }
      });
      for (const fdeeValue of fdeeValues) {
        if (fdeeValue.length > 0) {
          return fdeeValue;
        }
      }
      const serviceValues: Uint8Array[] = [];
      result.serviceDataMap.forEach((value: Uint8Array): void => {
        serviceValues.push(value);
      });
      for (const value of serviceValues) {
        const candidate = this.normalizeBeacon(value);
        if (candidate !== undefined) {
          return candidate;
        }
      }
    }
    if (result.advertisingDataMap !== undefined) {
      const advValues: Uint8Array[] = [];
      result.advertisingDataMap.forEach((value: Uint8Array): void => {
        advValues.push(value);
      });
      for (const value of advValues) {
        const candidate = this.normalizeBeacon(value);
        if (candidate !== undefined) {
          return candidate;
        }
      }
    }
    if (result.data !== undefined) {
      const candidate = this.normalizeBeacon(new Uint8Array(result.data));
      if (candidate !== undefined) {
        return candidate;
      }
    }
    return undefined;
  }

  private normalizeBeacon(value: Uint8Array): Uint8Array | undefined {
    if (value === undefined || value.length === 0) {
      return undefined;
    }
    if (value[0] === GS_NEARSHARE_SCENARIO && value.length >= 10) {
      return value;
    }
    if (value.length >= 4 && value[0] === 0x06 && value[1] === 0x00) {
      const rest = value.slice(2);
      if (rest.length >= 10 && rest[0] === GS_NEARSHARE_SCENARIO) {
        return rest;
      }
    }
    const found = this.findCdpBeacon(value);
    if (found !== undefined && found.length >= 10) {
      return found;
    }
    return undefined;
  }

  private findCdpBeacon(raw: Uint8Array): Uint8Array | undefined {
    for (let i = 0; i + 4 < raw.length; i++) {
      if (raw[i] !== 0xff || raw[i + 1] !== 0x06 || raw[i + 2] !== 0x00) {
        continue;
      }
      const payload = raw.slice(i + 3);
      if (payload.length >= 10 && payload[0] === GS_NEARSHARE_SCENARIO) {
        return payload;
      }
    }
    return undefined;
  }
}
