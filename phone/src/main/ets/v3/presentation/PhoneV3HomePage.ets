import { PhoneV3SessionCard } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import {
  phoneV3ComputerStage,
  phoneV3ProcessingStage,
  phoneV3SessionTitle,
  phoneV3UpdatedLabel,
  phoneV3WatchStage
} from './PhoneV3UiFormat';

@Component
export struct PhoneV3HomePage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  onOpenSession: (session: PhoneV3SessionCard) => void = (_session: PhoneV3SessionCard): void => {};

  @Builder
  private latestSession(session: PhoneV3SessionCard) {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 4 }) {
          Text(phoneV3SessionTitle(session))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(phoneV3UpdatedLabel(session.updatedAt))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(session.sessionId.length > 0 ? '已投影' : '本地')
          .fontSize(12)
          .fontColor($r('app.color.brand_primary'))
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor($r('app.color.surface_accent'))
          .borderRadius(12)
      }
      .width('100%')

      Text(`Watch → Phone  ${phoneV3WatchStage(session)}`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      Text(`Phone → Computer  ${phoneV3ComputerStage(session)}`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      Text(`Computer 处理  ${phoneV3ProcessingStage(session)}`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
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
      Column({ space: 16 }) {
        Column({ space: 4 }) {
          Text('全天候录音 V3')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('手机本地优先 · 电脑可离线')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Row({ space: 10 }) {
          Column({ space: 4 }) {
            Text(this.viewModel.state.snapshot.sessions.length.toString())
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text('会话')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .layoutWeight(1)
          .padding(14)
          .backgroundColor($r('app.color.surface_primary'))
          .borderRadius(14)

          Column({ space: 4 }) {
            Text(this.viewModel.state.snapshot.sync.pendingOperations.toString())
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text('待同步操作')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .layoutWeight(1)
          .padding(14)
          .backgroundColor($r('app.color.surface_primary'))
          .borderRadius(14)
        }
        .width('100%')

        Column({ space: 6 }) {
          Text(this.viewModel.state.device.watchStatus)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.viewModel.state.device.watchSyncing ?
            `正在接收 ${this.viewModel.state.device.watchReceived}/${this.viewModel.state.device.watchTotal}` :
            '当前 Watch 同步与恢复能力保持可用')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(16)

        Row({ space: 10 }) {
          Button('同步 Watch', { type: ButtonType.Capsule })
            .layoutWeight(1)
            .height(46)
            .backgroundColor($r('app.color.brand_primary'))
            .fontColor(Color.White)
            .enabled(!this.viewModel.state.device.watchSyncing)
            .onClick((): void => this.viewModel.requestWatchSync())
          Button('刷新本地', { type: ButtonType.Capsule })
            .layoutWeight(1)
            .height(46)
            .backgroundColor($r('app.color.surface_secondary'))
            .fontColor($r('app.color.text_primary'))
            .onClick((): void => this.viewModel.refresh())
        }

        if (this.viewModel.state.error.length > 0) {
          Text(this.viewModel.state.error)
            .width('100%')
            .fontSize(13)
            .fontColor($r('app.color.brand_danger'))
            .padding(12)
            .backgroundColor($r('app.color.surface_primary'))
            .borderRadius(12)
        }

        Text('最近会话')
          .width('100%')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        if (this.viewModel.state.snapshot.sessions.length > 0) {
          this.latestSession(this.viewModel.state.snapshot.sessions[0])
        } else if (this.viewModel.state.localReady) {
          Text('手机上还没有录音；电脑离线不会影响这里的本地列表。')
            .width('100%')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .padding(18)
            .backgroundColor($r('app.color.surface_primary'))
            .borderRadius(16)
        } else {
          LoadingProgress().width(32).height(32)
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 22, bottom: 100 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
