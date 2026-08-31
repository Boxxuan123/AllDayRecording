import {
  formatRecordingDuration, formatRecordingReceivedAt, formatRecordingSize
} from 'common';
import { PhoneRecordingGroup } from './PhoneRecordingGroups';
import { PhoneRecordingPlaybackPage } from './PhoneRecordingPlaybackPage';
import { PhoneRecordingViewModel } from './PhoneRecordingViewModel';

@Component
export struct PhoneLegacyReadOnlyPage {
  @ObjectLink viewModel: PhoneRecordingViewModel;
  @State private playbackGroupKey: string = '';

  private openPlayback(group: PhoneRecordingGroup): void {
    this.viewModel.selectRecordingGroup(group);
    this.playbackGroupKey = group.key;
  }

  private closePlayback(): void {
    this.viewModel.stopPlayback();
    this.playbackGroupKey = '';
  }

  @Builder
  private recordingList() {
    Scroll() {
      Column({ space: 14 }) {
        Column({ space: 6 }) {
          Text('Legacy V2 只读回退')
            .width('100%')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('仅用于查看与试听既有手机录音；同步、上传、删除和数据修改均已禁用。')
            .width('100%')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        if (this.viewModel.receivedRecordingGroups.length === 0) {
          Text('Legacy 本地索引中没有录音')
            .width('100%')
            .padding(18)
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .backgroundColor($r('app.color.surface_primary'))
            .borderRadius(14)
        } else {
          ForEach(this.viewModel.receivedRecordingGroups, (group: PhoneRecordingGroup) => {
            Column({ space: 5 }) {
              Text(formatRecordingReceivedAt(group.startedAt))
                .width('100%')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text(`${formatRecordingDuration(group.durationMs)} · ${formatRecordingSize(group.size)} · ` +
                `${group.recordings.length} 个本地文件`)
                .width('100%')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .padding(15)
            .alignItems(HorizontalAlign.Start)
            .backgroundColor($r('app.color.surface_primary'))
            .borderRadius(14)
            .onClick((): void => this.openPlayback(group))
          }, (group: PhoneRecordingGroup): string => group.key)
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 22, bottom: 48 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private playback() {
    Column({ space: 8 }) {
      Button('返回 Legacy 录音列表', { type: ButtonType.Capsule })
        .margin({ left: 18, right: 18, top: 12 })
        .fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.surface_secondary'))
        .onClick((): void => this.closePlayback())

      PhoneRecordingPlaybackPage({
        viewModel: this.viewModel,
        groupKey: this.playbackGroupKey
      })
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      if (this.playbackGroupKey.length > 0) {
        this.playback()
      } else {
        this.recordingList()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
