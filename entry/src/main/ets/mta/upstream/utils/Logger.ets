import { LogCapture } from '../../../common/LogCapture';
export class MtaHostLogger {
  private tag: string;
  constructor(tag: string) { this.tag = tag; }
  debug(message: string): void { LogCapture.d(this.tag + ' ' + message); }
  info(message: string): void { LogCapture.i(this.tag + ' ' + message); }
  warn(message: string): void { LogCapture.w(this.tag + ' ' + message); }
  error(message: string): void { LogCapture.e(this.tag + ' ' + message); }
  fatal(message: string): void { LogCapture.e(this.tag + ' ' + message); }
  log(level: string, message: string): void {
    if (level === 'error' || level === 'fatal') { this.error(message); }
    else if (level === 'warn') { this.warn(message); }
    else if (level === 'debug') { this.debug(message); }
    else { this.info(message); }
  }
}
export function getLogger(domain: number, tag: string, label: string): MtaHostLogger {
  return new MtaHostLogger(tag);
}
