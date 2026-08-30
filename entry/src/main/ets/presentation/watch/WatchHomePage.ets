import { formatRecordingDuration } from 'common';
import { WatchRecordingViewModel } from './WatchRecordingViewModel';

@Component
export struct WatchHomePage {
  @ObjectLink viewModel: WatchRecordingViewModel;

  build() {
    Column({ space: 7 }) {
      Text('全天录音')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))

      if (this.viewModel.isRecording) {
        Text('正在录音')
          .fontSize(12)
          .fontColor($r('app.color.brand_danger'))

        Text(formatRecordingDuration(this.viewModel.elapsedSeconds * 1000))
          .fontSize(30)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))

        Text(`已安全保存 ${this.viewModel.completedSegments} 段`)
          .fontSize(10)
          .fontColor($r('app.color.text_secondary'))

        Button('停止并保存', { type: ButtonType.Capsule })
          .width(132)
          .height(44)
          .fontSize(15)
          .backgroundColor($r('app.color.brand_danger'))
          .onClick((): void => this.viewModel.toggleRecording())
      } else if (this.viewModel.latestRecording === undefined) {
        Text('需要时轻点开始\n熄屏后也会继续记录')
          .width(158)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)

        Button('开始录音', { type: ButtonType.Capsule })
          .width(132)
          .height(46)
          .fontSize(16)
          .backgroundColor($r('app.color.brand_primary'))
          .onClick((): void => this.viewModel.toggleRecording())
      } else {
        Text(this.viewModel.isPlaying ? '正在播放' : '录音已保存')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.viewModel.isPlaying ?
            $r('app.color.brand_primary') : $r('app.color.brand_success'))

        Text(formatRecordingDuration(this.viewModel.elapsedSeconds * 1000))
          .fontSize(24)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))

        Button(this.viewModel.isSending ? '正在发送…' : '发送到手机', { type: ButtonType.Capsule })
          .width(132)
          .height(40)
          .fontSize(14)
          .backgroundColor($r('app.color.brand_primary'))
          .enabled(!this.viewModel.isSending)
          .onClick((): void => this.viewModel.sendLatestRecording())

        Row({ space: 8 }) {
          Button(this.viewModel.isPlaying ? '停止' : '试听', { type: ButtonType.Capsule })
            .width(68)
            .height(28)
            .fontSize(12)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.surface_secondary'))
            .onClick((): void => this.viewModel.togglePlayback())

          Button('再次录音', { type: ButtonType.Capsule })
            .width(82)
            .height(28)
            .fontSize(12)
            .fontColor($r('app.color.brand_primary'))
            .backgroundColor($r('app.color.surface_accent'))
            .onClick((): void => this.viewModel.toggleRecording())
        }
      }

      Text(this.viewModel.userStatusMessage())
        .width(158)
        .fontSize(9)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(2)

      if (!this.viewModel.notificationEnabled && !this.viewModel.isRecording) {
        Button('开启通知', { type: ButtonType.Capsule })
          .width(92)
          .height(28)
          .fontSize(12)
          .fontColor($r('app.color.on_emphasis'))
          .backgroundColor($r('app.color.brand_warning'))
          .onClick((): void => this.viewModel.openNotificationSettings())
      }

      Text('下滑进入开发者界面')
        .fontSize(9)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 18, right: 18, top: 22, bottom: 22 })
    .backgroundColor($r('app.color.page_background'))
  }
}
