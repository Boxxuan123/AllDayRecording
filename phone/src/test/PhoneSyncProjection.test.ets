import { describe, it, expect } from '@ohos/hypium';
import {
  DeviceV3ApiError,
  DeviceV3Change,
  DeviceV3OperationReceipt,
  DeviceV3SyncResponse
} from '../main/ets/computer/ComputerTransferProtocol';
import { retryDelayMs } from '../main/ets/v3/data/PhoneSyncCoordinator';
import {
  PhoneProjectionStorage,
  applySyncResponse,
  clearRebuildableProjection
} from '../main/ets/v3/data/PhoneSyncProjection';

const OPERATION_ID: string = '01ARZ3NDEKTSV4RRFFQ69G5FAV';
const SESSION_ID: string = '01ARZ3NDEKTSV4RRFFQ69G5FAW';
const ASSET_ID: string = '01ARZ3NDEKTSV4RRFFQ69G5FAX';

interface SessionProjectionFixture {
  status_code: string;
  revision: number;
}

interface AssetProjectionFixture {
  size_bytes: number;
  revision: number;
}

interface ReceiptErrorDetailsFixture {
  terminal_status: string;
}

class FakeProjectionStorage implements PhoneProjectionStorage {
  rows: Map<string, string> = new Map<string, string>();
  outbox: Set<string> = new Set<string>([OPERATION_ID]);
  operationPayloads: Map<string, string> = new Map<string, string>([
    [OPERATION_ID, JSON.stringify({ decision: 'keep-me' })]
  ]);
  terminalReceipts: Map<string, string> = new Map<string, string>();
  localAudio: Set<string> = new Set<string>(['/phone/session/segment.wav']);
  cursor: string = 'cursor-0';
  failAtChange: number = -1;
  private changeCount: number = 0;
  private savedRows: Map<string, string> = new Map<string, string>();
  private savedOutbox: Set<string> = new Set<string>();
  private savedTerminalReceipts: Map<string, string> = new Map<string, string>();
  private savedCursor: string = 'cursor-0';

  async beginTransaction(): Promise<void> {
    this.savedRows = new Map<string, string>(this.rows);
    this.savedOutbox = new Set<string>(this.outbox);
    this.savedTerminalReceipts = new Map<string, string>(this.terminalReceipts);
    this.savedCursor = this.cursor;
    this.changeCount = 0;
  }

  async commit(): Promise<void> {
  }

  async rollback(): Promise<void> {
    this.rows = new Map<string, string>(this.savedRows);
    this.outbox = new Set<string>(this.savedOutbox);
    this.terminalReceipts = new Map<string, string>(this.savedTerminalReceipts);
    this.cursor = this.savedCursor;
  }

  async applyChange(change: DeviceV3Change): Promise<void> {
    this.changeCount += 1;
    if (this.changeCount === this.failAtChange) {
      throw new Error('injected projection crash');
    }
    const key = `${change.resource_type}:${change.resource_id}`;
    if (change.operation === 'tombstone') {
      this.rows.delete(key);
    } else {
      this.rows.set(key, JSON.stringify(change.resource));
    }
  }

  async acknowledgeReceipt(receipt: DeviceV3OperationReceipt): Promise<void> {
    if (receipt.status === 'conflict' || receipt.status === 'rejected') {
      this.terminalReceipts.set(receipt.operation_id, JSON.stringify({
        status: receipt.status,
        payload: this.operationPayloads.get(receipt.operation_id),
        error: receipt.error
      }));
    }
    this.outbox.delete(receipt.operation_id);
  }

  async setCursor(cursor: string, serverTime: string): Promise<void> {
    this.cursor = cursor;
  }

  async clearRebuildableRows(): Promise<void> {
    this.rows.clear();
  }
}

function response(status: string = 'applied'): DeviceV3SyncResponse {
  let receiptError: DeviceV3ApiError | null = null;
  if (status !== 'applied') {
    const details: ReceiptErrorDetailsFixture = { terminal_status: status };
    receiptError = {
      code: status === 'conflict' ? 'REVISION_CONFLICT' : 'INVALID_OPERATION',
      message: `terminal ${status}`,
      details: details,
      request_id: '01ARZ3NDEKTSV4RRFFQ69G5FAZ'
    };
  }
  const receipt: DeviceV3OperationReceipt = {
    operation_id: OPERATION_ID,
    status: status,
    resource_revision: status === 'applied' ? 2 : null,
    error: receiptError
  };
  const session: SessionProjectionFixture = { status_code: 'ready', revision: 1 };
  const asset: AssetProjectionFixture = { size_bytes: 244, revision: 1 };
  const sessionChange: DeviceV3Change = {
    sequence: 1,
    resource_type: 'recording_session',
    resource_id: SESSION_ID,
    revision: 1,
    operation: 'upsert',
    resource: session
  };
  const assetChange: DeviceV3Change = {
    sequence: 2,
    resource_type: 'audio_asset',
    resource_id: ASSET_ID,
    revision: 1,
    operation: 'upsert',
    resource: asset
  };
  return {
    projection_version: 1,
    receipts: [receipt],
    changes: [sessionChange, assetChange],
    next_cursor: 'cursor-2',
    has_more: false,
    server_time: '2026-08-31T00:00:00Z'
  };
}

export default function phoneSyncProjectionTest() {
  describe('PhoneSyncProjection', () => {
    it('atomicallyAppliesReceiptChangesAndCursorWithoutReplayDuplicates', 0, async () => {
      const storage = new FakeProjectionStorage();
      await applySyncResponse(storage, response());
      expect(storage.cursor).assertEqual('cursor-2');
      expect(storage.outbox.size).assertEqual(0);
      expect(storage.rows.size).assertEqual(2);

      await applySyncResponse(storage, response());
      expect(storage.rows.size).assertEqual(2);
      expect(storage.cursor).assertEqual('cursor-2');
    });

    it('retainsConflictAndRejectedPayloadsAndReplaysWithoutDuplicates', 0, async () => {
      for (const status of ['conflict', 'rejected']) {
        const storage = new FakeProjectionStorage();
        await applySyncResponse(storage, response(status));
        expect(storage.outbox.size).assertEqual(0);
        expect(storage.terminalReceipts.size).assertEqual(1);
        const retained = storage.terminalReceipts.get(OPERATION_ID) ?? '';
        expect(retained.includes(status)).assertTrue();
        expect(retained.includes('keep-me')).assertTrue();

        await applySyncResponse(storage, response(status));
        expect(storage.terminalReceipts.size).assertEqual(1);
      }
    });

    it('rollsBackCursorOutboxAndRowsWhenResponseApplicationCrashes', 0, async () => {
      const storage = new FakeProjectionStorage();
      storage.failAtChange = 2;
      let failed = false;
      try {
        await applySyncResponse(storage, response('rejected'));
      } catch (error) {
        failed = true;
      }
      expect(failed).assertTrue();
      expect(storage.cursor).assertEqual('cursor-0');
      expect(storage.outbox.has(OPERATION_ID)).assertTrue();
      expect(storage.terminalReceipts.size).assertEqual(0);
      expect(storage.rows.size).assertEqual(0);
    });

    it('clearsOnlyRebuildableProjectionAndPreservesOfflineState', 0, async () => {
      const storage = new FakeProjectionStorage();
      await applySyncResponse(storage, response());
      storage.outbox.add(OPERATION_ID);
      await clearRebuildableProjection(storage);
      expect(storage.rows.size).assertEqual(0);
      expect(storage.cursor).assertEqual('cursor-0');
      expect(storage.outbox.has(OPERATION_ID)).assertTrue();
      expect(storage.localAudio.has('/phone/session/segment.wav')).assertTrue();
      expect(retryDelayMs(20)).assertEqual(300000);
    });
  });
}
