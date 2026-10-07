import { PhoneV3Utterance } from './PhoneV3Models';

/** Stable identity separates people even when their display names match. */
export function phoneV3SpeakerKey(row: PhoneV3Utterance, sessionId: string): string {
  return row.annotationPersonId.length > 0 ? `person:${row.annotationPersonId}` :
    `sound:${sessionId}:${row.speakerTrackId ?? row.utteranceId}`;
}
