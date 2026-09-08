export interface QuickShareMdnsService {
  readonly instanceName: string;
  readonly host: string;
  readonly ipv4: string;
  readonly port: number;
  readonly txt: Map<string, string>;
}
