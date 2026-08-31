import { formatRecordingSize } from 'common';
import { PhoneV3FileTransferState } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';

@Component
export struct PhoneV3SyncCenterPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  onOpenComputerConnection: () => void = (): void => {};

  @Builder
  private watchProgress(transfer: PhoneV3FileTransferState) {
    if (this.viewModel.state.device.watchSyncing || transfer.active) {
      Column({ space: 8 }) {
        Row() {
          Text(transfer.stage.length > 0 ? transfer.stage : transfer.message)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(`${transfer.percent}%`)
            .fontSize(13)
            .fontColor($r('app.color.brand_primary'))
        }
        .width('100%')
        Progress({ value: transfer.percent, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(6)
          .color($r('app.color.brand_primary'))
        if (transfer.fileName.length > 0) {
          Text(`${transfer.fileName}${transfer.totalBytes > 0 ?
            ` · ${formatRecordingSize(transfer.transferredBytes)} / ${formatRecordingSize(transfer.totalBytes)}` : ''}`)
            .width('100%')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .padding(12)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.surface_progress'))
      .borderRadius(12)
    }
  }

  @Builder
  private valueRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      Blank()
      Text(value)
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
    }
    .width('100%')
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Column({ space: 3 }) {
          Text('同步中心')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('增量游标、离线队列与错误均保存在 Phone RDB')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 10 }) {
          Text('Watch 文件同步')
            .width('100%')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.viewModel.state.device.watchSyncing ?
            `正在接收 ${this.viewModel.state.device.watchReceived}/${this.viewModel.state.device.watchTotal}` :
            '可使用 Wear Engine 普通同步，或在同一 WLAN 下使用加密 Wi-Fi 快传')
            .width('100%')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
          Row({ space: 8 }) {
            Button('同步 Watch', { type: ButtonType.Capsule })
              .layoutWeight(1)
              .height(44)
              .enabled(!this.viewModel.state.device.watchSyncing &&
                !this.viewModel.state.device.wifi.busy && !this.viewModel.state.device.wifi.ready)
              .fontColor(Color.White)
              .backgroundColor($r('app.color.brand_primary'))
              .onClick((): void => this.viewModel.requestWatchSync())
            Button(this.viewModel.state.device.wifi.busy ?
              this.viewModel.state.device.wifi.stopping ? '正在停止…' : '正在准备…' :
              this.viewModel.state.device.wifi.ready ? '停止快传' : 'Wi-Fi 快传',
            { type: ButtonType.Capsule })
              .layoutWeight(1)
              .height(44)
              .enabled(!this.viewModel.state.device.wifi.busy && !this.viewModel.state.device.watchSyncing)
              .fontColor(this.viewModel.state.device.wifi.ready ? Color.White : $r('app.color.text_primary'))
              .backgroundColor(this.viewModel.state.device.wifi.ready ?
                $r('app.color.brand_success') : $r('app.color.surface_secondary'))
              .onClick((): void => this.viewModel.toggleWifiReceiver())
          }
          this.watchProgress(this.viewModel.state.device.watchTransfer)
          if (this.viewModel.state.device.wifi.ready || this.viewModel.state.device.wifi.percent > 0 ||
            this.viewModel.state.device.wifi.error.length > 0) {
            Text(this.viewModel.state.device.wifi.status)
              .width('100%')
              .fontSize(13)
              .fontColor(this.viewModel.state.device.wifi.error.length > 0 ?
                $r('app.color.brand_danger') : $r('app.color.text_secondary'))
              .maxLines(2)
            if (this.viewModel.state.device.wifi.percent > 0) {
              Progress({ value: this.viewModel.state.device.wifi.percent, total: 100, type: ProgressType.Linear })
                .width('100%')
                .height(6)
                .color($r('app.color.brand_success'))
            }
          }
          Text(this.viewModel.state.device.wifi.capability)
            .width('100%')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(2)
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(16)

        Column({ space: 12 }) {
          this.valueRow('电脑连接', this.viewModel.state.snapshot.paired ? '已配对' : '未配对')
          this.valueRow('增量游标', this.viewModel.state.snapshot.sync.cursor)
          this.valueRow('待提交操作', this.viewModel.state.snapshot.sync.pendingOperations.toString())
          this.valueRow('重试次数', this.viewModel.state.snapshot.sync.retryCount.toString())
          this.valueRow('服务端时间', this.viewModel.state.snapshot.sync.lastServerTime.length > 0 ?
            this.viewModel.state.snapshot.sync.lastServerTime : '尚未成功同步')
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(16)

        if (this.viewModel.state.error.length > 0 || this.viewModel.state.snapshot.sync.lastError.length > 0 ||
          this.viewModel.state.device.watchTransfer.error.length > 0 ||
          this.viewModel.state.device.wifi.error.length > 0) {
          Column({ space: 10 }) {
            Text(this.viewModel.state.error.length > 0 ? this.viewModel.state.error :
              this.viewModel.state.device.watchTransfer.error.length > 0 ?
                this.viewModel.state.device.watchTransfer.error :
                this.viewModel.state.device.wifi.error.length > 0 ? this.viewModel.state.device.wifi.error :
                  this.viewModel.state.snapshot.sync.lastError)
              .width('100%')
              .fontSize(13)
              .fontColor($r('app.color.brand_danger'))
            if (this.viewModel.canRetry()) {
              Button('重试上一步操作', { type: ButtonType.Capsule })
                .height(40)
                .fontColor(Color.White)
                .backgroundColor($r('app.color.brand_danger'))
                .onClick((): void => this.viewModel.retryLastAction())
            }
          }
          .width('100%')
          .padding(14)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor($r('app.color.surface_primary'))
          .borderRadius(12)
        }

        Button(this.viewModel.state.busy ? '正在同步…' : '立即增量同步', { type: ButtonType.Capsule })
          .width('100%')
          .height(50)
          .enabled(!this.viewModel.state.busy && this.viewModel.state.snapshot.paired)
          .backgroundColor($r('app.color.brand_primary'))
          .fontColor(Color.White)
          .onClick((): void => this.viewModel.synchronize())

        Button('电脑连接与安全上传', { type: ButtonType.Capsule })
          .width('100%')
          .height(48)
          .backgroundColor($r('app.color.surface_secondary'))
          .fontColor($r('app.color.text_primary'))
          .onClick((): void => this.onOpenComputerConnection())

        Button('重建可缓存投影', { type: ButtonType.Capsule })
          .width('100%')
          .height(48)
          .enabled(!this.viewModel.state.busy && this.viewModel.state.snapshot.paired)
          .backgroundColor($r('app.color.surface_secondary'))
          .fontColor($r('app.color.text_primary'))
          .onClick((): void => this.viewModel.rebuild())

        Text('重建只清理可从电脑恢复的投影；本地音频、outbox、冲突和配对信息会保留。')
          .width('100%')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))

        Text(this.viewModel.state.message)
          .width('100%')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 22, bottom: 100 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
