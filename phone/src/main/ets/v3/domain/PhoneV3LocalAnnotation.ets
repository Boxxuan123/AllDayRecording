import { PhoneV3SessionCard, PhoneV3Utterance } from './PhoneV3Models';
import { PhonePendingOperation } from '../data/PhoneSyncProjection';

export interface PhoneV3AnnotationSentence {
  utterance_id: string;
  revision: number;
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
