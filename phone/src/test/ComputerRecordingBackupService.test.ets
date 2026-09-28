import { describe, expect, it } from '@ohos/hypium';
import { ReceivedRecordingFile, WAV_HEADER_BYTES } from 'common';
import {
  ComputerRecordingBackupReceiptPort,
  ComputerRecordingBackupRuntimePort,
  ComputerRecordingBackupService
} from '../main/ets/computer/ComputerRecordingBackupService';
import {
  ComputerUploadProgress,
  ComputerUploadProgressHandler,
  ComputerUploadResult
} from '../main/ets/computer/ComputerRecordingUploadService';
import { PreparedComputerSession, prepareComputerSessions } from '../main/ets/computer/ComputerSessionManifest';
import { ComputerTransferConfig } from '../main/ets/computer/ComputerTransferConfigStore';
import { ComputerUploadRecord } from '../main/ets/computer/ComputerTransferProtocol';
import { PhoneSessionCompletionRecord } from '../main/ets/v3/domain/PhoneV3Models';
import { PhoneSessionTransferFailure } from '../main/ets/v3/domain/PhoneV3Models';
import { ComputerHttpError } from '../main/ets/computer/ComputerTransferHttpClient';

class FakeBackupRuntime implements ComputerRecordingBackupRuntimePort {
  connectCount: number = 0;
  uploadCount: number = 0;

  async connect(): Promise<ComputerTransferConfig> {
    this.connectCount += 1;
    return new ComputerTransferConfig('https://computer.example', 'fingerprint', 'rp-id',
      '/trusted/ca.pem', 'receiver-id', 'device-id');
  }

  async upload(_config: ComputerTransferConfig, recordings: Array<ReceivedRecordingFile>,
    onProgress: ComputerUploadProgressHandler,
    onSessionCompleted?: (session: PreparedComputerSession, upload: ComputerUploadRecord) => Promise<void>,
    onFileCompleted?: (session: PreparedComputerSession, recording: ReceivedRecordingFile,
      upload: ComputerUploadRecord) => Promise<void>,
    completions: Array<PhoneSessionCompletionRecord> = []): Promise<ComputerUploadResult> {
    this.uploadCount += 1;
    onProgress(new ComputerUploadProgress('uploaded', recordings.length, recordings.length,
      recordings.length, recordings.length));
    const session = prepareComputerSessions(recordings, 'Asia/Singapore', completions)[0];
    if (onFileCompleted !== undefined) {
      for (let index = 0; index < session.recordings.length; index += 1) {
        const file = session.recordings[index];
        await onFileCompleted(session, file, fakeUpload(file));
      }
    }
    if (session.canCommit() && onSessionCompleted !== undefined) {
      await onSessionCompleted(session, fakeUpload(session.recordings[0]));
    }
    return new ComputerUploadResult(session.canCommit() ? 1 : 0,
      session.recordings.length, session.canCommit() ? 1 : 0, 0);
  }
}

class FakeBackupReceipts implements ComputerRecordingBackupReceiptPort {
  sessionKeys: Array<string> = [];
  paths: Array<string> = [];
  completions: Array<PhoneSessionCompletionRecord> = [];
  failures: Array<PhoneSessionTransferFailure> = [];

  async recordSessionCompletion(record: PhoneSessionCompletionRecord): Promise<void> {
    this.completions.push(record);
  }

  async recordSessionFailure(failure: PhoneSessionTransferFailure): Promise<void> {
    this.failures.push(failure);
  }

  async clearSessionFailure(_sessionKey: string): Promise<void> {
    this.failures = [];
  }

  async linkLocalAudio(sessionKey: string, localPath: string, _sha256: string,
    _uploadStatus: string): Promise<void> {
    this.sessionKeys.push(sessionKey);
    this.paths.push(localPath);
  }
}

class PartialBackupRuntime extends FakeBackupRuntime {
  async upload(_config: ComputerTransferConfig, recordings: Array<ReceivedRecordingFile>,
    _onProgress: ComputerUploadProgressHandler,
    _onSessionCompleted?: (session: PreparedComputerSession, upload: ComputerUploadRecord) => Promise<void>,
    onFileCompleted?: (session: PreparedComputerSession, recording: ReceivedRecordingFile,
      upload: ComputerUploadRecord) => Promise<void>): Promise<ComputerUploadResult> {
    const session = prepareComputerSessions(recordings)[0];
    if (onFileCompleted !== undefined) {
      await onFileCompleted(session, session.recordings[0], fakeUpload(session.recordings[0]));
    }
    throw new Error('second session disconnected');
  }
}

class ConflictBackupRuntime extends FakeBackupRuntime {
  async upload(_config: ComputerTransferConfig, recordings: Array<ReceivedRecordingFile>,
    _onProgress: ComputerUploadProgressHandler): Promise<ComputerUploadResult> {
    throw new ComputerHttpError(409, '旧分片哈希与已入库音频不一致');
  }
}

function fakeUpload(file: ReceivedRecordingFile): ComputerUploadRecord {
  return { upload_id: 'uploaded', relative_path: file.sourcePath, size: file.size,
    sha256: 'a'.repeat(64), kind: 'recording', offset: file.size, status: 'completed' };
}

function recording(index: number, firstSample: number): ReceivedRecordingFile {
  const fileName = `segment_${index.toString().padStart(6, '0')}_first_${
    firstSample.toString().padStart(12, '0')}.wav`;
  return {
    fileName: fileName,
    path: `/phone/${fileName}`,
    size: WAV_HEADER_BYTES + 32000,
    durationMs: 1000,
    requestId: 'request',
    sourcePath: `pcm_gap_test_1788000000000/${fileName}`,
    receivedAt: index
  };
}

export default function computerRecordingBackupServiceTest() {
  describe('ComputerRecordingBackupService', () => {
    it('preservesCompletedSessionReceiptsWhenLaterUploadFails', 0, async () => {
      const receipts = new FakeBackupReceipts();
      let failed = false;
      try {
        await new ComputerRecordingBackupService(new PartialBackupRuntime(), receipts)
          .backup([recording(1, 0)], (): void => {});
      } catch (_error) {
        failed = true;
      }
      expect(failed).assertTrue();
      expect(receipts.paths.length).assertEqual(1);
      expect(receipts.sessionKeys[0]).assertEqual('watch-session:1788000000000');
      expect(receipts.failures.length).assertEqual(1);
      expect(receipts.failures[0].category).assertEqual('network');
    });
    it('usesOneUploadPipelineAndRecordsEveryUploadedLocalFile', 0, async () => {
      const runtime = new FakeBackupRuntime();
      const receipts = new FakeBackupReceipts();
      let progressEvents = 0;
      const result = await new ComputerRecordingBackupService(runtime, receipts).backup([
        recording(1, 0),
        recording(2, 16000)
      ], (_progress: ComputerUploadProgress): void => {
        progressEvents += 1;
      });

      expect(runtime.connectCount).assertEqual(1);
      expect(runtime.uploadCount).assertEqual(1);
      expect(progressEvents).assertEqual(1);
      expect(result.upload.recordings).assertEqual(2);
      expect(result.config.baseUrl).assertEqual('https://computer.example');
      expect(receipts.paths.length).assertEqual(2);
      expect(receipts.sessionKeys[0]).assertEqual('watch-session:1788000000000');
      expect(receipts.sessionKeys[1]).assertEqual('watch-session:1788000000000');
      expect(receipts.completions.length).assertEqual(0);
    });
    it('storesSeparateSessionReceiptOnlyAfterFinalEvidence', 0, async () => {
      const runtime = new FakeBackupRuntime();
      const receipts = new FakeBackupReceipts();
      const finality: PhoneSessionCompletionRecord = {
        sessionKey: 'watch-session:1788000000000', source: 'legacy_user_confirmed',
        completedSegments: 2, totalSamples: 32000, confirmedAt: 1788000001000,
        manifestSha256: ''
      };
      await new ComputerRecordingBackupService(runtime, receipts).backup([
        recording(1, 0), recording(2, 16000)
      ], (): void => {}, [finality]);
      expect(receipts.paths.length).assertEqual(2);
      expect(receipts.completions.length).assertEqual(1);
      expect(receipts.completions[0].completedSegments).assertEqual(2);
      expect(receipts.completions[0].manifestSha256).assertEqual('a'.repeat(64));
    });
    it('persistsManifestConflictForManualRecovery', 0, async () => {
      const receipts = new FakeBackupReceipts();
      let failed = false;
      try {
        await new ComputerRecordingBackupService(new ConflictBackupRuntime(), receipts)
          .backup([recording(1, 0)], (): void => {});
      } catch (_error) { failed = true; }
      expect(failed).assertTrue();
      expect(receipts.failures.length).assertEqual(1);
      expect(receipts.failures[0].category).assertEqual('conflict');
      expect(receipts.failures[0].retryAt).assertEqual(0);
    });
  });
}
