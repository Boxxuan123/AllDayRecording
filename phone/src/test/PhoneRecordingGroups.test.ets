import { describe, it, expect } from '@ohos/hypium';
import { ReceivedRecordingFile, WAV_HEADER_BYTES } from 'common';
import {
  groupReceivedRecordings,
  receivedRecordingDurationMs
} from '../main/ets/presentation/phone/PhoneRecordingGroups';

function recording(sourcePath: string, fileName: string, receivedAt: number, size: number,
  durationMs: number = 0): ReceivedRecordingFile {
  return {
    fileName: fileName,
    path: `/phone/${receivedAt}_${fileName}`,
    size: size,
    durationMs: durationMs,
    requestId: 'request',
    sourcePath: sourcePath,
    receivedAt: receivedAt
  };
}

export default function phoneRecordingGroupsTest() {
  describe('PhoneRecordingGroups', () => {
    it('groupsContinuousSegmentsByWatchSessionAndSortsThem', 0, () => {
      const firstSize = WAV_HEADER_BYTES + 32000;
      const secondSize = WAV_HEADER_BYTES + 64000;
      const groups = groupReceivedRecordings([
        recording('pcm_gap_test_1788000000000/segment_000002_first_000000016000.wav',
          'segment_000002_first_000000016000.wav', 300, secondSize),
        recording('pcm_gap_test_1788000000000/segment_000001_first_000000000000.wav',
          'segment_000001_first_000000000000.wav', 200, firstSize),
        recording('pcm_gap_test_1787000000000/segment_000001_first_000000000000.wav',
          'segment_000001_first_000000000000.wav', 400, firstSize)
      ]);

      expect(groups.length).assertEqual(2);
      expect(groups[0].startedAt).assertEqual(1788000000000);
      expect(groups[0].recordings.length).assertEqual(2);
      expect(groups[0].recordings[0].fileName).assertEqual('segment_000001_first_000000000000.wav');
      expect(groups[0].durationMs).assertEqual(3000);
      expect(groups[0].size).assertEqual(firstSize + secondSize);
    });

    it('keepsStandaloneRecordingsSeparate', 0, () => {
      const groups = groupReceivedRecordings([
        recording('手表手动发送', 'received_1.wav', 200, WAV_HEADER_BYTES + 32000),
        recording('手表手动发送', 'received_2.wav', 100, WAV_HEADER_BYTES + 32000)
      ]);

      expect(groups.length).assertEqual(2);
      expect(groups[0].recordings.length).assertEqual(1);
      expect(groups[1].recordings.length).assertEqual(1);
    });

    it('prefersStoredDurationAndDerivesPcmWavDurationWhenMissing', 0, () => {
      const stored = recording('session/segment_1.wav', 'segment_1.wav', 1, 100, 4321);
      const derived = recording('session/segment_2.wav', 'segment_2.wav', 1,
        WAV_HEADER_BYTES + 96000);

      expect(receivedRecordingDurationMs(stored)).assertEqual(4321);
      expect(receivedRecordingDurationMs(derived)).assertEqual(3000);
    });
  });
}
