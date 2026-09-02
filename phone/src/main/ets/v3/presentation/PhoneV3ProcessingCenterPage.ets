import { PhoneV3SessionCard } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { phoneV3ProcessingStage, phoneV3SessionTitle } from './PhoneV3UiFormat';

@Component
export struct PhoneV3ProcessingCenterPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  onOpenSession: (session: PhoneV3SessionCard) => void = (_session: PhoneV3SessionCard): void => {};

  private processingSessions(): Array<PhoneV3SessionCard> {
    return this.viewModel.snapshot.sessions.filter((session: PhoneV3SessionCard): boolean =>
      session.processingStatus.length > 0 || session.processingStage.length > 0);
  }

  @Builder
  private processingRow(session: PhoneV3SessionCard) {
    Column({ space: 9 }) {
      Row() {
        Text(phoneV3SessionTitle(session))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text(`${Math.round(session.processingProgress * 100)}%`)
          .fontSize(13)
          .fontColor($r('app.color.brand_primary'))
      }
      .width('100%')
      Text(phoneV3ProcessingStage(session))
        .width('100%')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      Progress({ value: session.processingProgress * 100, total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(6)
        .color($r('app.color.brand_primary'))
        .backgroundColor($r('app.color.surface_secondary'))
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.surface_primary'))
    .borderRadius(16)
    .onClick((): void => this.onOpenSession(session))
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Text('电脑处理任务的手机摘要；失败重试和取消仍需电脑在线。')
          .width('100%')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
        if (this.processingSessions().length === 0) {
          Text('当前没有处理记录。')
            .width('100%')
            .padding(18)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor($r('app.color.surface_primary'))
            .borderRadius(16)
        } else {
          ForEach(this.processingSessions(), (session: PhoneV3SessionCard) => {
            this.processingRow(session)
          }, (session: PhoneV3SessionCard): string => session.id)
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
