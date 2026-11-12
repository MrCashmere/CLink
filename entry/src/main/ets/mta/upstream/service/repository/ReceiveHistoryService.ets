import { ReceiveHistoryEntry } from '../../model/Types';
import { preferencesRepo } from './PreferencesRepo';
import { getLogger } from '../../utils/Logger';
const logger = getLogger(6, 'MTA:History', '历史');
export function listMtaReceiveHistory(): ReceiveHistoryEntry[] {
  try {
    const entries: ReceiveHistoryEntry[] = JSON.parse(preferencesRepo.getString('receiveHistory', '[]')) as ReceiveHistoryEntry[];
    return Array.isArray(entries) ? entries : [];
  } catch (error) { logger.warn('读取接收历史失败：' + String(error)); return []; }
}
export function addEntries(entries: ReceiveHistoryEntry[]): void {
  try {
    preferencesRepo.setString('receiveHistory', JSON.stringify(entries.concat(listMtaReceiveHistory()).slice(0, 500)));
  } catch (error) { logger.warn('保存接收历史失败：' + String(error)); }
}
