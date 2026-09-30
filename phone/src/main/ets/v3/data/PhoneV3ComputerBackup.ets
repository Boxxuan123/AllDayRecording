import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import {
  ComputerUploadProgressHandler,
  ComputerUploadResult,
  computerSessionManifestSha256,
  computerTransferTimezone
} from '../../computer/ComputerRecordingUploadService';
import { ComputerRecordingBackupOutcome, createComputerRecordingBackupService } from '../../computer/ComputerRecordingBackupService';
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
import { PhoneSessionCompletionRecord, PhoneSessionTransferFailure, PhoneV3LocalAudioLink } from '../domain/PhoneV3Models';

export class PhoneV3ComputerBackup implements PhoneV3AudioBackupPort {
  private onProgress: ComputerUploadProgressHandler;
  private context: common.UIAbilityContext;
  private repository: PhoneV3ProjectionRepositoryPort;
  private progressGeneration: number = 0;

  constructor(context: common.UIAbilityContext, repository: PhoneV3ProjectionRepositoryPort,
    onProgress: ComputerUploadProgressHandler = (): void => {}) {
    this.onProgress = onProgress;
    this.context = context;
    this.repository = repository;
  }

  async backup(): Promise<PhoneV3AudioBackupResult> {
    const progressGeneration = ++this.progressGeneration;
    const localRecordings = PhoneV3RecordingStore.shared(this.context.filesDir).list();
    const links = await this.repository.localAudioLinks();
    const completions = await this.repository.localSessionCompletions();
    await retryLegacyCompletionConflictsOnce(this.context.filesDir, this.repository, completions);
    const failures = await this.repository.localSessionFailures();
    const recordings = await recordingsNeedingComputerBackup(localRecordings, links, completions,
      computerSessionManifestSha256, failures);
    const sessions = prepareComputerSessions(recordings, computerTransferTimezone(), completions).reverse();
    if (sessions.length === 0) {
      const result = new PhoneV3AudioBackupResult();
      result.failedSessions = failures.length;
      result.failureReason = failures.length > 0 ? failures[0].reason : '';
      result.failureCategory = failures.length > 0 ? failures[0].category : '';
      result.retryAfterMs = nextNetworkRetryMs(failures);
      return result;
    }
    let outcome: ComputerRecordingBackupOutcome;
    try {
      outcome = await createComputerRecordingBackupService(this.context, this.repository)
        .backup(recordings.filter((recording: ReceivedRecordingFile): boolean =>
          recording.sourcePath.startsWith(`${sessions[0].directory}/`)), (progress): void => {
            if (progressGeneration === this.progressGeneration) { this.onProgress(progress); }
          }, completions, links, failures);
    } catch (error) {
      const updated = await this.repository.localSessionFailures();
      const failed = updated.find((value: PhoneSessionTransferFailure): boolean => {
          if (value.sessionKey !== sessions[0].manifest.sessionKey) { return false; }
          const old = failures.find((entry: PhoneSessionTransferFailure): boolean =>
            entry.sessionKey === value.sessionKey);
          return old === undefined || value.manifestSha256 !== old.manifestSha256 ||
            value.attemptCount > old.attemptCount || value.updatedAt > old.updatedAt;
        });
      if (failed === undefined) { throw error as Error; }
      const remaining = await recordingsNeedingComputerBackup(localRecordings,
        await this.repository.localAudioLinks(), completions, computerSessionManifestSha256, updated);
      const result = new PhoneV3AudioBackupResult();
      result.more = remaining.length > 0;
      result.failedSessions = 1;
      result.failureReason = failed.reason;
      result.failureCategory = failed.category;
      result.retryAfterMs = nextNetworkRetryMs(updated);
      return result;
    } finally {
      if (progressGeneration === this.progressGeneration) { this.progressGeneration += 1; }
    }
    const result = backupResult(outcome.upload);
    result.more = sessions.length > 1;
    result.retryAfterMs = nextNetworkRetryMs(await this.repository.localSessionFailures());
    return result;
  }
}

// Only stale failures from the old completion protocol are retried on upgrade.
// The marker prevents a genuine conflict from entering an automatic retry loop.
export async function retryLegacyCompletionConflictsOnce(filesDir: string,
  repository: PhoneV3ProjectionRepositoryPort,
  completions: Array<PhoneSessionCompletionRecord>): Promise<void> {
  const marker = `${filesDir}/computer_completion_compat_v1.done`;
  if (fileIo.accessSync(marker)) { return; }
  const failures = await repository.localSessionFailures();
  for (const failure of failures) {
    if (failure.category !== 'conflict' ||
      !failure.reason.includes('新清单没有连续追加分片，不能替换已确认版本') ||
      !completions.some((receipt: PhoneSessionCompletionRecord): boolean =>
        receipt.sessionKey === failure.sessionKey && receipt.source === 'legacy_user_confirmed' &&
          receipt.manifestSha256.length === 0)) { continue; }
    await repository.clearSessionFailure(failure.sessionKey);
  }
  const file = fileIo.openSync(marker, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
  fileIo.closeSync(file);
}

export async function recordingsNeedingComputerBackup(recordings: Array<ReceivedRecordingFile>,
  links: Array<PhoneV3LocalAudioLink>,
  completions: Array<PhoneSessionCompletionRecord> = [],
  manifestDigest: (session: PreparedComputerSession) => Promise<string> = computerSessionManifestSha256,
  failures: Array<PhoneSessionTransferFailure> = []):
  Promise<Array<ReceivedRecordingFile>> {
  const sessions = prepareComputerSessions(recordings, computerTransferTimezone(), completions);
  const pending: Array<ReceivedRecordingFile> = [];
  for (let sessionIndex = sessions.length - 1; sessionIndex >= 0; sessionIndex -= 1) {
    const session = sessions[sessionIndex];
    const failed = failures.find((value: PhoneSessionTransferFailure): boolean =>
      value.sessionKey === session.manifest.sessionKey);
    if (failed !== undefined && (failed.category === 'conflict' || failed.retryAt > Date.now()) &&
      failed.manifestSha256 === (session.canCommit() ? await manifestDigest(session) : '')) {
      continue;
    }
    if (await sessionIsUploaded(session, links, completions, manifestDigest)) {
      continue;
    }
    pending.push(...session.recordings);
    const summary = recordings.find((recording: ReceivedRecordingFile): boolean =>
      recording.sourcePath === `${session.directory}/session_summary.json`);
    if (summary !== undefined) { pending.push(summary); }
  }
  return pending;
}

async function sessionIsUploaded(session: PreparedComputerSession, links: Array<PhoneV3LocalAudioLink>,
  completions: Array<PhoneSessionCompletionRecord>,
  manifestDigest: (session: PreparedComputerSession) => Promise<string>): Promise<boolean> {
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
  if (!session.canCommit()) { return session.recordings.length > 0; }
  const receipt = completions.find((record: PhoneSessionCompletionRecord): boolean =>
    record.sessionKey === session.manifest.sessionKey && record.manifestSha256.length === 64 &&
    record.completedSegments === session.manifest.completedSegments &&
    record.totalSamples === session.manifest.totalSamples);
  return receipt !== undefined && receipt.manifestSha256 === await manifestDigest(session);
}

function backupResult(result: ComputerUploadResult): PhoneV3AudioBackupResult {
  const totalFiles = result.recordings + result.manifests;
  return new PhoneV3AudioBackupResult(result.sessions,
    Math.max(0, totalFiles - result.skippedFiles), result.skippedFiles);
}

function nextNetworkRetryMs(failures: Array<PhoneSessionTransferFailure>): number {
  let next = 0;
  for (let index = 0; index < failures.length; index += 1) {
    const failure = failures[index];
    if (failure.category !== 'network') { continue; }
    const delay = Math.max(1000, failure.retryAt - Date.now());
    next = next === 0 ? delay : Math.min(next, delay);
  }
  return next;
}
