import { describe, expect, it } from '@ohos/hypium';
import {
  WIFI_SOURCE_ALREADY_ABSENT,
  WIFI_SOURCE_DELETED,
  WifiSourceCleanupFileInfo,
  WifiSourceCleanupFileSystem,
  WifiVerifiedSourceFile,
  deleteVerifiedWifiSource
} from 'common';

const MATCHING_HASH: string = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const OTHER_HASH: string = '1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

class FakeCleanupFileSystem implements WifiSourceCleanupFileSystem {
  fileExists: boolean = true;
  fileInfo: WifiSourceCleanupFileInfo = { size: 1024, isFile: true };
  unlinkedPaths: Array<string> = [];
  failUnlink: boolean = false;

  exists(_path: string): boolean {
    return this.fileExists;
  }

  stat(_path: string): WifiSourceCleanupFileInfo {
    return this.fileInfo;
  }

  unlink(path: string): void {
    if (this.failUnlink) {
      throw new Error('unlink failed');
    }
    this.unlinkedPaths.push(path);
  }
}

function source(path: string = '/files/session/segment.wav',
  relativePath: string = 'session/segment.wav'): WifiVerifiedSourceFile {
  return {
    fileName: 'segment.wav',
    path: path,
    relativePath: relativePath,
    size: 1024,
    sha256: MATCHING_HASH
  };
}

export default function wifiSyncedSourceCleanerTest() {
  describe('WifiSyncedSourceCleaner', () => {
    it('deletesOnlyTheExactVerifiedSource', 0, () => {
      const fileSystem = new FakeCleanupFileSystem();

      const result = deleteVerifiedWifiSource('/files', source(), MATCHING_HASH.toUpperCase(), fileSystem);

      expect(result).assertEqual(WIFI_SOURCE_DELETED);
      expect(fileSystem.unlinkedPaths.join('|')).assertEqual('/files/session/segment.wav');
    });

    it('treatsAnAlreadyMissingVerifiedSourceAsCleaned', 0, () => {
      const fileSystem = new FakeCleanupFileSystem();
      fileSystem.fileExists = false;

      const result = deleteVerifiedWifiSource('/files', source(), MATCHING_HASH, fileSystem);

      expect(result).assertEqual(WIFI_SOURCE_ALREADY_ABSENT);
      expect(fileSystem.unlinkedPaths.length).assertEqual(0);
    });

    it('retainsAFileWhenSizeOrContentChanged', 0, () => {
      const sizeChanged = new FakeCleanupFileSystem();
      sizeChanged.fileInfo = { size: 2048, isFile: true };
      let sizeRejected = false;
      let hashRejected = false;

      try {
        deleteVerifiedWifiSource('/files', source(), MATCHING_HASH, sizeChanged);
      } catch (error) {
        sizeRejected = true;
      }
      try {
        deleteVerifiedWifiSource('/files', source(), OTHER_HASH, new FakeCleanupFileSystem());
      } catch (error) {
        hashRejected = true;
      }

      expect(sizeRejected).assertTrue();
      expect(hashRejected).assertTrue();
      expect(sizeChanged.unlinkedPaths.length).assertEqual(0);
    });

    it('refusesPartTraversalAndOutsidePaths', 0, () => {
      const fileSystem = new FakeCleanupFileSystem();
      let partRejected = false;
      let traversalRejected = false;
      let outsideRejected = false;

      try {
        deleteVerifiedWifiSource('/files', source('/files/session/segment.wav.part',
          'session/segment.wav.part'), MATCHING_HASH, fileSystem);
      } catch (error) {
        partRejected = true;
      }
      try {
        deleteVerifiedWifiSource('/files', source('/files/../outside.wav', '../outside.wav'),
          MATCHING_HASH, fileSystem);
      } catch (error) {
        traversalRejected = true;
      }
      try {
        deleteVerifiedWifiSource('/files', source('/other/session/segment.wav'), MATCHING_HASH, fileSystem);
      } catch (error) {
        outsideRejected = true;
      }

      expect(partRejected).assertTrue();
      expect(traversalRejected).assertTrue();
      expect(outsideRejected).assertTrue();
      expect(fileSystem.unlinkedPaths.length).assertEqual(0);
    });

    it('surfacesUnlinkFailureWithoutReportingDeletion', 0, () => {
      const fileSystem = new FakeCleanupFileSystem();
      fileSystem.failUnlink = true;
      let rejected = false;

      try {
        deleteVerifiedWifiSource('/files', source(), MATCHING_HASH, fileSystem);
      } catch (error) {
        rejected = true;
      }

      expect(rejected).assertTrue();
      expect(fileSystem.unlinkedPaths.length).assertEqual(0);
    });
  });
}
