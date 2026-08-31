import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo, hash } from '@kit.CoreFileKit';
import { i18n } from '@kit.LocalizationKit';
import { ReceivedRecordingFile } from 'common';
import {
  COMPUTER_UPLOAD_CHUNK_BYTES,
  ComputerStatusResponse,
  ComputerUploadMetadata,
  ComputerUploadRecord
} from './ComputerTransferProtocol';
import { ComputerTransferConfig } from './ComputerTransferConfigStore';
import { ComputerTransferHttpClient, sha256Hex } from './ComputerTransferHttpClient';
import {
  PreparedComputerSession,
  prepareComputerSessions
} from './ComputerSessionManifest';

export type ComputerUploadProgressHandler = (progress: ComputerUploadProgress) => void;

export class ComputerUploadProgress {
  message: string;
  completedFiles: number;
  totalFiles: number;
  transferredBytes: number;
  totalBytes: number;

  constructor(message: string, completedFiles: number, totalFiles: number,
    transferredBytes: number, totalBytes: number) {
    this.message = message;
    this.completedFiles = completedFiles;
    this.totalFiles = totalFiles;
    this.transferredBytes = transferredBytes;
    this.totalBytes = totalBytes;
  }

  percent(): number {
    if (this.totalBytes <= 0) {
      return 0;
    }
    return Math.min(100, Math.max(0, Math.floor(this.transferredBytes * 100 / this.totalBytes)));
  }
}

export class ComputerUploadResult {
  sessions: number;
  recordings: number;
  manifests: number;
  skippedFiles: number;

  constructor(sessions: number, recordings: number, manifests: number, skippedFiles: number) {
    this.sessions = sessions;
    this.recordings = recordings;
    this.manifests = manifests;
    this.skippedFiles = skippedFiles;
  }
}

class ComputerFileUploadResult {
  upload: ComputerUploadRecord;
  skipped: boolean;

  constructor(upload: ComputerUploadRecord, skipped: boolean) {
    this.upload = upload;
    this.skipped = skipped;
  }
}

class PreparedManifestPayload {
  relativePath: string;
  bytes: Uint8Array;

  constructor(relativePath: string, bytes: Uint8Array) {
    this.relativePath = relativePath;
    this.bytes = bytes;
  }
}

export class ComputerRecordingUploadService {
  private client: ComputerTransferHttpClient;

  constructor(context: common.UIAbilityContext, config: ComputerTransferConfig) {
    if (!config.isPaired()) {
      throw new Error('尚未完成电脑 Passkey 配对');
    }
    this.client = new ComputerTransferHttpClient(context, config.baseUrl, config.caPath, config.deviceId);
  }

  async upload(recordings: Array<ReceivedRecordingFile>, onProgress: ComputerUploadProgressHandler):
    Promise<ComputerUploadResult> {
    const sessions = prepareComputerSessions(recordings, currentTimezone());
    if (sessions.length === 0) {
      throw new Error('没有可上传的手表分段录音');
    }
    const manifests = prepareManifests(sessions);
    const totalFiles = recordingsInSessions(sessions) + manifests.length;
    const totalBytes = bytesInSessions(sessions) + manifestBytes(manifests);
    const status = await this.client.status();
    verifyStatus(status);
    verifyFileSizes(sessions, manifests, status.max_file_bytes);
    const chunkBytes = Math.min(COMPUTER_UPLOAD_CHUNK_BYTES, status.max_chunk_bytes);
    let completedFiles = 0;
    let transferredBytes = 0;
    let skippedFiles = 0;

    for (let sessionIndex = 0; sessionIndex < sessions.length; sessionIndex += 1) {
      const session = sessions[sessionIndex];
      for (let recordingIndex = 0; recordingIndex < session.recordings.length; recordingIndex += 1) {
        const recording = session.recordings[recordingIndex];
        const beforeFile = transferredBytes;
        const result = await this.uploadRecording(recording, chunkBytes,
          (remoteOffset: number): void => {
            onProgress(new ComputerUploadProgress(
              `正在上传 ${recording.fileName}`,
              completedFiles,
              totalFiles,
              beforeFile + remoteOffset,
              totalBytes
            ));
          });
        transferredBytes = beforeFile + result.upload.offset;
        if (result.skipped) {
          skippedFiles += 1;
        }
        completedFiles += 1;
        onProgress(new ComputerUploadProgress(
          result.skipped ? `电脑已有，已跳过 ${recording.fileName}` :
            `已上传 ${completedFiles}/${totalFiles} 个文件`, completedFiles, totalFiles,
          transferredBytes, totalBytes));
      }
      const manifest = manifests[sessionIndex];
      const beforeManifest = transferredBytes;
      const result = await this.uploadBytes(manifest.relativePath, manifest.bytes, 'manifest', chunkBytes,
        (remoteOffset: number): void => {
          onProgress(new ComputerUploadProgress(
            `正在提交 ${session.directory} 会话清单`, completedFiles, totalFiles,
            beforeManifest + remoteOffset, totalBytes));
        });
      transferredBytes = beforeManifest + result.upload.offset;
      if (result.skipped) {
        skippedFiles += 1;
      }
      completedFiles += 1;
      onProgress(new ComputerUploadProgress(
        result.skipped ? `电脑已有，已跳过 ${manifest.relativePath}` :
          `已上传 ${completedFiles}/${totalFiles} 个文件`, completedFiles, totalFiles,
        transferredBytes, totalBytes));
    }
    return new ComputerUploadResult(sessions.length, totalFiles - manifests.length, manifests.length, skippedFiles);
  }

  private async uploadRecording(recording: ReceivedRecordingFile, chunkBytes: number,
    onOffset: (offset: number) => void): Promise<ComputerFileUploadResult> {
    const stat = fileIo.statSync(recording.path);
    if (!stat.isFile() || stat.size !== recording.size) {
      throw new Error(`录音文件已改变，请刷新后重试：${recording.fileName}`);
    }
    const digest = (await hash.hash(recording.path, 'sha256')).toLowerCase();
    const metadata: ComputerUploadMetadata = {
      relative_path: recording.sourcePath,
      size: stat.size,
      sha256: digest,
      kind: 'recording'
    };
    let remote = (await this.client.createUpload(metadata)).upload;
    verifyRemoteUpload(remote, metadata);
    onOffset(remote.offset);
    if (remote.status === 'completed') {
      return new ComputerFileUploadResult(remote, true);
    }
    let fd: number = -1;
    try {
      fd = fileIo.openSync(recording.path, fileIo.OpenMode.READ_ONLY).fd;
      let positioned = false;
      while (remote.offset < metadata.size) {
        const sentOffset = remote.offset;
        const length = Math.min(chunkBytes, metadata.size - remote.offset);
        const buffer = new ArrayBuffer(length);
        const read = positioned ? fileIo.readSync(fd, buffer, { length: length }) :
          fileIo.readSync(fd, buffer, { offset: remote.offset, length: length });
        positioned = true;
        if (read !== length) {
          throw new Error(`录音文件没有完整读取：${recording.fileName}`);
        }
        remote = (await this.client.appendUpload(remote.upload_id, remote.offset,
          new Uint8Array(buffer))).upload;
        verifyRemoteUpload(remote, metadata);
        if (remote.offset !== sentOffset + length) {
          throw new Error(`电脑返回了意外的录音断点：${recording.fileName}`);
        }
        onOffset(remote.offset);
      }
      if (remote.status !== 'completed') {
        throw new Error(`电脑没有确认录音文件完成：${recording.fileName}`);
      }
      return new ComputerFileUploadResult(remote, false);
    } finally {
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (error) {
        }
      }
    }
  }

  private async uploadBytes(relativePath: string, bytes: Uint8Array, kind: string, chunkBytes: number,
    onOffset: (offset: number) => void): Promise<ComputerFileUploadResult> {
    const metadata: ComputerUploadMetadata = {
      relative_path: relativePath,
      size: bytes.length,
      sha256: await sha256Hex(bytes),
      kind: kind
    };
    let remote = (await this.client.createUpload(metadata)).upload;
    verifyRemoteUpload(remote, metadata);
    onOffset(remote.offset);
    if (remote.status === 'completed') {
      return new ComputerFileUploadResult(remote, true);
    }
    while (remote.offset < metadata.size) {
      const sentOffset = remote.offset;
      const end = Math.min(remote.offset + chunkBytes, metadata.size);
      const chunk = bytes.slice(remote.offset, end);
      remote = (await this.client.appendUpload(remote.upload_id, remote.offset, chunk)).upload;
      verifyRemoteUpload(remote, metadata);
      if (remote.offset !== end || remote.offset <= sentOffset) {
        throw new Error(`电脑返回了意外的会话清单断点：${relativePath}`);
      }
      onOffset(remote.offset);
    }
    if (remote.status !== 'completed') {
      throw new Error(`电脑没有确认会话清单完成：${relativePath}`);
    }
    return new ComputerFileUploadResult(remote, false);
  }
}

function prepareManifests(sessions: Array<PreparedComputerSession>): Array<PreparedManifestPayload> {
  const result: Array<PreparedManifestPayload> = [];
  for (let index = 0; index < sessions.length; index += 1) {
    const bytes = util.TextEncoder.create('utf-8').encodeInto(JSON.stringify(sessions[index].manifest, undefined, 2));
    result.push(new PreparedManifestPayload(sessions[index].manifestRelativePath(), bytes));
  }
  return result;
}

function recordingsInSessions(sessions: Array<PreparedComputerSession>): number {
  let result = 0;
  for (let index = 0; index < sessions.length; index += 1) {
    result += sessions[index].recordings.length;
  }
  return result;
}

function bytesInSessions(sessions: Array<PreparedComputerSession>): number {
  let result = 0;
  for (let sessionIndex = 0; sessionIndex < sessions.length; sessionIndex += 1) {
    const recordings = sessions[sessionIndex].recordings;
    for (let recordingIndex = 0; recordingIndex < recordings.length; recordingIndex += 1) {
      result += recordings[recordingIndex].size;
    }
  }
  return result;
}

function manifestBytes(manifests: Array<PreparedManifestPayload>): number {
  let result = 0;
  for (let index = 0; index < manifests.length; index += 1) {
    result += manifests[index].bytes.length;
  }
  return result;
}

function verifyStatus(status: ComputerStatusResponse): void {
  if (status.protocol !== 'ALL_DAY_RECORDING_TRANSFER' || status.version !== 2 ||
    status.status !== 'ready' || status.transport !== 'tls' || status.authentication !== 'device-signature' ||
    status.enrollment !== 'passkey' ||
    !Number.isSafeInteger(status.max_chunk_bytes) || status.max_chunk_bytes <= 0 ||
    !Number.isSafeInteger(status.max_file_bytes) || status.max_file_bytes <= 0) {
    throw new Error('连接的服务不是兼容的 AllDayRecording HTTPS 设备密钥接收端');
  }
}

function verifyFileSizes(sessions: Array<PreparedComputerSession>, manifests: Array<PreparedManifestPayload>,
  maxFileBytes: number): void {
  for (let sessionIndex = 0; sessionIndex < sessions.length; sessionIndex += 1) {
    const recordings = sessions[sessionIndex].recordings;
    for (let recordingIndex = 0; recordingIndex < recordings.length; recordingIndex += 1) {
      if (recordings[recordingIndex].size > maxFileBytes) {
        throw new Error(`录音超过电脑接收上限：${recordings[recordingIndex].fileName}`);
      }
    }
  }
  for (let index = 0; index < manifests.length; index += 1) {
    if (manifests[index].bytes.length > maxFileBytes) {
      throw new Error(`会话清单超过电脑接收上限：${manifests[index].relativePath}`);
    }
  }
}

function verifyRemoteUpload(remote: ComputerUploadRecord, expected: ComputerUploadMetadata): void {
  if (remote.relative_path !== expected.relative_path || remote.size !== expected.size ||
    remote.sha256 !== expected.sha256 || remote.kind !== expected.kind ||
    !Number.isSafeInteger(remote.offset) || remote.offset < 0 || remote.offset > expected.size ||
    (remote.status !== 'uploading' && remote.status !== 'completed')) {
    throw new Error(`电脑返回了不一致的上传状态：${expected.relative_path}`);
  }
}

function currentTimezone(): string {
  try {
    return i18n.getCalendar('zh-CN').getTimeZone();
  } catch (error) {
    return 'Asia/Singapore';
  }
}

export function computerDeviceName(): string {
  const name = deviceInfo.marketName.trim();
  return name.length > 0 ? name : deviceInfo.productModel;
}
