import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { DeviceV3PersonChoice } from '../../computer/ComputerTransferProtocol';
import { PhoneV3ReviewItem, PhoneV3SessionCard } from '../domain/PhoneV3Models';
import { PhoneV3VoiceCandidate, phoneV3ReviewIsHistory, phoneV3VoiceCandidates } from '../domain/PhoneV3ReviewModels';
import { PhoneV3VoiceTask } from '../domain/PhoneV3VoiceReviewTask';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { PhoneV3PeopleLoader } from './PhoneV3PeopleLoader';
import { PhoneV3PersonSelector } from './PhoneV3PersonSelector';
import { phoneV3SessionTitle } from './PhoneV3UiFormat';

interface PurityAnswer {
  primary_speaker_person_id?: string | null;
  primary_speaker_unknown?: boolean;
  unknown_kind?: string;
  purity?: string;
  other_speaker_ids?: Array<string>;
  quality_flags?: Array<string>;
  target_person_id?: string;
}

interface PurityContext {
  purity_review?: PurityAnswer;
  duration_ms?: number;
}

@Component
export struct PhoneV3PurityReviewPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  navStack: NavPathStack = new NavPathStack();
  reviewId: string = '';
  reviewKind: string = 'speaker_profile_purity';
  history: boolean = false;
  @Prop @Watch('refreshState') stateRevision: number = 0;
  private peopleLoader: PhoneV3PeopleLoader = new PhoneV3PeopleLoader();
  @State private people: Array<DeviceV3PersonChoice> = [];
  @State private tasks: Array<PhoneV3ReviewItem> = [];
  @State private task: PhoneV3ReviewItem | undefined = undefined;
  @State private candidate: PhoneV3VoiceCandidate | undefined = undefined;
  @State private primaryId: string = '';
  @State private primaryName: string = '';
  @State private unknown: boolean = false;
  @State private unknownKind: string = 'dont_know';
  @State private purity: string = '';
  @State private others: Array<string> = [];
  @State private flags: Array<string> = [];
  @State private pickerOpen: boolean = false;
  @State private pickingOther: boolean = false;
  @State private qualityOpen: boolean = false;
  @State private feedback: string = '';
  @State private saving: boolean = false;
  @State private lastReviewId: string = '';
  private visible: boolean = false;

  aboutToAppear(): void {
    this.visible = true;
    this.loadQueue();
    this.peopleLoader.refresh((accept): void => this.viewModel.loadPeople(accept),
      (values: Array<DeviceV3PersonChoice>): void => { this.people = values; if (this.history) { this.resetAnswer(); } });
  }

  aboutToDisappear(): void {
    this.visible = false;
    this.viewModel.setReviewAudioWindow([], false);
    this.viewModel.stopPlayback();
  }

  private refreshState(): void {
    if (this.visible && this.tasks.length === 0) { this.loadQueue(); }
  }

  private loadQueue(): void {
    const all = this.viewModel.snapshot.reviewItems.filter((item: PhoneV3ReviewItem): boolean =>
      item.kind === this.reviewKind && phoneV3ReviewIsHistory(item) === this.history);
    const start = this.reviewId ? all.findIndex((item: PhoneV3ReviewItem): boolean => item.reviewId === this.reviewId) : 0;
    this.tasks = start > 0 ? all.slice(start).concat(all.slice(0, start)) : all;
    this.showCurrent();
  }

  private showCurrent(): void {
    this.task = this.tasks[0];
    this.candidate = this.task ? phoneV3VoiceCandidates(this.task)[0] : undefined;
    this.resetAnswer();
    const upcoming: Array<PhoneV3VoiceTask> = [];
    for (const item of this.tasks.slice(0, 3)) {
      const candidate = phoneV3VoiceCandidates(item)[0];
      if (candidate !== undefined) { upcoming.push(new PhoneV3VoiceTask(item, candidate)); }
    }
    this.viewModel.setReviewAudioWindow(upcoming, !this.history && upcoming.length > 0);
  }

  private current(): PhoneV3ReviewItem | undefined { return this.task; }

  private candidateId(): string {
    const item = this.current();
    return item ? phoneV3VoiceCandidates(item)[0]?.prototypeId ?? '' : '';
  }

  private context(): PurityContext {
    try { return JSON.parse(this.current()?.contextJson ?? '{}') as PurityContext; }
    catch (_) { return {}; }
  }

  private sourceTitle(): string {
    const session = this.viewModel.snapshot.sessions.find((value: PhoneV3SessionCard): boolean =>
      value.sessionId === this.task?.sessionId);
    return session ? phoneV3SessionTitle(session) : '来源日期暂不可用';
  }

  private resetAnswer(): void {
    const answer = this.context().purity_review;
    this.primaryId = answer?.primary_speaker_person_id ?? '';
    this.unknown = answer?.primary_speaker_unknown === true;
    this.unknownKind = answer?.unknown_kind ?? 'dont_know';
    this.primaryName = this.people.find((p: DeviceV3PersonChoice): boolean => p.person_id === this.primaryId)?.display_name ?? '';
    this.purity = answer?.purity ?? '';
    this.others = answer?.other_speaker_ids ?? [];
    this.flags = answer?.quality_flags ?? [];
  }

  private quickPeople(): Array<DeviceV3PersonChoice> {
    return this.people.slice(0, 5);
  }

  private choosePrimary(id: string, name: string): void {
    this.primaryId = id; this.primaryName = name; this.unknown = false;
    this.pickerOpen = false;
  }

  private chooseUnknown(kind: string = 'dont_know'): void {
    this.primaryId = ''; this.primaryName = ''; this.unknown = true;
    this.unknownKind = kind;
    this.purity = 'uncertain';
  }

  private toggleOther(id: string): void {
    this.others = this.others.includes(id) ? this.others.filter((v: string): boolean => v !== id) : this.others.concat([id]);
  }

  private toggleFlag(flag: string): void {
    this.flags = this.flags.includes(flag) ? this.flags.filter((v: string): boolean => v !== flag) : this.flags.concat([flag]);
  }

  private audioStatus(): string {
    if (this.task === undefined || this.candidate === undefined) { return ''; }
    if (this.viewModel.reviewPlaybackRange.startsWith('上下文播放中')) { return this.viewModel.reviewPlaybackRange; }
    if (this.viewModel.reviewPlaybackPrototype === this.candidate.prototypeId) { return '正在播放目标片段…'; }
    if (this.viewModel.reviewSampleWasPlayed(this.task.reviewId, this.candidate.prototypeId)) {
      return '目标片段已播完，可以提交';
    }
    return '请先播放并听完整段目标原音';
  }

  private submit(): void {
    const item = this.current();
    if (this.saving || item === undefined || (!this.primaryId && !this.unknown) || !this.purity) { return; }
    this.saving = true;
    const started = this.viewModel.submitPurityReview(item.reviewId, this.primaryId, this.unknown,
      this.purity, this.others, this.flags, false, (): void => {
        this.saving = false;
        this.lastReviewId = item.reviewId;
        this.feedback = '';
        this.viewModel.stopPlayback();
        this.loadQueue();
      }, (): void => { this.saving = false; this.feedback = '本机保存失败，请重试'; }, this.unknownKind);
    if (!started) { this.saving = false; this.feedback = '当前无法提交，请稍后重试'; }
  }

  private undo(): void {
    if (!this.lastReviewId || this.saving) { return; }
    const previous = this.lastReviewId;
    this.saving = true;
    const started = this.viewModel.submitPurityReview(previous, '', true, '', [], [], true, (): void => {
      this.saving = false;
      this.lastReviewId = ''; this.feedback = ''; this.loadQueue();
    }, (): void => { this.saving = false; this.feedback = '本机撤销失败，请重试'; });
    if (!started) { this.saving = false; this.feedback = '当前无法撤销，请稍后重试'; }
  }

  private skip(): void {
    if (!this.saving && this.tasks.length > 1) {
      this.viewModel.stopPlayback();
      this.tasks = this.tasks.slice(1).concat([this.tasks[0]]);
      this.showCurrent(); this.feedback = this.history ? '' : '已排到队尾，仍待审核';
    }
  }

  private reviewedCount(): number {
    return this.viewModel.snapshot.reviewItems.filter((v: PhoneV3ReviewItem): boolean =>
      v.kind === this.reviewKind && phoneV3ReviewIsHistory(v)).length;
  }

  private totalCount(): number {
    return this.viewModel.snapshot.reviewItems.filter((v: PhoneV3ReviewItem): boolean =>
      v.kind === this.reviewKind).length;
  }

  @Builder
  private picker() {
    PhoneV3PersonSelector({ people: this.people, selectedId: this.primaryId, allowCreate: false,
      onCancel: (): void => { this.pickerOpen = false; },
      onSelect: (id: string, name: string): void => {
        if (id) {
          if (this.pickingOther) { this.toggleOther(id); this.pickerOpen = false; }
          else { this.choosePrimary(id, name); }
        }
      } })
  }

  @Builder
  private choice(label: string, selected: boolean, action: () => void) {
    Button(selected ? `✓ ${label}` : label).buttonStyle(selected ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
      .backgroundColor(selected ? $r('app.color.brand_primary') : $r('app.color.surface_primary'))
      .fontColor(selected ? Color.White : $r('app.color.text_primary'))
      .fontSize(15).constraintSize({ minHeight: 46 }).margin(4).onClick(action)
  }

  build() {
    HdsNavDestination() {
      Column({ space: 14 }) {
        Text(this.history ? `已审核 ${this.tasks.length} 条` : `${this.reviewKind === 'blind_identity_review' ? 'Blind 人物验收' : '声纹纯度审核'} ${this.reviewedCount() + (this.task ? 1 : 0)} / ${this.totalCount()}`)
          .fontSize(16).width('100%')
        if (this.feedback) { Text(this.feedback).fontSize(15).fontColor($r('app.color.brand_primary')).width('100%') }
        if (this.lastReviewId) { Button('撤销上一条').buttonStyle(ButtonStyleMode.TEXTUAL).onClick((): void => this.undo()) }
        if (this.task === undefined || this.candidate === undefined) {
          Text(this.history ? '暂无已审核记录' : '当前没有待审核原音').fontSize(18).width('100%')
          Button('从电脑刷新').onClick((): void => this.viewModel.refreshVoiceReviews((): void => this.loadQueue()))
        } else {
          Scroll() {
            Column({ space: 16 }) {
              Text(`${this.sourceTitle()} · ${(this.context().duration_ms ?? this.candidate.totalMs) / 1000} 秒`)
                .fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              Text(this.audioStatus()).fontSize(15).fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.brand_primary')).width('100%')
              Button(this.viewModel.reviewPlaybackPrototype === this.candidate.prototypeId ? '停止播放' :
                  this.viewModel.reviewSampleWasPlayed(this.task.reviewId, this.candidate.prototypeId) ? '▶ 重播目标片段' : '▶ 播放目标片段')
                .width('100%').constraintSize({ minHeight: 52 }).enabled(this.candidate.hasAudio)
                .onClick((): void => {
                  if (this.viewModel.reviewPlaybackPrototype) {
                    this.viewModel.stopPlayback();
                  } else { this.viewModel.playReviewSample(this.task!.reviewId, this.candidate!.prototypeId); }
                })
              if (this.reviewKind !== 'blind_identity_review') {
              Button('听前后文').buttonStyle(ButtonStyleMode.NORMAL).width('100%')
                .onClick((): void => this.viewModel.playPurityContext(this.task!.reviewId, this.candidate!.prototypeId))
              Text('听前后文时，请只判断中间目标片段，不把上下文人物算进去。')
                .fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              }
              if (this.viewModel.reviewPlaybackRange) {
                Text(this.viewModel.reviewPlaybackRange).fontSize(13).fontColor($r('app.color.brand_primary'))
              }
              Text('这段主要是谁在说话？').fontSize(19).fontWeight(FontWeight.Bold).width('100%')
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.quickPeople(), (person: DeviceV3PersonChoice) => {
                  this.choice(person.display_name, this.primaryId === person.person_id,
                    (): void => this.choosePrimary(person.person_id, person.display_name))
                }, (person: DeviceV3PersonChoice): string => person.person_id)
                this.choice('其他人物', false, (): void => { this.pickingOther = false; this.pickerOpen = true; })
                if (this.reviewKind === 'blind_identity_review') {
                  this.choice('陌生人 / 未建档', this.unknown && this.unknownKind === 'stranger', (): void => this.chooseUnknown('stranger'))
                }
                this.choice('不知道是谁', this.unknown && this.unknownKind === 'dont_know', (): void => this.chooseUnknown('dont_know'))
                this.choice('听不清', this.unknown && this.unknownKind === 'inaudible', (): void => this.chooseUnknown('inaudible'))
              }.width('100%')
              if (this.primaryId || this.unknown) {
                Text(`已选主要人物：${this.primaryName || (this.unknownKind === 'stranger' ? '陌生人 / 未建档' : this.unknownKind === 'inaudible' ? '听不清' : '不知道是谁')}`).fontSize(14)
                  .fontColor($r('app.color.brand_primary')).width('100%')
              }
              if (this.primaryId || this.unknown) {
                Text('目标片段里还有别人的声音吗？').fontSize(19).fontWeight(FontWeight.Bold).width('100%')
                this.choice('只有这个人', this.purity === 'clean_single', (): void => { this.purity = 'clean_single'; this.others = []; })
                this.choice('有其他人 / 重叠', this.purity === 'mixed_overlap', (): void => { this.purity = 'mixed_overlap'; })
                this.choice('切片边界跨到别人', this.purity === 'boundary_cross', (): void => { this.purity = 'boundary_cross'; this.others = []; })
                this.choice('听不清 / 不确定', this.purity === 'uncertain', (): void => { this.purity = 'uncertain'; this.others = []; })
              }
              if (this.purity) {
                Text(`已选纯度：${this.purity === 'clean_single' ? '只有这个人' :
                  this.purity === 'mixed_overlap' ? '有其他人 / 重叠' :
                    this.purity === 'boundary_cross' ? '切片边界跨到别人' : '听不清 / 不确定'}`)
                  .fontSize(14).fontColor($r('app.color.brand_primary')).width('100%')
              }
              if (this.purity === 'mixed_overlap' && this.reviewKind !== 'blind_identity_review') {
                Text('还能听到谁？可跳过').fontSize(14).width('100%')
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.quickPeople(), (person: DeviceV3PersonChoice) => {
                    this.choice(person.display_name, this.others.includes(person.person_id), (): void => this.toggleOther(person.person_id))
                  }, (person: DeviceV3PersonChoice): string => person.person_id)
                  this.choice('其他人物', false, (): void => { this.pickingOther = true; this.pickerOpen = true; })
                  this.choice('不知道', this.others.includes('unknown'), (): void => this.toggleOther('unknown'))
                }.width('100%')
              }
              if (this.reviewKind !== 'blind_identity_review') {
              Button(this.qualityOpen ? '收起音质标记' : '⚑ 音质有问题（可选）').buttonStyle(ButtonStyleMode.TEXTUAL)
                .onClick((): void => { this.qualityOpen = !this.qualityOpen; })
              if (this.qualityOpen) {
                Flex({ wrap: FlexWrap.Wrap }) {
                  this.choice('太短', this.flags.includes('too_short'), (): void => this.toggleFlag('too_short'))
                  this.choice('噪声大', this.flags.includes('noisy'), (): void => this.toggleFlag('noisy'))
                  this.choice('声音太远', this.flags.includes('distant'), (): void => this.toggleFlag('distant'))
                  this.choice('严重失真', this.flags.includes('distorted'), (): void => this.toggleFlag('distorted'))
                  this.choice('音量过低', this.flags.includes('low_volume'), (): void => this.toggleFlag('low_volume'))
                  this.choice('其他', this.flags.includes('other'), (): void => this.toggleFlag('other'))
                }.width('100%')
              }
              }
              if (this.history && this.context().purity_review) {
                Text(`我的选择：${this.primaryName || '不知道是谁'} · ${this.purity}`).fontSize(14).width('100%')
              }
              if (this.viewModel.reviewSubmissionState(this.task.reviewId)) {
                Text(this.viewModel.reviewSubmissionMessage(this.task.reviewId)).fontSize(13).fontColor($r('app.color.brand_warning'))
                Button('核对电脑状态').onClick((): void => this.viewModel.refreshVoiceReviews((): void => this.loadQueue()))
              }
              Button(this.history ? '保存修改' :
                !this.viewModel.reviewSampleWasPlayed(this.task.reviewId, this.candidate.prototypeId) ?
                  '听完整段后可提交' : '提交并听下一条').width('100%').constraintSize({ minHeight: 52 })
                .enabled((!!this.primaryId || this.unknown) && !!this.purity &&
                  (this.history || this.viewModel.reviewSampleWasPlayed(this.task.reviewId, this.candidate.prototypeId)) &&
                  !this.saving && !this.viewModel.reviewSubmissionState(this.task.reviewId))
                .onClick((): void => this.submit())
              if (!this.history) { Button('稍后再看').buttonStyle(ButtonStyleMode.TEXTUAL)
                .enabled(!this.viewModel.reviewSubmissionState(this.task.reviewId)).onClick((): void => this.skip()) }
              if (this.history && this.tasks.length > 1) {
                Button('下一条已审核').buttonStyle(ButtonStyleMode.TEXTUAL).onClick((): void => this.skip())
              }
              if (this.viewModel.error) { Text(this.viewModel.error).fontSize(13).fontColor($r('app.color.brand_warning')) }
            }.width('100%').alignItems(HorizontalAlign.Start)
          }.layoutWeight(1).width('100%')
        }
      }.width('100%').height('100%').padding(18).alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.page_background'))
    }.titleBar({ enableComponentSafeArea: true, content: { title: { mainTitle: this.history ? '已审核' : this.reviewKind === 'blind_identity_review' ? 'Blind 人物验收' : '声纹纯度审核' } } })
      .titleMode(HdsNavDestinationTitleMode.MINI).backgroundColor($r('app.color.page_background'))
      .bindSheet($$this.pickerOpen, this.picker(), { height: SheetSize.LARGE, showClose: false,
        keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY })
  }
}
