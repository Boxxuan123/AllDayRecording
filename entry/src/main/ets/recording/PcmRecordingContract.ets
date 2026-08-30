import {
  PCM_BITS_PER_SAMPLE,
  PCM_BYTES_PER_SAMPLE,
  PCM_CHANNEL_COUNT,
  PCM_SAMPLE_RATE_HZ
} from '../shared/io/WavFormat';

const PCM_RECORDING_SESSION_PREFIX: string = 'pcm_gap_test_';
export const PCM_RECORDING_SUMMARY_FILE_NAME: string = 'session_summary.json';
const PCM_RECORDING_SUMMARY_FORMAT: string = 'AllDayRecording PCM gap test v1';
const PCM_RECORDING_SEGMENT_SECONDS: number = 60;
export const PCM_RECORDING_SEGMENT_SAMPLES: number = PCM_SAMPLE_RATE_HZ * PCM_RECORDING_SEGMENT_SECONDS;
export const PCM_RECORDING_SEGMENT_BYTES: number = PCM_RECORDING_SEGMENT_SAMPLES * PCM_BYTES_PER_SAMPLE;
export const PCM_RECORDING_MAX_QUEUED_BYTES: number = PCM_SAMPLE_RATE_HZ * PCM_BYTES_PER_SAMPLE * 5;

export interface PcmSegmentEvidence {
  index: number;
  fileName: string;
  firstSample: number;
  sampleCount: number;
  pcmBytes: number;
}

export interface PcmSessionSummary {
  format: string;
  sessionStartedAt: number;
  sampleRate: number;
  channels: number;
  bitsPerSample: number;
  segmentSamples: number;
  totalSamples: number;
  completedSegments: number;
  continuityValid: boolean;
  hardwareOverflowCount: number;
  softwareQueueOverflowCount: number;
  capturerFramePosition: number;
  capturerBufferSizeBytes: number;
  segments: Array<PcmSegmentEvidence>;
}

export interface PcmSessionMetrics {
  sessionStartedAt: number;
  totalSamples: number;
  hardwareOverflowCount: number;
  softwareQueueOverflowCount: number;
  capturerFramePosition: number;
  capturerBufferSizeBytes: number;
}

export function pcmRecordingSessionDirectory(filesDirectory: string, sessionStartedAt: number): string {
  return `${filesDirectory}/${PCM_RECORDING_SESSION_PREFIX}${sessionStartedAt}`;
}

export function pcmSegmentFileName(index: number, firstSample: number): string {
  const indexText = index.toString().padStart(6, '0');
  const sampleText = firstSample.toString().padStart(12, '0');
  return `segment_${indexText}_first_${sampleText}.wav`;
}

export function isPcmRecordingSessionName(name: string): boolean {
  return name.startsWith(PCM_RECORDING_SESSION_PREFIX);
}

export function createPcmSessionSummary(metrics: PcmSessionMetrics,
  evidence: Array<PcmSegmentEvidence>): PcmSessionSummary {
  return {
    format: PCM_RECORDING_SUMMARY_FORMAT,
    sessionStartedAt: metrics.sessionStartedAt,
    sampleRate: PCM_SAMPLE_RATE_HZ,
    channels: PCM_CHANNEL_COUNT,
    bitsPerSample: PCM_BITS_PER_SAMPLE,
    segmentSamples: PCM_RECORDING_SEGMENT_SAMPLES,
    totalSamples: metrics.totalSamples,
    completedSegments: evidence.length,
    continuityValid: isPcmEvidenceContinuous(evidence, metrics.totalSamples,
      metrics.hardwareOverflowCount, metrics.softwareQueueOverflowCount),
    hardwareOverflowCount: metrics.hardwareOverflowCount,
    softwareQueueOverflowCount: metrics.softwareQueueOverflowCount,
    capturerFramePosition: metrics.capturerFramePosition,
    capturerBufferSizeBytes: metrics.capturerBufferSizeBytes,
    segments: evidence.slice()
  };
}

function isPcmEvidenceContinuous(evidence: Array<PcmSegmentEvidence>, totalSamples: number,
  hardwareOverflowCount: number, softwareQueueOverflowCount: number): boolean {
  let expectedFirstSample: number = 0;
  for (let index = 0; index < evidence.length; index += 1) {
    const segment = evidence[index];
    if (segment.firstSample !== expectedFirstSample) {
      return false;
    }
    expectedFirstSample += segment.sampleCount;
  }
  return expectedFirstSample === totalSamples && hardwareOverflowCount === 0 && softwareQueueOverflowCount === 0;
}
