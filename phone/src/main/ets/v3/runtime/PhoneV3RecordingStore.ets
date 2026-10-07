import { fileIo } from '@kit.CoreFileKit';
import {
  JSON_LOAD_SUCCESS,
  JsonTextReadOperation,
  JsonTextWriteOperation,
  ReceivedRecordingFile,
  WatchSyncFileDescriptor,
  exactWatchFileKey,
  loadVersionedJson,
  writeVersionedJson
} from 'common';

export const SYNC_RECEIVE_DIRECTORY: string = 'synced_from_watch';
const MANIFEST_FILE_NAME: string = 'received_index_v1.json';
const MANIFEST_VERSION: number = 1;
const RECEIPT_VERSION: number = 2;
const RECEIPT_SUFFIX: string = '.receipt.json';

interface ReceivedRecordingManifestEntry {
  fileName: string;
  localPath: string;
  size: number;
  durationMs: number;
  requestId: string;
  sourcePath: string;
  receivedAt: number;
  syncKey?: string;
}

interface ReceivedRecordingManifest {
  version: number;
  updatedAt: number;
  recordings: Array<ReceivedRecordingManifestEntry>;
}

interface RecordingReceipt {
  version: number;
  recordingId: string;
  sessionKey: string;
  fileName: string;
  size: number;
  durationMs: number;
  requestId: string;
  sourcePath: string;
  receivedAt: number;
  syncKey: string;
  sha256: string;
  verified: boolean;
}

export type DirectoryListOperation = (path: string) => Array<string>;
export type TextReadOperation = JsonTextReadOperation;
export type TextWriteOperation = JsonTextWriteOperation;

function isReceivedRecordingManifest(manifest: ReceivedRecordingManifest): boolean {
  return Array.isArray(manifest.recordings);
}

function isRecordingReceipt(receipt: RecordingReceipt): boolean {
  return receipt.verified === true && receipt.size > 0 &&
    receipt.requestId.length > 0 && receipt.sourcePath.length > 0 &&
    receipt.sourcePath.lastIndexOf('/') > 0 &&
    receipt.sessionKey === receipt.sourcePath.substring(0, receipt.sourcePath.lastIndexOf('/')) &&
    receipt.recordingId === exactWatchFileKey(receipt.sourcePath, receipt.size) &&
    receipt.syncKey === exactWatchFileKey(receipt.sourcePath, receipt.size) &&
    /^[0-9a-f]{64}$/.test(receipt.sha256);
}

export class PhoneV3RecordingStore {
  private static sharedStores: Map<string, PhoneV3RecordingStore> = new Map<string, PhoneV3RecordingStore>();
  static shared(filesDirectory: string): PhoneV3RecordingStore {
    let store = PhoneV3RecordingStore.sharedStores.get(filesDirectory);
    if (store === undefined) {
      store = new PhoneV3RecordingStore(filesDirectory);
      PhoneV3RecordingStore.sharedStores.set(filesDirectory, store);
    }
    return store;
  }
  private filesDirectory: string;
  private syncRoot: string;
  private manifestPath: string;
  private recordings: Array<ReceivedRecordingFile>;
  private listDirectory: DirectoryListOperation;
  private readText: TextReadOperation;
  private writeText: TextWriteOperation | undefined;

  constructor(filesDirectory: string,
    listDirectory: DirectoryListOperation = (path: string): Array<string> => fileIo.listFileSync(path),
    readText: TextReadOperation = (path: string): string => fileIo.readTextSync(path),
    writeText?: TextWriteOperation) {
    this.filesDirectory = filesDirectory;
    this.syncRoot = `${filesDirectory}/${SYNC_RECEIVE_DIRECTORY}`;
    this.manifestPath = `${this.syncRoot}/${MANIFEST_FILE_NAME}`;
    this.listDirectory = listDirectory;
    this.readText = readText;
    this.writeText = writeText;
    this.recordings = this.loadFromDisk();
  }

  list(): Array<ReceivedRecordingFile> {
    return this.recordings.slice();
  }

  knownFileKeys(): Array<string> {
    const keys: Array<string> = [];
    for (let index = 0; index < this.recordings.length; index += 1) {
      const recording = this.recordings[index];
      if (recording.verified === true && recording.syncKey !== undefined && keys.indexOf(recording.syncKey) < 0) {
        keys.push(recording.syncKey);
      }
    }
    return keys;
  }

  findExact(descriptor: WatchSyncFileDescriptor): ReceivedRecordingFile | undefined {
    const key = exactWatchFileKey(descriptor.relativePath, descriptor.size);
    for (let index = 0; index < this.recordings.length; index += 1) {
      const recording = this.recordings[index];
      if (recording.verified === true && (recording.syncKey === key ||
        (recording.sourcePath === descriptor.relativePath && recording.size === descriptor.size))) {
        return recording;
      }
    }
    return undefined;
  }

  findExisting(descriptor: WatchSyncFileDescriptor): ReceivedRecordingFile | undefined {
    // One-minute segments intentionally reuse the same file name and size in each
    // recording session. Only the watch source path plus size can safely identify
    // a retry; a name-size-only match could discard a different session's audio.
    return this.findExact(descriptor);
  }

  findWifiExisting(sourcePath: string, size: number): ReceivedRecordingFile | undefined {
    const key = exactWatchFileKey(sourcePath, size);
    for (let index = 0; index < this.recordings.length; index += 1) {
      const recording = this.recordings[index];
      if (recording.verified === true &&
        (recording.syncKey === key || (recording.sourcePath === sourcePath && recording.size === size))) {
        return recording;
      }
    }
    return undefined;
  }

  record(recording: ReceivedRecordingFile, sha256: string): ReceivedRecordingFile {
    this.writeReceipt(recording, sha256);
    const durable = durableRecording(recording, sha256);
    for (let index = 0; index < this.recordings.length; index += 1) {
      const existing = this.recordings[index];
      if ((recording.syncKey !== undefined && existing.syncKey === recording.syncKey) ||
        existing.path === recording.path) {
        this.recordings[index] = durable;
        this.sortNewestFirst();
        this.tryWriteManifest();
        return durable;
      }
    }
    this.recordings.push(durable);
    this.sortNewestFirst();
    this.tryWriteManifest();
    return durable;
  }

  recordVerified(recording: ReceivedRecordingFile, sha256: string): ReceivedRecordingFile {
    if (recording.syncKey === undefined) {
      return this.record(recording, sha256);
    }
    for (let index = 0; index < this.recordings.length; index += 1) {
      const existing = this.recordings[index];
      if (existing.syncKey !== recording.syncKey &&
        (existing.sourcePath !== recording.sourcePath || existing.size !== recording.size)) {
        continue;
      }
      if (existing.path === recording.path) {
        return this.record(recording, sha256);
      }
      this.writeReceipt(recording, sha256);
      const durable = durableRecording(recording, sha256);
      this.recordings[index] = durable;
      this.sortNewestFirst();
      this.tryWriteManifest();
      return durable;
    }
    return this.record(recording, sha256);
  }

  deleteRecordings(recordings: Array<ReceivedRecordingFile>): number {
    let deletedCount = 0;
    for (let targetIndex = 0; targetIndex < recordings.length; targetIndex += 1) {
      const targetPath = recordings[targetIndex].path;
      const storedIndex = this.findPathIndex(targetPath);
      if (storedIndex < 0) {
        continue;
      }
      try {
        if (fileIo.accessSync(targetPath)) {
          fileIo.unlinkSync(targetPath);
        }
        const receiptPath = `${targetPath}${RECEIPT_SUFFIX}`;
        if (fileIo.accessSync(receiptPath)) {
          fileIo.unlinkSync(receiptPath);
        }
      } catch (error) {
        this.tryWriteManifest();
        throw receivedStoreError(error);
      }
      this.recordings.splice(storedIndex, 1);
      deletedCount += 1;
    }
    this.tryWriteManifest();
    return deletedCount;
  }

  private loadFromDisk(): Array<ReceivedRecordingFile> {
    const loaded: Array<ReceivedRecordingFile> = [];
    this.loadManifest(loaded);
    const indexedCount = loaded.length;
    // Recover files copied just before a manifest write failed. The shared
    // store runs this scan once per process, not on each ordinary refresh.
    this.scanExistingSyncFiles(loaded);
    this.recordings = loaded;
    this.sortNewestFirst();
    if (loaded.length > indexedCount) {
      try {
        this.writeManifest();
      } catch (error) {
        // A directory scan can still restore the visible list without rewriting the index.
      }
    }
    return loaded;
  }

  private writeReceipt(recording: ReceivedRecordingFile, sha256: string): void {
    const stat = fileIo.statSync(recording.path);
    if (!stat.isFile() || stat.size !== recording.size ||
      !/^[0-9a-f]{64}$/.test(sha256)) {
      throw new Error('录音文件大小或 SHA-256 无效，不能确认接收');
    }
    const receipt: RecordingReceipt = {
      version: RECEIPT_VERSION,
      recordingId: exactWatchFileKey(recording.sourcePath, recording.size),
      sessionKey: recording.sourcePath.substring(0, recording.sourcePath.lastIndexOf('/')),
      fileName: recording.fileName,
      size: recording.size,
      durationMs: recording.durationMs,
      requestId: recording.requestId,
      sourcePath: recording.sourcePath,
      receivedAt: recording.receivedAt,
      syncKey: exactWatchFileKey(recording.sourcePath, recording.size),
      sha256: sha256,
      verified: true
    };
    const path = `${recording.path}${RECEIPT_SUFFIX}`;
    if (this.writeText === undefined) {
      writeVersionedJson<RecordingReceipt>(path, RECEIPT_VERSION, receipt, isRecordingReceipt);
    } else {
      writeVersionedJson<RecordingReceipt>(path, RECEIPT_VERSION, receipt, isRecordingReceipt, this.writeText);
    }
  }

  private loadReceipt(path: string, size: number): ReceivedRecordingFile | undefined {
    const loaded = loadVersionedJson<RecordingReceipt>(`${path}${RECEIPT_SUFFIX}`, RECEIPT_VERSION,
      isRecordingReceipt, (candidate: string): boolean => fileIo.accessSync(candidate), this.readText);
    if (loaded.status !== JSON_LOAD_SUCCESS || loaded.value === undefined || loaded.value.size !== size) {
      return undefined;
    }
    const receipt = loaded.value;
    return {
      fileName: receipt.fileName, path: path, size: receipt.size, durationMs: receipt.durationMs,
      requestId: receipt.requestId, sourcePath: receipt.sourcePath,
      receivedAt: receipt.receivedAt, syncKey: receipt.syncKey,
      sha256: receipt.sha256, verified: true
    };
  }

  private loadManifest(target: Array<ReceivedRecordingFile>): void {
    const loaded = loadVersionedJson<ReceivedRecordingManifest>(this.manifestPath, MANIFEST_VERSION,
      isReceivedRecordingManifest, (path: string): boolean => fileIo.accessSync(path), this.readText);
    if (loaded.status !== JSON_LOAD_SUCCESS || loaded.value === undefined) {
      return;
    }
    try {
      const manifest = loaded.value;
      for (let index = 0; index < manifest.recordings.length; index += 1) {
        const entry = manifest.recordings[index];
        if (!entry.localPath.startsWith(`${SYNC_RECEIVE_DIRECTORY}/`) ||
          entry.localPath.startsWith('/') || entry.localPath.includes('..')) {
          continue;
        }
        const path = `${this.filesDirectory}/${entry.localPath}`;
        if (!fileIo.accessSync(path)) {
          continue;
        }
        const stat = fileIo.statSync(path);
        if (!stat.isFile() || stat.size <= 0 || stat.size !== entry.size) {
          continue;
        }
        const receipt = this.loadReceipt(path, stat.size);
        target.push(receipt ?? {
          fileName: entry.fileName,
          path: path,
          size: entry.size,
          durationMs: entry.durationMs,
          requestId: entry.requestId,
          sourcePath: entry.sourcePath,
          receivedAt: entry.receivedAt,
          syncKey: entry.syncKey
        });
      }
    } catch (error) {
      // The audio files remain authoritative; the directory scan below rebuilds a damaged index.
    }
  }

  private scanExistingSyncFiles(target: Array<ReceivedRecordingFile>): void {
    try {
      if (!fileIo.accessSync(this.syncRoot)) {
        return;
      }
      this.scanSyncDirectory(this.syncRoot, '', target);
    } catch (error) {
      throw receivedStoreError(error);
    }
  }

  private scanSyncDirectory(directory: string, relativeDirectory: string,
    target: Array<ReceivedRecordingFile>): void {
    try {
      const entries = this.listDirectory(directory);
      for (let index = 0; index < entries.length; index += 1) {
        const name = entries[index];
        if (name === MANIFEST_FILE_NAME) {
          continue;
        }
        const path = `${directory}/${name}`;
        const relativePath = relativeDirectory.length > 0 ? `${relativeDirectory}/${name}` : name;
        const stat = fileIo.statSync(path);
        if (stat.isDirectory()) {
          this.scanSyncDirectory(path, relativePath, target);
          continue;
        }
        if (!this.isAudioFile(name) || stat.size <= 0 || this.containsPath(target, path)) {
          continue;
        }
        const receipt = this.loadReceipt(path, stat.size);
        if (receipt !== undefined) {
          const previous = target.findIndex((item: ReceivedRecordingFile): boolean =>
            item.syncKey === receipt.syncKey && item.verified === true);
          if (previous >= 0) {
            if (target[previous].receivedAt < receipt.receivedAt) {
              target[previous] = receipt;
            }
          } else {
            target.push(receipt);
          }
          continue;
        }
        // Unverified audio without a durable receipt has no trustworthy
        // session/source identity. Keep it on disk for repair, not in the
        // acknowledged recording set or Computer manifest.
      }
    } catch (error) {
      throw receivedStoreError(error);
    }
  }

  private writeManifest(): void {
    try {
      if (!fileIo.accessSync(this.syncRoot)) {
        fileIo.mkdirSync(this.syncRoot);
      }
      const entries: Array<ReceivedRecordingManifestEntry> = [];
      const prefix = `${this.filesDirectory}/`;
      for (let index = 0; index < this.recordings.length; index += 1) {
        const recording = this.recordings[index];
        if (!recording.path.startsWith(prefix)) {
          continue;
        }
        entries.push({
          fileName: recording.fileName,
          localPath: recording.path.substring(prefix.length),
          size: recording.size,
          durationMs: recording.durationMs,
          requestId: recording.requestId,
          sourcePath: recording.sourcePath,
          receivedAt: recording.receivedAt,
          syncKey: recording.syncKey
        });
      }
      const manifest: ReceivedRecordingManifest = {
        version: MANIFEST_VERSION,
        updatedAt: Date.now(),
        recordings: entries
      };
      if (this.writeText === undefined) {
        writeVersionedJson<ReceivedRecordingManifest>(this.manifestPath, MANIFEST_VERSION,
          manifest, isReceivedRecordingManifest);
      } else {
        writeVersionedJson<ReceivedRecordingManifest>(this.manifestPath, MANIFEST_VERSION,
          manifest, isReceivedRecordingManifest, this.writeText);
      }
    } catch (error) {
      throw receivedStoreError(error);
    }
  }

  private tryWriteManifest(): void {
    try {
      this.writeManifest();
    } catch (error) {
      // Deleted audio cannot be restored. A later launch safely drops missing
      // manifest entries and rebuilds the index from the remaining files.
    }
  }

  private sortNewestFirst(): void {
    this.recordings.sort((left: ReceivedRecordingFile, right: ReceivedRecordingFile) =>
      right.receivedAt - left.receivedAt);
  }

  private containsPath(recordings: Array<ReceivedRecordingFile>, path: string): boolean {
    for (let index = 0; index < recordings.length; index += 1) {
      if (recordings[index].path === path) {
        return true;
      }
    }
    return false;
  }

  private findPathIndex(path: string): number {
    for (let index = 0; index < this.recordings.length; index += 1) {
      if (this.recordings[index].path === path) {
        return index;
      }
    }
    return -1;
  }

  private isAudioFile(fileName: string): boolean {
    const lowerName = fileName.toLowerCase();
    return lowerName.endsWith('.wav') || lowerName.endsWith('.m4a') ||
      fileName === 'session_summary.json' || /^[0-9]+_session_summary\.json$/.test(fileName);
  }
}

function receivedStoreError(error: Object): Error {
  return error instanceof Error ? error : new Error(JSON.stringify(error));
}

function durableRecording(recording: ReceivedRecordingFile, sha256: string): ReceivedRecordingFile {
  return {
    fileName: recording.fileName, path: recording.path, size: recording.size,
    durationMs: recording.durationMs, requestId: recording.requestId,
    sourcePath: recording.sourcePath, receivedAt: recording.receivedAt,
    syncKey: exactWatchFileKey(recording.sourcePath, recording.size),
    sha256: sha256, verified: true
  };
}
