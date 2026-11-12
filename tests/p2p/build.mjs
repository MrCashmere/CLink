/**
 * 把 gs 模块里的**纯协议文件**（无 @kit 依赖，除 GsBytes 的 TextEncoder/TextDecoder）
 * 转译成 Node 可 import 的 ESM，供 tests/p2p 的用例直接断言线上字节。
 *
 * 与被测源码目录结构保持一致（util/ quickshare/ model/），这样 `../util/GsBytes`
 * 这类相对导入加上 `.mjs` 后就能被 Node 解析。
 *
 * 用法：node tests/p2p/tests.mjs（会先自动 build）
 */
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const here = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const srcRoot = path.resolve(here, '../../gs/src/main/ets');
const outDir = path.resolve(here, 'build');

const TS_CANDIDATES = [
  'C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js'
];

function loadTypeScript() {
  const fromEnv = process.env.TS_LIB;
  if (fromEnv && fs.existsSync(fromEnv)) {
    return require(fromEnv);
  }
  for (const candidate of TS_CANDIDATES) {
    if (fs.existsSync(candidate)) {
      return require(candidate);
    }
  }
  throw new Error('未找到 DevEco 自带的 typescript；请设置 TS_LIB 环境变量指向 typescript.js');
}

/** 被测模块（相对 gs/src/main/ets）。 */
const MODULES = [
  'util/GsBytes',
  'model/GsTypes',
  'quickshare/ProtoWire',
  'quickshare/ProtoReader',
  'quickshare/NearbyCapabilities',
  'quickshare/NearDropWire',
  'quickshare/BandwidthUpgrade'
];

/**
 * entry 侧模块：只需两处 shim 就能在 Node 里跑 ——
 * `@ohos.file.fs`（只有 readFileRange 用，测试不调用）与 `util.Base64Helper`。
 */
const ENTRY_MODULES = ['common/ByteUtils'];
const ENTRY_ROOT = path.resolve(here, '../../entry/src/main/ets');

export function build() {
  const ts = loadTypeScript();
  fs.mkdirSync(outDir, { recursive: true });

  // util/GsBytes 只用到 TextEncoder.encodeInto 与 TextDecoder.create(...).decodeToString
  fs.mkdirSync(path.join(outDir, 'util'), { recursive: true });
  fs.writeFileSync(path.join(outDir, 'util', 'utilshim.mjs'), `export const util = {
  TextEncoder: class {
    encodeInto(value) { return new TextEncoder().encode(value); }
  },
  TextDecoder: {
    create: (enc) => ({ decodeToString: (bytes) => new TextDecoder(enc || 'utf-8').decode(bytes) })
  },
  Base64Helper: class {
    encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
    decodeSync(text) { return new Uint8Array(Buffer.from(text, 'base64')); }
  }
};
`);

  transpileAll(ts, srcRoot, MODULES, outDir, false);
  transpileAll(ts, ENTRY_ROOT, ENTRY_MODULES, path.join(outDir, 'entry'), true);
}

function transpileAll(ts, root, modules, target, entrySide) {
  for (const relative of modules) {
    const source = path.join(root, relative + '.ets');
    let code = fs.readFileSync(source, 'utf8');
    // entry 侧模块在 build/entry/<dir>/ 下，相对路径多两级，指回共享的 build/util/utilshim.mjs。
    const shimPath = entrySide ? '../../util/utilshim.mjs' : './utilshim.mjs';
    code = code.replace(/import\s*\{\s*util\s*\}\s*from\s*'@kit\.ArkTS';/, `import { util } from '${shimPath}';`);
    if (entrySide) {
      // 测试不碰文件读写，把平台模块换成空实现即可。
      code = code.replace(/import\s+fs\s+from\s*'@ohos\.file\.fs';/, 'const fs = {};');
    }
    code = code.replace(/from\s*'\.\/([A-Za-z0-9_]+)'/g, "from './$1.mjs'");
    code = code.replace(/from\s*'\.\.\/([A-Za-z0-9_]+)\/([A-Za-z0-9_]+)'/g, "from '../$1/$2.mjs'");
    const out = ts.transpileModule(code, {
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ESNext },
      fileName: path.basename(relative) + '.ts'
    });
    for (const d of out.diagnostics ?? []) {
      if (d.category === 1) {
        throw new Error(`${relative}: TS 语法错误 ${JSON.stringify(d)}`);
      }
    }
    const file = path.join(target, relative + '.mjs');
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, out.outputText);
  }
}

if (process.argv[1] && process.argv[1].endsWith('build.mjs')) {
  build();
  console.log('built', outDir);
}
