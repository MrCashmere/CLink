import { util } from '@kit.ArkTS';

const textEncoder: util.TextEncoder = new util.TextEncoder();
const textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8');
const FRAME_MAX_BYTES = 32 * 1024 * 1024;

export class GsBytes {
  static encodeText(value: string): Uint8Array {
    return textEncoder.encodeInto(value);
  }

  static decodeText(bytes: Uint8Array): string {
    return textDecoder.decodeToString(bytes);
  }
  // Strip a UTF-8 BOM, control chars and NULs from user-facing strings. Nearby
  // peers sometimes pad the endpoint/file name, which otherwise renders as
  // mojibake (&#xFFFD; or control glyphs) in dialogs.
  static cleanText(value: string): string {
    let out: string = value;
    if (out.charCodeAt(0) === 0xFEFF) {
      out = out.slice(1);
    }
    return out.replace(/[\u0000-\u001F\u007F]/g, '').trim();
  }

  static toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
  }

  static concat(parts: Uint8Array[]): Uint8Array {
    let total = 0;
    for (const part of parts) {
      total += part.length;
    }
    const output = new Uint8Array(total);
    let offset = 0;
    for (const part of parts) {
      output.set(part, offset);
      offset += part.length;
    }
    return output;
  }

  static writeU32BE(value: number): Uint8Array {
    const bytes = new Uint8Array(4);
    bytes[0] = (value >>> 24) & 0xff;
    bytes[1] = (value >>> 16) & 0xff;
    bytes[2] = (value >>> 8) & 0xff;
    bytes[3] = value & 0xff;
    return bytes;
  }

  static readU32BE(bytes: Uint8Array, offset: number): number {
    return ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0;
  }

  static writeU16LE(value: number): Uint8Array {
    const bytes = new Uint8Array(2);
    bytes[0] = value & 0xff;
    bytes[1] = (value >>> 8) & 0xff;
    return bytes;
  }

  static readU16LE(bytes: Uint8Array, offset: number): number {
    return (bytes[offset] | (bytes[offset + 1] << 8)) >>> 0;
  }

  static toHex(bytes: Uint8Array): string {
    let text = '';
    for (let i = 0; i < bytes.length; i++) {
      text += bytes[i].toString(16).padStart(2, '0');
    }
    return text;
  }

  static fromHex(hex: string): Uint8Array {
    const bytes = new Uint8Array(Math.floor(hex.length / 2));
    for (let i = 0; i < bytes.length; i++) {
      bytes[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
    }
    return bytes;
  }
}

export interface GsRawFrame {
  readonly type: number;
  readonly payload: Uint8Array;
}

export function encodeFrame(type: number, payload: Uint8Array): Uint8Array {
  return GsBytes.concat([GsBytes.writeU32BE(payload.length), new Uint8Array([type & 0xff]), payload]);
}

export class FrameStream {
  private buffer: Uint8Array = new Uint8Array(0);

  push(chunk: Uint8Array): GsRawFrame[] {
    this.buffer = GsBytes.concat([this.buffer, chunk]);
    const frames: GsRawFrame[] = [];
    while (this.buffer.length >= 5) {
      const length = GsBytes.readU32BE(this.buffer, 0);
      if (length > FRAME_MAX_BYTES) {
        throw new Error('frame exceeds maximum size');
      }
      if (this.buffer.length < 5 + length) {
        break;
      }
      frames.push({ type: this.buffer[4], payload: this.buffer.slice(5, 5 + length) });
      this.buffer = this.buffer.slice(5 + length);
    }
    return frames;
  }

  reset(): void {
    this.buffer = new Uint8Array(0);
  }
}
