export interface QuickShareFileRepository { save(name: string, data: Uint8Array): Promise<string>; }
