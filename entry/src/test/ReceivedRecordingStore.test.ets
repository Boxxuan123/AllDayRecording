import { describe, it, expect } from '@ohos/hypium';
import { ReceivedRecordingFile } from '../main/ets/models/RecordingModels';
import { ReceivedRecordingStore, SYNC_RECEIVE_DIRECTORY } from '../main/ets/services/ReceivedRecordingStore';
import { exactWatchFileKey } from '../main/ets/sync/protocol/WatchFileSyncProtocol';
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

function listFixture(entriesByDirectory: Map<string, Array<string>>): (path: string) => Array<string> {
  return (path: string): Array<string> => entriesByDirectory.get(path) ?? [];
}

export default function receivedRecordingStoreTest() {
  describe('ReceivedRecordingStore', () => {
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

        const store = new ReceivedRecordingStore(root, listDirectory, readTestText, writeTestText);

        expect(store.list().length).assertEqual(1);
        expect(store.list()[0].sourcePath).assertEqual('session_a/segment.wav');
        expect(store.knownFileKeys().length).assertEqual(1);
        expect(store.knownFileKeys()[0]).assertEqual(syncKey);
      } finally {
        removeTestTree(root, listDirectory);
      }
    });

    it('rebuildsListByScanningWhenIndexIsDamaged', 0, () => {
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

        const store = new ReceivedRecordingStore(root, listDirectory, readTestText, writeTestText);

        expect(store.list().length).assertEqual(1);
        expect(store.list()[0].fileName).assertEqual('scanned.wav');
        expect(store.list()[0].requestId).assertEqual('request_scan');
        const repaired = JSON.parse(readTestText(`${syncRoot}/received_index_v1.json`)) as Object;
        expect(repaired !== undefined).assertTrue();
      } finally {
        removeTestTree(root, listDirectory);
      }
    });

    it('returnsExistingRecordForDuplicatePath', 0, () => {
      const root = createTestDirectory('received_duplicate');
      const syncRoot = `${root}/${SYNC_RECEIVE_DIRECTORY}`;
      const listDirectory = listFixture(new Map<string, Array<string>>([
        [root, ['received_100.wav', SYNC_RECEIVE_DIRECTORY]],
        [syncRoot, ['received_index_v1.json']]
      ]));
      try {
        const path = `${root}/received_100.wav`;
        writeTestBytes(path, new Uint8Array([9, 10]));
        const store = new ReceivedRecordingStore(root, listDirectory, readTestText, writeTestText);
        const recording: ReceivedRecordingFile = {
          fileName: 'received_100.wav',
          path: path,
          size: 2,
          durationMs: 0,
          requestId: 'manual',
          sourcePath: '手表手动发送',
          receivedAt: 100
        };

        const first = store.record(recording);
        const second = store.record(recording);

        expect(first.path).assertEqual(second.path);
        expect(store.list().length).assertEqual(1);
      } finally {
        removeTestTree(root, listDirectory);
      }
    });
  });
}
