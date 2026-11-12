import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import { execFileSync } from 'child_process';

function newestSource(directory: string): number {
  let newest = 0;
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (entry.name === 'target' || entry.name === '.git' || entry.name === '.DS_Store' ||
      entry.name.startsWith('._')) { continue; }
    const file = path.join(directory, entry.name);
    newest = Math.max(newest, entry.isDirectory() ? newestSource(file) : fs.statSync(file).mtimeMs);
  }
  return newest;
}

/** 缺少或过期的 MTA 库必须先构建，避免源码可编译而安装后找不到原生模块。 */
function nativeSdk(project: string): string {
  const properties = path.join(project, 'local.properties');
  const sdkLine = fs.existsSync(properties) ? fs.readFileSync(properties, 'utf8').split(/\r?\n/)
    .map(line => /^\s*sdk\.dir\s*=\s*(.*?)\s*$/.exec(line)).find(match => match !== null) : undefined;
  const configuredSdk = sdkLine ? sdkLine[1].replace(/\\([\\:= ])/g, '$1') : undefined;
  // DevEco 的内置 Node 位于 Contents/tools/node/bin，可从这里定位配套 SDK。
  const bundledSdk = path.resolve(path.dirname(process.execPath), '..', '..', '..', 'sdk');
  const roots = [process.env.OHOS_NDK_HOME, configuredSdk, process.env.DEVECO_SDK_HOME,
    process.env.OHOS_SDK_HOME, bundledSdk].filter((root): root is string => !!root);
  const clang = process.platform === 'win32' ? 'clang.exe' : 'clang';
  for (const root of roots) {
    for (const suffix of ['', 'default/openharmony/native', 'openharmony/native', 'native']) {
      const candidate = path.resolve(root, suffix);
      if (fs.existsSync(path.join(candidate, 'llvm', 'bin', clang)) &&
        fs.existsSync(path.join(candidate, 'sysroot'))) { return candidate; }
    }
  }
  throw new Error('未找到 OHOS Native SDK。请设置 OHOS_NDK_HOME（native 目录）、DEVECO_SDK_HOME（SDK 根目录），或在 local.properties 配置 sdk.dir。');
}

function shellQuote(value: string): string {
  return "'" + value.replace(/'/g, "'\\''") + "'";
}

function buildUnix(project: string, entryDirectory: string, native: string): void {
  const env = { ...process.env };
  const portable = path.join(project, '.toolhome', 'mta');
  const portableCargo = path.join(portable, 'cargo', 'bin', 'cargo');
  if (fs.existsSync(portableCargo)) {
    env.CARGO_HOME = path.join(portable, 'cargo');
    env.RUSTUP_HOME = path.join(portable, 'rustup');
  }
  const cargoBin = path.join(env.CARGO_HOME || path.join(os.homedir(), '.cargo'), 'bin');
  const cargo = fs.existsSync(path.join(cargoBin, 'cargo')) ? path.join(cargoBin, 'cargo') : 'cargo';
  env.PATH = cargoBin + path.delimiter + (env.PATH || '');
  env.OHOS_NDK_HOME = native;
  env.CARGO_TARGET_DIR = path.resolve(project, env.CARGO_TARGET_DIR || 'mta_native/target');
  const wrappers = path.join(portable, 'ohos-linkers');
  fs.mkdirSync(wrappers, { recursive: true });
  for (const [target, abi] of [['aarch64-unknown-linux-ohos', 'arm64-v8a'], ['x86_64-unknown-linux-ohos', 'x86_64']]) {
    const wrapper = path.join(wrappers, target + '-clang');
    fs.writeFileSync(wrapper, '#!/bin/sh\nexec ' + shellQuote(path.join(native, 'llvm', 'bin', 'clang')) +
      ' --target=' + target + ' --sysroot=' + shellQuote(path.join(native, 'sysroot')) + ' "$@"\n');
    fs.chmodSync(wrapper, 0o755);
    const suffix = target.replace(/-/g, '_');
    env['CC_' + suffix] = wrapper;
    env['AR_' + suffix] = path.join(native, 'llvm', 'bin', 'llvm-ar');
    env['CARGO_TARGET_' + suffix.toUpperCase() + '_LINKER'] = wrapper;
    try {
      execFileSync(cargo, ['build', '--manifest-path', path.join(project, 'mta_native', 'Cargo.toml'),
        '--locked', '--release', '--target', target], { cwd: project, env, stdio: 'inherit' });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
        throw new Error('MTA 原生构建未找到 Cargo。请安装 Rust，并执行 rustup target add aarch64-unknown-linux-ohos x86_64-unknown-linux-ohos。');
      }
      throw error;
    }
    const output = path.join(entryDirectory, 'libs', abi, 'libmta_core.so');
    fs.mkdirSync(path.dirname(output), { recursive: true });
    fs.copyFileSync(path.join(env.CARGO_TARGET_DIR, target, 'release', 'libmta_core.so'), output);
  }
}

/** 由 entry 的真实构建前置任务调用；同步阶段不读取 SDK 或启动编译器。 */
export function ensureMtaNative(entryDirectory: string): void {
  const project = path.resolve(entryDirectory, '..');
  const sourceTime = Math.max(newestSource(path.join(project, 'mta_native')),
    fs.statSync(path.join(project, 'scripts/build_mta_native.ps1')).mtimeMs);
  const outputs = ['arm64-v8a', 'x86_64'].map(abi => path.join(entryDirectory, 'libs', abi, 'libmta_core.so'));
  if (outputs.every(file => fs.existsSync(file) && fs.statSync(file).mtimeMs >= sourceTime)) { return; }
  const native = nativeSdk(project);
  console.info('[MTA] 正在构建独立 Rust 传输库（arm64 / x86_64）');
  if (process.platform === 'win32') {
    execFileSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
      path.join(project, 'scripts/build_mta_native.ps1'), '-SdkNative', native], { cwd: project, stdio: 'inherit' });
  } else {
    buildUnix(project, entryDirectory, native);
  }
  for (const output of outputs) {
    if (!fs.existsSync(output)) { throw new Error('MTA 原生构建未生成所需库：' + output); }
  }
}
