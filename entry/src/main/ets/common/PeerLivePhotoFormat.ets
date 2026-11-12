/**
 * 对端平台/品牌识别，以及「这张动态图片该按哪种格式发给它」的决策。
 *
 * 背景：动态图片没有跨平台统一格式 —— Apple 只认「实况照片」（JPEG + MOV 成对、
 * 靠资产标识配对），Android 阵营认的是 Google 相机那套「Motion Photo」（JPEG 尾部
 * 追加 MP4 + XMP 声明），鸿蒙则用系统动态照片。所以发送前要先判断对端是什么设备。
 *
 * 识别来源只有发现阶段拿到的那点信息（设备名、型号、协议、设备类型），因此这里全部是
 * **关键字启发式**：
 *  - 认不出品牌时**不猜**，回落到用户设置的「默认通用动态图片格式」；
 *  - 鸿蒙 / 华为 / 荣耀**不转换**（对端很可能就是本应用，直接发「图片 + 视频」最稳，
 *    接收端已验证可还原）；
 *  - Windows PC 不转换（没有实况照片概念，拆开发用户反而拿得到视频）；
 *  - macOS 按 Apple 实况照片发（「照片」App 支持导入实况照片）。
 *
 * 本模块是纯函数，便于在 tests/dp-format 里直接跑用例。
 */

import { DeviceEndpoint } from '../model/TransferModels';
import { AndroidMotionDialect } from './LivePhotoWriter';

/** 发送时的目标封装格式：拆成图片+视频 / Apple 实况照片 / Android 标准动态照片。 */
export type LivePhotoFormat = 'split' | 'apple' | 'android';

/** 设置页「默认通用动态图片格式」的取值（只含两种可写出的格式）。 */
export type FallbackLivePhotoFormat = 'apple' | 'android';

/** 识别出的对端平台。 */
export type PeerPlatform = 'apple' | 'harmony' | 'android' | 'windows' | 'desktop' | 'unknown';

/** 识别输入（只取与判断有关的字段）。 */
export interface PeerIdentity {
  readonly name: string;
  readonly model: string;
  readonly protocol: string;
  readonly deviceType?: number;
}

/** 识别结论。 */
export interface PeerDecision {
  readonly platform: PeerPlatform;
  /** 命中的品牌名（用于日志/UI，未命中为空串）。 */
  readonly brand: string;
  readonly format: LivePhotoFormat;
  /** `format === 'android'` 时叠加哪家的私有字段（识别不出对端时用通用方言）。 */
  readonly dialect: AndroidMotionDialect;
  /** 判定理由（写日志用，避免「为什么没转换」这类问题只能靠猜）。 */
  readonly reason: string;
}

interface BrandRule {
  readonly platform: PeerPlatform;
  readonly brand: string;
  /** Android 品牌的私有方言（平台不是 android 时忽略）。 */
  readonly dialect: AndroidMotionDialect;
  readonly keywords: string[];
}

/**
 * 关键字表（全部小写；按「先 Apple → 再鸿蒙/华为/荣耀 → 再 Windows → 再 Android 品牌」的顺序匹配）。
 *
 * 注意顺序：`honor`（荣耀，鸿蒙/安卓两代都有）按鸿蒙处理（不转换，宁可稳）；
 * `huawei`/`harmony` 同理。
 */
const BRAND_RULES: BrandRule[] = [
  {
    platform: 'apple', brand: 'Apple', dialect: 'google',
    keywords: ['iphone', 'ipad', 'ipod', 'apple', 'macbook', 'imac', 'mac mini', 'macmini',
      'mac studio', 'macstudio', 'mac pro', 'macpro', 'macos', 'mac os', 'darwin', 'os x',
      'vision pro', 'airdrop']
  },
  {
    platform: 'harmony', brand: 'HarmonyOS', dialect: 'google',
    keywords: ['harmony', 'harmonyos', 'hongmeng', 'hmos', 'huawei', 'honor', '华为', '荣耀', '鸿蒙', '羊绒互传']
  },
  {
    platform: 'android', brand: 'Xiaomi', dialect: 'xiaomi',
    keywords: ['xiaomi', 'redmi', 'poco', '小米', '红米']
  },
  {
    platform: 'android', brand: 'OPPO', dialect: 'oppo',
    keywords: ['oppo', 'realme', 'oneplus', 'one plus', '一加', '真我']
  },
  {
    platform: 'android', brand: 'vivo', dialect: 'vivo',
    keywords: ['vivo', 'iqoo']
  },
  {
    platform: 'android', brand: 'Samsung', dialect: 'samsung',
    keywords: ['samsung', 'galaxy', 'sm-', 'sm_', '三星']
  },
  {
    platform: 'android', brand: 'Google', dialect: 'google',
    keywords: ['pixel', 'google']
  },
  {
    platform: 'android', brand: 'Meizu', dialect: 'google',
    keywords: ['meizu', '魅族']
  },
  {
    platform: 'android', brand: 'ZTE', dialect: 'google',
    keywords: ['zte', 'nubia', 'red magic', '中兴', '努比亚']
  },
  {
    platform: 'android', brand: 'Motorola', dialect: 'google',
    keywords: ['motorola', 'moto ', 'moto g', 'moto edge']
  },
  {
    platform: 'android', brand: 'Nothing', dialect: 'google',
    keywords: ['nothing phone', 'nothing (']
  },
  {
    platform: 'android', brand: 'Sony', dialect: 'google',
    keywords: ['xperia', 'sony']
  },
  {
    platform: 'android', brand: 'ASUS', dialect: 'google',
    keywords: ['asus', 'zenfone', 'rog phone']
  },
  {
    platform: 'android', brand: 'Transsion', dialect: 'google',
    keywords: ['infinix', 'tecno', 'itel']
  },
  {
    platform: 'android', brand: 'Android', dialect: 'google',
    keywords: ['android', 'aosp', 'lineage']
  }
];

/** Windows 关键字：协议已经说明是 Windows Nearby 时不再看关键字。 */
const WINDOWS_KEYWORDS: string[] = [
  'windows', 'laptop-', 'desktop-', 'thinkpad', 'surface', 'win10', 'win11', 'pc-', 'msi ', 'aspire'
];

function lower(text: string): string {
  return text.toLowerCase();
}

/**
 * 浏览器 UA 里的设备识别规则（**网页传输**用：网页端没有 LocalSend 注册信息，只有 UA）。
 *
 * 为什么不用关键字满串搜：UA 里除了设备令牌还塞着厂商自家的 App/浏览器名
 * （`XiaoMi/MiuiBrowser`、`V2251/15 (vivo;V22...)`、`TwitterAndroid/...`），
 * 满串搜容易命中「评论里提到的别家品牌」。所以这里**先取出设备令牌**（`Android 14; CPH2449 Build/…`
 * 里的 `CPH2449`），令牌优先按各家的**型号编码规则**匹配，匹配不上再看品牌自报名关键字。
 *
 * 令牌规则依据真实 UA 样本（见 `tests/dp-format/dialect-useragent.mjs` 的用例，样本来源
 * 写在 docs/DYNAMIC_PHOTO.md §3.5）：
 *  - OPPO / 一加：`CPH####`、`PGBM10`/`PGT110`/`PJD110`、一加 `LE2100`/`IN2013`/`NE2210`/`KB2001`/`MT2110`；
 *  - realme：`RMX####`；
 *  - 小米 / Redmi / POCO：`22101316C`、`2407FPN8ER`（4~9 位数字开头再接字母）、`M2101K6G`、`Redmi …`、`POCO …`；
 *  - vivo / iQOO：`V2251`、`V2243A`（iQOO 也用 V 编码）；
 *  - 三星：`SM-S928B`；
 *  - Pixel：`Pixel 8`；
 *  - 华为 / 荣耀：`ELS-NX9`、`ANY-LX1`（三字母-字母数字，且 UA 里通常还有 HMSCore/MagicOS）。
 */
interface UserAgentRule {
  readonly brand: string;
  readonly platform: PeerPlatform;
  readonly dialect: AndroidMotionDialect;
  /** 设备令牌必须整体匹配的正则（源码字符串，避免 ArkTS 正则字面量歧义）。 */
  readonly token: string;
  /** 令牌没匹配上时的兜底关键字（品牌自报名，全部小写）。 */
  readonly keywords: string[];
}

const UA_RULES: UserAgentRule[] = [
  {
    brand: 'OPPO', platform: 'android', dialect: 'oppo',
    token: '^(CPH\\d{3,4}|RMX\\d{4}|P[A-Z]{2,3}\\d{2,3}|(AC|GM|HD|IN|KB|LE|MT|NE|ON|IV)\\d{3,4}|OPPO [A-Z0-9]+)$',
    keywords: ['oppo', 'oneplus', 'one plus', 'realme', 'oplus', '一加', '真我']
  },
  {
    brand: 'Xiaomi', platform: 'android', dialect: 'xiaomi',
    token: '^(M\\d{4}[A-Z0-9]+|\\d{4,9}[A-Z][A-Z0-9]*|Mi \\d.*|Redmi.*|POCO.*|Xiaomi.*)$',
    keywords: ['xiaomi', 'miui', 'redmi', 'poco', '小米', '红米']
  },
  {
    brand: 'vivo', platform: 'android', dialect: 'vivo',
    token: '^V\\d{4}[A-Z]?$',
    keywords: ['vivo', 'iqoo']
  },
  {
    brand: 'Samsung', platform: 'android', dialect: 'samsung',
    token: '^SM-[A-Z0-9]+$',
    keywords: ['samsung', 'galaxy', 'sm-']
  },
  {
    brand: 'Google', platform: 'android', dialect: 'google',
    token: '^Pixel( [A-Za-z0-9 ]+)?$',
    keywords: ['pixel']
  },
  {
    // 华为/荣耀按鸿蒙处理（不转换）：UA 里通常带 HMSCore / HarmonyOS / MagicOS / EMUI。
    brand: 'Huawei', platform: 'harmony', dialect: 'google',
    token: '^[A-Z]{3}-[A-Z0-9]{2,}$',
    keywords: ['huawei', 'honor', 'harmony', 'hmos', 'magicos', 'emui', 'hmscore', '华为', '荣耀', '鸿蒙']
  }
];

/** 鸿蒙平台判据（UA 里出现即认定，不看设备令牌）。 */
const UA_HARMONY_TOKENS: string[] = [
  'harmonyos', 'openharmony', 'arkweb', 'hmscore', 'huaweibrowser', 'hmos', 'magicos'
];

/** 命中 UA 事实（内部用；导出是为了让 Node 用例能直接断言令牌提取）。 */
export interface UserAgentFacts {
  readonly raw: string;
  readonly text: string;
  readonly device: string;
  readonly android: boolean;
}

function matchesAny(haystack: string, keywords: string[]): string {
  for (const keyword of keywords) {
    if (haystack.indexOf(keyword) >= 0) {
      return keyword;
    }
  }
  return '';
}

export class PeerLivePhotoFormat {
  static readonly APPLE: FallbackLivePhotoFormat = 'apple';
  static readonly ANDROID: FallbackLivePhotoFormat = 'android';

  /** 从发现阶段的设备信息里取判断所需字段。 */
  static identityOf(device: DeviceEndpoint): PeerIdentity {
    return {
      name: device.name !== undefined ? device.name : '',
      model: device.model !== undefined ? device.model : '',
      protocol: device.protocol,
      deviceType: device.deviceType
    };
  }

  /** 识别对端平台（纯启发式，认不出返回 unknown）。 */
  static detect(peer: PeerIdentity): PeerDecision {
    // 本应用自己的 catshare 协议对端：一定也是鸿蒙，不需要转换。
    if (peer.protocol === 'catshare') {
      return {
        platform: 'harmony', brand: 'Cashmere Link', format: 'split',
        dialect: 'google', reason: 'protocol:catshare'
      };
    }
    const haystack = lower(peer.name + ' ' + peer.model);
    for (const rule of BRAND_RULES) {
      const hit = matchesAny(haystack, rule.keywords);
      if (hit.length > 0) {
        return {
          platform: rule.platform, brand: rule.brand, format: 'split',
          dialect: rule.dialect, reason: 'keyword:' + hit
        };
      }
    }
    if (peer.protocol === 'windowsnearby') {
      return {
        platform: 'windows', brand: 'Windows', format: 'split',
        dialect: 'google', reason: 'protocol:windowsnearby'
      };
    }
    const windowsHit = matchesAny(haystack, WINDOWS_KEYWORDS);
    if (windowsHit.length > 0) {
      return {
        platform: 'windows', brand: 'Windows', format: 'split',
        dialect: 'google', reason: 'keyword:' + windowsHit
      };
    }
    return {
      platform: 'unknown', brand: '', format: 'split', dialect: 'google', reason: 'no-match'
    };
  }

  /**
   * 决策：对端支持的动态图片格式。
   *
   * 顺序：Apple → Apple 实况照片；识别得出的 Android 品牌 → 该品牌方言的动态照片；
   * 鸿蒙 / 华为 / 荣耀 / 本应用 → 不转换（拆成「图片 + 视频」，接收端已验证）；
   * 电脑（Windows）→ 不转换；**认不出对端** → 才回落到设置里的「默认通用动态图片格式」。
   *
   * @param peer 对端标识
   * @param fallback 认不出对端时用的默认格式（设置页「默认通用动态图片格式」）
   */
  static resolve(peer: PeerIdentity, fallback: FallbackLivePhotoFormat): PeerDecision {
    const detected = PeerLivePhotoFormat.detect(peer);
    if (detected.platform === 'apple') {
      return {
        platform: 'apple', brand: detected.brand, format: 'apple',
        dialect: detected.dialect, reason: detected.reason
      };
    }
    if (detected.platform === 'android') {
      return {
        platform: 'android', brand: detected.brand, format: 'android',
        dialect: detected.dialect, reason: detected.reason
      };
    }
    if (detected.platform === 'harmony') {
      return {
        platform: 'harmony', brand: detected.brand, format: 'split',
        dialect: detected.dialect, reason: 'harmony-no-convert'
      };
    }
    if (detected.platform === 'windows') {
      return {
        platform: 'windows', brand: detected.brand, format: 'split',
        dialect: detected.dialect, reason: 'windows-no-convert'
      };
    }
    return {
      platform: 'unknown',
      brand: '',
      format: fallback === PeerLivePhotoFormat.APPLE ? 'apple' : 'android',
      // 认不出对端品牌时用「全方言」：OPPO/一加、小米、vivo 的私有字段一次全写
      // （各家只读自己命名空间，陌生的忽略）。真机踩过：对端是 OnePlus，但广播的名字里
      // 没有品牌关键字 → 只写 Google 那段，OPPO 相册不当自家动态照片。
      dialect: 'universal',
      reason: 'fallback:' + fallback
    };
  }

  /** 是否按 Apple 实况照片发送（用于日志/UI 文案）。 */
  static isApple(format: LivePhotoFormat): boolean {
    return format === 'apple';
  }

  // ── 网页传输：从浏览器 UA 识别设备（网页端没有 LocalSend 注册信息，只有请求头里的 UA）──

  /**
   * 从 UA 里取出判断所需的几个事实。
   *
   * 设备令牌取 `Android <版本>; <令牌> Build/…` 里的 `<令牌>`：这是各家浏览器/WebView 写真实
   * 型号的位置。真机踩到的坑：国产浏览器会在版本后面再插一段**语言**，例如
   * `(Linux; U; Android 16; zh-cn; PLR110 Build/BP2A.250605.015)` —— 直接取「版本后的第一段」
   * 会拿到 `zh-cn`，于是 OPPO 手机被认成「Android 但认不出品牌」（真机日志：
   * `reason=ua:android-unknown-brand ua=…zh-cn; PLR110…`）。所以要把语言/限定词跳掉，取**倒数第一段**
   * 非限定词的令牌。
   */
  static factsFromUserAgent(userAgent: string): UserAgentFacts {
    const raw = userAgent.length > 0 ? userAgent : '';
    const text = lower(raw);
    let device = '';
    const group = new RegExp('android([^)]*)', 'i').exec(raw);
    if (group !== null && group.length > 1) {
      const parts = group[1].split(';');
      for (let i = parts.length - 1; i >= 0; i--) {
        const candidate = parts[i].trim().replace(new RegExp('\\s+build/.*$', 'i'), '').trim();
        if (candidate.length === 0 || PeerLivePhotoFormat.isUserAgentQualifier(candidate)) {
          continue;
        }
        device = candidate;
        break;
      }
    }
    return {
      raw: raw,
      text: text,
      device: device,
      android: text.indexOf('android') >= 0
    };
  }

  /** UA 里那些不是设备型号的限定词（版本号、语言、`wv`、`U`、`Mobile`…）。 */
  private static isUserAgentQualifier(token: string): boolean {
    const value = token.trim();
    const lowered = lower(value);
    if (lowered === 'u' || lowered === 'wv' || lowered === 'mobile' || lowered === 'tablet' || lowered === 'tv') {
      return true;
    }
    // 纯版本号（`16` / `16.0` / `16.0.0`）
    if (new RegExp('^[0-9]+(\\.[0-9]+)*$').test(value)) {
      return true;
    }
    // 语言/地区（`zh-cn`、`en-US`、`pt-BR`）
    if (new RegExp('^[a-z]{2,3}(-[a-zA-Z]{2,4})?$').test(value)) {
      return true;
    }
    return false;
  }

  /**
   * 从浏览器 UA 判断对端设备 → 该发哪种动态图片格式。
   *
   * 与 `resolve()`（基于发现阶段的设备名/型号）的区别：UA 是网页端**唯一**能拿到的设备线索，
   * 且它是「对端自己报的」，比拼设备名靠谱（真机踩过：对端叫「皓然的手机」，名字里没有任何品牌线索）。
   *
   * 判定顺序（宁可不动，也不要猜错）：Apple → 鸿蒙/华为/荣耀 → Android 品牌 → 桌面 → 认不出。
   * **认不出时返回 `split`（原样发文件）而不是回落设置**：网页端可能是 curl/wget/未知客户端，
   * 原样给字节永远是对的；转发成动态照片反而可能让对端拿到一个读不了的文件。
   */
  static resolveForUserAgent(userAgent: string): PeerDecision {
    const facts = PeerLivePhotoFormat.factsFromUserAgent(userAgent);
    if (facts.raw.length === 0) {
      return {
        platform: 'unknown', brand: '', format: 'split', dialect: 'google', reason: 'ua:empty'
      };
    }
    const text = facts.text;
    const device = facts.device;

    // 1. Apple（iOS 与 macOS 都按实况照片那套，配对靠资产标识）
    if (text.indexOf('iphone') >= 0 || text.indexOf('ipad') >= 0 || text.indexOf('ipod') >= 0) {
      return { platform: 'apple', brand: 'Apple', format: 'apple', dialect: 'google', reason: 'ua:ios' };
    }
    if (text.indexOf('macintosh') >= 0 || text.indexOf('mac os x') >= 0) {
      return { platform: 'apple', brand: 'Apple', format: 'apple', dialect: 'google', reason: 'ua:macos' };
    }

    // 2. 鸿蒙 / 华为 / 荣耀：对端多半自己就认这套动态照片，不转换最稳
    for (const token of UA_HARMONY_TOKENS) {
      if (text.indexOf(token) >= 0) {
        return {
          platform: 'harmony', brand: 'HarmonyOS', format: 'split', dialect: 'google',
          reason: 'ua:harmony:' + token
        };
      }
    }

    // 3. Android：先按设备令牌匹配型号编码，再按品牌自报名兜底
    if (facts.android) {
      const byToken = PeerLivePhotoFormat.matchByToken(device);
      if (byToken !== undefined) {
        return byToken;
      }
      const byKeyword = PeerLivePhotoFormat.matchByKeyword(text, device);
      if (byKeyword !== undefined) {
        return byKeyword;
      }
      // Android 但认不出品牌：全方言（各家只读自己命名空间，陌生命名空间被忽略）
      return {
        platform: 'android', brand: 'Android', format: 'android', dialect: 'universal',
        reason: 'ua:android-unknown-brand'
      };
    }

    // 4. 桌面：Windows / Linux / 其它桌面系统都不转换（没有动态照片概念，拆开发用户反而拿得到视频）
    if (text.indexOf('windows nt') >= 0 || text.indexOf('win64') >= 0 || text.indexOf('win32') >= 0) {
      return {
        platform: 'windows', brand: 'Windows', format: 'split', dialect: 'google',
        reason: 'ua:windows'
      };
    }
    if (text.indexOf('linux') >= 0 || text.indexOf('x11') >= 0 || text.indexOf('cros ') >= 0) {
      return {
        platform: 'desktop', brand: 'Desktop', format: 'split', dialect: 'google',
        reason: 'ua:desktop-linux'
      };
    }
    return {
      platform: 'unknown', brand: '', format: 'split', dialect: 'google', reason: 'ua:no-match'
    };
  }

  /**
   * 按**型号编码**匹配设备令牌（最可靠：`CPH2449`、`SM-S928B`、`V2251`、`22101316C` 都是各家自报的真型号）。
   */
  private static matchByToken(device: string): PeerDecision | undefined {
    const token = device.trim();
    if (token.length === 0) {
      return undefined;
    }
    for (const rule of UA_RULES) {
      if (new RegExp(rule.token).test(token)) {
        return PeerLivePhotoFormat.decisionOf(rule, 'ua:device-code:' + token);
      }
    }
    return undefined;
  }

  /**
   * 按**品牌自报名**兜底（`XiaoMi/MiuiBrowser`、`OPPO A79k`、`Galaxy`…）。
   *
   * 令牌与整串一起看：有的设备令牌是营销名（`Redmi Note 12 Pro`）而不是编码。
   */
  private static matchByKeyword(text: string, device: string): PeerDecision | undefined {
    const hay = text + ' ' + lower(device);
    for (const rule of UA_RULES) {
      const hit = matchesAny(hay, rule.keywords);
      if (hit.length > 0) {
        return PeerLivePhotoFormat.decisionOf(rule, 'ua:keyword:' + hit);
      }
    }
    return undefined;
  }

  private static decisionOf(rule: UserAgentRule, reason: string): PeerDecision {
    return {
      platform: rule.platform,
      brand: rule.brand,
      format: rule.platform === 'android' ? 'android' : 'split',
      dialect: rule.dialect,
      reason: reason
    };
  }

  static formatLabel(format: LivePhotoFormat): string {
    if (format === 'apple') {
      return 'Apple 实况照片';
    }
    if (format === 'android') {
      return 'Android 动态照片';
    }
    return '图片 + 视频';
  }

  /** 方言的中文名（写日志用）。 */
  static dialectLabel(dialect: AndroidMotionDialect): string {
    if (dialect === 'xiaomi') {
      return '小米';
    }
    if (dialect === 'oppo') {
      return 'OPPO/realme/一加';
    }
    if (dialect === 'vivo') {
      return 'vivo/iQOO';
    }
    if (dialect === 'samsung') {
      return '三星';
    }
    if (dialect === 'universal') {
      return '通用多方言（OPPO/小米/vivo 字段同写）';
    }
    return 'Google 通用';
  }

  /** 设置项文案。 */
  static fallbackLabel(fallback: FallbackLivePhotoFormat): string {
    return fallback === PeerLivePhotoFormat.APPLE ? 'Apple 实况照片' : 'Android 标准动态照片';
  }

  /** 归一化设置里读到的字符串（非法值一律回落 android）。 */
  static parseFallback(value: string): FallbackLivePhotoFormat {
    return value === PeerLivePhotoFormat.APPLE ? PeerLivePhotoFormat.APPLE : PeerLivePhotoFormat.ANDROID;
  }
}
