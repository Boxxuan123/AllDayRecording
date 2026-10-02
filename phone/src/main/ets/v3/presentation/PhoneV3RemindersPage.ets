import { PhoneV3Reminder, PhoneV3SessionCard, PhoneV3Conflict } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { phoneV3ReminderState, phoneV3ReminderTime } from './PhoneV3UiFormat';
import { localReminderTime, reminderConflictMessage } from '../domain/PhoneV3ReminderCommands';

@Component
export struct PhoneV3RemindersPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  @State private editingId: string = '';
  @State private editedTitle: string = '';
  @State private editedDue: string = '';
  onOpenSession: (session: PhoneV3SessionCard) => void = (_session: PhoneV3SessionCard): void => {};

  private matchingSession(reminder: PhoneV3Reminder): PhoneV3SessionCard | undefined {
    return this.viewModel.snapshot.sessions.find((session: PhoneV3SessionCard): boolean =>
      session.sessionId === reminder.sessionId);
  }

  @Builder
  private reminderCard(reminder: PhoneV3Reminder) {
    Column({ space: 8 }) {
      Row() {
        Text(phoneV3ReminderTime(reminder))
          .fontSize(12)
          .fontColor($r('app.color.brand_primary'))
        Blank()
        Text(phoneV3ReminderState(reminder))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      Text(reminder.title)
        .width('100%')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      if (reminder.pendingAction.length > 0) {
        Text('操作已保存在手机，待电脑确认').fontSize(13).fontColor($r('app.color.brand_warning'))
      }
      if (this.viewModel.calendarReminderState(reminder.eventId) === 'permission_required') {
        Text('需要日历权限才能按时提醒').fontSize(13).fontColor($r('app.color.brand_warning'))
        Button('授权日历并重试').enabled(!this.viewModel.busy).onClick((): void => this.viewModel.retryCalendarReminder(reminder.eventId))
      } else if (this.viewModel.calendarReminderState(reminder.eventId) === 'externally_removed') {
        Text('系统提醒已被删除').fontSize(13).fontColor($r('app.color.brand_warning'))
        Button('重新启用提醒').enabled(!this.viewModel.busy).onClick((): void => this.viewModel.retryCalendarReminder(reminder.eventId))
      } else if (this.viewModel.calendarReminderState(reminder.eventId) === 'externally_modified') {
        Text('系统提醒已被修改，已保留日历中的修改').fontSize(13).fontColor($r('app.color.brand_warning'))
        Button('按任务时间重新启用提醒').enabled(!this.viewModel.busy).onClick((): void => this.viewModel.retryCalendarReminder(reminder.eventId))
      } else if (this.viewModel.calendarReminderState(reminder.eventId) === 'error') {
        Text('日历提醒同步失败，任务已保留').fontSize(13).fontColor($r('app.color.brand_warning'))
        Button('重试日历提醒').enabled(!this.viewModel.busy).onClick((): void => this.viewModel.retryCalendarReminder(reminder.eventId))
      } else if (this.viewModel.calendarReminderState(reminder.eventId) === 'scheduled') {
        Text('已安排系统日历提醒').fontSize(13).fontColor($r('app.color.text_secondary'))
      }
      if (reminder.location !== null && reminder.location.length > 0) {
        Text(`地点：${reminder.location}`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      }
      if (this.matchingSession(reminder) !== undefined) {
        Button('查看来源录音', { type: ButtonType.Capsule })
          .height(40)
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .onClick((): void => this.onOpenSession(this.matchingSession(reminder) as PhoneV3SessionCard))
      }
      if ((reminder.status === 'scheduled' || reminder.status === 'delivered') && reminder.pendingAction.length === 0) {
        Row({ space: 8 }) {
          Button('完成').enabled(!this.viewModel.busy).onClick((): void =>
            this.viewModel.reminderCommand('reminder.task', reminder.eventId, 'complete', reminder.eventRevision))
          Button('改时间').enabled(!this.viewModel.busy).onClick((): void => {
            this.editingId = reminder.eventId; this.editedTitle = reminder.title;
            this.editedDue = localReminderTime(reminder.scheduledAt);
          })
          Button('取消提醒').enabled(!this.viewModel.busy).onClick((): void =>
            this.viewModel.reminderCommand('reminder.task', reminder.eventId, 'cancel', reminder.eventRevision))
        }
        if (this.editingId === reminder.eventId) {
          TextInput({ text: this.editedTitle, placeholder: '要做什么' }).onChange((value: string): void => { this.editedTitle = value; })
          TextInput({ text: this.editedDue, placeholder: 'YYYY-MM-DD HH:mm（手机本地时间）' }).onChange((value: string): void => { this.editedDue = value; })
          Button('保存新时间').enabled(!this.viewModel.busy).onClick((): void =>
            this.viewModel.reminderCommand('reminder.task', reminder.eventId, 'reschedule', reminder.eventRevision, this.editedTitle, this.editedDue))
          Button('收起修改').onClick((): void => { this.editingId = ''; })
        }
      }
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.surface_primary'))
    .borderRadius(16)
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.viewModel.reminderSchedulingError().length > 0) {
          Text(this.viewModel.reminderSchedulingError()).fontSize(14).fontColor($r('app.color.brand_warning'))
        }
        ForEach(this.viewModel.snapshot.conflicts.filter((conflict: PhoneV3Conflict): boolean => conflict.kind.startsWith('reminder.')),
          (conflict: PhoneV3Conflict) => {
            Text(`提醒操作未被电脑接受：${reminderConflictMessage(conflict.errorJson)}`).fontSize(13).fontColor($r('app.color.brand_warning'))
          }, (conflict: PhoneV3Conflict): string => conflict.operationId)
        Text(`${this.viewModel.snapshot.reminders.length} 条已确认提醒`)
          .width('100%')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
        if (this.viewModel.snapshot.reminders.length === 0) {
          Text('当前没有已确认提醒；新候选会先进入审核页。')
            .width('100%')
            .padding(18)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor($r('app.color.surface_primary'))
            .borderRadius(16)
        } else {
          ForEach(this.viewModel.snapshot.reminders, (reminder: PhoneV3Reminder) => {
            this.reminderCard(reminder)
          }, (reminder: PhoneV3Reminder): string => reminder.eventId)
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 10, bottom: 32 })
      .alignItems(HorizontalAlign.Start)
    }
    .align(Alignment.TopStart)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
