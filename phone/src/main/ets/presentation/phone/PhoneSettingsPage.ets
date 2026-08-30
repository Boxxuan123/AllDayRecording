import { PhoneRecordingViewModel } from './PhoneRecordingViewModel';

@Component
export struct PhoneSettingsPage {
  @ObjectLink viewModel: PhoneRecordingViewModel;
  onOpenDeveloper: () => void = (): void => {};

  build() {
    Column({ space: 16 }) {
      Text('应用设置')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))

      Column({ space: 6 }) {
        Text('录音与存储')
          .width('100%')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))

        Text('手表录音按固定时长安全分段，并自动保留原文件。同步到手机后可直接试听。')
          .width('100%')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.surface_primary'))
      .borderRadius(14)

      Button('开发者界面', { type: ButtonType.Capsule })
        .width('100%')
        .height(48)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.surface_secondary'))
        .onClick((): void => this.onOpenDeveloper())

      Text('包含连接状态、分段计数、溢出统计和原始诊断信息')
        .width('100%')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(2)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .padding({ left: 20, right: 20, top: 24, bottom: 92 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.page_background'))
  }
}
