/**
 * HTTP 响应解析回归（`HttpBodyParser`）。
 *
 * 真机事故（2026-09-10，用户报「发送失败」）：
 *   对端是官方 LocalSend（Dart 服务端），它的 JSON 响应是 `Transfer-Encoding: chunked`，
 *   **没有 `Content-Length`**。老实现把「没有这个头」当成 0 → 一收到响应头就认为 body 读完 →
 *   `/info` 与 `/prepare-upload` 全是「200 + 空 body」→ 会话解析失败 → 发送失败。
 *   日志原样：
 *     LocalSend send: probe /api/localsend/v2/info -> status 200
 *     LocalSend send: peer info body:
 *     E 羊绒互传 transfer failed: 无法解析对端返回的会话响应:
 *
 * 这个用例覆盖：
 *   1. 有 Content-Length 的普通响应；
 *   2. **chunked** 响应（一次收全 / 分多次收 / 带扩展参数 / 带 trailer / 缺最后 CRLF）；
 *   3. 两者都没有时 `contentLength === -1`（**不是 0**，这是本次 bug 的核心）；
 *   4. 真实 LocalSend `/api/localsend/v2/info` 的 chunked 报文（分片喂入，模拟 socket 回调）。
 *
 * 用法：node tests/http/tests.mjs
 */
import { build } from './build.mjs';

build();
const { HttpBodyParser } = await import('./build/HttpBodyParser.mjs');

let passed = 0;
let failed = 0;
function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) {
    passed += 1;
    console.log(`  ok   ${name}`);
  } else {
    failed += 1;
    console.log(`  FAIL ${name}\n       expected ${e}\n       actual   ${a}`);
  }
}

const enc = new TextEncoder();

// ---------------------------------------------------------------------------
console.log('1) 有 Content-Length 的响应');
{
  const head = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 17\r\nConnection: close';
  check('状态码', HttpBodyParser.parseHead(head).status, 200);
  check('长度', HttpBodyParser.parseHead(head).contentLength, 17);
  check('不是 chunked', HttpBodyParser.parseHead(head).chunked, false);
}

// ---------------------------------------------------------------------------
console.log('2) chunked 响应（官方 LocalSend 的形态）');
{
  const head = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close';
  const parsed = HttpBodyParser.parseHead(head);
  check('识别为 chunked', parsed.chunked, true);
  check('长度未知 = -1（不是 0）', parsed.contentLength, -1);

  const one = Buffer.concat([
    Buffer.from('d\r\n{"alias":"A"}\r\n', 'latin1'),   // 0x0d = 13 字节（"{"alias":"A"}" 正好 13 字节）
    Buffer.from('0\r\n\r\n', 'latin1')
  ]);
  const decoded = HttpBodyParser.decodeChunked(new Uint8Array(one));
  check('一次收全', decoded === undefined ? undefined : Buffer.from(decoded).toString('latin1'), '{"alias":"A"}');

  // 合法的两段式报文：先只喂前半截，解不出来；再喂后半截就解出来了。
  const body = Buffer.concat([
    Buffer.from('d\r\n{"ali', 'latin1'),
    Buffer.from('as":"A"}\r\n0\r\n\r\n', 'latin1')
  ]);
  const splitAt = 9;
  check('分块未收全时返回 undefined（继续等）',
    HttpBodyParser.decodeChunked(new Uint8Array(body.subarray(0, splitAt))), undefined);
  const full = HttpBodyParser.decodeChunked(new Uint8Array(body));
  check('补齐后解出完整 body',
    full === undefined ? undefined : Buffer.from(full).toString('latin1'), '{"alias":"A"}');

  const withExt = Buffer.from('7;foo=bar\r\n{"a":1}\r\n0\r\n\r\n', 'latin1');
  check('块大小带扩展参数',
    Buffer.from(HttpBodyParser.decodeChunked(new Uint8Array(withExt)) ?? []).toString('latin1'), '{"a":1}');

  const withTrailer = Buffer.from('7\r\n{"a":1}\r\n0\r\nX-Trailer: v\r\n\r\n', 'latin1');
  check('结束块之后有 trailer 也能解',
    Buffer.from(HttpBodyParser.decodeChunked(new Uint8Array(withTrailer)) ?? []).toString('latin1'), '{"a":1}');

  const missingFinalCrlf = Buffer.from('7\r\n{"a":1}\r\n0\r\n', 'latin1');
  check('缺最后一个 CRLF 也能解',
    Buffer.from(HttpBodyParser.decodeChunked(new Uint8Array(missingFinalCrlf)) ?? []).toString('latin1'), '{"a":1}');

  const empty = Buffer.from('0\r\n\r\n', 'latin1');
  check('空 body', (HttpBodyParser.decodeChunked(new Uint8Array(empty)) ?? new Uint8Array(1)).length, 0);
}

// ---------------------------------------------------------------------------
console.log('3) 既无 Content-Length 也非 chunked：长度必须是 -1');
{
  const head = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close';
  const parsed = HttpBodyParser.parseHead(head);
  check('contentLength = -1', parsed.contentLength, -1);
  check('chunked = false', parsed.chunked, false);
  check('状态码仍能读出', parsed.status, 200);
}

// ---------------------------------------------------------------------------
console.log('4) 真实 LocalSend /info 响应（chunked，按 socket 分片喂入）');
{
  const info = JSON.stringify({
    alias: '整洁的甜瓜',
    version: '2.0',
    deviceModel: 'OPPO Find X9 Pro',
    deviceType: 'mobile',
    fingerprint: 'ABC123',
    port: 53317,
    protocol: 'http',
    download: true
  });
  const infoBytes = enc.encode(info);
  const chunkSize = 32;
  const frames = [];
  for (let i = 0; i < infoBytes.length; i += chunkSize) {
    const slice = infoBytes.subarray(i, Math.min(infoBytes.length, i + chunkSize));
    frames.push(enc.encode(slice.length.toString(16) + '\r\n'));
    frames.push(slice);
    frames.push(enc.encode('\r\n'));
  }
  frames.push(enc.encode('0\r\n\r\n'));
  const wire = Buffer.concat(frames.map((f) => Buffer.from(f)));
  const head = Buffer.from('HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\n'
    + 'Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n', 'latin1');

  // 模拟客户端的累积逻辑：每来一片就尝试解析，未收全则继续等
  let buffer = new Uint8Array(0);
  let settled = undefined;
  const feed = (bytes) => {
    buffer = new Uint8Array(Buffer.concat([Buffer.from(buffer), Buffer.from(bytes)]));
    const headerEnd = HttpBodyParser.headerEnd(buffer);
    if (headerEnd < 0) {
      return;
    }
    const parsed = HttpBodyParser.parseHead(Buffer.from(buffer.subarray(0, headerEnd)).toString('latin1'));
    if (!parsed.chunked) {
      return;
    }
    const decoded = HttpBodyParser.decodeChunked(buffer.subarray(headerEnd + 4));
    if (decoded !== undefined) {
      settled = Buffer.from(decoded).toString('utf8');
    }
  };
  const stream = Buffer.concat([head, wire]);
  for (let i = 0; i < stream.length; i += 64) {
    feed(stream.subarray(i, Math.min(stream.length, i + 64)));
  }
  check('分片喂入后解出完整 JSON', settled, info);
  const parsedInfo = settled === undefined ? {} : JSON.parse(settled);
  check('别名正确（含中文）', parsedInfo.alias, '整洁的甜瓜');
  check('协议正确', parsedInfo.protocol, 'http');
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) {
  process.exitCode = 1;
}
