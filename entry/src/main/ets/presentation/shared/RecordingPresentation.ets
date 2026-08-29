import { WatchSyncProgress } from '../../models/RecordingModels';

export class PhoneSyncUiState {
  readonly inProgress: boolean;
  readonly total: number;
  readonly received: number;
  readonly skipped: number;
  readonly alreadyReceived: number;
  readonly scannedTotal: number;
  readonly message: string;
  readonly fileTransferActive: boolean;
  readonly transferStage: string;
  readonly transferPercent: number;
  readonly transferFileName: string;
  readonly transferredBytes: number;
  readonly transferSize: number;
  readonly transferIndex: number;
  readonly transferTotal: number;
  readonly automatic: boolean;

  constructor(progress?: WatchSyncProgress) {
    this.inProgress = progress?.inProgress === true;
    this.total = progress?.total !== undefined ? progress.total : 0;
    this.received = progress?.received !== undefined ? progress.received : 0;
    this.skipped = progress?.skipped !== undefined ? progress.skipped : 0;
    this.alreadyReceived = progress?.alreadyReceived !== undefined ? progress.alreadyReceived : 0;
    this.scannedTotal = progress?.scannedTotal !== undefined ? progress.scannedTotal : 0;
    this.message = progress?.message !== undefined ? progress.message : '';
    this.fileTransferActive = progress?.fileTransferActive === true;
    this.transferStage = progress?.transferStage !== undefined ? progress.transferStage : 'idle';
    this.transferPercent = progress?.transferPercent !== undefined ? progress.transferPercent : 0;
    this.transferFileName = progress?.transferFileName !== undefined ? progress.transferFileName : '';
    this.transferredBytes = progress?.transferredBytes !== undefined ? progress.transferredBytes : 0;
    this.transferSize = progress?.transferSize !== undefined ? progress.transferSize : 0;
    this.transferIndex = progress?.transferIndex !== undefined ? progress.transferIndex : 0;
    this.transferTotal = progress?.transferTotal !== undefined ? progress.transferTotal : 0;
    this.automatic = progress?.automatic === true;
  }
}

export class PresentationLifecycleCoordinator {
  private generation: number = 0;
  private activeGeneration: number = -1;

  activate(): number {
    this.generation += 1;
    this.activeGeneration = this.generation;
    return this.activeGeneration;
  }

  invalidate(): void {
    this.generation += 1;
    this.activeGeneration = -1;
  }

  isActive(token: number): boolean {
    return token >= 0 && token === this.generation && token === this.activeGeneration;
  }
}

export function recordingErrorMessage(error: Object): string {
  return error instanceof Error ? error.message : JSON.stringify(error);
}

export function formatRecordingDuration(durationMs: number): string {
  const seconds = Math.max(0, Math.floor(durationMs / 1000));
  const minutesPart = Math.floor(seconds / 60).toString().padStart(2, '0');
  const secondsPart = (seconds % 60).toString().padStart(2, '0');
  return `${minutesPart}:${secondsPart}`;
}

export function formatRecordingSize(size: number): string {
  if (size < 1024) {
    return `${size} B`;
  }
  if (size < 1024 * 1024) {
    return `${(size / 1024).toFixed(1)} KB`;
  }
  return `${(size / 1024 / 1024).toFixed(1)} MB`;
}

export function formatRecordingReceivedAt(timestamp: number): string {
  const date = new Date(timestamp);
  const month = (date.getMonth() + 1).toString().padStart(2, '0');
  const day = date.getDate().toString().padStart(2, '0');
  const hour = date.getHours().toString().padStart(2, '0');
  const minute = date.getMinutes().toString().padStart(2, '0');
  return `${month}月${day}日 ${hour}:${minute}`;
}
