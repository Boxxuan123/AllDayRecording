import { describe, expect, it } from '@ohos/hypium';
import { ComputerUploadConcurrency, runAdaptiveComputerUploadQueue } from '../main/ets/computer/ComputerUploadQueue';

function tick(): Promise<void> {
  return new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 1); });
}

export default function computerUploadQueueTest() {
  describe('ComputerUploadQueue', () => {
    it('limitsParallelFilesAndWaitsForEveryAcknowledgement', 0, async () => {
      let active = 0;
      let maximum = 0;
      let completed = 0;
      await runAdaptiveComputerUploadQueue(9, new ComputerUploadConcurrency(), async (): Promise<number> => {
        active += 1;
        maximum = Math.max(maximum, active);
        await tick();
        active -= 1;
        completed += 1;
        return 100;
      });
      expect(maximum).assertEqual(3);
      expect(active).assertEqual(0);
      expect(completed).assertEqual(9);
    });
    it('stopsSchedulingAndDrainsInflightFilesBeforeFailure', 0, async () => {
      let started = 0;
      let active = 0;
      let failed = false;
      try {
        await runAdaptiveComputerUploadQueue(9, new ComputerUploadConcurrency(), async (index: number): Promise<number> => {
          started += 1;
          active += 1;
          if (index === 0) {
            active -= 1;
            throw new Error('disconnected');
          }
          await tick();
          active -= 1;
          return 100;
        });
      } catch (_error) {
        failed = true;
      }
      expect(failed).assertTrue();
      expect(started).assertEqual(3);
      expect(active).assertEqual(0);
    });

    it('validatesBoundsAndCapsGrowthAtSixteen', 0, () => {
      let rejected = 0;
      [-1, 0, 17, 1.5].forEach((n: number): void => {
        try { new ComputerUploadConcurrency(n); } catch (_error) { rejected += 1; }
      });
      expect(rejected).assertEqual(4);
      const control = new ComputerUploadConcurrency(1);
      for (let window = 0; window < 30; window += 1) {
        healthyWindow(control, window * 2000);
      }
      expect(control.limit).assertEqual(16);
      control.congested(100000);
      expect(control.limit).assertEqual(8);
      control.congested(102000);
      expect(control.limit).assertEqual(4);
      control.congested(104000);
      control.congested(106000);
      expect(control.limit).assertEqual(2);
      const single = new ComputerUploadConcurrency(1);
      single.congested(0);
      expect(single.limit).assertEqual(1);
    });
    it('growsOnlyAfterEnoughRealSuccessfulTraffic', 0, () => {
      const control = new ComputerUploadConcurrency();
      for (let i = 0; i < 50; i += 1) {
        control.completed(0, 0, 2000, control.epoch);
      }
      expect(control.limit).assertEqual(3);
      const epoch = control.epoch;
      for (let i = 0; i < 3; i += 1) {
        control.completed(1000, 0, 1200, epoch);
      }
      expect(control.limit).assertEqual(3);
      control.completed(1000, 0, 1200, epoch);
      expect(control.limit).assertEqual(4);
    });
    it('backsOffOnRateDropAndHighLatency', 0, () => {
      const rate = new ComputerUploadConcurrency(8);
      healthyWindow(rate, 0);
      expect(rate.limit).assertEqual(9);
      healthyWindow(rate, 2000, 100);
      expect(rate.limit).assertEqual(4);
      const latency = new ComputerUploadConcurrency(8);
      healthyWindow(latency, 0);
      const epoch = latency.epoch;
      for (let i = 0; i < 9; i += 1) {
        latency.completed(2000, 2000, 3900, epoch);
      }
      expect(latency.limit).assertEqual(4);
      const stalled = new ComputerUploadConcurrency(8);
      stalled.completed(1000, 0, 16000, stalled.epoch);
      expect(stalled.limit).assertEqual(4);
    });
    it('holdsOnSmallDegradationAndCoalescesRetryBursts', 0, () => {
      const control = new ComputerUploadConcurrency(8);
      healthyWindow(control, 0);
      healthyWindow(control, 2000, 800);
      expect(control.limit).assertEqual(9);
      const oldEpoch = control.epoch;
      control.congested(4000);
      control.congested(4100);
      expect(control.limit).assertEqual(4);
      for (let i = 0; i < 20; i += 1) {
        control.completed(1000, 4000, 5500, oldEpoch);
      }
      expect(control.limit).assertEqual(4);
      healthyWindow(control, 6000);
      expect(control.limit).assertEqual(5);
    });
    it('shrinksDispatchWithoutReplacingInflightWorkers', 0, async () => {
      const control = new ComputerUploadConcurrency(4);
      const gates: Array<UploadGate> = [];
      let active = 0;
      const queue = runAdaptiveComputerUploadQueue(6, control, async (index: number): Promise<number> => {
        const gate = new UploadGate();
        gates.push(gate);
        active += 1;
        await gate.promise;
        active -= 1;
        return 0;
      });
      expect(gates.length).assertEqual(4);
      control.congested(0);
      gates[0].finish();
      gates[1].finish();
      await tick();
      expect(gates.length).assertEqual(4);
      expect(active).assertEqual(2);
      gates[2].finish();
      await tick();
      expect(gates.length).assertEqual(5);
      gates[3].finish();
      await tick();
      expect(gates.length).assertEqual(6);
      gates[4].finish();
      gates[5].finish();
      await queue;
      expect(active).assertEqual(0);
    });
    it('growsDispatchAndNeverOverlapsOldWorkersWithRetry', 0, async () => {
      const control = new ComputerUploadConcurrency();
      const gates: Array<UploadGate> = [];
      let now = 0;
      let settled = false;
      let active = 0;
      let failed = false;
      const queue = runAdaptiveComputerUploadQueue(20, control, async (index: number): Promise<number> => {
        const gate = new UploadGate();
        gates.push(gate);
        active += 1;
        try { await gate.promise; } finally { active -= 1; }
        return 1000;
      }, (): number => now).catch((): void => { failed = true; }).then((): void => { settled = true; });
      for (let i = 0; i < 4; i += 1) {
        now += 400;
        gates[i].finish();
        await tick();
      }
      expect(control.limit).assertEqual(4);
      expect(active).assertEqual(4);
      gates[4].fail();
      await tick();
      expect(settled).assertFalse();
      expect(control.limit).assertEqual(2);
      const started = gates.length;
      for (let i = 5; i < started; i += 1) { gates[i].finish(); }
      await queue;
      expect(failed).assertTrue();
      expect(gates.length).assertEqual(started);
      expect(active).assertEqual(0);
      await runAdaptiveComputerUploadQueue(3, new ComputerUploadConcurrency(),
        async (): Promise<number> => {
          expect(active).assertEqual(0);
          return 0;
        });
    });
    it('keepsRetryInsideItsOriginalFileWorker', 0, async () => {
      const control = new ComputerUploadConcurrency();
      const started: Array<number> = [];
      const gates: Array<UploadGate> = [];
      let attempts = 0;
      const queue = runAdaptiveComputerUploadQueue(5, control, async (index: number): Promise<number> => {
        started.push(index);
        if (index === 0) {
          attempts += 1;
          control.congested(0);
          const gate = new UploadGate();
          gates.push(gate);
          await gate.promise; // HTTP recovery owns this slot until its sequential retry finishes.
          attempts += 1;
        } else {
          await tick();
        }
        return 0;
      });
      await tick();
      expect(attempts).assertEqual(1);
      expect(started.filter((n: number): boolean => n === 0).length).assertEqual(1);
      gates[0].finish();
      await queue;
      expect(attempts).assertEqual(2);
      expect(started.length).assertEqual(5);
      expect(new Set<number>(started).size).assertEqual(5);
    });
    it('handlesEmptyQueueAndRejectsInvalidCount', 0, async () => {
      let calls = 0;
      await runAdaptiveComputerUploadQueue(0, new ComputerUploadConcurrency(), async (): Promise<number> => {
        calls += 1;
        return 0;
      });
      let failed = false;
      try {
        await runAdaptiveComputerUploadQueue(-1, new ComputerUploadConcurrency(), async (): Promise<number> => 0);
      } catch (_error) { failed = true; }
      expect(failed).assertTrue();
      expect(calls).assertEqual(0);
    });
  });
}

function healthyWindow(control: ComputerUploadConcurrency, start: number, bytes: number = 1000): void {
  const epoch = control.epoch;
  const count = Math.max(4, control.limit);
  for (let i = 0; i < count; i += 1) { control.completed(bytes, start, start + 1200, epoch); }
}

class UploadGate {
  promise: Promise<void>;
  finish: () => void = (): void => {};
  fail: () => void = (): void => {};
  constructor() {
    this.promise = new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      this.finish = resolve;
      this.fail = (): void => { reject(new Error('disconnected')); };
    });
  }
}
