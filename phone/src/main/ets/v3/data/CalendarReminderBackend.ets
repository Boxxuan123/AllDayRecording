import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { calendarManager } from '@kit.CalendarKit';
import { CalendarReminderBackendPort, CalendarReminderEvent } from '../application/CalendarReminderPorts';

const PERMISSIONS: Array<Permissions> = ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR'];
const ACCOUNT_NAME: string = 'AllDayRecording';

export class CalendarReminderBackend implements CalendarReminderBackendPort {
  private context: common.UIAbilityContext;
  private manager: calendarManager.CalendarManager;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.manager = calendarManager.getCalendarManager(context);
  }

  async permission(request: boolean): Promise<boolean> {
    const access = abilityAccessCtrl.createAtManager();
    const token = this.context.applicationInfo.accessTokenId;
    let granted = true;
    for (let permission of PERMISSIONS) {
      if (await access.checkAccessToken(token, permission) !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        granted = false;
      }
    }
    if (granted || !request) { return granted; }
    const result = await access.requestPermissionsFromUser(this.context, PERMISSIONS);
    return result.authResults.length === PERMISSIONS.length && result.authResults.every((value: number): boolean => value === 0);
  }

  async account(preferredId: number): Promise<number> {
    const calendars = await this.manager.getAllCalendars();
    const owned = calendars.filter((calendar: calendarManager.Calendar): boolean =>
      calendar.getAccount().name === ACCOUNT_NAME && calendar.getAccount().type === calendarManager.CalendarType.LOCAL);
    let calendar = owned.find((value: calendarManager.Calendar): boolean => value.id === preferredId);
    if (calendar === undefined) { calendar = owned[0]; }
    if (calendar === undefined) {
      calendar = await this.manager.createCalendar({ name: ACCOUNT_NAME,
        type: calendarManager.CalendarType.LOCAL, displayName: ACCOUNT_NAME });
      await calendar.setConfig({ enableReminder: true });
    }
    // Recover a first-time account creation whose configuration call failed.
    // Once the ID is persisted, keep a user's later account settings intact.
    if (preferredId < 0 && calendar.getConfig().enableReminder !== true) {
      await calendar.setConfig({ enableReminder: true });
    }
    if (calendar.id < 0) { throw new Error('日历账户创建失败'); }
    return calendar.id;
  }

  async events(accountId: number): Promise<Array<CalendarReminderEvent>> {
    const calendar = await this.calendar(accountId);
    // API 20+ includes identifier and reminderTime in the default query fields.
    const values = await calendar.getEvents();
    return values.map((value: calendarManager.Event): CalendarReminderEvent => {
      const event = new CalendarReminderEvent();
      event.id = value.id ?? -1; event.identifier = value.identifier ?? '';
      event.title = value.title ?? ''; event.startTime = value.startTime; event.endTime = value.endTime;
      event.description = value.description ?? ''; event.reminderTime = value.reminderTime ?? [];
      return event;
    });
  }

  async create(accountId: number, event: CalendarReminderEvent): Promise<number> {
    const id = await (await this.calendar(accountId)).addEvent(this.nativeEvent(event));
    if (id < 0) { throw new Error('日历事件创建失败'); }
    return id;
  }

  async update(accountId: number, event: CalendarReminderEvent): Promise<void> {
    await (await this.calendar(accountId)).updateEvent(this.nativeEvent(event));
  }

  async remove(accountId: number, eventId: number): Promise<void> {
    await (await this.calendar(accountId)).deleteEvent(eventId);
  }

  private async calendar(accountId: number): Promise<calendarManager.Calendar> {
    const calendars = await this.manager.getAllCalendars();
    const calendar = calendars.find((value: calendarManager.Calendar): boolean => value.id === accountId &&
      value.getAccount().name === ACCOUNT_NAME && value.getAccount().type === calendarManager.CalendarType.LOCAL);
    if (calendar === undefined) { throw new Error('应用日历账户不存在'); }
    return calendar;
  }

  private nativeEvent(event: CalendarReminderEvent): calendarManager.Event {
    return { id: event.id < 0 ? undefined : event.id, type: calendarManager.EventType.NORMAL,
      identifier: event.identifier, title: event.title, startTime: event.startTime, endTime: event.endTime,
      isAllDay: false, description: event.description, reminderTime: event.reminderTime };
  }
}
