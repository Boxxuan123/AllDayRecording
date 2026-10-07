import { PhoneV3ReminderSchedulerPort } from './PhoneV3Ports';
import { CalendarReminderBackendPort, CalendarReminderStoragePort, CalendarReminderMapping,
  CalendarReminderEvent } from './CalendarReminderPorts';
import { PhoneV3Reminder } from '../domain/PhoneV3Models';

const IDENTIFIER_PREFIX: string = 'allday-calendar-task:';

export class CalendarReminderScheduler implements PhoneV3ReminderSchedulerPort {
  private backend: CalendarReminderBackendPort;
  private storage: CalendarReminderStoragePort;
  private tail: Promise<void> = Promise.resolve();
  private states: Array<CalendarReminderMapping> = [];

  constructor(backend: CalendarReminderBackendPort, storage: CalendarReminderStoragePort) {
    this.backend = backend; this.storage = storage;
  }

  state(taskId: string): string {
    return this.states.find((value: CalendarReminderMapping): boolean => value.taskId === taskId)?.calendarSyncState ?? '';
  }

  reconcile(reminders: Array<PhoneV3Reminder>): Promise<void> {
    return this.serial((): Promise<void> => this.apply(reminders));
  }

  // Explicit user action is the only way to reinstate an externally removed/edited event.
  retry(taskId: string, reminders: Array<PhoneV3Reminder>): Promise<void> {
    return this.serial(async (): Promise<void> => {
      const mappings = await this.storage.calendarMappings();
      const mapping = mappings.find((value: CalendarReminderMapping): boolean => value.taskId === taskId);
      if (mapping !== undefined) {
        if (mapping.calendarSyncState === 'externally_removed') { mapping.calendarEventId = -1; }
        mapping.calendarSyncState = 'reenable';
        await this.storage.saveCalendarMapping(mapping);
      }
      await this.apply(reminders, true);
    });
  }

  private serial(action: () => Promise<void>): Promise<void> {
    const next = this.tail.catch((): void => {}).then(action); this.tail = next; return next;
  }

  private async apply(reminders: Array<PhoneV3Reminder>, request: boolean = false): Promise<void> {
    this.states = await this.storage.calendarMappings();
    const relevant = reminders.filter((task: PhoneV3Reminder): boolean =>
      (task.status === 'scheduled' && Date.parse(task.scheduledAt) > Date.now()) ||
      ((task.status === 'cancelled' || task.status === 'completed') &&
        this.states.some((value: CalendarReminderMapping): boolean => value.taskId === task.eventId &&
          value.calendarSyncState !== 'removed' &&
          (value.calendarEventId >= 0 || value.calendarAccountId >= 0))));
    if (relevant.length === 0) { return; }
    const shouldRequest = request || relevant.some((task: PhoneV3Reminder): boolean =>
      !this.states.some((value: CalendarReminderMapping): boolean => value.taskId === task.eventId && value.calendarSyncState === 'permission_required'));
    let granted: boolean;
    try { granted = await this.backend.permission(shouldRequest); }
    catch (error) {
      for (let task of relevant) { await this.failure(this.mapping(task), error as Object); }
      this.states = await this.storage.calendarMappings(); return;
    }
    if (!granted) {
      for (let task of relevant) {
        const mapping = this.mapping(task); mapping.calendarSyncState = 'permission_required';
        mapping.lastError = '需要日历权限才能按时提醒'; await this.storage.saveCalendarMapping(mapping);
      }
      this.states = await this.storage.calendarMappings(); return;
    }
    let accountId: number;
    let events: Array<CalendarReminderEvent>;
    try {
      const previousAccountId = await this.storage.calendarAccountId();
      accountId = await this.backend.account(previousAccountId);
      if (accountId !== previousAccountId) { await this.storage.saveCalendarAccountId(accountId); }
      events = await this.backend.events(accountId);
    } catch (error) {
      for (let task of relevant) { await this.failure(this.mapping(task), error as Object); }
      this.states = await this.storage.calendarMappings(); return;
    }
    for (let task of relevant) {
      const mapping = this.mapping(task);
      try { await this.applyTask(task, mapping, accountId, events); }
      catch (error) { await this.failure(mapping, error as Object); }
    }
    this.states = await this.storage.calendarMappings();
  }

  private mapping(task: PhoneV3Reminder): CalendarReminderMapping {
    const saved = this.states.find((value: CalendarReminderMapping): boolean => value.taskId === task.eventId);
    if (saved !== undefined) { return saved; }
    const mapping = new CalendarReminderMapping(); mapping.taskId = task.eventId; return mapping;
  }

  private async applyTask(task: PhoneV3Reminder, mapping: CalendarReminderMapping,
    accountId: number, events: Array<CalendarReminderEvent>): Promise<void> {
    const identifier = `${IDENTIFIER_PREFIX}${task.eventId}`;
    let current = events.find((value: CalendarReminderEvent): boolean =>
      (mapping.calendarEventId >= 0 && value.id === mapping.calendarEventId &&
        mapping.calendarAccountId === accountId) || value.identifier === identifier);
    if (task.status === 'cancelled' || task.status === 'completed') {
      // A create can commit in Calendar before its event ID reaches local storage.
      // The durable creating intent and stable identifier still identify the event.
      const owned = events.filter((value: CalendarReminderEvent): boolean =>
        value.identifier === identifier || (mapping.calendarEventId >= 0 &&
          mapping.calendarAccountId === accountId && value.id === mapping.calendarEventId));
      for (let event of owned) {
        await this.backend.remove(accountId, event.id);
      }
      const remaining = await this.backend.events(accountId);
      if (remaining.some((value: CalendarReminderEvent): boolean =>
        value.identifier === identifier || (mapping.calendarEventId >= 0 &&
          mapping.calendarAccountId === accountId && value.id === mapping.calendarEventId))) {
        throw new Error('系统日历事件删除后仍存在');
      }
      mapping.calendarEventId = -1; mapping.calendarSyncState = 'removed'; mapping.lastError = '';
      await this.storage.saveCalendarMapping(mapping); return;
    }
    if (mapping.calendarSyncState === 'externally_removed' || mapping.calendarSyncState === 'externally_modified') { return; }
    if (mapping.calendarEventId >= 0 && current === undefined) {
      mapping.calendarSyncState = 'externally_removed'; mapping.lastError = '';
      await this.storage.saveCalendarMapping(mapping); return;
    }
    if (current !== undefined && mapping.scheduledDueAt.length > 0 && mapping.calendarSyncState !== 'reenable' &&
      (current.startTime !== Date.parse(mapping.scheduledDueAt) || current.endTime !== Date.parse(mapping.scheduledDueAt) + 900000 ||
        current.title !== mapping.scheduledTitle || current.reminderTime.length !== 1 || current.reminderTime[0] !== 0)) {
      // A failed update may have committed in Calendar. Accept that exact desired version on retry.
      if (mapping.calendarSyncState !== 'error' || !matches(current, task)) {
        mapping.calendarSyncState = 'externally_modified'; mapping.lastError = '';
        await this.storage.saveCalendarMapping(mapping); return;
      }
    }
    if (current !== undefined && mapping.calendarSyncState === 'scheduled' && matches(current, task)) { return; }
    const desired = new CalendarReminderEvent(); desired.identifier = identifier;
    desired.title = task.title; desired.startTime = Date.parse(task.scheduledAt); desired.endTime = desired.startTime + 900000;
    if (current === undefined) {
      mapping.calendarAccountId = accountId; mapping.calendarSyncState = 'creating';
      await this.storage.saveCalendarMapping(mapping); // Recovery intent before the external side effect.
      desired.id = await this.backend.create(accountId, desired); events.push(desired); current = desired;
      mapping.calendarEventId = desired.id;
    } else if (!matches(current, task) || mapping.calendarSyncState === 'reenable') {
      desired.id = current.id; await this.backend.update(accountId, desired);
    }
    const verified = (await this.backend.events(accountId)).find((value: CalendarReminderEvent): boolean => value.id === current?.id);
    if (verified === undefined || !matches(verified, task)) { throw new Error('日历事件或到点提醒校验失败'); }
    mapping.calendarAccountId = accountId; mapping.calendarEventId = current.id;
    mapping.scheduledDueAt = task.scheduledAt; mapping.scheduledTitle = task.title;
    mapping.calendarSyncState = 'scheduled'; mapping.lastError = '';
    await this.storage.saveCalendarMapping(mapping);
  }

  private async failure(mapping: CalendarReminderMapping, error: Object): Promise<void> {
    mapping.calendarSyncState = 'error'; mapping.lastError = error instanceof Error ? error.message : JSON.stringify(error);
    await this.storage.saveCalendarMapping(mapping);
  }
}

function matches(event: CalendarReminderEvent, task: PhoneV3Reminder): boolean {
  return event.startTime === Date.parse(task.scheduledAt) && event.endTime === event.startTime + 900000 &&
    event.title === task.title && event.description === '由 AllDayRecording 创建' &&
    event.reminderTime.length === 1 && event.reminderTime[0] === 0;
}
