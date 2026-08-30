import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

export function createTestDirectory(label: string): string {
  const path = `/tmp/alldayrecording_${label}_${Date.now()}`;
  try {
    fileIo.mkdirSync(path);
    return path;
  } catch (error) {
    throw testFileError(error);
  }
}

export function ensureTestDirectory(path: string): void {
  try {
    if (!fileIo.accessSync(path)) {
      fileIo.mkdirSync(path);
    }
  } catch (error) {
    throw testFileError(error);
  }
}

export function writeTestText(path: string, content: string): void {
  let output: fileIo.File | undefined = undefined;
  try {
    output = fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(output.fd, content);
  } catch (error) {
    throw testFileError(error);
  } finally {
    if (output !== undefined) {
      closeTestFile(output.fd);
    }
  }
}

export function writeTestBytes(path: string, content: Uint8Array): void {
  let output: fileIo.File | undefined = undefined;
  try {
    output = fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(output.fd, content.buffer);
  } catch (error) {
    throw testFileError(error);
  } finally {
    if (output !== undefined) {
      closeTestFile(output.fd);
    }
  }
}

export function readTestBytes(path: string): Uint8Array {
  let input: fileIo.File | undefined = undefined;
  try {
    input = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    const size = fileIo.statSync(path).size;
    const buffer = new ArrayBuffer(size);
    const bytesRead = fileIo.readSync(input.fd, buffer);
    return new Uint8Array(buffer.slice(0, bytesRead));
  } catch (error) {
    throw testFileError(error);
  } finally {
    if (input !== undefined) {
      closeTestFile(input.fd);
    }
  }
}

export function readTestText(path: string): string {
  return util.TextDecoder.create('utf-8').decodeToString(readTestBytes(path));
}

export type TestDirectoryListOperation = (path: string) => Array<string>;

export function removeTestTree(path: string, listDirectory: TestDirectoryListOperation): void {
  try {
    if (!fileIo.accessSync(path)) {
      return;
    }
    const stat = fileIo.statSync(path);
    if (!stat.isDirectory()) {
      fileIo.unlinkSync(path);
      return;
    }
    const entries = listDirectory(path);
    for (let index = 0; index < entries.length; index += 1) {
      removeTestTree(`${path}/${entries[index]}`, listDirectory);
    }
    fileIo.rmdirSync(path);
  } catch (_) {
    // Previewer does not implement every CoreFileKit cleanup API. Cleanup must
    // never mask the assertion result from a filesystem characteristic test.
  }
}

function closeTestFile(fd: number): void {
  try {
    fileIo.closeSync(fd);
  } catch (error) {
    throw testFileError(error);
  }
}

function testFileError(error: Object): Error {
  return error instanceof Error ? error : new Error(JSON.stringify(error));
}
