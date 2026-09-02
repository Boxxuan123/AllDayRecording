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
import { ComputerTransferConfig } from '../main/ets/computer/ComputerTransferConfigStore';

class FakeBackupRuntime implements ComputerRecordingBackupRuntimePort {
  connectCount: number = 0;
  uploadCount: number = 0;

  async connect(): Promise<ComputerTransferConfig> {
    this.connectCount += 1;
    return new ComputerTransferConfig('https://computer.example', 'fingerprint', 'rp-id',
      '/trusted/ca.pem', 'receiver-id', 'device-id');
  }

  async upload(_config: ComputerTransferConfig, recordings: Array<ReceivedRecordingFile>,
    onProgress: ComputerUploadProgressHandler): Promise<ComputerUploadResult> {
    this.uploadCount += 1;
    onProgress(new ComputerUploadProgress('uploaded', recordings.length, recordings.length,
      recordings.length, recordings.length));
    return new ComputerUploadResult(1, recordings.length, 1, 0);
  }
}

class FakeBackupReceipts implements ComputerRecordingBackupReceiptPort {
  sessionKeys: Array<string> = [];
  paths: Array<string> = [];

  async linkLocalAudio(sessionKey: string, localPath: string, _sha256: string,
    _uploadStatus: string): Promise<void> {
    this.sessionKeys.push(sessionKey);
    this.paths.push(localPath);
  }
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
    });
  });
}
