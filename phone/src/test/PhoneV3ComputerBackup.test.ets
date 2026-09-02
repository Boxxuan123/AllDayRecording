import { describe, expect, it } from '@ohos/hypium';
import { ReceivedRecordingFile, WAV_HEADER_BYTES } from 'common';
import { recordingsNeedingComputerBackup } from '../main/ets/v3/data/PhoneV3ComputerBackup';
import { PhoneV3LocalAudioLink } from '../main/ets/v3/domain/PhoneV3Models';

function recording(sessionStartedAt: number, index: number): ReceivedRecordingFile {
  const firstSample = (index - 1) * 16000;
  const fileName = `segment_${index.toString().padStart(6, '0')}_first_${
    firstSample.toString().padStart(12, '0')}.wav`;
  return {
    fileName: fileName,
    path: `/phone/${sessionStartedAt}/${fileName}`,
    size: WAV_HEADER_BYTES + 32000,
    durationMs: 1000,
    requestId: 'request',
    sourcePath: `pcm_gap_test_${sessionStartedAt}/${fileName}`,
    receivedAt: sessionStartedAt + index
  };
}

function uploaded(recordingFile: ReceivedRecordingFile, sessionStartedAt: number): PhoneV3LocalAudioLink {
  return new PhoneV3LocalAudioLink(`watch-session:${sessionStartedAt}`, 'session-id',
    recordingFile.path, 'uploaded', 1);
}

export default function phoneV3ComputerBackupTest() {
  describe('PhoneV3ComputerBackup', () => {
    it('skipsFullyUploadedSessionsAndKeepsPendingSessionsWhole', 0, () => {
      const uploadedSession = 1788000000000;
      const pendingSession = 1788001000000;
      const oldFirst = recording(uploadedSession, 1);
      const oldSecond = recording(uploadedSession, 2);
      const newFirst = recording(pendingSession, 1);
      const newSecond = recording(pendingSession, 2);

      const pending = recordingsNeedingComputerBackup(
        [oldFirst, oldSecond, newFirst, newSecond],
        [uploaded(oldFirst, uploadedSession), uploaded(oldSecond, uploadedSession),
          uploaded(newFirst, pendingSession)]);

      expect(pending.length).assertEqual(2);
      expect(pending[0].path).assertEqual(newFirst.path);
      expect(pending[1].path).assertEqual(newSecond.path);
    });

    it('doesNotSkipAWholeSessionWhenOneReceiptIsMissing', 0, () => {
      const sessionStartedAt = 1788002000000;
      const first = recording(sessionStartedAt, 1);
      const second = recording(sessionStartedAt, 2);

      const pending = recordingsNeedingComputerBackup(
        [first, second], [uploaded(first, sessionStartedAt)]);

      expect(pending.length).assertEqual(2);
      expect(pending[0].path).assertEqual(first.path);
      expect(pending[1].path).assertEqual(second.path);
    });
  });
}
