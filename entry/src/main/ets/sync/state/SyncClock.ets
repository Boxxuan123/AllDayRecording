export type SyncScheduledTask = number;
export type SyncScheduledCallback = () => void;

export interface SyncClock {
  now(): number;
  schedule(delayMs: number, callback: SyncScheduledCallback): SyncScheduledTask;
  cancel(task: SyncScheduledTask): void;
}

export class SystemSyncClock implements SyncClock {
  now(): number {
    return Date.now();
  }

  schedule(delayMs: number, callback: SyncScheduledCallback): SyncScheduledTask {
    return setTimeout(callback, delayMs);
  }

  cancel(task: SyncScheduledTask): void {
    clearTimeout(task);
  }
}
