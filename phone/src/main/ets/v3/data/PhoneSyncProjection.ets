import {
  DeviceV3Change,
  DeviceV3ClientOperation,
  DeviceV3OperationReceipt,
  DeviceV3SyncResponse
} from '../../computer/ComputerTransferProtocol';
import { V3_PROJECTION_VERSION } from '../contracts/V3ContractModels';

const STABLE_ID: RegExp = /^(?:[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}|[0-9A-HJKMNP-TV-Z]{26})$/;
const CURSOR: RegExp = /^cursor-(0|[1-9][0-9]*)$/;
const RESOURCE_TYPES: Array<string> = [
  'recording_session', 'audio_asset', 'processing_run', 'utterance', 'review_item'
];

export interface PhonePendingOperation extends DeviceV3ClientOperation {
  attempt_count: number;
}

export interface PhoneProjectionStorage {
  beginTransaction(): Promise<void>;
  commit(): Promise<void>;
  rollback(): Promise<void>;
  applyChange(change: DeviceV3Change): Promise<void>;
  acknowledgeReceipt(receipt: DeviceV3OperationReceipt): Promise<void>;
  setCursor(cursor: string, serverTime: string): Promise<void>;
  clearRebuildableRows(): Promise<void>;
}

export async function applySyncResponse(storage: PhoneProjectionStorage,
  response: DeviceV3SyncResponse): Promise<void> {
  validateSyncResponse(response);
  await storage.beginTransaction();
  try {
    for (let index = 0; index < response.receipts.length; index += 1) {
      await storage.acknowledgeReceipt(response.receipts[index]);
    }
    for (let index = 0; index < response.changes.length; index += 1) {
      await storage.applyChange(response.changes[index]);
    }
    // Cursor publication is deliberately last. A process crash or failed write
    // rolls back all projection rows and leaves the previous cursor intact.
    await storage.setCursor(response.next_cursor, response.server_time);
    await storage.commit();
  } catch (error) {
    await storage.rollback();
    throw projectionError(error as Object);
  }
}

export async function clearRebuildableProjection(storage: PhoneProjectionStorage): Promise<void> {
  await storage.beginTransaction();
  try {
    await storage.clearRebuildableRows();
    await storage.setCursor('cursor-0', '');
    await storage.commit();
  } catch (error) {
    await storage.rollback();
    throw projectionError(error as Object);
  }
}

function projectionError(error: Object): Error {
  if (error instanceof Error) {
    return error;
  }
  return new Error(JSON.stringify(error));
}

export function validateSyncResponse(response: DeviceV3SyncResponse): void {
  if (response.projection_version !== V3_PROJECTION_VERSION ||
    !CURSOR.test(response.next_cursor) || !Array.isArray(response.receipts) ||
    !Array.isArray(response.changes) || response.receipts.length > 500 ||
    response.changes.length > 500 || typeof response.has_more !== 'boolean' ||
    typeof response.server_time !== 'string') {
    throw new Error('电脑返回的 V3 同步响应无效');
  }
  let previousSequence = -1;
  for (let index = 0; index < response.receipts.length; index += 1) {
    const receipt = response.receipts[index];
    if (!STABLE_ID.test(receipt.operation_id) ||
      ['applied', 'conflict', 'rejected'].indexOf(receipt.status) < 0) {
      throw new Error('电脑返回的 V3 操作回执无效');
    }
  }
  for (let index = 0; index < response.changes.length; index += 1) {
    const change = response.changes[index];
    if (!Number.isSafeInteger(change.sequence) || change.sequence <= previousSequence ||
      !STABLE_ID.test(change.resource_id) || !Number.isSafeInteger(change.revision) ||
      change.revision < 1 || RESOURCE_TYPES.indexOf(change.resource_type) < 0 ||
      ['upsert', 'tombstone'].indexOf(change.operation) < 0 ||
      (change.operation === 'upsert' && change.resource === null)) {
      throw new Error('电脑返回的 V3 投影变更无效');
    }
    previousSequence = change.sequence;
  }
}
