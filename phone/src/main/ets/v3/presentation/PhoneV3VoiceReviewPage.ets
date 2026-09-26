import { PhoneV3PeopleLoader } from './PhoneV3PeopleLoader';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { DeviceV3PersonChoice } from '../../computer/ComputerTransferProtocol';
import { PhoneV3Utterance, PhoneV3SessionCard, PhoneV3ReviewItem } from '../domain/PhoneV3Models';
import { phoneV3VoiceMode } from '../domain/PhoneV3ReviewModels';
import { PhoneV3VoiceTask, PhoneV3VoiceQueue, PhoneV3VoiceEvidenceIndex, phoneV3VoiceTasks, phoneV3EvidencePending } from '../domain/PhoneV3VoiceReviewTask';
import { phoneV3AnnotationLabel } from '../domain/PhoneV3AnnotationState';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { PhoneV3PersonSelector } from './PhoneV3PersonSelector';
import { phoneV3AbsoluteTime, phoneV3SessionTitle } from './PhoneV3UiFormat';

@Component
export struct PhoneV3VoiceReviewPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  navStack: NavPathStack = new NavPathStack();
  reviewId: string = '';
  history: boolean = false;
  @Prop @Watch('refreshState') stateRevision: number = 0;
  onOpenAnnotation: (rows: Array<PhoneV3Utterance>, title: string) => void = (): void => {};
  onOpenSession: (session: PhoneV3SessionCard) => void = (): void => {};
  onConnect: () => void = (): void => {};
  private peopleLoader: PhoneV3PeopleLoader = new PhoneV3PeopleLoader();
  @State private unavailable: boolean = false;
  private queue: PhoneV3VoiceQueue = new PhoneV3VoiceQueue();
  private evidenceIndex: PhoneV3VoiceEvidenceIndex = new PhoneV3VoiceEvidenceIndex();
  private reviewSource: Array<PhoneV3ReviewItem> | undefined = undefined;
  private taskIndex: Map<string, PhoneV3VoiceTask> = new Map<string, PhoneV3VoiceTask>();
  @State private task: PhoneV3VoiceTask | undefined = undefined;
  @State private queuePosition: number = 0;
  @State private rows: Array<PhoneV3Utterance> = [];
  @State private selected: Array<PhoneV3Utterance> = [];
  @State private people: Array<DeviceV3PersonChoice> = [];
  @State private personId: string = '';
  @State private personName: string = '';
  @State private layer: string = '';
  @State private layerVisible: boolean = false;
  @State private stale: boolean = false;
  @State private pendingEvidence: boolean = false;
  @State private feedback: string = '';
  @State private reloadLocal: boolean = false;
  @State private correction: boolean = false;
  @State private expanded: boolean = false;
  @State private overflow: boolean = false;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.queue.open(phoneV3VoiceTasks(this.viewModel.snapshot.reviewItems, this.history), this.reviewId);
    this.showCurrent();
    this.refreshPeople();
  }
  private refreshPeople(): void {
    this.peopleLoader.refresh((accept): void => this.viewModel.loadPeople(accept),
      (values: Array<DeviceV3PersonChoice>): void => { this.people = values; });
  }
  private submissionState(): string {
    return this.task ? this.viewModel.reviewSubmissionState(this.task.item.reviewId, this.task.candidate.prototypeId) : '';
  }
  aboutToDisappear(): void { this.viewModel.stopPlayback(); }
  private refreshState(): void {
    this.evidenceIndex.update(this.viewModel.snapshot.sessions);
    const current = this.task;
    if (current === undefined) { return; }
    if (this.reviewSource !== this.viewModel.snapshot.reviewItems) {
      this.reviewSource = this.viewModel.snapshot.reviewItems; this.taskIndex.clear();
      for (let task of phoneV3VoiceTasks(this.reviewSource, this.history)) { this.taskIndex.set(task.key, task); }
    }
    const fresh = this.taskIndex.get(current.key);
    this.stale = fresh === undefined || fresh.fingerprint !== current.fingerprint || (!this.history && this.evidenceIndex.sourceChanged(current.candidate));
    this.rows = this.evidenceIndex.resolve(current.candidate);
    const previouslyPending = this.pendingEvidence;
    this.pendingEvidence = phoneV3EvidencePending(this.rows);
    if (!previouslyPending && this.pendingEvidence && (this.viewModel.reviewPlaybackPrototype ||
      this.viewModel.reviewSampleWasPlayed(current.item.reviewId, current.candidate.prototypeId))) { this.viewModel.stopPlayback(); }
  }
  private showCurrent(): void {
    this.unavailable = this.queue.unavailable;
    this.task = this.queue.current(); this.queuePosition = this.queue.index;
    this.selected = []; this.personId = ''; this.personName = ''; this.correction = false; this.expanded = false;
    this.reloadLocal = false; this.refreshState(); this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
  }
  private dirty(): boolean { return this.selected.length > 0 || this.personName.length > 0; }
  private navigate(action: () => void): void {
    if ((this.viewModel.busy && this.viewModel.annotationPlaybackState() !== '正在加载') || this.viewModel.annotationSaving) { return; }
    if (this.dirty() && !this.reloadLocal) {
      AlertDialog.show({ title: '放弃未保存的修改？', message: '所选原句与人物尚未保存。',
        primaryButton: { value: '继续编辑', action: (): void => {} },
        secondaryButton: { value: '放弃修改', action: (): void => { this.viewModel.stopPlayback(); action(); } } });
    } else { this.viewModel.stopPlayback(); action(); }
  }
  private next(skip: boolean = false): void { this.queue.next(skip); this.showCurrent(); }
  private discovery(): boolean { return this.task !== undefined && phoneV3VoiceMode(this.task.item) === 'speaker_discovery'; }
  private editing(): boolean { return this.discovery() || this.correction; }
  private openLayer(value: string): void { if (value === 'person') { this.refreshPeople(); } this.layer = value; this.layerVisible = true; }
  private validSelection(): boolean {
    return this.selected.length > 0 && this.selected.every((row: PhoneV3Utterance): boolean =>
      this.rows.some((fresh: PhoneV3Utterance): boolean => fresh.utteranceId === row.utteranceId && fresh.revision === row.revision && fresh.status === 'active'));
  }
  private savePerson(): void {
    if (!this.validSelection() || !this.personName || this.reloadLocal || this.viewModel.annotationSaving) { return; }
    this.viewModel.saveAnnotation(this.selected, this.personId, this.personId ? '' : this.personName, true, '', (read: boolean): void => {
      this.refreshPeople();
      this.feedback = '所选片段已标注，待同步；未采纳声纹，发现任务仍由电脑判定';
      this.reloadLocal = !read;
      if (read) { this.selected = []; this.personId = ''; this.personName = ''; this.refreshState(); }
    });
  }
  private decide(action: string): void {
    const current = this.task;
    if (current === undefined || this.stale || (!this.history && this.pendingEvidence)) { return; }
    this.feedback = '';
    // Do not stop playback here: the VM checks the complete-audition credential first.
    this.viewModel.resolveReview(current.item.reviewId, action, current.candidate.prototypeId, '', (): void => {
      this.feedback = action === 'uncertain' ? '上一条已提交不确定；电脑仍可能保留此候选' : action === 'retract' ? '上一条样本授权已撤回' : '上一条审核结果已提交';
      this.viewModel.stopPlayback(); this.next();
    });
  }
  private refreshRemote(): void {
    const committed = this.submissionState() === 'committed';
    this.viewModel.refreshVoiceReviews((): void => {
      if (committed && !this.submissionState()) { this.feedback = '上一条结果已提交，状态已更新'; this.next(); return; }
      if (this.unavailable) {
        this.queue.open(phoneV3VoiceTasks(this.viewModel.snapshot.reviewItems, this.history), this.reviewId);
        this.showCurrent();
      }
      this.refreshState();
      this.feedback = this.stale ? '当前对象已变化或不在此队列，请重新核对或继续下一条' : '已读取电脑当前状态';
    });
  }
  private acceptFresh(): void {
    this.navigate((): void => {
      const current = this.task;
      const fresh = phoneV3VoiceTasks(this.viewModel.snapshot.reviewItems, this.history).find((t: PhoneV3VoiceTask): boolean => t.key === current?.key);
      if (fresh !== undefined) { this.queue.tasks[this.queue.index] = fresh; this.showCurrent(); }
      else { this.next(); }
    });
  }
  private sourceTitle(): string {
    const session = this.viewModel.snapshot.sessions.find((s: PhoneV3SessionCard): boolean => s.sessionId === this.task?.candidate.sessionId);
    return session ? phoneV3SessionTitle(session) : '录音时间暂不可用';
  }
  @Builder
  private quiet(label: string, action: () => void) {
    Button(label).buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(14).fontColor($r('app.color.text_secondary')).onClick(action)
  }
  @Builder
  private layerContent() {
    if (this.layer === 'person') {
      PhoneV3PersonSelector({ people: this.people, selectedId: this.personId,
        onCancel: (): void => { this.layerVisible = false; }, onSelect: (id: string, name: string): void => {
          this.personId = id; this.personName = name; this.layerVisible = false;
        } })
    } else {
      Column({ space: 16 }) {
        Row() {
          Text(this.layer === 'evidence' ? '本样本依据' : '声音审核详情').fontSize(20).layoutWeight(1)
          this.quiet('关闭', (): void => { this.layerVisible = false; })
        }.width('100%')
        if (this.layer === 'evidence') {
          Text('样本裁剪窗口与完整原句是不同范围。勾选仅表示你要确认这些完整原句；未选内容不修改。')
            .fontSize(13).fontColor($r('app.color.text_secondary'))
          List() {
            ForEach(this.rows, (row: PhoneV3Utterance) => {
              ListItem() {
                Column({ space: 8 }) {
                  Row() {
                    if (this.editing()) {
                      Checkbox().select(this.selected.some((r: PhoneV3Utterance): boolean => r.utteranceId === row.utteranceId))
                        .enabled(!this.discovery() || row.annotationFacts.person === '' || row.annotationFacts.person === 'review')
                        .onChange((checked: boolean): void => {
                          this.selected = this.selected.filter((r: PhoneV3Utterance): boolean => r.utteranceId !== row.utteranceId);
                          if (checked) { this.selected = this.selected.concat([row]); }
                        })
                    }
                    Text(`${phoneV3AbsoluteTime(row.startAt)} · 整句 ${row.startMs / 1000}–${row.endMs / 1000} 秒`).fontSize(12).layoutWeight(1)
                  }.width('100%')
                  Text(row.text).fontSize(16).width('100%')
                  Text(phoneV3AnnotationLabel(row)).fontSize(12).fontColor($r('app.color.text_secondary'))
                  Row() {
                    this.quiet('试听完整原句', (): void => this.viewModel.playUtterance(row))
                    this.quiet('逐句处理', (): void => { this.layerVisible = false; this.onOpenAnnotation([row], '审核依据'); })
                  }
                }.padding({ top: 12, bottom: 12 }).width('100%').alignItems(HorizontalAlign.Start)
              }
            }, (row: PhoneV3Utterance): string => `${row.utteranceId}:${row.revision}:${row.annotationFacts.person}`)
          }.layoutWeight(1).width('100%')
          if (this.editing()) { Button(`完成选择 · ${this.selected.length} 句`).width('100%').constraintSize({ minHeight: 48 }).onClick((): void => { this.layerVisible = false; }) }
        } else {
          Scroll() {
            Column({ space: 16 }) {
              Text(this.task?.candidate.ranges ?? '').fontSize(14)
              Text(`模型匹配分：${this.task?.candidate.bestScore ?? '未知'}；质量分：${this.task?.candidate.qualityScore ?? '未知'}。这些是模型分值，不是正确率。`).fontSize(13)
              if (!this.history) {
                this.quiet('纠正所选原句的人物', (): void => { this.correction = true; this.layer = 'evidence'; })
                this.quiet('仅跳过本轮样本', (): void => { this.layerVisible = false; this.navigate((): void => this.next(true)); })
              }
              this.quiet('查看原录音（上下文）', (): void => {
                const session = this.viewModel.snapshot.sessions.find((s: PhoneV3SessionCard): boolean => s.sessionId === this.task?.candidate.sessionId);
                if (session) { this.layerVisible = false; this.onOpenSession(session); }
              })
              Text('上下文不参与本次授权，也不会自动成为标注目标。').fontSize(13)
              this.quiet('核对电脑最新状态', (): void => { this.layerVisible = false; this.refreshRemote(); })
              this.quiet('电脑连接设置', (): void => { this.layerVisible = false; this.onConnect(); })
            }.width('100%').alignItems(HorizontalAlign.Start)
          }.layoutWeight(1).align(Alignment.TopStart)
        }
      }.padding(16).width('100%').height('100%').backgroundColor($r('app.color.page_background'))
    }
  }
  build() {
    HdsNavDestination() {
      Column({ space: 16 }) {
        if (this.task !== undefined) {
          Text(`${this.history ? '已采纳样本' : '当前队列'} · 样本 ${this.queuePosition + 1} / ${this.queue.tasks.length}`)
            .fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
          Scroll(this.scroller) {
            Column({ space: 20 }) {
              Text(this.history ? `「${this.task.candidate.personName}」的样本授权` : this.editing() ? '确认所选原句中的人物' : `这段声音都是「${this.task.candidate.personName}」吗？`)
                .fontSize(21).fontWeight(FontWeight.Bold).width('100%')
              Text(this.history ? '已采纳。重听为可选操作，可单独撤回此授权。' : this.editing() ? '只修改明确勾选的完整原句，不采纳声纹、不确认整组声音。' : '确认后采纳此声纹样本，用于人物匹配；可能触发历史重匹配。')
                .fontSize(14).fontColor($r('app.color.text_secondary')).width('100%')
              Text(`${this.sourceTitle()} · ${this.task.candidate.windowCount} 段窗口 · 共 ${this.task.candidate.totalMs / 1000} 秒`)
                .fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              Text(this.rows.length > 0 ? this.rows.slice(0, 2).map((r: PhoneV3Utterance): string => r.text).join(' / ') : '暂无可靠原句映射，可按完整音频核对样本。')
                .fontSize(17).lineHeight('25fp').maxLines(this.expanded ? 10000 : 4).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                .onAreaChange((_old: Area, area: Area): void => {
                  const text = this.rows.slice(0, 2).map((r: PhoneV3Utterance): string => r.text).join(' / ');
                  const size = this.getUIContext().getMeasureUtils().measureTextSize({ textContent: text, fontSize: '17fp', lineHeight: '25fp', constraintWidth: this.getUIContext().vp2px(Number(area.width)) });
                  this.overflow = Number(size.height) > this.getUIContext().fp2px(25) * 4 + 1;
                })
              if (this.overflow) { Button(this.expanded ? '收起摘要' : '展开摘要').buttonStyle(ButtonStyleMode.TEXTUAL).onClick((): void => { this.expanded = !this.expanded; }) }
              Button(this.viewModel.annotationPlaybackState() === '正在加载' ? '取消加载' : this.viewModel.reviewPlaybackPrototype === this.task.candidate.prototypeId ? '停止试听' : this.viewModel.reviewSampleWasPlayed(this.task.item.reviewId, this.task.candidate.prototypeId) ? '重新播放完整样本' : '▶ 播放完整样本')
                .buttonStyle(ButtonStyleMode.NORMAL).width('100%').constraintSize({ minHeight: 48 })
                .enabled(this.task.candidate.hasAudio && !this.stale && (!this.viewModel.busy || this.viewModel.annotationPlaybackState() === '正在加载'))
                .onClick((): void => {
                  if (this.viewModel.reviewPlaybackPrototype || this.viewModel.annotationPlaybackState() === '正在加载') { this.viewModel.stopPlayback(); }
                  else if (this.task) { this.viewModel.playReviewSample(this.task.item.reviewId, this.task.candidate.prototypeId); }
                })
              Text(this.viewModel.reviewSampleWasPlayed(this.task.item.reviewId, this.task.candidate.prototypeId) ? '完整样本已播放完毕' :
                this.viewModel.reviewPlaybackRange || (this.task.candidate.hasAudio ? this.history ? '重听为可选操作，不影响撤回授权' : this.editing() ? '可试听核对；人物保存不要求完整试听' : '确认和拒绝前需完整听完当前样本' : this.task.candidate.unavailableReason))
                .fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              Button(`查看 ${this.task.candidate.windowCount} 段窗口的依据 · ${this.rows.length} 句已映射 ›`).buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(14).fontColor($r('app.color.text_secondary')).onClick((): void => this.openLayer('evidence'))
              if (this.editing()) {
                Text(`已选 ${this.selected.length} 句；默认不选择任何原句`).fontSize(13).width('100%')
                Button(`说话人　${this.personName || '尚未选择'}　›`).buttonStyle(ButtonStyleMode.NORMAL).width('100%')
                  .enabled(!this.reloadLocal && !this.viewModel.annotationSaving).onClick((): void => this.openLayer('person'))
              }
              if (this.pendingEvidence && !this.history) { Text('依据已修改，等待同步/样本更新；不能采纳旧样本').fontSize(13).fontColor($r('app.color.brand_warning')) }
              if (this.stale) {
                Text('当前样本或来源已变化，保留原阅读位置，请重新核对。').fontSize(13).fontColor($r('app.color.brand_warning'))
                this.quiet('载入当前版本 / 继续下一条', (): void => this.acceptFresh())
              }
              if (this.feedback) { Text(this.feedback).fontSize(13).fontColor($r('app.color.brand_success')).width('100%') }
              if (this.submissionState()) {
                Text(this.viewModel.reviewSubmissionMessage(this.task.item.reviewId, this.task.candidate.prototypeId)).fontSize(13).fontColor($r('app.color.brand_warning'))
                Button('核对此项审核结果').buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.viewModel.busy).onClick((): void => this.refreshRemote())
              }
              if (this.viewModel.error) {
                Text(this.viewModel.error).fontSize(13).fontColor($r('app.color.brand_warning')).width('100%')
                this.quiet('核对状态 / 重试读取', (): void => this.refreshRemote())
                this.quiet('电脑连接设置', (): void => { this.layerVisible = false; this.onConnect(); })
              }
              if (this.reloadLocal) { Button('重试读取本地结果').onClick((): void => this.viewModel.reloadAnnotationResult((): void => {
                this.reloadLocal = false; this.selected = []; this.personName = ''; this.refreshState();
              })) }
            }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 16 })
          }.layoutWeight(1).width('100%').align(Alignment.TopStart)
          if (this.history) {
            Button('撤回此样本授权').buttonStyle(ButtonStyleMode.NORMAL).width('100%').constraintSize({ minHeight: 48 })
              .enabled(!this.viewModel.busy && !this.stale && !this.submissionState())
              .onClick((): void => AlertDialog.show({ title: '撤回此样本授权？', message: '仅停止此样本授权，不删除录音、人物人工事实或其他样本。电脑会重新匹配。',
                primaryButton: { value: '取消', action: (): void => {} }, secondaryButton: { value: '撤回', action: (): void => this.decide('retract') } }))
            this.quiet('下一个授权', (): void => this.navigate((): void => this.next()))
          } else if (this.editing()) {
            Button(`确认所选 ${this.selected.length} 句的人物`).width('100%').constraintSize({ minHeight: 48 })
              .enabled(this.validSelection() && this.personName.length > 0 && !this.reloadLocal && !this.viewModel.annotationSaving && !this.stale)
              .onClick((): void => this.savePerson())
            this.quiet('下一条样本（不解决整个任务）', (): void => this.navigate((): void => this.next(true)))
          } else {
            Row({ space: 12 }) {
              Button('不是他').buttonStyle(ButtonStyleMode.NORMAL).layoutWeight(1).constraintSize({ minHeight: 48 })
                .enabled(this.viewModel.reviewSampleWasPlayed(this.task.item.reviewId, this.task.candidate.prototypeId) && !this.stale && !this.pendingEvidence && !this.viewModel.busy && !this.submissionState())
                .onClick((): void => this.decide('reject'))
              Button('是他，采纳样本').layoutWeight(2).constraintSize({ minHeight: 48 })
                .enabled(this.viewModel.reviewSampleWasPlayed(this.task.item.reviewId, this.task.candidate.prototypeId) && !this.stale && !this.pendingEvidence && !this.viewModel.busy && !this.submissionState())
                .onClick((): void => this.decide('confirm'))
            }.width('100%')
            Button(this.task.candidate.reviewStatus === 'uncertain' ? '此前已提交不确定' : '暂不确定').buttonStyle(ButtonStyleMode.TEXTUAL).fontColor($r('app.color.text_secondary'))
              .enabled(!this.stale && !this.pendingEvidence && !this.viewModel.busy && !this.submissionState() && this.task.candidate.reviewStatus !== 'uncertain')
              .onClick((): void => this.decide('uncertain'))
          }
        } else if (this.unavailable) {
          Text('指定审核项已失效或暂无可用样本').fontSize(21).width('100%')
          Text('未打开其他任务，请刷新此项或返回列表。').fontSize(14)
          if (this.viewModel.error) { Text(this.viewModel.error).fontSize(13) }
          Button('刷新此项').enabled(!this.viewModel.busy).onClick((): void => this.refreshRemote())
          Button('返回审核列表').buttonStyle(ButtonStyleMode.TEXTUAL).onClick((): void => { this.navStack.pop(); })
          Blank()
        } else {
          Text(this.history ? '已浏览完当前缓存的样本授权' : '本轮可用样本已处理到末尾').fontSize(21).width('100%')
          Text(this.feedback || '此处不是全库完成状态，连接电脑可读取更多任务。').fontSize(14).width('100%')
          if (this.queue.skipped.length > 0) {
            Button(`回看 ${this.queue.skipped.length} 条本轮跳过样本`).onClick((): void => {
              this.queue.revisit(this.viewModel.snapshot.reviewItems, this.history); this.showCurrent();
            })
          }
          Button('返回审核列表').onClick((): void => { this.navStack.pop(); })
          Blank()
        }
      }.padding({ left: 16, right: 16, top: 8, bottom: 16 }).width('100%').height('100%').alignItems(HorizontalAlign.Start)
    }.titleBar({ enableComponentSafeArea: true, content: { title: { mainTitle: this.history ? '已采纳样本' : '核对声音' },
      menu: { maxCount: 1, value: [{ content: { icon: $r('sys.media.ohos_ic_public_more'), label: '更多', action: (): void => this.openLayer('more') } }] } } })
      .titleMode(HdsNavDestinationTitleMode.MINI).backgroundColor($r('app.color.page_background'))
      .onBackPressed((): boolean => { this.navigate((): void => { this.navStack.pop(); }); return true; })
      .onHidden((): void => this.viewModel.stopPlayback()).onShown((): void => this.refreshState())
      .bindSheet($$this.layerVisible, this.layerContent(), { height: SheetSize.LARGE, showClose: false, keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY })
  }
}
