import { formatRecordingSize } from 'common';
import { PhoneV3FileTransferState, PhoneV3Reminder, PhoneV3SessionCard } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import {
  phoneV3ComputerStage,
  phoneV3ProcessingStage,
  phoneV3ReminderState,
  phoneV3ReminderTime,
  phoneV3SessionTitle,
  phoneV3UpdatedLabel,
  phoneV3WatchStage
} from './PhoneV3UiFormat';

@Component
export struct PhoneV3HomePage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  onOpenSession: (session: PhoneV3SessionCard) => void = (_session: PhoneV3SessionCard): void => {};

  @Builder
  private watchProgress(transfer: PhoneV3FileTransferState) {
    if (this.viewModel.state.device.watchSyncing || transfer.active) {
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Text(transfer.stage.length > 0 ? transfer.stage : transfer.message)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(`${transfer.percent}%`)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.brand_primary'))
        }
        .width('100%')
        Progress({ value: transfer.percent, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(6)
          .color($r('app.color.brand_primary'))
          .backgroundColor($r('app.color.surface_secondary'))
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
  private operationError() {
    if (this.viewModel.state.device.watchTransfer.error.length > 0 ||
      this.viewModel.state.device.operationError.length > 0) {
      Column({ space: 10 }) {
        Text(this.viewModel.state.device.watchTransfer.error.length > 0 ?
          this.viewModel.state.device.watchTransfer.error : this.viewModel.state.device.operationError)
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
      .padding(12)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.surface_primary'))
      .borderRadius(12)
    }
  }

  @Builder
  private latestSession(session: PhoneV3SessionCard) {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 4 }) {
          Text(phoneV3SessionTitle(session))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(phoneV3UpdatedLabel(session.updatedAt))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(session.sessionId.length > 0 ? '已投影' : '本地')
          .fontSize(12)
          .fontColor($r('app.color.brand_primary'))
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor($r('app.color.surface_accent'))
          .borderRadius(12)
      }
      .width('100%')

      Text(`Watch → Phone  ${phoneV3WatchStage(session)}`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      Text(`Phone → Computer  ${phoneV3ComputerStage(session)}`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      Text(`Computer 处理  ${phoneV3ProcessingStage(session)}`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.surface_primary'))
    .borderRadius(16)
    .onClick((): void => this.onOpenSession(session))
  }

  @Builder
  private reminderNotification(reminder: PhoneV3Reminder) {
    Column({ space: 7 }) {
      Row({ space: 8 }) {
        Text(reminder.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .layoutWeight(1)
        Text(phoneV3ReminderState(reminder))
          .fontSize(12)
          .fontColor(Date.parse(reminder.scheduledAt) <= Date.now() ?
            $r('app.color.brand_warning') : $r('app.color.brand_primary'))
      }
      .width('100%')
      Text(phoneV3ReminderTime(reminder))
        .width('100%')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      if (reminder.location !== null && reminder.location.length > 0) {
        Text(`地点：${reminder.location}`)
          .width('100%')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .width('100%')
    .padding(14)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.surface_primary'))
    .borderRadius(14)
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Column({ space: 4 }) {
          Text('全天候录音 V3')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('手机本地优先 · 电脑可离线')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Row({ space: 10 }) {
          Column({ space: 4 }) {
            Text(this.viewModel.state.snapshot.sessions.length.toString())
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text('会话')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .layoutWeight(1)
          .padding(14)
          .backgroundColor($r('app.color.surface_primary'))
          .borderRadius(14)

          Column({ space: 4 }) {
            Text(this.viewModel.state.snapshot.sync.pendingOperations.toString())
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text('待同步操作')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .layoutWeight(1)
          .padding(14)
          .backgroundColor($r('app.color.surface_primary'))
          .borderRadius(14)
        }
        .width('100%')

        if (this.viewModel.state.snapshot.reminders.length > 0) {
          Row() {
            Text('提醒通知')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            Text(`${this.viewModel.state.snapshot.reminders.length} 条`)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          ForEach(this.viewModel.state.snapshot.reminders.slice(0, 3), (reminder: PhoneV3Reminder) => {
            this.reminderNotification(reminder)
          }, (reminder: PhoneV3Reminder): string => reminder.eventId)
        }

        Column({ space: 10 }) {
          Row() {
            Column({ space: 4 }) {
              Text('手表状态')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
              Text(this.viewModel.state.device.watchStatus)
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.viewModel.state.device.remoteRecordingState === 'recording' ?
                  $r('app.color.brand_success') : $r('app.color.text_primary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            if (this.viewModel.state.device.receiverReconnecting) {
              LoadingProgress().width(24).height(24)
            }
          }
          .width('100%')
          Button(this.viewModel.state.device.watchControlBusy ? '正在等待手表…' :
            this.viewModel.state.device.remoteRecordingState === 'recording' ? '停止并保存' : '开始录音',
          { type: ButtonType.Capsule })
            .width('100%')
            .height(50)
            .enabled(!this.viewModel.state.device.watchControlBusy &&
              !this.viewModel.state.device.receiverReconnecting)
            .fontColor(Color.White)
            .backgroundColor(this.viewModel.state.device.remoteRecordingState === 'recording' ?
              $r('app.color.brand_danger') : $r('app.color.brand_primary'))
            .onClick((): void => this.viewModel.requestWatchRecordingState(
              this.viewModel.state.device.remoteRecordingState === 'recording' ? 'stopped' : 'recording'))
          Text(this.viewModel.state.device.operationMessage.length > 0 ?
            this.viewModel.state.device.operationMessage : this.viewModel.state.message.length > 0 ?
              this.viewModel.state.message : '保持手机与手表连接，可自动接收新录音')
            .width('100%')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .maxLines(2)
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(16)

        Row({ space: 10 }) {
          Button('同步 Watch', { type: ButtonType.Capsule })
            .layoutWeight(1)
            .height(46)
            .backgroundColor($r('app.color.brand_primary'))
            .fontColor(Color.White)
            .enabled(!this.viewModel.state.device.watchSyncing)
            .onClick((): void => this.viewModel.requestWatchSync())
          Button(this.viewModel.state.device.receiverReconnecting ? '正在重连…' : '重新连接',
          { type: ButtonType.Capsule })
            .layoutWeight(1)
            .height(46)
            .backgroundColor($r('app.color.surface_secondary'))
            .fontColor($r('app.color.text_primary'))
            .enabled(!this.viewModel.state.device.receiverReconnecting &&
              !this.viewModel.state.device.watchSyncing)
            .onClick((): void => this.viewModel.reconnectReceiver())
        }

        this.watchProgress(this.viewModel.state.device.watchTransfer)
        this.operationError()

        if (this.viewModel.state.error.length > 0) {
          Column({ space: 10 }) {
            Text(this.viewModel.state.error)
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
          .padding(12)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor($r('app.color.surface_primary'))
          .borderRadius(12)
        }

        Text('最近会话')
          .width('100%')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        if (this.viewModel.state.snapshot.sessions.length > 0) {
          this.latestSession(this.viewModel.state.snapshot.sessions[0])
        } else if (this.viewModel.state.localReady) {
          Text('手机上还没有录音；电脑离线不会影响这里的本地列表。')
            .width('100%')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .padding(18)
            .backgroundColor($r('app.color.surface_primary'))
            .borderRadius(16)
        } else {
          LoadingProgress().width(32).height(32)
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 22, bottom: 100 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
