import { describe, expect, it } from '@ohos/hypium';
import {
  areRecordingDiagnosticsEnabled,
  requireRecordingDiagnosticsEnabled
} from '../main/ets/diagnostics/RecordingDiagnosticsPolicy';
import { sleepModeProbeDiagnosticName } from '../main/ets/diagnostics/SleepModeProbeService';
import { avRecorderGapBaselineDiagnosticName } from '../main/ets/diagnostics/legacy/AvRecorderGapBaseline';
import { RecordingFile } from 'common';
import {
  PCM_RECORDING_SEGMENT_SAMPLES,
  PcmSessionMetrics,
  isPcmRecordingSessionName,
  pcmRecordingSessionDirectory,
  pcmSegmentFileName
} from '../main/ets/recording/PcmRecordingContract';
import { PcmSessionSummaryStore } from '../main/ets/recording/PcmSessionSummaryStore';
import {
  WavSegmentFileOperations,
  WavSegmentSlot
} from '../main/ets/recording/WavSegmentSlot';

class FakeWavSegmentFileOperations implements WavSegmentFileOperations {
  events: Array<string> = [];
  failSyncAndClose: boolean = false;

  openForWrite(path: string): number {
    this.events.push(`open:${path}`);
    return 21;
  }

  write(fd: number, buffer: ArrayBuffer): number {
    this.events.push(`write:${fd}:${buffer.byteLength}`);
    return buffer.byteLength;
  }

  seekToStart(fd: number): void {
    this.events.push(`seek:${fd}`);
  }

  syncAndClose(fd: number): void {
    this.events.push(`sync_close:${fd}`);
    if (this.failSyncAndClose) {
      throw new Error('sync failed');
    }
  }

  publish(partPath: string, finalPath: string): void {
    this.events.push(`publish:${partPath}:${finalPath}`);
  }

  statSize(path: string): number {
    this.events.push(`stat:${path}`);
    return 48;
  }

  close(fd: number): void {
    this.events.push(`close:${fd}`);
  }

  unlink(path: string): void {
    this.events.push(`unlink:${path}`);
  }
}

function recording(fileName: string): RecordingFile {
  return {
    fileName: fileName,
    path: `/files/session/${fileName}`,
    size: 64,
    durationMs: 1
  };
}

function metrics(totalSamples: number, hardwareOverflowCount: number = 0,
  softwareQueueOverflowCount: number = 0): PcmSessionMetrics {
  return {
    sessionStartedAt: 123,
    totalSamples: totalSamples,
    hardwareOverflowCount: hardwareOverflowCount,
    softwareQueueOverflowCount: softwareQueueOverflowCount,
    capturerFramePosition: 15,
    capturerBufferSizeBytes: 320
  };
}

export default function pcmRecordingDomainTest() {
  describe('PcmRecordingContract', () => {
    it('preservesLegacySessionAndSegmentNames', 0, () => {
      expect(pcmRecordingSessionDirectory('/files', 123)).assertEqual('/files/pcm_gap_test_123');
      expect(pcmSegmentFileName(2, PCM_RECORDING_SEGMENT_SAMPLES)).assertEqual(
        'segment_000002_first_000000960000.wav');
      expect(isPcmRecordingSessionName('pcm_gap_test_123')).assertTrue();
      expect(isPcmRecordingSessionName('recording_123')).assertFalse();
    });

    it('buildsContinuousSummaryWithoutChangingSchema', 0, () => {
      const store = new PcmSessionSummaryStore();
      store.append(recording('segment_000001_first_000000000000.wav'), 1, 0, 10, 20);
      store.append(recording('segment_000002_first_000000000010.wav'), 2, 10, 5, 10);

      const summary = store.build(metrics(15));

      expect(summary.format).assertEqual('AllDayRecording PCM gap test v1');
      expect(summary.sampleRate).assertEqual(16000);
      expect(summary.channels).assertEqual(1);
      expect(summary.bitsPerSample).assertEqual(16);
      expect(summary.segmentSamples).assertEqual(960000);
      expect(summary.completedSegments).assertEqual(2);
      expect(summary.continuityValid).assertTrue();
      expect(summary.segments[1].firstSample).assertEqual(10);
    });

    it('rejectsGapAndOverflowFromContinuityEvidence', 0, () => {
      const store = new PcmSessionSummaryStore();
      store.append(recording('segment.wav'), 1, 1, 10, 20);

      expect(store.build(metrics(10)).continuityValid).assertFalse();
      store.reset();
      store.append(recording('segment.wav'), 1, 0, 10, 20);
      expect(store.build(metrics(10, 1, 0)).continuityValid).assertFalse();
      expect(store.build(metrics(10, 0, 1)).continuityValid).assertFalse();
    });
  });

  describe('WavSegmentSlot', () => {
    it('sealsPartBeforePublishingFinalWav', 0, () => {
      const operations = new FakeWavSegmentFileOperations();
      const slot = new WavSegmentSlot('/files/session', 1, 0, operations);
      slot.write(new ArrayBuffer(4));

      const result = slot.finalize();

      expect(result.fileName).assertEqual('segment_000001_first_000000000000.wav');
      expect(result.size).assertEqual(48);
      expect(slot.getPcmBytes()).assertEqual(4);
      expect(operations.events.join('|')).assertEqual(
        'open:/files/session/segment_000001_first_000000000000.wav.part|write:21:44|write:21:4|' +
        'seek:21|write:21:44|sync_close:21|' +
        'publish:/files/session/segment_000001_first_000000000000.wav.part:' +
        '/files/session/segment_000001_first_000000000000.wav|' +
        'stat:/files/session/segment_000001_first_000000000000.wav');
    });

    it('preservesPartAndDoesNotPublishAfterSealFailure', 0, () => {
      const operations = new FakeWavSegmentFileOperations();
      operations.failSyncAndClose = true;
      const slot = new WavSegmentSlot('/files/session', 1, 0, operations);
      slot.write(new ArrayBuffer(4));
      let rejected: boolean = false;

      try {
        slot.finalize();
      } catch (error) {
        rejected = true;
      }

      expect(rejected).assertTrue();
      expect(operations.events.join('|').includes('close:21')).assertTrue();
      expect(operations.events.join('|').includes('publish:')).assertFalse();
      expect(operations.events.join('|').includes('unlink:')).assertFalse();
    });

    it('removesUnusedStandbyPart', 0, () => {
      const operations = new FakeWavSegmentFileOperations();
      const slot = new WavSegmentSlot('/files/session', 2, PCM_RECORDING_SEGMENT_SAMPLES, operations);

      slot.discard();

      expect(operations.events.join('|').includes('close:21')).assertTrue();
      expect(operations.events.join('|').includes(
        'unlink:/files/session/segment_000002_first_000000960000.wav.part')).assertTrue();
    });
  });

  describe('RecordingDiagnosticsPolicy', () => {
    it('keepsDiagnosticsDisabledByDefault', 0, () => {
      expect(areRecordingDiagnosticsEnabled()).assertFalse();
      expect(avRecorderGapBaselineDiagnosticName()).assertEqual('av_recorder_gap_baseline');
      expect(sleepModeProbeDiagnosticName()).assertEqual('sleep_mode_probe');
      let rejected: boolean = false;
      try {
        requireRecordingDiagnosticsEnabled();
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });
  });
}
