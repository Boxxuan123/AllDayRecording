import { formatRecordingSize } from 'common';
import { ChipV2, ExceptionPromptV2, MarginTypeV2, PromptOptionsV2, SymbolGlyphModifier } from '@kit.ArkUI';
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
import { phoneV3StatusChip } from './PhoneV3NativeUi';

@Component
export struct PhoneV3HomePage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  onOpenSession: (session: PhoneV3SessionCard) => void = (_session: PhoneV3SessionCard): void => {};

  private operationErrorText(): string {
    if (this.viewModel.state.error.length > 0) {
      return this.viewModel.state.error;
    }
    if (this.viewModel.state.device.watchTransfer.error.length > 0) {
      return this.viewModel.state.device.watchTransfer.error;
    }
    return this.viewModel.state.device.operationError;
  }

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
    if (this.operationErrorText().length > 0) {
      ExceptionPromptV2({
        options: new PromptOptionsV2({
          marginType: MarginTypeV2.DEFAULT_MARGIN,
          marginTop: 0,
          symbolStyle: new SymbolGlyphModifier($r('sys.symbol.exclamationmark_circle_fill')),
          tip: this.operationErrorText(),
          actionText: this.viewModel.canRetry() ? '重试' : undefined,
          isShown: true
        }),
        onActionTextClick: (): void => this.viewModel.retryLastAction()
      })
        .width('100%')
    }
  }

  @Builder
  private summary(value: string, label: string) {
    Column({ space: 4 }) {
      Text(value)
        .fontSize(25)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .layoutWeight(1)
    .padding({ top: 14, bottom: 14 })
    .backgroundColor($r('app.color.surface_primary'))
    .borderRadius(14)
  }

  @Builder
  private latestSession(session: PhoneV3SessionCard) {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
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

        ChipV2({ chipV2Options: phoneV3StatusChip(session.sessionId.length > 0 ? '已备份' : '本地') })
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(17)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width('100%')

      Column({ space: 7 }) {
        Text(`手表录音  ${phoneV3WatchStage(session)}`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
        Text(`电脑备份  ${phoneV3ComputerStage(session)}`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
        Text(`转写处理  ${phoneV3ProcessingStage(session)}`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
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
      Column({ space: 18 }) {
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text('全天录音')
              .fontSize(30)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text('手表录音会自动安全回到手机')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          ChipV2({
            chipV2Options: phoneV3StatusChip(this.viewModel.state.snapshot.paired ? '电脑已连接' : '离线可用')
          })
        }
        .width('100%')

        Column({ space: 14 }) {
          Row({ space: 10 }) {
            Column()
              .width(12)
              .height(12)
              .borderRadius(6)
              .backgroundColor(this.viewModel.state.device.remoteRecordingState === 'recording' ?
                $r('app.color.brand_danger') : $r('app.color.brand_success'))
            Column({ space: 3 }) {
              Text('手表')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
              Text(this.viewModel.state.device.watchStatus)
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            if (this.viewModel.state.device.receiverReconnecting) {
              LoadingProgress().width(24).height(24).color($r('app.color.brand_primary'))
            }
          }
          .width('100%')

          Button(this.viewModel.state.device.watchControlBusy ? '正在等待手表…' :
            this.viewModel.state.device.remoteRecordingState === 'recording' ? '停止并保存' : '开始录音',
          { type: ButtonType.Capsule })
            .width('100%')
            .height(54)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .enabled(!this.viewModel.state.device.watchControlBusy &&
              !this.viewModel.state.device.receiverReconnecting)
            .buttonStyle(ButtonStyleMode.EMPHASIZED)
            .role(this.viewModel.state.device.remoteRecordingState === 'recording' ?
              ButtonRole.ERROR : ButtonRole.NORMAL)
            .onClick((): void => this.viewModel.requestWatchRecordingState(
              this.viewModel.state.device.remoteRecordingState === 'recording' ? 'stopped' : 'recording'))

          Row({ space: 10 }) {
            Button(this.viewModel.state.device.watchSyncing ? '正在同步…' : '接收手表录音',
            { type: ButtonType.Capsule })
              .layoutWeight(1)
              .height(44)
              .buttonStyle(ButtonStyleMode.NORMAL)
              .enabled(!this.viewModel.state.device.watchSyncing)
              .onClick((): void => this.viewModel.requestWatchSync())
            Button(this.viewModel.state.device.receiverReconnecting ? '正在重连…' : '重新连接',
            { type: ButtonType.Capsule })
              .layoutWeight(1)
              .height(44)
              .buttonStyle(ButtonStyleMode.NORMAL)
              .enabled(!this.viewModel.state.device.receiverReconnecting &&
                !this.viewModel.state.device.watchSyncing)
              .onClick((): void => this.viewModel.reconnectReceiver())
          }

          Text(this.viewModel.state.device.operationMessage.length > 0 ?
            this.viewModel.state.device.operationMessage : this.viewModel.state.message.length > 0 ?
              this.viewModel.state.message : '保持手机与手表连接，完成后会自动刷新录音')
            .width('100%')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .maxLines(2)
        }
        .width('100%')
        .padding(18)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(20)

        this.watchProgress(this.viewModel.state.device.watchTransfer)
        this.operationError()

        Row({ space: 10 }) {
          this.summary(this.viewModel.state.snapshot.sessions.length.toString(), '录音会话')
          this.summary(this.viewModel.state.snapshot.sync.pendingOperations.toString(), '待备份更新')
        }
        .width('100%')

        Text('最近录音')
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

        if (this.viewModel.state.snapshot.reminders.length > 0) {
          Row() {
            Text('接下来')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            Text(`${this.viewModel.state.snapshot.reminders.length} 条提醒`)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          ForEach(this.viewModel.state.snapshot.reminders.slice(0, 3), (reminder: PhoneV3Reminder) => {
            this.reminderNotification(reminder)
          }, (reminder: PhoneV3Reminder): string => reminder.eventId)
        }
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
