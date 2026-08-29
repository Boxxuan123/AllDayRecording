import { describe, it, expect } from '@ohos/hypium';
import { RecordingFile, WatchSyncFileDescriptor } from '../main/ets/models/RecordingModels';
import {
  AutomaticQueueCharacterization,
  CharacterizedAutomaticQueueEntry,
  FileTransferAckCharacterization,
  ReceiverRequestCharacterization
} from './support/SyncStateCharacterization';

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

export default function automaticQueueAndSyncStateTest() {
  describe('AutomaticQueuePersistence', () => {
    it('restoresValidEntryAndSkipsMissingFile', 0, () => {
      const files: Array<AutomaticQueueManifestEntryFixture> = [
        { relativePath: 'session_a/segment_1.wav', fileName: 'segment_1.wav', size: 32044, durationMs: 1000 },
        { relativePath: 'session_a/missing.wav', fileName: 'missing.wav', size: 100, durationMs: 10 }
      ];
      const fixture: AutomaticQueueManifestFixture = {
        version: 1,
        updatedAt: 100,
        completedCount: 2,
        files: files
      };
      const manifest = JSON.stringify(fixture);
      const sizes = new Map<string, number>();
      sizes.set('session_a/segment_1.wav', 32044);

      const restored = AutomaticQueueCharacterization.restore('/files', manifest, sizes);

      expect(restored.status).assertEqual('restored');
      expect(restored.completedCount).assertEqual(2);
      expect(restored.files.length).assertEqual(1);
      expect(restored.files[0].relativePath).assertEqual('session_a/segment_1.wav');
    });

    it('fallsBackWithoutQueueForDamagedJson', 0, () => {
      const restored = AutomaticQueueCharacterization.restore('/files', '{damaged', new Map<string, number>());

      expect(restored.status).assertEqual('damaged_json');
      expect(restored.files.length).assertEqual(0);
    });

    it('doesNotEnqueueSamePathTwice', 0, () => {
      const queue: Array<CharacterizedAutomaticQueueEntry> = [];
      const recording: RecordingFile = {
        fileName: 'segment_1.wav',
        path: '/files/session_a/segment_1.wav',
        size: 32044,
        durationMs: 1000
      };

      expect(AutomaticQueueCharacterization.enqueue('/files', queue, recording)).assertTrue();
      expect(AutomaticQueueCharacterization.enqueue('/files', queue, recording)).assertFalse();
      expect(queue.length).assertEqual(1);
    });
  });

  describe('FileTransferAckState', () => {
    it('acceptsDurableAckOnceAndClearsState', 0, () => {
      const state = new FileTransferAckCharacterization();
      const file = descriptor('request_a', 1);
      state.begin(file);
      state.progress(file, 100);

      expect(state.waitingForDurableAck).assertTrue();
      expect(state.acknowledge(file)).assertTrue();
      expect(state.activeKey).assertEqual('');
      expect(state.acknowledge(file)).assertFalse();
    });

    it('ignoresOutOfOrderProgressAndStaleRequest', 0, () => {
      const state = new FileTransferAckCharacterization();
      const current = descriptor('request_current', 1);
      const stale = descriptor('request_stale', 1);
      state.begin(current);

      expect(state.progress(current, 60)).assertTrue();
      expect(state.progress(current, 40)).assertFalse();
      expect(state.progress(stale, 80)).assertFalse();
      expect(state.lastProgress).assertEqual(60);
    });

    it('clearsOnlyMatchingTimeoutState', 0, () => {
      const state = new FileTransferAckCharacterization();
      const current = descriptor('request_timeout', 1);
      state.begin(current);
      const activeKey = state.activeKey;

      expect(state.expire('stale-key')).assertFalse();
      expect(state.activeKey).assertEqual(activeKey);
      expect(state.expire(activeKey)).assertTrue();
      expect(state.progressTimeoutActive).assertFalse();
      expect(state.ackTimeoutActive).assertFalse();
    });
  });

  describe('ReceiverRequestState', () => {
    it('rejectsExpiredManualRequestButAcceptsAutomaticMessage', 0, () => {
      const state = new ReceiverRequestCharacterization();
      state.begin('request_current');

      expect(state.accepts('request_stale', false)).assertFalse();
      expect(state.accepts('automatic_request', true)).assertTrue();
      expect(state.timeout('request_stale')).assertFalse();
      expect(state.timeout('request_current')).assertTrue();
      expect(state.activeRequestId).assertEqual('');
    });

    it('countsDuplicateDescriptorOnlyOnce', 0, () => {
      const state = new ReceiverRequestCharacterization();
      const file = descriptor('request_duplicate', 1);

      expect(state.markReceived(file)).assertTrue();
      expect(state.markReceived(file)).assertFalse();
      expect(state.completedDescriptorKeys.size).assertEqual(1);
    });
  });
}
