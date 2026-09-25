import { PhoneV3SessionCard, PhoneV3Utterance } from './PhoneV3Models';

// Snapshots replace the sessions array. Playback ticks and form edits do not.
export class PhoneV3AnnotationIndex {
  private targetIds: Set<string> = new Set<string>();
  private targetOrder: Array<string> = [];
  private sessions: Array<PhoneV3SessionCard> | undefined = undefined;
  rows: Array<PhoneV3Utterance> = [];

  setTargets(targets: Array<PhoneV3Utterance>): void {
    if (targets.length === this.targetOrder.length && targets.every(
      (value: PhoneV3Utterance, index: number): boolean => value.utteranceId === this.targetOrder[index])) {
      return;
    }
    this.targetOrder = targets.map((value: PhoneV3Utterance): string => value.utteranceId);
    this.targetIds = new Set<string>(this.targetOrder);
    this.sessions = undefined;
  }

  update(sessions: Array<PhoneV3SessionCard>): boolean {
    if (this.sessions === sessions) { return false; }
    this.sessions = sessions;
    const rows: Array<PhoneV3Utterance> = [];
    for (let session of sessions) {
      for (let utterance of session.utterances) {
        if (this.targetIds.has(utterance.utteranceId)) { rows.push(utterance); }
      }
    }
    this.rows = rows;
    return true;
  }
}
