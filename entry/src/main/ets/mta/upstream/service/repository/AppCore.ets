const listeners: Set<() => void> = new Set<() => void>();
export function notifyChange(): void { listeners.forEach((listener: () => void): void => listener()); }
export function onMtaHostChange(listener: () => void): void { listeners.add(listener); }
