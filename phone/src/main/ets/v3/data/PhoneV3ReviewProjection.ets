import { validateV3ReviewItemDto } from '../contracts/V3ContractModels';
import { PhoneV3ProjectionRow, PhoneV3ReviewItem } from '../domain/PhoneV3Models';

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
