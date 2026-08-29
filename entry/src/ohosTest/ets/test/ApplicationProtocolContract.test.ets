import { describe, it, expect } from '@ohos/hypium';
import {
  WATCH_SYNC_PROTOCOL_VERSION,
  exactWatchFileKey,
  legacyWatchFileKey
} from '../../../main/ets/sync/protocol/WatchFileSyncProtocol';

export default function applicationProtocolContractTest() {
  describe('ApplicationProtocolContract', () => {
    it('keepsVersionOneAndDistinctIdentityNamespaces', 0, () => {
      const exactKey = exactWatchFileKey('session/segment.wav', 32044);
      const legacyKey = legacyWatchFileKey('segment.wav', 32044);

      expect(WATCH_SYNC_PROTOCOL_VERSION).assertEqual(1);
      expect(exactKey.startsWith('e')).assertTrue();
      expect(legacyKey.startsWith('l')).assertTrue();
      expect(exactKey === legacyKey).assertFalse();
    });
  });
}
