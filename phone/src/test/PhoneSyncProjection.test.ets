import { describe, it, expect } from '@ohos/hypium';
import {
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

class FakeProjectionStorage implements PhoneProjectionStorage {
  rows: Map<string, string> = new Map<string, string>();
  outbox: Set<string> = new Set<string>([OPERATION_ID]);
  localAudio: Set<string> = new Set<string>(['/phone/session/segment.wav']);
  cursor: string = 'cursor-0';
  failAtChange: number = -1;
  private changeCount: number = 0;
  private savedRows: Map<string, string> = new Map<string, string>();
  private savedOutbox: Set<string> = new Set<string>();
  private savedCursor: string = 'cursor-0';

  async beginTransaction(): Promise<void> {
    this.savedRows = new Map<string, string>(this.rows);
    this.savedOutbox = new Set<string>(this.outbox);
    this.savedCursor = this.cursor;
    this.changeCount = 0;
  }

  async commit(): Promise<void> {
  }

  async rollback(): Promise<void> {
    this.rows = new Map<string, string>(this.savedRows);
    this.outbox = new Set<string>(this.savedOutbox);
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
    this.outbox.delete(receipt.operation_id);
  }

  async setCursor(cursor: string, serverTime: string): Promise<void> {
    this.cursor = cursor;
  }

  async clearRebuildableRows(): Promise<void> {
    this.rows.clear();
  }
}

function response(): DeviceV3SyncResponse {
  const receipt: DeviceV3OperationReceipt = {
    operation_id: OPERATION_ID,
    status: 'applied',
    resource_revision: 2,
    error: null
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

    it('rollsBackCursorOutboxAndRowsWhenResponseApplicationCrashes', 0, async () => {
      const storage = new FakeProjectionStorage();
      storage.failAtChange = 2;
      let failed = false;
      try {
        await applySyncResponse(storage, response());
      } catch (error) {
        failed = true;
      }
      expect(failed).assertTrue();
      expect(storage.cursor).assertEqual('cursor-0');
      expect(storage.outbox.has(OPERATION_ID)).assertTrue();
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
