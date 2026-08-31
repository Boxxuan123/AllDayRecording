import { describe, it, expect } from '@ohos/hypium';
import {
  decodeV3ContractFixture,
  isV3FeatureEnabled,
  validateV3UtteranceDto,
  V3ContractFixture,
  V3DecodedFixture,
  V3UtteranceDto
} from '../main/ets/v3/contracts/V3ContractModels';

// Generated with the fixture bodies. Python contract tests verify these receipts
// against the canonical JSON files when both repositories are checked out.
const CORE_FIXTURE_SHA256: string =
  '91659a8267d211d5f5bfe93ed5efaa300c1fde93bae7cc0ee88ba0bd701c41ee';
const FORWARD_FIXTURE_SHA256: string =
  '22e8f9407c98bee742f776eceb85b34c8aa6020fc34c3d681377b0cbbe4eb760';

interface UtteranceEvidenceFixture {
  media_id: string;
  start_ms: number;
  end_ms: number;
}

function canonicalFixture(): V3ContractFixture {
  return {
    contract_version: '3.0.0',
    recording_session: {
      state: 'ready_for_processing',
      status_code: 'ready'
    },
    processing_run: { status: 'running' },
    device_sync_response: {
      receipts: [{ status: 'applied' }],
      changes: [{ resource_type: 'utterance', operation: 'upsert' }],
      next_cursor: 'cursor-42'
    }
  };
}

function futureEnumFixture(): V3ContractFixture {
  return {
    contract_version: '3.0.0',
    recording_session: {
      state: 'future_archived_state',
      status_code: 'future_aggregate_status'
    },
    processing_run: { status: 'future_processing_status' },
    device_sync_response: {
      receipts: [{ status: 'future_receipt_status' }],
      changes: [{ resource_type: 'future_resource_type', operation: 'future_operation' }]
    }
  };
}

function expectDecoded(actual: V3DecodedFixture, expected: V3DecodedFixture): void {
  expect(JSON.stringify(actual)).assertEqual(JSON.stringify(expected));
}

export default function v3ContractFixtureTest() {
  describe('V3ContractFixture', () => {
    it('decodesCanonicalComputerFixture', 0, () => {
      expect(CORE_FIXTURE_SHA256.length).assertEqual(64);
      expectDecoded(decodeV3ContractFixture(canonicalFixture()), {
        contract_version: '3.0.0',
        session_state: 'ready_for_processing',
        aggregate_status: 'ready',
        processing_status: 'running',
        receipt_status: 'applied',
        change_resource_type: 'utterance',
        change_operation: 'upsert',
        next_cursor: 'cursor-42'
      });
    });

    it('degradesUnknownEnumsAndKeepsV3EnabledByDefault', 0, () => {
      expect(FORWARD_FIXTURE_SHA256.length).assertEqual(64);
      expectDecoded(decodeV3ContractFixture(futureEnumFixture()), {
        contract_version: '3.0.0',
        session_state: 'unknown',
        aggregate_status: 'unknown',
        processing_status: 'unknown',
        receipt_status: 'unknown',
        change_resource_type: 'unknown',
        change_operation: 'unknown',
        next_cursor: null
      });
      expect(isV3FeatureEnabled()).assertTrue();
      expect(isV3FeatureEnabled('true')).assertTrue();
    });

    it('validatesCanonicalUtteranceDtoAtRuntime', 0, () => {
      const evidence: UtteranceEvidenceFixture = {
        media_id: '01ARZ3NDEKTSV4RRFFQ69G5FAX',
        start_ms: 100,
        end_ms: 900
      };
      const candidate: V3UtteranceDto = {
        utterance_id: '01ARZ3NDEKTSV4RRFFQ69G5FAY',
        session_id: '01ARZ3NDEKTSV4RRFFQ69G5FAW',
        speaker_track_id: '01ARZ3NDEKTSV4RRFFQ69G5FAZ',
        speaker_label: 'SPEAKER_00',
        start_ms: 100,
        end_ms: 900,
        text: '测试文本',
        revision: 7,
        status: 'active',
        evidence: evidence
      };
      const utterance = validateV3UtteranceDto(candidate);
      expect(utterance.speaker_label).assertEqual('SPEAKER_00');
      expect(utterance.end_ms).assertEqual(900);
      let rejected = false;
      try {
        utterance.end_ms = 100;
        validateV3UtteranceDto(utterance);
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });
  });
}
