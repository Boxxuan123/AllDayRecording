import { PhoneV3SessionCard, PhoneV3Utterance, PhoneV3Conflict } from './PhoneV3Models';
import { PhonePendingOperation } from '../data/PhoneSyncProjection';

export interface PhoneV3AnnotationSentence {
  utterance_id: string;
  revision: number;
  session_id?: string;
  start_ms?: number;
  end_ms?: number;
  text: string;
  speaker_label: string;
  sound_kind?: string;
}
export interface PhoneV3LocalAnnotation {
  depends_on?: Array<string>;
  selections: Array<PhoneV3AnnotationSentence>;
  person_id?: string;
  new_person_id?: string;
  display_name?: string;
  person_name: string;
  sound_kind?: string;
}

export function applyLocalAnnotations(sessions: Array<PhoneV3SessionCard>,
  operations: Array<PhonePendingOperation>): void {
  const rows = new Map<string, PhoneV3Utterance>();
  for (let session of sessions) {
    for (let row of session.utterances) { rows.set(row.utteranceId, row); }
  }
  applyAnnotationRows(rows, operations);
}

export function applyAnnotationRows(rows: Map<string, PhoneV3Utterance>, operations: Array<PhonePendingOperation>): void {
  for (let operation of operations) {
    const annotation = operation.payload as PhoneV3LocalAnnotation;
    for (let selection of annotation.selections) {
      if ((operation.projected_resource_ids ?? []).indexOf(selection.utterance_id) >= 0) { continue; }
      const row = rows.get(selection.utterance_id);
      if (row === undefined) { continue; }
      if (annotation.sound_kind !== undefined) { row.soundKind = annotation.sound_kind; }
      else {
        row.speakerLabel = annotation.person_name;
        row.annotationPersonId = annotation.person_id ?? annotation.new_person_id ?? '';
      }
      const dimension = annotation.sound_kind !== undefined ? row.annotationFacts.sound : row.annotationFacts.person;
      const stale = (dimension === 'review' && selection.revision < row.revision) || (selection.session_id !== undefined && selection.session_id !== row.sessionId) ||
        (selection.start_ms !== undefined && selection.start_ms !== row.startMs) ||
        (selection.end_ms !== undefined && selection.end_ms !== row.endMs) || row.status !== 'active';
      const state = stale ? 'review' : operation.applied_revision !== undefined ? 'accepted' :
        operation.last_error ? 'failed' : 'pending';
      if (annotation.sound_kind !== undefined) { row.annotationFacts.sound = state; }
      else { row.annotationFacts.person = state; }
      if (stale) { row.annotationFacts.reason = '录音来源范围已变化，请重新核对'; }
      row.annotationPending = row.annotationPending || operation.applied_revision === undefined;
    }
  }
}

export function annotationRows(sessions: Array<PhoneV3SessionCard>,
  annotation: PhoneV3LocalAnnotation): Array<PhoneV3Utterance> {
  const ids = new Set<string>(annotation.selections.map((value: PhoneV3AnnotationSentence): string => value.utterance_id));
  const rows: Array<PhoneV3Utterance> = [];
  for (let session of sessions) {
    for (let row of session.utterances) { if (ids.has(row.utteranceId)) { rows.push(row); } }
  }
  return rows;
}

// Conflicts retain the original selections after the outbox operation is removed.
export function applyAnnotationConflicts(sessions: Array<PhoneV3SessionCard>, conflicts: Array<PhoneV3Conflict>): void {
  const rows = new Map<string, PhoneV3Utterance>();
  for (let session of sessions) {
    for (let row of session.utterances) { rows.set(row.utteranceId, row); }
  }
  for (let conflict of conflicts) {
    if (conflict.kind !== 'speaker.assign' && conflict.kind !== 'segment.classify') { continue; }
    try {
      const payload = JSON.parse(conflict.payloadJson) as PhoneV3LocalAnnotation;
      for (let selection of payload.selections ?? []) {
        const row = rows.get(selection.utterance_id);
        if (row === undefined) { continue; }
        if (conflict.kind === 'speaker.assign') {
          row.annotationFacts.person = 'review';
          row.annotationPersonId = payload.person_id ?? payload.new_person_id ?? '';
          row.speakerLabel = payload.person_name;
        } else {
          row.annotationFacts.sound = 'review';
          row.soundKind = payload.sound_kind ?? row.soundKind;
        }
        row.annotationFacts.reason = conflict.status === 'rejected' ?
          '电脑未接受这次标注，请到审核页核对；手机选择已保留' : '标注与电脑结果冲突，请到审核页核对；手机选择已保留';
      }
    } catch (error) { /* Malformed diagnostics must not hide unrelated rows. */ }
  }
}
