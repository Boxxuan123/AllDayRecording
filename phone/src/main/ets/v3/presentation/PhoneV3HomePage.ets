import { phoneV3PendingReviews } from '../domain/PhoneV3ReviewModels';
import { ExceptionPromptV2, MarginTypeV2, PromptOptionsV2, SymbolGlyphModifier } from '@kit.ArkUI';
import { PhoneV3SessionCard } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { PHONE_V3_UI_STATE_STORAGE_KEY, PhoneV3UiState } from './PhoneV3UiState';
import {
  phoneV3SessionTitle,
  phoneV3TranscriptSummary,
  phoneV3UpdatedLabel
} from './PhoneV3UiFormat';
import { PHONE_V3_FLOATING_TAB_BAR_CONTENT_END_OFFSET } from './PhoneV3NativeUi';

@Component
export struct PhoneV3HomePage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  @Prop stateRevision: number = 0;
  onOpenSession: (session: PhoneV3SessionCard) => void = (_session: PhoneV3SessionCard): void => {};
  onOpenReviews: () => void = (): void => {};

  private pendingReviewCount(): number {
    const snapshot = this.currentUiState().snapshot;
    return phoneV3PendingReviews(snapshot.reviewItems).length + snapshot.conflicts.filter((value): boolean => ['speaker.assign', 'segment.classify'].indexOf(value.kind) >= 0).length;
  }

  private currentUiState(): PhoneV3UiState {
    const state = AppStorage.get<PhoneV3UiState>(PHONE_V3_UI_STATE_STORAGE_KEY);
    return this.stateRevision >= 0 && state !== undefined ? state : new PhoneV3UiState();
  }

  private operationErrorText(): string {
    if (this.currentUiState().error.length > 0) {
      return this.currentUiState().error;
    }
    if (this.currentUiState().device.watchTransfer.error.length > 0) {
      return this.currentUiState().device.watchTransfer.error;
    }
    if (this.currentUiState().device.wifi.error.length > 0) {
      return this.currentUiState().device.wifi.error;
    }
    return this.currentUiState().device.operationError;
  }

  private activeProcessingCount(): number {
    return this.currentUiState().snapshot.sessions.filter((session: PhoneV3SessionCard): boolean =>
      session.processingStatus === 'running' || session.processingStatus === 'queued').length;
  }

  private recordingActionLabel(): string {
    if (this.currentUiState().device.watchControlBusy) {
      return '正在等待手表确认…';
    }
    return this.currentUiState().device.remoteRecordingState === 'recording' ?
      '停止录音并保存' : '开始录音';
  }

  private ordinarySyncLabel(): string {
    if (!this.currentUiState().device.watchSyncing) {
      return '普通同步';
    }
    if (this.currentUiState().device.watchTotal > 0) {
      return `${this.currentUiState().device.watchReceived}/${this.currentUiState().device.watchTotal}`;
    }
    return '正在同步…';
  }

  private wifiTransferLabel(): string {
    if (this.currentUiState().device.wifi.busy) {
      return this.currentUiState().device.wifi.stopping ? '正在停止…' : '正在准备…';
    }
    return this.currentUiState().device.wifi.ready ? '停止快传' : 'Wi-Fi 快传';
  }

  private transferStatusText(): string {
    if (this.currentUiState().device.watchSyncing || this.currentUiState().device.watchTransfer.active) {
      const transfer = this.currentUiState().device.watchTransfer;
      if (transfer.stage.length > 0) {
        return transfer.stage;
      }
      if (transfer.message.length > 0) {
        return transfer.message;
      }
      return '正在从手表接收录音';
    }
    if (this.currentUiState().device.wifi.busy || this.currentUiState().device.wifi.ready ||
      this.currentUiState().device.wifi.percent > 0) {
      return this.currentUiState().device.wifi.status.length > 0 ?
        this.currentUiState().device.wifi.status : 'Wi-Fi 快传已就绪';
    }
    return '普通同步更稳定；同一 Wi-Fi 下可使用快传';
  }

  private transferPercent(): number {
    if (this.currentUiState().device.watchSyncing || this.currentUiState().device.watchTransfer.active) {
      return this.currentUiState().device.watchTransfer.percent;
    }
    return this.currentUiState().device.wifi.percent;
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
  private summary(value: string, label: string, warning: boolean = false) {
    Column({ space: 2 }) {
      Text(value)
        .fontSize(21)
        .fontWeight(FontWeight.Bold)
        .fontColor(warning ? $r('app.color.brand_warning') : $r('app.color.text_primary'))
      Text(label)
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
    }
    .layoutWeight(1)
    .padding({ top: 4, bottom: 4 })
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private latestSession() {
    Column({ space: 7 }) {
      Row({ space: 8 }) {
        Text(phoneV3SessionTitle(this.currentUiState().snapshot.sessions[0]))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.currentUiState().snapshot.sessions[0].sessionId.length > 0 ? '已备份' : '仅手机')
          .fontSize(11)
          .fontColor(this.currentUiState().snapshot.sessions[0].sessionId.length > 0 ?
            $r('app.color.brand_success') : $r('app.color.text_secondary'))
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(15)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width('100%')
      Row({ space: 6 }) {
        Text(phoneV3UpdatedLabel(this.currentUiState().snapshot.sessions[0].updatedAt))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
        Text('·')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
        Text(phoneV3TranscriptSummary(this.currentUiState().snapshot.sessions[0]))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.surface_primary'))
    .borderRadius(14)
    .onClick((): void => this.onOpenSession(this.currentUiState().snapshot.sessions[0]))
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Column({ space: 10 }) {
          Row({ space: 10 }) {
            Column()
              .width(10)
              .height(10)
              .borderRadius(5)
              .backgroundColor(this.currentUiState().device.remoteRecordingState === 'recording' ?
                $r('app.color.brand_danger') : $r('app.color.brand_success'))
            Column({ space: 2 }) {
              Text('手表录音')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text(this.currentUiState().device.watchStatus)
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            if (this.currentUiState().device.receiverReconnecting) {
              LoadingProgress().width(22).height(22).color($r('app.color.brand_primary'))
            }
          }
          .width('100%')

          Button({ type: ButtonType.Capsule }) {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.waveform'))
                .fontSize(20)
                .fontColor([$r('app.color.on_emphasis')])
              Text(this.recordingActionLabel())
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.on_emphasis'))
            }
          }
          .width('100%')
          .height(52)
          .enabled(!this.currentUiState().device.watchControlBusy &&
            !this.currentUiState().device.receiverReconnecting)
          .buttonStyle(ButtonStyleMode.EMPHASIZED)
          .role(this.currentUiState().device.remoteRecordingState === 'recording' ?
            ButtonRole.ERROR : ButtonRole.NORMAL)
          .accessibilityText(this.recordingActionLabel())
          .onClick((): void => this.viewModel.requestWatchRecordingState(
            this.currentUiState().device.remoteRecordingState === 'recording' ? 'stopped' : 'recording'))

          Text(this.currentUiState().device.operationMessage.length > 0 ?
            this.currentUiState().device.operationMessage : '录音保存在手表，停止后可同步到手机')
            .width('100%')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding(14)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(18)

        Column({ space: 10 }) {
          Row() {
            Text('同步录音')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            Text(this.currentUiState().device.wifi.ready ? '快传已就绪' : '选择接收方式')
              .fontSize(11)
              .fontColor(this.currentUiState().device.wifi.ready ?
                $r('app.color.brand_success') : $r('app.color.text_secondary'))
          }
          .width('100%')

          Row({ space: 8 }) {
            Button({ type: ButtonType.Capsule }) {
              Row({ space: 6 }) {
                SymbolGlyph($r('sys.symbol.arrow_2_circlepath'))
                  .fontSize(18)
                  .fontColor([$r('app.color.text_primary')])
                Text(this.ordinarySyncLabel())
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
              }
            }
            .layoutWeight(1)
            .height(46)
            .enabled(!this.currentUiState().device.watchSyncing &&
              !this.currentUiState().device.wifi.busy && !this.currentUiState().device.wifi.ready)
            .opacity(!this.currentUiState().device.watchSyncing &&
              !this.currentUiState().device.wifi.busy && !this.currentUiState().device.wifi.ready ? 1 : 0.5)
            .buttonStyle(ButtonStyleMode.NORMAL)
            .backgroundColor($r('app.color.surface_secondary'))
            .accessibilityText(this.ordinarySyncLabel())
            .onClick((): void => this.viewModel.requestWatchSync())

            Button({ type: ButtonType.Capsule }) {
              Row({ space: 6 }) {
                SymbolGlyph($r('sys.symbol.wifi'))
                  .fontSize(18)
                  .fontColor([this.currentUiState().device.wifi.ready ?
                    $r('app.color.brand_success') : $r('app.color.brand_primary')])
                Text(this.wifiTransferLabel())
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.currentUiState().device.wifi.ready ?
                    $r('app.color.brand_success') : $r('app.color.brand_primary'))
                  .maxLines(1)
              }
            }
            .layoutWeight(1)
            .height(46)
            .enabled(!this.currentUiState().device.wifi.busy &&
              !this.currentUiState().device.watchSyncing)
            .opacity(!this.currentUiState().device.wifi.busy &&
              !this.currentUiState().device.watchSyncing ? 1 : 0.5)
            .buttonStyle(ButtonStyleMode.NORMAL)
            .backgroundColor($r('app.color.surface_accent'))
            .accessibilityText(this.wifiTransferLabel())
            .onClick((): void => this.viewModel.toggleWifiReceiver())
          }
          .width('100%')

          Text(this.transferStatusText())
            .width('100%')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (this.transferPercent() > 0) {
            Progress({ value: this.transferPercent(), total: 100, type: ProgressType.Linear })
              .width('100%')
              .height(5)
              .color(this.currentUiState().device.watchSyncing ?
                $r('app.color.brand_primary') : $r('app.color.brand_success'))
              .backgroundColor($r('app.color.surface_secondary'))
          }
        }
        .width('100%')
        .padding(14)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(18)

        Column({ space: 8 }) {
          Row() {
            this.summary(this.pendingReviewCount().toString(), '待审核',
              this.pendingReviewCount() > 0)
            Column()
              .width(1)
              .height(32)
              .backgroundColor($r('app.color.surface_secondary'))
            this.summary(this.activeProcessingCount().toString(), '处理中')
            Column()
              .width(1)
              .height(32)
              .backgroundColor($r('app.color.surface_secondary'))
            this.summary(this.currentUiState().snapshot.sync.pendingOperations.toString(), '待同步')
          }
          .width('100%')
        }
        .width('100%')
        .padding({ top: 9, bottom: 9 })
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(14)

        this.operationError()

        if (this.pendingReviewCount() > 0) {
          Row({ space: 10 }) {
            Stack() {
              SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                .fontSize(20)
                .fontColor([$r('app.color.brand_primary')])
            }
            .width(36)
            .height(36)
            .borderRadius(11)
            .backgroundColor($r('app.color.surface_accent'))
            Column({ space: 2 }) {
              Text(`${this.pendingReviewCount()} 项内容待审核`)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('声音、提醒和人物记忆集中处理')
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(16)
              .fontColor([$r('app.color.text_secondary')])
          }
          .width('100%')
          .padding(12)
          .backgroundColor($r('app.color.surface_progress'))
          .borderRadius(14)
          .accessibilityText('打开待审核内容')
          .onClick((): void => this.onOpenReviews())
        }

        Row() {
          Text('最近录音')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          Text(`${this.currentUiState().snapshot.sessions.length} 条`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .margin({ top: 2 })

        if (this.currentUiState().snapshot.sessions.length > 0) {
          this.latestSession()
        } else if (this.currentUiState().localReady) {
          Text('手机上还没有录音；电脑离线不会影响这里的本地列表。')
            .width('100%')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .padding(14)
            .backgroundColor($r('app.color.surface_primary'))
            .borderRadius(14)
        } else {
          LoadingProgress().width(32).height(32)
        }

      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 6 })
      .alignItems(HorizontalAlign.Start)
    }
    .contentEndOffset(PHONE_V3_FLOATING_TAB_BAR_CONTENT_END_OFFSET)
    .align(Alignment.TopStart)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
