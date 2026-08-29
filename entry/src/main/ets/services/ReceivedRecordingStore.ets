import { fileIo } from '@kit.CoreFileKit';
import { ReceivedRecordingFile, WatchSyncFileDescriptor } from '../models/RecordingModels';
import { exactWatchFileKey, legacyWatchFileKey } from './WatchFileSyncProtocol';

export const SYNC_RECEIVE_DIRECTORY: string = 'synced_from_watch';
const MANIFEST_FILE_NAME: string = 'received_index_v1.json';
const MANIFEST_VERSION: number = 1;

interface ReceivedRecordingManifestEntry {
  fileName: string;
  localPath: string;
  size: number;
  durationMs: number;
  requestId: string;
  sourcePath: string;
  receivedAt: number;
  syncKey?: string;
  legacySyncKey?: string;
}

interface ReceivedRecordingManifest {
  version: number;
  updatedAt: number;
  recordings: Array<ReceivedRecordingManifestEntry>;
}

export type DirectoryListOperation = (path: string) => Array<string>;
export type TextReadOperation = (path: string) => string;

export class ReceivedRecordingStore {
  private filesDirectory: string;
  private syncRoot: string;
  private manifestPath: string;
  private recordings: Array<ReceivedRecordingFile>;
  private listDirectory: DirectoryListOperation;
  private readText: TextReadOperation;

  constructor(filesDirectory: string,
    listDirectory: DirectoryListOperation = (path: string): Array<string> => fileIo.listFileSync(path),
    readText: TextReadOperation = (path: string): string => fileIo.readTextSync(path)) {
    this.filesDirectory = filesDirectory;
    this.syncRoot = `${filesDirectory}/${SYNC_RECEIVE_DIRECTORY}`;
    this.manifestPath = `${this.syncRoot}/${MANIFEST_FILE_NAME}`;
    this.listDirectory = listDirectory;
    this.readText = readText;
    this.recordings = this.loadFromDisk();
  }

  list(): Array<ReceivedRecordingFile> {
    return this.recordings.slice();
  }

  knownFileKeys(): Array<string> {
    const keys: Array<string> = [];
    for (let index = 0; index < this.recordings.length; index += 1) {
      const recording = this.recordings[index];
      if (recording.syncKey !== undefined && keys.indexOf(recording.syncKey) < 0) {
        keys.push(recording.syncKey);
      }
    }
    return keys;
  }

  findExact(descriptor: WatchSyncFileDescriptor): ReceivedRecordingFile | undefined {
    const key = exactWatchFileKey(descriptor.relativePath, descriptor.size);
    for (let index = 0; index < this.recordings.length; index += 1) {
      const recording = this.recordings[index];
      if (recording.syncKey === key ||
        (recording.sourcePath === descriptor.relativePath && recording.size === descriptor.size)) {
        return recording;
      }
    }
    return undefined;
  }

  findExisting(descriptor: WatchSyncFileDescriptor): ReceivedRecordingFile | undefined {
    // One-minute segments intentionally reuse the same file name and size in each
    // recording session. Only the watch source path plus size can safely identify
    // a retry; a legacy name-size match could discard a different session's audio.
    return this.findExact(descriptor);
  }

  record(recording: ReceivedRecordingFile): ReceivedRecordingFile {
    for (let index = 0; index < this.recordings.length; index += 1) {
      const existing = this.recordings[index];
      if ((recording.syncKey !== undefined && existing.syncKey === recording.syncKey) ||
        existing.path === recording.path) {
        return existing;
      }
    }
    this.recordings.push(recording);
    this.sortNewestFirst();
    try {
      this.writeManifest();
    } catch (error) {
      // The copied audio remains authoritative and will rebuild the index on the next launch.
    }
    return recording;
  }

  private loadFromDisk(): Array<ReceivedRecordingFile> {
    const loaded: Array<ReceivedRecordingFile> = [];
    this.loadManifest(loaded);
    this.scanExistingSyncFiles(loaded);
    this.scanLegacyManualFiles(loaded);
    this.recordings = loaded;
    this.sortNewestFirst();
    if (loaded.length > 0) {
      try {
        this.writeManifest();
      } catch (error) {
        // A directory scan can still restore the visible list without rewriting the index.
      }
    }
    return loaded;
  }

  private loadManifest(target: Array<ReceivedRecordingFile>): void {
    if (!fileIo.accessSync(this.manifestPath)) {
      return;
    }
    try {
      const manifest = JSON.parse(this.readText(this.manifestPath)) as ReceivedRecordingManifest;
      if (manifest.version !== MANIFEST_VERSION || !Array.isArray(manifest.recordings)) {
        return;
      }
      for (let index = 0; index < manifest.recordings.length; index += 1) {
        const entry = manifest.recordings[index];
        if (entry.localPath.length === 0 || entry.localPath.startsWith('/') || entry.localPath.includes('..')) {
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
        target.push({
          fileName: entry.fileName,
          path: path,
          size: entry.size,
          durationMs: entry.durationMs,
          requestId: entry.requestId,
          sourcePath: entry.sourcePath,
          receivedAt: entry.receivedAt,
          syncKey: entry.syncKey,
          legacySyncKey: entry.legacySyncKey
        });
      }
    } catch (error) {
      // The audio files remain authoritative; the directory scan below rebuilds a damaged index.
    }
  }

  private scanExistingSyncFiles(target: Array<ReceivedRecordingFile>): void {
    if (!fileIo.accessSync(this.syncRoot)) {
      return;
    }
    this.scanSyncDirectory(this.syncRoot, '', target);
  }

  private scanSyncDirectory(directory: string, relativeDirectory: string,
    target: Array<ReceivedRecordingFile>): void {
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
      const requestSeparator = relativePath.indexOf('/');
      const requestId = requestSeparator > 0 ? relativePath.substring(0, requestSeparator) : 'history';
      const fileName = name.replace(/^\d+_/, '');
      target.push({
        fileName: fileName,
        path: path,
        size: stat.size,
        durationMs: 0,
        requestId: requestId,
        sourcePath: '历史同步记录（来源目录未保存）',
        receivedAt: Math.round(stat.mtime * 1000),
        legacySyncKey: legacyWatchFileKey(fileName, stat.size)
      });
    }
  }

  private scanLegacyManualFiles(target: Array<ReceivedRecordingFile>): void {
    const entries = this.listDirectory(this.filesDirectory);
    for (let index = 0; index < entries.length; index += 1) {
      const name = entries[index];
      if (!name.startsWith('received_') || !this.isAudioFile(name)) {
        continue;
      }
      const path = `${this.filesDirectory}/${name}`;
      if (this.containsPath(target, path)) {
        continue;
      }
      const stat = fileIo.statSync(path);
      if (!stat.isFile() || stat.size <= 0) {
        continue;
      }
      target.push({
        fileName: name,
        path: path,
        size: stat.size,
        durationMs: 0,
        requestId: 'manual',
        sourcePath: '手表手动发送',
        receivedAt: Math.round(stat.mtime * 1000),
        legacySyncKey: legacyWatchFileKey(name, stat.size)
      });
    }
  }

  private writeManifest(): void {
    if (!fileIo.accessSync(this.syncRoot)) {
      fileIo.mkdirSync(this.syncRoot);
    }
    const entries: Array<ReceivedRecordingManifestEntry> = [];
    const prefix = `${this.filesDirectory}/`;
    for (let index = 0; index < this.recordings.length; index += 1) {
      const recording = this.recordings[index];
      if (!recording.path.startsWith(prefix) || !fileIo.accessSync(recording.path)) {
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
        syncKey: recording.syncKey,
        legacySyncKey: recording.legacySyncKey
      });
    }
    const manifest: ReceivedRecordingManifest = {
      version: MANIFEST_VERSION,
      updatedAt: Date.now(),
      recordings: entries
    };
    const output = fileIo.openSync(this.manifestPath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(output.fd, JSON.stringify(manifest, null, 2));
      fileIo.fsyncSync(output.fd);
    } finally {
      fileIo.closeSync(output.fd);
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

  private isAudioFile(fileName: string): boolean {
    const lowerName = fileName.toLowerCase();
    return lowerName.endsWith('.wav') || lowerName.endsWith('.m4a');
  }
}

export function loadReceivedRecordings(filesDirectory: string): Array<ReceivedRecordingFile> {
  return new ReceivedRecordingStore(filesDirectory).list();
}
