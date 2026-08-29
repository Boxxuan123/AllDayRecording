import { fileIo } from '@kit.CoreFileKit';

const SAMPLE_RATE: number = 16000;
const CHANNEL_COUNT: number = 1;
const BITS_PER_SAMPLE: number = 16;
const BYTES_PER_SAMPLE: number = BITS_PER_SAMPLE / 8;
const WAV_HEADER_BYTES: number = 44;
const MAX_SEGMENT_PCM_BYTES: number = SAMPLE_RATE * BYTES_PER_SAMPLE * 60;
const SESSION_PREFIX: string = 'pcm_gap_test_';
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

export type WavBufferWriteOperation = (buffer: ArrayBuffer) => number;
export type RecoveryDirectoryListOperation = (path: string) => Array<string>;
export type RecoverySeekOperation = (fd: number) => void;

export function writeEntireWavBuffer(buffer: ArrayBuffer, writeOperation: WavBufferWriteOperation): void {
  let remaining = buffer;
  while (remaining.byteLength > 0) {
    const written = writeOperation(remaining);
    if (written <= 0) {
      throw new Error('写入 WAV 文件失败');
    }
    if (written === remaining.byteLength) {
      return;
    }
    remaining = remaining.slice(written);
  }
}

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
      if (!sessionName.startsWith(SESSION_PREFIX)) {
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
      if (pcmBytes <= 0 || pcmBytes > MAX_SEGMENT_PCM_BYTES || pcmBytes % BYTES_PER_SAMPLE !== 0) {
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
        InterruptedWavRecoveryService.writeAll(output.fd,
          InterruptedWavRecoveryService.createWavHeader(pcmBytes));
        fileIo.fsyncSync(output.fd);
      } finally {
        fileIo.closeSync(output.fd);
      }
      fileIo.renameSync(partPath, finalPath);

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
    const output = fileIo.openSync(summaryPath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(output.fd, JSON.stringify(summary, null, 2));
      fileIo.fsyncSync(output.fd);
    } finally {
      fileIo.closeSync(output.fd);
    }
  }

  private static createWavHeader(pcmBytes: number): ArrayBuffer {
    const buffer = new ArrayBuffer(WAV_HEADER_BYTES);
    const header = new Uint8Array(buffer);
    InterruptedWavRecoveryService.writeAscii(header, 0, 'RIFF');
    InterruptedWavRecoveryService.writeUint32Le(header, 4, 36 + pcmBytes);
    InterruptedWavRecoveryService.writeAscii(header, 8, 'WAVE');
    InterruptedWavRecoveryService.writeAscii(header, 12, 'fmt ');
    InterruptedWavRecoveryService.writeUint32Le(header, 16, 16);
    InterruptedWavRecoveryService.writeUint16Le(header, 20, 1);
    InterruptedWavRecoveryService.writeUint16Le(header, 22, CHANNEL_COUNT);
    InterruptedWavRecoveryService.writeUint32Le(header, 24, SAMPLE_RATE);
    InterruptedWavRecoveryService.writeUint32Le(header, 28, SAMPLE_RATE * CHANNEL_COUNT * BYTES_PER_SAMPLE);
    InterruptedWavRecoveryService.writeUint16Le(header, 32, CHANNEL_COUNT * BYTES_PER_SAMPLE);
    InterruptedWavRecoveryService.writeUint16Le(header, 34, BITS_PER_SAMPLE);
    InterruptedWavRecoveryService.writeAscii(header, 36, 'data');
    InterruptedWavRecoveryService.writeUint32Le(header, 40, pcmBytes);
    return buffer;
  }

  private static writeAscii(target: Uint8Array, offset: number, value: string): void {
    for (let index = 0; index < value.length; index += 1) {
      target[offset + index] = value.charCodeAt(index);
    }
  }

  private static writeUint16Le(target: Uint8Array, offset: number, value: number): void {
    target[offset] = value & 0xff;
    target[offset + 1] = (value >>> 8) & 0xff;
  }

  private static writeUint32Le(target: Uint8Array, offset: number, value: number): void {
    target[offset] = value & 0xff;
    target[offset + 1] = (value >>> 8) & 0xff;
    target[offset + 2] = (value >>> 16) & 0xff;
    target[offset + 3] = (value >>> 24) & 0xff;
  }

  private static writeAll(fd: number, buffer: ArrayBuffer): void {
    writeEntireWavBuffer(buffer, (remaining: ArrayBuffer): number => fileIo.writeSync(fd, remaining));
  }

  private static errorMessage(error: Object): string {
    return error instanceof Error ? error.message : JSON.stringify(error);
  }
}
