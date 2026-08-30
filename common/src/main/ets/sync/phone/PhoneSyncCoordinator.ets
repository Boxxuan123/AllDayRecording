import { WatchSyncFileDescriptor } from '../../models/RecordingModels';
import { SyncClock, SyncScheduledTask, SystemSyncClock } from '../state/SyncClock';
import { watchFileTransferKey } from '../watch/WatchSyncCoordinator';

export interface PhoneSyncState {
  requestId: string;
  inProgress: boolean;
  handshakeWaiting: boolean;
}

export type PhoneSyncHandshakeTimeoutHandler = (requestId: string) => void;

export class PhoneSyncCoordinator {
  private clock: SyncClock;
  private handshakeTimeoutMs: number;
  private requestIdValue: string = '';
  private inProgressValue: boolean = false;
  private handshakeTask: SyncScheduledTask = -1;
  private pendingFiles: Array<WatchSyncFileDescriptor> = [];
  private completedDescriptorKeys: Set<string> = new Set<string>();

  constructor(handshakeTimeoutMs: number, clock?: SyncClock) {
    this.handshakeTimeoutMs = handshakeTimeoutMs;
    this.clock = clock !== undefined ? clock : new SystemSyncClock();
  }

  beginRequest(requestId: string, timeoutHandler: PhoneSyncHandshakeTimeoutHandler): void {
    if (this.inProgressValue) {
      throw new Error('上一项手表文件同步仍在进行');
    }
    this.cancelHandshake();
    this.requestIdValue = requestId;
    this.inProgressValue = true;
    this.completedDescriptorKeys.clear();
    this.retainAutomaticPending();
    this.handshakeTask = this.clock.schedule(this.handshakeTimeoutMs, () => {
      if (!this.inProgressValue || this.requestIdValue !== requestId) {
        return;
      }
      this.handshakeTask = -1;
      this.requestIdValue = '';
      this.inProgressValue = false;
      timeoutHandler(requestId);
    });
  }

  accepts(requestId: string, automatic: boolean): boolean {
    return automatic || requestId === this.requestIdValue;
  }

  addPendingFile(descriptor: WatchSyncFileDescriptor): boolean {
    for (let index = 0; index < this.pendingFiles.length; index += 1) {
      if (watchFileTransferKey(this.pendingFiles[index]) === watchFileTransferKey(descriptor)) {
        return false;
      }
    }
    this.pendingFiles.push(descriptor);
    return true;
  }

  removePendingFile(descriptor: WatchSyncFileDescriptor): boolean {
    const key = watchFileTransferKey(descriptor);
    for (let index = 0; index < this.pendingFiles.length; index += 1) {
      if (watchFileTransferKey(this.pendingFiles[index]) === key) {
        this.pendingFiles.splice(index, 1);
        return true;
      }
    }
    return false;
  }

  takePendingFile(): WatchSyncFileDescriptor | undefined {
    return this.pendingFiles.length > 0 ? this.pendingFiles.shift() : undefined;
  }

  markReceived(descriptor: WatchSyncFileDescriptor): boolean {
    const key = watchFileTransferKey(descriptor);
    if (this.completedDescriptorKeys.has(key)) {
      return false;
    }
    this.completedDescriptorKeys.add(key);
    return true;
  }

  clearHandshake(): void {
    this.cancelHandshake();
  }

  finishRequest(): void {
    this.cancelHandshake();
    this.requestIdValue = '';
    this.inProgressValue = false;
  }

  stop(): void {
    this.finishRequest();
    this.pendingFiles = [];
    this.completedDescriptorKeys.clear();
  }

  requestId(): string {
    return this.requestIdValue;
  }

  inProgress(): boolean {
    return this.inProgressValue;
  }

  state(): PhoneSyncState {
    return {
      requestId: this.requestIdValue,
      inProgress: this.inProgressValue,
      handshakeWaiting: this.handshakeTask >= 0
    };
  }

  private retainAutomaticPending(): void {
    this.pendingFiles = this.pendingFiles.filter((descriptor: WatchSyncFileDescriptor) =>
      descriptor.automatic === true);
  }

  private cancelHandshake(): void {
    if (this.handshakeTask >= 0) {
      this.clock.cancel(this.handshakeTask);
      this.handshakeTask = -1;
    }
  }
}

export class PhoneReceiverLifecycleCoordinator {
  private generation: number = 0;
  private activeGeneration: number = -1;

  beginStart(): number {
    this.generation += 1;
    this.activeGeneration = this.generation;
    return this.activeGeneration;
  }

  cancel(): void {
    this.generation += 1;
    this.activeGeneration = -1;
  }

  isActive(token: number): boolean {
    return token >= 0 && token === this.activeGeneration && token === this.generation;
  }

  finish(token: number): void {
    if (this.activeGeneration === token) {
      this.activeGeneration = -1;
    }
  }
}
