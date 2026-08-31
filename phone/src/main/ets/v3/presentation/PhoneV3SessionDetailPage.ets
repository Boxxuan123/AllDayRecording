import { formatRecordingDuration } from 'common';
import { PhoneV3SessionCard, PhoneV3Utterance } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import {
  phoneV3ComputerStage,
  phoneV3ProcessingStage,
  phoneV3SessionMeta,
  phoneV3SessionTitle,
  phoneV3TimelineTime,
  phoneV3WatchStage
} from './PhoneV3UiFormat';

@Component
export struct PhoneV3SessionDetailPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  onBack: () => void = (): void => {};
  @State private seeking: number = 0;

  @Builder
  private stage(label: string, value: string) {
    Row({ space: 12 }) {
      Text(label)
        .width(128)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text(value)
        .layoutWeight(1)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
  }

  @Builder
  private timeline(utterance: PhoneV3Utterance) {
    Column({ space: 6 }) {
      Text(`${phoneV3TimelineTime(utterance.startMs)}–${phoneV3TimelineTime(utterance.endMs)}`)
        .fontSize(12)
        .fontColor($r('app.color.brand_primary'))
      Text(utterance.text.length > 0 ? utterance.text : '（空文本）')
        .width('100%')
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
      Text(`utterance_id ${utterance.utteranceId} · revision ${utterance.revision}`)
        .width('100%')
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(2)
      Text(`evidence ${utterance.evidenceJson}`)
        .width('100%')
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(3)
    }
    .width('100%')
    .padding(14)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.surface_primary'))
    .borderRadius(12)
  }

  @Builder
  private content(session: PhoneV3SessionCard) {
    Scroll() {
      Column({ space: 16 }) {
        Row({ space: 8 }) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(20)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(42)
          .height(42)
          .backgroundColor($r('app.color.surface_secondary'))
          .onClick((): void => this.onBack())
          Text('会话详情')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
        }
        .width('100%')

        Column({ space: 5 }) {
          Text(phoneV3SessionTitle(session))
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(phoneV3SessionMeta(session))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
          Text(session.sessionId.length > 0 ? session.sessionId : '尚无 Computer session_id')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 12 }) {
          this.stage('Watch → Phone', phoneV3WatchStage(session))
          this.stage('Phone → Computer', phoneV3ComputerStage(session))
          this.stage('Computer 处理', phoneV3ProcessingStage(session))
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(16)

        if (session.localPaths.length > 0) {
          Column({ space: 10 }) {
            Row() {
              Text(this.viewModel.state.device.isPlaying ? '正在播放' :
                this.viewModel.state.device.playbackPositionMs > 0 ? '已暂停' : '本地播放')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Blank()
              Text(`${formatRecordingDuration(this.viewModel.state.device.playbackPositionMs)} / ` +
                `${formatRecordingDuration(Math.max(session.durationMs,
                  this.viewModel.state.device.playbackDurationMs))}`)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            Slider({
              value: this.viewModel.state.device.playbackPositionMs,
              min: 0,
              max: Math.max(1, session.durationMs, this.viewModel.state.device.playbackDurationMs),
              step: 1
            })
              .width('100%')
              .selectedColor($r('app.color.brand_primary'))
              .onChange((value: number, mode: SliderChangeMode): void => {
                this.seeking = value;
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.viewModel.seekPlayback(value);
                }
              })
            Button(this.viewModel.state.device.playbackBusy ? '正在载入…' :
              this.viewModel.state.device.isPlaying ? '暂停' : '播放', { type: ButtonType.Capsule })
              .width('100%')
              .height(46)
              .enabled(!this.viewModel.state.device.playbackBusy)
              .backgroundColor($r('app.color.brand_primary'))
              .fontColor(Color.White)
              .onClick((): void => this.viewModel.togglePlayback())
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.surface_primary'))
          .borderRadius(16)
        }

        Text('只读时间线')
          .width('100%')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        if (session.utterances.length === 0) {
          Text('电脑尚未生成 utterance 投影；已有本地音频仍可播放。')
            .width('100%')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .padding(16)
            .backgroundColor($r('app.color.surface_primary'))
            .borderRadius(12)
        } else {
          ForEach(session.utterances, (utterance: PhoneV3Utterance) => {
            this.timeline(utterance)
          }, (utterance: PhoneV3Utterance): string => utterance.utteranceId)
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 18, bottom: 32 })
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Column() {
      if (this.viewModel.selectedSession() !== undefined) {
        this.content(this.viewModel.selectedSession() as PhoneV3SessionCard)
      } else {
        Text('会话已不存在').fontColor($r('app.color.text_secondary'))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
