export interface RecordingFile {
  fileName: string;
  path: string;
  size: number;
  durationMs: number;
}

export interface WatchSyncFileDescriptor {
  requestId: string;
  index: number;
  total: number;
  relativePath: string;
  fileName: string;
  size: number;
  automatic?: boolean;
}

export interface ReceivedRecordingFile extends RecordingFile {
  requestId: string;
  sourcePath: string;
  receivedAt: number;
  syncKey?: string;
}

export interface WatchSyncProgress {
  requestId: string;
  total: number;
  received: number;
  skipped: number;
  alreadyReceived: number;
  remaining: number;
  scannedTotal?: number;
  inProgress: boolean;
  message: string;
  fileTransferActive?: boolean;
  transferStage?: string;
  transferPercent?: number;
  transferFileName?: string;
  transferredBytes?: number;
  transferSize?: number;
  transferIndex?: number;
  transferTotal?: number;
  automatic?: boolean;
  lastProgressAt?: number;
}

export interface WatchRecordingControlStatus {
  requestId: string;
  desiredState: string;
  actualState: string;
  inProgress: boolean;
  message: string;
}
