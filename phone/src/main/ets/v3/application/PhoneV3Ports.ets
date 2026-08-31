import {
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
  PhoneV3SyncStatus
} from '../domain/PhoneV3Models';

export interface PhoneV3ProjectionRepositoryPort extends PhoneProjectionStorage {
  pendingOperations(limit?: number): Promise<Array<PhonePendingOperation>>;
  currentCursor(): Promise<string>;
  projectionRows(resourceType: string): Promise<Array<PhoneV3ProjectionRow>>;
  localAudioLinks(): Promise<Array<PhoneV3LocalAudioLink>>;
  conflictRows(): Promise<Array<PhoneV3Conflict>>;
  v3Status(): Promise<PhoneV3SyncStatus>;
  markSyncFailure(message: string): Promise<void>;
  rebuildFromComputer(): Promise<void>;
}

export interface PhoneV3LocalAudioRepositoryPort {
  list(): Promise<Array<PhoneV3LocalAudioFact>>;
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
}
