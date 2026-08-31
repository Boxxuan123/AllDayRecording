import {
  formatRecordingDuration,
  formatRecordingReceivedAt,
  formatRecordingSize
} from 'common';
import { PhoneRecordingGroup } from './PhoneRecordingGroups';
import { PhoneRecordingViewModel } from './PhoneRecordingViewModel';

const PLAYER_WAVEFORM_LEVELS: Array<number> = [
  24, 38, 58, 42, 72, 50, 82, 62, 38, 68, 88, 54, 76, 46, 64, 34, 52, 28
];

@Component
export struct PhoneRecordingPlaybackPage {
  @ObjectLink viewModel: PhoneRecordingViewModel;
  @State private isSeeking: boolean = false;
  @State private seekingPositionMs: number = 0;
  groupKey: string = '';

  aboutToDisappear(): void {
    this.viewModel.stopPlayback();
  }

  private displayDuration(group: PhoneRecordingGroup): number {
    return Math.max(group.durationMs, this.viewModel.playbackDurationMs);
  }

  private displayPosition(group: PhoneRecordingGroup): number {
    const duration = this.displayDuration(group);
    const position = this.isSeeking ? this.seekingPositionMs : this.viewModel.playbackPositionMs;
    return Math.max(0, Math.min(position, duration));
  }

  private onSliderChange(value: number, mode: SliderChangeMode): void {
    this.seekingPositionMs = value;
    if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
      this.isSeeking = true;
      return;
    }
    this.isSeeking = false;
    this.viewModel.seekPlayback(value);
  }

  @Builder
  private recordingContent(group: PhoneRecordingGroup) {
    Column() {
      Column({ space: 6 }) {
        Text(formatRecordingReceivedAt(group.startedAt))
          .width('100%')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .textAlign(TextAlign.Center)

        Text(`${group.recordings.length > 1 ? `${group.recordings.length} 段连续录音` : '录音'}` +
          ` · ${formatRecordingSize(group.size)}`)
          .width('100%')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
      }
      .width('100%')

      Column({ space: 18 }) {
        Stack() {
          Row({ space: 4 }) {
            ForEach(PLAYER_WAVEFORM_LEVELS, (level: number) => {
              Column()
                .width(4)
                .height(level)
                .backgroundColor($r('app.color.brand_primary'))
                .borderRadius(2)
            }, (_level: number, index: number): string => index.toString())
          }
          .height(112)
          .alignItems(VerticalAlign.Center)
          .justifyContent(FlexAlign.Center)
        }
        .width(196)
        .height(196)
        .borderRadius(98)
        .backgroundColor($r('app.color.surface_accent'))

        Text(this.viewModel.isPlaybackBusy ? '正在载入…' : this.viewModel.isPlaying ? '正在播放' :
          this.viewModel.playbackPositionMs > 0 ? '已暂停' : '准备播放')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .padding({ top: 12, bottom: 12 })

      Column({ space: 2 }) {
        Slider({
          value: this.displayPosition(group),
          min: 0,
          max: Math.max(1, this.displayDuration(group)),
          step: 1,
          style: SliderStyle.OutSet
        })
          .width('100%')
          .trackThickness(4)
          .blockColor($r('app.color.brand_primary'))
          .selectedColor($r('app.color.brand_primary'))
          .trackColor($r('app.color.surface_secondary'))
          .enabled(this.displayDuration(group) > 0 && !this.viewModel.isPlaybackBusy &&
            this.viewModel.deletingRecordingGroupKey.length === 0)
          .onChange((value: number, mode: SliderChangeMode): void => this.onSliderChange(value, mode))

        Row() {
          Text(formatRecordingDuration(this.displayPosition(group)))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))

          Text(formatRecordingDuration(this.displayDuration(group)))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
      }
      .width('100%')

      Row() {
        Column({ space: 7 }) {
          SymbolGlyph($r('sys.symbol.gobackward_15'))
            .fontSize(30)
            .fontColor([$r('app.color.text_primary')])

          Text('后退 15 秒')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .width(96)
        .height(76)
        .justifyContent(FlexAlign.Center)
        .enabled(!this.viewModel.isPlaybackBusy)
        .onClick((): void => this.viewModel.skipPlayback(-15000))

        Stack() {
          if (this.viewModel.isPlaybackBusy) {
            LoadingProgress()
              .width(30)
              .height(30)
              .color($r('app.color.on_emphasis'))
          } else {
            SymbolGlyph(this.viewModel.isPlaying ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
              .fontSize(34)
              .fontColor([$r('app.color.on_emphasis')])
          }
        }
        .width(72)
        .height(72)
        .borderRadius(36)
        .backgroundColor($r('app.color.brand_primary'))
        .enabled(!this.viewModel.isPlaybackBusy)
        .onClick((): void => this.viewModel.togglePlayback())

        Column({ space: 7 }) {
          SymbolGlyph($r('sys.symbol.goforward_15'))
            .fontSize(30)
            .fontColor([$r('app.color.text_primary')])

          Text('前进 15 秒')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .width(96)
        .height(76)
        .justifyContent(FlexAlign.Center)
        .enabled(!this.viewModel.isPlaybackBusy)
        .onClick((): void => this.viewModel.skipPlayback(15000))
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceAround)
      .padding({ top: 18, bottom: 24 })

    }
    .width('100%')
    .height('100%')
  }

  build() {
    Column() {
      if (this.viewModel.recordingGroup(this.groupKey) !== undefined) {
        this.recordingContent(this.viewModel.recordingGroup(this.groupKey) as PhoneRecordingGroup)
      } else {
        Column({ space: 8 }) {
          Text('这条录音已不存在')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))

          Text('返回录音列表可查看当前保存的录音')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: 18, bottom: 24 })
    .backgroundColor($r('app.color.page_background'))
  }
}
