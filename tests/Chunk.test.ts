import { QuickShareChunker } from '../entry/src/main/ets/quickshare/transfer/Chunk';
export function chunksData(): boolean { return new QuickShareChunker(2).split(new Uint8Array([1, 2, 3])).length === 2; }
