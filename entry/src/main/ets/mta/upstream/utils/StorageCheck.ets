// StorageCheck：接收落盘前存储预留检查的纯逻辑（无 UI / 系统 IO 依赖，可单元测试）。
// 可用空间查询（statfs.getFreeSize）由调用方执行，本模块只做判定，查询失败由调用方按放行处理。

/** 接收落盘前要求的额外可用空间（字节，覆盖解压与元数据开销；与 MTA 预留量同值）。 */
export const RECEIVE_STORAGE_RESERVE_BYTES: number = 256 * 1024 * 1024;

/** 存储预留检查结果：充足 / 不足 / 未知（可用空间不可得，调用方放行并留痕）。 */
export enum StorageCheckVerdict {
  sufficient = 'sufficient',
  insufficient = 'insufficient',
  unknown = 'unknown'
}

/**
 * 判定落盘目录可用空间是否满足「声明大小 + 预留量」。
 * @param freeBytes 可用字节数（负数表示查询失败）
 * @param declaredBytes 对端声明的总字节数
 * @param reserveBytes 额外预留量（覆盖解压与元数据开销）
 */
export function decideStorageCheck(freeBytes: number, declaredBytes: number,
  reserveBytes: number): StorageCheckVerdict {
  if (freeBytes < 0) {
    return StorageCheckVerdict.unknown;
  }
  let required: number = declaredBytes + reserveBytes;
  return freeBytes >= required ? StorageCheckVerdict.sufficient : StorageCheckVerdict.insufficient;
}
