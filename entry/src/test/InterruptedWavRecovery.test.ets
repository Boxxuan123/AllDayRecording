import { fileIo } from '@kit.CoreFileKit';
import { describe, it, expect } from '@ohos/hypium';
import {
  InterruptedWavRecoveryService
} from '../main/ets/services/InterruptedWavRecoveryService';
import { writeEntireBuffer } from 'common';
import {
  createTestDirectory,
  ensureTestDirectory,
  readTestBytes,
  removeTestTree,
  writeTestBytes
} from './support/TestFileSystem';

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

function partBytes(pcmBytes: number): Uint8Array {
  const bytes = new Uint8Array(44 + pcmBytes);
  for (let index = 0; index < pcmBytes; index += 1) {
    bytes[44 + index] = (index + 1) & 0xff;
  }
  return bytes;
}

function listSession(root: string, session: string, entries: Array<string>): (path: string) => Array<string> {
  return (path: string): Array<string> => {
    if (path === root) {
      return [session.substring(root.length + 1)];
    }
    if (path === session) {
      return entries;
    }
    return [];
  };
}

export default function interruptedWavRecoveryTest() {
  describe('InterruptedWavRecovery', () => {
    it('discardsHeaderOnlyPart', 0, () => {
      const root = createTestDirectory('wav_empty');
      const session = `${root}/pcm_gap_test_empty`;
      const listDirectory = listSession(root, session,
        ['segment_000001_first_000000000000.wav.part', 'recovery_summary.json']);
      try {
        ensureTestDirectory(session);
        const partPath = `${session}/segment_000001_first_000000000000.wav.part`;
        writeTestBytes(partPath, partBytes(0));

        const result = InterruptedWavRecoveryService.recover(root, listDirectory, (_fd: number): void => {});

        expect(result.discardedEmptyCount).assertEqual(1);
        expect(result.recoveredCount).assertEqual(0);
        expect(fileIo.accessSync(partPath)).assertFalse();
      } finally {
        removeTestTree(root, listDirectory);
      }
    });

    it('recoversValidPartWithExpectedWavHeaderAndPcm', 0, () => {
      const root = createTestDirectory('wav_valid');
      const session = `${root}/pcm_gap_test_valid`;
      const fileName = 'segment_000001_first_000000000000.wav';
      const listDirectory = listSession(root, session, [`${fileName}.part`, fileName, 'recovery_summary.json']);
      try {
        ensureTestDirectory(session);
        const partPath = `${session}/${fileName}.part`;
        const expected = partBytes(4);
        writeTestBytes(partPath, expected);

        const result = InterruptedWavRecoveryService.recover(root, listDirectory, (_fd: number): void => {});
        const finalPath = `${session}/${fileName}`;
        const actual = readTestBytes(finalPath);

        expect(result.recoveredCount).assertEqual(1);
        expect(result.failureCount).assertEqual(0);
        expect(fileIo.accessSync(partPath)).assertFalse();
        expect(ascii(actual, 0, 4)).assertEqual('RIFF');
        expect(uint32Le(actual, 4)).assertEqual(40);
        expect(ascii(actual, 8, 4)).assertEqual('WAVE');
        expect(ascii(actual, 12, 4)).assertEqual('fmt ');
        expect(uint16Le(actual, 20)).assertEqual(1);
        expect(uint16Le(actual, 22)).assertEqual(1);
        expect(uint32Le(actual, 24)).assertEqual(16000);
        expect(uint32Le(actual, 28)).assertEqual(32000);
        expect(uint16Le(actual, 34)).assertEqual(16);
        expect(ascii(actual, 36, 4)).assertEqual('data');
        expect(uint32Le(actual, 40)).assertEqual(4);
        expect(actual[44]).assertEqual(expected[44]);
        expect(actual[47]).assertEqual(expected[47]);
      } finally {
        removeTestTree(root, listDirectory);
      }
    });

    it('preservesOversizedPartAsFailureEvidence', 0, () => {
      const root = createTestDirectory('wav_oversized');
      const session = `${root}/pcm_gap_test_oversized`;
      const listDirectory = listSession(root, session,
        ['segment_000001_first_000000000000.wav.part', 'recovery_summary.json']);
      try {
        ensureTestDirectory(session);
        const partPath = `${session}/segment_000001_first_000000000000.wav.part`;
        writeTestBytes(partPath, partBytes(16000 * 2 * 60 + 2));

        const result = InterruptedWavRecoveryService.recover(root, listDirectory, (_fd: number): void => {});

        expect(result.failureCount).assertEqual(1);
        expect(result.recoveredCount).assertEqual(0);
        expect(fileIo.accessSync(partPath)).assertTrue();
      } finally {
        removeTestTree(root, listDirectory);
      }
    });

    it('retriesShortWritesUntilWholeBufferIsWritten', 0, () => {
      const buffer = new ArrayBuffer(10);
      let calls = 0;
      let totalWritten = 0;

      writeEntireBuffer(buffer, (remaining: ArrayBuffer): number => {
        calls += 1;
        const written = Math.min(3, remaining.byteLength);
        totalWritten += written;
        return written;
      });

      expect(calls).assertEqual(4);
      expect(totalWritten).assertEqual(10);
    });

    it('failsWhenWriterMakesNoProgress', 0, () => {
      let rejected = false;
      try {
        writeEntireBuffer(new ArrayBuffer(4), (remaining: ArrayBuffer): number => 0);
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });
  });
}
