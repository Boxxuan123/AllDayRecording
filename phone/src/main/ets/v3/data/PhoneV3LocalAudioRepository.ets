import {
  PCM_BYTES_PER_SAMPLE,
  PCM_SAMPLE_RATE_HZ,
  ReceivedRecordingFile,
  WAV_HEADER_BYTES
} from 'common';
import { PhoneV3RecordingStore } from '../runtime/PhoneV3RecordingStore';
import { PhoneV3LocalAudioRepositoryPort } from '../application/PhoneV3Ports';
import { PhoneV3LocalAudioFact } from '../domain/PhoneV3Models';

const MILLISECONDS_PER_SECOND: number = 1000;

export class PhoneV3LocalAudioRepository implements PhoneV3LocalAudioRepositoryPort {
  private filesDirectory: string;

  constructor(filesDirectory: string) {
    this.filesDirectory = filesDirectory;
  }

  async list(): Promise<Array<PhoneV3LocalAudioFact>> {
    const recordings = new PhoneV3RecordingStore(this.filesDirectory).list();
    const groups: Array<PhoneV3LocalAudioFact> = [];
    for (let index = 0; index < recordings.length; index += 1) {
      const recording = recordings[index];
      const directory = sessionDirectory(recording);
      const startedAt = sessionStartedAt(directory, recording.receivedAt);
      const sessionKey = directory.length > 0 ? `watch-session:${startedAt}` : `file:${recording.path}`;
      const localGroupKey = directory.length > 0 ? `session:${directory}` : `file:${recording.path}`;
      let group = findGroup(groups, sessionKey);
      if (group === undefined) {
        group = new PhoneV3LocalAudioFact(sessionKey, localGroupKey, [], startedAt,
          recording.receivedAt, 0, 0);
        groups.push(group);
      }
      group.paths.push(recording.path);
      group.sizeBytes += recording.size;
      group.durationMs += durationMs(recording);
      group.receivedAt = Math.max(group.receivedAt, recording.receivedAt);
    }
    for (let index = 0; index < groups.length; index += 1) {
      groups[index].paths.sort((left: string, right: string): number => left.localeCompare(right));
    }
    groups.sort((left: PhoneV3LocalAudioFact, right: PhoneV3LocalAudioFact): number =>
      right.startedAt - left.startedAt || right.receivedAt - left.receivedAt);
    return groups;
  }
}

function findGroup(groups: Array<PhoneV3LocalAudioFact>, key: string): PhoneV3LocalAudioFact | undefined {
  for (let index = 0; index < groups.length; index += 1) {
    if (groups[index].sessionKey === key) {
      return groups[index];
    }
  }
  return undefined;
}

function sessionDirectory(recording: ReceivedRecordingFile): string {
  if (!recording.fileName.toLowerCase().startsWith('segment_')) {
    return '';
  }
  const separator = recording.sourcePath.lastIndexOf('/');
  return separator > 0 ? recording.sourcePath.substring(0, separator) : '';
}

function sessionStartedAt(directory: string, fallback: number): number {
  if (directory.length === 0) {
    return fallback;
  }
  const separator = directory.lastIndexOf('_');
  const value = separator >= 0 ? Number(directory.substring(separator + 1)) : Number.NaN;
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function durationMs(recording: ReceivedRecordingFile): number {
  if (recording.durationMs > 0) {
    return recording.durationMs;
  }
  if (!recording.fileName.toLowerCase().endsWith('.wav') || recording.size <= WAV_HEADER_BYTES) {
    return 0;
  }
  return Math.floor((recording.size - WAV_HEADER_BYTES) * MILLISECONDS_PER_SECOND /
    PCM_SAMPLE_RATE_HZ / PCM_BYTES_PER_SAMPLE);
}
