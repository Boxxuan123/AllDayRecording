import { common } from '@kit.AbilityKit';
import { ComputerTransferHttpClient } from '../../computer/ComputerTransferHttpClient';
import { DeviceV3AnnotationRequest, DeviceV3AnnotationResponse, DeviceV3ReviewActionRequest,
  DeviceV3ReviewActionResponse, DeviceV3ReviewAudioRequest, DeviceV3ReviewAudioResponse,
  DeviceV3ReviewSnapshot, DeviceV3StatusResponse, DeviceV3SyncRequest,
  DeviceV3SyncResponse } from '../../computer/ComputerTransferProtocol';
import { PhoneProjectionRepository } from '../data/PhoneProjectionRepository';
import { PhoneSyncResult } from '../data/PhoneSyncCoordinator';
import { PhoneV3LocalAudioRepositoryPort, PhoneV3RemotePort,
  PhoneV3RemoteSession } from './PhoneV3Ports';
import { PhoneV3LocalAudioFact } from '../domain/PhoneV3Models';
import { PhoneV3UseCases } from './PhoneV3UseCases';

class DirectClientSession implements PhoneV3RemoteSession {
  private client: ComputerTransferHttpClient;
  constructor(client: ComputerTransferHttpClient) { this.client = client; }
  status(): Promise<DeviceV3StatusResponse> { return this.client.v3Status(); }
  sync(request: DeviceV3SyncRequest): Promise<DeviceV3SyncResponse> { return this.client.sync(request); }
  annotations(request: DeviceV3AnnotationRequest): Promise<DeviceV3AnnotationResponse> {
    return this.client.annotations(request);
  }
  reviews(): Promise<DeviceV3ReviewSnapshot> { return this.client.v3Reviews(); }
  resolveReview(request: DeviceV3ReviewActionRequest): Promise<DeviceV3ReviewActionResponse> {
    return this.client.v3ReviewAction(request);
  }
  reviewAudio(request: DeviceV3ReviewAudioRequest): Promise<DeviceV3ReviewAudioResponse> {
    return this.client.v3ReviewAudio(request);
  }
}

class EmptyLocalAudioRepository implements PhoneV3LocalAudioRepositoryPort {
  list(): Promise<Array<PhoneV3LocalAudioFact>> { return Promise.resolve([]); }
}

class DirectClientRemote implements PhoneV3RemotePort {
  private client: ComputerTransferHttpClient;
  constructor(client: ComputerTransferHttpClient) { this.client = client; }
  isPaired(): Promise<boolean> { return Promise.resolve(true); }
  connect(): Promise<PhoneV3RemoteSession> {
    return Promise.resolve(new DirectClientSession(this.client));
  }
}

export class PhoneSyncServiceState {
  runningOwner: string = '';
  queued: number = 0;
  lastError: string = '';
  constructor(runningOwner: string = '', queued: number = 0, lastError: string = '') {
    this.runningOwner = runningOwner; this.queued = queued; this.lastError = lastError;
  }
}

/** Application-lifetime owner of the projection database and sync stream. */
export class PhoneSyncService {
  private static instances: Map<string, Promise<PhoneSyncService>> = new Map<string, Promise<PhoneSyncService>>();

  static shared(context: common.UIAbilityContext): Promise<PhoneSyncService> {
    const key = context.filesDir;
    let instance = PhoneSyncService.instances.get(key);
    if (instance === undefined) {
      instance = PhoneProjectionRepository.open(context).then(
        (repository: PhoneProjectionRepository): PhoneSyncService => new PhoneSyncService(repository));
      PhoneSyncService.instances.set(key, instance);
      instance.catch((): void => { PhoneSyncService.instances.delete(key); });
    }
    return instance;
  }

  private repository: PhoneProjectionRepository;
  private tail: Promise<void> = Promise.resolve();
  private epochs: Map<string, number> = new Map<string, number>();
  private active: Map<string, PhoneV3UseCases> = new Map<string, PhoneV3UseCases>();
  private state: PhoneSyncServiceState = new PhoneSyncServiceState();
  private listeners: Set<(state: PhoneSyncServiceState) => void> = new Set<(state: PhoneSyncServiceState) => void>();

  constructor(repository: PhoneProjectionRepository) { this.repository = repository; }

  projection(): PhoneProjectionRepository { return this.repository; }

  currentState(): PhoneSyncServiceState {
    return new PhoneSyncServiceState(this.state.runningOwner, this.state.queued, this.state.lastError);
  }

  subscribe(listener: (state: PhoneSyncServiceState) => void): () => void {
    this.listeners.add(listener);
    listener(this.currentState());
    return (): void => { this.listeners.delete(listener); };
  }

  private publish(): void {
    for (let listener of this.listeners) {
      try { listener(this.currentState()); }
      catch (_) { console.warn('[sync] state subscriber failed'); }
    }
  }

  cancel(owner: string): void {
    this.epochs.set(owner, (this.epochs.get(owner) ?? 0) + 1);
    this.active.get(owner)?.cancelSynchronize();
  }

  run<T>(owner: string, action: (repository: PhoneProjectionRepository) => Promise<T>,
    cancellable?: PhoneV3UseCases): Promise<T> {
    const epoch = this.epochs.get(owner) ?? 0;
    this.state.queued += 1;
    this.publish();
    const next = this.tail.catch((): void => {}).then(async (): Promise<T> => {
      this.state.queued -= 1;
      if ((this.epochs.get(owner) ?? 0) !== epoch) {
        this.publish();
        throw new Error('同步请求已取消');
      }
      this.state.runningOwner = owner;
      this.state.lastError = '';
      if (cancellable !== undefined) { this.active.set(owner, cancellable); }
      this.publish();
      try { return await action(this.repository); }
      catch (error) {
        this.state.lastError = error instanceof Error ? error.message : JSON.stringify(error);
        throw error as Error;
      } finally {
        if (cancellable !== undefined) { this.active.delete(owner); }
        this.state.runningOwner = '';
        this.publish();
      }
    });
    this.tail = next.then((): void => {}, (): void => {});
    return next;
  }

  synchronize(owner: string, client: ComputerTransferHttpClient): Promise<PhoneSyncResult> {
    return this.run(owner, async (repository: PhoneProjectionRepository): Promise<PhoneSyncResult> => {
      const useCases = new PhoneV3UseCases(repository,
        new EmptyLocalAudioRepository(), new DirectClientRemote(client));
      this.active.set(owner, useCases);
      try {
        const result = await useCases.synchronize();
        return { batches: result.batches, submitted_operations: result.submittedOperations,
          final_cursor: result.finalCursor };
      } finally { this.active.delete(owner); }
    });
  }

  rebuild(owner: string): Promise<void> {
    return this.run(owner, (repository: PhoneProjectionRepository): Promise<void> =>
      repository.rebuildFromComputer());
  }
}
