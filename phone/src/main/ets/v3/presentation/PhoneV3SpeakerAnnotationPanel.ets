import { phoneV3SoundKindLabel } from '../domain/PhoneV3SoundKind';
import { PhoneV3AnnotationIndex } from '../domain/PhoneV3AnnotationIndex';
import { DeviceV3PersonChoice, DeviceV3AnnotationStatus } from '../../computer/ComputerTransferProtocol';
import { phoneV3SampleStatus } from '../domain/PhoneV3SampleStatus';
import { PhoneV3SessionCard, PhoneV3Utterance } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { phoneV3AbsoluteTime, phoneV3TimelineTime } from './PhoneV3UiFormat';

@Component
export struct PhoneV3SpeakerAnnotationPanel {
  viewModel: PhoneV3ViewModel = new PhoneV3ViewModel();
  @Prop fullScreen: boolean = false;
  onClose: () => void = (): void => {};
  @State private editorVisible: boolean = false;
  @State private pageIndex: number = 0;
  @State private searchText: string = '';
  private listScroller: Scroller = new Scroller();
  @Prop @Watch('onSourceChanged') utterances: Array<PhoneV3Utterance> = [];
  @Prop @Watch('onStateChanged') stateRevision: number = 0;
  @State private selectedIds: Array<string> = [];
  @State private people: Array<DeviceV3PersonChoice> = [];
  @State private personIndex: number = 0;
  @State private personId: string = '';
  @State private name: string = '';
  @State private saved: boolean = false;
  @State private pageRows: Array<PhoneV3Utterance> = [];
  @State private totalCount: number = 0;
  @State private selectedCount: number = 0;
  @State private matchCount: number = 0;
  @State private pages: number = 1;
  @State private operationBusy: boolean = false;
  @State private playbackBusy: boolean = false;
  @State private refreshing: boolean = false;
  @State private errorText: string = '';
  @State private sampleStatuses: Array<DeviceV3AnnotationStatus> = [];
  @State private actionIndex: number = 0;
  private actionKinds: Array<string> = ['', 'non_speech', 'unintelligible', 'background_speech', 'speech', 'overlapping_speech', 'remote_speech', 'media_speech', 'live_speech'];
  private actionOptions: Array<SelectOption> = [{ value: '关联人物' }, { value: '非人声／噪声' },
    { value: '人声听不清' }, { value: '背景人声／电视声（来源未定）' }, { value: '恢复正常发言' },
    { value: '内容清楚但多人重叠' }, { value: '电话／会议中的实际互动者' }, { value: '确定是媒体播放' }, { value: '确认是现场实际对话' }];
  @State private personLabel: string = '创建新人物';
  @State private personOptions: Array<SelectOption> = [{ value: '创建新人物' }];
  private index: PhoneV3AnnotationIndex = new PhoneV3AnnotationIndex();
  private filteredRows: Array<PhoneV3Utterance> = [];
  private localAudioSessions: Set<string> = new Set<string>();


  aboutToAppear(): void {
    this.selectedIds = this.utterances.length === 1 ? [this.utterances[0].utteranceId] : [];
    this.onSourceChanged();
    if (this.fullScreen) { this.loadEditor(); }
  }

  aboutToDisappear(): void {
    this.viewModel.stopPlayback();
  }

  private onSourceChanged(): void {
    this.index.setTargets(this.utterances);
    this.onStateChanged();
  }

  private onStateChanged(): void {
    if (this.index.update(this.viewModel.snapshot.sessions)) {
      this.localAudioSessions = new Set<string>(this.viewModel.snapshot.sessions.filter(
        (session: PhoneV3SessionCard): boolean => session.localPaths.length > 0 && session.localGroupKey.length > 0)
        .map((session: PhoneV3SessionCard): string => session.sessionId));
      this.totalCount = this.index.rows.length;
      this.updateSelectionCount();
      this.filterRows();
    }
    this.operationBusy = this.viewModel.annotationSaving;
    this.playbackBusy = this.viewModel.device.playbackBusy;
    this.refreshing = this.viewModel.annotationRefreshing;
    this.errorText = this.viewModel.error;
  }

  private selected(): Array<PhoneV3Utterance> {
    const ids = new Set<string>(this.selectedIds);
    return this.index.rows.filter((value: PhoneV3Utterance): boolean => ids.has(value.utteranceId));
  }

  private querySamples(retry: boolean = false): void {
    const ids = this.pageRows.map((row: PhoneV3Utterance): string => row.utteranceId);
    if (ids.length === 0) { return; }
    this.viewModel.loadSampleStatus(ids, retry, (items: Array<DeviceV3AnnotationStatus>): void => {
      this.sampleStatuses = items;
    });
  }

  private sampleStatus(row: PhoneV3Utterance): string {
    if (row.annotationPending) { return '人工事实：本地待同步；样本状态待服务器确认'; }
    for (let conflict of this.viewModel.snapshot.conflicts) {
      if (conflict.payloadJson.includes(row.utteranceId)) { return '人工事实：同步冲突或失败，请到审核页处理'; }
    }
    const status = this.sampleStatuses.find((value: DeviceV3AnnotationStatus): boolean =>
      value.utterance_id === row.utteranceId && value.revision === row.revision);
    return status === undefined ? '样本状态尚未查询；保存不等于已采纳或已用于匹配' : phoneV3SampleStatus(status);
  }

  private updateSelectionCount(): void {
    this.selectedCount = this.selected().length;
  }

  private selectAll(): void {
    this.saved = false;
    this.selectedIds = this.index.rows.map((value: PhoneV3Utterance): string => value.utteranceId);
    this.updateSelectionCount();
  }

  private clearSelection(): void {
    this.selectedIds = [];
    this.selectedCount = 0;
  }

  private choose(id: string, checked: boolean): void {
    this.saved = false;
    this.selectedIds = this.selectedIds.filter((value: string): boolean => value !== id);
    if (checked) {
      this.selectedIds = this.selectedIds.concat([id]);
    }
    this.updateSelectionCount();
  }

  private loadEditor(): void {
    this.viewModel.loadPeople((people: Array<DeviceV3PersonChoice>): void => {
      this.people = people;
      const selectedIndex = people.findIndex((person: DeviceV3PersonChoice): boolean => person.person_id === this.personId);
      this.personIndex = selectedIndex + 1;
      const options: Array<SelectOption> = [{ value: '创建新人物' }];
      this.personOptions = options.concat(people.map((person: DeviceV3PersonChoice): SelectOption => {
        return { value: person.display_name };
      }));
    });
  }

  private closeEditor(): void {
    this.viewModel.stopPlayback();
    this.editorVisible = false;
    this.onClose();
  }

  private filterRows(): void {
    const query = this.searchText.trim().toLowerCase();
    this.filteredRows = query.length === 0 ? this.index.rows : this.index.rows.filter(
      (value: PhoneV3Utterance): boolean => value.text.toLowerCase().includes(query) ||
        phoneV3AbsoluteTime(value.startAt).includes(query));
    this.matchCount = this.filteredRows.length;
    this.pages = Math.max(1, Math.ceil(this.matchCount / 20));
    this.pageIndex = Math.min(this.pageIndex, this.pages - 1);
    this.updatePage();
  }

  private updatePage(): void {
    this.pageRows = this.filteredRows.slice(this.pageIndex * 20, (this.pageIndex + 1) * 20);
  }

  private changePage(delta: number): void {
    this.pageIndex = Math.max(0, Math.min(this.pageIndex + delta, this.pages - 1));
    this.updatePage();
    this.listScroller.scrollTo({ xOffset: 0, yOffset: 0 });
  }

  @Builder
  private editor() {
    Column({ space: 8 }) {
      Row() {
        Text('片段标注').fontSize(20).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('关闭').height(40).onClick((): void => this.closeEditor())
      }.width('100%')
      Row({ space: 8 }) {
        Button('全选整组').fontSize(12).layoutWeight(1).height(36)
          .onClick((): void => this.selectAll())
        Button('清空选择').fontSize(12).layoutWeight(1).height(36)
          .onClick((): void => this.clearSelection())
        Button('停止试听').fontSize(12).layoutWeight(1).height(36)
          .onClick((): void => this.viewModel.stopPlayback())
      }.width('100%')
      TextInput({ text: this.searchText, placeholder: '搜索发言内容或时间' }).height(38)
        .onChange((value: string): void => {
          this.searchText = value;
          this.pageIndex = 0;
          this.filterRows();
          this.listScroller.scrollTo({ xOffset: 0, yOffset: 0 });
        })
      Row({ space: 8 }) {
        Button('上一页').fontSize(12).height(34).enabled(this.pageIndex > 0)
          .onClick((): void => this.changePage(-1))
        Text(`${this.pageIndex + 1} / ${this.pages} 页 · ${this.matchCount} 句`)
          .fontSize(12).layoutWeight(1).textAlign(TextAlign.Center)
        Button('下一页').fontSize(12).height(34).enabled(this.pageIndex + 1 < this.pages)
          .onClick((): void => this.changePage(1))
      }.width('100%')
      Scroll(this.listScroller) {
        Column({ space: 8 }) {
          if (this.pageRows.length === 0) {
            Text('没有符合条件的发言').fontSize(14).padding(20)
          }
          ForEach(this.pageRows, (utterance: PhoneV3Utterance) => {
        Column({ space: 6 }) {
          Row() {
            Checkbox({ name: utterance.utteranceId })
              .select(this.selectedIds.indexOf(utterance.utteranceId) >= 0)
              .onChange((checked: boolean): void => this.choose(utterance.utteranceId, checked))
            Text(`${phoneV3AbsoluteTime(utterance.startAt)} · ${phoneV3TimelineTime(utterance.startMs)}–${phoneV3TimelineTime(utterance.endMs)}`)
              .fontSize(12).layoutWeight(1).fontColor($r('app.color.brand_primary'))
          }.width('100%')
          Text(utterance.text).fontSize(14).width('100%')
          Text(this.sampleStatus(utterance)).fontSize(12).width('100%')
          Text(`${phoneV3SoundKindLabel(utterance.soundKind)} · 当前归属：${utterance.speakerLabel ?? '未知说话人'}${utterance.annotationPending ? ' · 待同步' : ''}`)
            .fontSize(12).width('100%').fontColor($r('app.color.text_secondary'))
          Row({ space: 8 }) {
            Button(this.localAudioSessions.has(utterance.sessionId) ? '本地试听' : '需连接电脑试听')
              .fontSize(12).height(36).enabled(!this.operationBusy && !this.playbackBusy)
              .onClick((): void => this.viewModel.playUtterance(utterance))
            Button('含前后文').fontSize(12).height(36).enabled(!this.operationBusy && !this.playbackBusy)
              .onClick((): void => this.viewModel.playUtterance(utterance, true))
            Button('只选这句').fontSize(12).height(36).onClick((): void => {
              this.saved = false;
              this.selectedIds = [utterance.utteranceId];
              this.updateSelectionCount();
            })
          }
        }.padding(10).width('100%').backgroundColor($r('app.color.surface_secondary')).borderRadius(12)
          }, (utterance: PhoneV3Utterance): string => `${utterance.utteranceId}:${utterance.revision}:${utterance.speakerLabel}:${utterance.annotationPending}:${utterance.soundKind}`)
        }.width('100%')
      }.width('100%').layoutWeight(1).align(Alignment.TopStart)
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Button('查询本页样本状态').fontSize(12).onClick((): void => this.querySamples())
          Button('重试本页样本处理').fontSize(12).onClick((): void => this.querySamples(true))
        }
        Row() {
          Text(`已选 ${this.selectedCount} / ${this.totalCount} 句（跨页保留）`)
            .fontSize(13).layoutWeight(1)
          Button('刷新').fontSize(12).height(32).enabled(!this.operationBusy)
            .onClick((): void => this.viewModel.refreshAnnotationData())
        }.width('100%')
      Select(this.actionOptions).selected(this.actionIndex).value(this.actionOptions[this.actionIndex].value)
        .onSelect((index: number): void => { this.actionIndex = index; this.saved = false; })
      if (this.actionIndex === 0) {
      Select(this.personOptions).selected(this.personIndex)
        .value(this.personLabel)
        .onSelect((index: number): void => {
          this.personIndex = index;
          this.personLabel = index > 0 ? this.people[index - 1].display_name : '创建新人物';
          this.personId = index > 0 ? this.people[index - 1].person_id : '';
          this.saved = false;
        })
      if (this.personId.length === 0) {
        TextInput({ text: this.name, placeholder: '新人物姓名' }).maxLength(100)
          .onChange((value: string): void => { this.name = value; this.saved = false; })
      }
      }
      if (this.actionIndex > 0) {
        Text('人物归属独立保留。清楚的重叠或远程对话可提取内容，但不自动用作声纹。').fontSize(11)
      }
      if (this.refreshing) {
        Text('正在后台更新发言，可继续选择人物和片段').fontSize(11)
      }
      Button(this.operationBusy ? '正在处理…' : `本地保存 ${this.selectedCount} 个片段标注`)
        .width('100%').enabled(!this.operationBusy && this.selectedCount > 0 &&
          (this.actionIndex > 0 || this.personId.length > 0 || this.name.trim().length > 0))
        .onClick((): void => {
          if (this.actionIndex === 0) {
            this.viewModel.assignUtterances(this.selected(), this.personId, this.name,
              (): void => { this.saved = true; this.clearSelection(); this.loadEditor(); });
          } else {
            this.viewModel.classifyUtterances(this.selected(), this.actionKinds[this.actionIndex],
              (): void => { this.saved = true; this.clearSelection(); });
          }
        })
        if (this.saved) {
          Text('已在手机保存，等待同步；冲突请到审核处理').fontSize(12).fontColor($r('app.color.brand_success'))
        }
        if (this.errorText.length > 0) {
          Text(this.errorText).fontSize(12).maxLines(3)
            .fontColor($r('app.color.brand_warning')).width('100%')
        }
      }.width('100%').padding(8).backgroundColor($r('app.color.surface_primary')).borderRadius(12)
    }.width('100%').height('100%').padding({ left: 16, right: 16, top: 12, bottom: 16 })
      .backgroundColor($r('app.color.page_background')).alignItems(HorizontalAlign.Start)
  }

  build() {
    if (this.fullScreen) {
      this.editor()
    } else {
      Button(`打开片段标注 · ${this.utterances.length} 句`).width('100%')
        .onClick((): void => { this.editorVisible = true; this.loadEditor(); })
        .bindSheet(this.editorVisible, this.editor(), {
          height: SheetSize.LARGE,
          showClose: false,
          onDisappear: (): void => { this.editorVisible = false; this.viewModel.stopPlayback(); }
        })
    }
  }
}
