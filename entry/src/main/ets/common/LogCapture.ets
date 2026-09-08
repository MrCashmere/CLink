import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

// 应用内自采集日志：替代"只能靠 hdc/hilog 抓日志"的排障方式。
// 所有 console.info/warn/error/debug（经 Lg.i/w/e/d 统一入口）除了照常进 hilog，
// 还会追加写入应用沙箱下的日志文件；设置页可一键"保存到下载文件夹"导出。
//
// 存储：
//   <filesDir>/applog/applog.txt     当前日志（上限 64MB，超限轮转删旧重建）
// 注：本文件内部自己不上报日志（避免自旋），打开/写失败一律静默降级。

const LOG_DIR_NAME = 'applog';
const LOG_FILE_NAME = 'applog.txt';
const MAX_LOG_BYTES = 8 * 1024 * 1024; // 当前日志文件上限 8MB，超限后轮转（删旧重建）
// 攒够 FLUSH_THRESHOLD_BYTES 才落盘一次，避免每行都 open/close 文件造成额外 CPU/IO 开销。
const FLUSH_THRESHOLD_BYTES = 16 * 1024; // 16KB

export class LogCapture {
  private static logDir = '';
  private static logFile = '';
  private static downloadDirUri = '';
  private static pendingLines: string[] = [];
  private static pendingBytes = 0;

  /** 必须在应用启动早期（EntryAbility.onCreate）调用一次，之后才落盘。 */
  static init(context: common.Context): void {
    if (LogCapture.logDir !== '') {
      return;
    }
    try {
      LogCapture.logDir = context.filesDir + '/' + LOG_DIR_NAME;
      fs.mkdirSync(LogCapture.logDir);
      LogCapture.logFile = LogCapture.logDir + '/' + LOG_FILE_NAME;
    } catch (e) {
      // 沙箱目录缺失/只读时降级为仅 hilog，不阻塞应用。
      LogCapture.logDir = '';
      LogCapture.logFile = '';
    }
  }

  static i(...args: Object[]): void { LogCapture.write('I', args); }
  static w(...args: Object[]): void { LogCapture.write('W', args); }
  static e(...args: Object[]): void { LogCapture.write('E', args); }
  static d(...args: Object[]): void { LogCapture.write('D', args); }

  /** 当前日志落盘路径（未初始化时为空字符串）。 */
  static currentPath(): string { return LogCapture.logFile; }

  /** 清空当前日志与待写缓冲。 */
  static clear(): void {
    LogCapture.pendingLines = [];
    LogCapture.pendingBytes = 0;
    try {
      if (LogCapture.logFile !== '') { fs.unlinkSync(LogCapture.logFile); }
    } catch (e) { }
  }

  /**
   * 把当前日志文件"另存到下载文件夹"：
   * 弹系统保存对话框（默认落在下载目录、文件名预填为 applog_<时间戳>.txt），
   * 用户确认后把沙箱日志拷贝过去。返回是否保存成功（取消返回 false）。
   */
  static async saveCurrent(context: common.UIAbilityContext): Promise<boolean> {
    if (LogCapture.logFile === '') {
      LogCapture.init(context);
    }
    const path = LogCapture.logFile;
    if (path === '') {
      return false;
    }
    // 先落盘缓冲中的日志，保证导出文件完整。
    LogCapture.flush();
    // 确保文件存在（可能一条日志都还没写）。
    try {
      fs.statSync(path);
    } catch (e) {
      try {
        const f = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
        fs.closeSync(f);
      } catch (e2) {
        return false;
      }
    }
    let srcFd = -1;
    let dstFd = -1;
    try {
      const savePicker = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSaveOptions();
      options.pickerMode = picker.DocumentPickerMode.DEFAULT;
      options.newFileNames = [LogCapture.saveName()];
      // 解析系统下载目录（仅首次走 DOWNLOAD 模式获取，之后缓存），让弹窗默认落在下载目录。
      if (LogCapture.downloadDirUri.length === 0) {
        try {
          const dirPicker = new picker.DocumentViewPicker(context);
          const dirOptions = new picker.DocumentSaveOptions();
          dirOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
          const dirs = await dirPicker.save(dirOptions);
          if (dirs.length > 0) {
            LogCapture.downloadDirUri = dirs[0] ?? '';
          }
        } catch (dirError) {
          // 解析失败不阻塞：弹窗仍可用，用户手动选目录。
        }
      }
      if (LogCapture.downloadDirUri.length > 0) {
        options.defaultFilePathUri = LogCapture.downloadDirUri;
      }
      const uris = await savePicker.save(options);
      if (uris.length === 0) {
        return false; // 用户取消
      }
      const dest = uris[0] ?? '';
      if (dest.length === 0) {
        return false;
      }
      // DEFAULT 模式会预建空文件，用 TRUNC 覆盖为日志内容。
      srcFd = fs.openSync(path, fs.OpenMode.READ_ONLY).fd;
      dstFd = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC).fd;
      const buf = new ArrayBuffer(1024 * 1024);
      let n = fs.readSync(srcFd, buf);
      while (n > 0) {
        fs.writeSync(dstFd, buf.slice(0, n));
        n = fs.readSync(srcFd, buf);
      }
      fs.closeSync(srcFd);
      srcFd = -1;
      fs.closeSync(dstFd);
      dstFd = -1;
      return true;
    } catch (e) {
      return false;
    } finally {
      try {
        if (srcFd >= 0) { fs.closeSync(srcFd); }
      } catch (closeError) { }
      try {
        if (dstFd >= 0) { fs.closeSync(dstFd); }
      } catch (closeError) { }
    }
  }

  private static saveName(): string {
    const d = new Date();
    const pad = (v: number): string => (v < 10 ? '0' + v : '' + v);
    return 'applog_' + d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate())
      + '_' + pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds()) + '.txt';
  }

  private static write(level: string, args: Object[]): void {
    const msg = LogCapture.join(args);
    // 保持 hilog 侧行为不变，确保原有 console 排查链路仍然可用。
    try {
      if (level === 'I') { console.info(msg); }
      else if (level === 'W') { console.warn(msg); }
      else if (level === 'E') { console.error(msg); }
      else { console.debug(msg); }
    } catch (e) { }
    if (LogCapture.logFile === '') { return; }
    try {
      const line = new Date().toISOString() + ' ' + level + ' ' + msg + '\n';
      LogCapture.pendingLines.push(line);
      LogCapture.pendingBytes += line.length;
      // 批量落盘：攒够阈值才写一次文件，显著减少系统调用次数。
      if (LogCapture.pendingBytes >= FLUSH_THRESHOLD_BYTES) {
        LogCapture.flush();
      }
    } catch (e) { }
  }

  private static flush(): void {
    if (LogCapture.logFile === '' || LogCapture.pendingLines.length === 0) {
      return;
    }
    const batch = LogCapture.pendingLines.join('');
    LogCapture.pendingLines = [];
    LogCapture.pendingBytes = 0;
    try {
      LogCapture.rotateIfNeeded(batch.length);
      const file = fs.openSync(LogCapture.logFile,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      fs.writeSync(file.fd, batch);
      fs.closeSync(file);
    } catch (e) {
      // 落盘失败时丢弃本批，避免无限重试占用 CPU。
    }
  }

  private static join(args: Object[]): string {
    const parts: string[] = [];
    for (let i = 0; i < args.length; i++) {
      const a: Object = args[i];
      if (a === undefined || a === null) {
        parts.push('');
      } else if (typeof a === 'string' || a instanceof String) {
        parts.push(a as string);
      } else if (typeof a === 'object') {
        parts.push(JSON.stringify(a));
      } else {
        parts.push(String(a));
      }
    }
    return parts.join(' ');
  }

  private static rotateIfNeeded(newLineLen: number): void {
    try {
      const st = fs.statSync(LogCapture.logFile);
      if (st.size + newLineLen <= MAX_LOG_BYTES) {
        return;
      }
      // 当前日志轮转为 old，之后 write 会在 CREATE 模式下重建当前文件。
      fs.moveFileSync(LogCapture.logFile, LogCapture.logDir + '/applog.old.txt', 1);
    } catch (e) { }
  }
}
