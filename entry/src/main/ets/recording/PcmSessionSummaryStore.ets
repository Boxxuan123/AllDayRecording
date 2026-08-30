import { RecordingFile } from '../models/RecordingModels';
import { writeJsonAtomically } from '../shared/io/AtomicJsonStore';
import {
  PCM_RECORDING_SUMMARY_FILE_NAME,
  PcmSegmentEvidence,
  PcmSessionMetrics,
  PcmSessionSummary,
  createPcmSessionSummary
} from './PcmRecordingContract';

export class PcmSessionSummaryStore {
  private evidence: Array<PcmSegmentEvidence> = [];

  reset(): void {
    this.evidence = [];
  }

  append(recording: RecordingFile, index: number, firstSample: number, sampleCount: number,
    pcmBytes: number): void {
    this.evidence.push({
      index: index,
      fileName: recording.fileName,
      firstSample: firstSample,
      sampleCount: sampleCount,
      pcmBytes: pcmBytes
    });
  }

  getCompletedCount(): number {
    return this.evidence.length;
  }

  build(metrics: PcmSessionMetrics): PcmSessionSummary {
    return createPcmSessionSummary(metrics, this.evidence);
  }

  write(sessionDirectory: string, metrics: PcmSessionMetrics): PcmSessionSummary {
    const summary = this.build(metrics);
    writeJsonAtomically(`${sessionDirectory}/${PCM_RECORDING_SUMMARY_FILE_NAME}`, summary);
    return summary;
  }
}
