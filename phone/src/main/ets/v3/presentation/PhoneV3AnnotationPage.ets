import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { PhoneV3PersonSelector } from './PhoneV3PersonSelector';
import { PhoneV3AnnotationConflictPanel } from './PhoneV3AnnotationConflictPanel';
import { PhoneV3LocalAnnotation } from '../domain/PhoneV3LocalAnnotation';
import { PHONE_V3_SOUND_KINDS, phoneV3SoundKindLabel } from '../domain/PhoneV3SoundKind';
import { PhoneV3AnnotationEditor } from '../domain/PhoneV3AnnotationEditor';
import { phoneV3AnnotationState, phoneV3AnnotationLabel, phoneV3AnnotationKey } from '../domain/PhoneV3AnnotationState';
import { DeviceV3PersonChoice, DeviceV3AnnotationStatus } from '../../computer/ComputerTransferProtocol';
import { phoneV3SampleStatus } from '../domain/PhoneV3SampleStatus';
import { PhoneV3Utterance, PhoneV3Conflict } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { phoneV3AbsoluteTime } from './PhoneV3UiFormat';

@Component
export struct PhoneV3AnnotationPage {
  viewModel: PhoneV3ViewModel = new PhoneV3ViewModel();
  navStack: NavPathStack = new NavPathStack();
  @Prop scopeTitle: string = '当前范围';
  @Prop @Watch('onStateChanged') stateRevision: number = 0;
  @State editor: PhoneV3AnnotationEditor = new PhoneV3AnnotationEditor();
  @State private busy: boolean = false;
  @State private playback: string = '';
  @State private error: string = '';
  @State private feedback: string = '';
  @State private reloadNeeded: boolean = false;
  @State private people: Array<DeviceV3PersonChoice> = [];
  @State private personId: string = '';
  @State private personLabel: string = '';
  @State private personChanged: boolean = false;
  @State private creating: boolean = false;
  @State private name: string = '';
  @State private soundKind: string = '';
  @State private expanded: boolean = false;
  @State private withContext: boolean = false;
  @State private sampleStatuses: Array<DeviceV3AnnotationStatus> = [];
  private lastSavedIds: Array<string> = [];
  private opened: boolean = false;
  private contentScroller: Scroller = new Scroller();
  private conflictSource: Array<PhoneV3Conflict> | undefined = undefined;
  private conflictsById: Map<string, Array<PhoneV3Conflict>> = new Map<string, Array<PhoneV3Conflict>>();

  aboutToAppear(): void { this.open(); }
  aboutToDisappear(): void { this.viewModel.stopPlayback(); }

  private open(): void {
    this.editor.update(this.viewModel.snapshot.sessions);
    this.opened = true;
    this.feedback = ''; this.reloadNeeded = false;
    this.resetForm();
    this.viewModel.loadPeople((values: Array<DeviceV3PersonChoice>): void => { this.people = values; });
    this.onStateChanged();
  }
  private onStateChanged(): void {
    if (this.opened) { this.editor.update(this.viewModel.snapshot.sessions); }
    if (this.conflictSource !== this.viewModel.snapshot.conflicts) {
      this.conflictSource = this.viewModel.snapshot.conflicts;
      this.conflictsById.clear();
      for (let conflict of this.conflictSource) {
        if (conflict.kind !== 'speaker.assign' && conflict.kind !== 'segment.classify') { continue; }
        try {
          const payload = JSON.parse(conflict.payloadJson) as PhoneV3LocalAnnotation;
          for (let selection of payload.selections ?? []) {
            this.conflictsById.set(selection.utterance_id, (this.conflictsById.get(selection.utterance_id) ?? []).concat([conflict]));
          }
        } catch (error) { continue; }
      }
    }
    this.busy = this.viewModel.annotationSaving;
    this.error = this.viewModel.error;
    this.playback = this.viewModel.annotationPlaybackState();
  }
  private resetForm(): void {
    const row = this.editor.current;
    this.resultMode = !this.editor.batch && row !== undefined && phoneV3AnnotationState(row).done;
    this.personId = this.editor.batch ? '' : row?.annotationPersonId ?? '';
    this.personLabel = this.personId ? row?.speakerLabel ?? '已选人物' : '';
    this.overflow = false;
    this.name = ''; this.personChanged = false; this.creating = false;
    this.soundKind = '';
    this.expanded = false;
  }
  private dirty(): boolean { return this.personChanged || this.soundKind.length > 0 || this.name.length > 0; }
  private navigate(action: () => void): void {
    if (this.busy) { return; }
    if (this.dirty()) {
      AlertDialog.show({ title: '放弃未保存的修改？', message: '这次输入尚未保存。',
        primaryButton: { value: '继续编辑', action: (): void => {} },
        secondaryButton: { value: '放弃修改', action: (): void => { this.viewModel.stopPlayback(); action(); this.resetForm(); this.contentScroller.scrollTo({ xOffset: 0, yOffset: 0 }); } } });
    } else { this.viewModel.stopPlayback(); action(); this.resetForm(); this.contentScroller.scrollTo({ xOffset: 0, yOffset: 0 }); }
  }
  private close(): void {
    if (this.reloadNeeded && !this.busy) {
      this.viewModel.stopPlayback(); this.opened = false; this.navStack.pop(); return;
    }
    this.navigate((): void => { this.opened = false; this.navStack.pop(); });
  }
  private focused(): Array<PhoneV3Utterance> {
    const current = this.editor.current;
    return current ? [this.editor.rows.find((row: PhoneV3Utterance): boolean => row.utteranceId === current.utteranceId) ?? current] : [];
  }
  private disabledReason(): string {
    if (this.reloadNeeded) { return '已保存，请先重试读取结果'; }
    if (this.editor.changed) { return '片段已变化，请点击重新核对'; }
    const count = this.editor.batch ? this.editor.selectedCount : this.editor.current ? 1 : 0;
    if (count === 0) { return '请选择要标注的片段'; }
    if (this.editor.targets().some((row: PhoneV3Utterance): boolean => row.status !== 'active')) { return '片段来源已失效，请重新选择'; }
    if (count > 2000) { return '每次最多保存 2000 条，请减少选择'; }
    if (this.personChanged && !this.creating && !this.personId) { return '请选择人物'; }
    if (this.creating && this.name.trim().length === 0) { return '请输入新人物姓名'; }
    if (!this.personChanged && this.soundKind.length === 0) { return '请选择人物或修改声音类型'; }
    return '';
  }
  private save(): void {
    if (this.busy || this.disabledReason()) { return; }
    const targets = this.editor.targets().slice();
    const ids = targets.map((row: PhoneV3Utterance): string => row.utteranceId);
    this.viewModel.saveAnnotation(targets, this.creating ? '' : this.personId, this.name,
      this.personChanged, this.soundKind, (refreshed: boolean): void => {
        this.lastSavedIds = ids;
        this.feedback = '已保存 · 待同步';
        this.reloadNeeded = !refreshed;
        if (refreshed) { this.afterRead(); }
      });
  }
  private afterRead(): void {
    this.editor.update(this.viewModel.snapshot.sessions);
    this.editor.saved(this.lastSavedIds);
    this.viewModel.stopPlayback();
    this.reloadNeeded = false;
    this.resetForm();
    this.contentScroller.scrollTo({ xOffset: 0, yOffset: 0 });
    this.viewModel.loadPeople((values: Array<DeviceV3PersonChoice>): void => { this.people = values; });
  }
  private querySamples(retry: boolean = false): void {
    const rows = this.editor.batch ? this.editor.pageRows : this.focused();
    this.viewModel.loadSampleStatus(rows.map((row: PhoneV3Utterance): string => row.utteranceId), retry,
      (items: Array<DeviceV3AnnotationStatus>): void => { this.sampleStatuses = items; });
  }
  @State private resultMode: boolean = false;
  @State private selector: string = '';
  @State private selectorVisible: boolean = false;
  @State private overflow: boolean = false;

  private openSelector(kind: string): void {
    if (kind !== 'details' && (this.busy || this.reloadNeeded)) { return; }
    this.selector = kind;
    this.selectorVisible = true;
  }
  private choosePerson(id: string, label: string): void {
    this.personId = id; this.personLabel = label; this.personChanged = true;
    this.creating = id.length === 0; this.name = this.creating ? label : '';
    this.selectorVisible = false;
  }
  private soundLabel(): string {
    if (this.editor.batch && !this.soundKind) { return '不修改'; }
    return phoneV3SoundKindLabel(this.soundKind || this.editor.current?.soundKind || 'speech') +
      (!this.soundKind && !this.editor.current?.annotationFacts.sound ? '（未确认）' : '');
  }
  private shortSync(row: PhoneV3Utterance): string {
    const value = phoneV3AnnotationState(row).sync;
    return value.includes('失败') ? '同步失败' : value.includes('待同步') ? '待同步' :
      value.includes('更新中') ? '结果更新中' : value;
  }
  @Builder
  private quiet(label: string, action: () => void) {
    Button(label).buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(14)
      .fontColor($r('app.color.text_secondary')).onClick(action)
  }
  @Builder
  private setting(label: string, value: string, action: () => void) {
    AnnotationSettingRow({ label: label, value: value, onSelect: action })
  }
  @Builder
  private choice(label: string, id: string, person: boolean, action: () => void) {
    Row({ space: 12 }) {
      Text(label).fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
      if (person ? this.personId === id : id === (this.soundKind || (!this.editor.batch ? this.editor.current?.soundKind : ''))) {
        SymbolGlyph($r('sys.symbol.checkmark')).fontSize(20).fontColor([$r('app.color.brand_primary')])
      }
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .onClick(action).accessibilityGroup(true)
      .accessibilityText(`${label}${(person ? this.personId === id : id === (this.soundKind || (!this.editor.batch ? this.editor.current?.soundKind : ''))) ? '，已选择' : ''}`)
  }
  @Builder
  private selectorContent() {
    if (this.selector === 'person') {
      PhoneV3PersonSelector({ people: this.people, selectedId: this.personId,
        onSelect: (id: string, label: string): void => this.choosePerson(id, label),
        onCancel: (): void => { this.selectorVisible = false; } })
    } else {
    Column({ space: 16 }) {
      Row() {
        Text(this.selector === 'sound' ? '声音类型' : '标注详情')
          .fontSize(20).fontWeight(FontWeight.Bold).layoutWeight(1).fontColor($r('app.color.text_primary'))
        this.quiet('取消', (): void => {
          this.selectorVisible = false;
        })
      }.width('100%')
      if (this.selector === 'sound') {
        List() {
          ForEach(PHONE_V3_SOUND_KINDS, (kind: string) => {
            ListItem() { this.choice(phoneV3SoundKindLabel(kind), kind, false,
              (): void => { this.soundKind = kind; this.selectorVisible = false; }) }
          }, (kind: string): string => kind)
        }.layoutWeight(1).width('100%')
      } else {
        Scroll() {
          Column({ space: 16 }) {
            ForEach(this.focused(), (row: PhoneV3Utterance) => {
              Text(phoneV3AnnotationLabel(row)).fontSize(15)
              ForEach(this.conflictsById.get(row.utteranceId) ?? [], (conflict: PhoneV3Conflict) => {
                PhoneV3AnnotationConflictPanel({ viewModel: this.viewModel, conflict: conflict, stateRevision: this.stateRevision })
              }, (conflict: PhoneV3Conflict): string => conflict.operationId)
            }, (row: PhoneV3Utterance): string => phoneV3AnnotationKey(row, row.utteranceId, row.revision))
            this.setting('样本处理详情', '查询', (): void => this.querySamples())
            this.quiet('重试样本处理', (): void => this.querySamples(true))
            ForEach(this.sampleStatuses, (status: DeviceV3AnnotationStatus) => { Text(phoneV3SampleStatus(status)).fontSize(13) },
              (status: DeviceV3AnnotationStatus): string => `${status.utterance_id}:${status.revision}`)
            this.quiet('刷新标注数据', (): void => this.viewModel.refreshAnnotationData())
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.layoutWeight(1).width('100%')
      }
    }.padding(16).width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.page_background'))
    }
  }
  @Builder
  private sentence(row: PhoneV3Utterance) {
    Column({ space: 16 }) {
      Row() {
        Text(phoneV3AbsoluteTime(row.startAt)).layoutWeight(1).fontSize(13).fontColor($r('app.color.text_secondary'))
        Text(`${((row.endMs - row.startMs) / 1000).toFixed(1)} 秒`).fontSize(13).fontColor($r('app.color.text_secondary'))
      }.width('100%')
      Text(row.text || '（暂无转写）').fontSize(17).lineHeight('25fp').width('100%')
        .fontColor($r('app.color.text_primary')).maxLines(this.expanded ? 10000 : 4)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .onAreaChange((_old: Area, area: Area): void => {
          const size = this.getUIContext().getMeasureUtils().measureTextSize({ textContent: row.text, fontSize: '17fp', lineHeight: '25fp',
            constraintWidth: this.getUIContext().vp2px(Number(area.width)) });
          this.overflow = Number(size.height) > this.getUIContext().fp2px(25) * 4 + 1;
        })
      if (this.overflow) { Button(this.expanded ? '收起正文' : '展开全文').buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(14).onClick((): void => { this.expanded = !this.expanded; }) }
      Row({ space: 12 }) {
        Button({ type: ButtonType.Circle }) {
          if (this.playback) { Rect().width(18).height(18).fill($r('app.color.text_primary')) }
          else { SymbolGlyph($r('sys.symbol.play_fill')).fontSize(22).fontColor([$r('app.color.text_primary')]) }
        }.width(48).height(48).backgroundColor($r('app.color.surface_secondary'))
          .accessibilityText(this.playback ? '停止播放' : '播放片段')
          .onClick((): void => { if (this.playback) { this.viewModel.stopPlayback(); } else { this.viewModel.playUtterance(row, this.withContext); } })
        Text(this.playback || '播放片段').fontSize(14).layoutWeight(1).fontColor($r('app.color.text_secondary'))
        Checkbox().select(this.withContext).width(20).height(20)
          .onChange((value: boolean): void => { this.withContext = value; })
        Text('前后文').fontSize(13).fontColor($r('app.color.text_secondary'))
      }.width('100%')
      if (phoneV3AnnotationState(row).review) {
        Text(`需复核 · ${phoneV3AnnotationState(row).reason}`).fontSize(13).fontColor($r('app.color.brand_warning')).width('100%')
        this.quiet('查看并处理', (): void => this.openSelector('details'))
      }
      if (this.resultMode) {
        Text(phoneV3AnnotationState(row).result).fontSize(16).fontColor($r('app.color.text_primary')).width('100%')
        Text(this.shortSync(row)).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  private content() {
    Column({ space: 16 }) {
      Text(`${this.scopeTitle} · ${this.editor.batch ? '已选 ' + this.editor.selectedCount + ' 条' : '还剩 ' + this.editor.pending + ' 条'}`)
        .fontSize(13).fontColor($r('app.color.text_secondary')).width('100%').maxLines(2)
      Scroll(this.contentScroller) {
        Column({ space: 20 }) {
          if (this.editor.batch) { Text(this.editor.selectedCount > 0 ? `为 ${this.editor.selectedCount} 条片段设置标注` : '所选片段已保存').fontSize(18).width('100%') }
          else { ForEach(this.focused(), (row: PhoneV3Utterance) => { this.sentence(row) },
            (row: PhoneV3Utterance): string => phoneV3AnnotationKey(row, row.utteranceId, row.revision)) }
          if ((this.editor.current || (this.editor.batch && this.editor.selectedCount > 0)) && !this.resultMode) {
            Column() {
              AnnotationSettingRow({ label: '说话人', value: this.personLabel || (this.editor.batch ? '不修改' : '尚未选择'), onSelect: (): void => this.openSelector('person') })
              Divider().color($r('app.color.surface_secondary'))
              AnnotationSettingRow({ label: '声音类型', value: this.soundKind ? phoneV3SoundKindLabel(this.soundKind) : this.soundLabel(), onSelect: (): void => this.openSelector('sound') })
            }.borderRadius(16).clip(true)
            if (!this.personId && !this.personChanged && this.editor.current?.speakerLabel && !this.editor.batch) {
              Text(`系统建议：${this.editor.current?.speakerLabel}`).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            }
          }
          if (!this.editor.current && !this.editor.batch) {
            Text(this.editor.pending > 0 ? `已到末尾，还有 ${this.editor.pending} 条未标注` : '本范围已全部标注')
              .fontSize(20).width('100%').padding({ top: 24 })
            if (this.editor.pending > 0) { this.quiet('回去处理', (): void => { this.editor.restartPending(); this.resetForm(); }) }
          }
          if (this.feedback) { Text(this.feedback).fontSize(13).fontColor($r('app.color.brand_success')).width('100%') }
          if (this.reloadNeeded) {
            Button('重试读取结果').onClick((): void => this.viewModel.reloadAnnotationResult((): void => this.afterRead()))
          }
          if (this.editor.changed) {
            Text('片段已变化，请重新核对后保存').fontSize(13).fontColor($r('app.color.brand_warning'))
            this.quiet('重新核对', (): void => this.navigate((): void => {
              const id = this.editor.current?.utteranceId;
              if (this.editor.batch) { this.editor.setBatch(true); }
              else { this.editor.focus(this.editor.rows.find((row: PhoneV3Utterance): boolean => row.utteranceId === id)); }
            }))
          }
          if (this.error) { Text(this.error).fontSize(13).fontColor($r('app.color.brand_warning')).width('100%') }
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 16 })
      }.width('100%').layoutWeight(1).align(Alignment.TopStart)
      if (this.resultMode) {
        Button('修改标注').width('100%').constraintSize({ minHeight: 48 }).onClick((): void => { this.resultMode = false; })
      } else if ((this.editor.current || (this.editor.batch && this.editor.selectedCount > 0)) && !this.reloadNeeded) {
        if (this.disabledReason() && this.disabledReason() !== '请选择人物或修改声音类型') {
          Text(this.disabledReason()).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
        }
        Row({ space: 12 }) {
          if (!this.editor.batch && !this.editor.doneMode) {
            this.quiet('暂时跳过', (): void => this.navigate((): void => this.editor.move(1)))
          }
          Button(this.busy ? '正在保存…' : this.editor.batch ? `保存 ${this.editor.selectedCount} 条` : this.editor.doneMode ? '保存修改' : '保存并继续')
            .layoutWeight(1).constraintSize({ minHeight: 48 }).enabled(!this.busy && !this.disabledReason()).onClick((): void => this.save())
        }.width('100%')
      } else if (!this.reloadNeeded) {
        Button('返回').width('100%').constraintSize({ minHeight: 48 }).onClick((): void => this.close())
      }
    }.padding({ left: 16, right: 16, top: 8, bottom: 16 }).width('100%').height('100%')
      .backgroundColor($r('app.color.page_background'))
  }
  build() {
    HdsNavDestination() { this.content() }
      .titleBar({ enableComponentSafeArea: true, content: { title: { mainTitle: this.editor.batch ? '批量标注' : '标注片段' },
        menu: { maxCount: 1, value: [{ content: { icon: $r('sys.media.ohos_ic_public_more'), label: '更多',
          action: (): void => this.openSelector('details') } }] } } })
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.page_background'))
      .onBackPressed((): boolean => { this.close(); return true; })
      .onHidden((): void => this.viewModel.stopPlayback())
      .bindSheet($$this.selectorVisible, this.selectorContent(), { height: SheetSize.LARGE,
        keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY, showClose: false })
  }
}

@Component
struct AnnotationSettingRow {
  @Prop label: string = '';
  @Prop value: string = '';
  onSelect: () => void = (): void => {};
  build() {
    Row({ space: 12 }) {
      Text(this.label).fontSize(16).fontColor($r('app.color.text_primary'))
      Text(this.value).fontSize(15).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.End).layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_secondary')])
    }.width('100%').constraintSize({ minHeight: 60 }).padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor($r('app.color.surface_primary')).onClick((): void => this.onSelect())
      .accessibilityGroup(true).accessibilityText(`${this.label}，${this.value}`)
  }
}
