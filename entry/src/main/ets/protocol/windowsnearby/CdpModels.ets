export interface CdpEndpoint {
  readonly host: string;
  readonly port: number;
  readonly deviceId: string;
}

export interface CdpCapability {
  readonly name: string;
  readonly version: number;
  readonly enabled: boolean;
}

export interface CdpSession {
  readonly id: string;
  readonly local: CdpEndpoint;
  readonly remote?: CdpEndpoint;
  readonly capabilities: CdpCapability[];
}

export interface CdpTransferMetadata {
  readonly name: string;
  readonly size: number;
  readonly mime: string;
  readonly sha256?: string;
}
