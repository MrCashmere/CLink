export interface QuickShareDiscoveredDevice {
  readonly id: string;
  readonly endpointId: string;
  readonly name: string;
  readonly capabilities: number;
  readonly rssi: number;
  readonly address?: string;
  readonly port?: number;
}
