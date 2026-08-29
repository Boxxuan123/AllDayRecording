import { describe, it, expect } from '@ohos/hypium';
import { RecordingFile, WatchSyncFileDescriptor } from '../main/ets/models/RecordingModels';
import {
  WATCH_RECORDING_ACK,
  WATCH_SYNC_PROTOCOL_VERSION,
  WatchSyncProtocolMessage
} from '../main/ets/sync/protocol/WatchFileSyncProtocol';
import {
  PhoneRecordingControlCoordinator,
  WatchRecordingControlCoordinator,
  WATCH_CONTROL_BUSY,
  WATCH_CONTROL_REPLAY
} from '../main/ets/sync/control/WatchRecordingControlCoordinator';
import {
  PhoneReceiverLifecycleCoordinator,
  PhoneSyncCoordinator
} from '../main/ets/sync/phone/PhoneSyncCoordinator';
import { SyncClock, SyncScheduledCallback } from '../main/ets/sync/state/SyncClock';
import {
  P2P_COMMUNICATION_FAILURE,
  isP2pCommunicationError,
  p2pResultMessage,
  shouldRetryReceiverConnection
} from '../main/ets/sync/transport/WearEngineTransportPolicy';
import {
  AUTOMATIC_QUEUE_DAMAGED,
  AUTOMATIC_QUEUE_DUPLICATE,
  AUTOMATIC_QUEUE_ENQUEUED,
  AUTOMATIC_QUEUE_RESTORED,
  AutomaticSyncQueue,
  AutomaticSyncQueueClock,
  AutomaticSyncQueueFileInfo,
  AutomaticSyncQueueFileSystem
} from '../main/ets/sync/watch/AutomaticSyncQueue';
import {
  WATCH_MANUAL_DUPLICATE,
  WATCH_MANUAL_QUEUED,
  WatchFileAckCoordinator,
  WatchSyncCoordinator
} from '../main/ets/sync/watch/WatchSyncCoordinator';

interface FakeScheduledTask {
  id: number;
  dueAt: number;
  callback: SyncScheduledCallback;
  cancelled: boolean;
}

interface AutomaticQueueManifestEntryFixture {
  relativePath: string;
  fileName: string;
  size: number;
  durationMs: number;
}

interface AutomaticQueueManifestFixture {
  version: number;
  updatedAt: number;
  completedCount: number;
  files: Array<AutomaticQueueManifestEntryFixture>;
}

class FakeWearEngineError extends Error {
  code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

class FakeSyncClock implements SyncClock, AutomaticSyncQueueClock {
  private currentTime: number = 1000;
  private nextId: number = 1;
  private tasks: Array<FakeScheduledTask> = [];

  now(): number {
    return this.currentTime;
  }

  schedule(delayMs: number, callback: SyncScheduledCallback): number {
    const task: FakeScheduledTask = {
      id: this.nextId,
      dueAt: this.currentTime + delayMs,
      callback: callback,
      cancelled: false
    };
    this.nextId += 1;
    this.tasks.push(task);
    return task.id;
  }

  cancel(taskId: number): void {
    for (let index = 0; index < this.tasks.length; index += 1) {
      if (this.tasks[index].id === taskId) {
        this.tasks[index].cancelled = true;
      }
    }
  }

  advance(delayMs: number): void {
    this.currentTime += delayMs;
    let executed = true;
    while (executed) {
      executed = false;
      for (let index = 0; index < this.tasks.length; index += 1) {
        const task = this.tasks[index];
        if (!task.cancelled && task.dueAt <= this.currentTime) {
          task.cancelled = true;
          task.callback();
          executed = true;
        }
      }
    }
  }
}

class FakeQueueFileSystem implements AutomaticSyncQueueFileSystem {
  texts: Map<string, string> = new Map<string, string>();
  files: Map<string, AutomaticSyncQueueFileInfo> = new Map<string, AutomaticSyncQueueFileInfo>();

  exists(path: string): boolean {
    return this.texts.has(path) || this.files.has(path);
  }

  readText(path: string): string {
    return this.texts.get(path) || '';
  }

  writeText(path: string, content: string): void {
    this.texts.set(path, content);
  }

  stat(path: string): AutomaticSyncQueueFileInfo {
    const result = this.files.get(path);
    if (result === undefined) {
      throw new Error(`测试文件不存在：${path}`);
    }
    return result;
  }
}

function descriptor(requestId: string, index: number, automatic: boolean = false): WatchSyncFileDescriptor {
  return {
    requestId: requestId,
    index: index,
    total: 1,
    relativePath: `session_${requestId}/segment_${index}.wav`,
    fileName: `segment_${index}.wav`,
    size: 32044,
    automatic: automatic
  };
}

function recording(path: string): RecordingFile {
  return {
    fileName: 'segment_1.wav',
    path: path,
    size: 32044,
    durationMs: 1000
  };
}

function recordingAck(requestId: string, actualState: string): WatchSyncProtocolMessage {
  return {
    version: WATCH_SYNC_PROTOCOL_VERSION,
    type: WATCH_RECORDING_ACK,
    requestId: requestId,
    success: true,
    actualState: actualState
  };
}

export default function automaticQueueAndSyncStateTest() {
  describe('AutomaticSyncQueue', () => {
    it('restoresProductionManifestAndDropsMissingFile', 0, () => {
      const storage = new FakeQueueFileSystem();
      const clock = new FakeSyncClock();
      const fixture: AutomaticQueueManifestFixture = {
        version: 1,
        updatedAt: 100,
        completedCount: 2,
        files: [
          { relativePath: 'session_a/segment_1.wav', fileName: 'segment_1.wav', size: 32044, durationMs: 1000 },
          { relativePath: 'session_a/missing.wav', fileName: 'missing.wav', size: 100, durationMs: 10 }
        ]
      };
      storage.texts.set('/files/automatic_sync_queue_v1.json', JSON.stringify(fixture));
      storage.files.set('/files/session_a/segment_1.wav', { size: 32044, isFile: true });
      const queue = new AutomaticSyncQueue('/files', storage, clock);

      expect(queue.restore()).assertEqual(AUTOMATIC_QUEUE_RESTORED);
      expect(queue.completedCount()).assertEqual(2);
      expect(queue.count()).assertEqual(1);
      expect(queue.first()?.relativePath).assertEqual('session_a/segment_1.wav');
    });

    it('fallsBackWithoutQueueForDamagedJson', 0, () => {
      const storage = new FakeQueueFileSystem();
      storage.texts.set('/files/automatic_sync_queue_v1.json', '{damaged');
      const queue = new AutomaticSyncQueue('/files', storage, new FakeSyncClock());

      expect(queue.restore()).assertEqual(AUTOMATIC_QUEUE_DAMAGED);
      expect(queue.count()).assertEqual(0);
    });

    it('persistsSameManifestAndRejectsDuplicatePath', 0, () => {
      const storage = new FakeQueueFileSystem();
      const queue = new AutomaticSyncQueue('/files', storage, new FakeSyncClock());
      const item = recording('/files/session_a/segment_1.wav');

      expect(queue.enqueue(item)).assertEqual(AUTOMATIC_QUEUE_ENQUEUED);
      expect(queue.enqueue(item)).assertEqual(AUTOMATIC_QUEUE_DUPLICATE);
      const saved = JSON.parse(storage.texts.get('/files/automatic_sync_queue_v1.json') || '{}') as Object;
      expect(JSON.stringify(saved).includes('"version":1')).assertTrue();
      expect(JSON.stringify(saved).includes('"completedCount":0')).assertTrue();
      expect(queue.requestId()).assertEqual('auto_1000');
    });
  });

  describe('WatchSyncCoordinator', () => {
    it('queuesManualRequestDuringAutomaticTransferAndPromotesIt', 0, () => {
      const coordinator = new WatchSyncCoordinator();
      expect(coordinator.beginAutomatic()).assertTrue();
      const decision = coordinator.requestManual('manual_1', ['known_a']);

      expect(decision.action).assertEqual(WATCH_MANUAL_QUEUED);
      expect(coordinator.hasPendingManual()).assertTrue();
      coordinator.finishCurrent();
      const pending = coordinator.takePendingManual();
      expect(pending?.requestId).assertEqual('manual_1');
      expect(coordinator.isManual()).assertTrue();
    });

    it('ignoresDuplicateActiveAndPendingManualRequests', 0, () => {
      const coordinator = new WatchSyncCoordinator();
      coordinator.requestManual('manual_1', []);
      expect(coordinator.requestManual('manual_1', []).action).assertEqual(WATCH_MANUAL_DUPLICATE);
      expect(coordinator.requestManual('manual_2', []).action).assertEqual(WATCH_MANUAL_QUEUED);
      expect(coordinator.requestManual('manual_2', []).action).assertEqual(WATCH_MANUAL_DUPLICATE);
    });
  });

  describe('WatchFileAckCoordinator', () => {
    it('resolvesOnlyMatchingDurableAck', 0, () => {
      const state = new WatchFileAckCoordinator(60000, 60000, new FakeSyncClock());
      const current = descriptor('request_a', 1);
      let resolved = 0;
      state.begin(current, (): void => { resolved += 1; }, (_error: Error): void => {});
      state.progress(current, 100);

      expect(state.waitingForAck()).assertTrue();
      expect(state.acknowledge(descriptor('request_stale', 1))).assertFalse();
      expect(state.acknowledge(current)).assertTrue();
      expect(resolved).assertEqual(1);
      expect(state.acknowledge(current)).assertFalse();
    });

    it('failsAfterSixtySecondsWithoutProgress', 0, () => {
      const clock = new FakeSyncClock();
      const state = new WatchFileAckCoordinator(60000, 60000, clock);
      let failure = '';
      state.begin(descriptor('request_stall', 1), (): void => {},
        (error: Error): void => { failure = error.message; });

      clock.advance(59999);
      expect(failure).assertEqual('');
      clock.advance(1);
      expect(failure).assertEqual('Wear Engine 通信失败：文件传输进度 60 秒未变化');
    });

    it('keepsSavedSourcePendingWhenDurableAckIsLost', 0, () => {
      const clock = new FakeSyncClock();
      const state = new WatchFileAckCoordinator(60000, 60000, clock);
      const file = descriptor('request_ack_lost', 1);
      const phone = new PhoneSyncCoordinator(20000, clock);
      let failure = '';
      expect(phone.markReceived(file)).assertTrue();
      state.begin(file, (): void => {}, (error: Error): void => { failure = error.message; });
      state.progress(file, 100);

      expect(state.waitingForAck()).assertTrue();
      clock.advance(60000);
      expect(failure).assertEqual('Wear Engine 通信失败：文件已传完，但等待手机持久化回执超时');
    });
  });

  describe('PhoneSyncCoordinator', () => {
    it('acceptsAutomaticFileAndCountsDuplicateDescriptorOnce', 0, () => {
      const state = new PhoneSyncCoordinator(20000, new FakeSyncClock());
      state.beginRequest('manual_current', (_requestId: string): void => {});
      const file = descriptor('auto_request', 1, true);

      expect(state.accepts('manual_stale', false)).assertFalse();
      expect(state.accepts('auto_request', true)).assertTrue();
      expect(state.addPendingFile(file)).assertTrue();
      expect(state.addPendingFile(file)).assertFalse();
      expect(state.markReceived(file)).assertTrue();
      expect(state.markReceived(file)).assertFalse();
    });

    it('expiresOnlyCurrentHandshakeAndClearsRequest', 0, () => {
      const clock = new FakeSyncClock();
      const state = new PhoneSyncCoordinator(20000, clock);
      let expired = '';
      state.beginRequest('manual_timeout', (requestId: string): void => { expired = requestId; });
      clock.advance(20000);

      expect(expired).assertEqual('manual_timeout');
      expect(state.inProgress()).assertFalse();
      expect(state.requestId()).assertEqual('');
    });

    it('cancelsPendingStartupWhenPageExits', 0, () => {
      const lifecycle = new PhoneReceiverLifecycleCoordinator();
      const token = lifecycle.beginStart();
      expect(lifecycle.isActive(token)).assertTrue();
      lifecycle.cancel();
      expect(lifecycle.isActive(token)).assertFalse();
    });
  });

  describe('RecordingControlCoordinators', () => {
    it('replaysDuplicateAckAndRejectsConcurrentCommand', 0, () => {
      const state = new WatchRecordingControlCoordinator();
      state.begin();
      expect(state.inspect('request_other')).assertEqual(WATCH_CONTROL_BUSY);
      const ack = recordingAck('request_1', 'recording');
      state.complete('request_1', ack);
      expect(state.inspect('request_1')).assertEqual(WATCH_CONTROL_REPLAY);
      expect(state.lastAck()?.actualState).assertEqual('recording');
    });

    it('acceptsFinalAckWhilePendingUserAction', 0, () => {
      const clock = new FakeSyncClock();
      const state = new PhoneRecordingControlCoordinator(20000, 300000, clock);
      state.begin('control_1', 'recording', (_expired): void => {});
      state.markCommandSent();
      state.clearTimeout();
      state.beginPendingUserAction((_expired): void => {});
      expect(state.state().phase).assertEqual('pending_user_action');
      expect(state.matches('control_1')).assertTrue();
      state.finish();
      clock.advance(300000);
      expect(state.isActive()).assertFalse();
    });

    it('expiresPendingUserActionAfterFiveMinutes', 0, () => {
      const clock = new FakeSyncClock();
      const state = new PhoneRecordingControlCoordinator(20000, 300000, clock);
      let expiredPhase = '';
      state.begin('control_2', 'recording', (_expired): void => {});
      state.clearTimeout();
      state.beginPendingUserAction((expired): void => { expiredPhase = expired.phase; });
      clock.advance(299999);
      expect(expiredPhase).assertEqual('');
      clock.advance(1);
      expect(expiredPhase).assertEqual('pending_user_action');
      expect(state.isActive()).assertFalse();
    });
  });

  describe('WearEngineTransportPolicy', () => {
    it('classifiesCommunicationFailureForReconnect', 0, () => {
      expect(p2pResultMessage(P2P_COMMUNICATION_FAILURE)).assertEqual(
        'Wear Engine 通信失败，请检查华为运动健康中的设备连接');
      expect(isP2pCommunicationError(new Error('Wear Engine 通信失败'))).assertTrue();
      expect(isP2pCommunicationError(new FakeWearEngineError(1008500003, 'disconnected'))).assertTrue();
      expect(shouldRetryReceiverConnection(new FakeWearEngineError(1008500003, 'disconnected'))).assertTrue();
    });
  });
}
