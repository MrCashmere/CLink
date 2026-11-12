/**
 * 网页传输（浏览器）设备识别回归：**只用 UA** 判断对端是什么设备、该发哪种动态图片格式。
 *
 * 为什么要这条路径：`PeerLivePhotoFormat.resolve()` 用的是发现阶段的设备名/型号，而网页端
 * 根本不走发现——浏览器只有一个 `User-Agent` 请求头。于是「本机共享一个动态照片 → 手机浏览器
 * 下载」时，之前只能原样给字节：OPPO 浏览器下到的是鸿蒙形态的文件，相册不认动态照片/不认 HDR。
 *
 * 用例里的 UA 字符串**都是真实样本**（来源：whatmyuseragent.com 各机型页，2026-09-10 取），
 * 不是编的：
 *  - OPPO：`CPH2269`、`OPPO A79k`、realme `RMX3708`、一加 `CPH2449`
 *  - 小米/POCO：`22101316C`、`2407FPN8ER`、`Redmi Note 12 Pro`、`XiaoMi/MiuiBrowser`
 *  - vivo/iQOO：`V2251`、`V2243A`
 *  - 三星 `SM-S928B`、Pixel `Pixel 8`
 *  - 桌面：Windows NT、Linux x86_64；Apple：iPhone/iPad/Macintosh；鸿蒙：OpenHarmony/ArkWeb
 *
 * 用法：node tests/dp-format/dialect-useragent.mjs
 */
import { build } from './build.mjs';

build();
const { PeerLivePhotoFormat } = await import('./build/PeerLivePhotoFormat.mjs');

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

/** 只取关心的四个字段，断言更聚焦。 */
function decide(ua) {
  const d = PeerLivePhotoFormat.resolveForUserAgent(ua);
  return [d.platform, d.brand, d.format, d.dialect];
}

const CHROME_TAIL = ' AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

// ---------------------------------------------------------------------------
console.log('Android 各家：真实 UA → 品牌方言');
{
  const cases = [
    ['OPPO（CPH2269 / ColorOS 浏览器）',
      `Mozilla/5.0 (Linux; Android 11; CPH2269 Build/RP1A.200720.011; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/151.0.7922.199 Mobile Safari/537.36 open_news`,
      ['android', 'OPPO', 'android', 'oppo']],
    ['OPPO（令牌就是营销名 OPPO A79k）',
      'Mozilla/5.0 (Linux; Android 7.1.1; OPPO A79k Build/N6F26Q) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.6045.193 Mobile Safari/537.36',
      ['android', 'OPPO', 'android', 'oppo']],
    ['realme（RMX3708）',
      `Mozilla/5.0 (Linux; Android 14; RMX3708)${CHROME_TAIL}`,
      ['android', 'OPPO', 'android', 'oppo']],
    ['一加（CPH2449）',
      `Mozilla/5.0 (Linux; Android 14; CPH2449)${CHROME_TAIL}`,
      ['android', 'OPPO', 'android', 'oppo']],
    ['小米（22101316C，百度 App WebView）',
      'Mozilla/5.0 (Linux; Android 12; 2201123C Build/SKQ1.211006.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/97.0.4692.98 Mobile Safari/537.36 T7/13.38 baiduboxapp/13.38.0.11',
      ['android', 'Xiaomi', 'android', 'xiaomi']],
    ['POCO（2407FPN8ER）',
      `Mozilla/5.0 (Linux; Android 16; 2407FPN8ER)${CHROME_TAIL}`,
      ['android', 'Xiaomi', 'android', 'xiaomi']],
    ['Redmi（令牌是营销名 + XiaoMi/MiuiBrowser）',
      'Mozilla/5.0 (Linux; Android 13; Redmi Note 12 Pro Build/TKQ1.221114.001) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.7049.79 Mobile Safari/537.36 XiaoMi/MiuiBrowser/14.62.1-gn',
      ['android', 'Xiaomi', 'android', 'xiaomi']],
    ['vivo（V2251）',
      `Mozilla/5.0 (Linux; Android 15; V2251)${CHROME_TAIL} VivoBrowser/15.1.0.3`,
      ['android', 'vivo', 'android', 'vivo']],
    ['iQOO（V2243A，与 vivo 同编码）',
      `Mozilla/5.0 (Linux; Android 16; V2243A) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Mobile Safari/537.36`,
      ['android', 'vivo', 'android', 'vivo']],
    ['三星（SM-S928B）',
      'Mozilla/5.0 (Linux; Android 16; SM-S928B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36',
      ['android', 'Samsung', 'android', 'samsung']],
    ['Pixel（Pixel 8）',
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.3889.109 Mobile Safari/537.36',
      ['android', 'Google', 'android', 'google']]
  ];
  for (const [label, ua, expected] of cases) {
    check(label, decide(ua), expected);
  }
}

// ---------------------------------------------------------------------------
console.log('Android 但认不出品牌 → 全方言（不再只写 Google）');
{
  check('陌生型号（Nokia 味道的令牌）',
    decide('Mozilla/5.0 (Linux; Android 13; TA-1053 Build/TP1A.220624.014) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'),
    ['android', 'Android', 'android', 'universal']);
  check('普通 Android WebView 无型号',
    decide('Mozilla/5.0 (Linux; Android 11; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/90.0.4430.91 Mobile Safari/537.36'),
    ['android', 'Android', 'android', 'universal']);
}

// ---------------------------------------------------------------------------
console.log('Apple：iOS / macOS → 实况照片那套');
{
  check('iPhone Safari',
    decide('Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1'),
    ['apple', 'Apple', 'apple', 'google']);
  check('iPad',
    decide('Mozilla/5.0 (iPad; CPU OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1'),
    ['apple', 'Apple', 'apple', 'google']);
  check('iPhone 上的 Chrome（CriOS）',
    decide('Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/114.0.5735.99 Mobile/15E148 Safari/604.1'),
    ['apple', 'Apple', 'apple', 'google']);
  check('macOS Safari（Macintosh）',
    decide('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15'),
    ['apple', 'Apple', 'apple', 'google']);
}

// ---------------------------------------------------------------------------
console.log('鸿蒙 / 华为 / 荣耀 → 不转换（对端自己就认这套）');
{
  check('HarmonyOS NEXT（OpenHarmony + ArkWeb）',
    decide('Mozilla/5.0 (Phone; OpenHarmony 5.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 ArkWeb/4.1.6.1 Mobile HuaweiBrowser/5.0.2.300'),
    ['harmony', 'HarmonyOS', 'split', 'google']);
  check('华为 EMUI/HarmonyOS 老机型（HMSCore + ELS-AN00）',
    decide('Mozilla/5.0 (Linux; Android 10; HarmonyOS; ELS-AN00; HMSCore 6.11.0.302) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/99.0.4844.88 HuaweiBrowser/12.0.6.302 Mobile Safari/537.36'),
    ['harmony', 'HarmonyOS', 'split', 'google']);
  check('荣耀（MagicOS + 设备编码 ANY-LX1）',
    decide('Mozilla/5.0 (Linux; Android 14; ANY-LX1; MagicOS 8.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'),
    ['harmony', 'HarmonyOS', 'split', 'google']);
  // 品牌名只用于日志：UA 里写了 OpenHarmony 的报 HarmonyOS，靠华为机型编码认出的报 Huawei。
  // 两者平台都是 harmony → 都不转换，这才是关键。
  check('华为机型编码但 UA 没写 HarmonyOS/HMSCore',
    decide('Mozilla/5.0 (Linux; Android 10; ELS-NX9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Mobile Safari/537.36'),
    ['harmony', 'Huawei', 'split', 'google']);
}

// ---------------------------------------------------------------------------
console.log('桌面端 → 原样发文件（不转换）');
{
  check('Windows Chrome', decide('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'),
    ['windows', 'Windows', 'split', 'google']);
  check('Windows Edge', decide('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0'),
    ['windows', 'Windows', 'split', 'google']);
  check('Linux Chrome（不能因为含 Linux 就当 Android）',
    decide('Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'),
    ['desktop', 'Desktop', 'split', 'google']);
}

// ---------------------------------------------------------------------------
console.log('认不出 / 非浏览器客户端 → 原样发文件（绝不当成 Android 猜方言）');
{
  check('空 UA', decide(''), ['unknown', '', 'split', 'google']);
  check('curl', decide('curl/8.4.0'), ['unknown', '', 'split', 'google']);
  check('wget', decide('Wget/1.21.3'), ['unknown', '', 'split', 'google']);
  check('鸿蒙原生 App 的 okhttp', decide('okhttp/4.12.0'), ['unknown', '', 'split', 'google']);
}

// ---------------------------------------------------------------------------
console.log('设备令牌提取（型号编码优先，避免被 App 名带偏）');
{
  check('令牌 = Android 版本后的那段',
    PeerLivePhotoFormat.factsFromUserAgent('Mozilla/5.0 (Linux; Android 14; CPH2449 Build/TP1A.220905.001; wv) AppleWebKit/537.36').device,
    'CPH2449');
  check('没有 Build 也能取到（到右括号为止）',
    PeerLivePhotoFormat.factsFromUserAgent('Mozilla/5.0 (Linux; Android 14; SM-S928B) AppleWebKit/537.36').device,
    'SM-S928B');
  check('非 Android UA 不硬凑令牌',
    PeerLivePhotoFormat.factsFromUserAgent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15').device,
    '');
  // 反向断言：App 名里出现别家品牌，不能被当成本机品牌
  check('UA 里出现别家 App 名（vivo 手机里的 TwitterAndroid）仍按设备令牌判',
    decide('Mozilla/5.0 (Linux; Android 15; V2251 Build/AP3A.240905.015.A2; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/151.0.7922.199 Mobile Safari/537.36 TwitterAndroid/12.21.1-prod.05 V2251/15 (vivo;V22'),
    ['android', 'vivo', 'android', 'vivo']);
}

// ---------------------------------------------------------------------------
console.log('国产浏览器在版本号后插语言段：真机踩过的坑（OPPO 被误判成「认不出品牌」）');
{
  // 这是 2026-09-10 真机日志里 OPPO 手机访问本机网页端时的 UA 原文：
  //   reason=ua:android-unknown-brand ua=Mozilla/5.0 (Linux; U; Android 16; zh-cn; PLR110 Build/…)
  // 老实现取「Android 版本后的第一段」→ 拿到 `zh-cn` → 品牌识别失败 → 只发了通用方言。
  const oppoBrowser = 'Mozilla/5.0 (Linux; U; Android 16; zh-cn; PLR110 Build/BP2A.250605.015) '
    + 'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/115.0.5790.168 Mobile Safari/537.36';
  check('真机 UA（zh-cn; PLR110）：令牌取到 PLR110',
    PeerLivePhotoFormat.factsFromUserAgent(oppoBrowser).device, 'PLR110');
  check('真机 UA（zh-cn; PLR110）：认成 OPPO 方言', decide(oppoBrowser),
    ['android', 'OPPO', 'android', 'oppo']);
  check('英文语言段同样跳过（en-US; SM-S928B）',
    decide('Mozilla/5.0 (Linux; U; Android 14; en-US; SM-S928B Build/UP1A.231005.007) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'),
    ['android', 'Samsung', 'android', 'samsung']);
  check('只有限定词（wv）时不硬凑令牌', PeerLivePhotoFormat.factsFromUserAgent('Mozilla/5.0 (Linux; Android 10; wv)').device, '');
  check('只有限定词时回落全方言',
    decide('Mozilla/5.0 (Linux; Android 10; wv) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/99.0.0.0 Mobile Safari/537.36'),
    ['android', 'Android', 'android', 'universal']);
  check('大写语言段（ZH-CN）也跳过',
    PeerLivePhotoFormat.factsFromUserAgent('Mozilla/5.0 (Linux; Android 15; ZH-CN; CPH2451 Build/EML50P)').device,
    'CPH2451');
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) {
  process.exitCode = 1;
}
