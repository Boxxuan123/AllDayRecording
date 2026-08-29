import { PhoneRecordingViewModel } from './PhoneRecordingViewModel';

@Component
export struct PhoneHomePage {
  @ObjectLink viewModel: PhoneRecordingViewModel;

  build() {
    Column({ space: 18 }) {
      Column({ space: 4 }) {
        Text('全天录音')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        Text('从手机控制手表，录音自动安全保存')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: 14 }) {
        Row() {
          Text('手表状态')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)

          Text(this.viewModel.remoteStateLabel())
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.viewModel.remoteRecordingState === 'recording' ?
              $r('app.color.brand_success') : $r('app.color.text_primary'))
        }
        .width('100%')

        Button(this.viewModel.isControllingWatch ? '正在等待手表…' :
          this.viewModel.remoteRecordingState === 'recording' ? '停止并保存' : '开始录音',
        { type: ButtonType.Capsule })
          .width('100%')
          .height(52)
          .fontSize(17)
          .fontColor($r('app.color.on_emphasis'))
          .backgroundColor(this.viewModel.remoteRecordingState === 'recording' ?
            $r('app.color.brand_danger') : $r('app.color.brand_primary'))
          .enabled(!this.viewModel.isControllingWatch)
          .onClick((): void => this.viewModel.requestWatchRecordingState(
            this.viewModel.remoteRecordingState === 'recording' ? 'stopped' : 'recording'))

        Text(this.viewModel.userStatusMessage())
          .width('100%')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
          .maxLines(2)
      }
      .width('100%')
      .padding(18)
      .backgroundColor($r('app.color.surface_primary'))
      .borderRadius(18)

      Column({ space: 8 }) {
        Text('录音记录')
          .width('100%')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))

        Text(this.viewModel.receivedRecordingCount > 0 ?
          `手机已保存 ${this.viewModel.receivedRecordingCount} 个录音，可在“录音记录”中同步和试听。` :
          '完成录音后，可在“录音记录”中同步到手机。')
          .width('100%')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.surface_primary'))
      .borderRadius(14)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 24, bottom: 92 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.page_background'))
  }
}
