// 羊绒互传修改：系统扫描使用独立租约，避免其它协议启停时移除本协议回调。
import { SharedBleScanLease } from '../../common/SharedBleScan';
import { LogCapture as Lg } from '../../common/LogCapture';
import ble from '@ohos.bluetooth.ble';
import { QuickShareDiscoveredDevice } from '../model/DiscoveredDevice';
import { QuickShareAdvertisementParser } from './AdvertisementParser';
import { ByteUtils } from '../../common/ByteUtils';

export type QuickShareDeviceListener = (device: QuickShareDiscoveredDevice) => void;
export type QuickShareFastInitiationListener = () => void;

// The Nearby Fast Initiation signature carried in the FE2C service data.
const FAST_INIT_SIGNATURE: number[] = [0xfc, 0x12, 0x8e];
const FAST_INIT_COOLDOWN_MS = 30000;

export class QuickShareBleScanner {
  private scanLease: SharedBleScanLease = new SharedBleScanLease();
  private readonly parser: QuickShareAdvertisementParser;
  private readonly listener: QuickShareDeviceListener;
  private readonly fastInitiationListener?: QuickShareFastInitiationListener;
  private scanning: boolean = false;
  private lastFastInitAt: number = 0;

  constructor(parser: QuickShareAdvertisementParser, listener: QuickShareDeviceListener, fastInitiationListener?: QuickShareFastInitiationListener) {
    this.parser = parser;
    this.listener = listener;
    this.fastInitiationListener = fastInitiationListener;
  }

  start(): void {
    if (this.scanning) { return; }
    this.scanning = true;
    Lg.i('[QUICKSHARE] BLE scan start (FEF3 serviceData prefix 0x23; filter FE2C/FEF3 in JS)');
    this.scanLease.on('BLEDeviceFind', (results: Array<ble.ScanResult>): void => {
      results.forEach((result: ble.ScanResult): void => {
        const keys: string = result.serviceDataMap === undefined
          ? '<none>'
          : Array.from(result.serviceDataMap.keys()).join(',').toLowerCase();
        const svcUuids: string = (result.serviceUuids ?? []).join('|');
        if (result.serviceDataMap === undefined) {
          // Scan delivered a packet but it carried no Service Data; log so the
          // next run can tell "scan is returning packets" from "is not".
          Lg.i('[QUICKSHARE][BLE scan] device=' + result.deviceId
            + ' no-serviceData svcUuids=' + svcUuids);
          return;
        }
        // Android's Nearby copresence advertisement puts 0xFEF3 ONLY in Service
        // Data (AD type 0x16/0x21), never in the GAP "Service UUID" list. A
        // { serviceUuid: 0xFEF3 } startBLEScan filter matches only that GAP list,
        // so our scanner could never see a stock Android advertiser even though
        // Android discovers us (we advertise serviceUuids AND serviceData). We
        // therefore scan with a Service-Data prefix filter and dispatch on the
        // serviceDataMap key.
        if (keys.indexOf('fe2c') < 0 && keys.indexOf('fef3') < 0) {
          // A 0x23-prefixed service data was reported but it is not FE2C/FEF3;
          // log so we know the filter DID deliver a packet we chose to ignore.
          Lg.i('[QUICKSHARE][BLE scan] device=' + result.deviceId
            + ' unmatched mapKeys=' + keys + ' svcUuids=' + svcUuids);
          return;
        }
        Lg.i('[QUICKSHARE][BLE scan] device=' + result.deviceId
          + ' name=' + (result.deviceName ?? '') + ' rssi=' + result.rssi
          + ' mapKeys=' + keys + ' svcUuids=' + svcUuids);
        result.serviceDataMap.forEach((data: Uint8Array, key: string): void => {
          if (key.toLowerCase().indexOf('fe2c') < 0 && key.toLowerCase().indexOf('fef3') < 0) { return; }
          if (this.isFastInitiation(data)) {
            this.notifyFastInitiation();
            return;
          }
          const device = this.parser.parse(result.deviceId, result.deviceName, result.rssi, data);
          if (device !== undefined) { this.listener(device); }
        });
      });
    });
    // HarmonyOS/OpenHarmony requires a NON-empty filter array ("Requires array
    // length > 0", code 401). We also cannot use { serviceUuid: 0xFEF3 } as the
    // primary filter: that matches only the GAP "Service UUID list" AD, while a
    // stock Android Nearby advertisement carries 0xFEF3 ONLY as Service Data.
    // The FEF3 service-data value starts with 0x23 (PCP/version byte), so we
    // filter on that prefix + a 1-byte mask so the match is by first byte
    // (prefix semantics) rather than by exact total length.
    const filter: Array<ble.ScanFilter> = [{
      serviceData: ByteUtils.toArrayBuffer(new Uint8Array([0x23])),
      serviceDataMask: ByteUtils.toArrayBuffer(new Uint8Array([0xff]))
    }];
    try {
      this.scanLease.start(filter, {
        interval: 500,
        dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
        matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE
      });
    } catch (scanError) {
      // If the serviceData prefix filter is unsupported, fall back to the 0xFEF3
      // service-UUID filter; this still catches any peer that advertises FEF3 as
      // a GAP service UUID (e.g. our own advertising).
      Lg.w('[QUICKSHARE] BLE scan (FEF3 serviceData prefix) failed, fallback to FEF3 serviceUuid: '
        + JSON.stringify(scanError));
      this.scanLease.start([
        { serviceUuid: '0000fef3-0000-1000-8000-00805f9b34fb' }
      ], {
        interval: 500,
        dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
        matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE
      });
    }
  }

  stop(): void {
    if (!this.scanning) { return; }
    this.scanning = false;
    try {
      this.scanLease.stop();
    } catch (error) {
      // Teardown races the BLE service: by the time aboutToDisappear runs, the
      // scanner id can already be invalid (IsValidScannerId transact fails) or the
      // bluetooth permission can be revoked, so stopBLEScan throws a synchronous
      // BusinessError 201. A best-effort stop must never take the page down.
      Lg.w('[QUICKSHARE] BLE stopBLEScan failed: ' + JSON.stringify(error));
    }
    try {
      this.scanLease.off('BLEDeviceFind');
    } catch (error) {
      Lg.w('[QUICKSHARE] BLE off BLEDeviceFind failed: ' + JSON.stringify(error));
    }
  }

  private isFastInitiation(data: Uint8Array): boolean {
    if (data.length < FAST_INIT_SIGNATURE.length) { return false; }
    for (let i = 0; i < FAST_INIT_SIGNATURE.length; i++) {
      if (data[i] !== FAST_INIT_SIGNATURE[i]) { return false; }
    }
    return true;
  }

  private notifyFastInitiation(): void {
    const now = Date.now();
    if (now - this.lastFastInitAt < FAST_INIT_COOLDOWN_MS) { return; }
    this.lastFastInitAt = now;
    if (this.fastInitiationListener !== undefined) {
      this.fastInitiationListener();
    }
  }
}
