import {
  PCM_BITS_PER_SAMPLE,
  PCM_BYTES_PER_SAMPLE,
  PCM_CHANNEL_COUNT,
  PCM_SAMPLE_RATE_HZ,
  ReceivedRecordingFile,
  WAV_HEADER_BYTES
} from 'common';

export const COMPUTER_SESSION_MANIFEST_FILE: string = 'session_summary.json';
export const COMPUTER_SESSION_MANIFEST_FORMAT: string = 'AllDayRecording session manifest v1';

export interface ComputerManifestChunk {
  index: number;
  fileName: string;
  firstSample: number;
  sampleCount: number;
}

export interface ComputerSessionManifest {
  format: string;
  sessionKey: string;
  sessionStartedAt: number;
  device: string;
  timezone: string;
  audio: ComputerManifestAudio;
  chunks: Array<ComputerManifestChunk>;
  completedSegments: number;
  totalSamples: number;
  continuityValid: boolean;
}

export interface ComputerManifestAudio {
  sampleRate: number;
  channels: number;
  bitsPerSample: number;
}

export class PreparedComputerSession {
  directory: string;
  recordings: Array<ReceivedRecordingFile>;
  manifest: ComputerSessionManifest;

  constructor(directory: string, recordings: Array<ReceivedRecordingFile>, manifest: ComputerSessionManifest) {
    this.directory = directory;
    this.recordings = recordings;
    this.manifest = manifest;
  }

  manifestRelativePath(): string {
    return `${this.directory}/${COMPUTER_SESSION_MANIFEST_FILE}`;
  }
}

export function prepareComputerSessions(recordings: Array<ReceivedRecordingFile>,
  timezone: string = 'Asia/Singapore'): Array<PreparedComputerSession> {
  const grouped = new Map<string, Array<ReceivedRecordingFile>>();
  for (let index = 0; index < recordings.length; index += 1) {
    const recording = recordings[index];
    const directory = safeSessionDirectory(recording.sourcePath);
    if (directory.length === 0 || !isSupportedPcmWav(recording)) {
      continue;
    }
    const existing = grouped.get(directory) ?? [];
    existing.push(recording);
    grouped.set(directory, existing);
  }

  const sessions: Array<PreparedComputerSession> = [];
  grouped.forEach((files: Array<ReceivedRecordingFile>, directory: string): void => {
    sessions.push(prepareOneSession(directory, files, timezone));
  });
  sessions.sort((left: PreparedComputerSession, right: PreparedComputerSession): number =>
    left.manifest.sessionStartedAt - right.manifest.sessionStartedAt);
  return sessions;
}

function prepareOneSession(directory: string, recordings: Array<ReceivedRecordingFile>,
  timezone: string): PreparedComputerSession {
  const chunks: Array<ComputerManifestChunk> = [];
  const ordered = recordings.slice();
  ordered.sort((left: ReceivedRecordingFile, right: ReceivedRecordingFile): number =>
    parseSegment(left).firstSample - parseSegment(right).firstSample);
  let totalSamples = 0;
  let continuityValid = true;
  for (let index = 0; index < ordered.length; index += 1) {
    const chunk = parseSegment(ordered[index]);
    if (chunk.firstSample !== totalSamples) {
      continuityValid = false;
    }
    totalSamples = Math.max(totalSamples, chunk.firstSample + chunk.sampleCount);
    chunks.push(chunk);
  }
  const startedAt = sessionStartedAt(directory);
  return new PreparedComputerSession(directory, ordered, {
    format: COMPUTER_SESSION_MANIFEST_FORMAT,
    sessionKey: `watch-session:${startedAt}`,
    sessionStartedAt: startedAt,
    device: 'HUAWEI WATCH 5',
    timezone: timezone,
    audio: {
      sampleRate: PCM_SAMPLE_RATE_HZ,
      channels: PCM_CHANNEL_COUNT,
      bitsPerSample: PCM_BITS_PER_SAMPLE
    },
    chunks: chunks,
    completedSegments: chunks.length,
    totalSamples: totalSamples,
    continuityValid: continuityValid
  });
}

function parseSegment(recording: ReceivedRecordingFile): ComputerManifestChunk {
  const indexMatch = /^segment_([0-9]+)/.exec(recording.fileName);
  const sampleMatch = /_first_([0-9]+)/.exec(recording.fileName);
  const pcmBytes = recording.size - WAV_HEADER_BYTES;
  const sampleCount = pcmBytes / PCM_BYTES_PER_SAMPLE;
  if (indexMatch === null || sampleMatch === null || !Number.isSafeInteger(sampleCount) || sampleCount <= 0) {
    throw new Error(`无法从录音元数据生成会话清单：${recording.fileName}`);
  }
  return {
    index: Number(indexMatch[1]),
    fileName: recording.fileName,
    firstSample: Number(sampleMatch[1]),
    sampleCount: sampleCount
  };
}

function safeSessionDirectory(sourcePath: string): string {
  if (sourcePath.startsWith('/') || sourcePath.includes('\\') || sourcePath.includes('..')) {
    return '';
  }
  const separator = sourcePath.lastIndexOf('/');
  if (separator <= 0 || separator === sourcePath.length - 1) {
    return '';
  }
  const directory = sourcePath.substring(0, separator);
  return /^pcm_(gap_test|session)_[0-9]{13,}$/.test(directory) ? directory : '';
}

function isSupportedPcmWav(recording: ReceivedRecordingFile): boolean {
  return recording.fileName.startsWith('segment_') && recording.fileName.toLowerCase().endsWith('.wav') &&
    recording.size > WAV_HEADER_BYTES;
}

function sessionStartedAt(directory: string): number {
  const separator = directory.lastIndexOf('_');
  const value = Number(directory.substring(separator + 1));
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`无法识别录音会话时间：${directory}`);
  }
  return value;
}
