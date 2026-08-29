import { ReceivedRecordingFile } from '../../models/RecordingModels';
import { formatRecordingSize } from '../shared/RecordingPresentation';
import { PhoneRecordingViewModel } from './PhoneRecordingViewModel';
import { PhoneSyncProgressView } from './PhoneSyncProgressView';

@Component
export struct PhoneDeveloperPage {
  @ObjectLink viewModel: PhoneRecordingViewModel;

  build() {
    Column({ space: 12 }) {
      Text('手表录音与文件同步')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))

      Text(`手机可拉起手表 · 当前状态：${this.viewModel.remoteRecordingState === 'recording' ? '录音中' :
        this.viewModel.remoteRecordingState === 'stopped' ? '已停止' :
          this.viewModel.remoteRecordingState === 'pending_user_action' ? '等待手表点击通知' : '待确认'}`)
        .fontSize(14)
        .fontColor($r('app.color.text_tertiary'))

      Row({ space: 10 }) {
        Button(this.viewModel.isControllingWatch ? '控制中…' : '启动手表录音', { type: ButtonType.Capsule })
          .layoutWeight(1)
          .height(44)
          .backgroundColor($r('app.color.button_success'))
          .enabled(!this.viewModel.isControllingWatch && this.viewModel.remoteRecordingState !== 'recording')
          .onClick((): void => this.viewModel.requestWatchRecordingState('recording'))

        Button('停止手表录音', { type: ButtonType.Capsule })
          .layoutWeight(1)
          .height(44)
          .backgroundColor($r('app.color.brand_danger'))
          .enabled(!this.viewModel.isControllingWatch)
          .onClick((): void => this.viewModel.requestWatchRecordingState('stopped'))
      }
      .width('100%')

      Button(this.viewModel.developerSyncButtonLabel(), { type: ButtonType.Capsule })
        .width('100%')
        .height(48)
        .backgroundColor($r('app.color.brand_primary'))
        .enabled(!this.viewModel.syncState.inProgress && !this.viewModel.isReconnectingReceiver)
        .onClick((): void => this.viewModel.requestWatchSync())

      PhoneSyncProgressView({ viewModel: this.viewModel })

      Row({ space: 10 }) {
        if (this.viewModel.latestRecording !== undefined) {
          Button(this.viewModel.isPlaying ? '停止播放' : '试听选中文件', { type: ButtonType.Capsule })
            .layoutWeight(1)
            .height(40)
            .backgroundColor(this.viewModel.isPlaying ?
              $r('app.color.brand_danger') : $r('app.color.button_neutral'))
            .onClick((): void => this.viewModel.togglePlayback())
        }

        Button(this.viewModel.isReconnectingReceiver ? '正在重连…' : '重新连接', { type: ButtonType.Capsule })
          .layoutWeight(1)
          .height(40)
          .fontColor($r('app.color.brand_primary'))
          .backgroundColor($r('app.color.surface_accent'))
          .enabled(!this.viewModel.isReconnectingReceiver)
          .onClick((): void => this.viewModel.reconnectReceiver())
      }
      .width('100%')

      Text(`手机已保存 ${this.viewModel.receivedRecordingCount} 个文件` +
        `${this.viewModel.syncState.scannedTotal > 0 ? ` · 手表扫描 ${this.viewModel.syncState.scannedTotal} 个` : ''}` +
        `${this.viewModel.syncState.skipped > 0 ? ` · 无效 ${this.viewModel.syncState.skipped}` : ''}`)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))

      if (this.viewModel.receivedRecordings.length === 0) {
        Text('文件保存在手机应用私有目录 synced_from_watch；保持本页打开可自动接收')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      } else {
        List({ space: 8 }) {
          ForEach(this.viewModel.receivedRecordings, (recording: ReceivedRecordingFile) => {
            ListItem() {
              Column({ space: 4 }) {
                Text(recording.fileName)
                  .width('100%')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })

                Text(`${formatRecordingSize(recording.size)} · ${recording.sourcePath}`)
                  .width('100%')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .padding(12)
              .alignItems(HorizontalAlign.Start)
              .backgroundColor(this.viewModel.latestRecording?.path === recording.path ?
                $r('app.color.surface_accent') : $r('app.color.surface_primary'))
              .borderRadius(12)
            }
            .onClick((): void => this.viewModel.selectRecording(recording, true))
          }, (recording: ReceivedRecordingFile): string => recording.path)
        }
        .width('100%')
        .layoutWeight(1)
      }

      Text(this.viewModel.status)
        .width(320)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(2)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 28, bottom: 28 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.page_background'))
  }
}
