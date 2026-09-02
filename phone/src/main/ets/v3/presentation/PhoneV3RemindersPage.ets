import { PhoneV3Reminder, PhoneV3SessionCard } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { phoneV3ReminderState, phoneV3ReminderTime } from './PhoneV3UiFormat';

@Component
export struct PhoneV3RemindersPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
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
