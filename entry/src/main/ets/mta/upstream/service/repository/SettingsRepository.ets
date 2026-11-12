import { preferencesRepo } from './PreferencesRepo';
let foreground: boolean = true;
export function setMtaHostForeground(active: boolean): void { foreground = active; }
export function getMtaEnabled(): boolean { return preferencesRepo.getString('enabled', 'true') === 'true'; }
export function getMtaReceiveEnabled(): boolean { return foreground && getMtaEnabled(); }
export function getMtaSimulatedBrand(): number {
  const brand = Number(preferencesRepo.getString('simulatedBrand', '255'));
  return Number.isFinite(brand) ? brand : 255;
}
// 媒体落盘交给本项目统一文件处理，不在协议服务中写入图库。
export function isSaveToGallery(): boolean { return false; }
