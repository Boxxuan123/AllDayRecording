import {
  PCM_BYTES_PER_SAMPLE,
  PCM_SAMPLE_RATE_HZ,
  ReceivedRecordingFile,
  WAV_HEADER_BYTES
} from 'common';

const MILLISECONDS_PER_SECOND: number = 1000;

export class PhoneRecordingGroup {
  key: string;
  recordings: Array<ReceivedRecordingFile>;
  startedAt: number;
  receivedAt: number;
  size: number;
  durationMs: number;

  constructor(key: string, recordings: Array<ReceivedRecordingFile>, startedAt: number,
    receivedAt: number, size: number, durationMs: number) {
    this.key = key;
    this.recordings = recordings;
    this.startedAt = startedAt;
    this.receivedAt = receivedAt;
    this.size = size;
    this.durationMs = durationMs;
  }
}

export function groupReceivedRecordings(recordings: Array<ReceivedRecordingFile>): Array<PhoneRecordingGroup> {
  const groups: Array<PhoneRecordingGroup> = [];
  for (let index = 0; index < recordings.length; index += 1) {
    const recording = recordings[index];
    const sessionDirectory = continuousSessionDirectory(recording);
    const key = sessionDirectory.length > 0 ? `session:${sessionDirectory}` : `file:${recording.path}`;
    let group = findGroup(groups, key);
    if (group === undefined) {
      const startedAt = sessionStartedAt(sessionDirectory, recording.receivedAt);
      group = new PhoneRecordingGroup(key, [], startedAt, recording.receivedAt, 0, 0);
      groups.push(group);
    }
    group.recordings.push(recording);
    group.size += recording.size;
    group.durationMs += receivedRecordingDurationMs(recording);
    group.receivedAt = Math.max(group.receivedAt, recording.receivedAt);
  }

  for (let index = 0; index < groups.length; index += 1) {
    groups[index].recordings.sort(compareRecordingOrder);
  }
  groups.sort((left: PhoneRecordingGroup, right: PhoneRecordingGroup): number =>
    right.startedAt - left.startedAt || right.receivedAt - left.receivedAt);
  return groups;
}

export function receivedRecordingDurationMs(recording: ReceivedRecordingFile): number {
  if (recording.durationMs > 0) {
    return recording.durationMs;
  }
  if (!recording.fileName.toLowerCase().endsWith('.wav') || recording.size <= WAV_HEADER_BYTES) {
    return 0;
  }
  const pcmBytes = recording.size - WAV_HEADER_BYTES;
  return Math.floor(pcmBytes * MILLISECONDS_PER_SECOND / PCM_SAMPLE_RATE_HZ / PCM_BYTES_PER_SAMPLE);
}

function findGroup(groups: Array<PhoneRecordingGroup>, key: string): PhoneRecordingGroup | undefined {
  for (let index = 0; index < groups.length; index += 1) {
    if (groups[index].key === key) {
      return groups[index];
    }
  }
  return undefined;
}

function continuousSessionDirectory(recording: ReceivedRecordingFile): string {
  if (!recording.fileName.toLowerCase().startsWith('segment_')) {
    return '';
  }
  const separator = recording.sourcePath.lastIndexOf('/');
  return separator > 0 ? recording.sourcePath.substring(0, separator) : '';
}

function sessionStartedAt(sessionDirectory: string, fallback: number): number {
  if (sessionDirectory.length === 0) {
    return fallback;
  }
  const lastSeparator = sessionDirectory.lastIndexOf('/');
  const directoryName = lastSeparator >= 0 ? sessionDirectory.substring(lastSeparator + 1) : sessionDirectory;
  const timestampSeparator = directoryName.lastIndexOf('_');
  if (timestampSeparator < 0) {
    return fallback;
  }
  const timestampText = directoryName.substring(timestampSeparator + 1);
  if (timestampText.length < 13) {
    return fallback;
  }
  const timestamp = Number(timestampText);
  return Number.isFinite(timestamp) && timestamp > 0 ? timestamp : fallback;
}

function compareRecordingOrder(left: ReceivedRecordingFile, right: ReceivedRecordingFile): number {
  if (left.sourcePath !== right.sourcePath) {
    return left.sourcePath.localeCompare(right.sourcePath);
  }
  return left.receivedAt - right.receivedAt;
}
