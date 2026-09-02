import { common } from '@kit.AbilityKit';
import {
  ComputerUploadResult
} from '../../computer/ComputerRecordingUploadService';
import { createComputerRecordingBackupService } from '../../computer/ComputerRecordingBackupService';
import { prepareComputerSessions } from '../../computer/ComputerSessionManifest';
import { PhoneV3RecordingStore } from '../runtime/PhoneV3RecordingStore';
import {
  PhoneV3AudioBackupPort,
  PhoneV3AudioBackupResult,
  PhoneV3ProjectionRepositoryPort
} from '../application/PhoneV3Ports';

export class PhoneV3ComputerBackup implements PhoneV3AudioBackupPort {
  private context: common.UIAbilityContext;
  private repository: PhoneV3ProjectionRepositoryPort;

  constructor(context: common.UIAbilityContext, repository: PhoneV3ProjectionRepositoryPort) {
    this.context = context;
    this.repository = repository;
  }

  async backup(): Promise<PhoneV3AudioBackupResult> {
    const recordings = new PhoneV3RecordingStore(this.context.filesDir).list();
    const sessions = prepareComputerSessions(recordings);
    if (sessions.length === 0) {
      return new PhoneV3AudioBackupResult();
    }
    const outcome = await createComputerRecordingBackupService(this.context, this.repository)
      .backup(recordings, (): void => {});
    return backupResult(outcome.upload);
  }
}

function backupResult(result: ComputerUploadResult): PhoneV3AudioBackupResult {
  const totalFiles = result.recordings + result.manifests;
  return new PhoneV3AudioBackupResult(result.sessions,
    Math.max(0, totalFiles - result.skippedFiles), result.skippedFiles);
}
