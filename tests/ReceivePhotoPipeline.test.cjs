// Execute production receive orchestration with deterministic file/media adapters.
// Device decoding and gallery APIs are not emulated as evidence of device success.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.TS_LIB || 'C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const compiled = new Map();
function load(relative, mocks) {
  if (!compiled.has(relative)) {
    compiled.set(relative, ts.transpileModule(fs.readFileSync(path.join(__dirname,
      '../entry/src/main/ets', relative + '.ets'), 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
    }).outputText);
  }
  const exports = {};
  vm.runInNewContext(compiled.get(relative), { exports, require: name => mocks[name] || {},
    Date, setTimeout: () => 0, console }, { filename: relative });
  return exports;
}
const context = { filesDir: '/sandbox/files', cacheDir: '/sandbox/cache' };
function harness(options = {}) {
  const settings = { dynamicPhotoEnabled: true, hdrVividEnabled: true, hdrSkipSystemReencode: false,
    saveReceivedMediaToGallery: true, ...options.settings };
  const disk = new Map();
  const restored = [], queued = [], gallery = [], encoded = [], rewritten = [];
  let serial = 0;
  const log = { i() {}, w() {}, e() {}, flushNow() {} };
  const fileApi = { OpenMode: { READ_ONLY: 0 },
    accessSync: p => disk.has(p), statSync: p => { if (!disk.has(p)) throw Error('missing'); return { size: 2 }; },
    openSync: p => { if (!disk.has(p)) throw Error('missing'); return { fd: p }; }, closeSync() {},
    read: async (p, b) => { new Uint8Array(b).set(disk.get(p)); return 2; },
    renameSync: (src, dst) => { if (options.renameFailure) throw Error('rename failed'); disk.set(dst, disk.get(src)); disk.delete(src); },
    unlinkSync: p => disk.delete(p)
  };
  const { HdrPhotoService: hdr } = load('common/HdrPhotoService', {
    '@ohos.file.fs': { default: fileApi }, './LogCapture': { LogCapture: log },
    './SettingsStore': { SettingsStore: { current: () => settings } },
    './HdrGainMap': { HdrGainMap: { detectLayers: b => ({ gainMap: b[0] ? { end: 1 } : undefined,
      video: b[1] ? {} : undefined, layers: [{ end: 1 }, ...(b[1] ? [{ end: 2 }] : [])] }) } }
  });
  hdr.reencodeForLocal = async (ctx, p) => { encoded.push(p); return undefined; };
  hdr.toVividForLocal = async (ctx, p) => {
    if (options.conversionFailure) throw Error('conversion failed');
    const target = context.cacheDir + '/hdr-' + (++serial) + '.jpg';
    disk.set(target, [2, disk.get(p)[1]]); rewritten.push(p); return target;
  };
  const format = {
    extensionOf: n => n.slice(n.lastIndexOf('.') + 1).toLowerCase(),
    baseNameOf: n => n.slice(0, n.lastIndexOf('.')),
    stripPairMarker: n => n.replace(/\.dp$/i, ''),
    isVideoExtension: e => ['mp4', 'mov'].includes(e),
    isImageExtension: e => ['jpg', 'jpeg', 'heic'].includes(e)
  };
  const key = n => format.stripPairMarker(format.baseNameOf(n));
  const probe = (kind = 'none') => ({ kind, vendor: 'fixture', imageLength: 2,
    videoOffset: kind === 'vendor-motion' ? 2 : -1, imageExtension: 'jpg', videoExtension: 'mp4' });
  const bridge = {
    inSandbox: p => p.startsWith('/sandbox/'), workDir: () => context.cacheDir,
    pendingDir: () => context.filesDir + '/pending', headTailOf: async () => undefined,
    copyFile: async (src, dst) => { if (!disk.has(src)) return 0; disk.set(dst, [...disk.get(src)]); return 2; },
    pairToken: async (p, n) => n.includes('.dp.') ? 'dp:' + key(n) : '',
    probePath: async p => probe(disk.get(p)?.[1] ? 'vendor-motion' : 'none'),
    probeReceived: async (p, n, s, candidates) => {
      if (n.endsWith('.livp')) return { probe: probe('harmony-livp'), videoPath: '' };
      if (disk.get(p)?.[1]) return { probe: probe('vendor-motion'), videoPath: '' };
      const mate = n.includes('.dp.') && candidates.find(c => key(c.name) === key(n)
        && format.isVideoExtension(format.extensionOf(c.name)));
      return { probe: probe(mate ? 'apple-live' : 'none'), videoPath: mate ? mate.path : '' };
    },
    splitForSend: async (ctx, p, n) => {
      const imagePath = context.cacheDir + '/split-' + (++serial) + '.jpg';
      const videoPath = context.cacheDir + '/split-' + serial + '.mp4';
      disk.set(imagePath, [disk.get(p)[0], 0]); disk.set(videoPath, [0, 0]);
      return { split: true, imagePath, videoPath, imageName: n, imageSize: 2 };
    },
    restore: async (ctx, imagePath, videoPath, title) => {
      restored.push({ title, imagePath, videoPath, vivid: disk.get(imagePath)[0] === 2 });
      return { restored: !options.pending, pendingSave: !!options.pending, assetUri: 'media:' + restored.length };
    }
  };
  const { DynamicPhotoService: dynamic } = load('common/DynamicPhotoService', {
    '@ohos.file.fs': { default: fileApi }, './LogCapture': { LogCapture: log },
    './SettingsStore': { SettingsStore: { current: () => settings } },
    './HdrPhotoService': { HdrPhotoService: hdr }, './DynamicPhotoFormat': { DynamicPhotoFormat: format },
    './DynamicPhotoBridge': { DynamicPhotoBridge: bridge, DYNAMIC_PHOTO_PAIR_MARKER: '.dp' },
    './DynamicPhotoStore': { PendingDynamicPhotoStore: { add: p => { queued.push(p); return true; } } }
  });
  const { GalleryMediaClassifier: classifier } = load('quickshare/storage/GalleryMediaClassifier', {});
  const { GalleryAutoSaveService: autoSave } = load('quickshare/service/GalleryAutoSaveService', {
    '../../common/DynamicPhotoService': { DynamicPhotoService: dynamic },
    '../../common/HdrPhotoService': { HdrPhotoService: hdr },
    '../../common/SettingsStore': { SettingsStore: { current: () => settings } },
    '../../common/LogCapture': { LogCapture: log }, '@ohos.file.fs': { default: fileApi },
    './GalleryAuthorizationRequest': { GalleryAuthorizationRequest: { request: async () => true } },
    './GalleryAuthorizationSession': { GalleryAuthorizationSession: { isActive: () => true } },
    '../storage/GalleryMediaClassifier': { GalleryMediaClassifier: classifier },
    '../storage/GalleryMediaRepository': { GalleryMediaRepository: {
      save: async (ctx, p) => { gallery.push({ path: p, vivid: disk.get(p)[0] === 2 }); return { saved: true, uri: 'media:' + p }; }
    } }
  });
  const batch = [];
  async function receive(name, hdrFlag = 0, motionFlag = 0) {
    const file = { name, size: 2, savedPath: context.filesDir + '/incoming/' + name };
    disk.set(file.savedPath, [hdrFlag, motionFlag]); batch.push(file);
    await dynamic.settleReceivedFile(context, file, batch);
    await autoSave.saveStaged(context, file.savedPath, name, 2);
    return file;
  }
  return { settings, disk, dynamic, hdr, autoSave, batch, restored, queued, gallery, encoded, rewritten,
    receive, finish: () => dynamic.settleBatch(context, batch) };
}
function permutations(items) {
  return items.length ? items.flatMap((item, i) => permutations(items.filter((_, j) => i !== j)).map(rest => [item, ...rest])) : [[]];
}

test('120 mixed queue orders: plain/HDR/moving/moving-HDR/video each reach exactly one gallery route', async () => {
  for (const order of permutations([['plain.jpg', 0, 0], ['hdr.jpg', 1, 0], ['live.jpg', 0, 1], ['live-hdr.jpg', 1, 1], ['clip.mp4', 0, 0]])) {
    const h = harness();
    for (const item of order) await h.receive(...item);
    await h.finish(); await h.finish();
    assert.equal(h.restored.length, 2, JSON.stringify(order));
    assert.equal(h.gallery.length, 3, JSON.stringify(order));
    assert.deepEqual(h.restored.filter(p => p.vivid).map(p => p.title), ['live-hdr']);
    assert.equal(h.gallery.filter(p => p.vivid).length, 1);
    assert.equal(h.rewritten.length, 2);
  }
});
test('pending moving photo is queued once, including batch finalization', async () => {
  const h = harness({ pending: true });
  await h.receive('live-hdr.jpg', 1, 1); await h.finish(); await h.finish();
  assert.equal(h.queued.length, 1); assert.equal(h.restored.length, 1); assert.equal(h.gallery.length, 0);
});
test('concurrently completed mixed files keep their own conversion and gallery destination', async () => {
  const h = harness();
  await Promise.all([h.receive('plain.jpg'), h.receive('hdr.jpg', 1),
    h.receive('live.jpg', 0, 1), h.receive('live-hdr.jpg', 1, 1), h.receive('clip.mp4')]);
  await h.finish();
  assert.equal(h.restored.length, 2); assert.equal(h.gallery.length, 3);
  assert.equal(h.rewritten.length, 2);
});
test('all eight dynamic/HDR/gallery switch combinations apply separately within one queue', async () => {
  for (const dynamicPhotoEnabled of [false, true]) {
    for (const hdrVividEnabled of [false, true]) {
      for (const saveReceivedMediaToGallery of [false, true]) {
        const h = harness({ settings: { dynamicPhotoEnabled, hdrVividEnabled, saveReceivedMediaToGallery } });
        await h.receive('plain.jpg'); await h.receive('hdr.jpg', 1);
        await h.receive('live.jpg', 0, 1); await h.receive('live-hdr.jpg', 1, 1); await h.receive('clip.mp4');
        await h.finish();
        assert.equal(h.restored.length, dynamicPhotoEnabled ? 2 : 0);
        assert.equal(h.gallery.length, saveReceivedMediaToGallery ? (dynamicPhotoEnabled ? 3 : 5) : 0);
        assert.equal(h.rewritten.length, hdrVividEnabled ? 2 : 0);
      }
    }
  }
});
for (const videoFirst of [false, true]) {
  test(`paired moving HDR, ${videoFirst ? 'video' : 'image'} first, survives relocation and unrelated files`, async () => {
    const h = harness();
    const first = videoFirst ? ['pair.dp.mp4', 0, 0] : ['pair.dp.jpg', 1, 0];
    const last = videoFirst ? ['pair.dp.jpg', 1, 0] : ['pair.dp.mp4', 0, 0];
    const file = await h.receive(...first);
    h.disk.delete(file.savedPath); // protocol moved it out; only the preserved copy is readable.
    await h.receive('unrelated.jpg'); await h.receive('another-hdr.jpg', 1);
    await h.receive(...last); await h.finish();
    assert.equal(h.restored.length, 1); assert.equal(h.restored[0].vivid, true);
    assert.equal(h.gallery.length, 2, 'pair halves leaked to the ordinary gallery route');
  });
}
test('HDR conversion works with moving-photo and gallery settings both off', async () => {
  const h = harness({ settings: { dynamicPhotoEnabled: false, saveReceivedMediaToGallery: false } });
  assert.equal(h.autoSave.shouldStageForGallery('hdr.jpg'), true);
  const file = await h.receive('hdr.jpg', 1);
  assert.equal(h.disk.get(file.savedPath)[0], 2);
  assert.equal(h.restored.length + h.gallery.length, 0);
});
test('HDR off keeps ordinary and moving images unchanged while restoring motion', async () => {
  const h = harness({ settings: { hdrVividEnabled: false } });
  await h.receive('hdr.jpg', 1); await h.receive('live-hdr.jpg', 1, 1); await h.finish();
  assert.equal(h.rewritten.length, 0); assert.equal(h.restored.length, 1);
  assert.equal(h.restored[0].vivid, false); assert.equal(h.gallery.length, 1);
});
test('HDR-only processing preserves embedded video and avoids the image-only packer', async () => {
  const h = harness({ settings: { dynamicPhotoEnabled: false } });
  const file = await h.receive('live-hdr.jpg', 1, 1);
  assert.equal(h.encoded.length, 0); assert.deepEqual(h.disk.get(file.savedPath), [2, 1]);
});
for (const failure of ['conversionFailure', 'renameFailure']) {
  test(`${failure} preserves the received source and does not stop later queue items`, async () => {
    const h = harness({ [failure]: true });
    const file = await h.receive('hdr.jpg', 1); await h.receive('plain.jpg'); await h.receive('clip.mp4');
    assert.deepEqual(h.disk.get(file.savedPath), [1, 0]); assert.equal(h.gallery.length, 3);
  });
}
test('plain SDR photos never invoke HDR packing or rewriting', async () => {
  const h = harness(); await h.receive('plain.jpg');
  assert.equal(h.encoded.length + h.rewritten.length, 0); assert.equal(h.gallery.length, 1);
});

test('a finished batch cannot claim a matching filename from another session', async () => {
  const h = harness();
  const image = { name: 'same.dp.jpg', size: 2, savedPath: context.filesDir + '/one/same.dp.jpg' };
  const video = { name: 'same.dp.mp4', size: 2, savedPath: context.filesDir + '/two/same.dp.mp4' };
  h.disk.set(image.savedPath, [0, 0]);
  h.disk.set(video.savedPath, [0, 0]);
  await h.dynamic.settleReceivedFile(context, image, [image], 'peer-one');
  await h.dynamic.settleReceivedFile(context, video, [video], 'peer-two');
  assert.equal(h.restored.length, 0);
  assert.equal(h.dynamic.isClaimedByDynamicPhoto(image.savedPath), true);
  await h.dynamic.settleBatch(context, [image], 'peer-one');
  assert.equal(h.dynamic.isClaimedByDynamicPhoto(image.savedPath), false);
  assert.equal(h.dynamic.isClaimedByDynamicPhoto(video.savedPath), true);
  assert.ok(h.disk.has(image.savedPath), 'unpaired original must be kept');
});

test('LIVP is restored as a container even when it has no single video offset', async () => {
  const h = harness();
  await h.receive('moving.livp');
  assert.equal(h.restored.length, 1);
  assert.equal(h.restored[0].title, 'moving');
  assert.equal(h.gallery.length, 0);
});
