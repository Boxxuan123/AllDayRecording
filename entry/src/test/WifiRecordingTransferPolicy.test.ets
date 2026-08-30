import { describe, expect, it } from '@ohos/hypium';
import {
  WIFI_PHONE_TO_WATCH,
  WIFI_WATCH_TO_PHONE,
  WifiTransferSessionCredentials,
  buildWifiFrameAad,
  buildWifiFrameNonce,
  isExactWifiRecordingMatch,
  isSafeWifiRecordingSourcePath,
  isValidWifiTransferCredentials,
  wifiBytesToHex,
  wifiConstantTimeHexEqual,
  wifiHexToBytes,
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

    it('acceptsOnlyFreshOneTimeCredentialShapes', 0, () => {
      const now = 1000000;
      const valid: WifiTransferSessionCredentials = {
        batchToken: '00112233445566778899aabbccddeeff',
        temporaryKey: '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff',
        expiresAt: now + 180000
      };
      expect(isValidWifiTransferCredentials(valid, now)).assertTrue();
      expect(isValidWifiTransferCredentials({
        batchToken: valid.batchToken,
        temporaryKey: valid.temporaryKey,
        expiresAt: now
      }, now)).assertFalse();
      expect(isValidWifiTransferCredentials({
        batchToken: 'not-a-token',
        temporaryKey: valid.temporaryKey,
        expiresAt: valid.expiresAt
      }, now)).assertFalse();
    });

    it('bindsGcmNonceAndAadToDirectionFrameAndSequence', 0, () => {
      const batchToken = '00112233445566778899aabbccddeeff';
      const first = wifiBytesToHex(buildWifiFrameNonce(batchToken, WIFI_WATCH_TO_PHONE, 2, 88, 1));
      const next = wifiBytesToHex(buildWifiFrameNonce(batchToken, WIFI_WATCH_TO_PHONE, 2, 88, 2));
      const reverse = wifiBytesToHex(buildWifiFrameNonce(batchToken, WIFI_PHONE_TO_WATCH, 2, 88, 1));
      expect(first === next).assertFalse();
      expect(first === reverse).assertFalse();
      expect(wifiBytesToHex(wifiHexToBytes(first))).assertEqual(first);
      expect(wifiBytesToHex(buildWifiFrameAad(batchToken, WIFI_WATCH_TO_PHONE, 2, 88, 1)) ===
        wifiBytesToHex(buildWifiFrameAad(batchToken, WIFI_WATCH_TO_PHONE, 2, 88, 2))).assertFalse();
    });

    it('comparesAuthenticationProofsWithoutEarlyContentExit', 0, () => {
      expect(wifiConstantTimeHexEqual('001122', '001122')).assertTrue();
      expect(wifiConstantTimeHexEqual('001122', '001123')).assertFalse();
      expect(wifiConstantTimeHexEqual('001122', '00112200')).assertFalse();
    });
  });
}
