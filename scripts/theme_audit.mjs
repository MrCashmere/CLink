/*
 * 主题色 / 沉浸光感适配自检（可重复运行）
 * ======================================
 *
 *   node scripts/theme_audit.mjs
 *
 * 纯静态检查，不需要编译、不需要设备。逐项核对「卡片与控件是否跟着主题色走」，
 * 把几类最容易漏的适配点扫出来。判定依据见 docs/THEME_COLOR.md。
 *
 * 检查项：
 *   1. 卡片承载：用了 cardGlassEffect/cardGlassBorderColor/cardGlassShadow 的地方
 *      必须处于 CardSurface / MaterialCardLayer 作用域内 ——
 *      否则沉浸光感一生效（这三个 helper 返回「无效果」）卡片会直接丢掉背景；
 *   2. 订阅：带卡片的文件必须有 @StorageProp/@StorageLink('accentColor')；
 *   3. 控件选中色：ToggleType.Switch / Slider 必须显式 selectedColor、
 *      TextInput 必须显式 caretColor（SDK 默认是系统强调色，不覆盖就永远是蓝的）；
 *   4. 哨兵：页面/视图必须有 AccentColorSentinel()；
 *   5. 硬编码色值：UI 文件里出现「带色相」的字面量（切主题色后不会跟着变）；
 *   6. 实时跟随：主题色相关的属性表达式必须读到订阅变量 ——
 *      `hwPrimary(this.isDarkMode)` / `hwPrimaryButton(...)` / `hwGlassBorder(...)`
 *      都是纯函数（读模块级 HwColor），登记不上依赖，切色后那一处不会刷新，
 *      应改用 `resolvePrimaryColor(isDark, this.accentOrPrimary())` 等订阅版。
 */

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

// 允许在任意工作目录下运行：路径以脚本自身位置为基准
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../entry/src/main/ets');
const NEUTRAL_OK = new Set(['#14000000', '#1A000000', '#33000000', '#66000000', '#00000000', '#33FFFFFF',
  '#4D000000', '#80000000', '#26000000', '#99000000']);
/**
 * 刻意保留的「带色相」字面量白名单（每条都要在这里写清理由）。
 * 除此之外 UI 文件里出现带色相的硬编码色值都应改成主题色派生值。
 */
const HUE_LITERAL_ALLOW = new Map([
  // 协议徽标上的深色文字：底色是协议品牌色（绿/天蓝/靛蓝/琥珀/灰），与主题色无关
  ['view/DeviceList.ets', '#04121F']
]);
const GLASS = /cardGlassEffect\(|cardGlassBorderColor\(|cardGlassShadow\(/;
const CARRIER_CLOSURE = /CardSurface\(\{|MaterialSheetPanel\(\)/;
const CARRIER_SIBLING = /MaterialCardLayer\(\{/;

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      walk(full, out);
    } else if (name.endsWith('.ets')) {
      out.push(full);
    }
  }
  return out;
}

function stripLine(line) {
  return line
    .replace(/\/\/[^\n]*/g, '')
    .replace(/'(?:\\.|[^'\\])*'/g, "''")
    .replace(/`(?:\\.|[^`\\])*`/g, '``');
}

/** 从 start 行往后找 `.attr(...)`；遇到同层的新控件或容器收尾就停 */
function findAttr(lines, start, attr) {
  const indent = lines[start].match(/^(\s*)/)[1].length;
  for (let j = start + 1; j < Math.min(lines.length, start + 30); j++) {
    const trimmed = lines[j].trim();
    if (trimmed.length === 0) {
      continue;
    }
    const ind = lines[j].match(/^(\s*)/)[1].length;
    if (ind < indent && trimmed.startsWith('}')) {
      return '';
    }
    if (/(Toggle|Slider|TextInput)\(\{/.test(trimmed) || /^(Text|Row|Column|Button)\(/.test(trimmed)) {
      return '';
    }
    const matched = lines[j].match(new RegExp('\\.' + attr + '\\(([^)]*)\\)'));
    if (matched) {
      return matched[1].trim();
    }
  }
  return '';
}

const findings = [];
const add = (kind, where, detail) => findings.push(`${kind}  ${where}${detail ? '  ' + detail : ''}`);

const ALL_FILES = walk(ROOT);

for (const full of ALL_FILES) {
  const rel = relative(ROOT, full).split(sep).join('/');
  const src = readFileSync(full, 'utf8');
  const lines = src.split(/\r?\n/);
  const isUi = /^(pages|view|components)\//.test(rel);

  // ---- 1. 卡片承载作用域 ----
  let depth = 0;
  const scopes = [];
  for (let i = 0; i < lines.length; i++) {
    const code = stripLine(lines[i]);
    const before = depth;
    const opens = (code.match(/\{/g) || []).length;
    const closes = (code.match(/\}/g) || []).length;
    if (CARRIER_CLOSURE.test(code) && /\{\s*$/.test(code)) {
      scopes.push(before);
    } else if (CARRIER_SIBLING.test(code)) {
      scopes.push(before - 1);
    }
    const inside = scopes.some((d) => before > d);
    // utils/ 下是这三个 helper 的**定义**（不是调用点），跳过
    if (GLASS.test(code) && !inside && !/^utils\//.test(rel)) {
      add('卡片无承载层', `${rel}:${i + 1}`, lines[i].trim().slice(0, 80));
    }
    depth += opens - closes;
    while (scopes.length > 0 && depth <= scopes[scopes.length - 1]) {
      scopes.pop();
    }
  }

  // ---- 2/4. 订阅与哨兵 ----
  const hasCards = src.includes('CardSurface(') || GLASS.test(src);
  const hasSubscribe = src.includes("@StorageProp('accentColor')") || src.includes("@StorageLink('accentColor')");
  if (hasCards && !hasSubscribe && !/^utils\//.test(rel)) {
    add('未订阅主题色', rel);
  }
  // 哨兵只要求页面级（pages/ view/）：components/ 里的组件都嵌在页面里，
  // 页面重建时一起重建，而它们各自都订阅了 accentColor
  const isPageLevel = /^(pages|view)\//.test(rel);
  if (isPageLevel && !src.includes('AccentColorSentinel()') && /@Component|@Entry/.test(src)
    && /hwPrimary\(|hwPrimaryButton\(|accentOrPrimary\(/.test(src)
    && !/^(pages\/Index|pages\/Settings)\.ets$/.test(rel)) {
    add('页面缺少 AccentColorSentinel', rel);
  }

  // ---- 3. 控件选中色 / 光标色 ----
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/Toggle\(\{\s*type:\s*ToggleType\.Switch/.test(line)) {
      const v = findAttr(lines, i, 'selectedColor');
      if (v.length === 0) {
        add('开关未设 selectedColor', `${rel}:${i + 1}`, line.trim().slice(0, 70));
      } else if (!v.includes('accentOrPrimary') && !v.includes('Transparent')) {
        add('开关选中色非常规', `${rel}:${i + 1}`, v);
      }
    }
    if (/^\s*Slider\(\{\s*$/.test(line)) {
      const v = findAttr(lines, i, 'selectedColor');
      if (v.length === 0) {
        add('滑杆未设 selectedColor', `${rel}:${i + 1}`);
      } else if (!v.includes('accentOrPrimary')) {
        add('滑杆选中色非常规', `${rel}:${i + 1}`, v);
      }
    }
    if (/^\s*TextInput\(\{/.test(line)) {
      const v = findAttr(lines, i, 'caretColor');
      if (v.length === 0) {
        add('输入框未设 caretColor', `${rel}:${i + 1}`, line.trim().slice(0, 70));
      } else if (!v.includes('accentOrPrimary')) {
        add('输入框光标色非常规', `${rel}:${i + 1}`, v);
      }
    }
  }

  // ---- 5. 带色相的硬编码色值 / 6. 实时跟随 ----
  if (isUi) {
    for (let i = 0; i < lines.length; i++) {
      if (/^\s*(\/\/|\*|\/\*)/.test(lines[i])) {
        continue;
      }
      // 6. 主题色相关的纯函数调用（登记不上依赖，切色后不刷新）
      const stale = lines[i].match(/hwPrimary\(this\.isDarkMode\)|hwPrimaryButton\(this\.isDarkMode\)|hwGlassBorder\(this\.isDarkMode\)/);
      if (stale !== null) {
        add('主题色未实时跟随', `${rel}:${i + 1}`, `${stale[0]}  应改用 resolve* 订阅版`);
      }
      for (const literal of lines[i].match(/'#[0-9A-Fa-f]{6,8}'/g) || []) {
        const hex = literal.slice(1, -1).toUpperCase();
        if (NEUTRAL_OK.has(hex)) {
          continue;
        }
        if (HUE_LITERAL_ALLOW.get(rel) === hex) {
          continue;
        }
        const body = hex.length === 8 ? hex.slice(2) : hex;
        const r = body.slice(0, 2);
        const g = body.slice(2, 4);
        const b = body.slice(4, 6);
        if (r !== g || g !== b) {
          add('硬编码色相字面量', `${rel}:${i + 1}`, `${literal}  ${lines[i].trim().slice(0, 60)}`);
        }
      }
    }
  }
}

console.log('主题色 / 沉浸光感适配自检 —— 扫描 ' + ALL_FILES.length + ' 个 .ets');
if (findings.length === 0) {
  console.log('未发现问题 ✅');
} else {
  console.log('发现 ' + findings.length + ' 项（逐条见下；白名单内的刻意例外见脚本头部注释）：\n');
  console.log(findings.join('\n'));
  console.log('\n说明：IconCircleButton 的顶栏玻璃按钮、DeviceList 的协议徽标文字色是刻意的例外。');
}
