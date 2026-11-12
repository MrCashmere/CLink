import { ble, access } from '@kit.ConnectivityKit';
import { LogCapture } from './LogCapture';

type SharedBleListener = (results: ble.ScanResult[]) => void;

/** 只调度系统扫描资源；协议解析仍由各自原实现完成。 */
export class SharedBleScanLease {
  filters: ble.ScanFilter[] = [];
  active: boolean = false;
  options: ble.ScanOptions = { dutyMode: ble.ScanDuty.SCAN_MODE_BALANCED };
  private listeners: Set<SharedBleListener> = new Set<SharedBleListener>();
  private seen: Map<string, number> = new Map<string, number>();

  on(event: string, listener: SharedBleListener): void { this.listeners.add(listener); }
  off(event: string): void { this.listeners.clear(); }

  start(filters: ble.ScanFilter[], options: ble.ScanOptions): void {
    const previous = this.filters;
    const wasActive = this.active;
    const previousOptions = this.options;
    this.filters = filters;
    this.options = options;
    this.active = true;
    SharedBleScan.add(this);
    try {
      SharedBleScan.refresh();
    } catch (error) {
      this.filters = previous;
      this.active = wasActive;
      this.options = previousOptions;
      if (!wasActive) { SharedBleScan.remove(this); }
      try { SharedBleScan.refresh(); } catch (_) {}
      throw new Error(String(error));
    }
  }

  stop(): void {
    if (!this.active) { return; }
    this.active = false;
    this.seen.clear();
    SharedBleScan.remove(this);
    SharedBleScan.refresh();
  }

  deliver(results: ble.ScanResult[]): void {
    if (!this.active) { return; }
    const now = Date.now();
    const accepted: ble.ScanResult[] = [];
    this.seen.forEach((at: number, key: string): void => {
      if (now - at > 30000) { this.seen.delete(key); }
    });
    for (const result of results) {
      if (this.matches(result) || now - (this.seen.get(result.deviceId) ?? 0) < 30000) {
        if (this.seen.size >= 512 && !this.seen.has(result.deviceId)) { this.seen.clear(); }
        this.seen.set(result.deviceId, now);
        accepted.push(result);
      }
    }
    if (accepted.length === 0) { return; }
    this.listeners.forEach((listener: SharedBleListener): void => {
      try { listener(accepted); } catch (error) { LogCapture.w('[BLE-HUB] listener: ' + String(error)); }
    });
  }

  private matches(result: ble.ScanResult): boolean {
    if (this.filters.length === 0) { return true; }
    return this.filters.some((filter: ble.ScanFilter): boolean => {
      if (filter.deviceId !== undefined && filter.deviceId !== result.deviceId) { return false; }
      if (filter.name !== undefined && filter.name !== result.deviceName) { return false; }
      if (filter.manufactureId !== undefined && !this.hasManufacturer(result, filter.manufactureId)) { return false; }
      if (filter.serviceUuid !== undefined && !this.hasService(result, filter.serviceUuid)) { return false; }
      if (filter.serviceData !== undefined && !this.hasServiceData(result, filter.serviceData, filter.serviceDataMask)) { return false; }
      if (filter.rssiThreshold !== undefined && result.rssi < filter.rssiThreshold) { return false; }
      return true;
    });
  }

  private hasManufacturer(result: ble.ScanResult, id: number): boolean {
    if (result.manufacturerDataMap?.has(id) === true) { return true; }
    const bytes = new Uint8Array(result.data);
    for (let pos = 0; pos < bytes.length;) {
      const len = bytes[pos];
      if (len === 0 || pos + len >= bytes.length) { break; }
      if (bytes[pos + 1] === 0xFF && len >= 3 && (bytes[pos + 2] | (bytes[pos + 3] << 8)) === id) { return true; }
      pos += len + 1;
    }
    return false;
  }

  private hasService(result: ble.ScanResult, uuid: string): boolean {
    const normalized = uuid.toLowerCase();
    if (result.serviceUuids?.some((candidate: string): boolean => candidate.toLowerCase() === normalized) === true) { return true; }
    let found = false;
    result.serviceDataMap?.forEach((data: Uint8Array, key: string): void => {
      if (key.toLowerCase() === normalized) { found = true; }
    });
    if (found) { return true; }
    const short = parseInt(normalized.slice(4, 8), 16);
    const bytes = new Uint8Array(result.data);
    for (let pos = 0; pos < bytes.length;) {
      const len = bytes[pos];
      if (len === 0 || pos + len >= bytes.length) { break; }
      const kind = bytes[pos + 1];
      if ((kind === 0x02 || kind === 0x03 || kind === 0x16) && normalized.endsWith('-0000-1000-8000-00805f9b34fb')) {
        const end = kind === 0x16 ? pos + 4 : pos + len + 1;
        for (let i = pos + 2; i + 1 < end; i += 2) {
          if ((bytes[i] | (bytes[i + 1] << 8)) === short) { return true; }
        }
      }
      if (kind === 0x06 || kind === 0x07 || kind === 0x21) {
        const end = kind === 0x21 ? pos + 18 : pos + len + 1;
        for (let start = pos + 2; start + 15 < end; start += 16) {
          let hex = '';
          for (let i = start + 15; i >= start; i--) { hex += bytes[i].toString(16).padStart(2, '0'); }
          if (hex === normalized.replace(/-/g, '')) { return true; }
        }
      }
      pos += len + 1;
    }
    return false;
  }

  private hasServiceData(result: ble.ScanResult, expected: ArrayBuffer, mask?: ArrayBuffer): boolean {
    const wanted = new Uint8Array(expected);
    const bitmask = mask === undefined ? undefined : new Uint8Array(mask);
    if (bitmask !== undefined && bitmask.length !== wanted.length) { return false; }
    const matches = (data: Uint8Array): boolean => {
      if (data.length < wanted.length) { return false; }
      for (let i = 0; i < wanted.length; i++) {
        const bits = bitmask === undefined ? 0xFF : bitmask[i];
        if ((data[i] & bits) !== (wanted[i] & bits)) { return false; }
      }
      return true;
    };
    let found = false;
    result.serviceDataMap?.forEach((data: Uint8Array): void => { if (matches(data)) { found = true; } });
    if (found) { return true; }
    const bytes = new Uint8Array(result.data);
    for (let pos = 0; pos < bytes.length;) {
      const len = bytes[pos];
      if (len === 0 || pos + len >= bytes.length) { break; }
      const kind = bytes[pos + 1];
      const uuidBytes = kind === 0x16 ? 2 : kind === 0x20 ? 4 : kind === 0x21 ? 16 : 0;
      if (uuidBytes > 0 && len > uuidBytes && matches(bytes.subarray(pos + 2 + uuidBytes, pos + len + 1))) { return true; }
      pos += len + 1;
    }
    return false;
  }
}

class SharedBleScan {
  private static leases: Set<SharedBleScanLease> = new Set<SharedBleScanLease>();
  private static listening: boolean = false;
  private static running: boolean = false;
  private static signature: string = '';
  private static watching: boolean = false;
  private static stateCallback: (state: access.BluetoothState) => void = (state: access.BluetoothState): void => {
    if (state === access.BluetoothState.STATE_OFF) { SharedBleScan.running = false; }
    if (state === access.BluetoothState.STATE_ON || state === access.BluetoothState.STATE_BLE_ON) {
      try { SharedBleScan.refresh(); } catch (error) { LogCapture.w('[BLE-HUB] 蓝牙恢复起扫失败：' + String(error)); }
    }
  };
  private static callback: SharedBleListener = (results: ble.ScanResult[]): void => {
    SharedBleScan.leases.forEach((lease: SharedBleScanLease): void => lease.deliver(results));
  };
  static add(lease: SharedBleScanLease): void { SharedBleScan.leases.add(lease); }
  static remove(lease: SharedBleScanLease): void { SharedBleScan.leases.delete(lease); }
  static refresh(): void {
    const filters: ble.ScanFilter[] = [];
    let wildcard = false;
    let lowLatency = false;
    SharedBleScan.leases.forEach((lease: SharedBleScanLease): void => {
      if (lease.filters.length === 0) { wildcard = true; }
      if (lease.options.dutyMode === ble.ScanDuty.SCAN_MODE_LOW_LATENCY) { lowLatency = true; }
      for (const filter of lease.filters) { filters.push(filter); }
    });
    const signature = SharedBleScan.leases.size === 0 ? '' : JSON.stringify(wildcard ? [] : filters) + ':' + lowLatency;
    if (SharedBleScan.running && signature === SharedBleScan.signature) { return; }
    if (SharedBleScan.running) {
      try { ble.stopBLEScan(); }
      finally { SharedBleScan.running = false; }
    }
    if (SharedBleScan.leases.size === 0) {
      if (SharedBleScan.listening) { ble.off('BLEDeviceFind', SharedBleScan.callback); }
      SharedBleScan.listening = false;
      SharedBleScan.signature = '';
      return;
    }
    if (!SharedBleScan.listening) {
      ble.on('BLEDeviceFind', SharedBleScan.callback);
      SharedBleScan.listening = true;
    }
    if (!SharedBleScan.watching) {
      access.on('stateChange', SharedBleScan.stateCallback);
      SharedBleScan.watching = true;
    }
    ble.startBLEScan(wildcard ? [] : filters, {
      dutyMode: lowLatency ? ble.ScanDuty.SCAN_MODE_LOW_LATENCY : ble.ScanDuty.SCAN_MODE_BALANCED,
      matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE
    });
    SharedBleScan.running = true;
    SharedBleScan.signature = signature;
  }
}
