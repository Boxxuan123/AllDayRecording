import { describe, expect, it } from '@ohos/hypium';
import {
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
  });
}
