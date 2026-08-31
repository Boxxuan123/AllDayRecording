import { PhoneRecordingViewModel } from './PhoneRecordingViewModel';

@Component
export struct PhoneSettingsPage {
  @ObjectLink viewModel: PhoneRecordingViewModel;
  onOpenComputerTransfer: () => void = (): void => {};
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

        Text('手表录音按固定时长安全分段。普通同步保留手表原文件；Wi-Fi 快传经 SHA-256 校验并整批确认后，会删除已同步的手表源文件。')
          .width('100%')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.surface_primary'))
      .borderRadius(14)

      Button('上传录音到电脑', { type: ButtonType.Capsule })
        .width('100%')
        .height(50)
        .fontSize(16)
        .fontColor(Color.White)
        .backgroundColor($r('app.color.brand_primary'))
        .onClick((): void => this.onOpenComputerTransfer())

      Text('HTTPS 加密、CA 指纹固定、Passkey 身份确认与断点续传')
        .width('100%')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(2)

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
