import { formatRecordingSize } from 'common';
import { WatchRecordingViewModel } from './WatchRecordingViewModel';

@Component
export struct WatchWifiTransferPage {
  @ObjectLink viewModel: WatchRecordingViewModel;

  aboutToAppear(): void {
    this.viewModel.refreshWifiRecording();
  }

  build() {
    Column({ space: 7 }) {
      Text('Wi-Fi 快传')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))

      Text(this.viewModel.wifiCapability)
        .width(158)
        .fontSize(10)
        .fontColor(this.viewModel.wifiCapability.includes('可用') ?
          $r('app.color.brand_success') : $r('app.color.brand_warning'))
        .textAlign(TextAlign.Center)
        .maxLines(2)

      if (this.viewModel.wifiRecording === undefined) {
        Text('没有找到完整录音')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      } else {
        Text(`共 ${this.viewModel.wifiRecordingCount} 个完整录音`)
          .width(158)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)

        Text(`总计 ${formatRecordingSize(this.viewModel.wifiRecordingTotalBytes)}`)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }

      if (this.viewModel.wifiSending || this.viewModel.wifiProgress > 0) {
        Progress({ value: this.viewModel.wifiProgress, total: 100, type: ProgressType.Linear })
          .width(132)
          .height(5)
          .color($r('app.color.brand_success'))
          .backgroundColor($r('app.color.surface_secondary'))
      }

      Text(this.viewModel.wifiSending ? '正在进行加密同步…' : '请在配对手机上点击 Wi-Fi 快传')
        .width(146)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.brand_success'))
        .textAlign(TextAlign.Center)

      Text(this.viewModel.wifiStatus)
        .width(158)
        .fontSize(9)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(3)

      Text('一次性凭据只经 Wear Engine 下发 · 下滑返回首页')
        .fontSize(8)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 18, right: 18, top: 22, bottom: 22 })
    .backgroundColor($r('app.color.page_background'))
  }
}
