import { describe, expect, it } from '@ohos/hypium';
import {
  DeviceV3Change,
  DeviceV3OperationReceipt,
  DeviceV3StatusResponse,
  DeviceV3SyncRequest,
  DeviceV3SyncResponse
} from '../main/ets/computer/ComputerTransferProtocol';
import {
  PhoneV3LocalAudioRepositoryPort,
  PhoneV3ProjectionRepositoryPort,
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
  PhoneV3SyncStatus
} from '../main/ets/v3/domain/PhoneV3Models';

const SESSION_ID: string = '01ARZ3NDEKTSV4RRFFQ69G5FAW';
const SESSION_KEY: string = 'watch-session:1767225600000';
const LOCAL_GROUP_KEY: string = 'session:pcm_session_1767225600000';

interface EvidenceFixture {
  asset_id: string;
}

class FakePhoneV3Repository implements PhoneV3ProjectionRepositoryPort {
  recordingRows: Array<PhoneV3ProjectionRow> = [];
  processingRows: Array<PhoneV3ProjectionRow> = [];
  utteranceRows: Array<PhoneV3ProjectionRow> = [];
  links: Array<PhoneV3LocalAudioLink> = [];
  conflicts: Array<PhoneV3Conflict> = [];
  cursor: string = 'cursor-0';
  failure: string = '';

  async beginTransaction(): Promise<void> {}
  async commit(): Promise<void> {}
  async rollback(): Promise<void> {}
  async applyChange(_change: DeviceV3Change): Promise<void> {}
  async acknowledgeReceipt(_receipt: DeviceV3OperationReceipt): Promise<void> {}
  async clearRebuildableRows(): Promise<void> {}
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
    this.cursor = 'cursor-0';
  }

  async projectionRows(resourceType: string): Promise<Array<PhoneV3ProjectionRow>> {
    if (resourceType === 'recording_session') {
      return this.recordingRows;
    }
    if (resourceType === 'processing_run') {
      return this.processingRows;
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
    return { contract_version: '3.0.0', projection_version: 1, server_time: '2026-08-31T00:00:00Z' };
  }

  async sync(_request: DeviceV3SyncRequest): Promise<DeviceV3SyncResponse> {
    return {
      projection_version: 1,
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
        start_ms: 100,
        end_ms: 900,
        text: '测试文本',
        revision: 7,
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
      expect(cards[0].utterances[0].evidenceJson.includes('asset-1')).assertTrue();
    });

    it('loadsOfflineFirstThroughFakeRepositoryWithoutOpeningRemote', 0, async () => {
      const repository = new FakePhoneV3Repository();
      const remote = new FakePhoneV3Remote();
      const useCases = new PhoneV3UseCases(repository,
        new FakePhoneV3LocalAudio([localFact()]), remote);

      const local = await useCases.loadLocal();
      const snapshot = await useCases.loadCached(local);

      expect(snapshot.sessions.length).assertEqual(1);
      expect(snapshot.sessions[0].sessionKey).assertEqual(SESSION_KEY);
      expect(snapshot.sessions[0].sessionId).assertEqual('');
      expect(snapshot.paired).assertTrue();
      expect(remote.connectCount).assertEqual(0);
    });
  });
}
