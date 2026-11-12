/**
 * LogLevels.ets — 日志级别 token 单一事实源
 *
 * 统一规范五级日志标识（英文小写 debug/info/warn/error/fatal），供 MTA 服务、
 * 调试 ViewModel、页面渲染与导出文本共用，避免级别魔法字符串在各处重复。
 *
 * 同时提供归一/校验纯函数：
 * - normalizeLevel：把 Rust `log` crate 级别（trace 等）与未知值归一到规范 token
 * - isValidLevel：判断 token 是否为规范五级之一
 */

export class LogLevels {
  /** 诊断/状态变化细节 */
  static readonly DEBUG: string = 'debug';
  /** 关键流程节点 */
  static readonly INFO: string = 'info';
  /** 可恢复告警 */
  static readonly WARN: string = 'warn';
  /** 失败 */
  static readonly ERROR: string = 'error';
  /** 致命不可恢复 */
  static readonly FATAL: string = 'fatal';
}

/** 判断 token 是否为规范五级之一 */
export function isValidLevel(token: string): boolean {
  return token === LogLevels.DEBUG ||
    token === LogLevels.INFO ||
    token === LogLevels.WARN ||
    token === LogLevels.ERROR ||
    token === LogLevels.FATAL;
}

/**
 * 归一级别 token：
 * - 规范五级原样返回（大小写不敏感，统一转为小写）
 * - Rust `log` crate 的 `trace` 归一到 `debug`
 * - 其余未知/非法值兜底为 `info`
 */
export function normalizeLevel(token: string): string {
  let lower = token.toLowerCase();
  if (lower === 'trace') {
    return LogLevels.DEBUG;
  }
  if (isValidLevel(lower)) {
    return lower;
  }
  return LogLevels.INFO;
}
