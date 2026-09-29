import { validateV3ReviewItemDto } from '../contracts/V3ContractModels';
import { PhoneV3ProjectionRow, PhoneV3ReviewItem } from '../domain/PhoneV3Models';
import { DeviceV3ReviewActionRequest } from '../../computer/ComputerTransferProtocol';

interface PurityOverlayContext {
  review_lane?: string;
  purity_review?: PurityOverlayAnswer;
  local_pending?: boolean;
}

interface PurityOverlayAnswer {
  primary_speaker_person_id: string | null;
  primary_speaker_unknown: boolean;
  purity: string;
  other_speaker_ids: Array<string>;
  quality_flags: Array<string>;
}

export function overlayPendingPurityReviews(items: Array<PhoneV3ReviewItem>,
  pending: Array<DeviceV3ReviewActionRequest>): Array<PhoneV3ReviewItem> {
  const latest = new Map<string, DeviceV3ReviewActionRequest>();
  for (const request of pending) { latest.set(request.review_id, request); }
  return items.map((item: PhoneV3ReviewItem): PhoneV3ReviewItem => {
    const request = latest.get(item.reviewId);
    if (item.kind !== 'speaker_profile_purity' || request === undefined) { return item; }
    const context = JSON.parse(item.contextJson) as PurityOverlayContext;
    context.review_lane = request.action === 'undo' ? 'primary' : 'history';
    context.local_pending = true;
    if (request.action === 'undo') { context.purity_review = undefined; }
    else {
      context.purity_review = {
        primary_speaker_person_id: request.primary_speaker_person_id ?? null,
        primary_speaker_unknown: request.primary_speaker_unknown === true,
        purity: request.purity ?? '', other_speaker_ids: request.other_speaker_ids ?? [],
        quality_flags: request.quality_flags ?? []
      };
    }
    return new PhoneV3ReviewItem(item.reviewId, item.kind, item.priority, item.sourceId,
      item.sourceRevision, item.sessionId, item.personId, item.title, item.summary,
      item.reason, item.evidenceCount, item.createdAt, item.updatedAt, JSON.stringify(context));
  });
}

export function phoneV3ReviewItems(rows: Array<PhoneV3ProjectionRow>): Array<PhoneV3ReviewItem> {
  const items: Array<Object> = [];
  for (let index = 0; index < rows.length; index += 1) {
    try {
      items.push(JSON.parse(rows[index].payloadJson) as Object);
    } catch (_error) {
      // An unreadable cached row is not actionable and must not block the inbox.
    }
  }
  return phoneV3ReviewSnapshotItems(items);
}

export function phoneV3ReviewSnapshotItems(items: Array<Object>): Array<PhoneV3ReviewItem> {
  const values: Array<PhoneV3ReviewItem> = [];
  for (let index = 0; index < items.length; index += 1) {
    try {
      const payload = validateV3ReviewItemDto(items[index]);
      values.push(new PhoneV3ReviewItem(
        payload.review_id, payload.kind, payload.priority, payload.source_id,
        payload.source_revision, payload.session_id, payload.person_id,
        payload.title, payload.summary, payload.reason, payload.evidence_count,
        payload.created_at, payload.updated_at, JSON.stringify(payload.context)));
    } catch (_error) {
      // Older peers can expose an identity-only review row. Keep the cache usable
      // and omit it until the richer, actionable review projection is available.
    }
  }
  values.sort((left: PhoneV3ReviewItem, right: PhoneV3ReviewItem): number => {
    if (left.priority !== right.priority) {
      return left.priority === 'high' ? -1 : 1;
    }
    return Date.parse(left.createdAt) - Date.parse(right.createdAt);
  });
  return values;
}
