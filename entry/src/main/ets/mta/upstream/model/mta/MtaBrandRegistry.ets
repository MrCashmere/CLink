/**
 * MtaBrandRegistry.ets — 互传联盟品牌注册表（品牌标识 ↔ 名称的单一事实源）
 *
 * 分两部分：
 * (1) 完整识别映射：品牌标识区间 → 规范英文名，依据 MTA 协议品牌 ID 区间定义
 *     （与参考实现 EasyShare/CatShare 的注册表一致），
 *     供扫描识别对方设备与协议品牌名查询；覆盖范围不随可模拟清单收敛而缩减。
 *     各区间可标注对端手机品牌专属图标（iconRes），经 resolveMtaPhoneBrandIcon
 *     供发送页 MTA 设备列表与 MTA 传输页设备卡渲染；无专属图标的品牌回退默认兜底。
 * (2) 可模拟品牌清单：用户在设置中可选择的品牌，含图标与本地化显示名资源。
 * 广播品牌字节、发送载荷品牌名与设置展示均以此注册表为准，禁止在其它位置另建品牌映射。
 */

import { MtaConstants } from '../../service/mta/MtaConstants';

/** 品牌识别映射项：一段品牌标识区间及其对外名称 */
export interface MtaBrandEntry {
  /** 区间下界（含） */
  lower: number;

  /** 区间上界（含） */
  upper: number;

  /** 品牌名称（用于展示与发送载荷 senderBrand） */
  name: string;

  /** 对端手机品牌专属图标；缺省表示无专属图标（渲染时回退默认兜底） */
  iconRes?: Resource;
}

/** 可模拟品牌项：用户在设置中可选择模拟的品牌 */
export interface MtaSelectableBrand {
  /** 规范化品牌标识（广播与设置存储用） */
  canonical: number;

  /** 规范英文名（协议字段 senderBrand 用，不随语言变化） */
  name: string;

  /** 本地化显示名资源（仅设置页展示用） */
  displayNameRes: Resource;

  /** 品牌图标资源 */
  iconRes: Resource;
}

/** 第三方品牌标识（与 MtaConstants.BRAND_ID_THIRD_PARTY 保持同值） */
export const MTA_BRAND_ID_THIRD_PARTY: number = MtaConstants.BRAND_ID_THIRD_PARTY;

/** 兜底品牌图标：未命中可模拟清单时使用（与第三方图标一致） */
const BRAND_ICON_DEFAULT: Resource = $r('app.media.ic_brand_default');

/** 构造识别映射项（避免在字面量数组中散落隐式类型上下文；iconRes 缺省表示无专属图标） */
function brand(lower: number, upper: number, name: string, iconRes?: Resource): MtaBrandEntry {
  let entry: MtaBrandEntry = {
    lower: lower,
    upper: upper,
    name: name,
    iconRes: iconRes
  };
  return entry;
}

/** 构造可模拟品牌项 */
function selectable(canonical: number, name: string, displayNameRes: Resource,
  iconRes: Resource): MtaSelectableBrand {
  let item: MtaSelectableBrand = {
    canonical: canonical,
    name: name,
    displayNameRes: displayNameRes,
    iconRes: iconRes
  };
  return item;
}

/**
 * 完整品牌识别映射（查找顺序即优先级）。
 * 具体标识项（realme/Black Shark/RedMagic/Easy Share/ROG）排在其所属通用区间之前，
 * 保证单点标识不会被区间提前吞掉。
 */
const MTA_BRAND_REGISTRY: Array<MtaBrandEntry> = [
  brand(11, 11, 'Realme', $r('app.media.ic_phone_brand_realme')),
  brand(10, 19, 'OPPO', $r('app.media.ic_phone_brand_oppo')),
  brand(20, 29, 'vivo', $r('app.media.ic_phone_brand_vivo')),
  brand(32, 32, 'Black Shark', $r('app.media.ic_phone_brand_blackshark')),
  brand(30, 39, 'Xiaomi', $r('app.media.ic_phone_brand_xiaomi')),
  brand(41, 45, 'OnePlus', $r('app.media.ic_phone_brand_oneplus')),
  brand(50, 59, 'Meizu', $r('app.media.ic_phone_brand_meizu')),
  brand(66, 66, 'RedMagic', $r('app.media.ic_phone_brand_redmagic')),
  brand(60, 69, 'Nubia', $r('app.media.ic_phone_brand_nubia')),
  brand(70, 75, 'Samsung', $r('app.media.ic_phone_brand_samsung')),
  brand(80, 89, 'ZTE', $r('app.media.ic_phone_brand_zte')),
  brand(90, 95, 'Smartisan'),
  brand(100, 109, 'Lenovo', $r('app.media.ic_phone_brand_lenovo')),
  brand(114, 114, 'Easy Share'),
  brand(110, 119, 'Motorola', $r('app.media.ic_phone_brand_motorola')),
  brand(120, 129, 'NIO'),
  brand(130, 139, 'Pixel', $r('app.media.ic_phone_brand_pixel')),
  brand(140, 149, 'Honor', $r('app.media.ic_phone_brand_honor')),
  brand(160, 160, 'ROG', $r('app.media.ic_phone_brand_rog')),
  brand(161, 169, 'ASUS', $r('app.media.ic_phone_brand_asus')),
  brand(170, 179, 'Hisense', $r('app.media.ic_phone_brand_hisense')),
  brand(MTA_BRAND_ID_THIRD_PARTY, MTA_BRAND_ID_THIRD_PARTY, '第三方')
];

/**
 * 可模拟品牌清单：默认「第三方」在前，随后为 8 个主流品牌。
 * 顺序固定（第三方 → Xiaomi → OPPO → vivo → Honor → OnePlus → realme → Samsung → Meizu），供 UI 与单测使用。
 */
const MTA_SELECTABLE_BRANDS: Array<MtaSelectableBrand> = [
  selectable(MTA_BRAND_ID_THIRD_PARTY, '第三方',
    $r('app.string.brand_name_third_party'), $r('app.media.ic_brand_default')),
  selectable(30, 'Xiaomi', $r('app.string.brand_name_xiaomi'), $r('app.media.ic_brand_xiaomi')),
  selectable(10, 'OPPO', $r('app.string.brand_name_oppo'), $r('app.media.ic_brand_oppo')),
  selectable(20, 'vivo', $r('app.string.brand_name_vivo'), $r('app.media.ic_brand_vivo')),
  selectable(140, 'Honor', $r('app.string.brand_name_honor'), $r('app.media.ic_brand_honor')),
  selectable(42, 'OnePlus', $r('app.string.brand_name_oneplus'), $r('app.media.ic_brand_oneplus')),
  selectable(11, 'Realme', $r('app.string.brand_name_realme'), $r('app.media.ic_brand_realme')),
  selectable(70, 'Samsung', $r('app.string.brand_name_samsung'), $r('app.media.ic_brand_samsung')),
  selectable(50, 'Meizu', $r('app.string.brand_name_meizu'), $r('app.media.ic_brand_meizu'))
];

/** 按品牌标识查找识别映射项；未命中返回 undefined */
export function mtaBrandEntryOf(brandId: number): MtaBrandEntry | undefined {
  for (let i = 0; i < MTA_BRAND_REGISTRY.length; i++) {
    let entry = MTA_BRAND_REGISTRY[i];
    if (brandId >= entry.lower && brandId <= entry.upper) {
      return entry;
    }
  }
  return undefined;
}

/**
 * 品牌标识 → 规范英文名（覆盖完整识别映射）。
 * 未命中注册表返回 `未知(id)`（展示层可回退为固定文案）。
 */
export function resolveMtaBrandName(brandId: number): string {
  let entry = mtaBrandEntryOf(brandId);
  return entry !== undefined ? entry.name : `未知(${brandId})`;
}

/** 品牌标识是否已注册（第三方视为已注册） */
export function isRegisteredMtaBrand(brandId: number): boolean {
  return mtaBrandEntryOf(brandId) !== undefined;
}

/** 规范化品牌标识：未注册或越界值一律按第三方处理 */
export function normalizeMtaBrandId(brandId: number): number {
  return isRegisteredMtaBrand(brandId) ? brandId : MTA_BRAND_ID_THIRD_PARTY;
}

/** 可模拟品牌清单（顺序固定，返回副本避免外部修改） */
export function mtaSelectableBrands(): Array<MtaSelectableBrand> {
  return MTA_SELECTABLE_BRANDS.slice();
}

/** 按标识查找可模拟品牌项；未命中返回 undefined */
export function mtaSelectableBrandOf(brandId: number): MtaSelectableBrand | undefined {
  for (let i = 0; i < MTA_SELECTABLE_BRANDS.length; i++) {
    if (MTA_SELECTABLE_BRANDS[i].canonical === brandId) {
      return MTA_SELECTABLE_BRANDS[i];
    }
  }
  return undefined;
}

/**
 * 品牌标识 → 本地化显示名（仅设置页使用）。
 * 命中可模拟清单返回其显示名资源；已注册但不在清单内（历史选择）回退规范英文名；
 * 未注册回退第三方显示名资源。
 */
export function resolveMtaBrandDisplayName(brandId: number): ResourceStr {
  let option = mtaSelectableBrandOf(brandId);
  if (option !== undefined) {
    return option.displayNameRes;
  }
  let entry = mtaBrandEntryOf(brandId);
  if (entry !== undefined) {
    return entry.name;
  }
  return MTA_SELECTABLE_BRANDS[0].displayNameRes;
}

/** 品牌标识 → 图标资源（未命中可模拟清单回退默认图标） */
export function resolveMtaBrandIcon(brandId: number): Resource {
  let option = mtaSelectableBrandOf(brandId);
  return option !== undefined ? option.iconRes : BRAND_ICON_DEFAULT;
}

/**
 * 品牌标识 → 对端手机品牌图标（发送页 MTA 设备列表条目与 MTA 传输页设备卡共用，
 * 保证同一设备两处图标一致）。
 * 命中注册表条目且有专属图标返回之；未注册或无专属图标
 * （Smartisan / Easy Share / NIO / 第三方等）回退默认兜底图标；恒返回有效资源。
 */
export function resolveMtaPhoneBrandIcon(brandId: number): Resource {
  let entry = mtaBrandEntryOf(brandId);
  return entry !== undefined && entry.iconRes !== undefined ? entry.iconRes : BRAND_ICON_DEFAULT;
}
