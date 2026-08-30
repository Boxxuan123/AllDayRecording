import { WatchSyncFileDescriptor } from '../../models/RecordingModels';
import { SyncClock, SyncScheduledTask, SystemSyncClock } from '../state/SyncClock';

export const WATCH_SYNC_IDLE: string = 'idle';
export const WATCH_SYNC_MANUAL: string = 'manual';
export const WATCH_SYNC_AUTOMATIC: string = 'automatic';
export const WATCH_MANUAL_START: string = 'start';
export const WATCH_MANUAL_QUEUED: string = 'queued';
export const WATCH_MANUAL_DUPLICATE: string = 'duplicate';
export const WATCH_AUTOMATIC_RETRY_INITIAL_DELAY_MS: number = 35 * 1000;
export const WATCH_AUTOMATIC_RETRY_MAX_DELAY_MS: number = 5 * 60 * 1000;

export interface WatchManualSyncRequest {
  requestId: string;
  knownFileKeys: Array<string>;
}

export interface WatchManualSyncDecision {
  action: string;
  request: WatchManualSyncRequest;
}

export function watchFileTransferKey(descriptor: WatchSyncFileDescriptor): string {
  return `${descriptor.requestId}\n${descriptor.index}\n${descriptor.relativePath}`;
}

export class WatchSyncCoordinator {
  private stateValue: string = WATCH_SYNC_IDLE;
  private activeManualRequestId: string = '';
  private pendingManualRequest: WatchManualSyncRequest | undefined = undefined;

  requestManual(requestId: string, knownFileKeys: Array<string>): WatchManualSyncDecision {
    const request: WatchManualSyncRequest = {
      requestId: requestId,
      knownFileKeys: knownFileKeys.slice()
    };
    if (requestId === this.activeManualRequestId ||
      (this.pendingManualRequest !== undefined && this.pendingManualRequest.requestId === requestId)) {
      return { action: WATCH_MANUAL_DUPLICATE, request: request };
    }
    if (this.stateValue !== WATCH_SYNC_IDLE) {
      this.pendingManualRequest = request;
      return { action: WATCH_MANUAL_QUEUED, request: request };
    }
    this.stateValue = WATCH_SYNC_MANUAL;
    this.activeManualRequestId = requestId;
    return { action: WATCH_MANUAL_START, request: request };
  }

  beginAutomatic(): boolean {
    if (this.stateValue !== WATCH_SYNC_IDLE || this.pendingManualRequest !== undefined) {
      return false;
    }
    this.stateValue = WATCH_SYNC_AUTOMATIC;
    return true;
  }

  finishCurrent(): void {
    this.stateValue = WATCH_SYNC_IDLE;
    this.activeManualRequestId = '';
  }

  takePendingManual(): WatchManualSyncRequest | undefined {
    if (this.stateValue !== WATCH_SYNC_IDLE || this.pendingManualRequest === undefined) {
      return undefined;
    }
    const request = this.pendingManualRequest;
    this.pendingManualRequest = undefined;
    this.stateValue = WATCH_SYNC_MANUAL;
    this.activeManualRequestId = request.requestId;
    return request;
  }

  isBusy(): boolean {
    return this.stateValue !== WATCH_SYNC_IDLE;
  }

  isManual(): boolean {
    return this.stateValue === WATCH_SYNC_MANUAL;
  }

  isAutomatic(): boolean {
    return this.stateValue === WATCH_SYNC_AUTOMATIC;
  }

  hasPendingManual(): boolean {
    return this.pendingManualRequest !== undefined;
  }

  state(): string {
    return this.stateValue;
  }
}

export class WatchAutomaticRetryCoordinator {
  private clock: SyncClock;
  private initialDelayMs: number;
  private maximumDelayMs: number;
  private failureCountValue: number = 0;
  private retryAtValue: number = 0;
  private scheduledTask: SyncScheduledTask = -1;

  constructor(initialDelayMs: number = WATCH_AUTOMATIC_RETRY_INITIAL_DELAY_MS,
    maximumDelayMs: number = WATCH_AUTOMATIC_RETRY_MAX_DELAY_MS, clock?: SyncClock) {
    this.initialDelayMs = initialDelayMs;
    this.maximumDelayMs = maximumDelayMs;
    this.clock = clock !== undefined ? clock : new SystemSyncClock();
  }

  defer(): number {
    this.cancelScheduled();
    this.failureCountValue += 1;
    const exponent = Math.min(this.failureCountValue - 1, 16);
    const delayMs = Math.min(this.initialDelayMs * Math.pow(2, exponent), this.maximumDelayMs);
    this.retryAtValue = this.clock.now() + delayMs;
    return delayMs;
  }

  scheduleIfCoolingDown(callback: () => void): boolean {
    const delayMs = this.remainingMs();
    if (delayMs <= 0) {
      return false;
    }
    if (this.scheduledTask >= 0) {
      return true;
    }
    this.scheduledTask = this.clock.schedule(delayMs, () => {
      this.scheduledTask = -1;
      callback();
    });
    return true;
  }

  markSuccess(): void {
    this.cancelScheduled();
    this.failureCountValue = 0;
    this.retryAtValue = 0;
  }

  cancelScheduled(): void {
    if (this.scheduledTask >= 0) {
      this.clock.cancel(this.scheduledTask);
      this.scheduledTask = -1;
    }
  }

  remainingMs(): number {
    return Math.max(0, this.retryAtValue - this.clock.now());
  }

  failureCount(): number {
    return this.failureCountValue;
  }
}

export type WatchFileAckResolve = () => void;
export type WatchFileAckReject = (error: Error) => void;

export class WatchFileAckCoordinator {
  private clock: SyncClock;
  private progressStallTimeoutMs: number;
  private durableAckTimeoutMs: number;
  private activeKeyValue: string = '';
  private lastProgressValue: number = -1;
  private waitingForAckValue: boolean = false;
  private progressTask: SyncScheduledTask = -1;
  private ackTask: SyncScheduledTask = -1;
  private resolveHandler: WatchFileAckResolve | undefined = undefined;
  private rejectHandler: WatchFileAckReject | undefined = undefined;

  constructor(progressStallTimeoutMs: number, durableAckTimeoutMs: number, clock?: SyncClock) {
    this.progressStallTimeoutMs = progressStallTimeoutMs;
    this.durableAckTimeoutMs = durableAckTimeoutMs;
    this.clock = clock !== undefined ? clock : new SystemSyncClock();
  }

  begin(descriptor: WatchSyncFileDescriptor, resolve: WatchFileAckResolve,
    reject: WatchFileAckReject): void {
    if (this.activeKeyValue.length > 0) {
      throw new Error('上一片文件仍在等待手机持久化回执');
    }
    this.activeKeyValue = watchFileTransferKey(descriptor);
    this.lastProgressValue = -1;
    this.waitingForAckValue = false;
    this.resolveHandler = resolve;
    this.rejectHandler = reject;
    this.refreshProgressTimeout();
  }

  progress(descriptor: WatchSyncFileDescriptor, progress: number): boolean {
    if (watchFileTransferKey(descriptor) !== this.activeKeyValue || this.activeKeyValue.length === 0) {
      return false;
    }
    const bounded = Math.max(0, Math.min(100, Math.floor(progress)));
    if (bounded < this.lastProgressValue) {
      return false;
    }
    const increased = bounded > this.lastProgressValue;
    this.lastProgressValue = bounded;
    if (bounded >= 100) {
      this.startAckTimeout();
    } else if (increased) {
      this.refreshProgressTimeout();
    }
    return true;
  }

  acknowledge(descriptor: WatchSyncFileDescriptor): boolean {
    if (watchFileTransferKey(descriptor) !== this.activeKeyValue || this.resolveHandler === undefined) {
      return false;
    }
    const resolve = this.resolveHandler;
    this.clear();
    resolve();
    return true;
  }

  fail(error: Error): boolean {
    if (this.activeKeyValue.length === 0 || this.rejectHandler === undefined) {
      return false;
    }
    const reject = this.rejectHandler;
    this.clear();
    reject(error);
    return true;
  }

  failForKey(key: string, error: Error): boolean {
    if (key !== this.activeKeyValue) {
      return false;
    }
    return this.fail(error);
  }

  clear(): void {
    if (this.progressTask >= 0) {
      this.clock.cancel(this.progressTask);
    }
    if (this.ackTask >= 0) {
      this.clock.cancel(this.ackTask);
    }
    this.activeKeyValue = '';
    this.lastProgressValue = -1;
    this.waitingForAckValue = false;
    this.progressTask = -1;
    this.ackTask = -1;
    this.resolveHandler = undefined;
    this.rejectHandler = undefined;
  }

  activeKey(): string {
    return this.activeKeyValue;
  }

  lastProgress(): number {
    return this.lastProgressValue;
  }

  waitingForAck(): boolean {
    return this.waitingForAckValue;
  }

  private refreshProgressTimeout(): void {
    if (this.progressTask >= 0) {
      this.clock.cancel(this.progressTask);
    }
    const expectedKey = this.activeKeyValue;
    this.progressTask = this.clock.schedule(this.progressStallTimeoutMs, () => {
      if (this.activeKeyValue !== expectedKey || this.waitingForAckValue) {
        return;
      }
      this.progressTask = -1;
      this.fail(new Error('Wear Engine 通信失败：文件传输进度 60 秒未变化'));
    });
  }

  private startAckTimeout(): void {
    if (this.waitingForAckValue) {
      return;
    }
    this.waitingForAckValue = true;
    if (this.progressTask >= 0) {
      this.clock.cancel(this.progressTask);
      this.progressTask = -1;
    }
    const expectedKey = this.activeKeyValue;
    this.ackTask = this.clock.schedule(this.durableAckTimeoutMs, () => {
      if (this.activeKeyValue !== expectedKey) {
        return;
      }
      this.ackTask = -1;
      this.fail(new Error('Wear Engine 通信失败：文件已传完，但等待手机持久化回执超时'));
    });
  }
}
