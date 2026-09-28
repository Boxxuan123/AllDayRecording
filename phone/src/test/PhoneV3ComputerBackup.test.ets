import { describe, expect, it } from '@ohos/hypium';
import { ReceivedRecordingFile, WAV_HEADER_BYTES } from 'common';
import { recordingsNeedingComputerBackup } from '../main/ets/v3/data/PhoneV3ComputerBackup';
import { PhoneSessionCompletionRecord, PhoneSessionTransferFailure, PhoneV3LocalAudioLink } from '../main/ets/v3/domain/PhoneV3Models';

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
    it('skipsFullyUploadedSessionsAndKeepsPendingSessionsWhole', 0, async () => {
      const uploadedSession = 1788000000000;
      const pendingSession = 1788001000000;
      const oldFirst = recording(uploadedSession, 1);
      const oldSecond = recording(uploadedSession, 2);
      const newFirst = recording(pendingSession, 1);
      const newSecond = recording(pendingSession, 2);

      const pending = await recordingsNeedingComputerBackup(
        [oldFirst, oldSecond, newFirst, newSecond],
        [uploaded(oldFirst, uploadedSession), uploaded(oldSecond, uploadedSession),
          uploaded(newFirst, pendingSession)]);

      expect(pending.length).assertEqual(2);
      expect(pending[0].path).assertEqual(newFirst.path);
      expect(pending[1].path).assertEqual(newSecond.path);
    });

    it('doesNotSkipAWholeSessionWhenOneReceiptIsMissing', 0, async () => {
      const sessionStartedAt = 1788002000000;
      const first = recording(sessionStartedAt, 1);
      const second = recording(sessionStartedAt, 2);

      const pending = await recordingsNeedingComputerBackup(
        [first, second], [uploaded(first, sessionStartedAt)]);

      expect(pending.length).assertEqual(2);
      expect(pending[0].path).assertEqual(first.path);
      expect(pending[1].path).assertEqual(second.path);
    });
    it('doesNotReuseAStaleWholeSessionReceiptWithMatchingCounts', 0, async () => {
      const sessionStartedAt = 1788003000000;
      const first = recording(sessionStartedAt, 1);
      const second = recording(sessionStartedAt, 2);
      const stale: PhoneSessionCompletionRecord = {
        sessionKey: `watch-session:${sessionStartedAt}`, source: 'legacy_user_confirmed',
        completedSegments: 2, totalSamples: 32000, confirmedAt: sessionStartedAt + 1000,
        manifestSha256: 'a'.repeat(64)
      };
      const pending = await recordingsNeedingComputerBackup([first, second],
        [uploaded(first, sessionStartedAt), uploaded(second, sessionStartedAt)], [stale],
        async (): Promise<string> => 'b'.repeat(64));
      expect(pending.length).assertEqual(2);
    });
    it('skipsOnlyTheExactAcknowledgedWholeSessionManifest', 0, async () => {
      const sessionStartedAt = 1788004000000;
      const first = recording(sessionStartedAt, 1);
      const second = recording(sessionStartedAt, 2);
      const receipt: PhoneSessionCompletionRecord = {
        sessionKey: `watch-session:${sessionStartedAt}`, source: 'legacy_user_confirmed',
        completedSegments: 2, totalSamples: 32000, confirmedAt: sessionStartedAt + 1000,
        manifestSha256: 'b'.repeat(64)
      };
      const pending = await recordingsNeedingComputerBackup([first, second],
        [uploaded(first, sessionStartedAt), uploaded(second, sessionStartedAt)], [receipt],
        async (): Promise<string> => 'b'.repeat(64));
      expect(pending.length).assertEqual(0);
    });
    it('quarantinesOneConflictingManifestAndKeepsOtherSessionPending', 0, async () => {
      const firstTime = 1788005000000;
      const secondTime = 1788006000000;
      const first = recording(firstTime, 1);
      const second = recording(secondTime, 1);
      const completion: PhoneSessionCompletionRecord = {
        sessionKey: `watch-session:${firstTime}`, source: 'legacy_user_confirmed',
        completedSegments: 1, totalSamples: 16000, confirmedAt: firstTime + 1000,
        manifestSha256: ''
      };
      const conflict: PhoneSessionTransferFailure = {
        sessionKey: completion.sessionKey, manifestSha256: 'a'.repeat(64),
        category: 'conflict', reason: '旧分片哈希改变', attemptCount: 1,
        retryAt: 0, updatedAt: firstTime + 2000
      };
      const pending = await recordingsNeedingComputerBackup([first, second],
        [uploaded(first, firstTime)], [completion], async (): Promise<string> => 'a'.repeat(64), [conflict]);
      expect(pending.length).assertEqual(1);
      expect(pending[0].path).assertEqual(second.path);
      const changed = await recordingsNeedingComputerBackup([first, second],
        [uploaded(first, firstTime)], [completion], async (): Promise<string> => 'b'.repeat(64), [conflict]);
      expect(changed.length).assertEqual(2);
    });
  });
}
