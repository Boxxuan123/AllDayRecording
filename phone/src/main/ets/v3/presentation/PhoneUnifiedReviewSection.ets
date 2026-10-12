import { PhoneUnifiedReview, PhoneUnifiedClaim, PhoneUnifiedEvidence, PhoneUnifiedRef, unifiedEvidenceForClaim, unifiedRecordingEvidence, visibleUnifiedSections, unifiedRecordingIdentity, UNIFIED_COVERAGE_EXPLANATION } from '../domain/PhoneUnifiedReview';
import { ChatFollowup } from '../domain/PhoneChatFollowup';
import { PhoneV3Reminder } from '../domain/PhoneV3Models';
import { PhoneV3SessionCard } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { PhoneV3ChatFollowupsSection } from './PhoneV3ChatFollowupsSection';
import { PhoneV3RemindersPage } from './PhoneV3RemindersPage';

@Component
export struct PhoneUnifiedReviewSection {
  @ObjectLink viewModel: PhoneV3ViewModel;
  @Prop review: PhoneUnifiedReview | undefined = undefined;
  @State private selected: string = '';
  @State private taskId: string = '';
  @State private showTask: boolean = false;
  onOpenSession: (session: PhoneV3SessionCard) => void = (): void => {};
  private label(section: string): string { return section === 'activity' ? '今天涉及的重要事情和讨论' : section === 'followup' ? '承诺、进展与待跟进' : '今天与重要人物的互动'; }
  private perspective(value: string): string { return value === 'self' ? '本人' : value === 'other' ? '他人' : value === 'observed' ? '听到／看到的内容' : '身份未确认'; }
  private sources(claim: PhoneUnifiedClaim): Array<PhoneUnifiedEvidence> { return this.review === undefined ? [] : unifiedEvidenceForClaim(this.review,claim); }
  private openSource(e: PhoneUnifiedEvidence): void {
    const session = this.viewModel.snapshot.sessions.find((s: PhoneV3SessionCard): boolean => s.sessionId === e.session_id);
    if(session !== undefined) { this.onOpenSession(session); }
  }
  private play(e: PhoneUnifiedEvidence): void { const recording = unifiedRecordingEvidence(e); if(recording !== undefined) { this.viewModel.playDailyEvidence(recording); } }
  @Builder private taskSheet() {
    Column({ space: 12 }) {
      Button('关闭事项详情').onClick((): void => { this.showTask = false; })
      if(this.viewModel.snapshot.chatFollowups.some((t: ChatFollowup): boolean => t.event_id === this.taskId)) {
        PhoneV3ChatFollowupsSection({ viewModel:this.viewModel, eventId:this.taskId })
      } else if(this.viewModel.snapshot.reminders.some((t: PhoneV3Reminder): boolean => t.eventId === this.taskId)) {
        PhoneV3RemindersPage({ viewModel:this.viewModel, eventId:this.taskId, onOpenSession:this.onOpenSession })
      } else { Text('该关联事项尚未同步到手机，请连接电脑同步后查看。') }
    }.width('100%').padding(16)
  }
  @Builder private claimCard(claim: PhoneUnifiedClaim, key: string) {
    Column({ space: 8 }) {
      Text(`【${this.perspective(claim.perspective)}】${claim.certainty === 'uncertain' ? '【不确定】' : ''}${claim.text}`)
        .width('100%').fontSize(15)
        .onClick((): void => { this.selected = this.selected === key ? '' : key; })
      Button(this.selected === key ? '收起依据' : '查看依据')
        .onClick((): void => { this.selected = this.selected === key ? '' : key; })
      if(this.selected === key) {
        ForEach(this.sources(claim), (e: PhoneUnifiedEvidence) => {
          Column({ space: 6 }) {
            Text(`${e.source_type === 'chat' ? '聊天 · '+e.platform+' · '+(e.speaker ?? '身份未确认') : '录音转写 · '+unifiedRecordingIdentity(e)} · ${e.sent_at === undefined ? e.start_at ?? '' : new Date(e.sent_at*1000).toLocaleString()} · 原文修订 ${e.revision}`).fontSize(12)
            ForEach(claim.evidence.filter((r: PhoneUnifiedRef): boolean => r.evidence_id === e.evidence_id), (r: PhoneUnifiedRef) => { Text(`原话：${r.quote}`).fontSize(15) }, (r: PhoneUnifiedRef): string => r.evidence_id)
            Text(e.text).fontSize(14)
            if(e.context !== undefined && JSON.stringify(e.context) !== '{}') { Text(`引用／回复上下文：${JSON.stringify(e.context)}`).fontSize(12) }
            if(e.source_type === 'recording') {
              Button('播放引用片段').onClick((): void => this.play(e))
              Button('打开录音转写').enabled(this.viewModel.snapshot.sessions.some((s: PhoneV3SessionCard): boolean => s.sessionId === e.session_id)).onClick((): void => this.openSource(e))
            }
          }.width('100%').alignItems(HorizontalAlign.Start).padding(8)
        }, (e: PhoneUnifiedEvidence): string => e.evidence_id)
        ForEach(claim.event_ids, (id: string) => { Button('打开关联事项').onClick((): void => { this.taskId = id; this.showTask = true; }) }, (id: string): string => id)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  build() {
    Column({ space: 12 }) {
      Text('聊天＋录音 · 每日回顾').fontSize(20).fontWeight(FontWeight.Bold)
      if(this.review !== undefined) {
        Text(`${this.review.date} · ${this.review.timezone} · 生成于 ${this.review.generated_at ?? '尚未完成'}`).fontSize(13)
        if(this.review.revised_at !== undefined) { Text(`修订于 ${this.review.revised_at}`).fontSize(13) }
        if(this.review.status !== 'ready') { Text(`当前状态：${this.review.status === 'failed' ? '本次生成失败，保留上次内容' : '资料已更新，保留上次内容'}。${this.review.error ?? ''}`).fontColor($r('app.color.brand_warning')) }
        ForEach(visibleUnifiedSections(this.review), (section: string) => {
          Text(this.label(section)).fontSize(18).fontWeight(FontWeight.Bold)
          ForEach(this.review?.claims.filter((c: PhoneUnifiedClaim): boolean => c.section === section) ?? [], (claim: PhoneUnifiedClaim, index: number) => { this.claimCard(claim,`${this.review?.date}:${section}:${index}`) }, (claim: PhoneUnifiedClaim): string => claim.text)
        }, (section: string): string => section)
        Text('资料覆盖与不确定性').fontSize(18).fontWeight(FontWeight.Bold)
        Text(`聊天缓存 ${this.review.coverage.chat_records_in_day} 条，选取相关互动及上下文 ${this.review.coverage.chat_records_selected} 条；录音 ${this.review.coverage.recording_events} 个事件、${this.review.coverage.recording_evidence} 段转写。`).fontSize(13)
        Text(`${this.review.coverage.period_start} 至 ${this.review.coverage.period_end}。${this.review.coverage.scope}`).fontSize(12)
        if(this.review.coverage.missing_sources.length > 0) { Text(`缺少来源：${this.review.coverage.missing_sources.join('、')}`).fontSize(13) }
        Text(UNIFIED_COVERAGE_EXPLANATION).fontSize(12)
        ForEach(this.review.limitations, (line: string) => { Text(line).fontSize(13) }, (line: string): string => line)
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
      .bindSheet(this.showTask, this.taskSheet())
  }
}
