import { RecordingFile, WatchSyncFileDescriptor } from '../../main/ets/models/RecordingModels';

const MAX_RECORDING_BYTES: number = 10 * 1024 * 1024;
const AUTOMATIC_QUEUE_MANIFEST_VERSION: number = 1;

interface AutomaticQueueManifestEntry {
  relativePath: string;
  fileName: string;
  size: number;
  durationMs: number;
}

interface AutomaticQueueManifest {
  version: number;
  updatedAt: number;
  completedCount: number;
  files: Array<AutomaticQueueManifestEntry>;
}

export interface CharacterizedAutomaticQueueEntry extends RecordingFile {
  relativePath: string;
}

export interface CharacterizedQueueRestoreResult {
  status: string;
  completedCount: number;
  files: Array<CharacterizedAutomaticQueueEntry>;
}

export class AutomaticQueueCharacterization {
  static restore(filesDirectory: string, manifestText: string,
    existingFileSizes: Map<string, number>): CharacterizedQueueRestoreResult {
    const result: CharacterizedQueueRestoreResult = {
      status: 'restored',
      completedCount: 0,
      files: []
    };
    try {
      const manifest = JSON.parse(manifestText) as AutomaticQueueManifest;
      if (manifest.version !== AUTOMATIC_QUEUE_MANIFEST_VERSION || !Array.isArray(manifest.files)) {
        result.status = 'invalid_version';
        return result;
      }
      result.completedCount = Math.max(0, Math.floor(manifest.completedCount || 0));
      for (let index = 0; index < manifest.files.length; index += 1) {
        const entry = manifest.files[index];
        if (entry.relativePath.length === 0 || entry.relativePath.startsWith('/') ||
          entry.relativePath.includes('..')) {
          continue;
        }
        const size = existingFileSizes.get(entry.relativePath);
        const lowerName = entry.fileName.toLowerCase();
        if (size === undefined || size <= 0 || size > MAX_RECORDING_BYTES || size !== entry.size ||
          (!lowerName.endsWith('.wav') && !lowerName.endsWith('.m4a')) || lowerName.endsWith('.part')) {
          continue;
        }
        result.files.push({
          fileName: entry.fileName,
          path: `${filesDirectory}/${entry.relativePath}`,
          relativePath: entry.relativePath,
          size: entry.size,
          durationMs: entry.durationMs || 0
        });
      }
      return result;
    } catch (error) {
      result.status = 'damaged_json';
      result.files = [];
      return result;
    }
  }

  static enqueue(filesDirectory: string, queue: Array<CharacterizedAutomaticQueueEntry>,
    recording: RecordingFile): boolean {
    if (recording.path.endsWith('.part') || recording.size <= 0 || recording.size > MAX_RECORDING_BYTES) {
      return false;
    }
    for (let index = 0; index < queue.length; index += 1) {
      if (queue[index].path === recording.path) {
        return false;
      }
    }
    const prefix = `${filesDirectory}/`;
    queue.push({
      fileName: recording.fileName,
      path: recording.path,
      relativePath: recording.path.startsWith(prefix) ?
        recording.path.substring(prefix.length) : recording.fileName,
      size: recording.size,
      durationMs: recording.durationMs
    });
    return true;
  }
}

function fileTransferAckKey(descriptor: WatchSyncFileDescriptor): string {
  return `${descriptor.requestId}\n${descriptor.index}\n${descriptor.relativePath}`;
}

export class FileTransferAckCharacterization {
  activeKey: string = '';
  lastProgress: number = -1;
  waitingForDurableAck: boolean = false;
  progressTimeoutActive: boolean = false;
  ackTimeoutActive: boolean = false;

  begin(descriptor: WatchSyncFileDescriptor): void {
    this.activeKey = fileTransferAckKey(descriptor);
    this.lastProgress = -1;
    this.waitingForDurableAck = false;
    this.progressTimeoutActive = true;
    this.ackTimeoutActive = false;
  }

  progress(descriptor: WatchSyncFileDescriptor, progress: number): boolean {
    if (fileTransferAckKey(descriptor) !== this.activeKey) {
      return false;
    }
    const bounded = Math.max(0, Math.min(100, Math.floor(progress)));
    if (bounded < this.lastProgress) {
      return false;
    }
    this.lastProgress = bounded;
    if (bounded >= 100) {
      this.waitingForDurableAck = true;
      this.progressTimeoutActive = false;
      this.ackTimeoutActive = true;
    }
    return true;
  }

  acknowledge(descriptor: WatchSyncFileDescriptor): boolean {
    if (fileTransferAckKey(descriptor) !== this.activeKey || this.activeKey.length === 0) {
      return false;
    }
    this.clear();
    return true;
  }

  expire(timerKey: string): boolean {
    if (timerKey !== this.activeKey || this.activeKey.length === 0) {
      return false;
    }
    this.clear();
    return true;
  }

  clear(): void {
    this.activeKey = '';
    this.lastProgress = -1;
    this.waitingForDurableAck = false;
    this.progressTimeoutActive = false;
    this.ackTimeoutActive = false;
  }
}

export class ReceiverRequestCharacterization {
  activeRequestId: string = '';
  completedDescriptorKeys: Set<string> = new Set<string>();

  begin(requestId: string): void {
    this.activeRequestId = requestId;
  }

  accepts(requestId: string, automatic: boolean): boolean {
    return automatic || requestId === this.activeRequestId;
  }

  markReceived(descriptor: WatchSyncFileDescriptor): boolean {
    const key = fileTransferAckKey(descriptor);
    if (this.completedDescriptorKeys.has(key)) {
      return false;
    }
    this.completedDescriptorKeys.add(key);
    return true;
  }

  timeout(requestId: string): boolean {
    if (requestId !== this.activeRequestId || this.activeRequestId.length === 0) {
      return false;
    }
    this.activeRequestId = '';
    return true;
  }

  stop(): void {
    this.activeRequestId = '';
    this.completedDescriptorKeys.clear();
  }
}
