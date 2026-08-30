import { formatRecordingDuration } from 'common';
import { WatchRecordingViewModel } from './WatchRecordingViewModel';

@Component
export struct WatchDeveloperPage {
  @ObjectLink viewModel: WatchRecordingViewModel;

  build() {
    Column({ space: 6 }) {
      if (this.viewModel.isRecording) {
        Text('连续 PCM 采集中')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        Text(formatRecordingDuration(this.viewModel.elapsedSeconds * 1000))
          .fontSize(30)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.brand_danger'))

        Text(`第 ${this.viewModel.activeSegmentIndex} 段 · 已封口 ${this.viewModel.completedSegments} 段 · 自动同步`)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))

        Button('停止测试', { type: ButtonType.Capsule })
          .width(128)
          .height(44)
          .backgroundColor($r('app.color.brand_danger'))
          .onClick((): void => this.viewModel.toggleRecording())
      } else if (this.viewModel.latestRecording === undefined) {
        Text('PCM 无缝分段测试')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        Text('16 kHz · 单声道 · 1 分钟 WAV')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))

        Button('开始 PCM 测试', { type: ButtonType.Capsule })
          .width(128)
          .height(44)
          .backgroundColor($r('app.color.brand_primary'))
          .onClick((): void => this.viewModel.toggleRecording())
      } else {
        Text(this.viewModel.isPlaying ? '正在试听末段' : 'PCM 测试完成')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        Text(`共 ${this.viewModel.completedSegments} 段 · 溢出 ${this.viewModel.hardwareOverflowCount}`)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))

        Button(this.viewModel.isSending ? '正在发送…' : '发送到手机', { type: ButtonType.Capsule })
          .width(128)
          .height(42)
          .backgroundColor($r('app.color.brand_primary'))
          .enabled(!this.viewModel.isSending)
          .onClick((): void => this.viewModel.sendLatestRecording())

        Row({ space: 8 }) {
          Button(this.viewModel.isPlaying ? '停止' : '试听', { type: ButtonType.Capsule })
            .width(72)
            .height(30)
            .fontSize(13)
            .fontColor($r('app.color.brand_primary'))
            .backgroundColor($r('app.color.surface_accent'))
            .onClick((): void => this.viewModel.togglePlayback())

          Button('重录', { type: ButtonType.Capsule })
            .width(72)
            .height(30)
            .fontSize(13)
            .fontColor($r('app.color.brand_primary'))
            .backgroundColor($r('app.color.surface_accent'))
            .onClick((): void => this.viewModel.resetLatestRecording())
        }
      }

      if (!this.viewModel.notificationEnabled && !this.viewModel.isRecording) {
        Button('开启通知', { type: ButtonType.Capsule })
          .width(108)
          .height(30)
          .fontSize(13)
          .fontColor($r('app.color.on_emphasis'))
          .backgroundColor($r('app.color.brand_warning'))
          .onClick((): void => this.viewModel.openNotificationSettings())
      }

      Text(this.viewModel.status)
        .width(160)
        .fontSize(10)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(2)

      Text('上滑返回首页')
        .fontSize(9)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 20, right: 20, top: 28, bottom: 28 })
    .backgroundColor($r('app.color.page_background'))
  }
}
