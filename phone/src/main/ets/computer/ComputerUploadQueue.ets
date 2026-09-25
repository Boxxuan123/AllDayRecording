// Each epoch measures only files started at the same target concurrency.
// A retry invalidates older successes; a burst of retries backs off only once/second.
export class ComputerUploadConcurrency {
  private target: number;
  epoch: number = 0;
  private lastDecrease: number = -Infinity;
  private windowStarted: number = 0;
  private successes: number = 0;
  private bytes: number = 0;
  private latency: number = 0;
  private previousRate: number = 0;
  private previousLatency: number = 0;

  constructor(initial: number = 3) {
    if (!Number.isSafeInteger(initial) || initial < 1 || initial > 16) {
      throw new Error('上传并发必须在 1 到 16 之间');
    }
    this.target = initial;
  }

  get limit(): number {
    return this.target;
  }

  congested(now: number): void {
    if (now - this.lastDecrease >= 1000) {
      this.target = Math.min(this.limit, Math.max(2, Math.floor(this.limit / 2)));
      this.lastDecrease = now;
    }
    this.reset();
    this.previousRate = 0;
    this.previousLatency = 0;
  }

  completed(bytes: number, started: number, now: number, epoch: number): void {
    if (epoch !== this.epoch || bytes <= 0) {
      return; // Skips/resumed bytes are not network throughput.
    }
    const elapsed = Math.max(1, now - started);
    if (elapsed > Math.max(15000, this.previousLatency * 2)) {
      this.congested(now);
      return;
    }
    if (this.successes === 0) {
      this.windowStarted = started;
    }
    this.windowStarted = Math.min(this.windowStarted, started);
    this.successes += 1;
    this.bytes += bytes;
    this.latency += elapsed;
    const windowMs = now - this.windowStarted;
    if (this.successes < Math.max(4, this.limit) || windowMs < 1000) {
      return;
    }
    const rate = this.bytes / windowMs;
    const latency = this.latency / this.successes;
    if (this.previousRate > 0 &&
      (rate < this.previousRate * 0.85 || latency > this.previousLatency * 1.5)) {
      this.congested(now);
      return;
    }
    // Small fluctuations hold the target; only a healthy window probes +1.
    if (this.previousRate === 0 ||
      (rate >= this.previousRate * 0.95 && latency <= this.previousLatency * 1.2)) {
      this.target = Math.min(16, this.limit + 1);
    }
    this.previousRate = rate;
    this.previousLatency = latency;
    this.reset();
  }

  private reset(): void {
    this.epoch += 1;
    this.successes = 0;
    this.bytes = 0;
    this.latency = 0;
  }
}

// One dispatcher owns all indices. Shrinking never cancels or replaces workers.
// Drain in-flight work on failure before returning, so a retry never races old workers.
export async function runAdaptiveComputerUploadQueue(count: number, control: ComputerUploadConcurrency,
  upload: (index: number) => Promise<number>, clock: () => number = Date.now): Promise<void> {
  if (!Number.isSafeInteger(count) || count < 0) {
    throw new Error('上传队列大小无效');
  }
  let nextIndex = 0;
  let active = 0;
  let failure: Error | undefined = undefined;
  await new Promise<void>((resolve: () => void): void => {
    const pump = (): void => {
      while (failure === undefined && nextIndex < count && active < control.limit) {
        const index = nextIndex++;
        const started = clock();
        const epoch = control.epoch;
        active += 1;
        const execute = async (): Promise<void> => {
          try {
            const bytes = await upload(index);
            control.completed(bytes, started, clock(), epoch);
          } catch (error) {
            control.congested(clock());
            if (failure === undefined) {
              failure = error instanceof Error ? error : new Error(JSON.stringify(error));
            }
          } finally {
            active -= 1;
            pump();
          }
        };
        execute();
      }
      if (active === 0 && (failure !== undefined || nextIndex === count)) {
        resolve();
      }
    };
    pump();
  });
  if (failure !== undefined) {
    throw new Error((failure as Error).message);
  }
}

