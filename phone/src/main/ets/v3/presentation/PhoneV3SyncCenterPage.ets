import { formatRecordingSize } from 'common';
import { ChipV2, ExceptionPromptV2, MarginTypeV2, PromptOptionsV2, SymbolGlyphModifier } from '@kit.ArkUI';
import { PhoneV3FileTransferState } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { phoneV3StatusChip } from './PhoneV3NativeUi';

@Component
export struct PhoneV3SyncCenterPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  onOpenComputerConnection: () => void = (): void => {};

  private syncErrorText(): string {
    if (this.viewModel.state.error.length > 0) {
      return this.viewModel.state.error;
    }
    if (this.viewModel.state.device.watchTransfer.error.length > 0) {
      return this.viewModel.state.device.watchTransfer.error;
    }
    if (this.viewModel.state.device.wifi.error.length > 0) {
      return this.viewModel.state.device.wifi.error;
    }
    return this.viewModel.state.snapshot.sync.lastError;
  }

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

  build() {
    Scroll() {
      Column({ space: 18 }) {
        Column({ space: 4 }) {
          Text('同步')
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('从手表接收录音，并安全备份到电脑')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 14 }) {
          Row({ space: 12 }) {
            Stack() {
              SymbolGlyph($r('sys.symbol.waveform'))
                .fontSize(24)
                .fontColor([$r('app.color.brand_primary')])
            }
            .width(46)
            .height(46)
            .borderRadius(14)
            .backgroundColor($r('app.color.surface_accent'))
            Column({ space: 3 }) {
              Text('从手表接收')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text(this.viewModel.state.device.watchSyncing ?
                `正在接收 ${this.viewModel.state.device.watchReceived}/${this.viewModel.state.device.watchTotal}` :
                '手机会保留完整本地音频')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')

          Text(this.viewModel.state.device.watchSyncing ?
            `正在接收 ${this.viewModel.state.device.watchReceived}/${this.viewModel.state.device.watchTotal}` :
            '普通接收更稳定；同一 Wi-Fi 下可用快传')
            .width('100%')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
          Row({ space: 8 }) {
            Button(this.viewModel.state.device.watchSyncing ? '正在接收…' : '普通接收',
            { type: ButtonType.Capsule })
              .layoutWeight(1)
              .height(44)
              .enabled(!this.viewModel.state.device.watchSyncing &&
                !this.viewModel.state.device.wifi.busy && !this.viewModel.state.device.wifi.ready)
              .buttonStyle(ButtonStyleMode.EMPHASIZED)
              .onClick((): void => this.viewModel.requestWatchSync())
            Button(this.viewModel.state.device.wifi.busy ?
              this.viewModel.state.device.wifi.stopping ? '正在停止…' : '正在准备…' :
              this.viewModel.state.device.wifi.ready ? '停止快传' : 'Wi-Fi 快传',
            { type: ButtonType.Capsule })
              .layoutWeight(1)
              .height(44)
              .enabled(!this.viewModel.state.device.wifi.busy && !this.viewModel.state.device.watchSyncing)
              .buttonStyle(ButtonStyleMode.NORMAL)
              .onClick((): void => this.viewModel.toggleWifiReceiver())
          }
          this.watchProgress(this.viewModel.state.device.watchTransfer)

          if (this.viewModel.state.device.wifi.ready || this.viewModel.state.device.wifi.percent > 0 ||
            this.viewModel.state.device.wifi.error.length > 0) {
            Column({ space: 8 }) {
              Text(this.viewModel.state.device.wifi.status)
                .width('100%')
                .fontSize(13)
                .fontColor(this.viewModel.state.device.wifi.error.length > 0 ?
                  $r('app.color.brand_danger') : $r('app.color.text_secondary'))
                .maxLines(2)
              if (this.viewModel.state.device.wifi.percent > 0) {
                Progress({ value: this.viewModel.state.device.wifi.percent, total: 100,
                  type: ProgressType.Linear })
                  .width('100%')
                  .height(6)
                  .color($r('app.color.brand_success'))
              }
            }
            .width('100%')
            .padding(12)
            .alignItems(HorizontalAlign.Start)
            .backgroundColor($r('app.color.surface_progress'))
            .borderRadius(12)
          }
        }
        .width('100%')
        .padding(18)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(20)

        if (this.syncErrorText().length > 0) {
          ExceptionPromptV2({
            options: new PromptOptionsV2({
              marginType: MarginTypeV2.DEFAULT_MARGIN,
              marginTop: 0,
              symbolStyle: new SymbolGlyphModifier($r('sys.symbol.exclamationmark_circle_fill')),
              tip: this.syncErrorText(),
              actionText: this.viewModel.canRetry() ? '重试' : undefined,
              isShown: true
            }),
            onActionTextClick: (): void => this.viewModel.retryLastAction()
          })
            .width('100%')
        }

        Column({ space: 14 }) {
          Row({ space: 12 }) {
            Stack() {
              SymbolGlyph($r('sys.symbol.cloud_and_arrow_up'))
                .fontSize(23)
                .fontColor([$r('app.color.brand_success')])
            }
            .width(46)
            .height(46)
            .borderRadius(14)
            .backgroundColor($r('app.color.surface_progress'))
            Column({ space: 3 }) {
              Text('备份到电脑')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text(this.viewModel.state.snapshot.paired ?
                `${this.viewModel.state.snapshot.sync.pendingOperations} 项更新等待备份` :
                '连接电脑后可安全备份和同步转写')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            ChipV2({
              chipV2Options: phoneV3StatusChip(this.viewModel.state.snapshot.paired ? '已连接' : '未连接')
            })
          }
          .width('100%')

          Button(this.viewModel.state.busy ? '正在备份…' : '立即备份更新', { type: ButtonType.Capsule })
            .width('100%')
            .height(50)
            .enabled(!this.viewModel.state.busy && this.viewModel.state.snapshot.paired)
            .buttonStyle(ButtonStyleMode.EMPHASIZED)
            .onClick((): void => this.viewModel.synchronize())

          Button(this.viewModel.state.snapshot.paired ? '管理电脑连接' : '连接电脑',
          { type: ButtonType.Capsule })
            .width('100%')
            .height(46)
            .buttonStyle(ButtonStyleMode.NORMAL)
            .onClick((): void => this.onOpenComputerConnection())

          if (this.viewModel.state.message.length > 0) {
            Text(this.viewModel.state.message)
              .width('100%')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
          }
        }
        .width('100%')
        .padding(18)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(20)

        Column({ space: 12 }) {
          Text('同步详情')
            .width('100%')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Row() {
            Text('待备份更新')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.viewModel.state.snapshot.sync.pendingOperations.toString())
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
              .maxLines(2)
          }
          .width('100%')
          Row() {
            Text('自动重试')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.viewModel.state.snapshot.sync.retryCount.toString())
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
              .maxLines(2)
          }
          .width('100%')
          Row() {
            Text('上次成功同步')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.viewModel.state.snapshot.sync.lastServerTime.length > 0 ?
              this.viewModel.state.snapshot.sync.lastServerTime : '暂无')
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
              .maxLines(2)
          }
          .width('100%')
          Row() {
            Text('Wi-Fi 快传能力')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.viewModel.state.device.wifi.capability.length > 0 ?
              this.viewModel.state.device.wifi.capability : '等待检测')
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
              .maxLines(2)
          }
          .width('100%')
          Row() {
            Text('同步游标')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.viewModel.state.snapshot.sync.cursor)
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
              .maxLines(2)
          }
          .width('100%')
          Button('修复同步缓存', { type: ButtonType.Capsule })
            .width('100%')
            .height(44)
            .enabled(!this.viewModel.state.busy && this.viewModel.state.snapshot.paired)
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .onClick((): void => this.viewModel.rebuild())
          Text('仅重建可从电脑恢复的缓存，不会删除手机本地音频。')
            .width('100%')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(16)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 106 })
      .alignItems(HorizontalAlign.Start)
    }
    .align(Alignment.TopStart)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
