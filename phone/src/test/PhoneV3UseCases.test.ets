import { PhoneV3LocalAnnotation, applyLocalAnnotations } from '../main/ets/v3/domain/PhoneV3LocalAnnotation';
import { describe, expect, it } from '@ohos/hypium';
import {
  DeviceV3ClientOperation,
  DeviceV3PersonChoice,
  DeviceV3Change,
  DeviceV3OperationReceipt,
  DeviceV3AnnotationRequest,
  DeviceV3AnnotationResponse,
  DeviceV3ReviewActionRequest,
  DeviceV3ReviewActionResponse,
  DeviceV3ReviewAudioRequest,
  DeviceV3ReviewAudioResponse,
  DeviceV3ReviewSnapshot,
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
  PhoneV3Utterance,
  PhoneV3SessionCard,
  PhoneV3LocalAudioFact,
  PhoneV3LocalAudioLink,
  PhoneV3ProjectionRow,
  PhoneV3Reminder,
  PhoneV3Snapshot,
  PhoneV3SyncStatus
} from '../main/ets/v3/domain/PhoneV3Models';
import { PhoneV3ViewModel } from '../main/ets/v3/presentation/PhoneV3ViewModel';

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

interface ReviewContextFixture {
  scheduled_at: string;
}

interface LegacyReviewFixture {
  review_item_id: string;
  revision: number;
}

interface ReviewSnapshotItemFixture {
  review_id: string;
  updated_at: string;
}

interface ReviewActionResultFixture {
  resolved: boolean;
}

class FakePhoneV3Repository implements PhoneV3ProjectionRepositoryPort {
  recordingRows: Array<PhoneV3ProjectionRow> = [];
  processingRows: Array<PhoneV3ProjectionRow> = [];
  utteranceRows: Array<PhoneV3ProjectionRow> = [];
  reviewRows: Array<PhoneV3ProjectionRow> = [];
  reminderRows: Array<PhoneV3ProjectionRow> = [];
  links: Array<PhoneV3LocalAudioLink> = [];
  conflicts: Array<PhoneV3Conflict> = [];
  cursor: string = 'cursor-0';
  failure: string = '';
  operations: Array<DeviceV3ClientOperation> = [];
  pendingReads: number = 0;
  people: Array<DeviceV3PersonChoice> = [];
  async cachedPeople(): Promise<Array<DeviceV3PersonChoice>> { return this.people; }
  async cachePeople(people: Array<DeviceV3PersonChoice>): Promise<void> {
    for (let person of people) {
      this.people = this.people.filter((value): boolean => value.person_id !== person.person_id).concat([person]);
    }
  }
  async annotationOperations(): Promise<Array<PhonePendingOperation>> {
    return this.operations.filter((value): boolean => ['speaker.assign', 'segment.classify'].indexOf(value.kind) >= 0).map((value): PhonePendingOperation => {
      return { operation_id: value.operation_id, kind: value.kind, base_revision: value.base_revision,
        payload: value.payload, attempt_count: 0 };
    });
  }
  async removeConflict(id: string): Promise<void> {
    this.conflicts = this.conflicts.filter((value): boolean => value.operationId !== id);
  }

  transactions: number = 0;
  commits: number = 0;
  rollbacks: number = 0;
  failKind: string = '';
  private beforeOperations: Array<DeviceV3ClientOperation> = [];
  private beforePeople: Array<DeviceV3PersonChoice> = [];
  async beginTransaction(): Promise<void> {
    this.transactions++;
    this.beforeOperations = this.operations.slice();
    this.beforePeople = this.people.slice();
  }
  async commit(): Promise<void> { this.commits++; }
  async rollback(): Promise<void> {
    this.rollbacks++;
    this.operations = this.beforeOperations;
    this.people = this.beforePeople;
  }
  async applyChange(_change: DeviceV3Change): Promise<void> {}
  async acknowledgeReceipt(_receipt: DeviceV3OperationReceipt): Promise<void> {}
  async clearRebuildableRows(): Promise<void> {}
  async enqueue(operation: DeviceV3ClientOperation): Promise<void> {
    if (operation.kind === this.failKind) { throw new Error('database write failed'); }
    this.operations.push(operation);
  }
  async pendingOperations(_limit: number = 500): Promise<Array<PhonePendingOperation>> { this.pendingReads += 1; return []; }
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
    this.reviewRows = [];
    this.reminderRows = [];
    this.cursor = 'cursor-0';
  }
  async linkLocalAudio(_sessionKey: string, _localPath: string, _sha256: string,
    _uploadStatus: string): Promise<void> {}
  async replaceReviewItems(items: Array<Object>): Promise<void> {
    this.reviewRows = [];
    for (let index = 0; index < items.length; index += 1) {
      const item = items[index] as ReviewSnapshotItemFixture;
      this.reviewRows.push(new PhoneV3ProjectionRow(item.review_id, 1,
        JSON.stringify(item), Date.parse(item.updated_at)));
    }
  }

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
    if (resourceType === 'review_item') {
      return this.reviewRows;
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
  syncRequests: Array<DeviceV3SyncRequest> = [];
  async annotations(_request: DeviceV3AnnotationRequest): Promise<DeviceV3AnnotationResponse> {
    return { people: [] };
  }

  async status(): Promise<DeviceV3StatusResponse> {
    return { contract_version: '3.7.0', projection_version: 4, server_time: '2026-08-31T00:00:00Z' };
  }

  async sync(_request: DeviceV3SyncRequest): Promise<DeviceV3SyncResponse> {
    this.syncRequests.push(_request);
    return {
      projection_version: 4,
      receipts: [],
      changes: [],
      next_cursor: 'cursor-1',
      has_more: false,
      server_time: '2026-08-31T00:00:00Z'
    };
  }

  async reviews(): Promise<DeviceV3ReviewSnapshot> {
    return { items: [] };
  }

  async resolveReview(_request: DeviceV3ReviewActionRequest): Promise<DeviceV3ReviewActionResponse> {
    const result: ReviewActionResultFixture = { resolved: true };
    const reviews: DeviceV3ReviewSnapshot = { items: [] };
    return { result: result, reviews: reviews };
  }

  async reviewAudio(request: DeviceV3ReviewAudioRequest): Promise<DeviceV3ReviewAudioResponse> {
    return {
      review_id: request.review_id,
      prototype_id: request.prototype_id,
      format: 'wav',
      data_base64url: 'UklGRg',
      start_ms: 0,
      end_ms: 1000
    };
  }
}

class FakePhoneV3Remote implements PhoneV3RemotePort {
  connectCount: number = 0;
  session: FakePhoneV3RemoteSession = new FakePhoneV3RemoteSession();
  async isPaired(): Promise<boolean> { return true; }
  async connect(): Promise<PhoneV3RemoteSession> {
    this.connectCount += 1;
    return this.session;
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

    it('refreshesAnnotationProjectionWithoutBackupOrSubmittingOfflineEdits', 0, async () => {
      const repository = new FakePhoneV3Repository();
      repository.cursor = 'cursor-12';
      const remote = new FakePhoneV3Remote();
      const backup = new FakeAudioBackup();
      const useCases = new PhoneV3UseCases(repository,
        new FakePhoneV3LocalAudio([]), remote, undefined, backup);
      await useCases.refreshRemoteProjection();
      expect(backup.calls).assertEqual(0);
      expect(repository.pendingReads).assertEqual(0);
      expect(remote.session.syncRequests.length).assertEqual(1);
      expect(remote.session.syncRequests[0].cursor).assertEqual('cursor-12');
      expect(remote.session.syncRequests[0].client_operations.length).assertEqual(0);
      expect(repository.cursor).assertEqual('cursor-1');
    });

    it('combinedAnnotationCommitsBothDimensionsAndRollsBackFailure', 0, async () => {
      const repository = new FakePhoneV3Repository();
      const remote = new FakePhoneV3Remote();
      const useCases = new PhoneV3UseCases(repository, new FakePhoneV3LocalAudio([]), remote);
      const row = new PhoneV3Utterance('u', 's', null, null, null, null, '', '', '{}',
        0, 1000, '', '', 'text', 'text', 1, 'active', '{}');
      repository.utteranceRows = [new PhoneV3ProjectionRow(row.utteranceId, row.revision, '{"status":"active"}', 1)];
      await useCases.queueAnnotation([row], '', '合成人物甲', true, 'unintelligible');
      expect(repository.operations.length).assertEqual(2);
      expect(repository.transactions).assertEqual(1);
      expect(repository.commits).assertEqual(1);
      expect(remote.connectCount).assertEqual(0);
      repository.failKind = 'segment.classify';
      let failed = false;
      try { await useCases.queueAnnotation([row], '', '另一个人', true, 'media_speech'); }
      catch (error) { failed = true; }
      expect(failed).assertTrue();
      expect(repository.operations.length).assertEqual(2);
      expect(repository.people.length).assertEqual(1);
      expect(repository.rollbacks).assertEqual(1);
    });

    it('savesAnnotationsAndNewPeopleWithoutConnectingAndRestoresPendingOverlay', 0, async () => {
      const repository = new FakePhoneV3Repository();
      const remote = new FakePhoneV3Remote();
      const useCases = new PhoneV3UseCases(repository, new FakePhoneV3LocalAudio([]), remote);
      const row = new PhoneV3Utterance('u', 's', 'track', 'Original', 'track', 'Original',
        'unknown', 'unknown', '{}', 0, 1000, '', '', 'text', 'text', 7, 'active', '{}');
      repository.utteranceRows = [new PhoneV3ProjectionRow(row.utteranceId, row.revision, '{"status":"active"}', 1)];
      await useCases.queueSpeakerAnnotation([row], '', 'Local person');
      const restarted = new PhoneV3UseCases(repository, new FakePhoneV3LocalAudio([]), remote);
      const people = await restarted.localPeople();
      expect(people.length).assertEqual(1);
      await restarted.queueSpeakerAnnotation([row], people[0].person_id, '');
      expect((repository.operations[1].payload as PhoneV3LocalAnnotation).depends_on![0])
        .assertEqual(repository.operations[0].operation_id);
      expect((repository.operations[1].payload as PhoneV3LocalAnnotation).new_person_id).assertEqual(people[0].person_id);
      const session = new PhoneV3SessionCard('s', 's', '', '', '', 0, '', '', '', 0, 1, 0,
        [], 0, 0, '', '', '', 0, [row]);
      applyLocalAnnotations([session], await repository.annotationOperations());
      expect(row.speakerLabel).assertEqual('Local person');
      expect(row.originalSpeakerLabel).assertEqual('Original');
      expect(row.speakerTrackId).assertEqual('track');
      expect(row.revision).assertEqual(7);
      expect(row.annotationPending).assertTrue();
      expect(remote.connectCount).assertEqual(0);
    });

    it('classifiesAndRestoresOfflineWithoutChangingOriginalEvidence', 0, async () => {
      const repository = new FakePhoneV3Repository();
      const remote = new FakePhoneV3Remote();
      const useCases = new PhoneV3UseCases(repository, new FakePhoneV3LocalAudio([]), remote);
      const row = new PhoneV3Utterance('u', 's', 'track', 'Original', 'track', 'Original',
        'unknown', 'unknown', '{}', 0, 1000, '', '', 'text', 'text', 7, 'active', '{}');
      const session = new PhoneV3SessionCard('s', 's', '', '', '', 0, '', '', '', 0, 1, 0,
        [], 0, 0, '', '', '', 0, [row]);
      repository.utteranceRows = [new PhoneV3ProjectionRow(row.utteranceId, row.revision, '{"status":"active"}', 1)];
      await useCases.queueSoundClassification([row], 'non_speech');
      expect(repository.operations[0].kind).assertEqual('segment.classify');
      applyLocalAnnotations([session], await repository.annotationOperations());
      expect(row.soundKind).assertEqual('non_speech');
      expect(row.originalText).assertEqual('text');
      expect(row.revision).assertEqual(7);
      await useCases.queueSoundClassification([row], 'speech');
      applyLocalAnnotations([session], await repository.annotationOperations());
      expect(row.soundKind).assertEqual('speech');
      expect(row.speakerTrackId).assertEqual('track');
      expect(remote.connectCount).assertEqual(0);
    });

    it('retainsConflictPayloadUntilUserChoosesComputerResultOffline', 0, async () => {
      const repository = new FakePhoneV3Repository();
      const remote = new FakePhoneV3Remote();
      const payload: PhoneV3LocalAnnotation = { selections: [], person_name: 'Local' };
      repository.conflicts = [new PhoneV3Conflict('op', 'speaker.assign', 'conflict', '{}', 1, JSON.stringify(payload))];
      const useCases = new PhoneV3UseCases(repository, new FakePhoneV3LocalAudio([]), remote);
      expect((await useCases.loadCached([])).conflicts[0].payloadJson).assertEqual(JSON.stringify(payload));
      await useCases.resolveAnnotationConflict('op', false);
      expect(repository.conflicts.length).assertEqual(0);
      expect(repository.operations.length).assertEqual(0);
      expect(remote.connectCount).assertEqual(0);
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

    it('requeuesReviewedRevisionsAndKeepsConflictWhenReviewIsStale', 0, async () => {
      const repository = new FakePhoneV3Repository();
      const remote = new FakePhoneV3Remote();
      const useCases = new PhoneV3UseCases(repository, new FakePhoneV3LocalAudio([]), remote);
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
      const payload: PhoneV3LocalAnnotation = { person_id: 'p', person_name: 'Local', selections: [
        { utterance_id: utterance.utteranceId, revision: 1, text: 'old', speaker_label: 'old' }
      ] };
      repository.recordingRows = [new PhoneV3ProjectionRow(SESSION_ID, 1,
        JSON.stringify({ session_id: SESSION_ID, session_key: SESSION_KEY, captured_start: '2026-01-01T00:00:00Z' }), 1)];
      repository.utteranceRows = [new PhoneV3ProjectionRow(utterance.utteranceId, 7, JSON.stringify({
        utterance_id: utterance.utteranceId, session_id: SESSION_ID,
        speaker_track_id: utterance.speakerTrackId, speaker_label: utterance.speakerLabel,
        original_speaker_track_id: utterance.originalSpeakerTrackId, original_speaker_label: utterance.originalSpeakerLabel,
        identity: utterance.identity, original_identity: utterance.originalIdentity,
        identity_evidence: { source: 'none', decision: 'unknown' } as IdentityEvidenceFixture,
        start_ms: utterance.startMs, end_ms: utterance.endMs, start_at: utterance.startAt, end_at: utterance.endAt,
        text: utterance.text, original_text: utterance.originalText, revision: 7, status: 'active',
        evidence: { source: 'test' } as CorrectionEvidenceFixture
      }), 1)];
      repository.conflicts = [new PhoneV3Conflict('op', 'speaker.assign', 'conflict', '{}', 1, JSON.stringify(payload))];
      let failed = false;
      try { await useCases.resolveAnnotationConflict('op', true, []); } catch (error) { failed = true; }
      expect(failed).assertTrue();
      expect(repository.conflicts.length).assertEqual(1);
      expect(repository.operations.length).assertEqual(0);
      await useCases.resolveAnnotationConflict('op', true, [utterance]);
      expect(repository.conflicts.length).assertEqual(0);
      expect((repository.operations[0].payload as PhoneV3LocalAnnotation).selections[0].revision).assertEqual(7);
      expect(remote.connectCount).assertEqual(0);
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

    it('loadsReviewInboxProjectionIntoOfflineSnapshot', 0, async () => {
      const repository = new FakePhoneV3Repository();
      const reviewContext: ReviewContextFixture = {
        scheduled_at: '2026-09-02T07:00:00Z'
      };
      const legacyReview: LegacyReviewFixture = {
        review_item_id: 'legacy-review',
        revision: 1
      };
      repository.reviewRows = [
        new PhoneV3ProjectionRow('01ARZ3NDEKTSV4RRFFQ69G5OLD', 1,
          JSON.stringify(legacyReview), 2000),
        new PhoneV3ProjectionRow(
        '01ARZ3NDEKTSV4RRFFQ69G5FRV', 1, JSON.stringify({
          review_id: `reminder:01ARZ3NDEKTSV4RRFFQ69G5FB1`,
          kind: 'reminder',
          priority: 'high',
          source_id: '01ARZ3NDEKTSV4RRFFQ69G5FB1',
          source_revision: 2,
          session_id: SESSION_ID,
          person_id: 'self',
          title: '确认下午三点给医院打电话',
          summary: '候选提醒需要人工确认',
          reason: 'reminder_requires_confirmation',
          evidence_count: 1,
          created_at: '2026-09-02T01:00:00Z',
          updated_at: '2026-09-02T01:00:00Z',
          context: reviewContext
        }), 3000)
      ];
      const useCases = new PhoneV3UseCases(repository,
        new FakePhoneV3LocalAudio([]), new FakePhoneV3Remote());

      const snapshot = await useCases.loadCached([]);

      expect(snapshot.reviewItems.length).assertEqual(1);
      expect(snapshot.reviewItems[0].kind).assertEqual('reminder');
      expect(snapshot.reviewItems[0].sessionId).assertEqual(SESSION_ID);
      expect(snapshot.reviewItems[0].evidenceCount).assertEqual(1);
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

    it('usesPhoneComputerBindingWhenProjectionContainsAStaleSessionKey', 0, () => {
      const cards = mergePhoneV3Sessions([localFact()], [
        new PhoneV3LocalAudioLink(SESSION_KEY, SESSION_ID, '/phone/segment_0.wav', 'uploaded', 1500)
      ], [new PhoneV3ProjectionRow(SESSION_ID, 5, JSON.stringify({
        session_id: SESSION_ID,
        session_key: 'watch-session:stale-key',
        captured_start: '2026-01-01T00:00:00Z',
        revision: 5
      }), 3000)], [], []);

      expect(cards.length).assertEqual(1);
      expect(cards[0].sessionKey).assertEqual(SESSION_KEY);
      expect(cards[0].localPaths.length).assertEqual(1);
      expect(cards[0].sessionId).assertEqual(SESSION_ID);
    });

    it('usesTheLocalSessionBehindAnyBindingWhenTheNewestBindingIsStale', 0, () => {
      const cards = mergePhoneV3Sessions([localFact()], [
        new PhoneV3LocalAudioLink('watch-session:stale-key', SESSION_ID,
          '/phone/old-segment.wav', 'uploaded', 2000),
        new PhoneV3LocalAudioLink(SESSION_KEY, SESSION_ID,
          '/phone/segment_0.wav', 'uploaded', 1500)
      ], [new PhoneV3ProjectionRow(SESSION_ID, 5, JSON.stringify({
        session_id: SESSION_ID,
        session_key: 'watch-session:stale-key',
        captured_start: '2026-01-01T00:00:00Z',
        revision: 5
      }), 3000)], [], []);

      expect(cards.length).assertEqual(1);
      expect(cards[0].sessionKey).assertEqual(SESSION_KEY);
      expect(cards[0].localPaths.length).assertEqual(1);
    });

    it('deduplicatesComputerRowsThatRepresentTheSameStableSession', 0, () => {
      const cards = mergePhoneV3Sessions([], [], [
        new PhoneV3ProjectionRow(SESSION_ID, 5, JSON.stringify({
          session_id: SESSION_ID, session_key: SESSION_KEY,
          captured_start: '2026-01-01T00:00:00Z', revision: 5
        }), 3000),
        new PhoneV3ProjectionRow('01ARZ3NDEKTSV4RRFFQ69G5DUP', 3, JSON.stringify({
          session_id: '01ARZ3NDEKTSV4RRFFQ69G5DUP', session_key: SESSION_KEY,
          captured_start: '2026-01-01T00:00:00Z', revision: 3
        }), 2000)
      ], [], []);

      expect(cards.length).assertEqual(1);
      expect(cards[0].sessionId).assertEqual(SESSION_ID);
    });

    it('keepsDistinctSessionsEvenWhenTheirDisplayTimeMatches', 0, () => {
      const cards = mergePhoneV3Sessions([], [], [
        new PhoneV3ProjectionRow(SESSION_ID, 1, JSON.stringify({
          session_id: SESSION_ID, session_key: 'watch-session:first',
          captured_start: '2026-01-01T00:00:00Z'
        }), 3000),
        new PhoneV3ProjectionRow('01ARZ3NDEKTSV4RRFFQ69G5TWO', 1, JSON.stringify({
          session_id: '01ARZ3NDEKTSV4RRFFQ69G5TWO', session_key: 'watch-session:second',
          captured_start: '2026-01-01T00:00:00Z'
        }), 2000)
      ], [], []);

      expect(cards.length).assertEqual(2);
    });

    it('returnsTheAuthoritativeReviewSnapshotImmediatelyAfterAResolution', 0, async () => {
      const repository = new FakePhoneV3Repository();
      repository.reviewRows = [new PhoneV3ProjectionRow('review-before', 1, '{}', 1000)];
      const useCases = new PhoneV3UseCases(repository,
        new FakePhoneV3LocalAudio([]), new FakePhoneV3Remote());

      const items = await useCases.resolveReview({
        review_id: 'review-before', action: 'confirm', prototype_id: 'prototype-1'
      });

      expect(items.length).assertEqual(0);
      expect(repository.reviewRows.length).assertEqual(0);
    });

    it('resolvesAHomeBootstrapCardToTheCurrentComputerSession', 0, () => {
      const bootstrap = mergePhoneV3Sessions([localFact()], [], [], [], [])[0];
      const current = mergePhoneV3Sessions([localFact()], [
        new PhoneV3LocalAudioLink(SESSION_KEY, SESSION_ID, '/phone/segment_0.wav', 'uploaded', 1500)
      ], [new PhoneV3ProjectionRow(SESSION_ID, 5, JSON.stringify({
        session_id: SESSION_ID,
        session_key: SESSION_KEY,
        captured_start: '2026-01-01T00:00:00Z',
        revision: 5
      }), 3000)], [], [])[0];
      const viewModel = new PhoneV3ViewModel();
      viewModel.snapshot = new PhoneV3Snapshot([current]);

      const resolved = viewModel.resolveCurrentSession(bootstrap);

      expect(resolved.sessionId).assertEqual(SESSION_ID);
      expect(resolved.id).assertEqual(SESSION_ID);
      expect(resolved.localPaths.length).assertEqual(1);
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
