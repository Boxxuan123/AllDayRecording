import { PhoneV3ReviewItem, PhoneV3SessionCard, PhoneV3Utterance } from './PhoneV3Models';
import { PhoneV3VoiceCandidate, phoneV3ReviewIsHistory, phoneV3VoiceCandidates, phoneV3VoiceMode } from './PhoneV3ReviewModels';

export class PhoneV3VoiceTask {
  item: PhoneV3ReviewItem;
  candidate: PhoneV3VoiceCandidate;
  key: string;
  fingerprint: string;
  constructor(item: PhoneV3ReviewItem, candidate: PhoneV3VoiceCandidate) {
    this.item = item; this.candidate = candidate;
    this.key = `${item.reviewId}:${candidate.prototypeId}`;
    this.fingerprint = JSON.stringify([item.sourceRevision, item.personId, phoneV3VoiceMode(item), candidate]);
  }
}

export function phoneV3VoiceTasks(items: Array<PhoneV3ReviewItem>, history: boolean = false): Array<PhoneV3VoiceTask> {
  const result: Array<PhoneV3VoiceTask> = [];
  for (let item of items) {
    if (item.kind !== 'voice_identity' || phoneV3ReviewIsHistory(item) !== history) { continue; }
    for (let candidate of phoneV3VoiceCandidates(item)) { result.push(new PhoneV3VoiceTask(item, candidate)); }
  }
  return result;
}

// Stable browsing order, not a second persistent completion ledger.
export class PhoneV3VoiceQueue {
  tasks: Array<PhoneV3VoiceTask> = [];
  index: number = 0;
  skipped: Array<string> = [];
  unavailable: boolean = false;
  open(tasks: Array<PhoneV3VoiceTask>, reviewId: string): void {
    const start = reviewId ? tasks.findIndex((t: PhoneV3VoiceTask): boolean => t.item.reviewId === reviewId) : 0;
    this.unavailable = start < 0;
    if (this.unavailable) { this.tasks = []; this.index = 0; this.skipped = []; return; }
    this.tasks = tasks.slice(start).concat(tasks.slice(0, start)); this.index = 0;
    this.skipped = [];
  }
  current(): PhoneV3VoiceTask | undefined { return this.tasks[this.index]; }
  next(skip: boolean = false): void {
    if (skip && this.current()) { this.skipped.push((this.current() as PhoneV3VoiceTask).key); }
    this.index += 1;
  }
  revisit(items: Array<PhoneV3ReviewItem>, history: boolean): void {
    this.tasks = phoneV3VoiceTasks(items, history).filter((t: PhoneV3VoiceTask): boolean => this.skipped.includes(t.key));
    this.index = 0; this.skipped = [];
  }
}

export class PhoneV3VoiceEvidenceIndex {
  private source: Array<PhoneV3SessionCard> | undefined = undefined;
  private rows: Map<string, PhoneV3Utterance> = new Map<string, PhoneV3Utterance>();
  update(sessions: Array<PhoneV3SessionCard>): void {
    if (sessions === this.source) { return; }
    this.source = sessions; this.rows.clear();
    for (let session of sessions) { for (let row of session.utterances) { this.rows.set(row.utteranceId, row); } }
  }
  resolve(candidate: PhoneV3VoiceCandidate): Array<PhoneV3Utterance> {
    const selected = new Map<string, PhoneV3Utterance>();
    for (let evidence of candidate.evidence) {
      const clip = candidate.clips[evidence.window_index];
      const row = this.rows.get(evidence.utterance_id);
      if (clip === undefined || row === undefined || !Number.isSafeInteger(evidence.window_index) ||
        clip.media_id !== evidence.media_id || clip.start_ms !== evidence.clip_start_ms || clip.end_ms !== evidence.clip_end_ms ||
        row.sessionId !== candidate.sessionId || row.sessionId !== evidence.session_id || row.status !== 'active' ||
        row.revision !== evidence.revision || row.startMs !== evidence.utterance_start_ms || row.endMs !== evidence.utterance_end_ms ||
        evidence.session_end_ms - evidence.session_start_ms !== evidence.clip_end_ms - evidence.clip_start_ms ||
        row.startMs >= evidence.session_end_ms || row.endMs <= evidence.session_start_ms) { continue; }
      selected.set(row.utteranceId, row);
    }
    return Array.from(selected.values());
  }
  sourceChanged(candidate: PhoneV3VoiceCandidate): boolean {
    return candidate.evidence.some((evidence): boolean => {
      const row = this.rows.get(evidence.utterance_id);
      return row !== undefined && (row.status !== 'active' || row.revision !== evidence.revision ||
        row.startMs !== evidence.utterance_start_ms || row.endMs !== evidence.utterance_end_ms || row.sessionId !== evidence.session_id);
    });
  }
}

export function phoneV3EvidencePending(rows: Array<PhoneV3Utterance>): boolean {
  return rows.some((row: PhoneV3Utterance): boolean =>
    [row.annotationFacts.person, row.annotationFacts.sound].some((state: string): boolean =>
      state.length > 0 && state !== 'synced'));
}
