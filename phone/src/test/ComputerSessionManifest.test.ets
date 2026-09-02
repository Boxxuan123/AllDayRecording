import { describe, expect, it } from '@ohos/hypium';
import { ReceivedRecordingFile, WAV_HEADER_BYTES } from 'common';
import { prepareComputerSessions } from '../main/ets/computer/ComputerSessionManifest';

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
