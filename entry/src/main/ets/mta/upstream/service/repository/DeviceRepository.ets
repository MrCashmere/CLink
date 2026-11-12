import { SettingsStore } from '../../../../common/SettingsStore';
export function getDeviceAlias(): string { return SettingsStore.current().alias; }
