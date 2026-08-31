import { ComputerTransferHttpClient } from '../../computer/ComputerTransferHttpClient';
import {
  DeviceV3ClientOperation,
  DeviceV3SyncRequest
} from '../../computer/ComputerTransferProtocol';
import { V3_CONTRACT_VERSION, V3_PROJECTION_VERSION } from '../contracts/V3ContractModels';
import { PhoneProjectionRepository } from './PhoneProjectionRepository';
import { PhonePendingOperation, applySyncResponse } from './PhoneSyncProjection';

export interface PhoneSyncResult {
  batches: number;
  submitted_operations: number;
  final_cursor: string;
}

export class PhoneSyncCoordinator {
  private client: ComputerTransferHttpClient;
  private repository: PhoneProjectionRepository;

  constructor(client: ComputerTransferHttpClient, repository: PhoneProjectionRepository) {
    this.client = client;
    this.repository = repository;
  }

  async synchronize(): Promise<PhoneSyncResult> {
    try {
      const status = await this.client.v3Status();
      if (status.contract_version !== V3_CONTRACT_VERSION ||
        status.projection_version !== V3_PROJECTION_VERSION) {
        throw new Error('电脑 V3 Device API 版本与 Phone 投影不兼容');
      }
      const pending = await this.repository.pendingOperations(500);
      const operations = requestOperations(pending);
      let cursor = await this.repository.currentCursor();
      let hasMore = true;
      let batches = 0;
      while (hasMore) {
        if (batches >= 100) {
          throw new Error('V3 增量同步批次过多，请稍后重试');
        }
        const request: DeviceV3SyncRequest = {
          projection_version: V3_PROJECTION_VERSION,
          cursor: cursor === 'cursor-0' ? null : cursor,
          client_operations: batches === 0 ? operations : [],
          pull_limit: 500
        };
        const response = await this.client.sync(request);
        await applySyncResponse(this.repository, response);
        cursor = response.next_cursor;
        hasMore = response.has_more;
        batches += 1;
      }
      return {
        batches: batches,
        submitted_operations: operations.length,
        final_cursor: cursor
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : JSON.stringify(error);
      await this.repository.markSyncFailure(message);
      throw new Error(message);
    }
  }
}

export function retryDelayMs(attemptCount: number): number {
  const normalized = Math.max(0, Math.min(10, Math.floor(attemptCount)));
  return Math.min(300000, 1000 * Math.pow(2, normalized));
}

function requestOperations(pending: Array<PhonePendingOperation>): Array<DeviceV3ClientOperation> {
  const operations: Array<DeviceV3ClientOperation> = [];
  for (let index = 0; index < pending.length; index += 1) {
    operations.push({
      operation_id: pending[index].operation_id,
      kind: pending[index].kind,
      base_revision: pending[index].base_revision,
      payload: pending[index].payload
    });
  }
  return operations;
}
