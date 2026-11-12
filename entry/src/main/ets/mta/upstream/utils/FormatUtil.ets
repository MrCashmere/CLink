// FormatUtil：文件大小和时间戳的纯展示格式化辅助。

// 时间展示口径：yyyy-MM-dd HH:mm:ss（全局统一精确到秒）。
export function formatTime(timestamp: number): string {
  let date = new Date(timestamp);
  let y = date.getFullYear();
  let m = (date.getMonth() + 1).toString().padStart(2, '0');
  let d = date.getDate().toString().padStart(2, '0');
  let h = date.getHours().toString().padStart(2, '0');
  let min = date.getMinutes().toString().padStart(2, '0');
  let sec = date.getSeconds().toString().padStart(2, '0');
  return y + '-' + m + '-' + d + ' ' + h + ':' + min + ':' + sec;
}

// 1000 进制四级单位换算（B/KB/MB/GB），返回 [数值文本, 单位]。
function scaleBytes(size: number): Array<string> {
  if (size < 1000) {
    return [Math.round(size).toString(), 'B'];
  }
  if (size < 1000 * 1000) {
    return [(size / 1000).toFixed(1), 'KB'];
  }
  if (size < 1000 * 1000 * 1000) {
    return [(size / 1000 / 1000).toFixed(1), 'MB'];
  }
  return [(size / 1000 / 1000 / 1000).toFixed(1), 'GB'];
}

// 文件大小展示唯一实现：1000 进制，含 B/KB/MB/GB 档。
export function formatSizeDetailed(size: number): string {
  let scaled = scaleBytes(size);
  return scaled[0] + ' ' + scaled[1];
}

// 传输速度展示：1000 进制智能单位切换（B/s → KB/s → MB/s → GB/s），与 formatSizeDetailed 一致。
export function formatSpeed(bytesPerSec: number): string {
  if (bytesPerSec < 0) {
    return '0 B/s';
  }
  let scaled = scaleBytes(bytesPerSec);
  return scaled[0] + ' ' + scaled[1] + '/s';
}

// 剩余时间展示：< 1 小时用 mm:ss，≥ 1 小时用 hh:mm:ss；不可计算时返回 '--'。
export function formatDuration(seconds: number): string {
  if (seconds < 0 || !isFinite(seconds)) {
    return '--';
  }
  let totalSec: number = Math.floor(seconds);
  let h: number = Math.floor(totalSec / 3600);
  let m: number = Math.floor((totalSec % 3600) / 60);
  let s: number = totalSec % 60;
  if (h > 0) {
    return h.toString() + ':' + m.toString().padStart(2, '0') + ':' + s.toString().padStart(2, '0');
  }
  return m.toString().padStart(2, '0') + ':' + s.toString().padStart(2, '0');
}

// 中间缩略：长度不足时原样返回；超长时保留首尾字符、中间以省略号连接（供信息区块与设备指纹统一复用）。
export function abbreviateMiddle(value: string, headLen: number, tailLen: number): string {
  if (value.length <= headLen + tailLen + 1) {
    return value;
  }
  return value.substring(0, headLen) + '…' + value.substring(value.length - tailLen);
}

// 异常转可读文本：优先取 BusinessError 风格的 code/message，其次 Error.message。
export function errorText(e: Object): string {
  let obj = e as Record<string, Object>;
  let codeVal = obj['code'];
  let msgVal = obj['message'];
  if (codeVal !== undefined && msgVal !== undefined) {
    return `[${codeVal}] ${msgVal}`;
  }
  if (e instanceof Error) {
    let err = e as Error;
    return err.message.length > 0 ? err.message : '未知错误';
  }
  return '未知错误';
}
