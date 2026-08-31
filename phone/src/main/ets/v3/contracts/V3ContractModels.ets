/**
 * Generated consumer snapshot of AllDayRecording-ASR/contracts/v3.
 * Canonical schemas and enums remain in the Computer repository.
 */

export const V3_CONTRACT_VERSION: string = '3.0.0';
export const V3_PROJECTION_VERSION: number = 1;
export const V3_UNKNOWN_ENUM_VALUE: string = 'unknown';
export const V3_FEATURE_ENABLED_BY_DEFAULT: boolean = false;

const RECORDING_SESSION_STATES: string[] = [
  'capturing', 'closing', 'recovering', 'quarantined', 'sealed',
  'phone_verified', 'computer_ingested', 'admission_pending',
  'admission_blocked', 'ready_for_processing'
];
const AGGREGATE_STATUSES: string[] = [
  'awaiting_upload', 'verifying', 'backup_required', 'ready', 'processing',
  'needs_review', 'available', 'failed', 'stale'
];
const PROCESSING_STATUSES: string[] = [
  'created', 'queued', 'running', 'waiting_review', 'succeeded',
  'failed_retryable', 'failed_final', 'cancel_requested', 'cancelled', 'stale'
];
const RECEIPT_STATUSES: string[] = ['pending', 'applied', 'conflict', 'rejected'];
const RESOURCE_TYPES: string[] = [
  'recording_session', 'audio_asset', 'processing_run', 'utterance', 'review_item'
];
const SYNC_OPERATIONS: string[] = ['upsert', 'tombstone'];

export interface V3RecordingSessionFixture {
  state: string;
  status_code: string;
}

export interface V3ProcessingRunFixture {
  status: string;
}

export interface V3ReceiptFixture {
  status: string;
}

export interface V3ChangeFixture {
  resource_type: string;
  operation: string;
}

export interface V3DeviceSyncFixture {
  receipts: V3ReceiptFixture[];
  changes: V3ChangeFixture[];
  next_cursor?: string | null;
}

export interface V3ContractFixture {
  contract_version: string;
  recording_session: V3RecordingSessionFixture;
  processing_run: V3ProcessingRunFixture;
  device_sync_response: V3DeviceSyncFixture;
}

export interface V3DecodedFixture {
  contract_version: string;
  session_state: string;
  aggregate_status: string;
  processing_status: string;
  receipt_status: string;
  change_resource_type: string;
  change_operation: string;
  next_cursor: string | null;
}

function normalizeEnum(value: string, known: string[]): string {
  return known.indexOf(value) >= 0 ? value : V3_UNKNOWN_ENUM_VALUE;
}

export function decodeV3ContractFixture(payload: V3ContractFixture): V3DecodedFixture {
  const receipt = payload.device_sync_response.receipts[0];
  const change = payload.device_sync_response.changes[0];
  return {
    contract_version: payload.contract_version,
    session_state: normalizeEnum(payload.recording_session.state, RECORDING_SESSION_STATES),
    aggregate_status: normalizeEnum(payload.recording_session.status_code, AGGREGATE_STATUSES),
    processing_status: normalizeEnum(payload.processing_run.status, PROCESSING_STATUSES),
    receipt_status: normalizeEnum(receipt.status, RECEIPT_STATUSES),
    change_resource_type: normalizeEnum(change.resource_type, RESOURCE_TYPES),
    change_operation: normalizeEnum(change.operation, SYNC_OPERATIONS),
    next_cursor: typeof payload.device_sync_response.next_cursor === 'string' ?
      payload.device_sync_response.next_cursor : null
  };
}

export function isV3FeatureEnabled(value?: string): boolean {
  if (value === undefined) {
    return V3_FEATURE_ENABLED_BY_DEFAULT;
  }
  const normalized = value.toLowerCase();
  return normalized === '1' || normalized === 'true' || normalized === 'yes' || normalized === 'on';
}
