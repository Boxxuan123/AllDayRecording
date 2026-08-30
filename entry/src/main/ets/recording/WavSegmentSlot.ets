import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { RecordingFile } from '../models/RecordingModels';
import { publishPartFile, syncAndClose } from '../shared/io/AtomicFileWriter';
import {
  PCM_BYTES_PER_SAMPLE,
  PCM_SAMPLE_RATE_HZ,
  createPcmWavHeader,
  writeEntireBuffer
} from '../shared/io/WavFormat';
import { pcmSegmentFileName } from './PcmRecordingContract';

export interface WavSegmentFileOperations {
  openForWrite(path: string): number;
  write(fd: number, buffer: ArrayBuffer): number;
  seekToStart(fd: number): void;
  syncAndClose(fd: number): void;
  publish(partPath: string, finalPath: string): void;
  statSize(path: string): number;
  close(fd: number): void;
  unlink(path: string): void;
}

class CoreWavSegmentFileOperations implements WavSegmentFileOperations {
  openForWrite(path: string): number {
    return fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC).fd;
  }

  write(fd: number, buffer: ArrayBuffer): number {
    return fileIo.writeSync(fd, buffer);
  }

  seekToStart(fd: number): void {
    fileIo.lseek(fd, 0, fileIo.WhenceType.SEEK_SET);
  }

  syncAndClose(fd: number): void {
    syncAndClose(fd);
  }

  publish(partPath: string, finalPath: string): void {
    publishPartFile(partPath, finalPath);
  }

  statSize(path: string): number {
    return fileIo.statSync(path).size;
  }

  close(fd: number): void {
    fileIo.closeSync(fd);
  }

  unlink(path: string): void {
    fileIo.unlinkSync(path);
  }
}

const CORE_WAV_FILE_OPERATIONS: WavSegmentFileOperations = new CoreWavSegmentFileOperations();

export class WavSegmentSlot {
  readonly index: number;
  readonly firstSample: number;
  readonly partPath: string;
  readonly finalPath: string;
  private fd: number = -1;
  private pcmBytes: number = 0;
  private operations: WavSegmentFileOperations;

  constructor(sessionDirectory: string, index: number, firstSample: number,
    operations: WavSegmentFileOperations = CORE_WAV_FILE_OPERATIONS) {
    this.index = index;
    this.firstSample = firstSample;
    this.operations = operations;
    const fileName = pcmSegmentFileName(index, firstSample);
    this.finalPath = `${sessionDirectory}/${fileName}`;
    this.partPath = `${this.finalPath}.part`;
    this.fd = this.operations.openForWrite(this.partPath);
    try {
      writeEntireBuffer(createPcmWavHeader(0),
        (remaining: ArrayBuffer): number => this.operations.write(this.fd, remaining));
    } catch (error) {
      this.closePreservingPart();
      throw slotError(error);
    }
  }

  getPcmBytes(): number {
    return this.pcmBytes;
  }

  write(buffer: ArrayBuffer): void {
    if (this.fd < 0) {
      throw new Error('WAV 文件槽已经关闭');
    }
    writeEntireBuffer(buffer, (remaining: ArrayBuffer): number => this.operations.write(this.fd, remaining));
    this.pcmBytes += buffer.byteLength;
  }

  finalize(): RecordingFile {
    if (this.fd < 0) {
      throw new Error('WAV 文件槽已经关闭');
    }
    try {
      this.operations.seekToStart(this.fd);
      writeEntireBuffer(createPcmWavHeader(this.pcmBytes),
        (remaining: ArrayBuffer): number => this.operations.write(this.fd, remaining));
      this.operations.syncAndClose(this.fd);
      this.fd = -1;
      this.operations.publish(this.partPath, this.finalPath);
      const size = this.operations.statSize(this.finalPath);
      const pathParts = this.finalPath.split('/');
      return {
        fileName: pathParts[pathParts.length - 1],
        path: this.finalPath,
        size: size,
        durationMs: Math.round(this.pcmBytes * 1000 / (PCM_SAMPLE_RATE_HZ * PCM_BYTES_PER_SAMPLE))
      };
    } catch (error) {
      this.closePreservingPart();
      throw new Error(`WAV 封口失败：${slotError(error).message}`);
    }
  }

  discard(): void {
    this.closePreservingPart();
    try {
      this.operations.unlink(this.partPath);
    } catch (error) {
      // The placeholder may already have been finalized or removed.
    }
  }

  closePreservingPart(): void {
    if (this.fd < 0) {
      return;
    }
    try {
      this.operations.close(this.fd);
    } catch (error) {
      // Preserve the original failure while leaving .part as interruption evidence.
    }
    this.fd = -1;
  }
}

function slotError(error: Object): Error {
  const businessError = error as BusinessError;
  if (businessError.code !== undefined) {
    return new Error(`${businessError.message || 'WAV 文件操作失败'}（${businessError.code}）`);
  }
  return error instanceof Error ? error : new Error('WAV 文件操作失败');
}
