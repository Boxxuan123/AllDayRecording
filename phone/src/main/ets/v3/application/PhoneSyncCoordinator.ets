import { ComputerConnectionError } from '../../computer/ComputerConnectionError';

export class PhoneSyncWorkResult {
  again: boolean;
  pollMs: number;
  completed: boolean;
  constructor(again: boolean = false, pollMs: number = 0, completed: boolean = true) {
    this.again = again; this.pollMs = pollMs; this.completed = completed;
  }
}
export interface PhoneSyncCoordinatorPort {
  light: () => Promise<PhoneSyncWorkResult>;
  backup: () => Promise<PhoneSyncWorkResult>;
  cancelLight: () => void;
  changed: () => void;
}
export class PhoneSyncLane {
  running: boolean = false;
  pending: boolean = false;
  blocked: boolean = false;
  error: string = '';
  successAt: number = 0;
  failures: number = 0;
  due: number = 0;
}
// One owner per ViewModel. No HTTP/client/global database lock is owned here.
export class PhoneSyncCoordinator {
  light: PhoneSyncLane = new PhoneSyncLane();
  backup: PhoneSyncLane = new PhoneSyncLane();
  paused: boolean = false;
  private foreground: boolean = false;
  private stopped: boolean = false;
  private idleWaiters: Array<() => void> = [];
  private timer: number = -1;
  private port: PhoneSyncCoordinatorPort;
  constructor(port: PhoneSyncCoordinatorPort) { this.port = port; }
  setForeground(value: boolean): void {
    this.foreground = value;
    if (!value) { this.clearTimer(); this.port.cancelLight(); }
    else { this.trigger(); }
  }
  trigger(backup: boolean = false, manual: boolean = false): void {
    if (this.stopped || this.paused) { return; }
    this.light.pending = true;
    if (this.light.failures === 0) { this.light.due = 0; }
    if (backup) { this.backup.pending = true; }
    if (backup && this.backup.failures === 0) { this.backup.due = 0; }
    if (manual) {
      this.light.blocked = false; this.light.due = 0;
      if (backup) { this.backup.blocked = false; this.backup.due = 0; }
    }
    this.schedule();
  }
  pause(): void {
    this.paused = true; this.clearTimer(); this.port.cancelLight(); this.port.changed();
  }
  resume(): void { this.paused = false; this.trigger(true, true); this.port.changed(); }
  stop(): void { this.stopped = true; this.foreground = false; this.clearTimer(); this.port.cancelLight(); }
  async whenIdle(): Promise<void> {
    if (!this.light.running && !this.backup.running) { return; }
    await new Promise<void>((resolve): void => { this.idleWaiters.push(resolve); });
  }
  private clearTimer(): void { if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; } }
  private schedule(): void {
    if (!this.foreground || this.stopped || this.paused) { return; }
    this.clearTimer();
    const lanes = [this.light, this.backup].filter((lane): boolean => lane.pending && !lane.running && !lane.blocked);
    if (lanes.length === 0) { return; }
    const due = Math.min(...lanes.map((lane): number => lane.due));
    this.timer = setTimeout((): void => {
      this.timer = -1;
      this.run(this.light, false); this.run(this.backup, true);
    }, Math.max(250, due - Date.now()));
  }
  private run(lane: PhoneSyncLane, backup: boolean): void {
    if (!this.foreground || this.stopped || this.paused || lane.running || lane.blocked || !lane.pending) { return; }
    if (lane.due > Date.now()) { this.schedule(); return; }
    lane.running = true; lane.pending = false; lane.error = ''; this.port.changed();
    const work = backup ? this.port.backup() : this.port.light();
    work.then((result): void => {
      lane.failures = 0;
      if (result.completed) { lane.successAt = Date.now(); }
      const triggered = lane.pending;
      lane.pending = triggered || result.again || result.pollMs > 0;
      lane.due = triggered || result.again ? 0 : Date.now() + result.pollMs;
    }).catch((error: Object): void => {
      lane.error = error instanceof Error ? error.message : '同步失败';
      lane.failures += 1;
      const failure = error as ComputerConnectionError;
      lane.blocked = ['unpaired', 'authorization', 'identity', 'tls'].indexOf(failure.category) >= 0 ||
        (failure.statusCode >= 400 && failure.statusCode < 500 && failure.statusCode !== 408 && failure.statusCode !== 429) ||
        !(error instanceof ComputerConnectionError);
      lane.pending = true;
      lane.due = Date.now() + Math.min(300000, 2000 * Math.pow(2, Math.min(lane.failures, 7)) *
        (0.8 + Math.random() * 0.4));
    }).finally((): void => {
      lane.running = false;
      if (!this.light.running && !this.backup.running) {
        for (let resolve of this.idleWaiters) { resolve(); }
        this.idleWaiters = [];
      }
      if (backup && !this.stopped && !this.paused) {
        this.light.pending = true;
        if (this.light.failures === 0) { this.light.due = 0; }
      }
      if (!this.stopped) { this.port.changed(); this.schedule(); }
    });
  }
}
