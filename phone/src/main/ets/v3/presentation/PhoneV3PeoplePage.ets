import { phoneV3PendingReviews } from '../domain/PhoneV3ReviewModels';
import { PhoneV3SessionCard, PhoneV3Utterance } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { PHONE_V3_UI_STATE_STORAGE_KEY, PhoneV3UiState } from './PhoneV3UiState';
import { PHONE_V3_BACKUP_ACTION_CONTENT_END_OFFSET } from './PhoneV3NativeUi';

class PhoneV3SpeakerSummary {
  key: string;
  label: string;
  known: boolean;
  subtitle: string;
  rows: Array<PhoneV3Utterance> = [];
  constructor(key: string, label: string, known: boolean, subtitle: string) {
    this.key = key; this.label = label; this.known = known; this.subtitle = subtitle;
  }
}

@Component
export struct PhoneV3PeoplePage {
  onOpenAnnotation: (rows: Array<PhoneV3Utterance>, title: string) => void = (): void => {};
  @ObjectLink viewModel: PhoneV3ViewModel;
  @Prop stateRevision: number = 0;
  onOpenReviews: () => void = (): void => {};
  onOpenSession: (session: PhoneV3SessionCard) => void = (): void => {};
  private summarySessions: Array<PhoneV3SessionCard> | undefined = undefined;
  private summaryRows: Array<PhoneV3SpeakerSummary> = [];
  private currentUiState(): PhoneV3UiState {
    if (this.stateRevision < 0) { return new PhoneV3UiState(); }
    return AppStorage.get<PhoneV3UiState>(PHONE_V3_UI_STATE_STORAGE_KEY) ?? new PhoneV3UiState();
  }
  private summaries(known: boolean): Array<PhoneV3SpeakerSummary> {
    const sessions = this.currentUiState().snapshot.sessions;
    if (sessions !== this.summarySessions) {
      this.summarySessions = sessions;
      const groups = new Map<string, PhoneV3SpeakerSummary>();
      for (let session of sessions) {
        for (let row of session.utterances) {
          const person = row.annotationPersonId.length > 0;
          const key = person ? `person:${row.annotationPersonId}` : `sound:${session.id}:${row.speakerTrackId ?? row.utteranceId}`;
          const label = person ? row.speakerLabel ?? '已确认人物' : row.speakerTrackId ? `声音 ${row.originalSpeakerLabel || row.speakerTrackId}` : '未分组声音';
          const group = groups.get(key) ?? new PhoneV3SpeakerSummary(key, label, person, row.startAt.slice(0, 10));
          group.rows.push(row); groups.set(key, group);
        }
      }
      this.summaryRows = Array.from(groups.values());
    }
    return this.summaryRows.filter((group: PhoneV3SpeakerSummary): boolean => group.known === known);
  }

  private pendingPeopleReviews(): number {
    return phoneV3PendingReviews(this.currentUiState().snapshot.reviewItems).filter((item): boolean =>
      item.kind === 'voice_identity' || item.kind === 'person_memory').length;
  }

  @Builder
  private personRow(group: PhoneV3SpeakerSummary) {
    Row({ space: 12 }) {
      Text(group.known ? group.label.slice(0, 1) : '声').fontSize(17).fontColor($r('app.color.text_secondary'))
        .width(40).height(40).textAlign(TextAlign.Center).borderRadius(20).backgroundColor($r('app.color.surface_secondary'))
      Column({ space: 4 }) {
        Text(group.label).fontSize(16).fontColor($r('app.color.text_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(group.known ? `${group.rows.length} 条发言` : `${group.subtitle} · ${group.rows.length} 条片段`)
          .fontSize(13).fontColor($r('app.color.text_secondary')).maxLines(1)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_secondary')])
    }.width('100%').constraintSize({ minHeight: 64 }).padding({ top: 10, bottom: 10 })
      .onClick((): void => {
        const current = this.summaries(group.known).find((value: PhoneV3SpeakerSummary): boolean => value.key === group.key);
        if (current !== undefined) { this.onOpenAnnotation(current.rows, current.label); }
      })
  }
  build() {
    List({ space: 4 }) {
      if (this.pendingPeopleReviews() > 0) {
        ListItem() {
          Row() {
            Text(`人物审核 · ${this.pendingPeopleReviews()}`).fontSize(14).layoutWeight(1).fontColor($r('app.color.text_secondary'))
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_secondary')])
          }.padding({ top: 12, bottom: 12 }).width('100%').onClick((): void => this.onOpenReviews())
        }
      }
      ListItem() { Text('已知人物').fontSize(18).fontWeight(FontWeight.Bold).padding({ top: 16, bottom: 8 }) }
      if (this.summaries(true).length === 0) {
        ListItem() { Text('确认片段中的人物后，会显示在这里').fontSize(14).fontColor($r('app.color.text_secondary')).padding({ bottom: 16 }) }
      }
      ForEach(this.summaries(true), (group: PhoneV3SpeakerSummary) => { ListItem() { this.personRow(group) } },
        (group: PhoneV3SpeakerSummary): string => `${group.key}:${group.label}:${group.subtitle}:${group.rows.length}`)
      ListItem() { Text('未确认声音').fontSize(18).fontWeight(FontWeight.Bold).padding({ top: 24, bottom: 8 }) }
      ForEach(this.summaries(false), (group: PhoneV3SpeakerSummary) => { ListItem() { this.personRow(group) } },
        (group: PhoneV3SpeakerSummary): string => `${group.key}:${group.label}:${group.subtitle}:${group.rows.length}`)
      if (this.summaries(false).length === 0) {
        ListItem() { Text('暂无未确认声音').fontSize(14).fontColor($r('app.color.text_secondary')) }
      }
    }.padding({ left: 16, right: 16 }).width('100%').height('100%')
      .contentEndOffset(PHONE_V3_BACKUP_ACTION_CONTENT_END_OFFSET).backgroundColor($r('app.color.page_background'))
  }
}
