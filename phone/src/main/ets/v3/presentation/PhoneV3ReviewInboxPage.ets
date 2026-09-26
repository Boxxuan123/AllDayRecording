import { phoneV3VoiceTasks } from '../domain/PhoneV3VoiceReviewTask';
import { phoneV3PendingReviews } from '../domain/PhoneV3ReviewModels';
import { PhoneV3AnnotationConflictPanel } from './PhoneV3AnnotationConflictPanel';
import { PhoneV3Conflict, PhoneV3ReviewItem, PhoneV3SessionCard } from '../domain/PhoneV3Models';
import {
  phoneV3ReviewReason,
  phoneV3VoiceCandidates,
  phoneV3VoiceMode
} from '../domain/PhoneV3ReviewModels';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { phoneV3SessionTitle } from './PhoneV3UiFormat';
import { PHONE_V3_UI_STATE_STORAGE_KEY, PhoneV3UiState } from './PhoneV3UiState';
import { PHONE_V3_BACKUP_ACTION_CONTENT_END_OFFSET } from './PhoneV3NativeUi';

class PhoneV3ReviewGroup {
  key: string;
  label: string;
  items: Array<PhoneV3ReviewItem>;

  constructor(key: string, label: string, items: Array<PhoneV3ReviewItem>) {
    this.key = key;
    this.label = label;
    this.items = items;
  }
}

@Component
export struct PhoneV3ReviewInboxPage {
  onOpenVoice: (reviewId: string, history: boolean) => void = (): void => {};
  viewModel: PhoneV3ViewModel = new PhoneV3ViewModel();
  @Prop stateRevision: number = 0;
  @State private selectedFilter: number = 0;
  @State private groupMode: number = 0;
  onOpenSession: (session: PhoneV3SessionCard) => void = (_session: PhoneV3SessionCard): void => {};

  private currentUiState(): PhoneV3UiState {
    const state = AppStorage.get<PhoneV3UiState>(PHONE_V3_UI_STATE_STORAGE_KEY);
    return this.stateRevision >= 0 && state !== undefined ? state : new PhoneV3UiState();
  }

  aboutToDisappear(): void {
    this.viewModel.stopPlayback();
  }

  private annotationConflicts(): Array<PhoneV3Conflict> {
    return this.selectedFilter > 1 ? [] : this.currentUiState().snapshot.conflicts.filter(
      (value: PhoneV3Conflict): boolean => ['speaker.assign', 'segment.classify'].indexOf(value.kind) >= 0);
  }

  private visibleReviews(): Array<PhoneV3ReviewItem> {
    return phoneV3PendingReviews(this.currentUiState().snapshot.reviewItems, this.selectedFilter);
  }

  private groupedReviews(): Array<PhoneV3ReviewGroup> {
    const groups: Array<PhoneV3ReviewGroup> = [];
    const items = this.visibleReviews();
    for (let index = 0; index < items.length; index += 1) {
      const item = items[index];
      const key = this.groupMode === 0 ? `session:${item.sessionId ?? 'none'}` :
        `person:${item.personId ?? 'none'}`;
      let group = groups.find((value: PhoneV3ReviewGroup): boolean => value.key === key);
      if (group === undefined) {
        group = new PhoneV3ReviewGroup(key, this.reviewGroupLabel(item), []);
        groups.push(group);
      }
      group.items.push(item);
    }
    return groups;
  }

  private reviewGroupLabel(item: PhoneV3ReviewItem): string {
    if (this.groupMode === 0) {
      const session = this.matchingSession(item.sessionId);
      if (session !== undefined) {
        return phoneV3SessionTitle(session);
      }
      return item.sessionId === null ? '跨录音判断' : `录音 ${item.sessionId.substring(0, 8)}`;
    }
    if (item.personId === 'self') {
      return '我';
    }
    if (item.personId === null) {
      return '未识别人物';
    }
    if (item.kind === 'voice_identity' || item.kind === 'person_memory') {
      return item.title;
    }
    return `人物 ${item.personId.substring(0, 8)}`;
  }

  private kindLabel(kind: string): string {
    switch (kind) {
      case 'voice_identity': return '声音身份';
      case 'reminder': return '提醒确认';
      case 'person_memory': return '人物记忆';
      case 'knowledge_proposal': return '事件提案';
      default: return '人工判断';
    }
  }

  private matchingSession(sessionId: string | null): PhoneV3SessionCard | undefined {
    if (sessionId === null) {
      return undefined;
    }
    return this.currentUiState().snapshot.sessions.find((session: PhoneV3SessionCard): boolean =>
      session.sessionId === sessionId);
  }

  @Builder
  private filterButton(index: number, label: string) {
    Button(label, { type: ButtonType.Normal })
      .layoutWeight(1)
      .height(38)
      .fontSize(13)
      .fontWeight(this.selectedFilter === index ? FontWeight.Medium : FontWeight.Regular)
      .fontColor(this.selectedFilter === index ? Color.White : $r('app.color.text_secondary'))
      .backgroundColor(this.selectedFilter === index ? $r('app.color.brand_primary') : Color.Transparent)
      .borderRadius(19)
      .onClick((): void => {
        this.selectedFilter = index;
      })
  }

  @Builder
  private groupButton(index: number, label: string) {
    Button(label, { type: ButtonType.Normal })
      .height(34)
      .fontSize(12)
      .fontColor(this.groupMode === index ? $r('app.color.brand_primary') : $r('app.color.text_secondary'))
      .backgroundColor(Color.Transparent)
      .onClick((): void => {
        this.groupMode = index;
      })
  }

  @Builder
  private decisionButton(label: string, emphasized: boolean, enabled: boolean, action: () => void) {
    Button(label, { type: ButtonType.Capsule })
      .layoutWeight(1)
      .height(40)
      .fontSize(13)
      .buttonStyle(emphasized ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
      .enabled(enabled && !this.currentUiState().busy)
      .onClick(action)
  }

  @Builder
  private standardActions(item: PhoneV3ReviewItem) {
    Row({ space: 8 }) {
      if (item.kind === 'reminder') {
        this.decisionButton('创建提醒', true, true, (): void =>
          this.viewModel.resolveReview(item.reviewId, 'confirm'))
        this.decisionButton('不提醒', false, true, (): void =>
          this.viewModel.resolveReview(item.reviewId, 'ignore'))
      } else if (item.kind === 'person_memory') {
        this.decisionButton('记住', true, true, (): void =>
          this.viewModel.resolveReview(item.reviewId, 'confirm'))
        this.decisionButton('不记住', false, true, (): void =>
          this.viewModel.resolveReview(item.reviewId, 'reject'))
      } else if (item.kind === 'knowledge_proposal') {
        this.decisionButton('确认事件', true, true, (): void =>
          this.viewModel.resolveReview(item.reviewId, 'confirm'))
        this.decisionButton('拒绝提案', false, true, (): void =>
          this.viewModel.resolveReview(item.reviewId, 'reject'))
      }
    }
    .width('100%')
  }

  @Builder
  private reviewCard(item: PhoneV3ReviewItem) {
    if (item.kind === 'voice_identity') {
      Column({ space: 8 }) {
        Text(phoneV3VoiceMode(item) === 'speaker_discovery' ? '这是谁的声音？' : '核对声音样本').fontSize(13).fontColor($r('app.color.text_secondary'))
        Text(item.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Text(`${this.reviewGroupLabel(item)} · ${phoneV3VoiceCandidates(item).length} 个待核对样本`).fontSize(13).fontColor($r('app.color.text_secondary'))
        Button(phoneV3VoiceCandidates(item).length > 0 ? '进入核对' : '暂无可用样本 · 查看状态').buttonStyle(ButtonStyleMode.NORMAL).width('100%')
          .onClick((): void => this.onOpenVoice(item.reviewId, false))
      }.width('100%').padding(16).alignItems(HorizontalAlign.Start).borderRadius(16).backgroundColor($r('app.color.surface_primary'))
    } else {

    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text(this.kindLabel(item.kind))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(item.priority === 'high' ? $r('app.color.brand_warning') : $r('app.color.brand_primary'))
        Blank()
        Text(item.evidenceCount > 0 ? `${item.evidenceCount} 条依据` : '等待判断')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')

      Text(item.title)
        .width('100%')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
      Text(item.summary)
        .width('100%')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(4)
      Text(phoneV3ReviewReason(item.reason))
        .width('100%')
        .fontSize(12)
        .fontColor($r('app.color.brand_warning'))

      if (this.viewModel.reviewSubmissionState(item.reviewId)) {
        Text(this.viewModel.reviewSubmissionMessage(item.reviewId)).fontSize(13).fontColor($r('app.color.brand_warning'))
        Button('核对此项审核结果').buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.currentUiState().busy)
          .onClick((): void => this.viewModel.refreshVoiceReviews())
      } else { this.standardActions(item) }
      if (this.matchingSession(item.sessionId) !== undefined) {
        Button('查看原录音', { type: ButtonType.Capsule })
          .width('100%')
          .height(40)
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .onClick((): void => this.onOpenSession(
            this.matchingSession(item.sessionId) as PhoneV3SessionCard))
      }
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.surface_primary'))
    .borderRadius(16)
    }
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 2 }) {
        this.filterButton(0, '全部')
        this.filterButton(1, '声音')
        this.filterButton(2, '提醒')
        this.filterButton(3, '记忆')
      }
      .width('100%')
      .padding(3)
      .borderRadius(22)
      .backgroundColor($r('app.color.surface_secondary'))

      Row({ space: 4 }) {
        Text('分组')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
        Blank()
        this.groupButton(0, '按录音')
        this.groupButton(1, '按人物')
      }
      .width('100%')

      Row() {
        Text(`当前缓存 · ${this.visibleReviews().length + this.annotationConflicts().length} 个任务`).fontSize(12).layoutWeight(1).fontColor($r('app.color.text_secondary'))
        Button(`已采纳样本 ${phoneV3VoiceTasks(this.currentUiState().snapshot.reviewItems, true).length}`)
          .buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(13).onClick((): void => this.onOpenVoice('', true))
      }.width('100%')
      Scroll() {
        Column({ space: 10 }) {
          ForEach(this.annotationConflicts(), (conflict: PhoneV3Conflict) => {
            PhoneV3AnnotationConflictPanel({ viewModel: this.viewModel, conflict: conflict, stateRevision: this.stateRevision })
          }, (conflict: PhoneV3Conflict): string => conflict.operationId)
          if (this.visibleReviews().length === 0 && this.annotationConflicts().length === 0) {
            Column({ space: 8 }) {
              Text('当前缓存没有待处理任务')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('此处仅显示已同步到手机的任务，可连接电脑刷新。')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .padding(18)
            .alignItems(HorizontalAlign.Start)
            .backgroundColor($r('app.color.surface_primary'))
            .borderRadius(16)
          } else {
            ForEach(this.groupedReviews(), (group: PhoneV3ReviewGroup) => {
              Column({ space: 8 }) {
                Row() {
                  Text(group.label)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                  Blank()
                  Text(`${group.items.length} 个任务组`)
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                }
                .width('100%')
                ForEach(group.items, (item: PhoneV3ReviewItem) => {
                  this.reviewCard(item)
                }, (item: PhoneV3ReviewItem): string => `${JSON.stringify(item)}:${this.viewModel.reviewSubmissionState(item.reviewId)}`)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }, (group: PhoneV3ReviewGroup): string => `${group.key}:${JSON.stringify(group.items)}:${group.items.map((item: PhoneV3ReviewItem): string => this.viewModel.reviewSubmissionState(item.reviewId)).join()}`)
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Start)
        .align(Alignment.TopStart)
      }
      .width('100%')
      .layoutWeight(1)
      .contentEndOffset(PHONE_V3_BACKUP_ACTION_CONTENT_END_OFFSET)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 8 })
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Start)
    .align(Alignment.TopStart)
    .backgroundColor($r('app.color.page_background'))
  }
}
