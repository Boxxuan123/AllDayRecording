import { PhonePendingOperation } from '../data/PhoneSyncProjection';
import { PhoneV3Reminder, PhoneV3ReviewItem } from './PhoneV3Models';

export interface PhoneV3ReminderCommand {
  action: string;
  candidate_id?: string;
  event_id?: string;
  title?: string;
  scheduled_at?: string;
}

export interface PhoneV3ReminderContext {
  actor_person_id?: string;
  scheduled_at?: string;
  source_text?: string;
  source?: PhoneV3ReminderSource;
}

export interface PhoneV3ReminderSource {
  recorded_at?: string;
  timezone?: string;
  time_expression?: string;
}

interface ReminderError { message?: string; }

export function reminderConflictMessage(value: string): string {
  try { return (JSON.parse(value) as ReminderError).message ?? '电脑状态已变化，请同步后重新核对'; }
  catch (_) { return '电脑状态已变化，请同步后重新核对'; }
}

export function reminderContext(item: PhoneV3ReviewItem): PhoneV3ReminderContext {
  try { return JSON.parse(item.contextJson) as PhoneV3ReminderContext; }
  catch (_) { return {}; }
}

// Pending user choices survive process death in the existing sync outbox.
// Candidate confirmation waits for the authoritative projection before scheduling.
export function overlayReminderCommands(reminders: Array<PhoneV3Reminder>,
  operations: Array<PhonePendingOperation>): Array<PhoneV3Reminder> {
  for (let operation of operations) {
    if (operation.kind !== 'reminder.task') { continue; }
    const command = operation.payload as PhoneV3ReminderCommand;
    const reminder = reminders.find((value: PhoneV3Reminder): boolean => value.eventId === command.event_id);
    if (reminder === undefined) { continue; }
    reminder.pendingAction = command.action;
    if (command.action === 'cancel') { reminder.status = 'cancelled'; }
    else if (command.action === 'complete') { reminder.status = 'completed'; }
    else if (command.action === 'reschedule' && command.scheduled_at !== undefined) {
      reminder.scheduledAt = command.scheduled_at;
      if (command.title !== undefined) { reminder.title = command.title; }
    }
  }
  return reminders;
}

export function pendingReminderReview(item: PhoneV3ReviewItem,
  operations: Array<PhonePendingOperation>): boolean {
  return operations.some((operation: PhonePendingOperation): boolean =>
    operation.kind === 'reminder.review' &&
    (operation.payload as PhoneV3ReminderCommand).candidate_id === item.sourceId);
}

export function editedReminderTime(value: string): string {
  const local = value.trim().replace(' ', 'T');
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(local)) { throw new Error('时间格式应为 YYYY-MM-DD HH:mm'); }
  const timestamp = Date.parse(local);
  if (!Number.isFinite(timestamp) || timestamp <= Date.now()) { throw new Error('请选择明确的未来时间'); }
  if (localReminderTime(new Date(timestamp).toISOString()).replace(' ', 'T') !== local) {
    throw new Error('日期或时间不存在，请重新选择');
  }
  return new Date(timestamp).toISOString();
}

export function localReminderTime(value: string): string {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) { return ''; }
  const shifted = new Date(date.getTime() - date.getTimezoneOffset() * 60000);
  return shifted.toISOString().slice(0, 16).replace('T', ' ');
}
