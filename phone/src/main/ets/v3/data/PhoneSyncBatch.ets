import { DeviceV3ClientOperation, DeviceV3SyncRequest } from '../../computer/ComputerTransferProtocol';
import { V3_PROJECTION_VERSION } from '../contracts/V3ContractModels';

// Must match the receiver JSON body limit, including the envelope and UTF-8 text.
export const PHONE_SYNC_BODY_BYTES: number = 64 * 1024;
// Each annotation writes facts and invalidates derived data. Bound transaction
// duration as well as bytes so a large outbox cannot starve other requests.
export const PHONE_SYNC_MAX_OPERATIONS: number = 32;

export function syncRequestBatch(cursor: string,
  candidates: Array<DeviceV3ClientOperation>): DeviceV3SyncRequest {
  const request: DeviceV3SyncRequest = {
    projection_version: V3_PROJECTION_VERSION,
    cursor: cursor === 'cursor-0' ? null : cursor,
    client_operations: [],
    pull_limit: 500
  };
  let bytes = jsonBytes(JSON.stringify(request));
  for (let index = 0; index < Math.min(PHONE_SYNC_MAX_OPERATIONS, candidates.length); index += 1) {
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

function jsonBytes(value: string): number {
  // JSON.stringify escapes lone surrogates, so URI encoding is defined here.
  return encodeURIComponent(value).replace(/%[0-9A-F]{2}/g, '_').length;
}
