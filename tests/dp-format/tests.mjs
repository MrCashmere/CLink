/**
 * 动态图片解析器的可执行验证套件（Node 端）。
 *
 * 为什么放在 Node 里跑：`DynamicPhotoFormat.ets` / `Isobmff.ets` 是纯字节解析，
 * 不依赖 UI 与文件系统，因此可以把 ArkTS 源码原样转译成 ESM，在 Node 上对
 * 「真实样本 + 合成样本」逐条断言，比在真机上反复试错快得多。
 *
 * 用法：
 *   node tests/dp-format/tests.mjs
 * 可选：把真实样本路径通过环境变量传进来（不存在则跳过对应用例）
 *   DP_SAMPLE_OPPO=<OPPO 实况照片.jpg>
 *   DP_SAMPLE_HEIC=<鸿蒙相机导出的 .heic>
 */
import fs from 'node:fs';
import path from 'node:path';

import { build } from './build.mjs';
import {
  jpegWithXmp, containerXmp, microVideoXmp, mp4, samsungJpeg, plainJpeg, livpZip, movWithChunks
} from './fixtures.mjs';

// 先转译 ArkTS 源码，再动态 import 产物（ESM 的静态 import 会先于 build() 解析）。
build();
const { DynamicPhotoFormat } = await import('./build/DynamicPhotoFormat.mjs');
const { Isobmff } = await import('./build/Isobmff.mjs');
const { LivePhotoWriter } = await import('./build/LivePhotoWriter.mjs');
const { PeerLivePhotoFormat } = await import('./build/PeerLivePhotoFormat.mjs');

const HEAD = 256 * 1024;
const TAIL = 256 * 1024;

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

function probeBuffer(name, buf) {
  const bytes = new Uint8Array(buf);
  const head = bytes.subarray(0, Math.min(bytes.length, HEAD));
  const tailLen = Math.min(bytes.length, TAIL);
  const tailStart = bytes.length - tailLen;
  const tail = bytes.subarray(tailStart, tailStart + tailLen);
  return DynamicPhotoFormat.probe(name, head, tail, tailStart, bytes.length);
}

function summarize(probe) {
  return {
    kind: probe.kind,
    vendor: probe.vendor,
    imageLength: probe.imageLength,
    videoOffset: probe.videoOffset,
    videoLength: probe.videoLength
  };
}

// ---------------------------------------------------------------------------
// 合成样本
// ---------------------------------------------------------------------------
const SMALL_MP4 = mp4(4096);

console.log('容器目录（Google/OPPO 式 Container:Directory）');

// 1. OPPO O-LivePhoto 布局：Primary(Length=0) + GainMap + MotionPhoto，视频远大于尾部窗口。
{
  const primary = plainJpeg(700 * 1024);
  const gainMap = plainJpeg(120 * 1024);
  const video = mp4(1_500_000);
  // 带 XMP 的 Primary 段真实长度 = 原 JPEG + 注入的 APP1 段长度。
  const jpg = jpegWithXmp(primary, containerXmp([
    { mime: 'image/jpeg', semantic: 'Primary', length: 0, padding: 0 },
    { mime: 'image/jpeg', semantic: 'GainMap', length: gainMap.length, padding: 0 },
    { mime: 'video/mp4', semantic: 'MotionPhoto', length: video.length }
  ]));
  const buf = Buffer.concat([jpg, gainMap, video]);
  const p = probeBuffer('IMG_test.jpg', buf);
  check('Primary(0)+GainMap+MotionPhoto：识别为动图', p.kind, 'vendor-motion');
  check('Primary(0)+GainMap+MotionPhoto：厂商', p.vendor, 'OPPO');
  // 图片段只取 Primary（不能把 GainMap 也算进去），视频段正好是尾部 MP4。
  check('Primary(0)+GainMap+MotionPhoto：分段', summarize(p), {
    kind: 'vendor-motion',
    vendor: 'OPPO',
    imageLength: jpg.length,
    videoOffset: jpg.length + gainMap.length,
    videoLength: video.length
  });
  const imageBytes = buf.subarray(0, p.imageLength);
  const videoBytes = buf.subarray(p.videoOffset, p.videoOffset + p.videoLength);
  check('图片段以 EOI 结尾', [imageBytes[0], imageBytes[1], imageBytes[imageBytes.length - 2], imageBytes[imageBytes.length - 1]],
    [0xff, 0xd8, 0xff, 0xd9]);
  check('视频段长度等于文件剩余', p.videoOffset + p.videoLength, buf.length);
  check('视频段以 ftyp box 开头', videoBytes.subarray(4, 8).toString('latin1'), 'ftyp');
}

// 2. 所有段都声明了长度（无 Primary=0），且视频就在尾部窗口内；纯 Google 命名空间。
{
  const primary = plainJpeg(500 * 1024);
  const video = mp4(60 * 1024);
  // XMP 里要写 Primary 的真实长度，而写下长度本身又会改变总长度 → 迭代到不动点。
  let declaredLength = primary.length;
  let jpg = null;
  for (let i = 0; i < 4; i++) {
    jpg = jpegWithXmp(primary, containerXmp([
      { mime: 'image/jpeg', semantic: 'Primary', length: declaredLength, padding: 0 },
      { mime: 'video/mp4', semantic: 'MotionPhoto', length: video.length }
    ], { vendor: 'google' }));
    if (jpg.length === declaredLength) break;
    declaredLength = jpg.length;
  }
  const buf = Buffer.concat([jpg, video]);
  const p = probeBuffer('IMG_declared.jpg', buf);
  check('全声明：识别为动图', p.kind, 'google-motion');
  check('全声明：厂商', p.vendor, 'Google');
  check('全声明：分段', summarize(p), {
    kind: 'google-motion',
    vendor: 'Google',
    imageLength: jpg.length,
    videoOffset: jpg.length,
    videoLength: video.length
  });
}

// 3. 只有一段（Primary）的目录不能当成动图。
{
  const primary = plainJpeg(64 * 1024);
  const buf = jpegWithXmp(primary, containerXmp([
    { mime: 'image/jpeg', semantic: 'Primary', length: 0, padding: 0 }
  ]));
  check('只有 Primary 段：判为普通照片', probeBuffer('IMG_one.jpg', buf).kind, 'none');
}

// 4. 两段长度都未声明 → 无法定位，判为普通照片（宁可漏判不误判）。
{
  const primary = plainJpeg(64 * 1024);
  const buf = jpegWithXmp(primary, containerXmp([
    { mime: 'image/jpeg', semantic: 'Primary', length: 0, padding: 0 },
    { mime: 'video/mp4', semantic: 'MotionPhoto', length: 0 }
  ]));
  check('两段都未声明长度：判为普通照片', probeBuffer('IMG_amb.jpg', buf).kind, 'none');
}

// 5. 声明值有偏差但视频仍在窗口内：容差搜索应能救回来。
{
  const primary = plainJpeg(300 * 1024);
  const video = mp4(40 * 1024);
  const jpg = jpegWithXmp(primary, containerXmp([
    { mime: 'image/jpeg', semantic: 'Primary', length: 0, padding: 0 },
    // 声明值比真实值小 1000 字节（相机改写图片段的情形）
    { mime: 'video/mp4', semantic: 'MotionPhoto', length: video.length - 1000 }
  ]));
  const buf = Buffer.concat([jpg, video]);
  const p = probeBuffer('IMG_drift.jpg', buf);
  check('声明值有偏差：仍能识别', p.kind === 'vendor-motion', true);
  check('声明值有偏差：视频起点落在真实 ftyp 上', p.videoOffset, jpg.length);
}
{
  const primary = plainJpeg(80 * 1024);
  const video = mp4(20 * 1024);
  const jpg = jpegWithXmp(primary, microVideoXmp(video.length));
  const buf = Buffer.concat([jpg, video]);
  const p = probeBuffer('IMG_micro.jpg', buf);
  check('MicroVideoOffset：分段', summarize(p), {
    kind: 'google-motion',
    vendor: 'Google',
    imageLength: jpg.length,
    videoOffset: jpg.length,
    videoLength: video.length
  });
}
{
  const primary = plainJpeg(90 * 1024);
  const video = mp4(30 * 1024);
  const buf = samsungJpeg(primary, video);
  const p = probeBuffer('IMG_sef.jpg', buf);
  check('三星 SEF：识别', p.kind === 'samsung-motion' || p.kind === 'vendor-motion', true);
  check('三星 SEF：视频起点', p.videoOffset, primary.length);
  check('三星 SEF：视频段以 ftyp 开头', Buffer.from(buf.subarray(p.videoOffset, p.videoOffset + 8)).subarray(4, 8).toString('latin1'), 'ftyp');
}

console.log('非动图与 livp');
{
  const buf = plainJpeg(200 * 1024);
  check('普通 JPEG：none', probeBuffer('IMG_plain.jpg', buf).kind, 'none');
}
{
  // XMP 里出现 MotionPhoto 字样，但没有任何视频段：不能误判。
  const primary = plainJpeg(50 * 1024);
  const xmp = '<?xpacket?><x:xmpmeta xmlns:x="adobe:ns:meta/">'
    + '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
    + '<rdf:Description xmlns:GCamera="http://ns.google.com/photos/1.0/camera/" GCamera:MotionPhoto="1"/>'
    + '</rdf:RDF></x:xmpmeta>';
  check('仅声明 MotionPhoto 无视频：none', probeBuffer('IMG_liar.jpg', jpegWithXmp(primary, xmp)).kind, 'none');
}
{
  const buf = livpZip(plainJpeg(40 * 1024), mp4(SMALL_MP4.length));
  check('livp ZIP：harmony-livp', probeBuffer('IMG_live.livp', buf).kind, 'harmony-livp');
}

console.log('写出：Android 标准动态照片（与解析器互为往返）');
{
  const jpeg = plainJpeg(60 * 1024);
  const video = mp4(300 * 1024);
  const written = LivePhotoWriter.writeAndroidMotionPhoto(
    new Uint8Array(jpeg), new Uint8Array(video), 'google');
  check('写出成功', written !== undefined, true);
  const bytes = Buffer.from(written.bytes);
  check('输出总长 = 主图 + 视频', bytes.length, written.primaryLength + video.length);
  check('视频段就是原视频字节',
    bytes.subarray(written.primaryLength).equals(video), true);
  const p = probeBuffer('IMG_motion.jpg', bytes);
  check('往返：识别为动态图片', p.kind === 'google-motion' || p.kind === 'vendor-motion', true);
  check('往返：视频起点 = 主图长度', p.videoOffset, written.primaryLength);
  check('往返：视频长度', p.videoLength, video.length);
  check('往返：图片段以 EOI 结尾',
    [bytes[p.imageLength - 2], bytes[p.imageLength - 1]], [0xff, 0xd9]);
  const head = bytes.subarray(0, 8192).toString('latin1');
  check('XMP 含旧版 MicroVideoOffset 方言', head.includes('GCamera:MicroVideoOffset="' + video.length + '"'), true);
  check('XMP 含新版 Container:Directory', head.includes('Container:Directory'), true);
  check('XMP 声明 Primary 段长度自洽',
    head.includes('Item:Semantic="Primary" Item:Length="' + written.primaryLength + '"'), true);
  check('XMP 声明 MotionPhoto 段', head.includes('Item:Semantic="MotionPhoto"'), true);
}

console.log('写出：按品牌叠加私有方言，且仍能被自家解析器读回');
{
  const jpeg = plainJpeg(24 * 1024);
  const video = mp4(120 * 1024);
  const xmpOf = (dialect) => {
    const written = LivePhotoWriter.writeAndroidMotionPhoto(new Uint8Array(jpeg), new Uint8Array(video), dialect);
    return written === undefined ? '' : Buffer.from(written.bytes).subarray(0, 8192).toString('latin1');
  };
  const oppo = xmpOf('oppo');
  check('OPPO 方言：自家命名空间', oppo.includes('xmlns:OpCamera="http://ns.oplus.com/photos/1.0/camera/"'), true);
  check('OPPO 方言：厂商归属字段', oppo.includes('OpCamera:MotionPhotoOwner="oplus"'), true);
  // 真机 OPPO 自家文件里没有旧版 MicroVideo*（Pixel 也没有）：OPPO 方言只写 Google 的动图声明 + OpCamera。
  check('OPPO 方言：不写旧版 MicroVideo 字段', oppo.includes('GCamera:MicroVideo'), false);
  check('OPPO 方言：仍带 Google 动图声明', oppo.includes('GCamera:MotionPhoto="1"'), true);
  check('OPPO 方言：OpCamera 四件套齐全',
    oppo.includes('OpCamera:OLivePhotoVersion="2"')
    && oppo.includes('OpCamera:MotionPhotoPrimaryPresentationTimestampUs="0"')
    && oppo.includes('OpCamera:VideoLength="'), true);
  const xiaomi = xmpOf('xiaomi');
  check('小米方言：自家命名空间', xiaomi.includes('xmlns:XMPhoto="http://ns.xiaomi.com/photos/1.0/camera/"'), true);
  check('小米方言：厂商归属字段', xiaomi.includes('XMPhoto:MotionPhotoOwner="xiaomi"'), true);
  const vivo = xmpOf('vivo');
  check('vivo 方言：自家命名空间', vivo.includes('xmlns:vivo="http://ns.vivo.com/photos/1.0/camera/"'), true);
  check('vivo 方言：厂商归属字段', vivo.includes('vivo:MotionPhotoOwner="vivo"'), true);
  const samsung = xmpOf('samsung');
  check('三星方言：厂商归属字段', samsung.includes('GCamera:MotionPhotoOwner="samsung"'), true);
  const google = xmpOf('google');
  check('通用方言：不夹带任何厂商字段',
    google.includes('OpCamera') || google.includes('XMPhoto') || google.includes('MotionPhotoOwner'), false);
  // 各家方言都要能被解析器读回，并识别出对应厂商。
  for (const [dialect, vendor] of [['oppo', 'OPPO'], ['xiaomi', 'Xiaomi'], ['vivo', 'vivo'], ['samsung', 'Samsung']]) {
    const written = LivePhotoWriter.writeAndroidMotionPhoto(new Uint8Array(jpeg), new Uint8Array(video), dialect);
    const back = probeBuffer('IMG_' + dialect + '.jpg', Buffer.from(written.bytes));
    check(`${dialect} 方言：解析器读回厂商`, back.vendor, vendor);
    check(`${dialect} 方言：解析器读回分段`,
      [back.videoOffset, back.videoLength], [written.primaryLength, video.length]);
  }
}

console.log('写出：Apple 实况照片（EXIF 标识 + MOV 元数据 + 分片偏移平移）');
{
  const jpeg = plainJpeg(80 * 1024);
  const mov = movWithChunks(8192);
  const identifier = LivePhotoWriter.newIdentifier(20260910);
  check('标识形态（大写 UUID）',
    /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/.test(identifier), true);

  const written = LivePhotoWriter.writeAppleLivePhoto(
    new Uint8Array(jpeg), new Uint8Array(mov.bytes), identifier);
  check('写出成功', written !== undefined, true);

  // 1) 图片侧：用解析器自己的 EXIF 读取路径把标识读回来。
  const image = Buffer.from(written.image);
  const exifPayload = (() => {
    let cursor = 2;
    while (cursor + 4 <= image.length) {
      if (image[cursor] !== 0xff) return -1;
      const marker = image[cursor + 1];
      const length = image.readUInt16BE(cursor + 2);
      if (marker === 0xe1 && image.subarray(cursor + 4, cursor + 10).toString('latin1') === 'Exif\0\0') {
        return cursor + 10; // 跳过 'Exif\0\0'
      }
      if (marker === 0xda) return -1;
      cursor += 2 + length;
    }
    return -1;
  })();
  check('图片含 EXIF APP1', exifPayload > 0, true);
  const view = (offset, length) => new Uint8Array(image.subarray(offset, offset + length));
  check('图片侧 Apple 标识可被解析器读出',
    Isobmff.readAppleContentIdentifier(view, exifPayload, image.length), identifier);
  check('图片原内容仍然完整（EOI 结尾）',
    [image[image.length - 2], image[image.length - 1]], [0xff, 0xd9]);

  // 2) 视频侧：moov 下出现 mdta 元数据，键值一致。
  const video = Buffer.from(written.video);
  const videoView = (offset, length) => new Uint8Array(video.subarray(offset, offset + length));
  const meta = Isobmff.findMoovMeta(videoView, video.length);
  check('视频含 moov/meta', meta !== undefined, true);
  const qtMeta = Isobmff.readQuickTimeMetadata(videoView, meta);
  const index = qtMeta.keys.indexOf('com.apple.quicktime.content.identifier');
  check('mdta 含 content.identifier 键', index >= 0, true);
  check('mdta 的标识与图片侧一致', index >= 0 ? qtMeta.values[index] : '', identifier);
  check('mdta 含 still-image-time 键',
    qtMeta.keys.indexOf('com.apple.quicktime.still-image-time') >= 0, true);

  // 3) 结构：moov 变长后，它后面的 mdat 整体后移，stco 里的分片偏移必须同步平移。
  //    （meta 现在插在 mvhd 之后，所以 stco 自身在新文件里也后移了 —— 按查找定位再比对。）
  const metaLength = video.length - mov.bytes.length;
  check('moov 插入长度 = 文件增长量', metaLength > 0, true);
  const firstStco = (bytes) => {
    const at = bytes.indexOf(Buffer.from('stco', 'latin1'));
    return at < 0 ? -1 : bytes.readUInt32BE(at + 4 + 4 + 4);
  };
  const shifted = firstStco(video);
  check('stco 分片偏移平移了插入长度', shifted - mov.stcoValue, metaLength);
  check('平移后的偏移确实指向 mdat 载荷',
    video.subarray(shifted, shifted + 4).equals(Buffer.alloc(4, 0x22)), true);
  check('ftyp 品牌改为 qt', video.subarray(8, 12).toString('latin1'), 'qt  ');
}

console.log('对端品牌 → 目标格式');
{
  const resolve = (name, model = '', protocol = 'localsend', fallback = 'android') =>
    PeerLivePhotoFormat.resolve({ name, model, protocol }, fallback);
  check('iPhone → Apple 实况照片', resolve('iPhone 15 Pro').format, 'apple');
  check('MacBook → Apple 实况照片', resolve('MacBook Pro').format, 'apple');
  check('iPad → Apple 实况照片', resolve('iPad Air').format, 'apple');
  check('Mac 型号（MacBookPro18,3）→ Apple 实况照片', resolve('MacBookPro18,3').format, 'apple');
  check('Darwin 设备名 → Apple 实况照片', resolve('Darwin').format, 'apple');
  check('小米 → Android 动态照片（小米方言）',
    [resolve('Xiaomi 14').format, resolve('Xiaomi 14').dialect], ['android', 'xiaomi']);
  check('Redmi → 小米方言',
    [resolve('Redmi Note 13').format, resolve('Redmi Note 13').dialect], ['android', 'xiaomi']);
  check('POCO → 小米方言', resolve('POCO F6').dialect, 'xiaomi');
  check('OPPO → OPPO 方言',
    [resolve('OPPO Find X7').format, resolve('OPPO Find X7').dialect], ['android', 'oppo']);
  check('realme → OPPO 方言', resolve('realme GT5').dialect, 'oppo');
  check('一加 → OPPO 方言', resolve('OnePlus 12').dialect, 'oppo');
  check('vivo → vivo 方言',
    [resolve('vivo X100 Pro').format, resolve('vivo X100 Pro').dialect], ['android', 'vivo']);
  check('iQOO → vivo 方言', resolve('iQOO 12').dialect, 'vivo');
  check('三星型号 → 三星方言',
    [resolve('SM-G991B').format, resolve('SM-G991B').dialect], ['android', 'samsung']);
  check('Pixel → 通用方言',
    [resolve('Pixel 8').format, resolve('Pixel 8').dialect], ['android', 'google']);
  check('其它 Android → 通用方言', resolve('Android SDK built for x86').dialect, 'google');
  check('华为 → 不转换', resolve('HUAWEI Mate 60 Pro').format, 'split');
  check('荣耀 → 不转换', resolve('HONOR Magic6').format, 'split');
  check('鸿蒙机型 → 不转换', resolve('HarmonyOS NEXT').format, 'split');
  check('Windows 协议 → 不转换', resolve('LAPTOP-3K6RV3OC', '', 'windowsnearby').format, 'split');
  check('Windows 机器名 → 不转换', resolve('DESKTOP-I9K2L').format, 'split');
  check('本应用 catshare 对端 → 不转换', resolve('羊绒互传', '', 'catshare').format, 'split');
  check('认不出 + 回落 Apple', resolve('Unknown Device', '', 'localsend', 'apple').format, 'apple');
  check('认不出 + 回落 Android', resolve('Unknown Device').format, 'android');
  check('认不出时的理由可追溯', resolve('Unknown Device').reason, 'fallback:android');
  check('品牌识别：Apple', resolve('iPhone 15').brand, 'Apple');
  check('品牌识别：Xiaomi', resolve('Xiaomi 14').brand, 'Xiaomi');
  check('设置项取值归一化', PeerLivePhotoFormat.parseFallback('nonsense'), 'android');
}

// ---------------------------------------------------------------------------
// 结构完整性工具：不依赖本工程的解析器，直接按格式规则检查写出的字节
// （解析器容忍度较高，只靠它无法发现「尺寸字段写错但恰好还能读」这类问题）
// ---------------------------------------------------------------------------

/** 顶层 box 链覆盖的总字节数；链不合法（重叠/越界/size 荒谬）返回 -1。 */
function boxChainLength(bytes, start, end) {
  let cursor = start;
  let guard = 0;
  while (cursor + 8 <= end && guard < 128) {
    let size = bytes.readUInt32BE(cursor);
    if (size === 1) {
      if (cursor + 16 > end) return -1;
      const large = Number(bytes.readBigUInt64BE(cursor + 8));
      if (large < 16) return -1;
      size = large;
    } else if (size === 0) {
      size = end - cursor;
    }
    if (size < 8 || cursor + size > end) return -1;
    cursor += size;
    guard += 1;
  }
  return cursor === end ? end - start : -1;
}

/** JPEG 段链：每段长度字段自洽，返回 APP1 XMP 段的数量（-1 表示段链坏了）。 */
function jpegXmpSegmentCount(bytes, limit) {
  let cursor = 2;
  let xmp = 0;
  let guard = 0;
  while (cursor + 4 <= limit && guard < 256) {
    if (bytes[cursor] !== 0xff) return -1;
    const marker = bytes[cursor + 1];
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      cursor += 2;
      continue;
    }
    const length = bytes.readUInt16BE(cursor + 2);
    if (length < 2 || cursor + 2 + length > limit) return -1;
    if (marker === 0xe1) {
      const payload = bytes.subarray(cursor + 4, cursor + 4 + 29).toString('latin1');
      if (payload.startsWith('http://ns.adobe.com/xap/1.0/')) xmp += 1;
    }
    if (marker === 0xda) return xmp;
    cursor += 2 + length;
    guard += 1;
  }
  return xmp;
}

/** 定位第一个 `Exif\0\0` APP1 的 TIFF 起点；找不到返回 -1。 */
function exifTiffBase(bytes) {
  let cursor = 2;
  while (cursor + 4 <= bytes.length) {
    if (bytes[cursor] !== 0xff) return -1;
    const marker = bytes[cursor + 1];
    const length = bytes.readUInt16BE(cursor + 2);
    if (marker === 0xe1 && bytes.subarray(cursor + 4, cursor + 10).toString('latin1') === 'Exif\0\0') {
      return cursor + 10;
    }
    if (marker === 0xda) return -1;
    cursor += 2 + length;
  }
  return -1;
}

/** 遍历 EXIF 的 IFD 树，返回 { tags, badOffsets }（badOffsets 为越界/超界的偏移）。 */
function exifAudit(bytes, base, limit) {
  const little = bytes[base] === 0x49;
  const u16 = (o) => (little ? bytes[o] | (bytes[o + 1] << 8) : bytes.readUInt16BE(o));
  const u32 = (o) => (little ? bytes.readUInt32LE(o) : bytes.readUInt32BE(o));
  const typeSize = (t) => ([0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8][t] ?? 1);
  const tags = [];
  const badOffsets = [];
  const seen = new Set();
  const readIfd = (relative) => {
    if (relative <= 0 || seen.has(relative)) return;
    seen.add(relative);
    const at = base + relative;
    if (at + 2 > limit) { badOffsets.push(relative); return; }
    const count = u16(at);
    if (count <= 0 || count > 512 || at + 2 + count * 12 + 4 > limit) { badOffsets.push(relative); return; }
    for (let i = 0; i < count; i++) {
      const entry = at + 2 + i * 12;
      const tag = u16(entry);
      const type = u16(entry + 2);
      const items = u32(entry + 4);
      const size = typeSize(type) * items;
      tags.push(tag);
      if (tag === 0x8769 || tag === 0x8825 || tag === 0xa005) {
        readIfd(u32(entry + 8));
        continue;
      }
      if (size > 4) {
        const dataOffset = u32(entry + 8);
        if (base + dataOffset + size > limit || dataOffset <= 0) badOffsets.push(dataOffset);
      }
    }
  };
  const ifd0 = u32(base + 4);
  readIfd(ifd0);
  return { tags, badOffsets };
}

/** moov 内所有 stco/co64 的分片偏移列表。 */
function chunkOffsets(bytes) {
  const boxTypes = ['stco', 'co64'];
  const result = [];
  for (const type of boxTypes) {
    let from = 0;
    for (;;) {
      const at = bytes.indexOf(Buffer.from(type, 'latin1'), from);
      if (at < 0 || at < 4 || bytes.readUInt32BE(at - 4) < 8) break;
      const count = bytes.readUInt32BE(at + 8);
      if (count > 0 && count < 4096) {
        for (let i = 0; i < count; i++) {
          const field = at + 12 + i * (type === 'co64' ? 8 : 4);
          if (field + (type === 'co64' ? 8 : 4) > bytes.length) break;
          result.push(type === 'co64' ? Number(bytes.readBigUInt64BE(field)) : bytes.readUInt32BE(field));
        }
        break;
      }
      from = at + 4;
    }
  }
  return result;
}

console.log('写出的文件结构完整性（独立于解析器的规则检查）');
{
  const jpeg = plainJpeg(48 * 1024);
  const video = mp4(220 * 1024);
  const written = LivePhotoWriter.writeAndroidMotionPhoto(
    new Uint8Array(jpeg), new Uint8Array(video), 'oppo');
  const bytes = Buffer.from(written.bytes);
  check('Android：JPEG 段链自洽（无长度错位）', jpegXmpSegmentCount(bytes, written.primaryLength) >= 0, true);
  check('Android：只有一个 XMP APP1', jpegXmpSegmentCount(bytes, written.primaryLength), 1);
  check('Android：主图以 EOI 结尾',
    [bytes[written.primaryLength - 2], bytes[written.primaryLength - 1]], [0xff, 0xd9]);
  check('Android：追加的视频 box 链正好铺满视频段',
    boxChainLength(bytes, written.primaryLength, bytes.length), bytes.length - written.primaryLength);
  check('Android：视频段以 ftyp 起头',
    bytes.subarray(written.primaryLength + 4, written.primaryLength + 8).toString('latin1'), 'ftyp');
  // 这个用例传的是 `oppo` 方言：真机 OPPO 自家文件里没有旧版 `MicroVideo*`（Pixel 也没有），
  // 所以 OPPO 方言**不写**这些字段，只写 Google 的动图声明 + `OpCamera` 四件套。
  check('Android(oppo 方言)：不写旧版 MicroVideo 字段',
    bytes.subarray(0, 8192).toString('latin1').includes('GCamera:MicroVideo'), false);
  check('Android(oppo 方言)：OpCamera:VideoLength = 视频长度',
    bytes.subarray(0, 8192).toString('latin1').includes('OpCamera:VideoLength="' + video.length + '"'), true);

  const mov = movWithChunks(16 * 1024);
  const identifier = LivePhotoWriter.newIdentifier(31337);
  const apple = LivePhotoWriter.writeAppleLivePhoto(
    new Uint8Array(jpeg), new Uint8Array(mov.bytes), identifier);
  const image = Buffer.from(apple.image);
  const movie = Buffer.from(apple.video);

  // 图片侧：EXIF 段结构 + IFD 树偏移全部落在 APP1 内。
  const tiffBase = exifTiffBase(image);
  check('Apple：写出后仍能找到 EXIF APP1', tiffBase > 0, true);
  const audit = exifAudit(image, tiffBase, image.length);
  check('Apple：EXIF 里没有越界偏移', audit.badOffsets, []);
  check('Apple：EXIF 含 ExifIFD(0x8769) 与 MakerNote(0x927C)',
    [audit.tags.includes(0x8769), audit.tags.includes(0x927c)], [true, true]);
  check('Apple：图片不含 XMP APP1（Apple 侧只靠 EXIF 标识）', jpegXmpSegmentCount(image, image.length), 0);

  // 视频侧：顶层 box 链铺满整个文件、moov 尺寸字段与实际一致、分片偏移落在 mdat 内。
  check('Apple：MOV 顶层 box 链铺满整个文件', boxChainLength(movie, 0, movie.length), movie.length);
  const moovAt = movie.indexOf(Buffer.from('moov', 'latin1')) - 4;
  const moovSize = movie.readUInt32BE(moovAt);
  const nextAt = moovAt + moovSize;
  check('Apple：moov 尺寸字段与下一个 box 对齐',
    nextAt + 4 <= movie.length && ['free', 'mdat', 'moov', 'wide', 'skip'].includes(movie.subarray(nextAt + 4, nextAt + 8).toString('latin1')), true);
  const mdatAt = movie.indexOf(Buffer.from('mdat', 'latin1')) - 4;
  const mdatSize = movie.readUInt32BE(mdatAt) === 1
    ? Number(movie.readBigUInt64BE(mdatAt + 8)) : movie.readUInt32BE(mdatAt);
  const offsets = chunkOffsets(movie);
  check('Apple：分片偏移全部落在 mdat 载荷范围内',
    offsets.length > 0 && offsets.every((o) => o >= mdatAt + 8 && o < mdatAt + mdatSize), true);
  check('Apple：注入的 meta 是 moov 内第一个 meta（否则读取方取不到）',
    (() => {
      const first = movie.indexOf(Buffer.from('meta', 'latin1'));
      const ours = movie.indexOf(Buffer.from('com.apple.quicktime.content.identifier', 'latin1'));
      return first > 0 && ours > first && ours < moovAt + moovSize;
    })(), true);
}

console.log('Apple 成对文件能满足本应用接收侧的「同源」判据');
{
  // 接收侧就是这么配对的：图片侧读 EXIF 标识、视频侧读 mdta 标识，再比对是否同源。
  const makeBytesHolder = (bytes) => ({
    head: new Uint8Array(bytes.subarray(0, Math.min(bytes.length, HEAD))),
    tail: new Uint8Array(bytes.subarray(Math.max(0, bytes.length - TAIL))),
    tailStart: Math.max(0, bytes.length - TAIL),
    holder: { read: (off, len) => new Uint8Array(bytes.subarray(off, off + len)) }
  });
  const makeViewHolder = (bytes) => ({
    read: (off, len) => new Uint8Array(bytes.subarray(off, off + len))
  });
  const auditPair = (label, image, video, expectedId) => {
    const imageId = DynamicPhotoFormat.readImageContentIdentifier(
      makeBytesHolder(image), image.length, 'jpg');
    const videoId = DynamicPhotoFormat.readMovContentIdentifier(makeViewHolder(video), video.length);
    check(`${label}：图片侧标识读回`, imageId, expectedId);
    check(`${label}：视频侧标识读回`, videoId, expectedId);
    check(`${label}：同源判据成立（会被配成一张实况照片）`,
      DynamicPhotoFormat.appleIdentifiersMatch(imageId, videoId), true);
  };

  const jpeg = plainJpeg(64 * 1024);
  const mov = movWithChunks(8192);
  const identifier = LivePhotoWriter.newIdentifier(424242);
  const apple = LivePhotoWriter.writeAppleLivePhoto(
    new Uint8Array(jpeg), new Uint8Array(mov.bytes), identifier);
  auditPair('合成样本', Buffer.from(apple.image), Buffer.from(apple.video), identifier);
}

console.log('拒绝非法输入（宁可退回「图片 + 视频」也不写出坏文件）');
{
  const jpeg = plainJpeg(16 * 1024);
  const video = mp4(64 * 1024);
  check('非 MP4 的“视频”不写 Android 动态照片',
    LivePhotoWriter.writeAndroidMotionPhoto(new Uint8Array(jpeg), new Uint8Array(Buffer.alloc(4096, 0x7a)), 'google') === undefined, true);
  check('非 JPEG 的“图片”不写 Android 动态照片',
    LivePhotoWriter.writeAndroidMotionPhoto(new Uint8Array(Buffer.alloc(4096, 0x7a)), new Uint8Array(video), 'google') === undefined, true);
  check('looksLikeMp4：真 MP4 通过', LivePhotoWriter.looksLikeMp4(new Uint8Array(video)), true);
  check('looksLikeMp4：随机字节不通过',
    LivePhotoWriter.looksLikeMp4(new Uint8Array(Buffer.alloc(4096, 0x11))), false);
  // 没有 moov 的“视频”（只有 ftyp + 随机数据）也要被 Apple 侧拒绝：注入点找不到。
  const ftypOnly = Buffer.concat([video.subarray(0, video.indexOf(Buffer.from('moov', 'latin1')) - 4),
    Buffer.alloc(512, 0x33)]);
  check('缺 moov 的视频不写 Apple 实况照片',
    LivePhotoWriter.writeAppleLivePhoto(new Uint8Array(jpeg), new Uint8Array(ftypOnly), 'X'.repeat(36)) === undefined, true);
}

console.log('真实样本（缺失则跳过）');
for (const [env, label] of [['DP_SAMPLE_OPPO', 'OPPO 实况照片'], ['DP_SAMPLE_HEIC', '鸿蒙相机导出 .heic']]) {
  const file = process.env[env];
  if (!file || !fs.existsSync(file)) {
    console.log(`  skip ${label}（未设置 ${env}）`);
    continue;
  }
  const buf = fs.readFileSync(file);
  const p = probeBuffer(path.basename(file), buf);
  console.log(`  ${label}: ${JSON.stringify(summarize(p))}`);
  if (env === 'DP_SAMPLE_OPPO') {
    check('真实 OPPO：识别为动图', p.kind, 'vendor-motion');
    check('真实 OPPO：厂商', p.vendor, 'OPPO');
    check('真实 OPPO：图片段 + 视频段正好铺满整个文件', p.imageLength + (p.videoOffset - p.imageLength) + p.videoLength, buf.length);
    const imageBytes = buf.subarray(0, p.imageLength);
    check('真实 OPPO：图片段以 EOI 结尾',
      [imageBytes[imageBytes.length - 2], imageBytes[imageBytes.length - 1]], [0xff, 0xd9]);
    const videoBytes = buf.subarray(p.videoOffset, p.videoOffset + 8);
    check('真实 OPPO：视频段以 ftyp 开头', videoBytes.subarray(4, 8).toString('latin1'), 'ftyp');
    check('真实 OPPO：视频段含 moov', buf.subarray(p.videoOffset, p.videoOffset + 65536).indexOf(Buffer.from('moov')) >= 0, true);

    // 用真实字节跑一遍「写出 → 再解析」：真实相机 EXIF（IFD0/ExifIFD/IFD1/GPS）与真实录制
    // MP4（64 位 mdat、多个 trak/stco）都比合成样本苛刻得多 —— 这轮就靠它抓出过 largesize 漏解析。
    const realImage = new Uint8Array(buf.subarray(0, p.imageLength));
    const realVideo = new Uint8Array(buf.subarray(p.videoOffset, p.videoOffset + p.videoLength));

    const android = LivePhotoWriter.writeAndroidMotionPhoto(realImage, realVideo, 'oppo');
    check('真实样本 → Android 动态照片（OPPO 方言）：写出成功', android !== undefined, true);
    const androidBack = probeBuffer('IMG_OPPO_mp.jpg', Buffer.from(android.bytes));
    check('真实样本 → Android 动态照片：往返识别为 OPPO 动态照片',
      [androidBack.kind, androidBack.vendor], ['vendor-motion', 'OPPO']);
    check('真实样本 → Android 动态照片：视频起点 = 主图长度', androidBack.videoOffset, android.primaryLength);
    check('真实样本 → Android 动态照片：视频长度不变', androidBack.videoLength, realVideo.length);

    const identifier = LivePhotoWriter.newIdentifier(7);
    const apple = LivePhotoWriter.writeAppleLivePhoto(realImage, realVideo, identifier);
    check('真实样本 → Apple 实况照片：写出成功', apple !== undefined, true);
    if (apple !== undefined) {
      const image = Buffer.from(apple.image);
      const tiffBase = (() => {
        let cursor = 2;
        while (cursor + 4 <= image.length) {
          if (image[cursor] !== 0xff) return -1;
          const marker = image[cursor + 1];
          const length = image.readUInt16BE(cursor + 2);
          if (marker === 0xe1 && image.subarray(cursor + 4, cursor + 10).toString('latin1') === 'Exif\0\0') {
            return cursor + 10;
          }
          if (marker === 0xda) return -1;
          cursor += 2 + length;
        }
        return -1;
      })();
      const imageView = (offset, length) => new Uint8Array(image.subarray(offset, offset + length));
      check('真实样本 → Apple：图片侧标识读回', tiffBase > 0
        ? Isobmff.readAppleContentIdentifier(imageView, tiffBase, image.length) : '', identifier);
      // 原 EXIF 的条目应当整体保留：对「原图 IFD0/ExifIFD 里的 tag 集合」与写出结果做超集比较。
      const listTags = (bytes, base) => {
        const little = bytes[base] === 0x49;
        const u16 = (o) => (little ? bytes[o] | (bytes[o + 1] << 8) : bytes.readUInt16BE(o));
        const u32 = (o) => (little ? bytes.readUInt32LE(o) : bytes.readUInt32BE(o));
        const tags = [];
        const readIfd = (off) => {
          const count = u16(base + off);
          if (count <= 0 || count > 512) return;
          for (let i = 0; i < count; i++) {
            const at = base + off + 2 + i * 12;
            const tag = u16(at);
            tags.push(tag);
            if (tag === 0x8769 || tag === 0x8825 || tag === 0xa005) readIfd(u32(at + 8));
          }
        };
        readIfd(u32(base + 4));
        return tags;
      };
      const exifTiffBase = (bytes) => {
        let cursor = 2;
        while (cursor + 4 <= bytes.length) {
          if (bytes[cursor] !== 0xff) return -1;
          const marker = bytes[cursor + 1];
          const length = bytes.readUInt16BE(cursor + 2);
          if (marker === 0xe1 && bytes.subarray(cursor + 4, cursor + 10).toString('latin1') === 'Exif\0\0') {
            return cursor + 10;
          }
          if (marker === 0xda) return -1;
          cursor += 2 + length;
        }
        return -1;
      };
      const sourceBase = exifTiffBase(Buffer.from(realImage));
      const sourceTags = sourceBase > 0 ? listTags(Buffer.from(realImage), sourceBase) : [];
      const outTags = listTags(image, tiffBase);
      const missing = sourceTags.filter((tag) => tag !== 0x927c && !outTags.includes(tag));
      check('真实样本 → Apple：原 EXIF 条目全部保留（MakerNote 除外）', missing, []);
      check('真实样本 → Apple：写出后含 Apple MakerNote(0x927C)', outTags.includes(0x927c), true);

      const video = Buffer.from(apple.video);
      const videoView = (offset, length) => new Uint8Array(video.subarray(offset, offset + length));
      const meta = Isobmff.findMoovMeta(videoView, video.length);
      check('真实样本 → Apple：视频含 moov/meta', meta !== undefined, true);
      const qtMeta = Isobmff.readQuickTimeMetadata(videoView, meta);
      const ki = qtMeta.keys.indexOf('com.apple.quicktime.content.identifier');
      check('真实样本 → Apple：mdta 标识与图片侧一致', ki >= 0 ? qtMeta.values[ki] : '', identifier);

      // 分片偏移平移：真实 MP4 用 co64（64 位）且 moov 在 mdat 之前，插入后必须整体后移。
      const firstChunkOffset = (bytes, boxType) => {
        const at = bytes.indexOf(Buffer.from(boxType, 'latin1'));
        if (at < 0) return -1;
        const count = bytes.readUInt32BE(at + 4 + 4);
        if (count <= 0) return -1;
        return boxType === 'co64'
          ? Number(bytes.readBigUInt64BE(at + 4 + 4 + 4))
          : bytes.readUInt32BE(at + 4 + 4 + 4);
      };
      const type = firstChunkOffset(Buffer.from(realVideo), 'co64') >= 0 ? 'co64' : 'stco';
      const before = firstChunkOffset(Buffer.from(realVideo), type);
      const after = firstChunkOffset(video, type);
      const grew = video.length - realVideo.length;
      check('真实样本 → Apple：文件增长 = meta 长度', grew > 0, true);
      check('真实样本 → Apple：' + type + ' 分片偏移按插入长度平移', after - before, grew);
      check('真实样本 → Apple：平移后的偏移仍指向 mdat 载荷内',
        after > 0 && after < video.length, true);
      check('真实样本 → Apple：ftyp 品牌改为 qt', video.subarray(8, 12).toString('latin1'), 'qt  ');
      // 接收侧同源判据（与合成样本同一套断言，只是这次跑在真实字节上）。
      const realHolder = (bytes) => ({
        head: new Uint8Array(bytes.subarray(0, Math.min(bytes.length, HEAD))),
        tail: new Uint8Array(bytes.subarray(Math.max(0, bytes.length - TAIL))),
        tailStart: Math.max(0, bytes.length - TAIL),
        holder: { read: (off, len) => new Uint8Array(bytes.subarray(off, off + len)) }
      });
      const imageId = DynamicPhotoFormat.readImageContentIdentifier(realHolder(image), image.length, 'jpg');
      const videoId = DynamicPhotoFormat.readMovContentIdentifier(
        { read: (off, len) => new Uint8Array(video.subarray(off, off + len)) }, video.length);
      check('真实样本 → Apple：接收侧同源判据成立',
        DynamicPhotoFormat.appleIdentifiersMatch(imageId, videoId), true);
    }
  } else {
    check('真实 heic：交付给应用的文件里确实没有视频段', p.kind, 'none');
  }
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
