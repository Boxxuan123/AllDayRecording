import { describe, expect, it } from '@ohos/hypium';
import { ReceivedRecordingFile, WAV_HEADER_BYTES } from 'common';
import { prepareComputerSessions } from '../main/ets/computer/ComputerSessionManifest';
import { PhoneSessionCompletionRecord } from '../main/ets/v3/domain/PhoneV3Models';

function recording(sourcePath: string, fileName: string, receivedAt: number,
  samples: number): ReceivedRecordingFile {
  return {
    fileName: fileName,
    path: `/phone/${receivedAt}_${fileName}`,
    size: WAV_HEADER_BYTES + samples * 2,
    durationMs: 0,
    requestId: 'request',
    sourcePath: sourcePath,
    receivedAt: receivedAt
  };
}

export default function computerSessionManifestTest() {
  describe('ComputerSessionManifest', () => {
    it('requiresFinalEvidenceEvenWhenFirstChunkIsContinuous', 0, () => {
      const startedAt = 1788000000000;
      const first = recording(`pcm_gap_test_${startedAt}/segment_000001_first_000000000000.wav`,
        'segment_000001_first_000000000000.wav', 1, 16000);
      const legacy: PhoneSessionCompletionRecord = { sessionKey: `watch-session:${startedAt}`,
        source: 'legacy_user_confirmed', completedSegments: 2, totalSamples: 32000,
        confirmedAt: 1788000001000, manifestSha256: '' };
      expect(prepareComputerSessions([first])[0].canCommit()).assertFalse();
      expect(prepareComputerSessions([first], 'Asia/Singapore', [legacy])[0].canCommit()).assertFalse();
      const second = recording(`pcm_gap_test_${startedAt}/segment_000002_first_000000016000.wav`,
        'segment_000002_first_000000016000.wav', 2, 16000);
      expect(prepareComputerSessions([first, second], 'Asia/Singapore', [legacy])[0].canCommit()).assertTrue();
      const late = recording(`pcm_gap_test_${startedAt}/segment_000003_first_000000032000.wav`,
        'segment_000003_first_000000032000.wav', 3, 16000);
      expect(prepareComputerSessions([first, second, late], 'Asia/Singapore', [legacy])[0].canCommit()).assertFalse();
    });
    it('blocksRestoredWatchSessionsWhenStoredSequenceHasGaps', 0, () => {
      const startedAt = 1787997129983;
      const sessions = prepareComputerSessions([
        recording(`restored_auto_${startedAt}/030_segment_000001_first_000000000000.wav`,
          'segment_000001_first_000000000000.wav', 2, 16000),
        recording(`restored_auto_${startedAt}/021_segment_000001_first_000000000000.wav`,
          'segment_000001_first_000000000000.wav', 1, 16000)
      ]);

      expect(sessions.length).assertEqual(1);
      expect(sessions[0].manifest.sessionKey).assertEqual(`watch-session:${startedAt}`);
      expect(sessions[0].manifest.continuityValid).assertFalse();
      expect(sessions[0].manifest.chunks[0].fileName)
        .assertEqual('021_segment_000001_first_000000000000.wav');
      expect(sessions[0].manifest.chunks[1].fileName)
        .assertEqual('030_segment_000001_first_000000000000.wav');
      expect(sessions[0].manifest.chunks[0].index).assertEqual(21);
      expect(sessions[0].manifest.chunks[1].index).assertEqual(30);
      expect(sessions[0].manifest.chunks[1].firstSample).assertEqual(16000);
      expect(sessions[0].manifest.totalSamples).assertEqual(32000);
    });

    it('acceptsRestoredWatchSessionsOnlyWhenStoredSequenceIsConsecutive', 0, () => {
      const startedAt = 1787997129984;
      const sessions = prepareComputerSessions([
        recording(`restored_auto_${startedAt}/022_segment_000001_first_000000000000.wav`,
          'segment_000001_first_000000000000.wav', 2, 8000),
        recording(`restored_auto_${startedAt}/021_segment_000001_first_000000000000.wav`,
          'segment_000001_first_000000000000.wav', 1, 16000)
      ]);

      expect(sessions.length).assertEqual(1);
      expect(sessions[0].manifest.continuityValid).assertTrue();
      expect(sessions[0].manifest.chunks[0].index).assertEqual(21);
      expect(sessions[0].manifest.chunks[1].index).assertEqual(22);
      expect(sessions[0].manifest.chunks[1].firstSample).assertEqual(16000);
      expect(sessions[0].manifest.totalSamples).assertEqual(24000);
    });
  });
}
