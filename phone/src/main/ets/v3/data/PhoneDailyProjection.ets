import { DeviceV3Change } from '../../computer/ComputerTransferProtocol';
import { PhoneDailyEvent, PhoneDailySummary } from '../domain/PhoneV3DailyModels';

const ID: RegExp = /^(?:[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}|[0-9A-HJKMNP-TV-Z]{26})$/;

export function validateDailyChange(change: DeviceV3Change): void {
  if (change.operation !== 'upsert') { return; }
  if (change.resource_type === 'daily_event') {
    const event = change.resource as PhoneDailyEvent;
    if (event.event_id !== change.resource_id || event.revision !== change.revision ||
      typeof event.title !== 'string' || typeof event.local_date !== 'string' ||
      !Array.isArray(event.participants) || !Array.isArray(event.linked_task_ids) ||
      !Array.isArray(event.evidence_snapshots) || event.evidence_snapshots.length === 0) {
      throw new Error('每日事件缺少来源证据');
    }
    for (let evidence of event.evidence_snapshots) {
      if (!ID.test(evidence.utterance_id) || !ID.test(evidence.session_id) ||
        !Number.isSafeInteger(evidence.revision) || evidence.revision < 1 ||
        !Number.isSafeInteger(evidence.start_ms) || !Number.isSafeInteger(evidence.end_ms) ||
        evidence.start_ms < 0 || evidence.end_ms <= evidence.start_ms ||
        typeof evidence.text !== 'string' || evidence.text.trim().length === 0 ||
        evidence.participant === undefined || ['self', 'known', 'unknown'].indexOf(evidence.participant.kind) < 0 ||
        (evidence.participant.kind === 'known' && !ID.test(evidence.participant.person_id ?? ''))) {
        throw new Error('每日事件来源范围无效');
      }
    }
  } else if (change.resource_type === 'daily_summary') {
    const summary = change.resource as PhoneDailySummary;
    const value = summary.objective;
    if (summary.summary_id !== change.resource_id || summary.revision !== change.revision ||
      value === undefined || typeof value.headline !== 'string' ||
      !Array.isArray(value.source_event_ids) || value.source_event_revisions === undefined ||
      !Array.isArray(value.key_events) || !Array.isArray(value.tasks_created) ||
      !Array.isArray(value.tasks_completed) || !Array.isArray(value.tasks_pending) ||
      !Array.isArray(value.people_interacted) || !Array.isArray(value.unresolved_items)) {
      throw new Error('每日总结结构无效');
    }
    for (let item of value.key_events.concat(value.tasks_created, value.tasks_completed,
      value.tasks_pending, value.unresolved_items)) {
      if (!Array.isArray(item.event_ids) || item.event_ids.length === 0 ||
        item.event_ids.some((id: string): boolean => value.source_event_ids.indexOf(id) < 0)) {
        throw new Error('每日总结条目缺少事件来源');
      }
    }
  }
}
