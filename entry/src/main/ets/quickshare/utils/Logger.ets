import { LogCapture as Lg } from '../../common/LogCapture';
export type QuickShareLogTag = 'BLE' | 'mDNS' | 'PROTO' | 'UKEY2' | 'TCP' | 'UI';

export class QuickShareLogger {
  log(tag: QuickShareLogTag, message: string): void {
    Lg.i('[' + tag + '] ' + message);
  }

  warn(tag: QuickShareLogTag, message: string): void {
    Lg.w('[' + tag + '] ' + message);
  }
}
