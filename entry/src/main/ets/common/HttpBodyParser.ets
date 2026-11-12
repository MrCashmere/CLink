/**
 * HTTP 响应头的解析 + 分块（chunked）响应体的解码。
 *
 * 为什么单独抽出来（2026-09-10 真机事故）：用户报「发送失败」，日志是
 *
 *   LocalSend send: probe /api/localsend/v2/info -> status 200
 *   LocalSend send: peer info body:            ← 空
 *   LocalSend send: /api/localsend/v2/prepare-upload -> status 200
 *   E 羊绒互传 transfer failed: 无法解析对端返回的会话响应:
 *
 * 对端是官方 LocalSend（Dart 服务端），它对 JSON 响应用的是 `Transfer-Encoding: chunked`，
 * **没有 `Content-Length`**。老代码用 `readContentLength()` 把「没有这个头」当成 `0`，
 * 于是「收到响应头 = 响应体已读完」，body 永远是空的 → 解析会话失败 → 发送失败。
 *
 * 这里把规则写成可测的纯函数（零平台依赖，Node 直接跑用例）：
 *  - `parseHead`：状态码、`Content-Length`（缺失时是 **-1**，绝不是 0）、是否 chunked；
 *  - `decodeChunked`：完整解出返回 body，**没解全返回 undefined**（调用方继续等数据）。
 */

export interface HttpHead {
  readonly status: number;
  /** 响应体字节数；`-1` = 响应头里没有 `Content-Length`（长度未知，不能当 0）。 */
  readonly contentLength: number;
  readonly chunked: boolean;
}

function indexOfBytes(haystack: Uint8Array, needle: Uint8Array, from: number): number {
  if (needle.length === 0 || haystack.length < needle.length) {
    return -1;
  }
  const first = needle[0];
  const last = haystack.length - needle.length;
  for (let i = Math.max(0, from); i <= last; i++) {
    if (haystack[i] !== first) {
      continue;
    }
    let hit = true;
    for (let j = 1; j < needle.length; j++) {
      if (haystack[i + j] !== needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) {
      return i;
    }
  }
  return -1;
}

function decodeAscii(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

function concatBytes(parts: Uint8Array[]): Uint8Array {
  let total = 0;
  for (const part of parts) {
    total += part.length;
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
}

export class HttpBodyParser {
  static readonly CRLF = new Uint8Array([13, 10]);
  static readonly CRLF_CRLF = new Uint8Array([13, 10, 13, 10]);

  /** 头部结束位置（`\r\n\r\n` 的起点）；未收全返回 -1。 */
  static headerEnd(bytes: Uint8Array): number {
    return indexOfBytes(bytes, HttpBodyParser.CRLF_CRLF, 0);
  }

  /** 解析响应头（传入的必须是 `\r\n\r\n` 之前的部分）。 */
  static parseHead(headText: string): HttpHead {
    const lines = headText.split('\r\n');
    const statusLine = lines.length > 0 ? lines[0] : '';
    const statusParts = statusLine.split(' ');
    const statusValue = parseInt(statusParts.length > 1 ? statusParts[1] : '0', 10);
    let contentLength = -1;
    let chunked = false;
    for (const line of lines) {
      const lower = line.toLowerCase();
      if (lower.startsWith('content-length:')) {
        const parsed = parseInt(line.substring(15).trim(), 10);
        contentLength = Number.isNaN(parsed) ? -1 : parsed;
      } else if (lower.startsWith('transfer-encoding:') && lower.indexOf('chunked') >= 0) {
        chunked = true;
      }
    }
    return {
      status: Number.isNaN(statusValue) ? 0 : statusValue,
      contentLength: contentLength,
      chunked: chunked
    };
  }

  /**
   * 解分块编码。**收全了才返回 body**；只要还有块没收全就返回 undefined，让调用方继续等。
   *
   * 兼容：
   *  - 块大小带扩展（`1a;foo=bar`）；
   *  - 结束块 `0\r\n\r\n` 之后还有 trailer 的情况（忽略 trailer）；
   *  - 结束块后缺少最后一个 CRLF（对端提前关连接）。
   */
  static decodeChunked(body: Uint8Array): Uint8Array | undefined {
    const parts: Uint8Array[] = [];
    let at = 0;
    let guard = 0;
    while (guard < 100000) {
      guard++;
      const lineEnd = indexOfBytes(body, HttpBodyParser.CRLF, at);
      if (lineEnd < 0) {
        return undefined;
      }
      const sizeText = decodeAscii(body.slice(at, lineEnd)).split(';')[0].trim();
      const size = parseInt(sizeText, 16);
      if (Number.isNaN(size) || size < 0) {
        return undefined;
      }
      const dataStart = lineEnd + 2;
      if (size === 0) {
        return concatBytes(parts);
      }
      if (body.length < dataStart + size + 2) {
        return undefined;
      }
      parts.push(body.slice(dataStart, dataStart + size));
      at = dataStart + size + 2;
    }
    return undefined;
  }
}
