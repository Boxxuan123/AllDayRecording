import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { PhoneV3SessionCard } from '../domain/PhoneV3Models';
import {
  PhoneDailyCache, PhoneDailySummary, PhoneDailyEvent, PhoneDailyEvidence,
  PhoneDailyItem, PhoneDailyParticipant, phoneDailyStatus
} from '../domain/PhoneV3DailyModels';

@Component
export struct PhoneV3DailyPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  @Prop @Watch('reload') stateRevision: number = 0;
  @State private cache: PhoneDailyCache = new PhoneDailyCache();
  @State private date: string = '';
  @State private selectedEventId: string = '';
  @State private loading: boolean = true;
  @State private error: string = '';
  @State private showSecondary: boolean = false;
  onOpenSession: (session: PhoneV3SessionCard) => void = (): void => {};
  private requestGeneration: number = 0;

  aboutToAppear(): void { this.reload(); }
  aboutToDisappear(): void { this.requestGeneration += 1; }

  private reload(): void {
    const generation = ++this.requestGeneration;
    this.viewModel.loadDailyCache().then((value: PhoneDailyCache): void => {
      if (generation !== this.requestGeneration) { return; }
      this.cache = value;
      if (this.date.length === 0 && value.summaries.length > 0) {
        this.date = value.summaries[0].summary_date;
      }
      this.loading = false; this.error = '';
    }).catch((error: Error): void => {
      if (generation !== this.requestGeneration) { return; }
      this.loading = false; this.error = error.message;
    });
  }

  private summary(): PhoneDailySummary | undefined {
    return this.cache.summaries.find((s: PhoneDailySummary): boolean => s.summary_date === this.date);
  }

  private events(): Array<PhoneDailyEvent> {
    const summary = this.summary();
    if (summary === undefined) { return []; }
    return this.cache.events.filter((e: PhoneDailyEvent): boolean =>
      summary.objective.source_event_ids.indexOf(e.event_id) >= 0 &&
      summary.objective.source_event_revisions[e.event_id] === e.revision);
  }

  private majorEvents(): Array<PhoneDailyEvent> {
    const ids = (this.summary()?.objective.major_events ?? [])
      .flatMap((item: PhoneDailyItem): Array<string> => item.event_ids);
    return this.events().filter((event: PhoneDailyEvent): boolean => ids.indexOf(event.event_id) >= 0);
  }

  private secondaryEvents(): Array<PhoneDailyEvent> {
    const ids = this.majorEvents().map((event: PhoneDailyEvent): string => event.event_id);
    return this.events().filter((event: PhoneDailyEvent): boolean => ids.indexOf(event.event_id) < 0);
  }

  private time(value: string): string {
    return new Date(value).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
  }

  private supportedItems(items: Array<PhoneDailyItem>): Array<PhoneDailyItem> {
    const ids = this.events().map((event: PhoneDailyEvent): string => event.event_id);
    return items.filter((item: PhoneDailyItem): boolean =>
      item.event_ids.every((id: string): boolean => ids.indexOf(id) >= 0));
  }

  private supportedPeople(): Array<PhoneDailyParticipant> {
    const ids = this.events().map((event: PhoneDailyEvent): string => event.event_id);
    return (this.summary()?.objective.people_interacted ?? []).filter((person: PhoneDailyParticipant): boolean =>
      person.kind === 'known' && (person.event_ids ?? []).every((id: string): boolean => ids.indexOf(id) >= 0));
  }

  private hasUnknownPeople(): boolean {
    const ids = this.events().map((event: PhoneDailyEvent): string => event.event_id);
    return (this.summary()?.objective.people_interacted ?? []).some((person: PhoneDailyParticipant): boolean =>
      person.kind === 'unknown' && (person.event_ids ?? []).some((id: string): boolean => ids.indexOf(id) >= 0));
  }

  private participantLabels(event: PhoneDailyEvent): string {
    const labels = event.participants.filter((p: PhoneDailyParticipant): boolean => p.kind !== 'unknown')
      .map((p: PhoneDailyParticipant): string => p.label);
    if (event.participants.some((p: PhoneDailyParticipant): boolean => p.kind === 'unknown')) {
      labels.push('另有未确认身份的说话人');
    }
    return labels.join('、');
  }

  private outcomeText(event: PhoneDailyEvent): string {
    if (event.outcome === undefined || typeof event.outcome === 'string') { return ''; }
    const label = event.outcome.kind === 'decision' ? '明确决定' :
      event.outcome.kind === 'commitment' ? '明确承诺' : '明确完成表述';
    return `${label}：${event.outcome.quote}`;
  }

  private openSource(evidence: PhoneDailyEvidence): void {
    const session = this.viewModel.snapshot.sessions.find((s: PhoneV3SessionCard): boolean =>
      s.sessionId === evidence.session_id);
    if (session !== undefined) { this.onOpenSession(session); }
  }

  @Builder
  private section(title: string, items: Array<PhoneDailyItem>) {
    Column({ space: 8 }) {
      Text(title).fontSize(18).fontWeight(FontWeight.Bold)
      if (items.length === 0) { Text('暂无有证据的条目').fontColor($r('app.color.text_secondary')) }
      ForEach(this.supportedItems(items), (item: PhoneDailyItem) => {
        Text(`${item.text ?? item.title ?? ''}${item.status === undefined ? '' : ' · ' + phoneDailyStatus(item.status)}`)
          .width('100%').fontSize(15)
          .onClick((): void => { this.selectedEventId = item.event_ids[0]; })
        if (item.scheduled_at !== undefined && item.scheduled_at !== null) {
          Text(`时间：${item.scheduled_at}`).fontSize(12).fontColor($r('app.color.text_secondary'))
        }
      }, (item: PhoneDailyItem): string => `${item.task_id ?? ''}:${item.event_ids.join(',')}:${item.text ?? item.title ?? ''}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private eventCard(event: PhoneDailyEvent) {
    Column({ space: 8 }) {
      Text(`${this.time(event.start_at)}—${this.time(event.end_at)}`)
        .fontSize(12).fontColor($r('app.color.text_secondary'))
      Text(event.title).fontSize(17).fontWeight(FontWeight.Medium)
      if ((event.summary ?? '').length > 0) {
        Text(event.summary ?? '').fontSize(15).width('100%')
      }
      Text(this.participantLabels(event))
        .fontSize(13).fontColor($r('app.color.text_secondary'))
      if (event.linked_task_ids.length > 0) {
        Text(`关联待办：${event.linked_task_ids.length} 项`).fontSize(13)
      }
      if (this.outcomeText(event).length > 0) {
        Text(this.outcomeText(event)).fontSize(13)
      }
      Button(this.selectedEventId === event.event_id ? '收起证据' : `查看证据（${event.evidence_snapshots.length}）`)
        .onClick((): void => { this.selectedEventId = this.selectedEventId === event.event_id ? '' : event.event_id; })
      if (this.selectedEventId === event.event_id) {
        ForEach(event.evidence_snapshots, (evidence: PhoneDailyEvidence) => {
          Column({ space: 5 }) {
            Text(`${this.time(evidence.start_at)} · ${evidence.participant.label}`).fontSize(13)
            Text(evidence.text).fontSize(15).width('100%')
            Row({ space: 12 }) {
              Button('播放原音').onClick((): void => this.viewModel.playDailyEvidence(evidence))
              Button('打开录音').onClick((): void => this.openSource(evidence))
            }
          }.width('100%').alignItems(HorizontalAlign.Start).padding(8)
        }, (evidence: PhoneDailyEvidence): string => `${evidence.utterance_id}:${evidence.revision}`)
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(14)
      .backgroundColor($r('app.color.surface_primary')).borderRadius(14)
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        if (this.loading) { LoadingProgress().width(28).height(28) }
        if (this.error.length > 0) {
          Text(this.error).fontColor($r('app.color.brand_warning'))
          Button('重新读取').onClick((): void => this.reload())
        }
        if (this.viewModel.error.length > 0) {
          Text(this.viewModel.error).fontColor($r('app.color.brand_warning'))
        }
        if (this.viewModel.annotationPlaybackState().length > 0) {
          Text(this.viewModel.annotationPlaybackState()).fontColor($r('app.color.brand_primary'))
          Button('停止播放').onClick((): void => this.viewModel.stopPlayback())
        }
        if (!this.loading && this.cache.summaries.length === 0) {
          Text('还没有每日总结').fontSize(18)
          Text('连接电脑并同步后，在这里查看事件及原始证据。离线时保留已同步内容。')
        }
        if (this.cache.summaries.length > 0) {
          Select(this.cache.summaries.map((s: PhoneDailySummary): SelectOption => ({ value: s.summary_date })))
            .value(this.date).onSelect((_index: number, value: string): void => {
              this.date = value; this.selectedEventId = ''; this.showSecondary = false;
            })
          if (this.summary()?.objective.semantic_status === 'complete') {
            Text(this.summary()?.objective.headline ?? '').fontSize(20).fontWeight(FontWeight.Bold)
            Text(this.summary()?.objective.overview ?? '').fontSize(15).width('100%')
          } else {
            Text('语义总结尚未生成').fontSize(20).fontWeight(FontWeight.Bold)
            Text('原始事件和录音证据已保留，等待电脑完成语义分析。').fontSize(15)
          }
          if (this.events().length !== (this.summary()?.objective.source_event_ids.length ?? 0)) {
            Text('部分事件已更新，等待同步对应总结；当前只展示版本一致的证据。')
              .fontColor($r('app.color.brand_warning'))
          }
          Text('主要事件').fontSize(18).fontWeight(FontWeight.Bold)
          ForEach(this.majorEvents(), (event: PhoneDailyEvent) => { this.eventCard(event) },
            (event: PhoneDailyEvent): string => `${event.event_id}:${event.revision}`)
          if (this.majorEvents().length === 0) {
            Text('暂无可展示的主要事件').fontColor($r('app.color.text_secondary'))
          }
          if (this.secondaryEvents().length > 0) {
            Button(this.showSecondary ? '收起其他事件' : `其他事件（${this.secondaryEvents().length}）`)
              .onClick((): void => { this.showSecondary = !this.showSecondary; })
            if (this.showSecondary) {
              ForEach(this.secondaryEvents(), (event: PhoneDailyEvent) => { this.eventCard(event) },
                (event: PhoneDailyEvent): string => `${event.event_id}:${event.revision}`)
            }
          }
          this.section('产生的待办', this.summary()?.objective.tasks_created ?? [])
          this.section('已完成', this.summary()?.objective.tasks_completed ?? [])
          this.section('待办', this.summary()?.objective.tasks_pending ?? [])
          Text('相关人物').fontSize(18).fontWeight(FontWeight.Bold)
          ForEach(this.supportedPeople(), (person: PhoneDailyParticipant) => {
            Text(person.label).fontSize(15)
          }, (person: PhoneDailyParticipant): string => person.key)
          if (this.hasUnknownPeople()) {
            Text('另有身份未确认的说话人，详情保留在事件证据中。').fontSize(15)
          }
          this.section('未解决事项', this.summary()?.objective.unresolved_items ?? [])
        }
        Button('刷新缓存').onClick((): void => this.reload())
      }.width('100%').padding(20).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
  }
}
