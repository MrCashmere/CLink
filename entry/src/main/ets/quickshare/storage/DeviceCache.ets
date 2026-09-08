import { QuickShareDiscoveredDevice } from '../model/DiscoveredDevice';
export class QuickShareDeviceCache {
  private readonly devices: Map<string, QuickShareDiscoveredDevice> = new Map<string, QuickShareDiscoveredDevice>();
  put(device: QuickShareDiscoveredDevice): void { this.devices.set(device.id, device); }
  list(): QuickShareDiscoveredDevice[] { return Array.from(this.devices.values()); }
  clear(): void { this.devices.clear(); }
}
