import { fileIo } from '@kit.CoreFileKit';
import { RecordingFile } from '../../models/RecordingModels';
import {
  JSON_LOAD_DAMAGED,
  JSON_LOAD_MISSING,
  JSON_LOAD_SUCCESS,
  loadVersionedJson,
  writeVersionedJson
} from '../../shared/io/AtomicJsonStore';

export const AUTOMATIC_QUEUE_MANIFEST_VERSION: number = 1;
export const AUTOMATIC_QUEUE_MANIFEST_FILE: string = 'automatic_sync_queue_v1.json';
export const AUTOMATIC_QUEUE_RESTORED: string = 'restored';
export const AUTOMATIC_QUEUE_MISSING: string = 'missing';
export const AUTOMATIC_QUEUE_DAMAGED: string = 'damaged';
export const AUTOMATIC_QUEUE_INVALID: string = 'invalid';
export const AUTOMATIC_QUEUE_ENQUEUED: string = 'enqueued';
export const AUTOMATIC_QUEUE_ENQUEUED_NOT_SAVED: string = 'enqueued_not_saved';
export const AUTOMATIC_QUEUE_DUPLICATE: string = 'duplicate';
export const AUTOMATIC_QUEUE_REJECTED: string = 'rejected';

const MAX_RECORDING_BYTES: number = 10 * 1024 * 1024;

export interface AutomaticSyncQueueEntry extends RecordingFile {
  relativePath: string;
}

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

export interface AutomaticSyncQueueFileInfo {
  size: number;
  isFile: boolean;
}

export interface AutomaticSyncQueueFileSystem {
  exists(path: string): boolean;
  readText(path: string): string;
  writeText(path: string, content: string): void;
  stat(path: string): AutomaticSyncQueueFileInfo;
}

export interface AutomaticSyncQueueClock {
  now(): number;
}

class SystemAutomaticSyncQueueFileSystem implements AutomaticSyncQueueFileSystem {
  exists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (error) {
      throw queueFileError(error);
    }
  }

  readText(path: string): string {
    try {
      return fileIo.readTextSync(path);
    } catch (error) {
      throw queueFileError(error);
    }
  }

  writeText(path: string, content: string): void {
    // AtomicJsonStore owns the durable write when this method is selected below.
    throw new Error(`不应直接写入自动队列清单：${path}（${content.length} 字节）`);
  }

  stat(path: string): AutomaticSyncQueueFileInfo {
    try {
      const result = fileIo.statSync(path);
      return {
        size: result.size,
        isFile: result.isFile()
      };
    } catch (error) {
      throw queueFileError(error);
    }
  }
}

function queueFileError(error: Object): Error {
  return error instanceof Error ? error : new Error(JSON.stringify(error));
}

class SystemAutomaticSyncQueueClock implements AutomaticSyncQueueClock {
  now(): number {
    return Date.now();
  }
}

function isAutomaticQueueManifest(manifest: AutomaticQueueManifest): boolean {
  if (manifest === null || typeof manifest !== 'object' || Array.isArray(manifest) ||
    typeof manifest.version !== 'number' || manifest.version !== AUTOMATIC_QUEUE_MANIFEST_VERSION ||
    typeof manifest.updatedAt !== 'number' || !Number.isFinite(manifest.updatedAt) || manifest.updatedAt < 0 ||
    typeof manifest.completedCount !== 'number' || !Number.isFinite(manifest.completedCount) ||
    manifest.completedCount < 0 || Math.floor(manifest.completedCount) !== manifest.completedCount ||
    !Array.isArray(manifest.files)) {
    return false;
  }
  for (let index = 0; index < manifest.files.length; index += 1) {
    if (!isAutomaticQueueManifestEntry(manifest.files[index])) {
      return false;
    }
  }
  return true;
}

function isAutomaticQueueManifestEntry(entry: AutomaticQueueManifestEntry): boolean {
  if (entry === null || typeof entry !== 'object' || Array.isArray(entry) ||
    typeof entry.relativePath !== 'string' || entry.relativePath.trim().length === 0 ||
    typeof entry.fileName !== 'string' || entry.fileName.trim().length === 0 ||
    typeof entry.size !== 'number' || !Number.isFinite(entry.size) ||
    entry.size <= 0 || entry.size > MAX_RECORDING_BYTES ||
    typeof entry.durationMs !== 'number' || !Number.isFinite(entry.durationMs) || entry.durationMs < 0) {
    return false;
  }
  if (entry.relativePath.startsWith('/') || entry.relativePath.includes('..')) {
    return false;
  }
  return isSupportedAudioFile(entry.relativePath) && isSupportedAudioFile(entry.fileName);
}

function isSupportedAudioFile(path: string): boolean {
  const lowerPath = path.toLowerCase();
  return (lowerPath.endsWith('.wav') || lowerPath.endsWith('.m4a')) && !lowerPath.endsWith('.part');
}

export class AutomaticSyncQueue {
  private filesDirectory: string;
  private manifestPath: string;
  private fileSystem: AutomaticSyncQueueFileSystem;
  private clock: AutomaticSyncQueueClock;
  private usesSystemFileSystem: boolean;
  private entries: Array<AutomaticSyncQueueEntry> = [];
  private loaded: boolean = false;
  private completed: number = 0;
  private automaticRequestId: string;

  constructor(filesDirectory: string, fileSystem?: AutomaticSyncQueueFileSystem,
    clock?: AutomaticSyncQueueClock) {
    this.filesDirectory = filesDirectory;
    this.manifestPath = `${filesDirectory}/${AUTOMATIC_QUEUE_MANIFEST_FILE}`;
    this.usesSystemFileSystem = fileSystem === undefined;
    this.fileSystem = fileSystem !== undefined ? fileSystem : new SystemAutomaticSyncQueueFileSystem();
    this.clock = clock !== undefined ? clock : new SystemAutomaticSyncQueueClock();
    this.automaticRequestId = `auto_${this.clock.now()}`;
  }

  restore(): string {
    if (this.loaded) {
      return AUTOMATIC_QUEUE_RESTORED;
    }
    this.loaded = true;
    const loaded = loadVersionedJson<AutomaticQueueManifest>(this.manifestPath,
      AUTOMATIC_QUEUE_MANIFEST_VERSION, isAutomaticQueueManifest,
      (path: string): boolean => this.fileSystem.exists(path),
      (path: string): string => this.fileSystem.readText(path));
    if (loaded.status === JSON_LOAD_MISSING) {
      return AUTOMATIC_QUEUE_MISSING;
    }
    if (loaded.status !== JSON_LOAD_SUCCESS || loaded.value === undefined) {
      return loaded.status === JSON_LOAD_DAMAGED ? AUTOMATIC_QUEUE_DAMAGED : AUTOMATIC_QUEUE_INVALID;
    }
    const manifest = loaded.value;
    this.completed = manifest.completedCount;
    for (let index = 0; index < manifest.files.length; index += 1) {
      const entry = manifest.files[index];
      if (!this.isSafeEntry(entry)) {
        continue;
      }
      const path = `${this.filesDirectory}/${entry.relativePath}`;
      if (!this.fileSystem.exists(path)) {
        continue;
      }
      const stat = this.fileSystem.stat(path);
      if (!stat.isFile || stat.size !== entry.size) {
        continue;
      }
      this.entries.push({
        fileName: entry.fileName,
        path: path,
        relativePath: entry.relativePath,
        size: entry.size,
        durationMs: entry.durationMs || 0
      });
    }
    if (this.entries.length !== manifest.files.length) {
      this.persist();
    }
    return AUTOMATIC_QUEUE_RESTORED;
  }

  enqueue(recording: RecordingFile): string {
    if (!this.isSyncableRecording(recording)) {
      return AUTOMATIC_QUEUE_REJECTED;
    }
    for (let index = 0; index < this.entries.length; index += 1) {
      if (this.entries[index].path === recording.path) {
        return AUTOMATIC_QUEUE_DUPLICATE;
      }
    }
    const prefix = `${this.filesDirectory}/`;
    this.entries.push({
      fileName: recording.fileName,
      path: recording.path,
      relativePath: recording.path.startsWith(prefix) ?
        recording.path.substring(prefix.length) : recording.fileName,
      size: recording.size,
      durationMs: recording.durationMs
    });
    return this.persist() ? AUTOMATIC_QUEUE_ENQUEUED : AUTOMATIC_QUEUE_ENQUEUED_NOT_SAVED;
  }

  first(): AutomaticSyncQueueEntry | undefined {
    return this.entries.length > 0 ? this.entries[0] : undefined;
  }

  count(): number {
    return this.entries.length;
  }

  completedCount(): number {
    return this.completed;
  }

  requestId(): string {
    return this.automaticRequestId;
  }

  complete(path: string): boolean {
    for (let index = 0; index < this.entries.length; index += 1) {
      if (this.entries[index].path === path) {
        this.entries.splice(index, 1);
        this.completed += 1;
        return this.persist();
      }
    }
    return false;
  }

  removeIfQueued(path: string): boolean {
    let removedCount = 0;
    for (let index = this.entries.length - 1; index >= 0; index -= 1) {
      if (this.entries[index].path === path) {
        this.entries.splice(index, 1);
        removedCount += 1;
      }
    }
    if (removedCount === 0) {
      return false;
    }
    this.completed += removedCount;
    return this.persist();
  }

  removeAllIfQueued(paths: Array<string>): number {
    if (paths.length === 0) {
      return 0;
    }
    let removedCount = 0;
    for (let index = this.entries.length - 1; index >= 0; index -= 1) {
      if (paths.indexOf(this.entries[index].path) >= 0) {
        this.entries.splice(index, 1);
        removedCount += 1;
      }
    }
    if (removedCount === 0) {
      return 0;
    }
    this.completed += removedCount;
    this.persist();
    return removedCount;
  }

  persist(): boolean {
    const files: Array<AutomaticQueueManifestEntry> = [];
    for (let index = 0; index < this.entries.length; index += 1) {
      const entry = this.entries[index];
      files.push({
        relativePath: entry.relativePath,
        fileName: entry.fileName,
        size: entry.size,
        durationMs: entry.durationMs
      });
    }
    const manifest: AutomaticQueueManifest = {
      version: AUTOMATIC_QUEUE_MANIFEST_VERSION,
      updatedAt: this.clock.now(),
      completedCount: this.completed,
      files: files
    };
    try {
      if (this.usesSystemFileSystem) {
        writeVersionedJson<AutomaticQueueManifest>(this.manifestPath, AUTOMATIC_QUEUE_MANIFEST_VERSION,
          manifest, isAutomaticQueueManifest);
      } else {
        writeVersionedJson<AutomaticQueueManifest>(this.manifestPath, AUTOMATIC_QUEUE_MANIFEST_VERSION,
          manifest, isAutomaticQueueManifest,
          (path: string, content: string): void => this.fileSystem.writeText(path, content));
      }
      return true;
    } catch (error) {
      return false;
    }
  }

  private isSafeEntry(entry: AutomaticQueueManifestEntry): boolean {
    return isAutomaticQueueManifestEntry(entry);
  }

  private isSyncableRecording(recording: RecordingFile): boolean {
    return !recording.path.endsWith('.part') && recording.size > 0 && recording.size <= MAX_RECORDING_BYTES;
  }
}
