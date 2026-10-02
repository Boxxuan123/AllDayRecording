export interface PhoneDailyParticipant {
  key: string;
  kind: string;
  label: string;
  status: string;
  person_id?: string;
  event_ids?: Array<string>;
}

export interface PhoneDailyEvidence {
  session_id: string;
  utterance_id: string;
  revision: number;
  start_ms: number;
  end_ms: number;
  start_at: string;
  end_at: string;
  text: string;
  participant: PhoneDailyParticipant;
}

export interface PhoneDailyEvent {
  event_id: string;
  revision: number;
  local_date: string;
  timezone: string;
  title: string;
  start_at: string;
  end_at: string;
  category: string;
  derivation_status: string;
  participants: Array<PhoneDailyParticipant>;
  evidence_snapshots: Array<PhoneDailyEvidence>;
  linked_task_ids: Array<string>;
}

export interface PhoneDailyItem {
  text?: string;
  title?: string;
  task_id?: string;
  status?: string;
  scheduled_at?: string;
  event_ids: Array<string>;
}

export interface PhoneDailyObjective {
  date: string;
  headline: string;
  source_event_ids: Array<string>;
  source_event_revisions: Record<string, number>;
  key_events: Array<PhoneDailyItem>;
  tasks_created: Array<PhoneDailyItem>;
  tasks_completed: Array<PhoneDailyItem>;
  tasks_pending: Array<PhoneDailyItem>;
  people_interacted: Array<PhoneDailyParticipant>;
  unresolved_items: Array<PhoneDailyItem>;
}

export interface PhoneDailySummary {
  summary_id: string;
  revision: number;
  summary_date: string;
  timezone: string;
  derivation_status: string;
  objective: PhoneDailyObjective;
}

export class PhoneDailyCache {
  summaries: Array<PhoneDailySummary> = [];
  events: Array<PhoneDailyEvent> = [];
}

export function phoneDailyStatus(status: string): string {
  if (status === 'completed') { return '已完成'; }
  if (status === 'cancelled') { return '已取消'; }
  return '待办';
}
