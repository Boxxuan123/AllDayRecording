import {
  DeviceV3ClientOperation,
  DeviceV3StatusResponse,
  DeviceV3SyncRequest,
  DeviceV3SyncResponse
} from '../../computer/ComputerTransferProtocol';
import { PhonePendingOperation, PhoneProjectionStorage } from '../data/PhoneSyncProjection';
import {
  PhoneV3Conflict,
  PhoneV3DeviceState,
  PhoneV3LocalAudioFact,
  PhoneV3LocalAudioLink,
  PhoneV3ProjectionRow,
  PhoneV3Reminder,
  PhoneV3SyncStatus
} from '../domain/PhoneV3Models';

export interface PhoneV3ProjectionRepositoryPort extends PhoneProjectionStorage {
  enqueue(operation: DeviceV3ClientOperation): Promise<void>;
  pendingOperations(limit?: number): Promise<Array<PhonePendingOperation>>;
  currentCursor(): Promise<string>;
  projectionRows(resourceType: string): Promise<Array<PhoneV3ProjectionRow>>;
  localAudioLinks(): Promise<Array<PhoneV3LocalAudioLink>>;
  conflictRows(): Promise<Array<PhoneV3Conflict>>;
  v3Status(): Promise<PhoneV3SyncStatus>;
  markSyncFailure(message: string): Promise<void>;
  rebuildFromComputer(): Promise<void>;
  linkLocalAudio(sessionKey: string, localPath: string, sha256: string,
    uploadStatus: string): Promise<void>;
}

export interface PhoneV3LocalAudioRepositoryPort {
  list(): Promise<Array<PhoneV3LocalAudioFact>>;
}

export class PhoneV3AudioBackupResult {
  sessions: number;
  uploadedFiles: number;
  skippedFiles: number;

  constructor(sessions: number = 0, uploadedFiles: number = 0, skippedFiles: number = 0) {
    this.sessions = sessions;
    this.uploadedFiles = uploadedFiles;
    this.skippedFiles = skippedFiles;
  }
}

export interface PhoneV3AudioBackupPort {
  backup(): Promise<PhoneV3AudioBackupResult>;
}

export interface PhoneV3ReminderSchedulerPort {
  reconcile(reminders: Array<PhoneV3Reminder>): Promise<void>;
}

export interface PhoneV3RemoteSession {
  status(): Promise<DeviceV3StatusResponse>;
  sync(request: DeviceV3SyncRequest): Promise<DeviceV3SyncResponse>;
}

export interface PhoneV3RemotePort {
  isPaired(): Promise<boolean>;
  connect(): Promise<PhoneV3RemoteSession>;
}

export interface PhoneV3DeviceBridgePort {
  state(): PhoneV3DeviceState;
  selectSession(sessionKey: string): void;
  togglePlayback(): void;
  seekPlayback(positionMs: number): void;
  stopPlayback(): void;
  requestWatchSync(): void;
  requestWatchRecordingState(desiredState: string): void;
  toggleWifiReceiver(): void;
  retryWifiReceiver(): void;
  reconnectReceiver(): void;
  deleteLocalSession(localGroupKey: string): Promise<void>;
  addLocalAudioChangeListener(listener: () => void): void;
  removeLocalAudioChangeListener(listener: () => void): void;
}
