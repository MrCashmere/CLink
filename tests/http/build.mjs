/**
 * 把 ArkTS 源码转译成 Node 可 import 的 ESM（只做语法转译，语义与 IDE 一致）。
 * 与 tests/dp-format/build.mjs 同一套路，供 tests/http 使用。
 */
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const here = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const srcDir = path.resolve(here, '../../entry/src/main/ets/common');
const outDir = path.resolve(here, 'build');

const TS_CANDIDATES = [
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
  const modules = ['HttpBodyParser'];
  for (const name of modules) {
    let code = fs.readFileSync(path.join(srcDir, name + '.ets'), 'utf8');
    code = code.replace(/from\s*'\.\/([A-Za-z0-9_]+)'/g, "from './$1.mjs'");
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

if (process.argv[1] && process.argv[1].endsWith('build.mjs')) {
  build();
  console.log('built', outDir);
}
