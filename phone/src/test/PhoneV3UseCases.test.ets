import { describe, expect, it } from '@ohos/hypium';
import {
  DeviceV3ClientOperation,
  DeviceV3Change,
  DeviceV3OperationReceipt,
  DeviceV3StatusResponse,
  DeviceV3SyncRequest,
  DeviceV3SyncResponse
} from '../main/ets/computer/ComputerTransferProtocol';
import {
  PhoneV3AudioBackupPort,
  PhoneV3AudioBackupResult,
  PhoneV3LocalAudioRepositoryPort,
  PhoneV3ProjectionRepositoryPort,
  PhoneV3ReminderSchedulerPort,
  PhoneV3RemotePort,
  PhoneV3RemoteSession
} from '../main/ets/v3/application/PhoneV3Ports';
import { PhoneV3UseCases, mergePhoneV3Sessions } from '../main/ets/v3/application/PhoneV3UseCases';
import { PhonePendingOperation } from '../main/ets/v3/data/PhoneSyncProjection';
import {
  PhoneV3Conflict,
  PhoneV3LocalAudioFact,
  PhoneV3LocalAudioLink,
  PhoneV3ProjectionRow,
  PhoneV3Reminder,
  PhoneV3SyncStatus
} from '../main/ets/v3/domain/PhoneV3Models';

const SESSION_ID: string = '01ARZ3NDEKTSV4RRFFQ69G5FAW';
const SESSION_KEY: string = 'watch-session:1767225600000';
const LOCAL_GROUP_KEY: string = 'session:pcm_session_1767225600000';

interface EvidenceFixture {
  asset_id: string;
}

interface CorrectionEvidenceFixture {
  source: string;
}

interface IdentityEvidenceFixture {
  source: string;
  decision: string;
}

class FakePhoneV3Repository implements PhoneV3ProjectionRepositoryPort {
  recordingRows: Array<PhoneV3ProjectionRow> = [];
  processingRows: Array<PhoneV3ProjectionRow> = [];
  utteranceRows: Array<PhoneV3ProjectionRow> = [];
  reminderRows: Array<PhoneV3ProjectionRow> = [];
  links: Array<PhoneV3LocalAudioLink> = [];
  conflicts: Array<PhoneV3Conflict> = [];
  cursor: string = 'cursor-0';
  failure: string = '';
  operations: Array<DeviceV3ClientOperation> = [];

  async beginTransaction(): Promise<void> {}
  async commit(): Promise<void> {}
  async rollback(): Promise<void> {}
  async applyChange(_change: DeviceV3Change): Promise<void> {}
  async acknowledgeReceipt(_receipt: DeviceV3OperationReceipt): Promise<void> {}
  async clearRebuildableRows(): Promise<void> {}
  async enqueue(operation: DeviceV3ClientOperation): Promise<void> { this.operations.push(operation); }
  async pendingOperations(_limit: number = 500): Promise<Array<PhonePendingOperation>> { return []; }
  async currentCursor(): Promise<string> { return this.cursor; }
  async setCursor(cursor: string, _serverTime: string): Promise<void> { this.cursor = cursor; }
  async localAudioLinks(): Promise<Array<PhoneV3LocalAudioLink>> { return this.links; }
  async conflictRows(): Promise<Array<PhoneV3Conflict>> { return this.conflicts; }
  async v3Status(): Promise<PhoneV3SyncStatus> { return new PhoneV3SyncStatus(this.cursor); }
  async markSyncFailure(message: string): Promise<void> { this.failure = message; }
  async rebuildFromComputer(): Promise<void> {
    this.recordingRows = [];
    this.processingRows = [];
    this.utteranceRows = [];
    this.reminderRows = [];
    this.cursor = 'cursor-0';
  }
  async linkLocalAudio(_sessionKey: string, _localPath: string, _sha256: string,
    _uploadStatus: string): Promise<void> {}

  async projectionRows(resourceType: string): Promise<Array<PhoneV3ProjectionRow>> {
    if (resourceType === 'recording_session') {
      return this.recordingRows;
    }
    if (resourceType === 'processing_run') {
      return this.processingRows;
    }
    if (resourceType === 'reminder') {
      return this.reminderRows;
    }
    return this.utteranceRows;
  }
}

class FakePhoneV3LocalAudio implements PhoneV3LocalAudioRepositoryPort {
  values: Array<PhoneV3LocalAudioFact>;

  constructor(values: Array<PhoneV3LocalAudioFact>) {
    this.values = values;
  }

  async list(): Promise<Array<PhoneV3LocalAudioFact>> { return this.values; }
}

class FakePhoneV3RemoteSession implements PhoneV3RemoteSession {
  async status(): Promise<DeviceV3StatusResponse> {
    return { contract_version: '3.7.0', projection_version: 4, server_time: '2026-08-31T00:00:00Z' };
  }

  async sync(_request: DeviceV3SyncRequest): Promise<DeviceV3SyncResponse> {
    return {
      projection_version: 4,
      receipts: [],
      changes: [],
      next_cursor: 'cursor-1',
      has_more: false,
      server_time: '2026-08-31T00:00:00Z'
    };
  }
}

class FakePhoneV3Remote implements PhoneV3RemotePort {
  connectCount: number = 0;
  async isPaired(): Promise<boolean> { return true; }
  async connect(): Promise<PhoneV3RemoteSession> {
    this.connectCount += 1;
    return new FakePhoneV3RemoteSession();
  }
}

class FakeReminderScheduler implements PhoneV3ReminderSchedulerPort {
  reconciled: Array<PhoneV3Reminder> = [];

  async reconcile(reminders: Array<PhoneV3Reminder>): Promise<void> {
    this.reconciled = reminders.slice();
  }
}

class FakeAudioBackup implements PhoneV3AudioBackupPort {
  calls: number = 0;

  async backup(): Promise<PhoneV3AudioBackupResult> {
    this.calls += 1;
    return new PhoneV3AudioBackupResult(1, 3, 4);
  }
}

function localFact(): PhoneV3LocalAudioFact {
  return new PhoneV3LocalAudioFact(SESSION_KEY, LOCAL_GROUP_KEY, ['/phone/segment_0.wav'],
    1767225600000, 1767225660000, 244, 1000);
}

export default function phoneV3UseCasesTest() {
  describe('PhoneV3UseCases', () => {
    it('mergesLocalAudioComputerProjectionAndStableTimelineIdentity', 0, () => {
      const evidence: EvidenceFixture = { asset_id: 'asset-1' };
      const recording = new PhoneV3ProjectionRow(SESSION_ID, 3, JSON.stringify({
        session_id: SESSION_ID,
        session_key: SESSION_KEY,
        captured_start: '2026-01-01T00:00:00Z',
        device_name: 'HUAWEI WATCH 5',
        state: 'ready',
        status_code: 'ready',
        progress: 1,
        revision: 3
      }), 2000);
      const processing = new PhoneV3ProjectionRow('01ARZ3NDEKTSV4RRFFQ69G5FAX', 2, JSON.stringify({
        session_id: SESSION_ID, status: 'running', current_stage: 'asr', progress: 0.5
      }), 3000);
      const utterance = new PhoneV3ProjectionRow('01ARZ3NDEKTSV4RRFFQ69G5FAY', 7, JSON.stringify({
        utterance_id: '01ARZ3NDEKTSV4RRFFQ69G5FAY',
        session_id: SESSION_ID,
        speaker_track_id: '01ARZ3NDEKTSV4RRFFQ69G5FAZ',
        speaker_label: 'SPEAKER_00',
        original_speaker_track_id: '01ARZ3NDEKTSV4RRFFQ69G5FAZ',
        original_speaker_label: 'SPEAKER_00',
        identity: 'unknown',
        original_identity: 'unknown',
        identity_evidence: { source: 'none', decision: 'unknown' } as IdentityEvidenceFixture,
        start_ms: 100,
        end_ms: 900,
        start_at: '2026-01-01T00:00:00.100Z',
        end_at: '2026-01-01T00:00:00.900Z',
        text: '测试文本',
        original_text: '测试文本',
        revision: 7,
        status: 'active',
        evidence: evidence
      }), 4000);
      const cards = mergePhoneV3Sessions([localFact()], [
        new PhoneV3LocalAudioLink(SESSION_KEY, SESSION_ID, '/phone/segment_0.wav', 'uploaded', 1500)
      ], [recording], [processing], [utterance]);

      expect(cards.length).assertEqual(1);
      expect(cards[0].localPaths.length).assertEqual(1);
      expect(cards[0].sessionId).assertEqual(SESSION_ID);
      expect(cards[0].localGroupKey).assertEqual(LOCAL_GROUP_KEY);
      expect(cards[0].processingStage).assertEqual('asr');
      expect(cards[0].utterances[0].utteranceId).assertEqual('01ARZ3NDEKTSV4RRFFQ69G5FAY');
      expect(cards[0].utterances[0].revision).assertEqual(7);
      expect(cards[0].utterances[0].speakerLabel).assertEqual('SPEAKER_00');
      expect(cards[0].utterances[0].status).assertEqual('active');
      expect(cards[0].utterances[0].evidenceJson.includes('asset-1')).assertTrue();
    });

    it('queuesOptimisticUtteranceCorrectionInTheDurableOutbox', 0, async () => {
      const repository = new FakePhoneV3Repository();
      const useCases = new PhoneV3UseCases(repository,
        new FakePhoneV3LocalAudio([]), new FakePhoneV3Remote());
      const utterance = mergePhoneV3Sessions([], [], [new PhoneV3ProjectionRow(
        SESSION_ID, 1, JSON.stringify({
          session_id: SESSION_ID,
          session_key: SESSION_KEY,
          captured_start: '2026-01-01T00:00:00Z'
        }), 1000)], [], [new PhoneV3ProjectionRow(
        '01ARZ3NDEKTSV4RRFFQ69G5FAY', 7, JSON.stringify({
          utterance_id: '01ARZ3NDEKTSV4RRFFQ69G5FAY',
          session_id: SESSION_ID,
          speaker_track_id: '01ARZ3NDEKTSV4RRFFQ69G5FAZ',
          speaker_label: 'SPEAKER_00',
          original_speaker_track_id: '01ARZ3NDEKTSV4RRFFQ69G5FAZ',
          original_speaker_label: 'SPEAKER_00',
          identity: 'unknown',
          original_identity: 'unknown',
          identity_evidence: { source: 'none', decision: 'unknown' } as IdentityEvidenceFixture,
          start_ms: 100,
          end_ms: 900,
          start_at: '2026-01-01T00:00:00.100Z',
          end_at: '2026-01-01T00:00:00.900Z',
          text: '测试文本',
          original_text: '测试文本',
          revision: 7,
          status: 'active',
          evidence: { source: 'test' } as CorrectionEvidenceFixture
        }), 2000)])[0].utterances[0];

      await useCases.queueUtteranceCorrection(utterance, ' 修订文本 ', null, 'self');

      expect(repository.operations.length).assertEqual(1);
      expect(repository.operations[0].kind).assertEqual('utterance.correct');
      expect(repository.operations[0].base_revision).assertEqual(7);
      expect(JSON.stringify(repository.operations[0].payload).includes('修订文本')).assertTrue();
      expect(JSON.stringify(repository.operations[0].payload).includes('self')).assertTrue();
    });

    it('loadsOfflineFirstThroughFakeRepositoryWithoutOpeningRemote', 0, async () => {
      const repository = new FakePhoneV3Repository();
      repository.reminderRows = [new PhoneV3ProjectionRow(
        '01ARZ3NDEKTSV4RRFFQ69G5FB0', 1, JSON.stringify({
          event_id: '01ARZ3NDEKTSV4RRFFQ69G5FB0',
          session_id: SESSION_ID,
          event_revision: 1,
          source_candidate_id: '01ARZ3NDEKTSV4RRFFQ69G5FB1',
          title: '发送修订后的文档',
          actor_person_id: 'self',
          commitment_direction: 'self_to_other',
          related_person_ids: ['person-zhang'],
          scheduled_at: '2026-09-02T02:00:00Z',
          location: '学校',
          status: 'scheduled',
          updated_at: '2026-09-01T02:29:00Z'
        }), 3000)];
      const remote = new FakePhoneV3Remote();
      const scheduler = new FakeReminderScheduler();
      const useCases = new PhoneV3UseCases(repository,
        new FakePhoneV3LocalAudio([localFact()]), remote, scheduler);

      const local = await useCases.loadLocal();
      const snapshot = await useCases.loadCached(local);

      expect(snapshot.sessions.length).assertEqual(1);
      expect(snapshot.sessions[0].sessionKey).assertEqual(SESSION_KEY);
      expect(snapshot.sessions[0].sessionId).assertEqual('');
      expect(snapshot.paired).assertTrue();
      expect(snapshot.reminders.length).assertEqual(1);
      expect(snapshot.reminders[0].title).assertEqual('发送修订后的文档');
      expect(scheduler.reconciled.length).assertEqual(1);
      expect(scheduler.reconciled[0].eventId).assertEqual('01ARZ3NDEKTSV4RRFFQ69G5FB0');
      expect(remote.connectCount).assertEqual(0);
    });

    it('surfacesMalformedProjectionWithItsResourceIdentity', 0, async () => {
      const repository = new FakePhoneV3Repository();
      repository.reminderRows = [new PhoneV3ProjectionRow(
        '01ARZ3NDEKTSV4RRFFQ69G5BAD', 1, '{"event_id":', 3000)];
      const useCases = new PhoneV3UseCases(repository,
        new FakePhoneV3LocalAudio([]), new FakePhoneV3Remote());
      let message = '';

      try {
        await useCases.loadCached([]);
      } catch (error) {
        message = error instanceof Error ? error.message : JSON.stringify(error);
      }

      expect(message.includes('reminder')).assertTrue();
      expect(message.includes('01ARZ3NDEKTSV4RRFFQ69G5BAD')).assertTrue();
    });

    it('surfacesContractInvalidUtteranceInsteadOfDroppingIt', 0, () => {
      let message = '';
      try {
        mergePhoneV3Sessions([], [], [new PhoneV3ProjectionRow(
          SESSION_ID, 1, JSON.stringify({ session_id: SESSION_ID }), 1000)], [], [
          new PhoneV3ProjectionRow('01ARZ3NDEKTSV4RRFFQ69G5ERR', 1, '{}', 2000)
        ]);
      } catch (error) {
        message = error instanceof Error ? error.message : JSON.stringify(error);
      }

      expect(message.includes('utterance')).assertTrue();
      expect(message.includes('01ARZ3NDEKTSV4RRFFQ69G5ERR')).assertTrue();
    });

    it('allowsDeletingOnlyAudioThatHasNoComputerProjectionOrUploadedLink', 0, async () => {
      const repository = new FakePhoneV3Repository();
      const useCases = new PhoneV3UseCases(repository,
        new FakePhoneV3LocalAudio([localFact()]), new FakePhoneV3Remote());

      expect(await useCases.localAudioIsProtected(SESSION_KEY)).assertFalse();

      repository.links = [
        new PhoneV3LocalAudioLink(SESSION_KEY, '', '/phone/segment_0.wav', 'uploaded', 1500)
      ];
      expect(await useCases.localAudioIsProtected(SESSION_KEY)).assertTrue();
    });

    it('protectsLocalAudioWhenComputerAlreadyHasTheSession', 0, async () => {
      const repository = new FakePhoneV3Repository();
      repository.recordingRows = [new PhoneV3ProjectionRow(SESSION_ID, 1, JSON.stringify({
        session_id: SESSION_ID,
        session_key: SESSION_KEY
      }), 2000)];
      const useCases = new PhoneV3UseCases(repository,
        new FakePhoneV3LocalAudio([localFact()]), new FakePhoneV3Remote());

      expect(await useCases.localAudioIsProtected(SESSION_KEY)).assertTrue();
    });

    it('mergesCanonicalProjectionThroughTombstoneReboundLink', 0, () => {
      const cards = mergePhoneV3Sessions([localFact()], [
        new PhoneV3LocalAudioLink(SESSION_KEY, SESSION_ID, '/phone/segment_0.wav', 'uploaded', 1500)
      ], [new PhoneV3ProjectionRow(SESSION_ID, 5, JSON.stringify({
        session_id: SESSION_ID,
        captured_start: '2026-01-01T00:00:00Z',
        revision: 5
      }), 3000)], [], []);

      expect(cards.length).assertEqual(1);
      expect(cards[0].sessionKey).assertEqual(SESSION_KEY);
      expect(cards[0].localPaths.length).assertEqual(1);
      expect(cards[0].sessionId).assertEqual(SESSION_ID);
    });

    it('backsUpAudioBeforePullingComputerProjection', 0, async () => {
      const repository = new FakePhoneV3Repository();
      const remote = new FakePhoneV3Remote();
      const backup = new FakeAudioBackup();
      const useCases = new PhoneV3UseCases(repository,
        new FakePhoneV3LocalAudio([localFact()]), remote, undefined, backup);

      const result = await useCases.synchronize();

      expect(backup.calls).assertEqual(1);
      expect(remote.connectCount).assertEqual(1);
      expect(result.backup.uploadedFiles).assertEqual(3);
      expect(result.backup.skippedFiles).assertEqual(4);
    });
  });
}
