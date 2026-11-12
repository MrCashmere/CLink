/**
 * 把 ArkTS 源码转译成可被 Node 直接 import 的 ESM，供 tests/dp-format 下的用例使用。
 *
 * 用 DevEco 自带的 TypeScript（与 IDE 编译同一份 tsconfig 语义），只做语法转译：
 *  - `import { util } from '@kit.ArkTS'` 换成最小的 TextDecoder 垫片；
 *  - 相对导入补上 `.mjs` 后缀，让 Node 的 ESM 解析器能解析。
 */
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const here = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const srcDir = path.resolve(here, '../../entry/src/main/ets/common');
const outDir = path.resolve(here, 'build');

const TS_CANDIDATES = [
  'C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  'C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js'
];

function loadTypeScript() {
  for (const candidate of TS_CANDIDATES) {
    if (fs.existsSync(candidate)) {
      return require(candidate);
    }
  }
  throw new Error('未找到 DevEco 自带的 typescript；请设置 TS_LIB 环境变量指向 typescript.js');
}

export function build() {
  const tsPath = process.env.TS_LIB && fs.existsSync(process.env.TS_LIB) ? process.env.TS_LIB : undefined;
  const ts = tsPath ? require(tsPath) : loadTypeScript();
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, 'utilshim.mjs'), `export const util = {
  TextDecoder: {
    create: (enc) => ({ decodeToString: (bytes) => new TextDecoder(enc || 'utf-8').decode(bytes) })
  }
};
`);
  // 每个被测模块的重写规则：把平台专属 import 换成可跑的等价物。
  const modules = [
    { name: 'Isobmff', extra: [] },
    { name: 'DynamicPhotoFormat', extra: [] },
    // LivePhotoWriter 现在会 import `./HdrMp4`（动图视频的 moov 前移），一并转译。
    { name: 'HdrMp4', extra: [] },
    { name: 'LivePhotoWriter', extra: [] },
    {
      name: 'PeerLivePhotoFormat',
      extra: [
        // DeviceEndpoint 只作为类型使用（转译后会被擦除），Node 里不需要真的解析该模块。
        [/import\s*\{\s*DeviceEndpoint\s*\}\s*from\s*'\.\.\/model\/TransferModels';/, '']
      ]
    }
  ];
  for (const module of modules) {
    const name = module.name;
    let code = fs.readFileSync(path.join(srcDir, name + '.ets'), 'utf8');
    code = code.replace(/import\s*\{\s*util\s*\}\s*from\s*'@kit\.ArkTS';/, "import { util } from './utilshim.mjs';");
    // 所有相对导入补 `.mjs`（新增模块时不必再逐条加规则 —— 漏加就会在运行时报 ERR_MODULE_NOT_FOUND）。
    code = code.replace(/from\s*'\.\/([A-Za-z0-9_]+)'/g, "from './$1.mjs'");
    for (const [pattern, replacement] of module.extra) {
      code = code.replace(pattern, replacement);
    }
    const out = ts.transpileModule(code, {
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ESNext },
      fileName: name + '.ts'
    });
    for (const d of out.diagnostics ?? []) {
      if (d.category === 1) {
        throw new Error(`${name}: TS 语法错误 ${JSON.stringify(d)}`);
      }
    }
    fs.writeFileSync(path.join(outDir, name + '.mjs'), out.outputText);
  }
}

// 直接执行本文件时也构建一次，方便 `node tests/dp-format/build.mjs` 单独验证。
if (process.argv[1] && process.argv[1].endsWith('build.mjs')) {
  build();
  console.log('built', outDir);
}
