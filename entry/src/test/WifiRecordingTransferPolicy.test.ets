import { describe, expect, it } from '@ohos/hypium';
import {
  isExactWifiRecordingMatch,
  isSafeWifiRecordingSourcePath,
  sanitizeWifiRecordingFileName
} from 'common';

export default function wifiRecordingTransferPolicyTest() {
  describe('WifiRecordingTransferPolicy', () => {
    it('acceptsOnlyRelativeAudioSourcePaths', 0, () => {
      expect(isSafeWifiRecordingSourcePath('pcm_session_1/segment_000001.wav')).assertTrue();
      expect(isSafeWifiRecordingSourcePath('session/audio.m4a')).assertTrue();
      expect(isSafeWifiRecordingSourcePath('/data/audio.wav')).assertFalse();
      expect(isSafeWifiRecordingSourcePath('../audio.wav')).assertFalse();
      expect(isSafeWifiRecordingSourcePath('session/summary.json')).assertFalse();
    });

    it('sanitizesReceivedFileNames', 0, () => {
      expect(sanitizeWifiRecordingFileName('segment 01/测试.wav')).assertEqual('segment_01___.wav');
      expect(sanitizeWifiRecordingFileName('segment_000001.wav')).assertEqual('segment_000001.wav');
    });

    it('skipsOnlyAnExactPathSizeAndHashMatch', 0, () => {
      const hash = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      const otherHash = '1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

      expect(isExactWifiRecordingMatch('session_a/segment.wav', 1024, hash,
        'session_a/segment.wav', 1024, hash.toUpperCase())).assertTrue();
      expect(isExactWifiRecordingMatch('session_a/segment.wav', 1024, hash,
        'session_b/segment.wav', 1024, hash)).assertFalse();
      expect(isExactWifiRecordingMatch('session_a/segment.wav', 1024, hash,
        'session_a/segment.wav', 1024, otherHash)).assertFalse();
    });
  });
}
