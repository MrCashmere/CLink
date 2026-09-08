export interface QuickShareChunk { readonly index: number; readonly offset: number; readonly data: Uint8Array; readonly checksum: number; }

export class QuickShareChunker {
  constructor(readonly chunkSize: number = 64 * 1024) {}
  split(data: Uint8Array): QuickShareChunk[] {
    const chunks: QuickShareChunk[] = [];
    for (let offset = 0, index = 0; offset < data.length; offset += this.chunkSize, index++) {
      const part = data.slice(offset, Math.min(offset + this.chunkSize, data.length));
      chunks.push({ index, offset, data: part, checksum: this.checksum(part) });
    }
    return chunks;
  }
  private checksum(data: Uint8Array): number { let value = 0; data.forEach((item: number): void => { value = (value + item) >>> 0; }); return value; }
}
