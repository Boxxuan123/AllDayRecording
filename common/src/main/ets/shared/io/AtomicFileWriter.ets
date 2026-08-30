import { fileIo } from '@kit.CoreFileKit';
import { writeEntireBuffer } from './WavFormat';

export interface AtomicFileOperations {
  openForWrite(path: string): number;
  openForSync(path: string): number;
  write(fd: number, buffer: ArrayBuffer): number;
  sync(fd: number): void;
  close(fd: number): void;
  rename(sourcePath: string, targetPath: string): void;
  copy(sourceFd: number, targetPath: string): void;
}

class CoreAtomicFileOperations implements AtomicFileOperations {
  openForWrite(path: string): number {
    try {
      return fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC).fd;
    } catch (error) {
      throw fileError(error);
    }
  }

  openForSync(path: string): number {
    try {
      return fileIo.openSync(path, fileIo.OpenMode.READ_WRITE).fd;
    } catch (error) {
      throw fileError(error);
    }
  }

  write(fd: number, buffer: ArrayBuffer): number {
    try {
      return fileIo.writeSync(fd, buffer);
    } catch (error) {
      throw fileError(error);
    }
  }

  sync(fd: number): void {
    try {
      fileIo.fsyncSync(fd);
    } catch (error) {
      throw fileError(error);
    }
  }

  close(fd: number): void {
    try {
      fileIo.closeSync(fd);
    } catch (error) {
      throw fileError(error);
    }
  }

  rename(sourcePath: string, targetPath: string): void {
    try {
      fileIo.renameSync(sourcePath, targetPath);
    } catch (error) {
      throw fileError(error);
    }
  }

  copy(sourceFd: number, targetPath: string): void {
    try {
      fileIo.copyFileSync(sourceFd, targetPath);
    } catch (error) {
      throw fileError(error);
    }
  }
}

const CORE_FILE_OPERATIONS: AtomicFileOperations = new CoreAtomicFileOperations();

export function syncAndClose(fd: number,
  operations: AtomicFileOperations = CORE_FILE_OPERATIONS): void {
  let syncError: Error | undefined = undefined;
  try {
    operations.sync(fd);
  } catch (error) {
    syncError = fileError(error);
  }

  let closeError: Error | undefined = undefined;
  try {
    operations.close(fd);
  } catch (error) {
    closeError = fileError(error);
  }

  if (syncError !== undefined) {
    throw syncError;
  }
  if (closeError !== undefined) {
    throw closeError;
  }
}

export function publishPartFile(partPath: string, finalPath: string,
  operations: AtomicFileOperations = CORE_FILE_OPERATIONS): void {
  operations.rename(partPath, finalPath);
}

export function writeBufferAtomically(finalPath: string, buffer: ArrayBuffer,
  operations: AtomicFileOperations = CORE_FILE_OPERATIONS): void {
  const partPath = `${finalPath}.part`;
  const fd = operations.openForWrite(partPath);
  try {
    writeEntireBuffer(buffer, (remaining: ArrayBuffer): number => operations.write(fd, remaining));
  } catch (error) {
    try {
      operations.close(fd);
    } catch (closeError) {
      // Preserve the write failure and leave the .part file as evidence.
    }
    throw fileError(error);
  }
  syncAndClose(fd, operations);
  publishPartFile(partPath, finalPath, operations);
}

function fileError(error: Object): Error {
  return error instanceof Error ? error : new Error(JSON.stringify(error));
}

export function copyFileAtomically(sourceFd: number, finalPath: string,
  operations: AtomicFileOperations = CORE_FILE_OPERATIONS): void {
  const partPath = `${finalPath}.part`;
  operations.copy(sourceFd, partPath);
  const copiedFd = operations.openForSync(partPath);
  syncAndClose(copiedFd, operations);
  publishPartFile(partPath, finalPath, operations);
}
