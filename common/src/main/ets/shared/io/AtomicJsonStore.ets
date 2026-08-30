import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { writeBufferAtomically } from './AtomicFileWriter';

export const JSON_LOAD_MISSING: string = 'missing';
export const JSON_LOAD_SUCCESS: string = 'success';
export const JSON_LOAD_INVALID_VERSION: string = 'invalid_version';
export const JSON_LOAD_INVALID_CONTENT: string = 'invalid_content';
export const JSON_LOAD_DAMAGED: string = 'damaged';

export interface VersionedJsonDocument {
  version: number;
}

export interface VersionedJsonLoadResult<T> {
  status: string;
  value?: T;
}

export type VersionedJsonValidator<T> = (document: T) => boolean;
export type JsonFileExistsOperation = (path: string) => boolean;
export type JsonTextReadOperation = (path: string) => string;
export type JsonTextWriteOperation = (path: string, content: string) => void;

function defaultExists(path: string): boolean {
  try {
    return fileIo.accessSync(path);
  } catch (error) {
    throw jsonFileError(error);
  }
}

function defaultReadText(path: string): string {
  try {
    return fileIo.readTextSync(path);
  } catch (error) {
    throw jsonFileError(error);
  }
}

function defaultWriteText(path: string, content: string): void {
  const encoded = util.TextEncoder.create('utf-8').encodeInto(content);
  const buffer = encoded.buffer.slice(encoded.byteOffset, encoded.byteOffset + encoded.byteLength);
  writeBufferAtomically(path, buffer);
}

export function loadVersionedJson<T extends VersionedJsonDocument>(path: string, expectedVersion: number,
  validator: VersionedJsonValidator<T>, exists: JsonFileExistsOperation = defaultExists,
  readText: JsonTextReadOperation = defaultReadText): VersionedJsonLoadResult<T> {
  try {
    if (!exists(path)) {
      return { status: JSON_LOAD_MISSING };
    }
    const document = JSON.parse(readText(path)) as T;
    if (document.version !== expectedVersion) {
      return { status: JSON_LOAD_INVALID_VERSION };
    }
    if (!validator(document)) {
      return { status: JSON_LOAD_INVALID_CONTENT };
    }
    return {
      status: JSON_LOAD_SUCCESS,
      value: document
    };
  } catch (error) {
    return { status: JSON_LOAD_DAMAGED };
  }
}

export function writeJsonAtomically(path: string, document: Object,
  writeText: JsonTextWriteOperation = defaultWriteText): void {
  writeText(path, JSON.stringify(document, null, 2));
}

export function writeVersionedJson<T extends VersionedJsonDocument>(path: string, expectedVersion: number,
  document: T, validator: VersionedJsonValidator<T>,
  writeText: JsonTextWriteOperation = defaultWriteText): void {
  if (document.version !== expectedVersion || !validator(document)) {
    throw new Error('JSON 清单版本或内容无效');
  }
  writeJsonAtomically(path, document, writeText);
}

function jsonFileError(error: Object): Error {
  return error instanceof Error ? error : new Error(JSON.stringify(error));
}
