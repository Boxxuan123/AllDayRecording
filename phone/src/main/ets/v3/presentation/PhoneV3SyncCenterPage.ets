import { PhoneV3ViewModel } from './PhoneV3ViewModel';

@Component
export struct PhoneV3SyncCenterPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  onOpenComputerConnection: () => void = (): void => {};

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

        if (this.viewModel.state.snapshot.sync.lastError.length > 0) {
          Text(this.viewModel.state.snapshot.sync.lastError)
            .width('100%')
            .fontSize(13)
            .fontColor($r('app.color.brand_danger'))
            .padding(14)
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
