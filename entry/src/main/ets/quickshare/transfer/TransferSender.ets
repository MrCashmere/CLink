import { QuickShareChunker } from './Chunk';
import { QuickShareTransferMetadata } from './TransferMetadata';
export interface QuickShareChunkSink { write(chunk: Uint8Array): Promise<void>; }
export class QuickShareTransferSender {
  constructor(private readonly chunker: QuickShareChunker) {}
  async send(data: Uint8Array, metadata: QuickShareTransferMetadata, sink: QuickShareChunkSink, progress: (fraction: number) => void): Promise<void> {
    void metadata;
    const chunks = this.chunker.split(data);
    for (let index = 0; index < chunks.length; index++) { await sink.write(chunks[index].data); progress((index + 1) / chunks.length); }
  }
}
