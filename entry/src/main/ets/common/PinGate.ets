type PinResolver = (accepted: boolean) => void;

interface PendingEntry {
  resolver: PinResolver;
  timerId: number;
}

const PIN_TIMEOUT_MS = 90000;

export class PinGate {
  private static readonly pending: Map<string, PendingEntry> = new Map();

  static request(key: string): Promise<boolean> {
    return new Promise<boolean>((resolve: (accepted: boolean) => void) => {
      const timerId = setTimeout(() => {
        const entry = PinGate.pending.get(key);
        if (entry !== undefined && entry.timerId === timerId) {
          PinGate.pending.delete(key);
          resolve(false);
        }
      }, PIN_TIMEOUT_MS);
      PinGate.pending.set(key, { resolver: resolve, timerId });
    });
  }

  static resolve(key: string, accepted: boolean): boolean {
    const entry = PinGate.pending.get(key);
    if (entry === undefined) {
      return false;
    }
    PinGate.pending.delete(key);
    clearTimeout(entry.timerId);
    entry.resolver(accepted);
    return true;
  }
}