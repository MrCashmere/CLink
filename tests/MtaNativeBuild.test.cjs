const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const cp = require('node:child_process');
const ts = require(process.env.TS_LIB || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '..');

function load(relative, mocks, globals = {}) {
  const source = fs.readFileSync(path.join(root, relative), 'utf8');
  const output = ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
  }}).outputText;
  const exports = {};
  vm.runInNewContext(output, { exports, require: name => mocks[name] || require(name),
    __dirname: path.join(root, path.dirname(relative)), console: { info() {} }, process, ...globals });
  return exports;
}

function fixture(t, platform = 'darwin') {
  const project = fs.mkdtempSync(path.join(os.tmpdir(), 'mta-native-build-'));
  t.after(() => fs.rmSync(project, { recursive: true, force: true }));
  const entry = path.join(project, 'entry');
  const nativeProject = path.join(project, 'mta_native');
  fs.mkdirSync(entry); fs.mkdirSync(nativeProject); fs.mkdirSync(path.join(project, 'scripts'));
  const source = path.join(nativeProject, 'lib.rs');
  fs.writeFileSync(source, '// native source'); fs.utimesSync(source, 1000, 1000);
  const ps = path.join(project, 'scripts', 'build_mta_native.ps1');
  fs.writeFileSync(ps, ''); fs.utimesSync(ps, 1000, 1000);
  const sdk = path.join(project, "Mock IDE's SDK");
  const native = path.join(sdk, 'default', 'openharmony', 'native');
  fs.mkdirSync(path.join(native, 'llvm', 'bin'), { recursive: true });
  fs.mkdirSync(path.join(native, 'sysroot'));
  const clang = path.join(native, 'llvm', 'bin', platform === 'win32' ? 'clang.exe' : 'clang');
  fs.writeFileSync(clang, '#!/usr/bin/env node\nprocess.stdout.write(JSON.stringify(process.argv.slice(2)));\n', { mode: 0o755 });
  const env = { DEVECO_SDK_HOME: sdk, PATH: process.env.PATH };
  const calls = [];
  const execFileSync = (command, args, options) => {
    calls.push({ command, args, options });
    if (args[0] === 'build') {
      const target = args[args.indexOf('--target') + 1];
      const output = path.join(options.env.CARGO_TARGET_DIR, target, 'release', 'libmta_core.so');
      fs.mkdirSync(path.dirname(output), { recursive: true }); fs.writeFileSync(output, target);
    } else if (command === 'powershell.exe') {
      for (const abi of ['arm64-v8a', 'x86_64']) {
        const out = path.join(entry, 'libs', abi, 'libmta_core.so');
        fs.mkdirSync(path.dirname(out), { recursive: true }); fs.writeFileSync(out, abi);
      }
    }
  };
  const { ensureMtaNative } = load('scripts/mta-native-build.ts', { child_process: { execFileSync } }, {
    process: { platform, env, execPath: '/missing/IDE/tools/node/bin/node' }
  });
  return { project, entry, source, sdk, native, clang, env, calls, ensureMtaNative };
}

test('IDE sync and clean skip the native check while actual builds enforce it', () => {
  let resolved, runs = 0, commands = ['init'];
  load('entry/hvigorfile.ts', {
    '@ohos/hvigor-ohos-plugin': { hapTasks: {} },
    '@ohos/hvigor': { hvigor: { taskGraphResolved: fn => { resolved = fn; }, getCommandEntryTask: () => commands } },
    '../scripts/mta-native-build': { ensureMtaNative: () => { runs++; } }
  });
  assert.equal(runs, 0, 'loading hvigorfile must not inspect SDK or start a compiler');
  resolved(); assert.equal(runs, 0);
  commands = ['entry:clean']; resolved(); assert.equal(runs, 0);
  commands = ['entry:default@assembleHap']; resolved();
  assert.equal(runs, 1, 'real build still enforces the native prerequisite');
});

test('Finder metadata cannot invalidate current libraries or require local.properties', t => {
  const f = fixture(t);
  for (const abi of ['arm64-v8a', 'x86_64']) {
    const out = path.join(f.entry, 'libs', abi, 'libmta_core.so');
    fs.mkdirSync(path.dirname(out), { recursive: true }); fs.writeFileSync(out, abi); fs.utimesSync(out, 2000, 2000);
  }
  fs.writeFileSync(path.join(f.project, 'mta_native', '.DS_Store'), 'Finder');
  fs.writeFileSync(path.join(f.project, 'mta_native', '._lib.rs'), 'AppleDouble');
  f.ensureMtaNative(f.entry); assert.equal(f.calls.length, 0);
});

test('macOS discovers the SDK without local.properties and builds both ABIs with Cargo', t => {
  const f = fixture(t);
  f.env.CARGO_TARGET_DIR = 'custom target';
  f.ensureMtaNative(f.entry);
  assert.equal(f.calls.length, 2);
  for (const [i, target] of ['aarch64-unknown-linux-ohos', 'x86_64-unknown-linux-ohos'].entries()) {
    const call = f.calls[i];
    assert.ok(call.args.includes('--locked')); assert.ok(call.args.includes(target));
    assert.notEqual(call.command, 'powershell.exe');
    const suffix = target.replaceAll('-', '_');
    const wrapper = call.options.env['CC_' + suffix];
    const args = JSON.parse(cp.execFileSync(wrapper, ['argument with spaces'], { encoding: 'utf8' }));
    assert.deepEqual(args, ['--target=' + target, '--sysroot=' + path.join(f.native, 'sysroot'), 'argument with spaces']);
    const abi = i === 0 ? 'arm64-v8a' : 'x86_64';
    assert.equal(fs.readFileSync(path.join(f.entry, 'libs', abi, 'libmta_core.so'), 'utf8'), target);
  }
});

test('Linux uses the Unix builder and native SDK override', t => {
  const f = fixture(t, 'linux'); delete f.env.DEVECO_SDK_HOME; f.env.OHOS_NDK_HOME = f.native;
  f.ensureMtaNative(f.entry); assert.equal(f.calls.length, 2);
  assert.ok(f.calls.every(call => call.options.env.OHOS_NDK_HOME === f.native));
});

test('Windows keeps the PowerShell builder with SDK environment discovery', t => {
  const f = fixture(t, 'win32'); f.ensureMtaNative(f.entry);
  assert.equal(f.calls.length, 1); assert.equal(f.calls[0].command, 'powershell.exe');
  assert.equal(f.calls[0].args.at(-1), f.native);
});

test('missing SDK gives an actionable error instead of local.properties ENOENT', t => {
  const f = fixture(t); delete f.env.DEVECO_SDK_HOME;
  assert.throws(() => f.ensureMtaNative(f.entry), /OHOS_NDK_HOME|DEVECO_SDK_HOME/);
  assert.equal(f.calls.length, 0);
});
