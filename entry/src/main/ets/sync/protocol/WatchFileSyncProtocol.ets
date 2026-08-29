import { util } from '@kit.ArkTS';
import { WatchSyncFileDescriptor } from '../../models/RecordingModels';

export const WATCH_SYNC_PROTOCOL_VERSION: number = 1;
export const WATCH_SYNC_INVENTORY_PAGE: string = 'sync_inventory_page';
export const WATCH_SYNC_REQUEST: string = 'sync_request';
export const WATCH_SYNC_READY: string = 'sync_ready';
export const WATCH_SYNC_QUEUED: string = 'sync_queued';
export const WATCH_SYNC_BEGIN: string = 'sync_begin';
export const WATCH_SYNC_FILE: string = 'sync_file';
export const WATCH_SYNC_FILE_PROGRESS: string = 'sync_file_progress';
export const WATCH_SYNC_FILE_RECEIVED: string = 'sync_file_received';
export const WATCH_SYNC_COMPLETE: string = 'sync_complete';
export const WATCH_SYNC_ERROR: string = 'sync_error';
export const WATCH_AUTO_FILE: string = 'auto_file';
export const WATCH_SYNC_FILE_FAILED: string = 'sync_file_failed';
export const WATCH_PHONE_READY: string = 'phone_ready';
export const WATCH_CONTROL_PROBE: string = 'control_probe';
export const WATCH_CONTROL_READY: string = 'control_ready';
export const WATCH_RECORDING_COMMAND: string = 'recording_command';
export const WATCH_RECORDING_ACK: string = 'recording_ack';

export interface WatchSyncProtocolMessage {
  version: number;
  type: string;
  requestId: string;
  total?: number;
  sent?: number;
  skipped?: number;
  alreadyReceived?: number;
  remaining?: number;
  scannedTotal?: number;
  inventoryPage?: number;
  inventoryPages?: number;
  knownFileKeys?: Array<string>;
  message?: string;
  file?: WatchSyncFileDescriptor;
  progress?: number;
  transferredBytes?: number;
  transferStage?: string;
  desiredState?: string;
  actualState?: string;
  success?: boolean;
  sessionId?: string;
  sentAt?: number;
}

function hashFileIdentity(value: string, seed: number): string {
  let hash = seed >>> 0;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    hash ^= code & 0xff;
    hash = Math.imul(hash, 0x01000193) >>> 0;
    hash ^= (code >>> 8) & 0xff;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(16).padStart(8, '0');
}

function compactFileIdentity(value: string): string {
  return `${hashFileIdentity(value, 0x811c9dc5)}${hashFileIdentity(value, 0x9e3779b9)}`;
}

export function exactWatchFileKey(relativePath: string, size: number): string {
  return `e${compactFileIdentity(`${relativePath}\n${size}`)}`;
}

export function legacyWatchFileKey(fileName: string, size: number): string {
  return `l${compactFileIdentity(`${fileName}\n${size}`)}`;
}

export function encodeWatchSyncMessage(message: WatchSyncProtocolMessage): Uint8Array {
  return util.TextEncoder.create('utf-8').encodeInto(JSON.stringify(message));
}

export function decodeWatchSyncMessage(content: Uint8Array): WatchSyncProtocolMessage {
  const text = util.TextDecoder.create('utf-8').decodeToString(content);
  const message = JSON.parse(text) as WatchSyncProtocolMessage;
  if (message.version !== WATCH_SYNC_PROTOCOL_VERSION || message.type.length === 0) {
    throw new Error('不支持的手表同步消息');
  }
  return message;
}
