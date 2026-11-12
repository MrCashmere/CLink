import { ble } from '@kit.ConnectivityKit';

/** 每个上游外设独占一个广播 ID；排队收尾也覆盖仍在等待系统返回 ID 的启动。 */
export class ScopedBleAdvertiser {
  private advertisingId: number = -1;
  private operation: Promise<void> = Promise.resolve();
  start(setting: ble.AdvertiseSetting, mainData: ble.AdvertiseData, response: ble.AdvertiseData): Promise<void> {
    const pending = this.operation.then(async (): Promise<void> => {
      if (this.advertisingId >= 0) { return; }
      this.advertisingId = await ble.startAdvertising({
        advertisingSettings: setting, advertisingData: mainData, advertisingResponse: response
      });
    });
    this.operation = pending.catch((): void => {});
    return pending;
  }
  stop(): Promise<void> {
    const pending = this.operation.then(async (): Promise<void> => {
      if (this.advertisingId < 0) { return; }
      const ownedId = this.advertisingId;
      this.advertisingId = -1;
      await ble.stopAdvertising(ownedId);
    });
    this.operation = pending.catch((): void => {});
    return pending;
  }
}
