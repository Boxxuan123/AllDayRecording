import { describe, it, expect } from '@ohos/hypium';
import {
  WATCH_SYNC_PROTOCOL_VERSION,
  WATCH_SYNC_REQUEST,
  WatchSyncProtocolMessage,
  decodeWatchSyncMessage,
  encodeWatchSyncMessage,
  exactWatchFileKey,
  legacyWatchFileKey
} from '../main/ets/services/WatchFileSyncProtocol';

export default function watchSyncProtocolTest() {
  describe('WatchSyncProtocol', () => {
    it('roundTripsCurrentProtocolMessage', 0, () => {
      const original: WatchSyncProtocolMessage = {
        version: WATCH_SYNC_PROTOCOL_VERSION,
        type: WATCH_SYNC_REQUEST,
        requestId: 'request_001',
        knownFileKeys: ['e001', 'e002'],
        message: '手表同步'
      };

      const decoded = decodeWatchSyncMessage(encodeWatchSyncMessage(original));

      expect(decoded.version).assertEqual(WATCH_SYNC_PROTOCOL_VERSION);
      expect(decoded.type).assertEqual(WATCH_SYNC_REQUEST);
      expect(decoded.requestId).assertEqual('request_001');
      expect(decoded.knownFileKeys?.length).assertEqual(2);
      expect(decoded.message).assertEqual('手表同步');
    });

    it('rejectsUnsupportedProtocolVersion', 0, () => {
      const unsupported: WatchSyncProtocolMessage = {
        version: WATCH_SYNC_PROTOCOL_VERSION + 1,
        type: WATCH_SYNC_REQUEST,
        requestId: 'request_unsupported'
      };
      let rejected = false;

      try {
        decodeWatchSyncMessage(encodeWatchSyncMessage(unsupported));
      } catch (error) {
        rejected = true;
      }

      expect(rejected).assertTrue();
    });

    it('keepsExactAndLegacyIdentitySemantics', 0, () => {
      const firstPath = 'pcm_gap_test_100/segment_000001.wav';
      const secondPath = 'pcm_gap_test_200/segment_000001.wav';
      const fileName = 'segment_000001.wav';

      expect(exactWatchFileKey(firstPath, 32044)).assertEqual(exactWatchFileKey(firstPath, 32044));
      expect(exactWatchFileKey(firstPath, 32044) === exactWatchFileKey(secondPath, 32044)).assertFalse();
      expect(legacyWatchFileKey(fileName, 32044)).assertEqual(legacyWatchFileKey(fileName, 32044));
    });
  });
}
