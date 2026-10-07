import { relationalStore } from '@kit.ArkData';
import { CalendarReminderMapping, CalendarReminderStoragePort } from '../application/CalendarReminderPorts';
import { PhoneProjectionTransaction } from './PhoneProjectionTransaction';

/** Calendar account and task-event mapping persistence; writes share the projection transaction owner. */
export class PhoneCalendarMappingStore implements CalendarReminderStoragePort {
  private store: relationalStore.RdbStore;
  private transactions: PhoneProjectionTransaction;
  constructor(store: relationalStore.RdbStore, transactions: PhoneProjectionTransaction) {
    this.store = store; this.transactions = transactions;
  }

  async calendarAccountId(): Promise<number> {
    const result = await this.store.querySql('SELECT calendar_account_id FROM calendar_reminder_account WHERE singleton_id=1');
    try { return result.goToNextRow() ? result.getLong(0) : -1; } finally { result.close(); }
  }

  async saveCalendarAccountId(id: number): Promise<void> {
    await this.transactions.beginTransaction();
    try {
      await this.store.executeSql('INSERT OR REPLACE INTO calendar_reminder_account(singleton_id,calendar_account_id) VALUES(1,?)', [id]);
      await this.transactions.commit();
    } catch (error) { await this.transactions.rollback(); throw error as Error; }
  }

  async calendarMappings(): Promise<Array<CalendarReminderMapping>> {
    const result = await this.store.querySql(`SELECT task_id,calendar_account_id,calendar_event_id,
      scheduled_due_at,scheduled_title,calendar_sync_state,last_error FROM calendar_reminder_mappings`);
    const values: Array<CalendarReminderMapping> = [];
    try {
      while (result.goToNextRow()) {
        const mapping = new CalendarReminderMapping();
        mapping.taskId = result.getString(0); mapping.calendarAccountId = result.getLong(1);
        mapping.calendarEventId = result.getLong(2); mapping.scheduledDueAt = result.getString(3);
        mapping.scheduledTitle = result.getString(4); mapping.calendarSyncState = result.getString(5);
        mapping.lastError = result.getString(6); values.push(mapping);
      }
    } finally { result.close(); }
    return values;
  }

  async saveCalendarMapping(mapping: CalendarReminderMapping): Promise<void> {
    await this.transactions.beginTransaction();
    try {
      await this.store.executeSql(`INSERT OR REPLACE INTO calendar_reminder_mappings
        (task_id,calendar_account_id,calendar_event_id,scheduled_due_at,scheduled_title,calendar_sync_state,last_error)
        VALUES(?,?,?,?,?,?,?)`, [mapping.taskId, mapping.calendarAccountId, mapping.calendarEventId,
        mapping.scheduledDueAt, mapping.scheduledTitle, mapping.calendarSyncState, mapping.lastError]);
      await this.transactions.commit();
    } catch (error) { await this.transactions.rollback(); throw error as Error; }
  }

}
