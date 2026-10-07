import { DeviceV3ReviewActionRequest } from '../../computer/ComputerTransferProtocol';
import { PhoneV3Snapshot } from '../domain/PhoneV3Models';
import { phoneV3VoiceTasks, PhoneV3VoiceEvidenceIndex, phoneV3EvidencePending } from '../domain/PhoneV3VoiceReviewTask';

/** Validates the current evidence before a voice review command is submitted. */
export function voiceReviewCommand(reviewId: string, action: string, prototypeId: string,
  displayName: string, snapshot: PhoneV3Snapshot, samplePlayed: boolean): DeviceV3ReviewActionRequest | undefined {
  if (prototypeId.length > 0 && (action === 'confirm' || action === 'reject') && !samplePlayed) {
    return undefined;
  }
  const request: DeviceV3ReviewActionRequest = { review_id: reviewId, action: action };
  const task = phoneV3VoiceTasks(snapshot.reviewItems, action === 'retract').find(
    (value): boolean => value.item.reviewId === reviewId && value.candidate.prototypeId === prototypeId);
  if (prototypeId && task !== undefined) {
    const index = new PhoneV3VoiceEvidenceIndex(); index.update(snapshot.sessions);
    if (action !== 'retract' &&
      (index.sourceChanged(task.candidate) || phoneV3EvidencePending(index.resolve(task.candidate)))) {
      throw new Error('依据已修改，等待同步/样本更新');
    }
    if (task.candidate.reviewKey) { request.expected_review_key = task.candidate.reviewKey; }
  }
  if (prototypeId.length > 0) { request.prototype_id = prototypeId; }
  if (displayName.trim().length > 0) { request.display_name = displayName.trim(); }
  if (action === 'ignore' || action === 'reject') { request.reason = '手机审核未采纳'; }
  return request;
}

/** Builds the existing purity and blind review contract without changing its meaning. */
export function purityReviewCommand(reviewId: string, personId: string, unknown: boolean,
  purity: string, others: Array<string>, flags: Array<string>, undo: boolean,
  unknownKind: string, reviewSchemaVersion: number, composition: string,
  boundary: string): DeviceV3ReviewActionRequest {
  const request: DeviceV3ReviewActionRequest = { review_id: reviewId, action: undo ? 'undo' : 'submit' };
  if (!undo) {
    request.primary_speaker_person_id = unknown ? null : personId;
    request.primary_speaker_unknown = unknown;
    if (reviewId.startsWith('blind:')) { request.unknown_kind = unknown ? unknownKind : 'none'; }
    if (reviewId.startsWith('blind:') && reviewSchemaVersion === 2) {
      request.review_schema_version = 2;
      request.speaker_composition = composition;
      request.boundary_quality = boundary;
    } else { request.purity = purity; }
    request.other_speaker_ids = others;
    request.quality_flags = flags;
  }
  return request;
}
