/**
 * 动态照片「方言选择」回归：认不出对端品牌时，必须写**全方言**（各家私有字段同写）。
 *
 * 真机踩到的 bug（2026-09-10）：对端是 OnePlus/OPPO，但它广播的名字是「皓然的手机」、model 也没
 * 品牌关键字 → `PeerLivePhotoFormat.detect` 认不出 → 回落成 only-Google 的方言 → OPPO 相册不当
 * 自家动态照片（用户实测：没有转成 OPPO 的动态照片格式）。
 *
 * 修法：① 识别失败时方言取 `universal`（OpCamera + XMPhoto/MiCamera + vivo 字段一次全写，
 * 各家只读自己命名空间）；② 日志补上对端 model，便于判断「它到底有没有给品牌线索」。
 *
 * 用法：node tests/dp-format/dialect-universal.mjs
 */
import { build } from './build.mjs';
import { plainJpeg, mp4 } from './fixtures.mjs';

build();
const { LivePhotoWriter } = await import('./build/LivePhotoWriter.mjs');
const { PeerLivePhotoFormat } = await import('./build/PeerLivePhotoFormat.mjs');
const { DynamicPhotoFormat } = await import('./build/DynamicPhotoFormat.mjs');

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

// ---------------------------------------------------------------------------
console.log('方言选择：认不出对端品牌 → 全方言');
{
  const unknown = { name: '皓然的手机', model: '', protocol: 'localsend', deviceType: 'mobile' };
  const decision = PeerLivePhotoFormat.resolve(unknown, PeerLivePhotoFormat.ANDROID);
  check('认不出品牌：平台仍是 unknown', decision.platform, 'unknown');
  check('认不出品牌：格式回落为 android（设置默认）', decision.format, 'android');
  check('认不出品牌：方言 = universal（不再只写 Google）', decision.dialect, 'universal');

  const oppo = { name: 'OnePlus Ace 6T', model: '', protocol: 'localsend', deviceType: 'mobile' };
  const oppoDecision = PeerLivePhotoFormat.resolve(oppo, PeerLivePhotoFormat.ANDROID);
  check('名字里有 OnePlus：认成 OPPO 家族', [oppoDecision.brand, oppoDecision.dialect], ['OPPO', 'oppo']);

  const modelOnly = { name: '皓然的手机', model: 'OnePlus Ace 6T Genshin Impact',
    protocol: 'localsend', deviceType: 'mobile' };
  const modelDecision = PeerLivePhotoFormat.resolve(modelOnly, PeerLivePhotoFormat.ANDROID);
  check('名字没线索但 model 有 OnePlus：也认成 OPPO 家族',
    [modelDecision.brand, modelDecision.dialect], ['OPPO', 'oppo']);

  const fallbackApple = PeerLivePhotoFormat.resolve(unknown, PeerLivePhotoFormat.APPLE);
  check('设置默认是 Apple 时：格式为 apple（方言不影响）', fallbackApple.format, 'apple');
}

// ---------------------------------------------------------------------------
console.log('全方言 XMP：四家字段都在，且容器长度自洽');
{
  const videoLength = 123456;
  const xmp = LivePhotoWriter.buildMotionPhotoXmp(1000, videoLength, 'universal');
  for (const needle of [
    'xmlns:OpCamera="http://ns.oplus.com/photos/1.0/camera/"',
    'xmlns:XMPhoto="http://ns.xiaomi.com/photos/1.0/camera/"',
    'xmlns:MiCamera="http://ns.xiaomi.com/photos/1.0/camera/"',
    'xmlns:vivo="http://ns.vivo.com/photos/1.0/camera/"',
    'OpCamera:MotionPhotoOwner="oplus"',
    'OpCamera:OLivePhotoVersion="2"',
    'XMPhoto:MotionPhotoOwner="xiaomi"',
    'MiCamera:XMPMeta=',
    'vivo:MotionPhotoOwner="vivo"',
    'GCamera:MicroVideoOffset="' + videoLength + '"',
    'Item:Semantic="MotionPhoto"'
  ]) {
    check(`全方言 XMP 含 ${needle.slice(0, 44)}`, xmp.indexOf(needle) >= 0, true);
  }
  const items = DynamicPhotoFormat.parseXmpContainerItems(xmp);
  check('全方言 XMP 的容器目录仍是两段（Primary + MotionPhoto）',
    items.map((i) => i.semantic), ['Primary', 'MotionPhoto']);
  check('MotionPhoto 段长度写的是视频长度',
    items[1].length, videoLength);

  // 单方言仍要各自成立（不能被 universal 抢了）
  const oppoOnly = LivePhotoWriter.buildMotionPhotoXmp(1000, videoLength, 'oppo');
  check('oppo 方言不写小米/vivo 字段',
    [oppoOnly.indexOf('XMPhoto'), oppoOnly.indexOf('vivo:')], [-1, -1]);
  check('oppo 方言仍写 OpCamera 字段', oppoOnly.indexOf('OpCamera:VideoLength') >= 0, true);
  const googleOnly = LivePhotoWriter.buildMotionPhotoXmp(1000, videoLength, 'google');
  check('google 方言不写任何厂商私有字段',
    [googleOnly.indexOf('OpCamera'), googleOnly.indexOf('XMPhoto'), googleOnly.indexOf('vivo:')],
    [-1, -1, -1]);
}

// ---------------------------------------------------------------------------
console.log('全方言落盘：写出的单文件动态照片结构自洽');
{
  const jpeg = plainJpeg(4096);
  const video = mp4(8192);
  const written = LivePhotoWriter.writeAndroidMotionPhoto(jpeg, video, 'universal');
  check('writeAndroidMotionPhoto(universal) 成功', written !== undefined, true);
  if (written !== undefined) {
    const bytes = Buffer.from(written.bytes);
    const xmp = DynamicPhotoFormat.findXmpText(new Uint8Array(bytes), true);
    check('落盘文件里含全方言字段', xmp.indexOf('OpCamera:MotionPhotoOwner') >= 0, true);
    const items = DynamicPhotoFormat.parseXmpContainerItems(xmp);
    check('落盘的容器目录两段', items.map((i) => i.semantic), ['Primary', 'MotionPhoto']);
    // 主图长度 + 视频长度必须正好等于文件长度（XMP 长度自洽迭代的意义）
    const imageLength = DynamicPhotoFormat.jpegEndOffset(new Uint8Array(bytes), 0);
    check('主图 EOI 之后就是视频段', bytes.length - imageLength, video.length);
    check('XMP 里声明的主图长度 = 实际主图长度', items[0].length, imageLength);
  }
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
