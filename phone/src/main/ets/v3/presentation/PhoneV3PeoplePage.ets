import { PhoneV3SessionCard, PhoneV3Utterance } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { PHONE_V3_UI_STATE_STORAGE_KEY, PhoneV3UiState } from './PhoneV3UiState';
import { PHONE_V3_BACKUP_ACTION_CONTENT_END_OFFSET } from './PhoneV3NativeUi';

class PhoneV3SpeakerSummary {
  key: string;
  label: string;
  utteranceCount: number;
  sessionIds: Array<string>;

  constructor(key: string, label: string, utteranceCount: number = 0,
    sessionIds: Array<string> = []) {
    this.key = key;
    this.label = label;
    this.utteranceCount = utteranceCount;
    this.sessionIds = sessionIds;
  }
}

@Component
export struct PhoneV3PeoplePage {
  viewModel: PhoneV3ViewModel = new PhoneV3ViewModel();
  @Prop stateRevision: number = 0;
  onOpenSession: (session: PhoneV3SessionCard) => void = (_session: PhoneV3SessionCard): void => {};
  onOpenReviews: () => void = (): void => {};

  private currentUiState(): PhoneV3UiState {
    const state = AppStorage.get<PhoneV3UiState>(PHONE_V3_UI_STATE_STORAGE_KEY);
    return this.stateRevision >= 0 && state !== undefined ? state : new PhoneV3UiState();
  }

  private summaries(): Array<PhoneV3SpeakerSummary> {
    const values: Map<string, PhoneV3SpeakerSummary> = new Map<string, PhoneV3SpeakerSummary>();
    for (let sessionIndex = 0; sessionIndex < this.currentUiState().snapshot.sessions.length; sessionIndex += 1) {
      const session = this.currentUiState().snapshot.sessions[sessionIndex];
      for (let utteranceIndex = 0; utteranceIndex < session.utterances.length; utteranceIndex += 1) {
        const utterance = session.utterances[utteranceIndex];
        const speakerKey = this.speakerKey(utterance);
        const key = speakerKey === 'self' ? 'self' : `${session.id}:${speakerKey}`;
        const label = utterance.identity === 'self' ? '本人' :
          utterance.speakerLabel === null ? '未指定说话人' : utterance.speakerLabel;
        const current = values.get(key) ?? new PhoneV3SpeakerSummary(key, label);
        current.utteranceCount += 1;
        if (current.sessionIds.indexOf(session.id) < 0) {
          current.sessionIds.push(session.id);
        }
        values.set(key, current);
      }
    }
    const result = Array.from(values.values());
    result.sort((left: PhoneV3SpeakerSummary, right: PhoneV3SpeakerSummary): number => {
      if (left.label === '本人') {
        return -1;
      }
      if (right.label === '本人') {
        return 1;
      }
      return right.utteranceCount - left.utteranceCount;
    });
    return result;
  }

  private speakerKey(utterance: PhoneV3Utterance): string {
    if (utterance.identity === 'self') {
      return 'self';
    }
    return utterance.speakerTrackId ?? utterance.speakerLabel ?? 'unassigned';
  }

  private sessionFor(summary: PhoneV3SpeakerSummary): PhoneV3SessionCard | undefined {
    if (summary.sessionIds.length === 0) {
      return undefined;
    }
    return this.currentUiState().snapshot.sessions.find((session: PhoneV3SessionCard): boolean =>
      session.id === summary.sessionIds[0]);
  }

  private pendingPeopleReviews(): number {
    return this.currentUiState().snapshot.reviewItems.filter((item): boolean =>
      item.kind === 'voice_identity' || item.kind === 'person_memory').length;
  }

  @Builder
  private personRow(summary: PhoneV3SpeakerSummary) {
    Row({ space: 12 }) {
      Stack() {
        Text(summary.label.slice(0, 1))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.brand_primary'))
      }
      .width(44)
      .height(44)
      .borderRadius(14)
      .backgroundColor($r('app.color.surface_accent'))
      Column({ space: 4 }) {
        Text(summary.label)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text(`${summary.sessionIds.length} 段录音 · ${summary.utteranceCount} 条发言`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(17)
        .fontColor([$r('app.color.text_secondary')])
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.surface_primary'))
    .borderRadius(14)
    .onClick((): void => {
      const session = this.sessionFor(summary);
      if (session !== undefined) {
        this.onOpenSession(session);
      }
    })
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        if (this.pendingPeopleReviews() > 0) {
          Row({ space: 10 }) {
            Column({ space: 4 }) {
              Text(`${this.pendingPeopleReviews()} 项人物审核`)
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('包含声音身份与人物记忆')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Button('去审核', { type: ButtonType.Capsule })
              .height(40)
              .buttonStyle(ButtonStyleMode.EMPHASIZED)
              .onClick((): void => this.onOpenReviews())
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.surface_progress'))
          .borderRadius(16)
        }

        Text('说话人')
          .width('100%')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        if (this.summaries().length === 0) {
          Text('同步电脑转写后，会在这里汇总已识别和未知说话人。')
            .width('100%')
            .padding(18)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor($r('app.color.surface_primary'))
            .borderRadius(16)
        } else {
          ForEach(this.summaries(), (summary: PhoneV3SpeakerSummary) => {
            this.personRow(summary)
          }, (summary: PhoneV3SpeakerSummary): string => summary.key)
        }

        Text('人物资料、跨天记忆和关系观察将在对应投影同步后继续出现在人物详情中。')
          .width('100%')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .padding({ top: 4 })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8 })
      .alignItems(HorizontalAlign.Start)
    }
    .contentEndOffset(PHONE_V3_BACKUP_ACTION_CONTENT_END_OFFSET)
    .align(Alignment.TopStart)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
