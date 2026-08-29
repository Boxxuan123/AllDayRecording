import { describe, it, expect } from '@ohos/hypium';
import { WatchSyncProgress } from '../main/ets/models/RecordingModels';
import {
  PhoneSyncUiState,
  PresentationLifecycleCoordinator,
  formatRecordingDuration,
  formatRecordingReceivedAt,
  formatRecordingSize
} from '../main/ets/presentation/shared/RecordingPresentation';

export default function presentationStateTest() {
  describe('PresentationState', () => {
    it('aggregatesSyncProgressIntoOneReplacementState', 0, () => {
      const progress: WatchSyncProgress = {
        requestId: 'request_1',
        total: 3,
        received: 1,
        skipped: 2,
        alreadyReceived: 4,
        remaining: 5,
        scannedTotal: 12,
        inProgress: true,
        message: '正在传输',
        fileTransferActive: true,
        transferStage: 'transferring',
        transferPercent: 45,
        transferFileName: 'segment.wav',
        transferredBytes: 450,
        transferSize: 1000,
        transferIndex: 2,
        transferTotal: 3,
        automatic: true
      };
      const state = new PhoneSyncUiState(progress);
      expect(state.inProgress).assertTrue();
      expect(state.scannedTotal).assertEqual(12);
      expect(state.transferStage).assertEqual('transferring');
      expect(state.transferPercent).assertEqual(45);
      expect(state.automatic).assertTrue();
    });

    it('usesIdleDefaultsWhenNoProgressExists', 0, () => {
      const state = new PhoneSyncUiState();
      expect(state.inProgress).assertFalse();
      expect(state.fileTransferActive).assertFalse();
      expect(state.transferStage).assertEqual('idle');
      expect(state.transferPercent).assertEqual(0);
      expect(state.message).assertEqual('');
    });

    it('invalidatesOldLifecycleTokensAcrossPageExitAndRestart', 0, () => {
      const lifecycle = new PresentationLifecycleCoordinator();
      const first = lifecycle.activate();
      expect(lifecycle.isActive(first)).assertTrue();
      lifecycle.invalidate();
      expect(lifecycle.isActive(first)).assertFalse();
      const second = lifecycle.activate();
      expect(lifecycle.isActive(first)).assertFalse();
      expect(lifecycle.isActive(second)).assertTrue();
    });

    it('keepsPresentationFormattingStable', 0, () => {
      expect(formatRecordingDuration(65000)).assertEqual('01:05');
      expect(formatRecordingSize(1536)).assertEqual('1.5 KB');
      expect(formatRecordingReceivedAt(0).length > 0).assertTrue();
    });
  });
}
