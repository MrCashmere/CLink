export const nativeMtaStartServer: (configJson: string) => Promise<string>;
export const nativeExtractLivp: (fd: number, targetDir: string) => Promise<string>;
export const nativeGenerateCdpIdentity: () => Promise<string>;
export const nativeGenerateTlsIdentity: () => Promise<string>;
export const nativeMtaStopServer: () => void;
export const nativeMtaRejectPeer: () => void;
export const nativeGetInterfaceMac: (interfaceName: string) => string;
export const nativeMtaFetchThumbnail: (goIp: string, port: number, taskId: string, targetDir: string,
  connectTimeoutMs: number | undefined, maxBytes: number) => Promise<string>;
export const nativeMtaReceiveDownload: (goIp: string, port: number, taskId: string, targetDir: string,
  totalBytes: number, maxEntries: number, maxTotalBytes: number, maxEntryBytes: number,
  cancelTokenId?: string, connectTimeoutMs?: number, stallTimeoutMs?: number, headerTimeoutMs?: number) => Promise<string>;
export const cancelTransfer: (taskId: string) => void;
export const pollDebugLog: () => string[];
export const registerEventListener: (listener: (error: Error | null, eventJson: string) => void) => void;
