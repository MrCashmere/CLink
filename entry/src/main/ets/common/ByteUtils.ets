import { util } from '@kit.ArkTS';

const textEncoder: util.TextEncoder = new util.TextEncoder();
const textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8');
const FRAME_MAX_BYTES = 32 * 1024 * 1024;

export interface RawFrame {
  readonly type: number;
  readonly payload: Uint8Array;
}

export class ByteUtils {
  static encodeText(value: string): Uint8Array {
    const result = textEncoder.encodeInto(value !== undefined ? value : '');
    if (result === undefined) {
      return new Uint8Array(0);
    }
    return result;
  }

  static decodeText(bytes: Uint8Array): string {
    return textDecoder.decodeToString(bytes);
  }

  static toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
    // 构造一个精确长度、独立的新 ArrayBuffer。TLSSocket.send 的 NAPI 层对
    // 共享/切片产生的 ArrayBuffer 可能触发 memcpy_s failed，用全新 buffer 规避。
    const buffer = new ArrayBuffer(bytes.byteLength);
    new Uint8Array(buffer).set(bytes);
    return buffer;
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


  static toBase64(bytes: Uint8Array): string {
    return new util.Base64Helper().encodeToStringSync(bytes);
  }

  static fromBase64(text: string): Uint8Array {
    return new util.Base64Helper().decodeSync(text);
  }
  static indexOf(haystack: Uint8Array, needle: Uint8Array, from: number): number {
    for (let i = from; i + needle.length <= haystack.length; i++) {
      let matched = true;
      for (let j = 0; j < needle.length; j++) {
        if (haystack[i + j] !== needle[j]) {
          matched = false;
          break;
        }
      }
      if (matched) {
        return i;
      }
    }
    return -1;
  }
}

export function encodeFrame(type: number, payload: Uint8Array): Uint8Array {
  return ByteUtils.concat([ByteUtils.writeU32BE(payload.length), new Uint8Array([type & 0xff]), payload]);
}

export class FrameStream {
  private buffer: Uint8Array = new Uint8Array(0);

  push(chunk: Uint8Array): RawFrame[] {
    this.buffer = ByteUtils.concat([this.buffer, chunk]);
    const frames: RawFrame[] = [];
    while (this.buffer.length >= 5) {
      const length = ByteUtils.readU32BE(this.buffer, 0);
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
