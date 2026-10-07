import { ComputerConnectionError } from '../../computer/ComputerConnectionError';
import { PhoneV3ReviewAudioRetry } from '../domain/PhoneV3ReviewAudioRetry';
import { PhoneV3VoiceTask } from '../domain/PhoneV3VoiceReviewTask';
import { DeviceV3ReviewAudioResponse } from '../../computer/ComputerTransferProtocol';

export interface ReviewAudioPrefetchPort {
  loadReviewAudio(reviewId: string, prototypeId: string, prefetch: boolean): Promise<DeviceV3ReviewAudioResponse>;
  cancelReviewPrefetch(): void;
}

class PrefetchDemand {
  state: string = 'waiting';
  retryAt: number = 0;
  failures: number = 0;
}

/** Bounded cache preparation for the three visible review samples. */
export class PhoneReviewAudioPrefetch {
  private window: Array<PhoneV3VoiceTask> = [];
  private active: boolean = false;
  private foreground: boolean = true;
  private port: ReviewAudioPrefetchPort | undefined = undefined;
  private identity: string = '';
  private generation: number = 0;
  private timer: number = -1;
  private demands: Map<string, PrefetchDemand> = new Map<string, PrefetchDemand>();
  private states: Map<string, string> = new Map<string, string>();
  private changed: () => void;

  constructor(changed: () => void) { this.changed = changed; }

  state(key: string): string { return this.states.get(key) ?? '点击准备试听'; }
  demandCount(): number { return this.demands.size; }

  stop(): void {
    this.clearTimer();
    this.generation += 1;
    this.identity = '';
    this.window = [];
    this.active = false;
    this.demands.clear(); this.states.clear();
    this.port?.cancelReviewPrefetch();
    this.port = undefined;
  }

  setWindow(tasks: Array<PhoneV3VoiceTask>, active: boolean,
    foreground: boolean, port: ReviewAudioPrefetchPort | undefined): void {
    this.window = tasks; this.active = active; this.foreground = foreground; this.port = port;
    const selected = active && foreground ? tasks.slice(0, 3) : [];
    const identity = selected.map((task: PhoneV3VoiceTask): string => `${task.key}:${task.fingerprint}`).join('|');
    if (identity !== this.identity) {
      this.clearTimer(); this.identity = identity; this.generation += 1;
      port?.cancelReviewPrefetch();
      this.demands.clear(); this.states.clear();
    }
    const generation = this.generation;
    let next: Promise<void> = Promise.resolve();
    for (const task of selected) {
      if (!task.candidate.hasAudio || !task.candidate.audioContentKey) { continue; }
      let demand = this.demands.get(task.key);
      if (demand === undefined) { demand = new PrefetchDemand(); this.demands.set(task.key, demand); }
      if (demand.state !== 'waiting' || demand.retryAt > Date.now()) { continue; }
      const current = demand;
      current.state = 'running';
      next = next.then(async (): Promise<void> => {
        if (generation !== this.generation || port === undefined) { return; }
        this.states.set(task.key, '正在准备试听'); this.changed();
        try {
          await port.loadReviewAudio(task.item.reviewId, task.candidate.prototypeId, true);
          if (generation !== this.generation) { return; }
          current.state = 'ready';
          this.states.set(task.key, '已缓存，可离线试听');
        } catch (error) {
          if (generation !== this.generation) { return; }
          current.failures += 1;
          const connection = error instanceof ComputerConnectionError;
          const failure = error as ComputerConnectionError;
          const recoverable = connection &&
            ['unpaired', 'authorization', 'identity', 'tls'].indexOf(failure.category) < 0 &&
            !(failure.statusCode >= 400 && failure.statusCode < 500 && failure.statusCode !== 408 && failure.statusCode !== 429);
          current.state = recoverable || error instanceof PhoneV3ReviewAudioRetry ? 'waiting' : 'blocked';
          current.retryAt = error instanceof PhoneV3ReviewAudioRetry ? error.retryAt :
            Date.now() + Math.min(300000, 60000 * Math.pow(2, Math.min(current.failures - 1, 3)));
          this.states.set(task.key, current.state === 'blocked' ? '试听准备失败，点击查看原因' : '等待连接恢复后准备试听');
        }
        this.scheduleRetry(); this.changed();
      });
    }
    this.scheduleRetry();
  }

  private clearTimer(): void {
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
  }

  private scheduleRetry(): void {
    this.clearTimer();
    if (!this.foreground || !this.active) { return; }
    const pending = Array.from(this.demands.values()).filter((d: PrefetchDemand): boolean => d.state === 'waiting');
    if (pending.length === 0) { return; }
    const due = Math.min(...pending.map((d: PrefetchDemand): number => d.retryAt));
    const generation = this.generation;
    this.timer = setTimeout((): void => {
      this.timer = -1;
      if (generation === this.generation) { this.setWindow(this.window, this.active, this.foreground, this.port); }
    }, Math.max(1, due - Date.now()));
  }
}
