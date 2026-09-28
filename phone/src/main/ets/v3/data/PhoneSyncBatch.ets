import { DeviceV3ClientOperation, DeviceV3SyncRequest } from '../../computer/ComputerTransferProtocol';
import { V3_PROJECTION_VERSION } from '../contracts/V3ContractModels';

// Must match the receiver JSON body limit, including the envelope and UTF-8 text.
export const PHONE_SYNC_BODY_BYTES: number = 64 * 1024;
// Each annotation writes facts and invalidates derived data. Bound transaction
// duration as well as bytes so a large outbox cannot starve other requests.
export const PHONE_SYNC_MAX_OPERATIONS: number = 32;

export function syncRequestBatch(cursor: string,
  candidates: Array<DeviceV3ClientOperation>, maxOperations: number = PHONE_SYNC_MAX_OPERATIONS,
  pullLimit: number = 500, pullBytes?: number, bootstrap: boolean = false): DeviceV3SyncRequest {
  const request: DeviceV3SyncRequest = {
    projection_version: V3_PROJECTION_VERSION,
    cursor: cursor === 'cursor-0' ? null : cursor,
    client_operations: [],
    pull_limit: pullLimit
  };
  if (pullBytes !== undefined) { request.pull_bytes = pullBytes; }
  if (bootstrap && cursor === 'cursor-0') { request.bootstrap = true; }
  let bytes = jsonBytes(JSON.stringify(request));
  for (let index = 0; index < Math.min(maxOperations, candidates.length); index += 1) {
    const size = jsonBytes(JSON.stringify(candidates[index])) + (index === 0 ? 0 : 1);
    if (bytes + size > PHONE_SYNC_BODY_BYTES) {
      if (index === 0) {
        throw new Error('单条同步操作超过电脑 64 KB 限制，已保留原操作，请联系维护者处理；不会拆改或丢弃标注');
      }
      break;
    }
    request.client_operations.push(candidates[index]);
    bytes += size;
  }
  return request;
}

export function jsonBytes(value: string): number {
  // JSON.stringify escapes lone surrogates, so URI encoding is defined here.
  return encodeURIComponent(value).replace(/%[0-9A-F]{2}/g, '_').length;
}

export class PhoneSyncBatchPolicy {
  operations: number = 32;
  pullLimit: number = 500;
  pullBytes: number = 256 * 1024;

  observe(sent: number, requestBytes: number, serverMs: number | undefined,
    changes: number, responseBytes: number, commitMs: number): void {
    if (serverMs !== undefined && Number.isFinite(serverMs) && serverMs >= 0 && sent > 0) {
      if (serverMs > 150) { this.operations = Math.max(4, Math.floor(sent * Math.max(0.5, 150 / serverMs))); }
      else if (sent >= this.operations && serverMs < 75 && requestBytes < PHONE_SYNC_BODY_BYTES * 0.8) {
        this.operations = Math.min(128, this.operations + 8);
      }
    }
    if (changes > 0 && Number.isFinite(commitMs) && commitMs >= 0) {
      if (commitMs > 100) {
        const scale = Math.max(0.5, 100 / commitMs);
        this.pullLimit = Math.max(16, Math.floor(changes * scale));
        this.pullBytes = Math.max(16384, Math.floor(Math.min(this.pullBytes, responseBytes) * scale));
      } else if (commitMs < 50 && (changes >= this.pullLimit || responseBytes >= this.pullBytes * 0.8)) {
        this.pullLimit = Math.min(500, Math.ceil(this.pullLimit * 1.25));
        this.pullBytes = Math.min(1048576, Math.ceil(this.pullBytes * 1.25));
      }
    }
  }
}
