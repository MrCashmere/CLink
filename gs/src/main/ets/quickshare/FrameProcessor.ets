/**
 * Legacy CatShare/private framing compatibility only. QuickShareChannel does
 * not import this module; official Nearby Share uses ProtoWire + WireInbox.
 */
import { GsBytes, encodeFrame, FrameStream, GsRawFrame } from '../util/GsBytes';
import { GsFrameInbox } from '../util/GsFrameInbox';

export enum QuickShareFrameType {
  HANDSHAKE_INIT = 1,
  HANDSHAKE_RESPONSE = 2,
  HANDSHAKE_FINISH = 3,
  AUTH_CODE = 4,
  AUTH_ACK = 5,
  FILE_MANIFEST = 6,
  FILE_DATA = 7,
  FILE_ACK = 8,
  TRANSFER_DONE = 9,
  ERROR = 10
}

export interface QuickShareFrame {
  readonly type: QuickShareFrameType;
  readonly payload: Uint8Array;
}

export class FrameProcessor {
  static encode(type: QuickShareFrameType, payload: Uint8Array): Uint8Array {
    return encodeFrame(type as number, payload);
  }

  static encodeText(type: QuickShareFrameType, value: string): Uint8Array {
    return FrameProcessor.encode(type, GsBytes.encodeText(value));
  }

  static decodeText(frame: QuickShareFrame): string {
    return GsBytes.decodeText(frame.payload);
  }
}

export class FrameDecoder {
  private readonly stream = new FrameStream();

  push(chunk: Uint8Array): QuickShareFrame[] {
    const rawFrames: GsRawFrame[] = this.stream.push(chunk);
    const frames: QuickShareFrame[] = [];
    for (const raw of rawFrames) {
      frames.push({ type: raw.type as QuickShareFrameType, payload: raw.payload });
    }
    return frames;
  }

  reset(): void {
    this.stream.reset();
  }
}

/** Decoder for NearDrop's pure 4-byte-length protobuf framing. */
export class ProtoFrameDecoder {
  private buffer: Uint8Array = new Uint8Array(0);

  push(chunk: Uint8Array): Uint8Array[] {
    this.buffer = GsBytes.concat([this.buffer, chunk]);
    const frames: Uint8Array[] = [];
    while (this.buffer.length >= 4) {
      const length = GsBytes.readU32BE(this.buffer, 0);
      if (length > 32 * 1024 * 1024) {
        throw new Error('protobuf frame exceeds maximum size');
      }
      if (this.buffer.length < length + 4) {
        break;
      }
      frames.push(this.buffer.slice(4, 4 + length));
      this.buffer = this.buffer.slice(4 + length);
    }
    return frames;
  }
}

/**
 * Type-keyed inbox whose `next()` removes its waiter on timeout — this is the
 * frame-eating fix: a timed-out waiter can no longer consume a later frame.
 */
export class FrameInbox {
  private readonly inbox = new GsFrameInbox<QuickShareFrame>();

  deliver(frame: QuickShareFrame): void {
    this.inbox.deliver(frame.type as number, frame);
  }

  next(type: QuickShareFrameType, timeoutMs: number): Promise<QuickShareFrame> {
    return this.inbox.next(type as number, timeoutMs);
  }

  reset(): void {
    this.inbox.reset();
  }
}
