import { describe, it, expect } from '@ohos/hypium';
import {
  WATCH_SYNC_PROTOCOL_VERSION,
  exactWatchFileKey
} from 'common';

export default function applicationProtocolContractTest() {
  describe('ApplicationProtocolContract', () => {
    it('keepsVersionOneAndExactIdentityNamespace', 0, () => {
      const exactKey = exactWatchFileKey('session/segment.wav', 32044);

      expect(WATCH_SYNC_PROTOCOL_VERSION).assertEqual(1);
      expect(exactKey.startsWith('e')).assertTrue();
    });
  });
}
