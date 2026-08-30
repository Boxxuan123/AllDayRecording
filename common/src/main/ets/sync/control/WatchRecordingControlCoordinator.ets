import { WatchSyncProtocolMessage } from '../protocol/WatchFileSyncProtocol';
import { SyncClock, SyncScheduledTask, SystemSyncClock } from '../state/SyncClock';

export const WATCH_CONTROL_EXECUTE: string = 'execute';
export const WATCH_CONTROL_BUSY: string = 'busy';
export const WATCH_CONTROL_REPLAY: string = 'replay';

export class WatchRecordingControlCoordinator {
  private inProgressValue: boolean = false;
  private lastRequestIdValue: string = '';
  private lastAckValue: WatchSyncProtocolMessage | undefined = undefined;

  inspect(requestId: string): string {
    if (requestId === this.lastRequestIdValue && this.lastAckValue !== undefined) {
      return WATCH_CONTROL_REPLAY;
    }
    return this.inProgressValue ? WATCH_CONTROL_BUSY : WATCH_CONTROL_EXECUTE;
  }

  begin(): void {
    this.inProgressValue = true;
  }

  complete(requestId: string, ack: WatchSyncProtocolMessage): void {
    this.lastRequestIdValue = requestId;
    this.lastAckValue = ack;
    this.inProgressValue = false;
  }

  finishWithoutAck(): void {
    this.inProgressValue = false;
  }

  lastAck(): WatchSyncProtocolMessage | undefined {
    return this.lastAckValue;
  }
}

export interface PhoneRecordingControlState {
  requestId: string;
  desiredState: string;
  commandSent: boolean;
  phase: string;
}

export type PhoneRecordingControlTimeoutHandler = (state: PhoneRecordingControlState) => void;

export class PhoneRecordingControlCoordinator {
  private clock: SyncClock;
  private commandTimeoutMs: number;
  private pendingUserActionTimeoutMs: number;
  private requestIdValue: string = '';
  private desiredStateValue: string = '';
  private commandSentValue: boolean = false;
  private phaseValue: string = 'idle';
  private timeoutTask: SyncScheduledTask = -1;

  constructor(commandTimeoutMs: number, pendingUserActionTimeoutMs: number, clock?: SyncClock) {
    this.commandTimeoutMs = commandTimeoutMs;
    this.pendingUserActionTimeoutMs = pendingUserActionTimeoutMs;
    this.clock = clock !== undefined ? clock : new SystemSyncClock();
  }

  begin(requestId: string, desiredState: string, timeoutHandler: PhoneRecordingControlTimeoutHandler): void {
    if (this.requestIdValue.length > 0) {
      throw new Error('上一项手表录音控制仍在进行');
    }
    this.requestIdValue = requestId;
    this.desiredStateValue = desiredState;
    this.commandSentValue = false;
    this.phaseValue = 'waiting_ready';
    this.scheduleTimeout(this.commandTimeoutMs, timeoutHandler);
  }

  markCommandSent(): void {
    this.commandSentValue = true;
    this.phaseValue = 'waiting_ack';
  }

  markCommandSendFailed(): void {
    this.commandSentValue = false;
    this.phaseValue = 'waiting_ready';
  }

  beginPendingUserAction(timeoutHandler: PhoneRecordingControlTimeoutHandler): void {
    this.phaseValue = 'pending_user_action';
    this.scheduleTimeout(this.pendingUserActionTimeoutMs, timeoutHandler);
  }

  finish(): void {
    this.cancelTimeout();
    this.requestIdValue = '';
    this.desiredStateValue = '';
    this.commandSentValue = false;
    this.phaseValue = 'idle';
  }

  clearTimeout(): void {
    this.cancelTimeout();
  }

  matches(requestId: string): boolean {
    return this.requestIdValue.length > 0 && requestId === this.requestIdValue;
  }

  isActive(): boolean {
    return this.requestIdValue.length > 0;
  }

  commandSent(): boolean {
    return this.commandSentValue;
  }

  requestId(): string {
    return this.requestIdValue;
  }

  desiredState(): string {
    return this.desiredStateValue;
  }

  state(): PhoneRecordingControlState {
    return {
      requestId: this.requestIdValue,
      desiredState: this.desiredStateValue,
      commandSent: this.commandSentValue,
      phase: this.phaseValue
    };
  }

  private scheduleTimeout(delayMs: number, timeoutHandler: PhoneRecordingControlTimeoutHandler): void {
    this.cancelTimeout();
    this.timeoutTask = this.clock.schedule(delayMs, () => {
      if (this.requestIdValue.length === 0) {
        return;
      }
      const expiredState = this.state();
      this.timeoutTask = -1;
      this.requestIdValue = '';
      this.desiredStateValue = '';
      this.commandSentValue = false;
      this.phaseValue = 'idle';
      timeoutHandler(expiredState);
    });
  }

  private cancelTimeout(): void {
    if (this.timeoutTask >= 0) {
      this.clock.cancel(this.timeoutTask);
      this.timeoutTask = -1;
    }
  }
}
