import {
  formatRecordingDuration, formatRecordingReceivedAt, formatRecordingSize
} from 'common';
import { uiMaterial } from '@kit.ArkUI';
import { PhoneRecordingViewModel } from './PhoneRecordingViewModel';
import { PhoneRecordingGroup } from './PhoneRecordingGroups';
import { PhoneSyncProgressView } from './PhoneSyncProgressView';

@Component
struct PhoneRecordingMoreButton {
  @ObjectLink viewModel: PhoneRecordingViewModel;
  group: PhoneRecordingGroup = new PhoneRecordingGroup('', [], 0, 0, 0, 0);
  onDelete: (group: PhoneRecordingGroup) => void = (_group: PhoneRecordingGroup): void => {
  };

  @Builder
  private menu() {
    Menu() {
      MenuItem({ content: '删除' })
        .onClick((): void => this.onDelete(this.group))
    }
    .backgroundColor($r('app.color.surface_primary'))
    .borderRadius(16)
  }

  build() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      if (this.viewModel.isDeletingRecordingGroup(this.group)) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color($r('app.color.text_secondary'))
      } else {
        Image($r('sys.media.ohos_ic_public_more'))
          .width(22)
          .height(22)
          .fillColor($r('app.color.text_secondary'))
      }
    }
    .width(40)
    .height(40)
    .buttonStyle(ButtonStyleMode.TEXTUAL)
    .accessibilityText('更多')
    .enabled(this.viewModel.deletingRecordingGroupKey.length === 0)
    .bindMenu(this.menu, {
      systemMaterial: new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THICK,
        interactive: true,
        lightEffect: {}
      })
    })
  }
}

@Component
export struct PhoneRecordingHistoryPage {
  @ObjectLink viewModel: PhoneRecordingViewModel;
  onOpenRecording: (groupKey: string) => void = (_groupKey: string): void => {
  };

  private confirmDelete(group: PhoneRecordingGroup): void {
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '删除录音？',
        message: group.recordings.length > 1 ?
          '这条连续录音包含的全部音频都会被删除，且无法恢复。' : '删除后将无法恢复这条录音。',
        buttons: [
          { text: '取消', color: $r('app.color.text_secondary') },
          { text: '删除', color: $r('app.color.brand_danger') }
        ]
      }).then((result): void => {
        if (result.index === 1) {
          this.viewModel.deleteRecordingGroup(group);
        }
      }, (): void => {
      });
    } catch (error) {
      this.viewModel.status = '无法显示删除确认框，请重试';
    }
  }

  build() {
    Column({ space: 16 }) {
      Column({ space: 4 }) {
        Text('录音记录')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        Text('同步并试听已经保存到手机的录音')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Row({ space: 8 }) {
        Text(`我的录音  ${this.viewModel.receivedRecordingGroups.length}`)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Button(this.viewModel.syncButtonLabel(), { type: ButtonType.Capsule })
          .height(36)
          .fontSize(14)
          .fontColor($r('app.color.brand_primary'))
          .backgroundColor($r('app.color.surface_accent'))
          .enabled(!this.viewModel.syncState.inProgress && !this.viewModel.wifiReceiverReady &&
            !this.viewModel.wifiBusy)
          .onClick((): void => this.viewModel.requestWatchSync())

        Button(this.viewModel.wifiButtonLabel(), { type: ButtonType.Capsule })
          .height(36)
          .fontSize(14)
          .fontColor(this.viewModel.wifiReceiverReady ?
            $r('app.color.on_emphasis') : $r('app.color.brand_primary'))
          .backgroundColor(this.viewModel.wifiReceiverReady ?
            $r('app.color.brand_success') : $r('app.color.surface_accent'))
          .enabled(!this.viewModel.wifiBusy && !this.viewModel.syncState.inProgress)
          .onClick((): void => this.viewModel.toggleWifiReceiver())
      }
      .width('100%')

      PhoneSyncProgressView({ viewModel: this.viewModel })

      if (this.viewModel.wifiReceiverReady || this.viewModel.wifiProgress > 0 ||
        this.viewModel.wifiStatus.includes('失败')) {
        Column({ space: 7 }) {
          Row({ space: 8 }) {
            Text(this.viewModel.wifiStatus)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(2)
              .layoutWeight(1)

            if (this.viewModel.wifiProgress > 0) {
              Text(`${this.viewModel.wifiProgress}%`)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.brand_success'))
            }
          }
          .width('100%')

          if (this.viewModel.wifiProgress > 0) {
            Progress({ value: this.viewModel.wifiProgress, total: 100, type: ProgressType.Linear })
              .width('100%')
              .height(6)
              .color($r('app.color.brand_success'))
              .backgroundColor($r('app.color.surface_secondary'))
          }
        }
        .width('100%')
        .padding({
          left: 12,
          right: 12,
          top: 10,
          bottom: 10
        })
        .backgroundColor($r('app.color.surface_progress'))
        .borderRadius(10)
      }

      if (this.viewModel.receivedRecordingGroups.length === 0) {
        Column({ space: 8 }) {
          Text('还没有录音')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))

          Text('完成手表录音后，可用“同步录音”或同一 WLAN 下的“Wi-Fi 快传”接收')
            .width('100%')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.viewModel.receivedRecordingGroups, (group: PhoneRecordingGroup) => {
            ListItem() {
              Row({ space: 12 }) {
                Column({ space: 5 }) {
                  Text(formatRecordingReceivedAt(group.startedAt))
                    .width('100%')
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))

                  Text(`${formatRecordingDuration(group.durationMs)} · ${formatRecordingSize(group.size)}` +
                    `${group.recordings.length > 1 ? ` · ${group.recordings.length} 段连续录音` : ''}`)
                    .width('100%')
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .onClick((): void => {
                  this.viewModel.selectRecordingGroup(group);
                  this.onOpenRecording(group.key);
                })

                PhoneRecordingMoreButton({
                  viewModel: this.viewModel,
                  group: group,
                  onDelete: (recordingGroup: PhoneRecordingGroup): void => this.confirmDelete(recordingGroup)
                })
              }
              .width('100%')
              .padding(15)
              .backgroundColor($r('app.color.surface_primary'))
              .borderRadius(14)
            }
          }, (group: PhoneRecordingGroup): string => group.key)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .padding({
      left: 20,
      right: 20,
      top: 24,
      bottom: 92
    })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.page_background'))
  }
}
