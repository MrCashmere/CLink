export interface QuickShareTcpClient { connect(address: string, port: number, timeoutMs: number): Promise<void>; close(): void; }
