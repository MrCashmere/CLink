// MtaProgressUtil：MTA 互传进度口径与接收校验上限相关的纯逻辑（无 UI / 系统 IO 依赖，可单元测试）。
// 进度口径统一为「实际字节 ÷ sendRequest 声明的原始总大小」：发送端分子为已读源字节
// （由 Rust 流式写出过程上报），接收端分子为已解压字节（由 Rust 流式解压会话返回）。
// 本文件保留发送完成态进度解析、进度上报时间节流，以及解压总量上限的计算。

import { MtaSendProgress } from '../model/mta/MtaSendModels';
import { MtaConstants } from '../service/mta/MtaConstants';

/** 进度上报默认最小间隔（毫秒），与发送端节流间隔同量级 */
const DEFAULT_REPORT_INTERVAL_MS: number = 200;

/**
 * 由对端声明的原始总大小计算允许的解压总量上限。
 *
 * 声明值 ≤0（缺失/非法/非有限）时取未知声明兜底；否则取「声明值 + max(容差下限, 声明值 × 容差比例)」，
 * 再以接收总大小上限封顶。与对端 MTA 设备的解压总量校验语义一致
 * （参考实现 EasyShare 的 maxActualBytes 同此口径）。
 */
export function resolveMaxActualBytes(declaredTotal: number): number {
  if (!(declaredTotal > 0)) {
    return MtaConstants.UNZIP_FALLBACK_TOTAL_BYTES;
  }
  let tolerance = Math.max(MtaConstants.UNZIP_TOLERANCE_MIN_BYTES,
    declaredTotal * MtaConstants.UNZIP_TOLERANCE_RATIO);
  let allowed = declaredTotal + Math.ceil(tolerance);
  return Math.min(allowed, MtaConstants.MAX_UNZIP_TOTAL_BYTES);
}

/**
 * 计算发送完成态进度：总量优先沿用最近一次传输进度中的源总大小，
 * 从未收到进度时才回退声明总量；已发送字节等于总量、百分比为 100。
 * 网络字节累计原样保留（速率口径的终值，供完成态展示或诊断对照）。
 */
export function resolveSendCompletedProgress(last: MtaSendProgress, declaredTotal: number): MtaSendProgress {
  let total = last.totalBytes > 0 ? last.totalBytes : declaredTotal;
  if (total < 0) {
    total = 0;
  }
  let progress = new MtaSendProgress();
  progress.sentBytes = total;
  progress.totalBytes = total;
  progress.percent = 100;
  progress.networkBytes = last.networkBytes;
  return progress;
}

/**
 * 进度上报时间节流器：限制进度向展示层的上报频率；完成事件不受最小间隔限制，
 * 必须及时送达。复位用于新会话开始或会话终结。
 */
export class ProgressReportThrottle {
  /** 最小上报间隔（毫秒） */
  private readonly minIntervalMs: number;
  /** 最近一次上报时间（0 表示尚未上报） */
  private lastReportAt: number = 0;

  constructor(minIntervalMs: number = DEFAULT_REPORT_INTERVAL_MS) {
    this.minIntervalMs = minIntervalMs;
  }

  /** 判断当前是否应上报；完成事件无条件允许并刷新计时 */
  shouldReport(now: number, isComplete: boolean): boolean {
    if (isComplete) {
      this.lastReportAt = now;
      return true;
    }
    if (this.lastReportAt === 0 || now - this.lastReportAt >= this.minIntervalMs) {
      this.lastReportAt = now;
      return true;
    }
    return false;
  }

  /** 复位节流状态（新会话开始或会话终结时调用） */
  reset(): void {
    this.lastReportAt = 0;
  }
}
