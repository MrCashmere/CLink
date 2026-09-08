interface Waiter<T> {
  resolve: (value: T) => void;
  reject: (error: Error) => void;
  timer: number;
  settled: boolean;
}

/**
 * Type-keyed async frame inbox.
 *
 * Fixes the "frame eating" bug of the legacy FrameInbox:nnext(): when a waiter
 * times out it is now *removed* from the pending list, so a later frame of the
 * same type is never handed to a stale (already-rejected) resolver again.
 */
export class GsFrameInbox<T> {
  private readonly queued: Map<number, T[]> = new Map();
  private readonly waiters: Map<number, Waiter<T>[]> = new Map();

  queuedCount(key: number): number {
    const queue = this.queued.get(key);
    return queue === undefined ? 0 : queue.length;
  }

  deliver(key: number, value: T): void {
    const pending = this.waiters.get(key);
    if (pending !== undefined) {
      while (pending.length > 0) {
        const waiter = pending.shift();
        if (waiter === undefined || waiter.settled) {
          continue;
        }
        clearTimeout(waiter.timer);
        waiter.settled = true;
        waiter.resolve(value);
        return;
      }
    }
    let queue = this.queued.get(key);
    if (queue === undefined) {
      queue = [];
      this.queued.set(key, queue);
    }
    queue.push(value);
  }

  next(key: number, timeoutMs: number): Promise<T> {
    const queue = this.queued.get(key);
    if (queue !== undefined && queue.length > 0) {
      const value = queue.shift();
      if (value !== undefined) {
        return Promise.resolve(value);
      }
    }
    return new Promise<T>((resolve: (value: T) => void, reject: (error: Error) => void) => {
      let pending = this.waiters.get(key);
      if (pending === undefined) {
        pending = [];
        this.waiters.set(key, pending);
      }
      const waiter: Waiter<T> = { resolve, reject, timer: -1, settled: false };
      waiter.timer = setTimeout((): void => {
        this.onTimeout(key, waiter);
      }, timeoutMs);
      pending.push(waiter);
    });
  }

  private onTimeout(key: number, waiter: Waiter<T>): void {
    if (waiter.settled) {
      return;
    }
    waiter.settled = true;
    const pending = this.waiters.get(key);
    if (pending !== undefined) {
      const index = pending.indexOf(waiter);
      if (index >= 0) {
        pending.splice(index, 1);
      }
    }
    waiter.reject(new Error(`timeout waiting for frame ${key}`));
  }

  reset(): void {
    this.queued.clear();
    this.waiters.forEach((pending: Waiter<T>[]) => {
      for (const waiter of pending) {
        if (!waiter.settled) {
          clearTimeout(waiter.timer);
          waiter.settled = true;
          waiter.reject(new Error('frame inbox reset'));
        }
      }
    });
    this.waiters.clear();
  }
}