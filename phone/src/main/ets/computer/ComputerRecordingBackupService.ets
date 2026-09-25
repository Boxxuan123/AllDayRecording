import { common } from '@kit.AbilityKit';
import { ReceivedRecordingFile } from 'common';
import { connectComputerReceiver } from './ComputerReceiverConnection';
import {
  ComputerRecordingUploadService,
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

export interface ComputerRecordingBackupReceiptPort {
  linkLocalAudio(sessionKey: string, localPath: string, sha256: string,
    uploadStatus: string): Promise<void>;
}

export interface ComputerRecordingBackupRuntimePort {
  connect(): Promise<ComputerTransferConfig>;
  upload(config: ComputerTransferConfig, recordings: Array<ReceivedRecordingFile>,
    onProgress: ComputerUploadProgressHandler,
    onSessionCompleted?: (session: PreparedComputerSession) => Promise<void>): Promise<ComputerUploadResult>;
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

  async backup(recordings: Array<ReceivedRecordingFile>, onProgress: ComputerUploadProgressHandler):
    Promise<ComputerRecordingBackupOutcome> {
    const sessions = prepareComputerSessions(recordings);
    if (sessions.length === 0) {
      throw new Error('没有可上传的手表分段录音');
    }
    const config = await this.runtime.connect();
    const completed = new Set<string>();
    const result = await this.runtime.upload(config, recordings, onProgress,
      async (session: PreparedComputerSession): Promise<void> => {
        await this.recordReceipts([session]);
        completed.add(session.manifest.sessionKey);
      });
    await this.recordReceipts(sessions.filter((session: PreparedComputerSession): boolean =>
      !completed.has(session.manifest.sessionKey)));
    return new ComputerRecordingBackupOutcome(config, result);
  }

  private async recordReceipts(sessions: Array<PreparedComputerSession>): Promise<void> {
    for (let sessionIndex = 0; sessionIndex < sessions.length; sessionIndex += 1) {
      const session = sessions[sessionIndex];
      for (let recordingIndex = 0; recordingIndex < session.recordings.length; recordingIndex += 1) {
        await this.receipts.linkLocalAudio(session.manifest.sessionKey,
          session.recordings[recordingIndex].path, '', 'uploaded');
      }
    }
  }
}

export class ComputerRecordingBackupRuntime implements ComputerRecordingBackupRuntimePort {
  private context: common.UIAbilityContext;
  private configStore: ComputerTransferConfigStore;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.configStore = new ComputerTransferConfigStore(context);
  }

  async connect(): Promise<ComputerTransferConfig> {
    return connectComputerReceiver(this.context, this.configStore);
  }

  upload(config: ComputerTransferConfig, recordings: Array<ReceivedRecordingFile>,
    onProgress: ComputerUploadProgressHandler,
    onSessionCompleted?: (session: PreparedComputerSession) => Promise<void>): Promise<ComputerUploadResult> {
    return new ComputerRecordingUploadService(this.context, config).upload(recordings, onProgress, onSessionCompleted);
  }
}

export function createComputerRecordingBackupService(context: common.UIAbilityContext,
  receipts: ComputerRecordingBackupReceiptPort): ComputerRecordingBackupService {
  return new ComputerRecordingBackupService(new ComputerRecordingBackupRuntime(context), receipts);
}
