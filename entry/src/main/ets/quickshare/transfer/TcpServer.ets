export interface QuickShareTcpServer { start(port: number): Promise<void>; stop(): Promise<void>; }
