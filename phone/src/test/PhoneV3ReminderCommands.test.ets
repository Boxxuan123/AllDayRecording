import { describe, expect, it } from '@ohos/hypium';
import { PhoneV3ReminderCommand, overlayReminderCommands, localReminderTime, editedReminderTime } from '../main/ets/v3/domain/PhoneV3ReminderCommands';
import { PhonePendingOperation } from '../main/ets/v3/data/PhoneSyncProjection';
import { PhoneV3Reminder } from '../main/ets/v3/domain/PhoneV3Models';

export default function phoneV3ReminderCommandsTest() {
  describe('PhoneV3ReminderCommands', () => {
    it('pendingCancellationRemovesActiveSchedule', 0, () => {
      const reminder = new PhoneV3Reminder('e', 's', 1, 'c', 'PRODUCT_REMINDER_E2E_TEST', 'self',
        'not_applicable', [], '2099-01-01T00:00:00Z', null, 'scheduled', '');
      const payload: PhoneV3ReminderCommand = { event_id: 'e', action: 'cancel' };
      const operation: PhonePendingOperation = { operation_id: 'op', kind: 'reminder.task', base_revision: 1,
        payload: payload, attempt_count: 0 };
      overlayReminderCommands([reminder], [operation]);
      expect(reminder.status).assertEqual('cancelled');
    });
    it('pendingCompletionStopsReminder', 0, () => {
      const reminder = new PhoneV3Reminder('e', 's', 1, 'c', '测试', 'self', 'not_applicable', [],
        '2099-01-01T00:00:00Z', null, 'scheduled', '');
      const payload: PhoneV3ReminderCommand = { event_id: 'e', action: 'complete' };
      const operation: PhonePendingOperation = { operation_id: 'op', kind: 'reminder.task', base_revision: 1,
        payload: payload, attempt_count: 0 };
      overlayReminderCommands([reminder], [operation]);
      expect(reminder.status).assertEqual('completed');
    });
    it('confirmationAloneNeverSchedules', 0, () => {
      const payload: PhoneV3ReminderCommand = { candidate_id: 'c', action: 'confirm' };
      const operation: PhonePendingOperation = { operation_id: 'op', kind: 'reminder.review', base_revision: null,
        payload: payload, attempt_count: 0 };
      const reminders: Array<PhoneV3Reminder> = [];
      expect(overlayReminderCommands(reminders, [operation]).length).assertEqual(0);
    });
    it('editorRoundTripsAbsoluteFutureTime', 0, () => {
      const value = '2099-01-01T00:00:00.000Z';
      expect(editedReminderTime(localReminderTime(value))).assertEqual(value);
    });
  });
}
