import {
  ReceivedRecordingFile,
  formatRecordingDuration,
  formatRecordingReceivedAt,
  formatRecordingSize
} from 'common';
import { PhoneRecordingViewModel } from './PhoneRecordingViewModel';
import { PhoneSyncProgressView } from './PhoneSyncProgressView';

@Component
export struct PhoneRecordingHistoryPage {
  @ObjectLink viewModel: PhoneRecordingViewModel;

  build() {
    Column({ space: 16 }) {
      Column({ space: 4 }) {
        Text('录音记录')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        Text('同步并试听已经保存到手机的录音')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Row() {
        Text(`我的录音  ${this.viewModel.receivedRecordingCount}`)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Button(this.viewModel.syncButtonLabel(), { type: ButtonType.Capsule })
          .height(36)
          .fontSize(14)
          .fontColor($r('app.color.brand_primary'))
          .backgroundColor($r('app.color.surface_accent'))
          .enabled(!this.viewModel.syncState.inProgress)
          .onClick((): void => this.viewModel.requestWatchSync())
      }
      .width('100%')

      PhoneSyncProgressView({ viewModel: this.viewModel })

      if (this.viewModel.receivedRecordings.length === 0) {
        Column({ space: 8 }) {
          Text('还没有录音')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))

          Text('完成手表录音后，点击“同步录音”即可在这里试听')
            .width('100%')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.viewModel.receivedRecordings, (recording: ReceivedRecordingFile) => {
            ListItem() {
              Row({ space: 12 }) {
                Column({ space: 5 }) {
                  Text(formatRecordingReceivedAt(recording.receivedAt))
                    .width('100%')
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))

                  Text(`${formatRecordingDuration(recording.durationMs)} · ${formatRecordingSize(recording.size)}`)
                    .width('100%')
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Text(this.viewModel.latestRecording?.path === recording.path ? '已选择' : '选择')
                  .fontSize(13)
                  .fontColor($r('app.color.brand_primary'))
              }
              .width('100%')
              .padding(15)
              .backgroundColor(this.viewModel.latestRecording?.path === recording.path ?
                $r('app.color.surface_accent') : $r('app.color.surface_primary'))
              .borderRadius(14)
            }
            .onClick((): void => this.viewModel.selectRecording(recording))
          }, (recording: ReceivedRecordingFile): string => recording.path)
        }
        .width('100%')
        .layoutWeight(1)

        Button(this.viewModel.isPlaying ? '停止播放' : '播放选中的录音', { type: ButtonType.Capsule })
          .width('100%')
          .height(46)
          .fontSize(16)
          .backgroundColor(this.viewModel.isPlaying ?
            $r('app.color.brand_danger') : $r('app.color.button_neutral'))
          .enabled(this.viewModel.latestRecording !== undefined)
          .onClick((): void => this.viewModel.togglePlayback())
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 24, bottom: 92 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.page_background'))
  }
}
