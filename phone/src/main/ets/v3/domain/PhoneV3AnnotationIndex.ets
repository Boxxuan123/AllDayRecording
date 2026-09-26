import { PhoneV3SessionCard, PhoneV3Utterance } from './PhoneV3Models';

const snapshotRows: WeakMap<Array<PhoneV3SessionCard>, Map<string, PhoneV3Utterance>> =
  new WeakMap<Array<PhoneV3SessionCard>, Map<string, PhoneV3Utterance>>();

export function indexedUtterances(sessions: Array<PhoneV3SessionCard>): Map<string, PhoneV3Utterance> {
  let rows = snapshotRows.get(sessions);
  if (rows === undefined) {
    rows = new Map<string, PhoneV3Utterance>();
    for (let session of sessions) { for (let row of session.utterances) { rows.set(row.utteranceId, row); } }
    snapshotRows.set(sessions, rows);
  }
  return rows;
}

export function retainAnnotationIndex(previous: Array<PhoneV3SessionCard>, next: Array<PhoneV3SessionCard>): void {
  snapshotRows.set(next, indexedUtterances(previous));
}

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
    const indexed = indexedUtterances(sessions);
    for (let id of this.targetOrder) {
      const row = indexed.get(id);
      if (row !== undefined) { rows.push(row); }
    }
    this.rows = rows;
    return true;
  }
}
