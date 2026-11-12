// Host regression tests for actual ArkTS services; platform APIs are substituted, no device/gallery access.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.TS_LIB || 'C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '..');
const base = 'entry/src/main/ets/';
const log = { i() {}, w() {}, e() {}, flushNow() {} };
function load(relative, mocks = {}, globals = {}) {
  const source = fs.readFileSync(path.join(root, base, relative + '.ets'), 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
  const exports = {};
  vm.runInNewContext(js, { exports, require(name) {
    if (name in mocks) return mocks[name];
    if (name.endsWith('LogCapture')) return { LogCapture: log };
    return {};
  }, console, setTimeout, clearTimeout, ...globals }, { filename: relative });
  return exports;
}
const { GalleryMediaClassifier: classifier } = load('quickshare/storage/GalleryMediaClassifier');
const context = { filesDir: '/sandbox/files', cacheDir: '/sandbox/cache' };
function service(options = {}) {
  let enabled = options.enabled ?? true;
  let active = options.active ?? true;
  let authorizationRequests = 0;
  const calls = [];
  const results = options.saveResults ? [...options.saveResults] : [];
  const repository = {
    async save() { calls.push('gallery'); return results.shift() || options.saveResult || { saved: true, uri: 'file://media/Photo/123', permissionDenied: false, error: '' }; },
    async copyToDownload() { calls.push('download'); return options.fallbackResult || { copied: true, path: '/Download/media.jpg', error: '' }; },
    isSandboxPath: () => true
  };
  const dynamic = options.dynamic || { isClaimedByDynamicPhoto: () => false, wasHandledForGallery: () => false, enabled: () => false };
  const { GalleryAutoSaveService: api } = load('quickshare/service/GalleryAutoSaveService', {
    '../../common/SettingsStore': { SettingsStore: { current: () => ({ saveReceivedMediaToGallery: enabled }) } },
    '../../common/DynamicPhotoService': { DynamicPhotoService: dynamic },
    '../../common/HdrPhotoService': { HdrPhotoService: { enabled: () => options.hdrEnabled === true } },
    '../storage/GalleryMediaClassifier': { GalleryMediaClassifier: classifier },
    '../storage/GalleryMediaRepository': { GalleryMediaRepository: repository },
    './GalleryAuthorizationSession': { GalleryAuthorizationSession: { isActive: () => active, invalidate: () => { active = false; } } },
    './GalleryAuthorizationRequest': { GalleryAuthorizationRequest: { request: async () => {
      if (active) return true;
      authorizationRequests++;
      const granted = options.authorize ? await options.authorize() : false;
      if (granted) active = true;
      return granted;
    } } },
    '@ohos.file.fs': { default: { accessSync: () => true, unlinkSync: p => calls.push('delete:' + p) } }
  });
  return { api, calls, get active() { return active; }, get authorizationRequests() { return authorizationRequests; },
    setEnabled: value => { enabled = value; } };
}
test('classifier excludes documents, archives, source code and explicit text MIME', () => {
  for (const name of ['notes.pdf', 'archive.zip', 'app.apk', 'song.mp3', 'script.ts']) assert.equal(classifier.classify(name).kind, 'other');
  assert.equal(classifier.classify('fake.jpg', 'text/plain').kind, 'other');
  assert.equal(classifier.classify('PHOTO.JPG').kind, 'image');
  assert.equal(classifier.classify('movie.MOV').kind, 'video');
});
test('switch alone controls staging, authorization waits until media arrives', () => {
  assert.equal(service({ enabled: false }).api.shouldStageForGallery('a.jpg'), false);
  const expired = service({ active: false });
  assert.equal(expired.api.shouldStageForGallery('a.mp4'), true);
  assert.equal(expired.authorizationRequests, 0);
  assert.equal(service().api.shouldStageForGallery('a.mp4'), true);
});
test('ordinary image and video both reach the gallery repository', async () => {
  for (const name of ['a.jpg', 'b.mp4']) {
    const h = service();
    const result = await h.api.processCompleted(context, context.filesDir + '/incoming/quickshare/' + name, name, 5, true);
    assert.equal(result.savedToGallery, true);
    assert.equal(result.finalPath, 'file://media/Photo/123');
    assert.equal(h.calls.includes('download'), false);
    assert.equal(h.calls.length, 2);
  }
});
test('authorization expiry before completion falls back to download', async () => {
  const h = service({ active: false });
  const result = await h.api.processCompleted(context, context.filesDir + '/incoming/quickshare/a.jpg', 'a.jpg', 5, true);
  assert.equal(result.finalPath, '/Download/media.jpg');
  assert.equal(h.calls[0], 'download');
});
test('closing the switch during a transfer falls back to download', async () => {
  const h = service({ enabled: false });
  await h.api.processCompleted(context, context.filesDir + '/incoming/quickshare/a.jpg', 'a.jpg', 5, true);
  assert.equal(h.calls[0], 'download');
});
test('permission rejection invalidates authorization and falls back', async () => {
  const h = service({ saveResult: { saved: false, uri: '', permissionDenied: true, error: '201' } });
  const result = await h.api.processCompleted(context, context.filesDir + '/incoming/quickshare/a.jpg', 'a.jpg', 5, true);
  assert.equal(h.active, false);
  assert.equal(result.savedToGallery, false);
  assert.equal(h.calls[1], 'download');
});
test('if gallery and download fail, source file is preserved', async () => {
  const source = context.filesDir + '/incoming/quickshare/a.jpg';
  const h = service({ saveResult: { saved: false, error: 'disk full' }, fallbackResult: { copied: false, path: source, error: 'picker failed' } });
  assert.equal((await h.api.processCompleted(context, source, 'a.jpg', 5, true)).finalPath, source);
  assert.equal(h.calls.length, 2);
});
test('LocalSend gallery URI handoff is consumed once', async () => {
  const h = service();
  const source = context.filesDir + '/incoming/a.jpg';
  assert.equal((await h.api.saveStaged(context, source, 'a.jpg', 5)).savedToGallery, true);
  assert.equal(h.api.galleryUriForSourcePath(source), 'file://media/Photo/123');
  assert.equal(h.api.galleryUriForSourcePath(source), '');
});
test('authorization expires at 55 seconds and resets on app startup', () => {
  let now = 1000;
  const storage = new Map();
  const { GalleryAuthorizationSession: auth } = load('quickshare/service/GalleryAuthorizationSession', {}, {
    Date: { now: () => now }, setTimeout: () => 1, clearTimeout() {},
    AppStorage: { setOrCreate: (key, value) => storage.set(key, value) }
  });
  auth.activate(); assert.equal(auth.isActive(), true);
  now += 55000; assert.equal(auth.isActive(), false);
  auth.activate(); auth.resetForAppStart(); assert.equal(auth.isActive(), false);
  assert.equal(storage.get('galleryAuthorizationActive'), false);
});
test('gallery preference persists, survives reload and unrelated settings save', async () => {
  const disk = new Map();
  const store = { get: async (k, d) => disk.has(k) ? disk.get(k) : d, put: async (k, v) => disk.set(k, v), flush: async () => {} };
  const mocks = { '@ohos.data.preferences': { default: { getPreferences: async () => store } },
    '../quickshare/model/TransportPolicy': load('quickshare/model/TransportPolicy') };
  const globals = { AppStorage: { setOrCreate() {} } };
  const { SettingsStore: settings } = load('common/SettingsStore', mocks, globals);
  await settings.setSaveReceivedMediaToGallery(context, true);
  assert.equal(settings.current().saveReceivedMediaToGallery, true);
  const { SettingsStore: reloaded } = load('common/SettingsStore', mocks, globals);
  const current = await reloaded.load(context);
  assert.equal(current.saveReceivedMediaToGallery, true);
  await reloaded.save(context, { alias: 'updated', requirePin: true, alwaysVisible: false });
  assert.equal(reloaded.current().saveReceivedMediaToGallery, true);
  assert.equal(disk.get('saveReceivedMediaToGallery'), true);
});
test('MIME-only media staged by Quick Share is saved; missing MIME still falls back', async () => {
  const h = service();
  assert.equal(h.api.shouldStageForGallery('clip.ts', 'video/mp2t'), true);
  const result = await h.api.processCompleted(context, context.filesDir + '/incoming/quickshare/clip.ts', 'clip.ts', 5, true);
  assert.ok(result.savedToGallery || h.calls.includes('download'), 'staged MIME-only media was left in the sandbox without either destination');
  const withMime = service();
  assert.equal((await withMime.api.processCompleted(context, context.filesDir + '/incoming/quickshare/clip.ts',
    'clip.ts', 5, true, 'video/mp2t')).savedToGallery, true);
  assert.equal((await service().api.processCompleted(context, context.filesDir + '/incoming/quickshare/photo',
    'photo', 5, true, 'image/jpeg')).savedToGallery, true);
});
test('an old dynamic photo cannot suppress a later same-name ordinary photo', async () => {
  // pairKey uses these two pure helpers, copied verbatim in behavior; all claim bookkeeping is production code.
  const format = { baseNameOf(name) { const base = name.slice(name.lastIndexOf('/') + 1); const dot = base.lastIndexOf('.'); return dot > 0 ? base.slice(0, dot) : base; },
    stripPairMarker(name) { return name.toLowerCase().endsWith('.dp') ? name.slice(0, -3) : name; } };
  let dynamicEnabled = true;
  const { DynamicPhotoService: dynamic } = load('common/DynamicPhotoService', {
    './DynamicPhotoFormat': { DynamicPhotoFormat: format },
    './SettingsStore': { SettingsStore: { current: () => ({ dynamicPhotoEnabled: dynamicEnabled }) } }
  });
  const oldPath = context.filesDir + '/old-session/IMG_0001.dp.jpg';
  dynamic.markHandledForGallery(oldPath);
  assert.equal(dynamic.isClaimedByDynamicPhoto(oldPath), true);
  assert.equal(dynamic.isClaimedByDynamicPhoto(context.filesDir + '/new-session/IMG_0001.jpg'), false);
  dynamicEnabled = false;
  assert.equal(dynamic.isClaimedByDynamicPhoto(oldPath), false);
  const h = service({ dynamic });
  const result = await h.api.saveStaged(context, context.filesDir + '/new-session/IMG_0001.jpg', 'IMG_0001.jpg', 5);
  assert.equal(result.savedToGallery, true, 'stale basename claim suppressed a new ordinary photo');
});
test('download fallback preserves existing files and resolves concurrent name collisions', async () => {
  const scratch = path.join(__dirname, '.test'); fs.mkdirSync(scratch, { recursive: true });
  const dir = fs.mkdtempSync(path.join(scratch, 'gallery-collision-'));
  const incoming = path.join(dir, 'incoming.jpg');
  const download = path.join(dir, 'Download'); fs.mkdirSync(download);
  const existing = path.join(download, 'photo.jpg');
  fs.writeFileSync(incoming, 'NEW'); fs.writeFileSync(existing, 'OLD-CONTENT');
  const fileApi = { ...fs, OpenMode: { READ_ONLY: fs.constants.O_RDONLY, READ_WRITE: fs.constants.O_RDWR, CREATE: fs.constants.O_CREAT, TRUNC: fs.constants.O_TRUNC },
    openSync: (p, flags) => ({ fd: fs.openSync(p, flags) }), closeSync: f => fs.closeSync(typeof f === 'number' ? f : f.fd),
    read: async (fd, b) => fs.readSync(fd, Buffer.from(b), 0, b.byteLength, null),
    write: async (fd, b) => fs.writeSync(fd, Buffer.from(b)), accessSync: p => fs.existsSync(p),
    mkdtempSync: prefix => fs.mkdtempSync(prefix.replace(/XXXXXX$/, '')),
    moveFile: async (src, dest, mode) => {
      assert.equal(mode, 1, 'publishing must reject an existing target');
      try { fs.copyFileSync(src, dest, fs.constants.COPYFILE_EXCL); fs.unlinkSync(src); }
      catch (error) { if (error.code === 'EEXIST') throw { code: 13900015 }; throw error; }
    } };
  const { GalleryMediaRepository: repo } = load('quickshare/storage/GalleryMediaRepository', {
    '@ohos.file.fs': { default: fileApi },
    '@kit.CoreFileKit': { picker: { DocumentSaveOptions: class {}, DocumentPickerMode: { DOWNLOAD: 1 },
      DocumentViewPicker: class { async save() { return ['file://download']; } } }, fileUri: { FileUri: class { constructor() { this.path = download; } } } }
  });
  const localContext = { ...context, cacheDir: dir };
  const [result, second] = await Promise.all([
    repo.copyToDownload(localContext, incoming, 'photo.jpg'), repo.copyToDownload(localContext, incoming, 'photo.jpg')]);
  assert.equal(result.copied, true);
  assert.equal(second.copied, true);
  assert.notEqual(result.path, second.path);
  assert.equal(fs.readFileSync(existing, 'utf8'), 'OLD-CONTENT', 'fallback truncated and overwrote the old file');
  assert.equal(fs.readFileSync(result.path, 'utf8'), 'NEW');
  assert.equal(fs.readFileSync(second.path, 'utf8'), 'NEW');
  assert.equal(fs.readFileSync(incoming, 'utf8'), 'NEW');
  assert.equal(fs.readdirSync(dir).some(name => name.startsWith('gallery-fallback-')), false);
  fileApi.moveFile = async () => { throw { code: 13900025, message: 'disk full' }; };
  const failed = await repo.copyToDownload(localContext, incoming, 'photo.jpg');
  assert.equal(failed.copied, false);
  assert.equal(failed.path, incoming);
  assert.equal(fs.readFileSync(incoming, 'utf8'), 'NEW');
  assert.equal(fs.readFileSync(existing, 'utf8'), 'OLD-CONTENT');
  assert.equal(fs.readdirSync(dir).some(name => name.startsWith('gallery-fallback-')), false);
});

test('non-media staged before classification is returned to downloads without gallery access', async () => {
  const h = service();
  const result = await h.api.processCompleted(context, context.filesDir + '/incoming/quickshare/a.jpg',
    'a.jpg', 5, true, 'text/plain');
  assert.equal(result.savedToGallery, false);
  assert.equal(h.calls[0], 'download');
  assert.equal(h.calls.includes('gallery'), false);
});

test('a reused source path is reclassified and stale claims expire', async () => {
  let now = 1000;
  const { DynamicPhotoService: dynamic } = load('common/DynamicPhotoService', {
    './HdrPhotoService': { HdrPhotoService: { convertReceivedInPlace: async () => {} } },
    './SettingsStore': { SettingsStore: { current: () => ({ dynamicPhotoEnabled: true }) } },
    './DynamicPhotoFormat': { DynamicPhotoFormat: { extensionOf: () => 'pdf', isVideoExtension: () => false, isImageExtension: () => false } }
  }, { Date: { now: () => now } });
  const source = context.filesDir + '/incoming/reused.jpg';
  dynamic.markHandledForGallery(source);
  assert.equal(dynamic.isClaimedByDynamicPhoto(source), true);
  await dynamic.settleReceivedFile(context, { savedPath: source, name: 'reused.jpg', size: 5 }, []);
  assert.equal(dynamic.isClaimedByDynamicPhoto(source), false);
  dynamic.markHandledForGallery(source);
  now += 300001;
  assert.equal(dynamic.isClaimedByDynamicPhoto(source), false);
});

function mtaHarness(options = {}) {
  let next = 0;
  const dynamic = options.dynamic || {
    enabled: () => false,
    isClaimedByDynamicPhoto: () => false, wasHandledForGallery: () => false,
    settleReceivedFile: async () => {}, settleBatch: async () => {}
  };
  const h = service({ ...options, dynamic });
  const { MtaGalleryService: mta } = load('mta/MtaGalleryService', {
    '@kit.CoreFileKit': { fileIo: { accessSync: () => true, mkdirSync() {}, mkdtempSync: prefix => prefix.replace('XXXXXX', String(++next)) } },
    '../common/DynamicPhotoService': { DynamicPhotoService: dynamic },
    '../common/HdrPhotoService': { HdrPhotoService: { enabled: () => options.hdrEnabled === true } },
    '../quickshare/service/GalleryAutoSaveService': { GalleryAutoSaveService: h.api }
  });
  return { ...h, mta };
}
test('MTA stages when enabled even without authorization, with separate batch directories', () => {
  assert.equal(mtaHarness({ enabled: false }).mta.receiveDirectory(context, '/Download'), '/Download');
  assert.match(mtaHarness({ active: false }).mta.receiveDirectory(context, '/Download'), /\/incoming\/mta\/batch-/);
  const h = mtaHarness();
  const first = h.mta.receiveDirectory(context, '/Download');
  assert.match(first, /\/incoming\/mta\/batch-/);
  assert.notEqual(h.mta.receiveDirectory(context, '/Download'), first);
});
test('MTA routes images/videos to gallery and documents to download; expiry falls back', async () => {
  const names = ['a.jpg', 'b.mp4', 'report.pdf'];
  const paths = names.map(name => context.filesDir + '/incoming/mta/batch-1/' + name);
  const metas = names.map(name => ({ name, size: 5, fileType: '' }));
  const h = mtaHarness();
  const resolved = await h.mta.finishReceived(context, paths, metas);
  assert.equal(resolved[0], 'file://media/Photo/123');
  assert.equal(resolved[1], 'file://media/Photo/123');
  assert.equal(resolved[2], '/Download/media.jpg');
  assert.equal(h.calls.filter(c => c === 'gallery').length, 2);
  assert.equal(h.calls.filter(c => c === 'download').length, 1);
  const expired = mtaHarness({ active: false });
  await expired.mta.finishReceived(context, paths, metas);
  assert.equal(expired.calls.filter(c => c === 'download').length, 3);
  assert.equal(expired.calls.includes('gallery'), false);
});
test('MTA handles a dynamic pair once and never creates separate ordinary assets', async () => {
  const paths = ['pair.jpg', 'pair.mov'].map(name => context.filesDir + '/incoming/mta/batch-1/' + name);
  const handled = new Set(); let restores = 0;
  const dynamic = { isClaimedByDynamicPhoto: p => handled.has(p), wasHandledForGallery: p => handled.has(p),
    settleBatch: async () => {}, settleReceivedFile: async () => { restores++; paths.forEach(p => handled.add(p)); } };
  const h = mtaHarness({ dynamic });
  const resolved = await h.mta.finishReceived(context, paths, [{ name: 'pair.jpg', size: 5 }, { name: 'pair.mov', size: 5 }]);
  assert.equal(restores, 1);
  assert.deepEqual(Array.from(resolved), paths);
  assert.equal(h.calls.length, 0);
});
test('MTA storage adapter awaits final destinations and preserves the default without a host', async () => {
  const adapter = load('mta/upstream/service/transfer/adapters/MtaReceiveAdapter');
  const paths = ['/original'];
  assert.equal(adapter.mtaReceiveDirectory('/Download'), '/Download');
  assert.equal(await adapter.finalizeMtaReceivedFiles(paths, []), paths);
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  adapter.configureMtaReceiveHost(() => {}, () => {}, {
    receiveDirectory: () => '/staged', finishReceived: async () => { await gate; return ['/gallery']; }
  });
  assert.equal(adapter.mtaReceiveDirectory('/Download'), '/staged');
  let finished = false;
  const pending = adapter.finalizeMtaReceivedFiles(paths, []).then(value => { finished = true; return value; });
  await Promise.resolve(); assert.equal(finished, false);
  release(); assert.deepEqual(Array.from(await pending), ['/gallery']);
});

test('received image/video requests expired authorization, then saves the same source', async () => {
  for (const name of ['photo.jpg', 'clip.mp4']) {
    const h = service({ active: false, authorize: async () => true });
    assert.equal(h.api.shouldStageForGallery(name), true);
    assert.equal(h.authorizationRequests, 0);
    const result = await h.api.processCompleted(context, context.filesDir + '/incoming/quickshare/' + name, name, 5, true);
    assert.equal(h.authorizationRequests, 1);
    assert.equal(result.savedToGallery, true);
    assert.equal(h.calls.includes('download'), false);
  }
});
test('LocalSend asks after staging and returns the gallery URI to relocation', async () => {
  const h = service({ active: false, authorize: async () => true });
  const source = context.filesDir + '/incoming/photo.jpg';
  assert.equal((await h.api.saveStaged(context, source, 'photo.jpg', 5)).savedToGallery, true);
  assert.equal(h.authorizationRequests, 1);
  assert.equal(h.api.galleryUriForSourcePath(source), 'file://media/Photo/123');
});
test('non-media and empty files never request gallery authorization', async () => {
  const h = service({ active: false, authorize: async () => { throw new Error('must not ask'); } });
  await h.api.processCompleted(context, '/sandbox/files/incoming/report.pdf', 'report.pdf', 5, true);
  await h.api.processCompleted(context, '/sandbox/files/incoming/empty.jpg', 'empty.jpg', 0, true);
  await h.api.saveStaged(context, '/sandbox/files/incoming/report.pdf', 'report.pdf', 5);
  assert.equal(h.authorizationRequests, 0);
  assert.equal(h.calls.includes('gallery'), false);
});
test('revoked authorization requests renewal and retries once without duplicate fallback', async () => {
  const h = service({ authorize: async () => true, saveResults: [
    { saved: false, permissionDenied: true, error: '201' },
    { saved: true, uri: 'file://media/Photo/renewed', permissionDenied: false, error: '' }
  ] });
  const result = await h.api.processCompleted(context, context.filesDir + '/incoming/quickshare/photo.jpg', 'photo.jpg', 5, true);
  assert.equal(result.finalPath, 'file://media/Photo/renewed');
  assert.equal(h.authorizationRequests, 1);
  assert.equal(h.calls.filter(c => c === 'gallery').length, 2);
  assert.equal(h.calls.includes('download'), false);
});
test('new authorization still rejected by system falls back without a prompt loop', async () => {
  const h = service({ active: false, authorize: async () => true,
    saveResult: { saved: false, permissionDenied: true, error: '201' } });
  const result = await h.api.processCompleted(context, context.filesDir + '/incoming/quickshare/photo.jpg', 'photo.jpg', 5, true);
  assert.equal(result.savedToGallery, false);
  assert.equal(h.authorizationRequests, 1);
  assert.equal(h.calls.filter(c => c === 'gallery').length, 1);
  assert.equal(h.calls.includes('download'), true);
});
test('disabling while authorization is pending prevents saving and keeps download fallback', async () => {
  let release;
  const h = service({ active: false, authorize: () => new Promise(resolve => { release = resolve; }) });
  const pending = h.api.processCompleted(context, context.filesDir + '/incoming/quickshare/photo.jpg', 'photo.jpg', 5, true);
  await Promise.resolve(); h.setEnabled(false); release(true);
  assert.equal((await pending).savedToGallery, false);
  assert.equal(h.calls.includes('gallery'), false);
  assert.equal(h.calls.includes('download'), true);
});

function authorizationHarness() {
  const state = { enabled: true, active: false };
  const { GalleryAuthorizationRequest: request } = load('quickshare/service/GalleryAuthorizationRequest', {
    '../../common/SettingsStore': { SettingsStore: { current: () => ({ saveReceivedMediaToGallery: state.enabled }) } },
    './GalleryAuthorizationSession': { GalleryAuthorizationSession: { isActive: () => state.active } }
  });
  return { request, state };
}
test('authorization coordinator opens only on demand, shares concurrent prompts and renews after expiry', async () => {
  const { request, state } = authorizationHarness(); let prompts = 0, release;
  request.configure(() => { prompts++; return new Promise(resolve => { release = resolve; }); });
  request.setForeground(true);
  assert.equal(prompts, 0);
  const first = request.request(), second = request.request();
  assert.equal(first, second);
  await Promise.resolve(); assert.equal(prompts, 1);
  state.active = true; release(true);
  assert.equal(await first, true); assert.equal(await second, true);
  assert.equal(await request.request(), true); assert.equal(prompts, 1);
  state.active = false;
  const renewed = request.request(); await Promise.resolve(); assert.equal(prompts, 2);
  state.active = true; release(true); assert.equal(await renewed, true);
});
test('cancelled or failed authorization allows a later received file to ask again', async () => {
  const { request } = authorizationHarness(); let prompts = 0;
  request.configure(async () => { prompts++; if (prompts === 1) throw new Error('window unavailable'); return false; });
  request.setForeground(true);
  assert.equal(await request.request(), false);
  assert.equal(await request.request(), false);
  assert.equal(prompts, 2);
});
test('background/window teardown releases pending authorization and ignores stale results', async () => {
  const { request, state } = authorizationHarness(); let release, dismissals = 0, prompts = 0;
  request.configure(() => { prompts++; return new Promise(resolve => { release = resolve; }); }, () => { dismissals++; });
  request.setForeground(true);
  const pending = request.request(); await Promise.resolve();
  request.setForeground(false);
  assert.equal(await pending, false);
  assert.equal(await request.request(), false);
  assert.equal(prompts, 1); assert.equal(dismissals, 1);
  state.active = true; release(true); await Promise.resolve();
  request.configure(); state.active = false;
  request.setForeground(true); assert.equal(await request.request(), false);
});

test('gallery imports the complete sandbox resource as one change request', async () => {
  const source = context.filesDir + '/incoming/quickshare/received.mov';
  let rejectImport = true;
  const imports = [];
  const { GalleryMediaRepository: repo } = load('quickshare/storage/GalleryMediaRepository', {
    '@ohos.file.fs': { default: { statSync: () => ({ size: 11 }) } },
    '@kit.CoreFileKit': { fileUri: { getUriFromPath: p => 'file://' + p } },
    '@kit.MediaLibraryKit': { photoAccessHelper: {
      PhotoType: { VIDEO: 2 }, ResourceType: { VIDEO_RESOURCE: 2 },
      MediaAssetChangeRequest: { createAssetRequest(_ctx, kind, ext, options) {
        assert.deepEqual([kind, ext, options.title], [2, 'mov', 'received']);
        return {
          resources: [],
          addResource(type, uri) { this.resources.push([type, uri]); },
          getAsset() { return { uri: 'file://media/Photo/asset' }; }
        };
      } },
      getPhotoAccessHelper: () => ({
        getSupportedPhotoFormats: async () => ['mov'],
        applyChanges: async change => {
          assert.deepEqual(change.resources, [[2, 'file://' + source]]);
          if (rejectImport) throw { code: 201 };
          imports.push(change);
        }
      })
    } }
  });
  const media = classifier.classify('received.mov');
  const denied = await repo.save(context, source, media);
  assert.equal(denied.permissionDenied, true);
  assert.equal(imports.length, 0);
  rejectImport = false;
  const accepted = await repo.save(context, source, media);
  assert.equal(accepted.uri, 'file://media/Photo/asset');
  assert.equal(imports.length, 1);
});
