/**
 * JsonGuard.ets — JSON 动态取值的统一守卫（跨模块公用）
 *
 * 项目内 JSON.parse 结果的动态取值一律经本模块收口，调用方不再手写
 * `obj[key]` 与类型断言。文件内唯一的 `as` 收敛于此，供形状校验使用。
 */

/** 收窄为字符串键表：非对象或数组返回 undefined。 */
function asRecord(obj: Object): Record<string, Object> | undefined {
  if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) {
    return undefined;
  }
  return obj as Record<string, Object>;
}

/** 读取字符串字段，缺失或类型不符返回默认值。 */
export function readJsonString(obj: Object, key: string, fallback: string): string {
  let table: Record<string, Object> | undefined = asRecord(obj);
  if (table === undefined) {
    return fallback;
  }
  let value: Object | undefined = table[key];
  return typeof value === 'string' ? value : fallback;
}

/** 读取数字字段，缺失或类型不符返回默认值。 */
export function readJsonNumber(obj: Object, key: string, fallback: number): number {
  let table: Record<string, Object> | undefined = asRecord(obj);
  if (table === undefined) {
    return fallback;
  }
  let value: Object | undefined = table[key];
  return typeof value === 'number' ? value : fallback;
}

/** 读取原始字段，缺失返回 undefined，由调用方再做类型守卫。 */
export function readJsonField(obj: Object, key: string): Object | undefined {
  let table: Record<string, Object> | undefined = asRecord(obj);
  if (table === undefined) {
    return undefined;
  }
  return table[key];
}
