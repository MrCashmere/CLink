// LargeTransferUtil：大文件提示阈值相关的纯逻辑（无 UI / 系统 IO 依赖，可单元测试）。
// 功能上限取消后，仅以阈值判定是否需要提示用户大文件传输可能失败，不拦截传输。

import { MtaConstants } from '../service/mta/MtaConstants';

/**
 * 是否达到大文件提示阈值（总大小或任一单文件达到 10GB）。
 * @param totalBytes 本次传输总字节数
 * @param maxSingleBytes 本次传输中最大的单文件字节数（未知时传 0，只按总量判定）
 */
export function isLargeTransfer(totalBytes: number, maxSingleBytes: number = 0): boolean {
  return totalBytes >= MtaConstants.LARGE_FILE_WARN_BYTES ||
    maxSingleBytes >= MtaConstants.LARGE_FILE_WARN_BYTES;
}
