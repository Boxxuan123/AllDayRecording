import { PhoneV3ReviewItem, PhoneV3SessionCard } from '../domain/PhoneV3Models';
import {
  PhoneV3VoiceCandidate,
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
  viewModel: PhoneV3ViewModel = new PhoneV3ViewModel();
  @Prop stateRevision: number = 0;
  @State private selectedFilter: number = 0;
  @State private groupMode: number = 0;
  @State private expandedReviewIds: Array<string> = [];
  @State private discoveryName: string = '';
  @State private heardReviewSampleKeys: Array<string> = [];
  onOpenSession: (session: PhoneV3SessionCard) => void = (_session: PhoneV3SessionCard): void => {};

  private currentUiState(): PhoneV3UiState {
    const state = AppStorage.get<PhoneV3UiState>(PHONE_V3_UI_STATE_STORAGE_KEY);
    return this.stateRevision >= 0 && state !== undefined ? state : new PhoneV3UiState();
  }

  private reviewSampleKey(reviewId: string, prototypeId: string): string {
    return `${reviewId}:${prototypeId}`;
  }

  private reviewSampleWasPlayed(reviewId: string, prototypeId: string): boolean {
    const key = this.reviewSampleKey(reviewId, prototypeId);
    return this.heardReviewSampleKeys.indexOf(key) >= 0 ||
      this.viewModel.reviewSampleWasPlayed(reviewId, prototypeId);
  }

  private markReviewSamplePlayed(reviewId: string, prototypeId: string): void {
    const key = this.reviewSampleKey(reviewId, prototypeId);
    if (this.heardReviewSampleKeys.indexOf(key) < 0) {
      this.heardReviewSampleKeys = this.heardReviewSampleKeys.concat([key]);
    }
  }

  private visibleReviews(): Array<PhoneV3ReviewItem> {
    const items = this.currentUiState().snapshot.reviewItems;
    if (this.selectedFilter === 0) {
      return items;
    }
    if (this.selectedFilter === 1) {
      return items.filter((item: PhoneV3ReviewItem): boolean => item.kind === 'voice_identity');
    }
    if (this.selectedFilter === 2) {
      return items.filter((item: PhoneV3ReviewItem): boolean => item.kind === 'reminder');
    }
    return items.filter((item: PhoneV3ReviewItem): boolean =>
      item.kind === 'person_memory' || item.kind === 'knowledge_proposal');
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

  private isExpanded(reviewId: string): boolean {
    return this.expandedReviewIds.indexOf(reviewId) >= 0;
  }

  private toggleExpanded(reviewId: string): void {
    if (this.isExpanded(reviewId)) {
      this.expandedReviewIds = this.expandedReviewIds.filter((value: string): boolean => value !== reviewId);
      return;
    }
    this.expandedReviewIds = this.expandedReviewIds.concat([reviewId]);
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
  private voiceDecisionButton(label: string, emphasized: boolean, reviewId: string,
    prototypeId: string, action: () => void) {
    Button(label, { type: ButtonType.Capsule })
      .layoutWeight(1)
      .height(40)
      .fontSize(13)
      .buttonStyle(emphasized ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
      .enabled(this.reviewSampleWasPlayed(reviewId, prototypeId) && !this.currentUiState().busy)
      .onClick(action)
  }

  @Builder
  private voiceCandidateCard(item: PhoneV3ReviewItem, candidate: PhoneV3VoiceCandidate) {
    Column({ space: 9 }) {
      Row() {
        Column({ space: 3 }) {
          Text(`样本 ${candidate.prototypeId.substring(0, 8)}`)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(candidate.bestScore === null ? '匹配分未知' :
            `匹配 ${Math.round(candidate.bestScore * 100)}% · 质量 ${candidate.qualityScore === null ?
              '未知' : Math.round(candidate.qualityScore * 100) + '%'}`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (this.reviewSampleWasPlayed(item.reviewId, candidate.prototypeId)) {
          Text('已听')
            .fontSize(12)
            .fontColor($r('app.color.brand_primary'))
        }
      }
      .width('100%')

      Button(candidate.hasAudio ? '播放这条样本' : '没有可播放的样本', { type: ButtonType.Capsule })
        .width('100%')
        .height(40)
        .buttonStyle(ButtonStyleMode.NORMAL)
        .enabled(candidate.hasAudio && !this.currentUiState().busy)
        .onClick((): void => this.viewModel.playReviewSample(item.reviewId, candidate.prototypeId,
          (): void => this.markReviewSamplePlayed(item.reviewId, candidate.prototypeId)))

      Row({ space: 8 }) {
        this.voiceDecisionButton('确认是他', true, item.reviewId, candidate.prototypeId, (): void =>
          this.viewModel.resolveReview(item.reviewId, 'confirm', candidate.prototypeId))
        this.voiceDecisionButton('不是他', false, item.reviewId, candidate.prototypeId, (): void =>
          this.viewModel.resolveReview(item.reviewId, 'reject', candidate.prototypeId))
        this.decisionButton('暂不确定', false, true, (): void =>
          this.viewModel.resolveReview(item.reviewId, 'uncertain', candidate.prototypeId))
      }
      .width('100%')

      if (!this.reviewSampleWasPlayed(item.reviewId, candidate.prototypeId)) {
        Text('播放实际开始后，才会解锁“确认是他”和“不是他”。')
          .width('100%')
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .width('100%')
    .padding(12)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.surface_secondary'))
    .borderRadius(12)
  }

  @Builder
  private knownVoiceActions(item: PhoneV3ReviewItem) {
    Column({ space: 10 }) {
      Button(this.isExpanded(item.reviewId) ? '收起样本' :
        `核对 ${phoneV3VoiceCandidates(item).length} 个样本`, { type: ButtonType.Capsule })
        .width('100%')
        .height(42)
        .buttonStyle(ButtonStyleMode.NORMAL)
        .onClick((): void => this.toggleExpanded(item.reviewId))
      if (this.isExpanded(item.reviewId)) {
        Text('样本按把握较弱的优先排列。每条都独立判断，不提供整组确认。')
          .width('100%')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
        ForEach(phoneV3VoiceCandidates(item), (candidate: PhoneV3VoiceCandidate) => {
          this.voiceCandidateCard(item, candidate)
        }, (candidate: PhoneV3VoiceCandidate): string => candidate.prototypeId)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private discoveryActions(item: PhoneV3ReviewItem) {
    Column({ space: 9 }) {
      TextInput({ text: this.discoveryName, placeholder: '输入人物姓名' })
        .width('100%')
        .height(42)
        .onChange((value: string): void => {
          this.discoveryName = value;
        })
      Row({ space: 8 }) {
        this.decisionButton('创建并关联人物', true, this.discoveryName.trim().length > 0, (): void =>
          this.viewModel.resolveReview(item.reviewId, 'create_person', '', this.discoveryName,
            (): void => {
              this.discoveryName = '';
            }))
        this.decisionButton('忽略这个声音', false, true, (): void =>
          this.viewModel.resolveReview(item.reviewId, 'ignore'))
      }
      .width('100%')
    }
    .width('100%')
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

      if (item.kind === 'voice_identity' && phoneV3VoiceMode(item) === 'known_person') {
        this.knownVoiceActions(item)
      } else if (item.kind === 'voice_identity' && phoneV3VoiceMode(item) === 'speaker_discovery') {
        this.discoveryActions(item)
      } else {
        this.standardActions(item)
      }

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

      Scroll() {
        Column({ space: 10 }) {
          if (this.visibleReviews().length === 0) {
            Column({ space: 8 }) {
              Text('当前没有需要你判断的项目')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('只有会改变提醒、长期记忆、事件或人物身份的项目才会进入这里。')
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
                  Text(`${group.items.length} 项`)
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                }
                .width('100%')
                ForEach(group.items, (item: PhoneV3ReviewItem) => {
                  this.reviewCard(item)
                }, (item: PhoneV3ReviewItem): string => item.reviewId)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }, (group: PhoneV3ReviewGroup): string => group.key)
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
