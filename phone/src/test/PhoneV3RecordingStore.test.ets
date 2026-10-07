import { describe, it, expect } from '@ohos/hypium';
import { fileIo } from '@kit.CoreFileKit';
import { prepareComputerSessions } from '../main/ets/computer/ComputerSessionManifest';
import {
  ReceivedRecordingFile,
  exactWatchFileKey
} from 'common';
import {
  PhoneV3RecordingStore,
  SYNC_RECEIVE_DIRECTORY
} from '../main/ets/v3/runtime/PhoneV3RecordingStore';
import {
  createTestDirectory,
  ensureTestDirectory,
  readTestText,
  removeTestTree,
  writeTestBytes,
  writeTestText
} from './support/TestFileSystem';

interface ReceivedManifestEntryFixture {
  fileName: string;
  localPath: string;
  size: number;
  durationMs: number;
  requestId: string;
  sourcePath: string;
  receivedAt: number;
  syncKey?: string;
}

interface ReceivedManifestFixture {
  version: number;
  updatedAt: number;
  recordings: Array<ReceivedManifestEntryFixture>;
}

interface RecordingReceiptFixture {
  recordingId: string;
  sessionKey: string;
}

function listFixture(entriesByDirectory: Map<string, Array<string>>): (path: string) => Array<string> {
  return (path: string): Array<string> => (entriesByDirectory.get(path) ?? []).filter(
    (name: string): boolean => fileIo.accessSync(`${path}/${name}`));
}

export default function phoneV3RecordingStoreTest() {
  describe('PhoneV3RecordingStore', () => {
    it('loadsValidManifestAndIgnoresMissingEntry', 0, () => {
      const root = createTestDirectory('received_manifest');
      const syncRoot = `${root}/${SYNC_RECEIVE_DIRECTORY}`;
      const requestRoot = `${syncRoot}/request_a`;
      const listDirectory = listFixture(new Map<string, Array<string>>([
        [root, [SYNC_RECEIVE_DIRECTORY]],
        [syncRoot, ['received_index_v1.json', 'request_a']],
        [requestRoot, ['001_segment.wav']]
      ]));
      try {
        ensureTestDirectory(syncRoot);
        ensureTestDirectory(requestRoot);
        const audioPath = `${requestRoot}/001_segment.wav`;
        writeTestBytes(audioPath, new Uint8Array([1, 2, 3, 4]));
        writeTestBytes(`${root}/orphan.wav`, new Uint8Array([5, 6, 7, 8]));
        const syncKey = exactWatchFileKey('session_a/segment.wav', 4);
        const recordings: Array<ReceivedManifestEntryFixture> = [
          {
            fileName: 'segment.wav',
            localPath: `${SYNC_RECEIVE_DIRECTORY}/request_a/001_segment.wav`,
            size: 4,
            durationMs: 1,
            requestId: 'request_a',
            sourcePath: 'session_a/segment.wav',
            receivedAt: 100,
            syncKey: syncKey
          },
          {
            fileName: 'orphan.wav',
            localPath: 'orphan.wav',
            size: 4,
            durationMs: 1,
            requestId: 'old_root',
            sourcePath: 'old/orphan.wav',
            receivedAt: 95
          },
          {
            fileName: 'missing.wav',
            localPath: `${SYNC_RECEIVE_DIRECTORY}/request_a/missing.wav`,
            size: 8,
            durationMs: 1,
            requestId: 'request_a',
            sourcePath: 'session_a/missing.wav',
            receivedAt: 90
          }
        ];
        const fixture: ReceivedManifestFixture = {
          version: 1,
          updatedAt: 100,
          recordings: recordings
        };
        writeTestText(`${syncRoot}/received_index_v1.json`, JSON.stringify(fixture));

        const store = new PhoneV3RecordingStore(root, listDirectory, readTestText, writeTestText);

        expect(store.list().length).assertEqual(1);
        expect(store.list()[0].sourcePath).assertEqual('session_a/segment.wav');
        expect(store.knownFileKeys().length).assertEqual(0);
      } finally {
        removeTestTree(root, listDirectory);
      }
    });

    it('doesNotClaimUnverifiedAudioWhenIndexIsDamaged', 0, () => {
      const root = createTestDirectory('received_damaged');
      const syncRoot = `${root}/${SYNC_RECEIVE_DIRECTORY}`;
      const requestRoot = `${syncRoot}/request_scan`;
      const listDirectory = listFixture(new Map<string, Array<string>>([
        [root, [SYNC_RECEIVE_DIRECTORY]],
        [syncRoot, ['received_index_v1.json', 'request_scan']],
        [requestRoot, ['001_scanned.wav']]
      ]));
      try {
        ensureTestDirectory(syncRoot);
        ensureTestDirectory(requestRoot);
        writeTestBytes(`${requestRoot}/001_scanned.wav`, new Uint8Array([5, 6, 7, 8]));
        writeTestText(`${syncRoot}/received_index_v1.json`, '{damaged');

        const store = new PhoneV3RecordingStore(root, listDirectory, readTestText, writeTestText);

        expect(store.list().length).assertEqual(0);
        expect(fileIo.accessSync(`${requestRoot}/001_scanned.wav`)).assertTrue();
      } finally {
        removeTestTree(root, listDirectory);
      }
    });

    it('ignoresRootAudioUntilV3RecordsItAndDeduplicatesItsPath', 0, () => {
      const root = createTestDirectory('v3_recorded_path');
      const syncRoot = `${root}/${SYNC_RECEIVE_DIRECTORY}`;
      const listDirectory = listFixture(new Map<string, Array<string>>([
        [root, ['orphan.wav', SYNC_RECEIVE_DIRECTORY]],
        [syncRoot, ['received_index_v1.json']]
      ]));
      try {
        const path = `${root}/orphan.wav`;
        writeTestBytes(path, new Uint8Array([9, 10]));
        const store = new PhoneV3RecordingStore(root, listDirectory, readTestText, writeTestText);
        expect(store.list().length).assertEqual(0);
        const recording: ReceivedRecordingFile = {
          fileName: 'orphan.wav',
          path: path,
          size: 2,
          durationMs: 0,
          requestId: 'v3_test',
          sourcePath: 'session/orphan.wav',
          receivedAt: 100
        };

        const first = store.record(recording, 'a'.repeat(64));
        const second = store.record(recording, 'a'.repeat(64));

        expect(first.path).assertEqual(second.path);
        expect(store.list().length).assertEqual(1);
      } finally {
        removeTestTree(root, listDirectory);
      }
    });

    it('replacesSameWifiIdentityWithNewVerifiedCopy', 0, () => {
      const root = createTestDirectory('received_wifi_replace');
      const syncRoot = `${root}/${SYNC_RECEIVE_DIRECTORY}`;
      const listDirectory = listFixture(new Map<string, Array<string>>([
        [root, ['old.wav', 'new.wav', SYNC_RECEIVE_DIRECTORY]],
        [syncRoot, ['received_index_v1.json']]
      ]));
      try {
        const oldPath = `${root}/old.wav`;
        const newPath = `${root}/new.wav`;
        writeTestBytes(oldPath, new Uint8Array([1, 2]));
        writeTestBytes(newPath, new Uint8Array([3, 4]));
        const store = new PhoneV3RecordingStore(root, listDirectory, readTestText, writeTestText);
        const syncKey = exactWatchFileKey('session_a/segment.wav', 2);
        const oldRecording: ReceivedRecordingFile = {
          fileName: 'segment.wav',
          path: oldPath,
          size: 2,
          durationMs: 0,
          requestId: 'wifi_old',
          sourcePath: 'session_a/segment.wav',
          receivedAt: 100,
          syncKey: syncKey
        };
        const newRecording: ReceivedRecordingFile = {
          fileName: 'segment.wav',
          path: newPath,
          size: 2,
          durationMs: 0,
          requestId: 'wifi_new',
          sourcePath: 'session_a/segment.wav',
          receivedAt: 200,
          syncKey: syncKey
        };

        store.record(oldRecording, 'a'.repeat(64));
        const stored = store.recordVerified(newRecording, 'b'.repeat(64));

        expect(stored.path).assertEqual(newPath);
        expect(store.list().length).assertEqual(1);
        expect(store.findWifiExisting('session_a/segment.wav', 2)?.path).assertEqual(newPath);
      } finally {
        removeTestTree(root, listDirectory);
      }
    });

    it('doesNotCommitOrAcknowledgeWhenReceiptWriteFails', 0, () => {
      const root = createTestDirectory('receipt_failure');
      const syncRoot = `${root}/${SYNC_RECEIVE_DIRECTORY}`;
      const requestRoot = `${syncRoot}/request_failure`;
      const path = `${requestRoot}/001_segment.wav`;
      const listDirectory = listFixture(new Map<string, Array<string>>([
        [syncRoot, ['request_failure']], [requestRoot, ['001_segment.wav']]
      ]));
      try {
        ensureTestDirectory(syncRoot);
        ensureTestDirectory(requestRoot);
        writeTestBytes(path, new Uint8Array([1, 2, 3, 4]));
        const store = new PhoneV3RecordingStore(root, listDirectory, readTestText,
          (target: string, content: string): void => {
            if (target.endsWith('.receipt.json')) { throw new Error('disk full'); }
            writeTestText(target, content);
          });
        const recording: ReceivedRecordingFile = {
          fileName: 'segment.wav', path: path, size: 4, durationMs: 0,
          requestId: 'request_failure', sourcePath: 'session_a/segment.wav',
          receivedAt: 100, syncKey: exactWatchFileKey('session_a/segment.wav', 4)
        };
        let failed = false;
        try { store.record(recording, 'a'.repeat(64)); }
        catch (error) { failed = true; }
        expect(failed).assertTrue();
        expect(store.list().length).assertEqual(0);
        const restarted = new PhoneV3RecordingStore(root, listDirectory, readTestText, writeTestText);
        expect(restarted.findWifiExisting(recording.sourcePath, recording.size) === undefined).assertTrue();
      } finally {
        removeTestTree(root, listDirectory);
      }
    });

    it('recoversDurableReceiptBeforeAckAndDeduplicatesRetry', 0, () => {
      const root = createTestDirectory('receipt_recovery');
      const syncRoot = `${root}/${SYNC_RECEIVE_DIRECTORY}`;
      const requestRoot = `${syncRoot}/request_recovery`;
      const path = `${requestRoot}/001_segment.wav`;
      const listDirectory = listFixture(new Map<string, Array<string>>([
        [syncRoot, ['request_recovery']],
        [requestRoot, ['001_segment.wav', '001_segment.wav.receipt.json']]
      ]));
      try {
        ensureTestDirectory(syncRoot);
        ensureTestDirectory(requestRoot);
        writeTestBytes(path, new Uint8Array([1, 2, 3, 4]));
        const recording: ReceivedRecordingFile = {
          fileName: 'segment.wav', path: path, size: 4, durationMs: 0,
          requestId: 'request_recovery', sourcePath: 'original_session/segment.wav',
          receivedAt: 100, syncKey: exactWatchFileKey('original_session/segment.wav', 4)
        };
        const failIndex = (target: string, content: string): void => {
          if (target.endsWith('received_index_v1.json')) { throw new Error('index failed'); }
          writeTestText(target, content);
        };
        const first = new PhoneV3RecordingStore(root, listDirectory, readTestText, failIndex);
        first.record(recording, 'a'.repeat(64)); // Crash before ACK: only the sidecar survives.
        const restarted = new PhoneV3RecordingStore(root, listDirectory, readTestText, writeTestText);
        const recovered = restarted.findWifiExisting(recording.sourcePath, recording.size);
        expect(recovered?.sourcePath).assertEqual('original_session/segment.wav');
        expect(recovered?.sha256).assertEqual('a'.repeat(64));
        restarted.record(recording, 'a'.repeat(64));
        expect(restarted.list().length).assertEqual(1);
        const afterAckRestart = new PhoneV3RecordingStore(root, listDirectory, readTestText, writeTestText);
        expect(afterAckRestart.list().length).assertEqual(1);
        expect(afterAckRestart.list()[0].sourcePath).assertEqual('original_session/segment.wav');
        expect(afterAckRestart.knownFileKeys().length).assertEqual(1);
      } finally {
        removeTestTree(root, listDirectory);
      }
    });

    it('buildsComputerManifestFromReceiptAfterAcknowledgedRestart', 0, () => {
      const root = createTestDirectory('receipt_manifest_restart');
      const syncRoot = `${root}/${SYNC_RECEIVE_DIRECTORY}`;
      const requestRoot = `${syncRoot}/request_manifest`;
      const fileName = 'segment_000001_first_000000.wav';
      const path = `${requestRoot}/${fileName}`;
      const source = `pcm_session_1760000000000/${fileName}`;
      const listDirectory = listFixture(new Map<string, Array<string>>([
        [syncRoot, ['request_manifest']],
        [requestRoot, [fileName, `${fileName}.receipt.json`]]
      ]));
      try {
        ensureTestDirectory(syncRoot);
        ensureTestDirectory(requestRoot);
        writeTestBytes(path, new Uint8Array(46));
        const recording: ReceivedRecordingFile = {
          fileName: fileName, path: path, size: 46, durationMs: 1,
          requestId: 'request_manifest', sourcePath: source, receivedAt: 100,
          syncKey: exactWatchFileKey(source, 46)
        };
        const store = new PhoneV3RecordingStore(root, listDirectory, readTestText, writeTestText);
        store.record(recording, 'a'.repeat(64));
        const receipt = JSON.parse(readTestText(`${path}.receipt.json`)) as RecordingReceiptFixture;
        expect(receipt.sessionKey).assertEqual('pcm_session_1760000000000');
        expect(receipt.recordingId).assertEqual(exactWatchFileKey(source, 46));
        const restarted = new PhoneV3RecordingStore(root, listDirectory, readTestText, writeTestText);
        const sessions = prepareComputerSessions(restarted.list());
        expect(sessions.length).assertEqual(1);
        const recoveredReceipt = JSON.parse(readTestText(`${path}.receipt.json`)) as RecordingReceiptFixture;
        expect(recoveredReceipt.sessionKey).assertEqual('pcm_session_1760000000000');
        expect(sessions[0].manifest.sessionKey).assertEqual('watch-session:1760000000000');
        expect(sessions[0].manifest.chunks.length).assertEqual(1);
        expect(sessions[0].recordings[0].sourcePath).assertEqual(source);
        restarted.record(recording, 'a'.repeat(64));
        expect(restarted.list().length).assertEqual(1);
        const retried = prepareComputerSessions(restarted.list());
        expect(retried.length).assertEqual(1);
        expect(retried[0].manifest.sessionKey).assertEqual(sessions[0].manifest.sessionKey);
      } finally { removeTestTree(root, listDirectory); }
    });

    it('deletesAudioFilesAndRemovesThemFromManifest', 0, () => {
      const root = createTestDirectory('received_delete');
      const syncRoot = `${root}/${SYNC_RECEIVE_DIRECTORY}`;
      const requestRoot = `${syncRoot}/request_delete`;
      const listDirectory = listFixture(new Map<string, Array<string>>([
        [root, [SYNC_RECEIVE_DIRECTORY]],
        [syncRoot, ['received_index_v1.json', 'request_delete']],
        [requestRoot, ['001_first.wav', '002_second.wav']]
      ]));
      try {
        ensureTestDirectory(syncRoot);
        ensureTestDirectory(requestRoot);
        const firstPath = `${requestRoot}/001_first.wav`;
        const secondPath = `${requestRoot}/002_second.wav`;
        writeTestBytes(firstPath, new Uint8Array([1, 2, 3, 4]));
        writeTestBytes(secondPath, new Uint8Array([5, 6, 7, 8]));
        const fixture: ReceivedManifestFixture = {
          version: 1,
          updatedAt: 100,
          recordings: [
            {
              fileName: 'first.wav',
              localPath: `${SYNC_RECEIVE_DIRECTORY}/request_delete/001_first.wav`,
              size: 4,
              durationMs: 1,
              requestId: 'request_delete',
              sourcePath: 'session/segment_000001_first.wav',
              receivedAt: 100
            },
            {
              fileName: 'second.wav',
              localPath: `${SYNC_RECEIVE_DIRECTORY}/request_delete/002_second.wav`,
              size: 4,
              durationMs: 1,
              requestId: 'request_delete',
              sourcePath: 'session/segment_000002_second.wav',
              receivedAt: 101
            }
          ]
        };
        writeTestText(`${syncRoot}/received_index_v1.json`, JSON.stringify(fixture));
        const store = new PhoneV3RecordingStore(root, listDirectory, readTestText, writeTestText);

        const deletedCount = store.deleteRecordings(store.list());

        expect(deletedCount).assertEqual(2);
        expect(store.list().length).assertEqual(0);
        expect(fileIo.accessSync(firstPath)).assertFalse();
        expect(fileIo.accessSync(secondPath)).assertFalse();
        const manifest = JSON.parse(readTestText(`${syncRoot}/received_index_v1.json`)) as ReceivedManifestFixture;
        expect(manifest.recordings.length).assertEqual(0);
      } finally {
        removeTestTree(root, listDirectory);
      }
    });
  });
}
