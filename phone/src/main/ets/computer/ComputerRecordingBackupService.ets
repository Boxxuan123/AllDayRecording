import { common } from '@kit.AbilityKit';
import { ReceivedRecordingFile } from 'common';
import { connectComputerReceiver, verifyConfiguration } from './ComputerReceiverConnection';
import {
  ComputerRecordingUploadService,
  computerSessionManifestSha256,
  computerTransferTimezone,
  ComputerUploadProgressHandler,
  ComputerUploadResult
} from './ComputerRecordingUploadService';
import {
  ComputerTransferConfig,
  ComputerTransferConfigStore
} from './ComputerTransferConfigStore';
import {
  PreparedComputerSession,
  prepareComputerSessions
} from './ComputerSessionManifest';
import { ComputerUploadRecord } from './ComputerTransferProtocol';
import { ComputerHttpError } from './ComputerTransferHttpClient';
import { PhoneSessionCompletionRecord, PhoneSessionTransferFailure, PhoneV3LocalAudioLink } from '../v3/domain/PhoneV3Models';

export interface ComputerRecordingBackupReceiptPort {
  linkLocalAudio(sessionKey: string, localPath: string, sha256: string,
    uploadStatus: string): Promise<void>;
  recordSessionCompletion(record: PhoneSessionCompletionRecord): Promise<void>;
  recordSessionFailure?(failure: PhoneSessionTransferFailure): Promise<void>;
  clearSessionFailure?(sessionKey: string): Promise<void>;
}

export interface ComputerRecordingBackupRuntimePort {
  connect(): Promise<ComputerTransferConfig>;
  upload(config: ComputerTransferConfig, recordings: Array<ReceivedRecordingFile>,
    onProgress: ComputerUploadProgressHandler,
    onSessionCompleted?: (session: PreparedComputerSession, upload: ComputerUploadRecord,
      inputRevision?: number) => Promise<void>,
    onFileCompleted?: (session: PreparedComputerSession, recording: ReceivedRecordingFile,
      upload: ComputerUploadRecord) => Promise<void>,
    completions?: Array<PhoneSessionCompletionRecord>,
    links?: Array<PhoneV3LocalAudioLink>): Promise<ComputerUploadResult>;
}

export class ComputerRecordingBackupOutcome {
  config: ComputerTransferConfig;
  upload: ComputerUploadResult;

  constructor(config: ComputerTransferConfig, upload: ComputerUploadResult) {
    this.config = config;
    this.upload = upload;
  }
}

export class ComputerRecordingBackupService {
  private runtime: ComputerRecordingBackupRuntimePort;
  private receipts: ComputerRecordingBackupReceiptPort;

  constructor(runtime: ComputerRecordingBackupRuntimePort,
    receipts: ComputerRecordingBackupReceiptPort) {
    this.runtime = runtime;
    this.receipts = receipts;
  }

  async backup(recordings: Array<ReceivedRecordingFile>, onProgress: ComputerUploadProgressHandler,
    completions: Array<PhoneSessionCompletionRecord> = [],
    links: Array<PhoneV3LocalAudioLink> = [],
    failures: Array<PhoneSessionTransferFailure> = []):
    Promise<ComputerRecordingBackupOutcome> {
    const sessions = prepareComputerSessions(recordings, computerTransferTimezone(), completions);
    if (sessions.length === 0) {
      throw new Error('没有可上传的手表分段录音');
    }
    const config = await this.runtime.connect();
    let receiptQueue: Promise<void> = Promise.resolve();
    let activeSessionKey = sessions[0].manifest.sessionKey;
    let result: ComputerUploadResult;
    try {
    result = await this.runtime.upload(config, recordings, (progress): void => {
      if (progress.sessionKey.length > 0) { activeSessionKey = progress.sessionKey; }
      onProgress(progress);
    },
      async (session: PreparedComputerSession, upload: ComputerUploadRecord,
        inputRevision: number = 1): Promise<void> => {
        if (session.manifest.completion !== undefined) {
          const proof = session.manifest.completion;
          await this.receipts.recordSessionCompletion({ sessionKey: session.manifest.sessionKey,
            source: proof.source, completedSegments: proof.completedSegments,
            totalSamples: proof.totalSamples, confirmedAt: proof.confirmedAt,
            manifestSha256: upload.sha256, inputRevision: inputRevision });
          if (this.receipts.clearSessionFailure !== undefined) {
            await this.receipts.clearSessionFailure(session.manifest.sessionKey);
          }
        }
      }, async (session: PreparedComputerSession, recording: ReceivedRecordingFile,
        upload: ComputerUploadRecord): Promise<void> => {
        receiptQueue = receiptQueue.then(async (): Promise<void> => {
          await this.receipts.linkLocalAudio(session.manifest.sessionKey,
            recording.path, upload.sha256, 'uploaded');
        });
        await receiptQueue;
      }, completions, links);
    } catch (error) {
      const session = sessions.find((value: PreparedComputerSession): boolean =>
        value.manifest.sessionKey === activeSessionKey) ?? sessions[0];
      if (this.receipts.recordSessionFailure !== undefined) {
        const digest = session.canCommit() ? await computerSessionManifestSha256(session) : '';
        const previous = failures.find((value: PhoneSessionTransferFailure): boolean =>
          value.sessionKey === activeSessionKey && value.manifestSha256 === digest);
        const attempts = (previous?.attemptCount ?? 0) + 1;
        const failure = error as Error;
        const conflict = failure instanceof ComputerHttpError &&
          (failure.statusCode === 409 || failure.statusCode === 422);
        await this.receipts.recordSessionFailure({ sessionKey: activeSessionKey,
          manifestSha256: digest, category: conflict ? 'conflict' : 'network',
          reason: failure.message, attemptCount: attempts,
          retryAt: conflict ? 0 : Date.now() + Math.min(300000, 15000 * Math.pow(2, Math.min(4, attempts - 1))),
          updatedAt: Date.now() });
      }
      throw error as Error;
    }
    await receiptQueue;
    return new ComputerRecordingBackupOutcome(config, result);
  }
}

export class ComputerRecordingBackupRuntime implements ComputerRecordingBackupRuntimePort {
  private context: common.UIAbilityContext;
  private configStore: ComputerTransferConfigStore;

  constructor(context: common.UIAbilityContext, store?: ComputerTransferConfigStore) {
    this.context = context;
    this.configStore = store ?? new ComputerTransferConfigStore(context);
  }

  async connect(): Promise<ComputerTransferConfig> {
    return connectComputerReceiver(this.context, this.configStore);
  }

  upload(config: ComputerTransferConfig, recordings: Array<ReceivedRecordingFile>,
    onProgress: ComputerUploadProgressHandler,
    onSessionCompleted?: (session: PreparedComputerSession, upload: ComputerUploadRecord,
      inputRevision?: number) => Promise<void>,
    onFileCompleted?: (session: PreparedComputerSession, recording: ReceivedRecordingFile,
      upload: ComputerUploadRecord) => Promise<void>,
    completions: Array<PhoneSessionCompletionRecord> = [],
    links: Array<PhoneV3LocalAudioLink> = []): Promise<ComputerUploadResult> {
    return new ComputerRecordingUploadService(this.context, config, this.configStore).upload(recordings, onProgress,
      async (session: PreparedComputerSession, upload: ComputerUploadRecord,
        inputRevision: number): Promise<void> => {
        await verifyConfiguration(this.configStore, config);
        if (onSessionCompleted !== undefined) { await onSessionCompleted(session, upload, inputRevision); }
      }, async (session: PreparedComputerSession, recording: ReceivedRecordingFile,
        upload: ComputerUploadRecord): Promise<void> => {
        if (onFileCompleted !== undefined) { await onFileCompleted(session, recording, upload); }
      }, completions, links);
  }
}

export function createComputerRecordingBackupService(context: common.UIAbilityContext,
  receipts: ComputerRecordingBackupReceiptPort): ComputerRecordingBackupService {
  return new ComputerRecordingBackupService(new ComputerRecordingBackupRuntime(context), receipts);
}
