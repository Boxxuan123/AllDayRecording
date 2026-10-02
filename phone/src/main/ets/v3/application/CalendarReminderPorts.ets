// System calendar metadata belongs to the reminder adapter, not the task domain.
export class CalendarReminderEvent {
  id: number = -1;
  identifier: string = '';
  title: string = '';
  startTime: number = 0;
  endTime: number = 0;
  description: string = '由 AllDayRecording 创建';
  reminderTime: Array<number> = [0];
}

export interface CalendarReminderBackendPort {
  permission(request: boolean): Promise<boolean>;
  account(preferredId: number): Promise<number>;
  events(accountId: number): Promise<Array<CalendarReminderEvent>>;
  create(accountId: number, event: CalendarReminderEvent): Promise<number>;
  update(accountId: number, event: CalendarReminderEvent): Promise<void>;
  remove(accountId: number, eventId: number): Promise<void>;
}

export class CalendarReminderMapping {
  taskId: string = '';
  calendarAccountId: number = -1;
  calendarEventId: number = -1;
  scheduledDueAt: string = '';
  scheduledTitle: string = '';
  calendarSyncState: string = 'creating';
  lastError: string = '';
}

export interface CalendarReminderStoragePort {
  calendarAccountId(): Promise<number>;
  saveCalendarAccountId(id: number): Promise<void>;
  calendarMappings(): Promise<Array<CalendarReminderMapping>>;
  saveCalendarMapping(mapping: CalendarReminderMapping): Promise<void>;
}
