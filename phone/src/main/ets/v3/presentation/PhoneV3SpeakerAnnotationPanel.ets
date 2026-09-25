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
export struct PhoneV3SpeakerAnnotationPanel {
  viewModel: PhoneV3ViewModel = new PhoneV3ViewModel();
  @Prop fullScreen: boolean = false;
  @Prop utterances: Array<PhoneV3Utterance> = [];
  @Prop @Watch('onStateChanged') stateRevision: number = 0;
  onClose: () => void = (): void => {};
  @State private editor: PhoneV3AnnotationEditor = new PhoneV3AnnotationEditor();
  @State private visible: boolean = false;
  @State private busy: boolean = false;
  @State private playback: string = '';
  @State private error: string = '';
  @State private feedback: string = '';
  @State private reloadNeeded: boolean = false;
  @State private people: Array<DeviceV3PersonChoice> = [];
  @State private picker: boolean = false;
  @State private personQuery: string = '';
  @State private searchDraft: string = '';
  @State private personId: string = '';
  @State private personLabel: string = '';
  @State private personChanged: boolean = false;
  @State private creating: boolean = false;
  @State private name: string = '';
  @State private soundExpanded: boolean = false;
  @State private soundKind: string = '';
  @State private expanded: boolean = false;
  @State private withContext: boolean = false;
  @State private details: boolean = false;
  @State private showSelected: boolean = false;
  @State private sampleStatuses: Array<DeviceV3AnnotationStatus> = [];
  private lastSavedIds: Array<string> = [];
  private opened: boolean = false;
  private contentScroller: Scroller = new Scroller();
  private conflictSource: Array<PhoneV3Conflict> | undefined = undefined;
  private conflictsById: Map<string, Array<PhoneV3Conflict>> = new Map<string, Array<PhoneV3Conflict>>();
  @State private conflictDetails: boolean = false;

  aboutToAppear(): void { if (this.fullScreen) { this.open(); } }
  aboutToDisappear(): void { this.viewModel.stopPlayback(); }

  private open(): void {
    this.editor = new PhoneV3AnnotationEditor();
    this.editor.open(this.utterances, this.viewModel.snapshot.sessions);
    this.opened = true;
    this.feedback = ''; this.reloadNeeded = false; this.searchDraft = '';
    this.resetForm();
    this.visible = true;
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
    this.personId = row?.annotationPersonId ?? '';
    this.personLabel = this.personId ? row?.speakerLabel ?? '已选人物' : '';
    this.name = ''; this.personChanged = false; this.creating = false;
    this.soundKind = ''; this.soundExpanded = false; this.picker = false;
    this.personQuery = ''; this.expanded = false; this.conflictDetails = false;
  }
  private dirty(): boolean { return this.personChanged || this.soundKind.length > 0 || this.name.length > 0; }
  private navigate(action: () => void): void {
    if (this.busy || this.reloadNeeded) { return; }
    if (this.dirty()) {
      AlertDialog.show({ title: '放弃未保存的修改？', message: '这次输入尚未保存。',
        primaryButton: { value: '继续编辑', action: (): void => {} },
        secondaryButton: { value: '放弃修改', action: (): void => { this.viewModel.stopPlayback(); action(); this.resetForm(); this.contentScroller.scrollTo({ xOffset: 0, yOffset: 0 }); } } });
    } else { this.viewModel.stopPlayback(); action(); this.resetForm(); this.contentScroller.scrollTo({ xOffset: 0, yOffset: 0 }); }
  }
  private close(): void {
    if (this.reloadNeeded && !this.busy) {
      this.viewModel.stopPlayback(); this.visible = false; this.opened = false; this.onClose(); return;
    }
    this.navigate((): void => { this.visible = false; this.opened = false; this.onClose(); });
  }
  private focus(row: PhoneV3Utterance): void {
    this.navigate((): void => { this.editor.focus(row); });
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
    const label = [this.personChanged ? `人物已确认：${this.creating ? this.name.trim() : this.personLabel}` : '',
      this.soundKind ? `已标记：${phoneV3SoundKindLabel(this.soundKind)}` : ''].filter((value: string): boolean => value.length > 0).join(' · ');
    this.viewModel.saveAnnotation(targets, this.creating ? '' : this.personId, this.name,
      this.personChanged, this.soundKind, (refreshed: boolean): void => {
        this.lastSavedIds = ids;
        this.feedback = `${label} · 已在手机保存，待同步到电脑`;
        this.reloadNeeded = !refreshed;
        if (refreshed) { this.afterRead(); }
      });
  }
  private afterRead(): void {
    this.editor.update(this.viewModel.snapshot.sessions);
    this.editor.saved(this.lastSavedIds);
    this.reloadNeeded = false;
    this.resetForm();
    this.contentScroller.scrollTo({ xOffset: 0, yOffset: 0 });
    this.viewModel.loadPeople((values: Array<DeviceV3PersonChoice>): void => { this.people = values; });
  }
  private viewSaved(): void {
    this.navigate((): void => {
      this.editor.switchMode(true);
      this.editor.focus(this.editor.rows.find((row: PhoneV3Utterance): boolean => row.utteranceId === this.lastSavedIds[0]));
    });
  }
  private querySamples(retry: boolean = false): void {
    const rows = this.editor.batch ? this.editor.pageRows : this.focused();
    this.viewModel.loadSampleStatus(rows.map((row: PhoneV3Utterance): string => row.utteranceId), retry,
      (items: Array<DeviceV3AnnotationStatus>): void => { this.sampleStatuses = items; });
  }
  private listPages(): number { return this.showSelected ? this.editor.selectionPages : this.editor.pages; }
  private changeListPage(delta: number): void {
    if (this.showSelected) { this.editor.selectionPage = Math.max(0, Math.min(this.editor.selectionPages - 1, this.editor.selectionPage + delta)); }
    else { this.editor.page = Math.max(0, Math.min(this.editor.pages - 1, this.editor.page + delta)); }
    this.editor.filter();
  }
  private hasAudio(row: PhoneV3Utterance): boolean {
    return this.viewModel.snapshot.sessions.some((session): boolean => session.sessionId === row.sessionId && session.localPaths.length > 0);
  }

  @Builder
  private secondary(label: string, action: () => void) {
    Button(label).buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(14).enabled(!this.busy && !this.reloadNeeded).onClick(action)
  }
  @Builder
  private fragment(row: PhoneV3Utterance) {
    Column({ space: 10 }) {
      Text(`${phoneV3AbsoluteTime(row.startAt)} · ${((row.endMs - row.startMs) / 1000).toFixed(1)} 秒`)
        .fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
      Text(phoneV3AnnotationLabel(row)).fontSize(14).width('100%')
      if (phoneV3AnnotationState(row).review) {
        Text(phoneV3AnnotationState(row).reason).fontSize(13).fontColor($r('app.color.brand_warning'))
        this.secondary('核对冲突／过期原因', (): void => { this.conflictDetails = !this.conflictDetails; })
        if (this.conflictDetails) {
          ForEach(this.conflictsById.get(row.utteranceId) ?? [], (conflict: PhoneV3Conflict) => {
            PhoneV3AnnotationConflictPanel({ viewModel: this.viewModel, conflict: conflict, stateRevision: this.stateRevision })
          }, (conflict: PhoneV3Conflict): string => conflict.operationId)
          if (!this.conflictsById.has(row.utteranceId)) {
            Text('请重新试听并核对当前来源，再保存修改；来源已失效的片段需返回会话选择新片段。').fontSize(13)
          }
        }
      }
      Text(row.text).fontSize(18).maxLines(this.expanded ? 1000 : 4).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      this.secondary(this.expanded ? '收起正文' : '展开全文', (): void => { this.expanded = !this.expanded; })
      Row({ space: 8 }) {
        if (this.playback.length > 0) {
          this.secondary(`${this.playback} · 停止`, (): void => this.viewModel.stopPlayback())
        } else {
          this.secondary('播放片段', (): void => this.viewModel.playUtterance(row, this.withContext))
        }
        Checkbox().select(this.withContext).onChange((value: boolean): void => { this.withContext = value; })
        Text('包含前后文').fontSize(12)
      }
      if (phoneV3AnnotationState(row).sync && phoneV3AnnotationState(row).sync !== '已同步') {
        Text('连接电脑后，可从首页的同步入口同步；标注已保存在手机。').fontSize(12)
      }
      if (!this.hasAudio(row)) { Text('手机没有这段音频，试听需连接电脑；仍可保存标注。').fontSize(12).width('100%') }
    }.padding(14).width('100%').backgroundColor($r('app.color.surface_secondary')).borderRadius(14)
  }
  @Builder
  private form() {
    Column({ space: 8 }) {
      Text('这是谁说的？').fontSize(17).fontWeight(FontWeight.Medium).width('100%')
      if (this.personLabel) { Text(`当前人物：${this.personLabel}`).fontSize(14).width('100%') }
      if (!this.personId && this.editor.current?.speakerLabel && !this.editor.batch) {
        Text(`系统建议：${this.editor.current?.speakerLabel}（尚未人工确认）`).fontSize(12).width('100%')
      }
      Row() {
        this.secondary('选择人物', (): void => {
          this.picker = !this.picker;
          if (this.creating) { this.creating = false; this.name = ''; this.personChanged = false; }
        })
        this.secondary('新建人物', (): void => { this.creating = true; this.picker = false; this.personChanged = true; })
      }
      if (this.picker) {
        TextInput({ text: this.personQuery, placeholder: '搜索已缓存人物' }).enabled(!this.busy)
          .onChange((value: string): void => { this.personQuery = value; })
        ForEach(this.people.filter((person: DeviceV3PersonChoice): boolean =>
          person.display_name.toLowerCase().includes(this.personQuery.toLowerCase())).slice(0, 30), (person: DeviceV3PersonChoice) => {
          this.secondary(person.display_name, (): void => {
            this.personId = person.person_id; this.personLabel = person.display_name;
            this.personChanged = true; this.creating = false; this.picker = false;
          })
        }, (person: DeviceV3PersonChoice): string => person.person_id)
        Text('显示最多 30 个匹配人物，可继续输入缩小范围。').fontSize(12)
      }
      if (this.creating) {
        TextInput({ text: this.name, placeholder: '新人物姓名' }).maxLength(100).enabled(!this.busy)
          .onChange((value: string): void => { this.name = value; })
      }
      this.secondary(`声音类型：${phoneV3SoundKindLabel(this.soundKind || this.editor.current?.soundKind || 'speech')}${!this.soundKind && !this.editor.current?.annotationFacts.sound ? '（未确认）' : ''} ›`,
        (): void => { this.soundExpanded = !this.soundExpanded; })
      if (this.soundExpanded) {
        ForEach(PHONE_V3_SOUND_KINDS, (kind: string) => {
          this.secondary(phoneV3SoundKindLabel(kind), (): void => { this.soundKind = kind; this.soundExpanded = false; })
        }, (kind: string): string => kind)
        Text('声音类型与人物分别保存；标注不会自动采纳声纹或改变授权。').fontSize(12)
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
  }
  @Builder
  private list() {
    ForEach(this.showSelected ? this.editor.selectedPageRows : this.editor.pageRows, (row: PhoneV3Utterance) => {
      Row({ space: 8 }) {
        if (this.editor.batch) {
          Checkbox({ name: row.utteranceId }).select(this.editor.isSelected(row.utteranceId)).enabled(!this.busy)
            .onChange((value: boolean): void => this.editor.choose(row, value))
        }
        Column({ space: 5 }) {
          Text(phoneV3AnnotationLabel(row)).fontSize(13).width('100%')
          Text(row.text).fontSize(15).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          Text(phoneV3AbsoluteTime(row.startAt)).fontSize(12).width('100%')
        }.layoutWeight(1).onClick((): void => { if (!this.editor.batch) { this.focus(row); } })
      }.padding(12).width('100%').backgroundColor($r('app.color.surface_secondary')).borderRadius(12)
    }, (row: PhoneV3Utterance): string => phoneV3AnnotationKey(row, row.utteranceId, row.revision))
  }
  @Builder
  private content() {
    Column({ space: 8 }) {
      Row() {
        Text(`片段标注 · ${this.utterances.length === 1 ? '本句' : '本组'}`).fontSize(20).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('关闭').buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.busy).onClick((): void => this.close())
      }.width('100%')
      Row() {
        this.secondary(`待标注 ${this.editor.pending}`, (): void => this.navigate((): void => this.editor.switchMode(false)))
        this.secondary(`已标注 ${this.editor.done}`, (): void => this.navigate((): void => this.editor.switchMode(true)))
      }.width('100%')
      Text(this.editor.doneMode ? '正在查看已标注' : '正在处理待标注').fontSize(12).fontColor($r('app.color.text_secondary'))
      Scroll(this.contentScroller) {
        Column({ space: 10 }) {
          if (this.feedback) {
            Text(this.feedback).fontSize(14).width('100%').fontColor($r('app.color.brand_success'))
            if (this.reloadNeeded) {
              Button('重试读取结果').buttonStyle(ButtonStyleMode.TEXTUAL)
                .onClick((): void => this.viewModel.reloadAnnotationResult((): void => this.afterRead()))
            } else { this.secondary('查看／修改刚才的标注', (): void => this.viewSaved()) }
          }
          if (this.editor.rows.length > 20) {
            TextInput({ text: this.searchDraft, placeholder: '搜索本组正文或时间，回车应用' }).enabled(!this.busy)
              .onChange((value: string): void => { this.searchDraft = value; })
              .onSubmit((): void => this.navigate((): void => {
                this.editor.query = this.searchDraft; this.editor.page = 0; this.editor.filter();
                if (!this.editor.batch) { this.editor.focus(this.editor.doneMode ? undefined : this.editor.filtered[0]); }
              }))
          }
          if (!this.editor.doneMode && this.editor.rows.length > 1) {
            this.secondary(this.editor.batch ? '退出批量' : '批量', (): void => this.navigate((): void => {
              this.editor.setBatch(!this.editor.batch); this.showSelected = false;
            }))
          }
          if (this.editor.batch) {
            Row() {
              this.secondary(`全选筛选结果 ${this.editor.filtered.length} 条（跨页）`, (): void => this.editor.selectFiltered())
              this.secondary('清空', (): void => this.editor.setBatch(true))
            }
            Text(`已选 ${this.editor.selectedCount} 条 · 筛选外 ${this.editor.hidden} 条`).fontSize(13)
            this.secondary(this.showSelected ? '返回筛选结果' : '查看全部选择', (): void => { this.showSelected = !this.showSelected; })
          }
          if (this.editor.filtered.length === 0 && (!this.editor.current || this.editor.batch)) {
            Text(this.editor.query.trim() ? '没有符合搜索条件的片段' : this.editor.doneMode ? '本范围还没有已标注片段' : '本范围全部标注完成')
              .fontSize(18).padding(20)
            if (!this.editor.doneMode && !this.editor.query.trim()) {
              this.secondary('查看已标注', (): void => this.navigate((): void => this.editor.switchMode(true)))
              this.secondary('返回', (): void => this.close())
            }
          }
          if (this.editor.batch || (this.editor.doneMode && !this.editor.current)) { this.list() }
          if (!this.editor.batch) {
            ForEach(this.focused(), (row: PhoneV3Utterance) => { this.fragment(row) }, (row: PhoneV3Utterance): string => phoneV3AnnotationKey(row, row.utteranceId, row.revision))
            if (this.editor.current && this.editor.filtered.length > 1) {
              Row() {
                this.secondary('上一条', (): void => this.navigate((): void => this.editor.move(-1)))
                this.secondary(this.editor.doneMode ? '下一条' : '暂时跳过', (): void => this.navigate((): void => this.editor.move(1)))
              }
            }
            if (this.editor.doneMode && this.editor.current) {
              this.secondary('返回已标注列表', (): void => this.navigate((): void => this.editor.focus(undefined)))
            }
          }
          if ((this.editor.batch || (this.editor.doneMode && !this.editor.current)) && this.listPages() > 1) {
            Row() {
              this.secondary('上一页', (): void => { this.changeListPage(-1); })
              Text(`${(this.showSelected ? this.editor.selectionPage : this.editor.page) + 1} / ${this.listPages()}`).fontSize(13)
              this.secondary('下一页', (): void => { this.changeListPage(1); })
            }
          }
          if (this.editor.current || (this.editor.batch && this.editor.pending > 0)) { this.form() }
          if (this.editor.changed) {
            this.secondary('重新核对最新片段', (): void => this.navigate((): void => {
              const id = this.editor.current?.utteranceId;
              this.editor.setBatch(false);
              this.editor.focus(this.editor.rows.find((row: PhoneV3Utterance): boolean => row.utteranceId === id));
            }))
          }
          this.secondary(this.details ? '收起样本处理详情' : '更多 › 样本处理详情', (): void => { this.details = !this.details; })
          if (this.details) {
            this.secondary('查询样本处理', (): void => this.querySamples())
            this.secondary('重试样本处理', (): void => this.querySamples(true))
            ForEach(this.sampleStatuses, (status: DeviceV3AnnotationStatus) => { Text(phoneV3SampleStatus(status)).fontSize(12) },
              (status: DeviceV3AnnotationStatus): string => `${status.utterance_id}:${status.revision}`)
            this.secondary('刷新标注数据', (): void => this.viewModel.refreshAnnotationData())
          }
          if (this.error) { Text(this.error).fontSize(13).fontColor($r('app.color.brand_warning')).width('100%') }
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 12 })
      }.layoutWeight(1).width('100%').align(Alignment.TopStart)
      if (this.editor.current || (this.editor.batch && this.editor.pending > 0)) {
        Column({ space: 4 }) {
          if (this.disabledReason()) { Text(this.disabledReason()).fontSize(13).width('100%') }
          Button(this.busy ? '正在保存…' : this.editor.batch ? `保存 ${this.editor.selectedCount} 条标注` : this.editor.doneMode ? '保存修改' : '保存并继续')
            .width('100%').enabled(!this.busy && !this.disabledReason()).onClick((): void => this.save())
        }.padding(8).width('100%').backgroundColor($r('app.color.surface_primary'))
      }
    }.padding({ left: 16, right: 16, top: 12, bottom: 16 }).width('100%').height('100%')
      .backgroundColor($r('app.color.page_background')).alignItems(HorizontalAlign.Start)
  }
  build() {
    if (this.fullScreen) { this.content() }
    else {
      Button(`打开片段标注 · ${this.utterances.length} 句`).buttonStyle(ButtonStyleMode.TEXTUAL).width('100%')
        .onClick((): void => this.open())
        .bindSheet(this.visible, this.content(), { height: SheetSize.LARGE, keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY, showClose: false,
          onDisappear: (): void => { this.visible = false; this.opened = false; this.viewModel.stopPlayback(); } })
    }
  }
}
