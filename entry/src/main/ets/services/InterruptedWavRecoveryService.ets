import { fileIo } from '@kit.CoreFileKit';
import {
  PCM_BITS_PER_SAMPLE as BITS_PER_SAMPLE,
  PCM_BYTES_PER_SAMPLE as BYTES_PER_SAMPLE,
  PCM_CHANNEL_COUNT as CHANNEL_COUNT,
  PCM_SAMPLE_RATE_HZ as SAMPLE_RATE,
  WAV_HEADER_BYTES,
  createPcmWavHeader,
  publishPartFile,
  syncAndClose,
  writeEntireBuffer,
  writeJsonAtomically
} from 'common';
import {
  PCM_RECORDING_SEGMENT_BYTES,
  isPcmRecordingSessionName
} from '../recording/PcmRecordingContract';

const PART_SUFFIX: string = '.wav.part';

interface RecoveredWavEvidence {
  sourcePartFileName: string;
  fileName: string;
  firstSample: number;
  pcmBytes: number;
  sampleCount: number;
  durationMs: number;
}

interface RecoveryFailureEvidence {
  fileName: string;
  message: string;
}

interface SessionRecoverySummary {
  format: string;
  recoveredAt: number;
  reason: string;
  continuityStatus: string;
  sampleRate: number;
  channels: number;
  bitsPerSample: number;
  recoveredFiles: Array<RecoveredWavEvidence>;
  discardedEmptyParts: Array<string>;
  failures: Array<RecoveryFailureEvidence>;
}

export interface InterruptedWavRecoveryResult {
  recoveredCount: number;
  discardedEmptyCount: number;
  failureCount: number;
}

export type RecoveryDirectoryListOperation = (path: string) => Array<string>;
export type RecoverySeekOperation = (fd: number) => void;

export class InterruptedWavRecoveryService {
  static recover(filesDirectory: string,
    listDirectory: RecoveryDirectoryListOperation =
      (path: string): Array<string> => fileIo.listFileSync(path),
    seekToStart: RecoverySeekOperation =
      (fd: number): void => {
        fileIo.lseek(fd, 0, fileIo.WhenceType.SEEK_SET);
      }): InterruptedWavRecoveryResult {
    const result: InterruptedWavRecoveryResult = {
      recoveredCount: 0,
      discardedEmptyCount: 0,
      failureCount: 0
    };
    const rootEntries = listDirectory(filesDirectory);
    for (let index = 0; index < rootEntries.length; index += 1) {
      const sessionName = rootEntries[index];
      if (!isPcmRecordingSessionName(sessionName)) {
        continue;
      }
      const sessionDirectory = `${filesDirectory}/${sessionName}`;
      try {
        if (!fileIo.statSync(sessionDirectory).isDirectory()) {
          continue;
        }
        const summary = InterruptedWavRecoveryService.recoverSession(sessionDirectory, listDirectory, seekToStart);
        result.recoveredCount += summary.recoveredFiles.length;
        result.discardedEmptyCount += summary.discardedEmptyParts.length;
        result.failureCount += summary.failures.length;
      } catch (error) {
        result.failureCount += 1;
      }
    }
    return result;
  }

  private static recoverSession(sessionDirectory: string,
    listDirectory: RecoveryDirectoryListOperation, seekToStart: RecoverySeekOperation): SessionRecoverySummary {
    const summary: SessionRecoverySummary = {
      format: 'AllDayRecording interrupted WAV recovery v1',
      recoveredAt: Date.now(),
      reason: 'process_interruption',
      continuityStatus: 'unknown_after_process_interruption',
      sampleRate: SAMPLE_RATE,
      channels: CHANNEL_COUNT,
      bitsPerSample: BITS_PER_SAMPLE,
      recoveredFiles: [],
      discardedEmptyParts: [],
      failures: []
    };
    const entries = listDirectory(sessionDirectory);
    let foundPart: boolean = false;
    for (let index = 0; index < entries.length; index += 1) {
      const fileName = entries[index];
      if (!fileName.endsWith(PART_SUFFIX)) {
        continue;
      }
      foundPart = true;
      InterruptedWavRecoveryService.recoverPart(sessionDirectory, fileName, summary, seekToStart);
    }
    if (foundPart) {
      InterruptedWavRecoveryService.writeSummary(sessionDirectory, summary);
    }
    return summary;
  }

  private static recoverPart(sessionDirectory: string, fileName: string,
    summary: SessionRecoverySummary, seekToStart: RecoverySeekOperation): void {
    const partPath = `${sessionDirectory}/${fileName}`;
    try {
      const size = fileIo.statSync(partPath).size;
      if (size === WAV_HEADER_BYTES) {
        fileIo.unlinkSync(partPath);
        summary.discardedEmptyParts.push(fileName);
        return;
      }
      const pcmBytes = size - WAV_HEADER_BYTES;
      if (pcmBytes <= 0 || pcmBytes > PCM_RECORDING_SEGMENT_BYTES || pcmBytes % BYTES_PER_SAMPLE !== 0) {
        throw new Error(`无效的 PCM 长度 ${pcmBytes}`);
      }

      const finalFileName = fileName.substring(0, fileName.length - '.part'.length);
      const finalPath = `${sessionDirectory}/${finalFileName}`;
      if (fileIo.accessSync(finalPath)) {
        throw new Error('目标 WAV 已存在，已保留原始 .part');
      }

      const output = fileIo.openSync(partPath, fileIo.OpenMode.READ_WRITE);
      try {
        seekToStart(output.fd);
        writeEntireBuffer(createPcmWavHeader(pcmBytes),
          (remaining: ArrayBuffer): number => fileIo.writeSync(output.fd, remaining));
      } catch (error) {
        try {
          fileIo.closeSync(output.fd);
        } catch (closeError) {
          // Preserve the header write failure and leave the original .part.
        }
        throw InterruptedWavRecoveryService.recoveryError(error);
      }
      syncAndClose(output.fd);
      publishPartFile(partPath, finalPath);

      const sampleCount = pcmBytes / BYTES_PER_SAMPLE;
      const evidence: RecoveredWavEvidence = {
        sourcePartFileName: fileName,
        fileName: finalFileName,
        firstSample: InterruptedWavRecoveryService.readFirstSample(fileName),
        pcmBytes: pcmBytes,
        sampleCount: sampleCount,
        durationMs: Math.round(sampleCount * 1000 / SAMPLE_RATE)
      };
      summary.recoveredFiles.push(evidence);
    } catch (error) {
      const failure: RecoveryFailureEvidence = {
        fileName: fileName,
        message: InterruptedWavRecoveryService.errorMessage(error)
      };
      summary.failures.push(failure);
    }
  }

  private static readFirstSample(fileName: string): number {
    const marker = '_first_';
    const markerIndex = fileName.indexOf(marker);
    const wavIndex = fileName.indexOf('.wav');
    if (markerIndex < 0 || wavIndex <= markerIndex + marker.length) {
      return -1;
    }
    const parsed = Number(fileName.substring(markerIndex + marker.length, wavIndex));
    return Number.isFinite(parsed) ? parsed : -1;
  }

  private static writeSummary(sessionDirectory: string, summary: SessionRecoverySummary): void {
    const summaryPath = `${sessionDirectory}/recovery_summary.json`;
    writeJsonAtomically(summaryPath, summary);
  }

  private static errorMessage(error: Object): string {
    return error instanceof Error ? error.message : JSON.stringify(error);
  }

  private static recoveryError(error: Object): Error {
    return error instanceof Error ? error : new Error(JSON.stringify(error));
  }
}
