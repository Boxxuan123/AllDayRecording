import { PhoneV3SessionCard } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import {
  phoneV3ComputerStage,
  phoneV3SessionMeta,
  phoneV3SessionTitle,
  phoneV3UpdatedLabel
} from './PhoneV3UiFormat';

@Component
export struct PhoneV3RecordingListPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  onOpenSession: (session: PhoneV3SessionCard) => void = (_session: PhoneV3SessionCard): void => {};

  @Builder
  private row(session: PhoneV3SessionCard) {
    Column({ space: 8 }) {
      Row() {
        Column({ space: 4 }) {
          Text(phoneV3SessionTitle(session))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(phoneV3SessionMeta(session))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(18)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width('100%')

      Row({ space: 8 }) {
        Text(session.localPaths.length > 0 ? '可离线播放' : '仅电脑投影')
          .fontSize(12)
          .fontColor(session.localPaths.length > 0 ? $r('app.color.brand_primary') :
            $r('app.color.text_secondary'))
        Text(phoneV3ComputerStage(session))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      Text(phoneV3UpdatedLabel(session.updatedAt))
        .width('100%')
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.surface_primary'))
    .borderRadius(14)
    .onClick((): void => this.onOpenSession(session))
  }

  build() {
    Column({ space: 14 }) {
      Row() {
        Column({ space: 3 }) {
          Text('录音')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('本地音频与电脑状态已合并')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Button('刷新', { type: ButtonType.Capsule })
          .backgroundColor($r('app.color.surface_secondary'))
          .fontColor($r('app.color.text_primary'))
          .onClick((): void => this.viewModel.refresh())
      }
      .width('100%')

      List({ space: 10 }) {
        ForEach(this.viewModel.state.snapshot.sessions, (session: PhoneV3SessionCard) => {
          ListItem() { this.row(session) }
        }, (session: PhoneV3SessionCard): string => session.id)
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 18, right: 18, top: 22, bottom: 90 })
    .backgroundColor($r('app.color.page_background'))
  }
}
