import { describe, it, expect } from '@ohos/hypium';
import { fileIo } from '@kit.CoreFileKit';
import {
  AtomicFileOperations,
  JSON_LOAD_DAMAGED,
  JSON_LOAD_INVALID_CONTENT,
  JSON_LOAD_INVALID_VERSION,
  JSON_LOAD_MISSING,
  JSON_LOAD_SUCCESS,
  VersionedJsonDocument,
  WAV_HEADER_BYTES,
  copyFileAtomically,
  createPcmWavHeader,
  loadVersionedJson,
  writeBufferAtomically,
  writeJsonAtomically,
  writeVersionedJson
} from 'common';
import {
  createTestDirectory,
  readTestText,
  removeTestTree
} from './support/TestFileSystem';

class FakeAtomicFileOperations implements AtomicFileOperations {
  events: Array<string> = [];
  maxWriteBytes: number = 1024;
  failSync: boolean = false;
  failClose: boolean = false;

  openForWrite(path: string): number {
    this.events.push(`open_write:${path}`);
    return 11;
  }

  openForSync(path: string): number {
    this.events.push(`open_sync:${path}`);
    return 12;
  }

  write(fd: number, buffer: ArrayBuffer): number {
    this.events.push(`write:${fd}:${buffer.byteLength}`);
    return Math.min(this.maxWriteBytes, buffer.byteLength);
  }

  sync(fd: number): void {
    this.events.push(`sync:${fd}`);
    if (this.failSync) {
      throw new Error('sync failed');
    }
  }

  close(fd: number): void {
    this.events.push(`close:${fd}`);
    if (this.failClose) {
      throw new Error('close failed');
    }
  }

  rename(sourcePath: string, targetPath: string): void {
    this.events.push(`rename:${sourcePath}:${targetPath}`);
  }

  copy(sourceFd: number, targetPath: string): void {
    this.events.push(`copy:${sourceFd}:${targetPath}`);
  }
}

interface JsonFixture extends VersionedJsonDocument {
  items: Array<string>;
}

interface AtomicJsonFixture {
  value: number;
}

function validJsonFixture(document: JsonFixture): boolean {
  return Array.isArray(document.items);
}

function ascii(bytes: Uint8Array, offset: number, length: number): string {
  let value = '';
  for (let index = 0; index < length; index += 1) {
    value += String.fromCharCode(bytes[offset + index]);
  }
  return value;
}

function uint16Le(bytes: Uint8Array, offset: number): number {
  return bytes[offset] | (bytes[offset + 1] << 8);
}

function uint32Le(bytes: Uint8Array, offset: number): number {
  return (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24)) >>> 0;
}

export default function sharedIoTest() {
  describe('WavFormat', () => {
    it('createsExpectedPcmHeader', 0, () => {
      const header = new Uint8Array(createPcmWavHeader(32000));

      expect(header.length).assertEqual(WAV_HEADER_BYTES);
      expect(ascii(header, 0, 4)).assertEqual('RIFF');
      expect(uint32Le(header, 4)).assertEqual(32036);
      expect(ascii(header, 8, 4)).assertEqual('WAVE');
      expect(ascii(header, 12, 4)).assertEqual('fmt ');
      expect(uint32Le(header, 16)).assertEqual(16);
      expect(uint16Le(header, 20)).assertEqual(1);
      expect(uint16Le(header, 22)).assertEqual(1);
      expect(uint32Le(header, 24)).assertEqual(16000);
      expect(uint32Le(header, 28)).assertEqual(32000);
      expect(uint16Le(header, 32)).assertEqual(2);
      expect(uint16Le(header, 34)).assertEqual(16);
      expect(ascii(header, 36, 4)).assertEqual('data');
      expect(uint32Le(header, 40)).assertEqual(32000);
    });
  });

  describe('AtomicFileWriter', () => {
    it('writesSyncsClosesAndPublishesInOrder', 0, () => {
      const operations = new FakeAtomicFileOperations();
      operations.maxWriteBytes = 2;

      writeBufferAtomically('/files/state.json', new ArrayBuffer(5), operations);

      expect(operations.events.join('|')).assertEqual(
        'open_write:/files/state.json.part|write:11:5|write:11:3|write:11:1|' +
        'sync:11|close:11|rename:/files/state.json.part:/files/state.json');
    });

    it('closesAndDoesNotPublishAfterSyncFailure', 0, () => {
      const operations = new FakeAtomicFileOperations();
      operations.failSync = true;
      let rejected = false;

      try {
        writeBufferAtomically('/files/state.json', new ArrayBuffer(2), operations);
      } catch (error) {
        rejected = true;
      }

      expect(rejected).assertTrue();
      expect(operations.events.join('|')).assertEqual(
        'open_write:/files/state.json.part|write:11:2|sync:11|close:11');
    });

    it('doesNotPublishAfterCloseFailure', 0, () => {
      const operations = new FakeAtomicFileOperations();
      operations.failClose = true;
      let rejected = false;

      try {
        writeBufferAtomically('/files/state.json', new ArrayBuffer(2), operations);
      } catch (error) {
        rejected = true;
      }

      expect(rejected).assertTrue();
      expect(operations.events.join('|')).assertEqual(
        'open_write:/files/state.json.part|write:11:2|sync:11|close:11');
    });

    it('copiesSyncsClosesAndPublishesInOrder', 0, () => {
      const operations = new FakeAtomicFileOperations();

      copyFileAtomically(7, '/files/received.wav', operations);

      expect(operations.events.join('|')).assertEqual(
        'copy:7:/files/received.wav.part|open_sync:/files/received.wav.part|' +
        'sync:12|close:12|rename:/files/received.wav.part:/files/received.wav');
    });
  });

  describe('AtomicJsonStore', () => {
    it('distinguishesMissingDamagedVersionAndContent', 0, () => {
      const missing = loadVersionedJson<JsonFixture>('/missing', 1, validJsonFixture,
        (path: string): boolean => false, (path: string): string => '');
      const damaged = loadVersionedJson<JsonFixture>('/damaged', 1, validJsonFixture,
        (path: string): boolean => true, (path: string): string => '{damaged');
      const invalidVersion = loadVersionedJson<JsonFixture>('/version', 1, validJsonFixture,
        (path: string): boolean => true, (path: string): string => '{"version":2,"items":[]}');
      const invalidContent = loadVersionedJson<JsonFixture>('/content', 1, validJsonFixture,
        (path: string): boolean => true, (path: string): string => '{"version":1}');

      expect(missing.status).assertEqual(JSON_LOAD_MISSING);
      expect(damaged.status).assertEqual(JSON_LOAD_DAMAGED);
      expect(invalidVersion.status).assertEqual(JSON_LOAD_INVALID_VERSION);
      expect(invalidContent.status).assertEqual(JSON_LOAD_INVALID_CONTENT);
    });

    it('loadsAndWritesTheSameVersionedShape', 0, () => {
      const loaded = loadVersionedJson<JsonFixture>('/valid', 1, validJsonFixture,
        (path: string): boolean => true,
        (path: string): string => '{"version":1,"items":["a","b"]}');
      let writtenPath = '';
      let writtenText = '';
      const fixture: JsonFixture = {
        version: 1,
        items: ['a', 'b']
      };

      writeVersionedJson<JsonFixture>('/valid', 1, fixture, validJsonFixture,
        (path: string, content: string): void => {
          writtenPath = path;
          writtenText = content;
        });

      expect(loaded.status).assertEqual(JSON_LOAD_SUCCESS);
      expect(loaded.value?.items.length).assertEqual(2);
      expect(writtenPath).assertEqual('/valid');
      expect(writtenText).assertEqual(JSON.stringify(fixture, null, 2));
    });

    it('atomicallyReplacesAnExistingJsonFile', 0, () => {
      const root = createTestDirectory('atomic_json_replace');
      const path = `${root}/state.json`;
      const listDirectory = (directory: string): Array<string> =>
        directory === root ? ['state.json', 'state.json.part'] : [];
      const first: AtomicJsonFixture = { value: 1 };
      const second: AtomicJsonFixture = { value: 2 };
      try {
        writeJsonAtomically(path, first);
        writeJsonAtomically(path, second);

        expect(readTestText(path)).assertEqual(JSON.stringify(second, null, 2));
        expect(fileIo.accessSync(`${path}.part`)).assertFalse();
      } finally {
        removeTestTree(root, listDirectory);
      }
    });
  });
}
