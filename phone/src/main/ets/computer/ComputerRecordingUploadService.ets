import { ComputerUploadConcurrency, runAdaptiveComputerUploadQueue } from './ComputerUploadQueue';
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
  ComputerUploadRecord,
  confirmedComputerSessionId
} from './ComputerTransferProtocol';
import { ComputerTransferConfig, ComputerTransferConfigStore } from './ComputerTransferConfigStore';
import { verifyConfiguration } from './ComputerReceiverConnection';
import { ComputerHttpError, ComputerTransferHttpClient, sha256Hex } from './ComputerTransferHttpClient';
import {
  PreparedComputerSession,
  prepareComputerSessions
} from './ComputerSessionManifest';
import { PhoneSessionCompletionRecord, PhoneV3LocalAudioLink } from '../v3/domain/PhoneV3Models';

export type ComputerUploadProgressHandler = (progress: ComputerUploadProgress) => void;

export class ComputerUploadProgress {
  activeFiles: Array<string> = [];
  sessionKey: string = '';
  sessionCompleted: boolean = false;
  message: string;
  completedFiles: number;
  totalFiles: number;
  transferredBytes: number;
  totalBytes: number;
  stage: string;

  constructor(message: string, completedFiles: number, totalFiles: number,
    transferredBytes: number, totalBytes: number, stage: string = 'verifying') {
    this.message = message;
    this.completedFiles = completedFiles;
    this.totalFiles = totalFiles;
    this.transferredBytes = transferredBytes;
    this.totalBytes = totalBytes;
    this.stage = stage;
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
  sessionId: string;
  inputRevision: number;

  constructor(upload: ComputerUploadRecord, skipped: boolean, sessionId: string = '', inputRevision: number = 1) {
    this.upload = upload;
    this.skipped = skipped;
    this.sessionId = sessionId;
    this.inputRevision = inputRevision;
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
  private config: ComputerTransferConfig;
  private store: ComputerTransferConfigStore;

  constructor(context: common.UIAbilityContext, config: ComputerTransferConfig, store?: ComputerTransferConfigStore) {
    if (!config.isPaired()) {
      throw new Error('尚未完成电脑 Passkey 配对');
    }
    this.client = new ComputerTransferHttpClient(context, config.baseUrl, config.caPath, config.deviceId, '', config.signingKeyAlias);
    this.config = config; this.store = store ?? new ComputerTransferConfigStore(context);
  }

  async upload(recordings: Array<ReceivedRecordingFile>, onProgress: ComputerUploadProgressHandler,
    onSessionCompleted: (session: PreparedComputerSession, upload: ComputerUploadRecord,
      inputRevision: number) => Promise<void> =
      async (): Promise<void> => {},
    onFileCompleted: (session: PreparedComputerSession, recording: ReceivedRecordingFile,
      upload: ComputerUploadRecord) => Promise<void> = async (): Promise<void> => {},
    completions: Array<PhoneSessionCompletionRecord> = [],
    links: Array<PhoneV3LocalAudioLink> = []):
    Promise<ComputerUploadResult> {
    const sessions = prepareComputerSessions(recordings, computerTransferTimezone(), completions);
    if (sessions.length === 0) {
      throw new Error('没有可上传的手表分段录音');
    }
    const manifests = prepareManifests(sessions.filter((session: PreparedComputerSession): boolean =>
      session.canCommit()));
    const totalFiles = recordingsInSessions(sessions) + manifests.length;
    let totalBytes = 0;
    const status = await this.client.status();
    verifyStatus(status);
    verifyFileSizes(sessions, manifests, status.max_file_bytes);
    const chunkBytes = Math.min(COMPUTER_UPLOAD_CHUNK_BYTES, status.max_chunk_bytes);
    let completedFiles = 0;
    let transferredBytes = 0;
    let skippedFiles = 0;
    let committedSessions = 0;
    const concurrency = new ComputerUploadConcurrency();
    const knownReceipts = new Map<string, PhoneV3LocalAudioLink>();
    links.forEach((link: PhoneV3LocalAudioLink): void => {
      if (link.uploadStatus === 'uploaded' && /^[0-9a-fA-F]{64}$/.test(link.sha256)) {
        knownReceipts.set(`${link.sessionKey}\u0000${link.localPath}`, link);
      }
    });
    sessions.forEach((session: PreparedComputerSession): void => {
      session.recordings.forEach((recording: ReceivedRecordingFile): void => {
        if (!knownReceipts.has(`${session.manifest.sessionKey}\u0000${recording.path}`)) {
          totalBytes += recording.size;
        }
      });
    });

    for (let sessionIndex = 0; sessionIndex < sessions.length; sessionIndex += 1) {
      await verifyConfiguration(this.store, this.config);
      const session = sessions[sessionIndex];
      const locallySkipped: Array<ReceivedRecordingFile> = [];
      const activeFiles = new Map<number, string>();
      const report = (progress: ComputerUploadProgress): void => {
        progress.activeFiles = Array.from(activeFiles.values());
        progress.sessionKey = session.manifest.sessionKey;
        progress.message = `会话 ${sessionIndex + 1}/${sessions.length} · ${sessionTimeLabel(session.manifest.sessionStartedAt)} · ${progress.message}`;
        onProgress(progress);
      };
      await runAdaptiveComputerUploadQueue(session.recordings.length, concurrency,
        async (recordingIndex: number): Promise<number> => {
        const recording = session.recordings[recordingIndex];
        let acknowledgedOffset = 0;
        let initialOffset = -1;
        activeFiles.set(recordingIndex, recording.fileName);
        report(new ComputerUploadProgress(`正在核对已有文件（当前上限 ${concurrency.limit} 个）`,
          completedFiles, totalFiles, transferredBytes, totalBytes));
        try {
          const receipt = knownReceipts.get(`${session.manifest.sessionKey}\u0000${recording.path}`);
          const result = receipt === undefined ? await this.uploadRecording(recording, chunkBytes,
            (remoteOffset: number): void => {
              if (initialOffset < 0) {
                initialOffset = remoteOffset;
                totalBytes -= remoteOffset;
                acknowledgedOffset = remoteOffset;
                report(new ComputerUploadProgress('正在核对已有文件',
                  completedFiles, totalFiles, transferredBytes, totalBytes));
                return;
              }
              transferredBytes += remoteOffset - acknowledgedOffset;
              acknowledgedOffset = remoteOffset;
              report(new ComputerUploadProgress(`正在上传 ${recording.fileName}`,
                completedFiles, totalFiles, transferredBytes, totalBytes, 'uploading'));
            }, (): void => { concurrency.congested(Date.now()); }) :
            completedLocalUpload(recording, receipt);
          if (receipt !== undefined) {
            locallySkipped.push(recording);
          }
          if (result.skipped) {
            skippedFiles += 1;
          }
          if (receipt === undefined) {
            await onFileCompleted(session, recording, result.upload);
          }
          completedFiles += 1;
          activeFiles.delete(recordingIndex);
          report(new ComputerUploadProgress(result.skipped ? `电脑已有，已跳过 ${recording.fileName}` :
            `已上传 ${completedFiles}/${totalFiles} 个文件`, completedFiles, totalFiles,
            transferredBytes, totalBytes));
          return result.skipped ? 0 : Math.max(0, result.upload.offset - initialOffset);
        } finally {
          activeFiles.delete(recordingIndex);
        }
      });
      if (!session.canCommit()) {
        const hasSummary = recordings.some((file: ReceivedRecordingFile): boolean =>
          file.sourcePath === `${session.directory}/session_summary.json`);
        const explanation = !session.manifest.continuityValid ?
          '分片已到电脑，但样本位置不连续，整场未确认' : hasSummary ?
            '手表结束记录与已收分片不符，请继续同步缺片' :
            '分片已备份，等待手表结束记录或明确的旧录音确认';
        report(new ComputerUploadProgress(explanation,
          completedFiles, totalFiles, transferredBytes, totalBytes));
        continue;
      }
      const manifest = prepareManifests([session])[0];
      report(new ComputerUploadProgress('音频已传完，正在确认完整录音', completedFiles, totalFiles,
        transferredBytes, totalBytes, 'confirming'));
      const submitManifest = (): Promise<ComputerFileUploadResult> =>
        this.uploadBytes(manifest.relativePath, manifest.bytes, 'manifest', chunkBytes,
          (remoteOffset: number): void => {
          report(new ComputerUploadProgress(
            `音频已传完，正在确认完整录音`, completedFiles, totalFiles,
            transferredBytes, totalBytes, 'confirming'));
        });
      let result: ComputerFileUploadResult;
      try {
        result = await submitManifest();
      } catch (error) {
        if (!(error instanceof ComputerHttpError) || error.statusCode !== 409 ||
          !error.message.includes('会话清单引用的录音尚未完整上传') || locallySkipped.length === 0) {
          throw error as Error;
        }
        report(new ComputerUploadProgress('电脑缺少已记录的分片，正在核验并补传',
          completedFiles, totalFiles, transferredBytes, totalBytes));
        locallySkipped.forEach((recording: ReceivedRecordingFile): void => { totalBytes += recording.size; });
        await runAdaptiveComputerUploadQueue(locallySkipped.length, concurrency,
          async (index: number): Promise<number> => {
            const recording = locallySkipped[index];
            let previousOffset = -1;
            const repaired = await this.uploadRecording(recording, chunkBytes, (offset: number): void => {
              if (previousOffset < 0) { totalBytes -= offset; previousOffset = offset; return; }
              transferredBytes += offset - previousOffset;
              previousOffset = offset;
              report(new ComputerUploadProgress(`正在补传 ${recording.fileName}`,
                completedFiles, totalFiles, transferredBytes, totalBytes, 'uploading'));
            },
              (): void => { concurrency.congested(Date.now()); });
            if (!repaired.skipped) { skippedFiles -= 1; }
            await onFileCompleted(session, recording, repaired.upload);
            return repaired.skipped ? 0 : repaired.upload.size;
          });
        result = await submitManifest();
      }
      if (result.skipped) {
        skippedFiles += 1;
      }
      completedFiles += 1;
      report(new ComputerUploadProgress(
        result.skipped ? `电脑已有，已跳过 ${manifest.relativePath}` :
          `已上传 ${completedFiles}/${totalFiles} 个文件`, completedFiles, totalFiles,
        transferredBytes, totalBytes));
      await onSessionCompleted(session, result.upload, result.inputRevision);
      committedSessions += 1;
      const done = new ComputerUploadProgress('会话备份完成', completedFiles, totalFiles,
        transferredBytes, totalBytes, 'completed');
      done.sessionCompleted = true;
      report(done);
    }
    return new ComputerUploadResult(committedSessions, totalFiles - manifests.length, manifests.length, skippedFiles);
  }

  private async uploadRecording(recording: ReceivedRecordingFile, chunkBytes: number,
    onOffset: (offset: number) => void, onRetry: () => void): Promise<ComputerFileUploadResult> {
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
    await verifyConfiguration(this.store, this.config);
    let remote = (await this.client.createUpload(metadata, onRetry)).upload;
    verifyRemoteUpload(remote, metadata);
    onOffset(remote.offset);
    if (remote.status === 'completed') {
      return new ComputerFileUploadResult(remote, true);
    }
    let fd: number = -1;
    try {
      fd = (await fileIo.open(recording.path, fileIo.OpenMode.READ_ONLY)).fd;
      while (remote.offset < metadata.size) {
        await verifyConfiguration(this.store, this.config);
        const sentOffset = remote.offset;
        const length = Math.min(chunkBytes, metadata.size - remote.offset);
        const buffer = new ArrayBuffer(length);
        // Explicit-position reads need not advance the descriptor cursor. Every
        // chunk must use the server-confirmed offset, including after resume.
        const read = await fileIo.read(fd, buffer, { offset: remote.offset, length: length });
        if (read !== length) {
          throw new Error(`录音文件没有完整读取：${recording.fileName}`);
        }
        remote = (await this.client.appendUpload(remote.upload_id, remote.offset,
          new Uint8Array(buffer), onRetry)).upload;
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
          await fileIo.close(fd);
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
    await verifyConfiguration(this.store, this.config);
    let response = await this.client.createUpload(metadata);
    let remote = response.upload;
    verifyRemoteUpload(remote, metadata);
    onOffset(remote.offset);
    if (remote.status === 'completed') {
      return new ComputerFileUploadResult(remote, true,
        confirmedComputerSessionId(response, metadata.sha256),
        response.automation?.v3?.input_revision ?? 1);
    }
    while (remote.offset < metadata.size) {
      await verifyConfiguration(this.store, this.config);
      const sentOffset = remote.offset;
      const end = Math.min(remote.offset + chunkBytes, metadata.size);
      const chunk = bytes.slice(remote.offset, end);
      response = await this.client.appendUpload(remote.upload_id, remote.offset, chunk);
      remote = response.upload;
      verifyRemoteUpload(remote, metadata);
      if (remote.offset !== end || remote.offset <= sentOffset) {
        throw new Error(`电脑返回了意外的会话清单断点：${relativePath}`);
      }
      onOffset(remote.offset);
    }
    if (remote.status !== 'completed') {
      throw new Error(`电脑没有确认会话清单完成：${relativePath}`);
    }
    return new ComputerFileUploadResult(remote, false,
      confirmedComputerSessionId(response, metadata.sha256),
      response.automation?.v3?.input_revision ?? 1);
  }
}

function completedLocalUpload(recording: ReceivedRecordingFile,
  receipt: PhoneV3LocalAudioLink): ComputerFileUploadResult {
  const stat = fileIo.statSync(recording.path);
  if (!stat.isFile() || stat.size !== recording.size) {
    throw new Error(`录音文件已改变，请刷新后重试：${recording.fileName}`);
  }
  const upload: ComputerUploadRecord = {
    upload_id: '', relative_path: recording.sourcePath, size: recording.size,
    sha256: receipt.sha256.toLowerCase(), kind: 'recording',
    offset: recording.size, status: 'completed'
  };
  return new ComputerFileUploadResult(upload, true);
}

function prepareManifests(sessions: Array<PreparedComputerSession>): Array<PreparedManifestPayload> {
  const result: Array<PreparedManifestPayload> = [];
  for (let index = 0; index < sessions.length; index += 1) {
    const bytes = util.TextEncoder.create('utf-8').encodeInto(JSON.stringify(sessions[index].manifest, undefined, 2));
    result.push(new PreparedManifestPayload(sessions[index].manifestRelativePath(), bytes));
  }
  return result;
}

export async function computerSessionManifestSha256(session: PreparedComputerSession): Promise<string> {
  return sha256Hex(prepareManifests([session])[0].bytes);
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

export function computerTransferTimezone(): string {
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

function sessionTimeLabel(startedAt: number): string {
  const date = new Date(startedAt);
  return `${date.getMonth() + 1}月${date.getDate()}日 ` +
    `${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}`;
}
