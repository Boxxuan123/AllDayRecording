import { common } from '@kit.AbilityKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { PhoneV3ReminderSchedulerPort } from '../application/PhoneV3Ports';
import { PhoneV3Reminder } from '../domain/PhoneV3Models';

const GROUP_PREFIX: string = 'allday-v33:';
const BUNDLE_NAME: string = 'AllDayRecording.huawei.com';

export class PhoneV3ReminderScheduler implements PhoneV3ReminderSchedulerPort {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async reconcile(reminders: Array<PhoneV3Reminder>): Promise<void> {
    if (!await notificationManager.isNotificationEnabled()) {
      await notificationManager.requestEnableNotification(this.context);
    }
    const desired = futureReminders(reminders);
    const current = await reminderAgentManager.getAllValidReminders();
    for (let index = 0; index < current.length; index += 1) {
      const groupId = current[index].reminderReq.groupId;
      if (typeof groupId === 'string' && groupId.startsWith(GROUP_PREFIX) &&
        findByGroup(desired, groupId) === undefined) {
        await reminderAgentManager.cancelReminder(current[index].reminderId);
      }
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
      try {
        await reminderAgentManager.updateReminder(existing.reminderId, request);
      } catch (error) {
        await reminderAgentManager.cancelReminder(existing.reminderId);
        await reminderAgentManager.publishReminder(request);
      }
    }
  }
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
  return {
    reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
    dateTime: {
      year: date.getUTCFullYear(),
      month: date.getUTCMonth() + 1,
      day: date.getUTCDate(),
      hour: date.getUTCHours(),
      minute: date.getUTCMinutes(),
      second: date.getUTCSeconds()
    },
    fixedTimeZone: reminderAgentManager.TimeZoneType.FIXED_TIME_ZONE,
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
