import { describe, it, expect } from '@ohos/hypium';
import {
  decodeV3ContractFixture,
  isV3FeatureEnabled,
  V3ContractFixture,
  V3DecodedFixture
} from '../main/ets/v3/contracts/V3ContractModels';

// Generated with the fixture bodies. Python contract tests verify these receipts
// against the canonical JSON files when both repositories are checked out.
const CORE_FIXTURE_SHA256: string =
  'b6bad8928c4a9e331f99f46c78462e54417c623e94902134bb91cf934fd3b7a7';
const FORWARD_FIXTURE_SHA256: string =
  '22e8f9407c98bee742f776eceb85b34c8aa6020fc34c3d681377b0cbbe4eb760';

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

    it('degradesUnknownEnumsAndKeepsV3DisabledByDefault', 0, () => {
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
      expect(isV3FeatureEnabled()).assertFalse();
      expect(isV3FeatureEnabled('true')).assertTrue();
    });
  });
}
