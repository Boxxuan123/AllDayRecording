import { common } from '@kit.AbilityKit';
import {
  ComputerUploadProgressHandler,
  ComputerUploadResult
} from '../../computer/ComputerRecordingUploadService';
import { createComputerRecordingBackupService } from '../../computer/ComputerRecordingBackupService';
import {
  PreparedComputerSession,
  prepareComputerSessions
} from '../../computer/ComputerSessionManifest';
import { ReceivedRecordingFile } from 'common';
import { PhoneV3RecordingStore } from '../runtime/PhoneV3RecordingStore';
import {
  PhoneV3AudioBackupPort,
  PhoneV3AudioBackupResult,
  PhoneV3ProjectionRepositoryPort
} from '../application/PhoneV3Ports';
import { PhoneV3LocalAudioLink } from '../domain/PhoneV3Models';

export class PhoneV3ComputerBackup implements PhoneV3AudioBackupPort {
  private onProgress: ComputerUploadProgressHandler;
  private context: common.UIAbilityContext;
  private repository: PhoneV3ProjectionRepositoryPort;

  constructor(context: common.UIAbilityContext, repository: PhoneV3ProjectionRepositoryPort,
    onProgress: ComputerUploadProgressHandler = (): void => {}) {
    this.onProgress = onProgress;
    this.context = context;
    this.repository = repository;
  }

  async backup(): Promise<PhoneV3AudioBackupResult> {
    const localRecordings = new PhoneV3RecordingStore(this.context.filesDir).list();
    const links = await this.repository.localAudioLinks();
    const recordings = recordingsNeedingComputerBackup(localRecordings, links);
    const sessions = prepareComputerSessions(recordings);
    if (sessions.length === 0) {
      return new PhoneV3AudioBackupResult();
    }
    const outcome = await createComputerRecordingBackupService(this.context, this.repository)
      .backup(sessions[0].recordings, this.onProgress);
    const result = backupResult(outcome.upload);
    result.more = sessions.length > 1;
    return result;
  }
}

export function recordingsNeedingComputerBackup(recordings: Array<ReceivedRecordingFile>,
  links: Array<PhoneV3LocalAudioLink>): Array<ReceivedRecordingFile> {
  const sessions = prepareComputerSessions(recordings);
  const pending: Array<ReceivedRecordingFile> = [];
  for (let sessionIndex = 0; sessionIndex < sessions.length; sessionIndex += 1) {
    const session = sessions[sessionIndex];
    if (sessionIsUploaded(session, links)) {
      continue;
    }
    pending.push(...session.recordings);
  }
  return pending;
}

function sessionIsUploaded(session: PreparedComputerSession, links: Array<PhoneV3LocalAudioLink>): boolean {
  for (let recordingIndex = 0; recordingIndex < session.recordings.length; recordingIndex += 1) {
    const recording = session.recordings[recordingIndex];
    let uploaded = false;
    for (let linkIndex = 0; linkIndex < links.length; linkIndex += 1) {
      const link = links[linkIndex];
      if (link.sessionKey === session.manifest.sessionKey && link.localPath === recording.path &&
        link.uploadStatus === 'uploaded') {
        uploaded = true;
        break;
      }
    }
    if (!uploaded) {
      return false;
    }
  }
  return session.recordings.length > 0;
}

function backupResult(result: ComputerUploadResult): PhoneV3AudioBackupResult {
  const totalFiles = result.recordings + result.manifests;
  return new PhoneV3AudioBackupResult(result.sessions,
    Math.max(0, totalFiles - result.skippedFiles), result.skippedFiles);
}
