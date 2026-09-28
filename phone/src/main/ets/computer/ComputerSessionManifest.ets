import {
  PCM_BITS_PER_SAMPLE,
  PCM_BYTES_PER_SAMPLE,
  PCM_CHANNEL_COUNT,
  PCM_SAMPLE_RATE_HZ,
  ReceivedRecordingFile,
  WAV_HEADER_BYTES
} from 'common';
import { fileIo } from '@kit.CoreFileKit';
import { PhoneSessionCompletionRecord } from '../v3/domain/PhoneV3Models';

export const COMPUTER_SESSION_MANIFEST_FILE: string = 'session_summary.json';
export const COMPUTER_SESSION_MANIFEST_FORMAT: string = 'AllDayRecording session manifest v2';

export interface ComputerManifestCompletion {
  source: string;
  completedSegments: number;
  totalSamples: number;
  confirmedAt: number;
}

interface WatchSummarySegment {
  index: number;
  fileName: string;
  firstSample: number;
  sampleCount: number;
}

interface WatchSummary {
  format: string;
  sessionStartedAt: number;
  completedSegments: number;
  totalSamples: number;
  continuityValid: boolean;
  segments: Array<WatchSummarySegment>;
}

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
  completion?: ComputerManifestCompletion;
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

  canCommit(): boolean {
    return this.manifest.continuityValid && this.manifest.completion !== undefined;
  }
}

export function prepareComputerSessions(recordings: Array<ReceivedRecordingFile>,
  timezone: string = 'Asia/Singapore',
  completions: Array<PhoneSessionCompletionRecord> = []): Array<PreparedComputerSession> {
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
    sessions.push(prepareOneSession(directory, files, timezone, recordings, completions));
  });
  sessions.sort((left: PreparedComputerSession, right: PreparedComputerSession): number =>
    left.manifest.sessionStartedAt - right.manifest.sessionStartedAt);
  return sessions;
}

function prepareOneSession(directory: string, recordings: Array<ReceivedRecordingFile>,
  timezone: string, allFiles: Array<ReceivedRecordingFile>,
  completions: Array<PhoneSessionCompletionRecord>): PreparedComputerSession {
  const chunks: Array<ComputerManifestChunk> = [];
  const ordered = recordings.slice();
  const isRestoredSession = directory.startsWith('restored_auto_');
  ordered.sort((left: ReceivedRecordingFile, right: ReceivedRecordingFile): number => {
    if (isRestoredSession) {
      return restoredSegmentIndex(left) - restoredSegmentIndex(right);
    }
    return parseSegment(left).firstSample - parseSegment(right).firstSample;
  });
  let totalSamples = 0;
  let continuityValid = true;
  let previousRestoredIndex: number | undefined = undefined;
  for (let index = 0; index < ordered.length; index += 1) {
    const parsed = parseSegment(ordered[index]);
    const restoredIndex = isRestoredSession ? restoredSegmentIndex(ordered[index]) : parsed.index;
    const chunk: ComputerManifestChunk = isRestoredSession ? {
      index: restoredIndex,
      fileName: parsed.fileName,
      firstSample: totalSamples,
      sampleCount: parsed.sampleCount
    } : parsed;
    if (isRestoredSession && previousRestoredIndex !== undefined &&
      restoredIndex !== previousRestoredIndex + 1) {
      continuityValid = false;
    }
    if (chunk.firstSample !== totalSamples) {
      continuityValid = false;
    }
    totalSamples = Math.max(totalSamples, chunk.firstSample + chunk.sampleCount);
    chunks.push(chunk);
    previousRestoredIndex = restoredIndex;
  }
  const startedAt = sessionStartedAt(directory);
  const sessionKey = `watch-session:${startedAt}`;
  const completion = verifiedCompletion(directory, startedAt, chunks, totalSamples,
    continuityValid, allFiles, completions, sessionKey);
  return new PreparedComputerSession(directory, ordered, {
    format: COMPUTER_SESSION_MANIFEST_FORMAT,
    sessionKey: sessionKey,
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
    continuityValid: continuityValid,
    completion: completion
  });
}

function verifiedCompletion(directory: string, startedAt: number,
  chunks: Array<ComputerManifestChunk>, totalSamples: number, continuityValid: boolean,
  allFiles: Array<ReceivedRecordingFile>, records: Array<PhoneSessionCompletionRecord>,
  sessionKey: string): ComputerManifestCompletion | undefined {
  if (!continuityValid || chunks.length === 0) { return undefined; }
  const summaryFile = allFiles.find((file: ReceivedRecordingFile): boolean =>
    file.sourcePath === `${directory}/session_summary.json`);
  if (summaryFile !== undefined) {
    try {
      const summary = JSON.parse(fileIo.readTextSync(summaryFile.path)) as WatchSummary;
      if (summary.format !== 'AllDayRecording PCM gap test v1' ||
        summary.sessionStartedAt !== startedAt || summary.continuityValid !== true ||
        summary.completedSegments !== chunks.length || summary.totalSamples !== totalSamples ||
        !Array.isArray(summary.segments) || summary.segments.length !== chunks.length) {
        return undefined;
      }
      for (let index = 0; index < chunks.length; index += 1) {
        const original = summary.segments[index];
        const received = chunks[index];
        if (original.index !== received.index || original.fileName !== received.fileName ||
          original.firstSample !== received.firstSample || original.sampleCount !== received.sampleCount) {
          return undefined;
        }
      }
      return { source: 'watch_stop', completedSegments: chunks.length,
        totalSamples: totalSamples, confirmedAt: summaryFile.receivedAt };
    } catch (_error) { return undefined; }
  }
  const legacy = records.find((record: PhoneSessionCompletionRecord): boolean =>
    record.sessionKey === sessionKey && record.source === 'legacy_user_confirmed');
  if (legacy !== undefined && legacy.completedSegments === chunks.length &&
    legacy.totalSamples === totalSamples && legacy.confirmedAt > 0) {
    return { source: 'legacy_user_confirmed', completedSegments: chunks.length,
      totalSamples: totalSamples, confirmedAt: legacy.confirmedAt };
  }
  return undefined;
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
    fileName: sourceFileName(recording.sourcePath),
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
  return /^(pcm_(gap_test|session)|restored_auto)_[0-9]{13,}$/.test(directory) ? directory : '';
}

function sourceFileName(sourcePath: string): string {
  const separator = sourcePath.lastIndexOf('/');
  const value = separator >= 0 ? sourcePath.substring(separator + 1) : sourcePath;
  if (value.length === 0 || value.includes('\\') || value.includes('..')) {
    throw new Error(`无法识别录音源文件名：${sourcePath}`);
  }
  return value;
}

function restoredSegmentIndex(recording: ReceivedRecordingFile): number {
  const match = /^([0-9]+)_segment_/.exec(sourceFileName(recording.sourcePath));
  if (match === null) {
    throw new Error(`恢复录音缺少可验证的顺序编号：${recording.sourcePath}`);
  }
  const value = Number(match[1]);
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error(`恢复录音顺序编号无效：${recording.sourcePath}`);
  }
  return value;
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
