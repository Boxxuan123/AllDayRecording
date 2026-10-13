import { phoneV3PendingReviews } from '../domain/PhoneV3ReviewModels';
import { PhoneV3SessionCard, PhoneV3Reminder } from '../domain/PhoneV3Models';
import { PhoneDailyCache, PhoneDailySummary, phoneDailyDisplayText } from '../domain/PhoneV3DailyModels';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { PHONE_V3_UI_STATE_STORAGE_KEY, PhoneV3UiState } from './PhoneV3UiState';
import { phoneV3SessionTitle, phoneV3TranscriptSummary, phoneV3ReminderTime } from './PhoneV3UiFormat';
import { PHONE_V3_FLOATING_TAB_BAR_CONTENT_END_OFFSET } from './PhoneV3NativeUi';
@Component
export struct PhoneV3HomePage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  @Prop @Watch('loadDaily') stateRevision: number = 0;
  @State private cache: PhoneDailyCache = new PhoneDailyCache();
  @State private loading: boolean = true;
  @State private dailyError: string = '';
  private generation: number = 0;
  private dayClock: Date = new Date();
  @State private today: string = '';
  onOpenSession: (session: PhoneV3SessionCard) => void = (): void => {};
  onOpenReviews: () => void = (): void => {};
  onOpenRecall: () => void = (): void => {};
  onOpenTasks: () => void = (): void => {};
  onOpenDaily: () => void = (): void => {};
  onOpenSync: () => void = (): void => {};
  aboutToAppear(): void { this.loadDaily(); }
  aboutToDisappear(): void { this.generation++; }
  private current(): PhoneV3UiState { return AppStorage.get<PhoneV3UiState>(PHONE_V3_UI_STATE_STORAGE_KEY) ?? new PhoneV3UiState(); }
  private day(): string { return this.today; }
  private daily(): PhoneDailySummary | undefined { return this.cache.summaries.find((s: PhoneDailySummary): boolean => s.summary_date === this.day() && s.timezone === 'Asia/Singapore'); }
  private tasks(): Array<PhoneV3Reminder> { return this.current().snapshot.reminders.filter((r: PhoneV3Reminder): boolean => r.status === 'scheduled' || r.status === 'delivered').slice(0, 3); }
  private pending(): number { return phoneV3PendingReviews(this.current().snapshot.reviewItems).length + this.current().snapshot.conflicts.length; }
  private loadDaily(): void {
    this.dayClock.setTime(Date.now() + 8 * 3600000);
    this.today = this.dayClock.toISOString().slice(0, 10);
    const revision = ++this.generation;
    this.viewModel.loadDailyCache().then((cache: PhoneDailyCache): void => {
      if (revision === this.generation) { this.cache = cache; this.loading = false; this.dailyError = ''; }
    }).catch((error: Error): void => { if (revision === this.generation) { this.loading = false; this.dailyError = error.message; } });
  }
  @Builder private entry(title: string, detail: string, action: () => void) {
    Button({ type: ButtonType.ROUNDED_RECTANGLE }) {
      Column({ space: 5 }) { Text(title).fontSize(20).fontWeight(FontWeight.Bold); Text(detail).fontSize(12) }
        .width('100%').alignItems(HorizontalAlign.Start)
    }.layoutWeight(1).height(82).padding(14).backgroundColor($r('app.color.surface_accent'))
      .fontColor($r('app.color.brand_primary')).onClick(action)
  }
  @Builder private dailyCard() {
    Column({ space: 10 }) {
      Text('今日回顾').fontSize(19).fontWeight(FontWeight.Bold)
      if (this.loading) { Text('正在读取已同步回顾…').fontSize(14) }
      if (this.dailyError.length > 0) { Text(`回顾暂不可用：${this.dailyError}`).fontSize(13).fontColor($r('app.color.brand_warning')); Button('重新读取').height(44).onClick((): void => this.loadDaily()) }
      if (!this.loading && this.daily() === undefined) {
        Text('今日回顾尚未同步或生成').fontSize(15)
        Text('可浏览已有原文；连接电脑同步后再查看。').fontSize(13).fontColor($r('app.color.text_secondary'))
      }
      if (this.daily() !== undefined) {
        if (this.daily()?.objective.unified_review !== undefined) {
          if (this.daily()?.objective.unified_review?.status !== 'ready') { Text((this.daily()?.objective.unified_review?.claims.length??0)>0?'回顾未更新成功，以下为上次保存的内容。':'回顾暂不可用，已有原文仍可浏览。').fontSize(13).fontColor($r('app.color.brand_warning')) }
          Text(this.daily()?.objective.unified_review?.claims[0]?.text ?? '当前没有有依据的回顾条目').fontSize(15)
          if ((this.daily()?.objective.unified_review?.coverage.missing_sources.length ?? 0) > 0) { Text('部分来源未覆盖，不能据此认定今天的全部经历。').fontSize(13).fontColor($r('app.color.brand_warning')) }
        } else if (this.daily()?.objective.semantic_status === 'complete' && this.daily()?.derivation_status === 'active') {
          Text(phoneDailyDisplayText(this.daily()?.objective.headline ?? '', this.daily()?.objective.source_event_ids ?? [])).fontSize(16)
        } else { Text('归纳暂不可用或资料已更新，已有原文仍可浏览。').fontSize(14) }
        Text('回顾是模型归纳，需结合原文核对。').fontSize(12).fontColor($r('app.color.text_secondary'))
      }
      Button('查看回顾与依据').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(this.onOpenDaily)
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16).borderRadius(16).backgroundColor($r('app.color.surface_primary'))
  }
  build() {
    Scroll() {
      Column({ space: 16 }) {
        Text(this.day()).fontSize(13).fontColor($r('app.color.text_secondary'))
        Row({ space: 12 }) { this.entry('回忆', '找原话与事情进展', this.onOpenRecall); this.entry('事项', '处理提醒与跟进', this.onOpenTasks) }.width('100%')
        Column({ space: 10 }) {
          Text('值得关注 · 已确认提醒').fontSize(19).fontWeight(FontWeight.Bold)
          if (this.tasks().length === 0) { Text('当前没有已确认提醒；候选会先等待你判断。').fontSize(14).fontColor($r('app.color.text_secondary')) }
          ForEach(this.tasks(), (r: PhoneV3Reminder) => {
            Column({ space: 6 }) {
              Text(r.title).fontSize(16).fontWeight(FontWeight.Medium)
              Text(phoneV3ReminderTime(r)).fontSize(13)
              if (r.pendingAction.length > 0) { Text('操作已保存，等待同步确认').fontSize(12).fontColor($r('app.color.brand_warning')) }
              if (this.viewModel.calendarReminderState(r.eventId) !== 'scheduled') { Text('系统日历状态需在事项中核对').fontSize(12).fontColor($r('app.color.brand_warning')) }
            }.width('100%').alignItems(HorizontalAlign.Start).padding(8).onClick(this.onOpenTasks)
          }, (r: PhoneV3Reminder): string => r.eventId)
          Button('查看事项与原话').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(this.onOpenTasks)
        }.width('100%').alignItems(HorizontalAlign.Start).padding(16).borderRadius(16).backgroundColor($r('app.color.surface_primary'))
        this.dailyCard()
        if (this.pending() > 0) { Button(`${this.pending()} 项待判断或操作冲突`).height(48).onClick(this.onOpenReviews) }
        Text('最近记录').fontSize(19).fontWeight(FontWeight.Bold)
        ForEach(this.current().snapshot.sessions.slice(0, 3), (s: PhoneV3SessionCard) => {
          Button({ type: ButtonType.ROUNDED_RECTANGLE }) { Column({ space: 6 }) { Text(phoneV3SessionTitle(s)).fontSize(16); Text(phoneV3TranscriptSummary(s)).fontSize(12) }.width('100%').alignItems(HorizontalAlign.Start) }
            .width('100%').height(76).padding(14).backgroundColor($r('app.color.surface_primary')).fontColor($r('app.color.text_primary')).onClick((): void => this.onOpenSession(s))
        }, (s: PhoneV3SessionCard): string => s.sessionId)
        if (this.current().snapshot.sessions.length === 0) { Text(this.current().localReady ? '手机还没有录音，接收后可在这里回看。' : '正在读取本机记录…').fontSize(14) }
        Column({ space: 8 }) {
          Text(`手表：${this.current().device.watchStatus}`).fontSize(13)
          Text(`${this.current().snapshot.sync.pendingOperations} 项待同步 · ${this.current().device.watchSyncing ? '正在接收录音' : '接收状态见同步管理'}`).fontSize(12)
          Button(this.current().device.remoteRecordingState === 'recording' ? '停止录音并保存' : '开始录音').height(48)
            .enabled(!this.current().device.watchControlBusy && !this.current().device.receiverReconnecting)
            .onClick((): void => this.viewModel.requestWatchRecordingState(this.current().device.remoteRecordingState === 'recording' ? 'stopped' : 'recording'))
          Button('同步与备份管理').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(this.onOpenSync)
          if (this.current().error.length > 0) { Text(this.current().error).fontSize(13).fontColor($r('app.color.brand_warning')); if (this.viewModel.canRetry()) { Button('重试上次操作').height(44).onClick((): void => this.viewModel.retryLastAction()) } }
        }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor($r('app.color.surface_secondary')).borderRadius(16)
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 16, right: 16, top: 8 })
    }.width('100%').height('100%').align(Alignment.TopStart).contentEndOffset(PHONE_V3_FLOATING_TAB_BAR_CONTENT_END_OFFSET).backgroundColor($r('app.color.page_background'))
  }
}
