/**
 * 动态图片格式解析的自检用例（合成字节，不依赖真机文件）。
 *
 * 与仓库里其它 tests/*.ts 用例一致：导出可直接 await/调用的函数，供 DevEco ohosTest
 * 配置或本地脚本调用。这里覆盖「识别的正确性」与「最关键的误报防护」两类断言。
 *
 * 注意：`DynamicPhotoFormat` 只依赖纯字节数组，不需要 UI / 文件系统上下文。
 */
import { DynamicPhotoFormat } from '../entry/src/main/ets/common/DynamicPhotoFormat';

const TAIL = 256 * 1024;

function ascii(text: string): number[] {
  const out: number[] = [];
  for (let i = 0; i < text.length; i++) {
    out.push(text.charCodeAt(i) & 0xff);
  }
  return out;
}

function concat(parts: number[][]): Uint8Array {
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

/** 造一个最小可用 JPEG 头尾（SOI + APP1 XMP + SOS ... EOI）。 */
function jpegWithXmp(xmp: string, extraTail: number[] = []): Uint8Array {
  const xmpHead = ascii('http://ns.adobe.com/xap/1.0/\u0000');
  const xmpBytes = ascii(xmp);
  const segmentLength = xmpHead.length + xmpBytes.length + 2;
  const app1 = concat([
    [0xff, 0xe1, (segmentLength >> 8) & 0xff, segmentLength & 0xff],
    xmpHead,
    xmpBytes
  ]);
  // 图像数据（扫描段）用若干非 0xFF 字节占位，最后加 EOI。
  const scan = new Array<number>(64).fill(0x20);
  return concat([[0xff, 0xd8], app1, [0xff, 0xda, 0x00, 0x04], scan, [0xff, 0xd9], extraTail]);
}

/** 造一个最小的假 MP4：ftyp box。 */
function fakeMp4(frameBytes: number): number[] {
  const out: number[] = [];
  const size = 16 + frameBytes;
  out.push((size >>> 24) & 0xff, (size >>> 16) & 0xff, (size >>> 8) & 0xff, size & 0xff);
  out.push(...ascii('ftyp'));
  out.push(...ascii('isom'));
  out.push(0, 0, 0, 1); // minor version
  for (let i = 0; i < frameBytes; i++) {
    out.push((i * 7) & 0xff);
  }
  return out;
}

/** 用整份字节做一次探测（head / tail 都传同一份，模拟小文件）。 */
function probeAll(name: string, bytes: Uint8Array) {
  return DynamicPhotoFormat.probe(name, bytes, bytes, 0, bytes.length);
}

/** 1) 旧版 Google MicroVideo：MicroVideoOffset 表示「从末尾数」的视频长度。 */
export function probeGoogleMicroVideo(): boolean {
  const video = fakeMp4(512);
  const xmp = '<x:xmpmeta xmlns:GCamera="http://ns.google.com/photos/1.0/camera/">'
    + '<rdf:Description GCamera:MicroVideo="1" GCamera:MicroVideoVersion="1" '
    + 'GCamera:MicroVideoOffset="' + video.length + '"/></x:xmpmeta>';
  const bytes = jpegWithXmp(xmp, video);
  const probe = probeAll('IMG_0001.jpg', bytes);
  const expectedStart = bytes.length - video.length;
  return probe.kind === 'google-motion'
    && probe.videoOffset === expectedStart
    && probe.imageLength === expectedStart
    && probe.videoExtension === 'mp4';
}

/** 2) 新版 Google Container 目录：各段从偏移 0 依次排布，偏移 = 前序 Length + Padding 之和。 */
export function probeGoogleContainer(): boolean {
  const video = fakeMp4(300);
  const imageLength = 200; // 目录声明的图片段长度（合成文件的真实长度不必相等）
  const xmp = '<x:xmpmeta xmlns:Container="http://ns.google.com/photos/1.0/container/"'
    + ' xmlns:Item="http://ns.google.com/photos/1.0/item/">'
    + '<Container:Directory><rdf:Seq>'
    + '<rdf:li><Container:Item Item:Semantic="Primary" Item:Length="' + imageLength + '" Item:Padding="16"/></rdf:li>'
    + '<rdf:li><Container:Item Item:Semantic="MotionPhoto" Item:Length="' + video.length + '" Item:Padding="0"/></rdf:li>'
    + '</rdf:Seq></Container:Directory></x:xmpmeta>';
  // 真实文件里视频段紧跟图片段（这里图片段声明 200 + 16 padding = 216）。
  const image = new Array<number>(216).fill(0);
  image[0] = 0xff;
  image[1] = 0xd8;
  image[2] = 0xff;
  image[3] = 0xe1;
  const head = jpegWithXmp(xmp);
  const bytes = concat([head, image.slice(head.length), video]);
  const probe = probeAll('IMG_0002.jpg', bytes);
  return probe.kind === 'google-motion';
}

/** 3) 三星 SEF trailer：视频段紧邻 SEFH 之前；没有视频的 SEF 文件必须不误报。 */
export function probeSamsungTrailer(): boolean {
  const video = fakeMp4(256);
  const image = jpegWithXmp('<x:xmpmeta/>');
  const sef = concat([ascii('SEFH'), [0, 0, 0, 1], ascii('SEFT')]);
  const withVideo = concat([image, video, sef]);
  const withoutVideo = concat([image, sef]);
  const ok = probeAll('SAM_0001.jpg', withVideo);
  const bad = probeAll('SAM_0002.jpg', withoutVideo);
  return ok.kind === 'samsung-motion'
    && ok.videoOffset === image.length
    && ok.videoLength === video.length
    && bad.kind === 'none';
}

/** 4) Apple Live Photo 的 MOV 侧标识符可被读出。 */
export function probeAppleIdentifier(): boolean {
  const uuid = '1E9B4C2F-3B2C-4C8A-9E4E-7C2F0A1B5D33';
  const mov = concat([
    fakeMp4(64),
    ascii('com.apple.quicktime.content.identifier'),
    [0, 0, 0, 1, 0, 0, 0, 0],
    ascii(uuid)
  ]);
  const probe = probeAll('IMG_0001.MOV', mov);
  const extracted = DynamicPhotoFormat.extractAppleContentIdentifier(mov);
  return extracted === uuid && probe.kind === 'none';
}

/** 5) 普通照片（无任何动图标记）必须判为 none，且图片段信息被正确回填。 */
export function probePlainPhoto(): boolean {
  const bytes = jpegWithXmp('<x:xmpmeta xmlns:x="adobe:ns:meta/"/>');
  const probe = probeAll('DSC_0001.jpg', bytes);
  return probe.kind === 'none'
    && probe.imageFormat === 'jpeg'
    && probe.videoOffset === -1
    && probe.imageLength === bytes.length;
}

/** 6) MicroVideoOffset 被尾部追加内容污染的坏文件：必须退化为「向前找 ftyp」而不是误判。 */
export function probeCorruptedMicroVideoFallsBack(): boolean {
  const video = fakeMp4(128);
  const wrongOffset = video.length + 40; // 声明值比真实值大 → 直接减会落在视频中间
  const xmp = '<x:xmpmeta xmlns:GCamera="http://ns.google.com/photos/1.0/camera/">'
    + '<rdf:Description GCamera:MicroVideo="1" GCamera:MicroVideoOffset="' + wrongOffset + '"/></x:xmpmeta>';
  const image = jpegWithXmp(xmp);
  const bytes = concat([image, video]);
  const probe = probeAll('IMG_0009.jpg', bytes);
  // 兜底扫描应回到真实的 ftyp 起点。
  return probe.kind !== 'none' && probe.videoOffset === image.length;
}

/** 7) livp（ZIP 容器）被识别为鸿蒙动态照片；fake zip 至少要有本地头 + EOCD。 */
export function probeLivpContainer(): boolean {
  const name = ascii('image.jpg');
  const eocd = concat([ascii('PK\u0005\u0006'), new Array<number>(18).fill(0)]);
  // 中央目录：1 个条目，指向偏移 0 的本地头。
  const central = concat([
    ascii('PK\u0001\u0002'),
    [0x14, 0x00], // version made by
    [0x14, 0x00], // version needed
    [0x00, 0x00], // flags
    [0x00, 0x00], // method = stored
    [0, 0, 0, 0], // time/date
    [0, 0, 0, 0], // crc
    [0x10, 0x00, 0x00, 0x00], // compressed size 16
    [0x10, 0x00, 0x00, 0x00], // uncompressed size 16
    [name.length, 0x00],
    [0x00, 0x00], // extra
    [0x00, 0x00], // comment
    [0x00, 0x00], // disk
    [0x00, 0x00], // internal attrs
    [0, 0, 0, 0], // external attrs
    [0x00, 0x00, 0x00, 0x00], // local header offset
    name
  ]);
  const bytes = concat([ascii('PK\u0003\u0004'), new Array<number>(26).fill(0), central, eocd]);
  const probe = probeAll('IMG_0001.livp', bytes);
  return probe.kind === 'harmony-livp' && probe.vendor === 'HarmonyOS' && probe.videoExtension === 'mp4';
}

/** 8) 扩展名 / basename / 配对标记工具函数。 */
export function formatHelpers(): boolean {
  return DynamicPhotoFormat.extensionOf('a/b/IMG_0001.HEIC') === 'heic'
    && DynamicPhotoFormat.extensionOf('noext') === ''
    && DynamicPhotoFormat.baseNameOf('/x/IMG_0001.dp.jpg') === 'IMG_0001.dp'
    && DynamicPhotoFormat.stripPairMarker('IMG_0001.dp') === 'IMG_0001'
    && DynamicPhotoFormat.stripPairMarker('IMG_0001') === 'IMG_0001'
    && DynamicPhotoFormat.isImageExtension('livp')
    && DynamicPhotoFormat.isVideoExtension('mov')
    && !DynamicPhotoFormat.isVideoExtension('jpg');
}

/** 9) JPEG 的 APP1 XMP 提取（多个 APP 段、含填充 0xFF 的写法）。 */
export function jpegXmpExtraction(): boolean {
  const xmp = '<x:xmpmeta xmlns:GCamera="http://ns.google.com/photos/1.0/camera/" '
    + 'GCamera:MotionPhoto="1" GCamera:MotionPhotoPresentationTimestampUs="-1"/>';
  const bytes = jpegWithXmp(xmp);
  const extract = DynamicPhotoFormat.extractJpegXmp(bytes);
  return extract.indexOf('GCamera:MotionPhoto') >= 0
    && DynamicPhotoFormat.xmpDeclaresMotionPhoto(extract)
    // -1 的时间戳不能被当成尺寸/偏移解析出正值
    && DynamicPhotoFormat.parseXmpVideoHint(extract) === undefined;
}
