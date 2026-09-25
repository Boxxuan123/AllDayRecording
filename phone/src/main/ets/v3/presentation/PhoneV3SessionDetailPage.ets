import { phoneV3AnnotationLabel, phoneV3AnnotationState } from '../domain/PhoneV3AnnotationState';
import { phoneV3SoundKindLabel } from '../domain/PhoneV3SoundKind';
import { formatRecordingDuration } from 'common';
import {
  CapsuleSegmentButtonV2,
  ChipGroupV2,
  ChipGroupV2ItemConfig,
  ChipGroupV2Items,
  ChipGroupV2ItemStyle,
  ChipV2,
  ExceptionPromptV2,
  MarginTypeV2,
  PromptOptionsV2,
  SegmentButtonV2Items,
  SymbolGlyphModifier
} from '@kit.ArkUI';
import { PhoneV3SessionCard, PhoneV3Utterance } from '../domain/PhoneV3Models';
import { PhoneV3SpeakerAnnotationPanel } from './PhoneV3SpeakerAnnotationPanel';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import {
  phoneV3AbsoluteTime,
  phoneV3SessionMeta,
  phoneV3TimelineTime
} from './PhoneV3UiFormat';
import { phoneV3ImmersiveMaterial, phoneV3StatusChip } from './PhoneV3NativeUi';
import {
  PhoneV3SessionEvidenceTab,
  PhoneV3SessionOverviewTab,
  PhoneV3SessionSpeakersTab
} from './PhoneV3SessionInfoTabs';

class PhoneV3SpeakerChoice {
  id: string | null;
  label: string;

  constructor(id: string | null, label: string) {
    this.id = id;
    this.label = label;
  }
}

@Component
export struct PhoneV3SessionDetailPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  @Prop stateRevision: number = 0;
  routeSession: PhoneV3SessionCard | undefined = undefined;
  @State private isSeeking: boolean = false;
  @State private seeking: number = 0;
  @State private annotationId: string = '';
  @State private correctionVisible: boolean = false;
  @State private correctionText: string = '';
  @State private correctionSpeakerTrackId: string = '';
  @State private correctionIdentity: string = 'unknown';
  @State private selectedContentTab: number = 0;
  private correctionTarget: PhoneV3Utterance | undefined = undefined;

  private currentSession(): PhoneV3SessionCard | undefined {
    if (this.stateRevision < 0) {
      return undefined;
    }
    if (this.routeSession === undefined) {
      return this.viewModel.selectedSession() ?? this.viewModel.snapshot.sessions[0];
    }
    return this.viewModel.resolveCurrentSession(this.routeSession);
  }

  aboutToDisappear(): void {
    this.viewModel.stopPlayback();
  }

  private editUtterance(utterance: PhoneV3Utterance): void {
    this.correctionTarget = utterance;
    this.correctionText = utterance.text;
    this.correctionSpeakerTrackId = utterance.speakerTrackId === null ? '' : utterance.speakerTrackId;
    this.correctionIdentity = utterance.identity;
    this.correctionVisible = true;
  }

  private skipPlayback(session: PhoneV3SessionCard, deltaMs: number): void {
    const duration = Math.max(session.durationMs, this.viewModel.device.playbackDurationMs);
    const next = Math.max(0, Math.min(duration, this.viewModel.device.playbackPositionMs + deltaMs));
    this.viewModel.seekPlayback(next);
  }

  private identityLabel(identity: string): string {
    if (identity === 'self') {
      return '本人';
    }
    if (identity === 'not_self') {
      return '非本人';
    }
    return '未知';
  }

  private identityChoices(): Array<string> {
    return ['self', 'not_self', 'unknown'];
  }

  private identityItems(): SegmentButtonV2Items {
    return new SegmentButtonV2Items([
      { text: '本人' },
      { text: '非本人' },
      { text: '未知' }
    ]);
  }

  private selectedIdentityIndex(): number {
    const index = this.identityChoices().indexOf(this.correctionIdentity);
    return index < 0 ? 2 : index;
  }

  private speakerChoices(): Array<PhoneV3SpeakerChoice> {
    const choices: Array<PhoneV3SpeakerChoice> = [new PhoneV3SpeakerChoice(null, '未指定说话人')];
    const seen: Set<string> = new Set<string>();
    const session = this.currentSession();
    if (session === undefined) {
      return choices;
    }
    for (let index = 0; index < session.utterances.length; index += 1) {
      const utterance = session.utterances[index];
      if (utterance.speakerTrackId !== null && !seen.has(utterance.speakerTrackId)) {
        seen.add(utterance.speakerTrackId);
        choices.push(new PhoneV3SpeakerChoice(utterance.speakerTrackId,
          utterance.speakerLabel === null ? utterance.speakerTrackId : utterance.speakerLabel));
      }
    }
    return choices;
  }

  private speakerItems(): ChipGroupV2Items {
    return new ChipGroupV2Items(this.speakerChoices().map((choice: PhoneV3SpeakerChoice):
      ChipGroupV2ItemConfig => {
      return { label: { text: choice.label } };
    }));
  }

  private selectedSpeakerIndexes(): Array<number> {
    const choices = this.speakerChoices();
    const selectedId = this.correctionSpeakerTrackId;
    for (let index = 0; index < choices.length; index += 1) {
      if ((choices[index].id === null ? '' : choices[index].id) === selectedId) {
        return [index];
      }
    }
    return [0];
  }

  private selectSpeaker(indexes: Array<number>): void {
    if (indexes.length === 0) {
      return;
    }
    const choices = this.speakerChoices();
    const choice = choices[indexes[0]];
    if (choice !== undefined) {
      this.correctionSpeakerTrackId = choice.id === null ? '' : choice.id;
    }
  }

  private submitCorrection(): void {
    if (this.correctionTarget === undefined) {
      return;
    }
    this.viewModel.correctUtterance(this.correctionTarget, this.correctionText,
      this.correctionSpeakerTrackId.length === 0 ? null : this.correctionSpeakerTrackId,
      this.correctionIdentity,
      (): void => {
        this.correctionVisible = false;
        this.correctionTarget = undefined;
      });
  }

  @Builder
  private contentTabButton(index: number, label: string) {
    Button(label, { type: ButtonType.Normal })
      .layoutWeight(1)
      .height(38)
      .fontSize(13)
      .fontWeight(this.selectedContentTab === index ? FontWeight.Medium : FontWeight.Regular)
      .fontColor(this.selectedContentTab === index ? Color.White : $r('app.color.text_secondary'))
      .backgroundColor(this.selectedContentTab === index ?
        $r('app.color.brand_primary') : Color.Transparent)
      .borderRadius(19)
      .onClick((): void => {
        this.selectedContentTab = index;
      })
  }

  @Builder
  private correctionSheet() {
    Column({ space: 14 }) {
      Text('编辑转写')
        .width('100%')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      if (this.correctionTarget !== undefined) {
        Text(`原始结果 · ${this.correctionTarget.originalSpeakerLabel === null ?
          '未指定说话人' : this.correctionTarget.originalSpeakerLabel} · ` +
          `${this.identityLabel(this.correctionTarget.originalIdentity)}`)
          .width('100%')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
        Text(this.correctionTarget.originalText)
          .width('100%')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      }
      TextArea({ text: this.correctionText, placeholder: '输入校正后的转写' })
        .width('100%')
        .height(110)
        .onChange((value: string): void => {
          this.correctionText = value;
        })
      Text('说话人')
        .width('100%')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
      ChipGroupV2({
        items: this.speakerItems(),
        itemStyle: new ChipGroupV2ItemStyle({
          backgroundSystemMaterial: phoneV3ImmersiveMaterial()
        }),
        selectedIndexes: this.selectedSpeakerIndexes(),
        multiple: false,
        onChange: (indexes: Array<number>): void => this.selectSpeaker(indexes)
      })
        .width('100%')
      Text('身份标记')
        .width('100%')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
      CapsuleSegmentButtonV2({
        items: this.identityItems(),
        selectedIndex: this.selectedIdentityIndex(),
        onItemClicked: (index: number): void => {
          this.correctionIdentity = this.identityChoices()[index];
        },
        backgroundSystemMaterial: phoneV3ImmersiveMaterial()
      })
        .width('100%')
      Button('保存修改', { type: ButtonType.Capsule })
        .width('100%')
        .height(46)
        .enabled(!this.viewModel.busy && this.correctionText.trim().length > 0)
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
        .onClick((): void => this.submitCorrection())
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 24, bottom: 24 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private timeline(utterance: PhoneV3Utterance) {
    Column({ space: 6 }) {
      Text(`${phoneV3AbsoluteTime(utterance.startAt)}–${phoneV3AbsoluteTime(utterance.endAt)} · ` +
        `${phoneV3TimelineTime(utterance.startMs)}`)
        .fontSize(12)
        .fontColor($r('app.color.brand_primary'))
      Text(utterance.text.length > 0 ? utterance.text : '（空文本）')
        .width('100%')
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
      Text(phoneV3AnnotationLabel(utterance))
        .width('100%')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
      Row({ space: 8 }) {
        Button('试听这句', { type: ButtonType.Capsule })
          .enabled(!this.viewModel.busy && !this.viewModel.device.playbackBusy)
          .onClick((): void => this.viewModel.playUtterance(utterance))
        Button(phoneV3AnnotationState(utterance).review ? '需复核' : phoneV3AnnotationState(utterance).done ? '查看／修改标注' : '标注片段', { type: ButtonType.Capsule })
          .onClick((): void => { this.annotationId = this.annotationId === utterance.utteranceId ? '' : utterance.utteranceId; })
      }
      if (this.annotationId === utterance.utteranceId) {
        PhoneV3SpeakerAnnotationPanel({ viewModel: this.viewModel,
          utterances: [utterance], stateRevision: this.stateRevision })
      }
      Button('编辑转写', { type: ButtonType.Capsule })
        .height(34)
        .fontSize(12)
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .onClick((): void => this.editUtterance(utterance))
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
      Column({ space: 12 }) {
        Row({ space: 10 }) {
          Text(phoneV3SessionMeta(session))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
          ChipV2({
            chipV2Options: phoneV3StatusChip(session.sessionId.length > 0 ? '已备份' : '本地')
          })
        }
        .width('100%')

        Row({ space: 2 }) {
          this.contentTabButton(0, '时间线')
          this.contentTabButton(1, '概览')
          this.contentTabButton(2, '说话人')
          this.contentTabButton(3, '证据')
        }
        .width('100%')
        .padding(3)
        .borderRadius(22)
        .backgroundColor($r('app.color.surface_secondary'))

        if (session.localPaths.length > 0) {
          Column({ space: 14 }) {
            Row() {
              Text(this.viewModel.device.isPlaying ? '正在播放' :
                this.viewModel.device.playbackPositionMs > 0 ? '已暂停' : '本地播放')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Blank()
              Text(this.viewModel.device.isPlaying ? '播放中' : '就绪')
                .fontSize(12)
                .fontColor(this.viewModel.device.isPlaying ?
                  $r('app.color.brand_success') : $r('app.color.text_secondary'))
            }
            .width('100%')
            Slider({
              value: this.isSeeking ? this.seeking : this.viewModel.device.playbackPositionMs,
              min: 0,
              max: Math.max(1, session.durationMs, this.viewModel.device.playbackDurationMs),
              step: 1,
              style: SliderStyle.OutSet
            })
              .width('100%')
              .trackThickness(4)
              .blockColor($r('app.color.brand_primary'))
              .selectedColor($r('app.color.brand_primary'))
              .trackColor($r('app.color.surface_secondary'))
              .enabled(!this.viewModel.device.playbackBusy)
              .onChange((value: number, mode: SliderChangeMode): void => {
                this.seeking = value;
                if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
                  this.isSeeking = true;
                  return;
                }
                this.isSeeking = false;
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.viewModel.seekPlayback(value);
                }
              })
            Row() {
              Text(formatRecordingDuration(this.isSeeking ? this.seeking :
                this.viewModel.device.playbackPositionMs))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
              Text(formatRecordingDuration(Math.max(session.durationMs,
                this.viewModel.device.playbackDurationMs)))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Button({ type: ButtonType.Normal }) {
                Column({ space: 5 }) {
                  SymbolGlyph($r('sys.symbol.gobackward_15'))
                    .fontSize(28)
                    .fontColor([$r('app.color.text_primary')])
                  Text('15 秒')
                    .fontSize(11)
                    .fontColor($r('app.color.text_secondary'))
                }
              }
              .width(78)
              .height(64)
              .buttonStyle(ButtonStyleMode.TEXTUAL)
              .enabled(!this.viewModel.device.playbackBusy)
              .onClick((): void => this.skipPlayback(session, -15000))

              Button({ type: ButtonType.Circle }) {
                if (this.viewModel.device.playbackBusy) {
                  LoadingProgress()
                    .width(28)
                    .height(28)
                    .color(Color.White)
                } else {
                  SymbolGlyph(this.viewModel.device.isPlaying ?
                    $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
                    .fontSize(30)
                    .fontColor([Color.White])
                }
              }
              .width(64)
              .height(64)
              .buttonStyle(ButtonStyleMode.EMPHASIZED)
              .enabled(!this.viewModel.device.playbackBusy)
              .onClick((): void => this.viewModel.togglePlayback())

              Button({ type: ButtonType.Normal }) {
                Column({ space: 5 }) {
                  SymbolGlyph($r('sys.symbol.goforward_15'))
                    .fontSize(28)
                    .fontColor([$r('app.color.text_primary')])
                  Text('15 秒')
                    .fontSize(11)
                    .fontColor($r('app.color.text_secondary'))
                }
              }
              .width(78)
              .height(64)
              .buttonStyle(ButtonStyleMode.TEXTUAL)
              .enabled(!this.viewModel.device.playbackBusy)
              .onClick((): void => this.skipPlayback(session, 15000))
            }
              .width('100%')
              .justifyContent(FlexAlign.SpaceAround)
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.surface_primary'))
          .borderRadius(16)
        } else {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.waveform'))
              .fontSize(20)
              .fontColor([$r('app.color.text_secondary')])
            Text('手机暂无可播放音频')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding(14)
          .backgroundColor($r('app.color.surface_primary'))
          .borderRadius(14)
        }

        if (this.viewModel.error.length > 0 || this.viewModel.device.operationError.length > 0) {
          ExceptionPromptV2({
            options: new PromptOptionsV2({
              marginType: MarginTypeV2.DEFAULT_MARGIN,
              marginTop: 0,
              symbolStyle: new SymbolGlyphModifier($r('sys.symbol.exclamationmark_circle_fill')),
              tip: this.viewModel.error.length > 0 ? this.viewModel.error :
                this.viewModel.device.operationError,
              actionText: this.viewModel.canRetry() ? '重试' : undefined,
              isShown: true
            }),
            onActionTextClick: (): void => this.viewModel.retryLastAction()
          })
            .width('100%')
        }

        if (this.selectedContentTab === 0) {
          Text('转写时间线')
            .width('100%')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          if (session.utterances.length === 0) {
            Text('电脑尚未生成转写，已有本地音频仍可播放。')
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
        } else if (this.selectedContentTab === 1) {
          PhoneV3SessionOverviewTab({ session: session })
        } else if (this.selectedContentTab === 2) {
          PhoneV3SessionSpeakersTab({ session: session })
        } else {
          PhoneV3SessionEvidenceTab({ session: session })
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 8, bottom: 32 })
    }
    .align(Alignment.TopStart)
    .width('100%')
    .height('100%')
  }

  build() {
    Column() {
      if (this.currentSession() !== undefined) {
        this.content(this.currentSession() as PhoneV3SessionCard)
      } else {
        Text('会话已不存在').fontColor($r('app.color.text_secondary'))
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.page_background'))
    .bindSheet(this.correctionVisible, this.correctionSheet(), {
      height: 680,
      showClose: true,
      onDisappear: (): void => {
        this.correctionVisible = false;
      }
    })
  }
}
