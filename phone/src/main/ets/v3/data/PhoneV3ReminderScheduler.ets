import { common } from '@kit.AbilityKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { PhoneV3ReminderSchedulerPort } from '../application/PhoneV3Ports';
import { PhoneV3Reminder } from '../domain/PhoneV3Models';

const GROUP_PREFIX: string = 'allday-v33:';
const BUNDLE_NAME: string = 'AllDayRecording.huawei.com';

export class PhoneV3ReminderScheduler implements PhoneV3ReminderSchedulerPort {
  private context: common.UIAbilityContext;
  private tail: Promise<void> = Promise.resolve();

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  reconcile(reminders: Array<PhoneV3Reminder>): Promise<void> {
    const next = this.tail.catch((): void => {}).then((): Promise<void> => this.apply(reminders));
    this.tail = next;
    return next;
  }

  private async apply(reminders: Array<PhoneV3Reminder>): Promise<void> {
    const desired = futureReminders(reminders);
    let current = await reminderAgentManager.getAllValidReminders();
    console.info(`Reminder inventory: system=${current.length}, desired=${desired.length}, owned=${current.filter(
      (item: reminderAgentManager.ReminderInfo): boolean => (item.reminderReq.groupId ?? '').startsWith(GROUP_PREFIX)).length}`);
    const retained = new Set<string>();
    for (let index = 0; index < current.length; index += 1) {
      const groupId = current[index].reminderReq.groupId;
      if (typeof groupId === 'string' && groupId.startsWith(GROUP_PREFIX) &&
        (findByGroup(desired, groupId) === undefined || retained.has(groupId))) {
        await reminderAgentManager.cancelReminder(current[index].reminderId);
      } else if (typeof groupId === 'string') {
        retained.add(groupId);
      }
    }
    if (desired.length === 0) { return; }
    if (!await notificationManager.isNotificationEnabled()) {
      // An obsolete due time must not survive a refused permission request.
      for (let reminder of desired) {
        const existing = findCurrent(current, reminderGroup(reminder));
        if (existing !== undefined && !sameRequest(existing.reminderReq, calendarRequest(reminder, reminderGroup(reminder)))) {
          await reminderAgentManager.cancelReminder(existing.reminderId);
          current = current.filter((item: reminderAgentManager.ReminderInfo): boolean => item.reminderId !== existing.reminderId);
        }
      }
      await notificationManager.requestEnableNotification(this.context);
      if (!await notificationManager.isNotificationEnabled()) { throw new Error('通知权限尚未允许'); }
    }
    for (let index = 0; index < desired.length; index += 1) {
      const reminder = desired[index];
      const groupId = reminderGroup(reminder);
      const existing = findCurrent(current, groupId);
      const request = calendarRequest(reminder, groupId);
      if (existing === undefined) {
        await reminderAgentManager.publishReminder(request);
        continue;
      }
      if (sameRequest(existing.reminderReq, request)) { continue; }
      try {
        await reminderAgentManager.updateReminder(existing.reminderId, request);
      } catch (error) {
        await reminderAgentManager.cancelReminder(existing.reminderId);
        await reminderAgentManager.publishReminder(request);
      }
    }
  }
}

function sameRequest(current: reminderAgentManager.ReminderRequest,
  desired: reminderAgentManager.ReminderRequestCalendar): boolean {
  if (current.reminderType !== reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR) { return false; }
  const calendar = current as reminderAgentManager.ReminderRequestCalendar;
  return calendar.dateTime.year === desired.dateTime.year && calendar.dateTime.month === desired.dateTime.month &&
    calendar.dateTime.day === desired.dateTime.day && calendar.dateTime.hour === desired.dateTime.hour &&
    calendar.dateTime.minute === desired.dateTime.minute && (calendar.dateTime.second ?? 0) === (desired.dateTime.second ?? 0) &&
    (calendar.fixedTimeZone ?? 0) === (desired.fixedTimeZone ?? 0) && current.content === desired.content &&
    current.title === desired.title && current.notificationId === desired.notificationId;
}

function futureReminders(reminders: Array<PhoneV3Reminder>): Array<PhoneV3Reminder> {
  const now = Date.now();
  return reminders.filter((reminder: PhoneV3Reminder): boolean =>
    reminder.status === 'scheduled' && Date.parse(reminder.scheduledAt) > now);
}

function findByGroup(reminders: Array<PhoneV3Reminder>, groupId: string): PhoneV3Reminder | undefined {
  for (let index = 0; index < reminders.length; index += 1) {
    if (reminderGroup(reminders[index]) === groupId) {
      return reminders[index];
    }
  }
  return undefined;
}

function findCurrent(current: Array<reminderAgentManager.ReminderInfo>,
  groupId: string): reminderAgentManager.ReminderInfo | undefined {
  for (let index = 0; index < current.length; index += 1) {
    if (current[index].reminderReq.groupId === groupId) {
      return current[index];
    }
  }
  return undefined;
}

function calendarRequest(reminder: PhoneV3Reminder,
  groupId: string): reminderAgentManager.ReminderRequestCalendar {
  const date = new Date(reminder.scheduledAt);
  // Calendar's native constructor validates local time before reading the
  // optional time-zone mode. UTC fields can therefore look expired on UTC+8
  // devices. Convert the persisted absolute instant to the device's local time.
  return {
    reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
    dateTime: {
      year: date.getFullYear(),
      month: date.getMonth() + 1,
      day: date.getDate(),
      hour: date.getHours(),
      minute: date.getMinutes(),
      second: date.getSeconds()
    },
    title: '全天候录音提醒',
    content: reminder.location === null || reminder.location.length === 0 ?
      reminder.title : `${reminder.title} · ${reminder.location}`,
    expiredContent: reminder.title,
    groupId: groupId,
    notificationId: notificationId(reminder.eventId),
    ringDuration: 0,
    tapDismissed: true,
    wantAgent: {
      pkgName: BUNDLE_NAME,
      abilityName: 'EntryAbility'
    }
  };
}

function reminderGroup(reminder: PhoneV3Reminder): string {
  return `${GROUP_PREFIX}${reminder.eventId}`;
}

function notificationId(value: string): number {
  let hash = 17;
  for (let index = 0; index < value.length; index += 1) {
    hash = (hash * 31 + value.charCodeAt(index)) & 0x7FFFFFFF;
  }
  return hash === 0 ? 1 : hash;
}
