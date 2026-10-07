import { PhoneDailyCache, PhoneDailyEvent, PhoneDailySummary } from '../domain/PhoneV3DailyModels';
import { overlayReminderCommands, pendingReminderReview } from '../domain/PhoneV3ReminderCommands';
import { validateV3UtteranceDto } from '../contracts/V3ContractModels';
import { phoneV3ReviewItems, overlayPendingPurityReviews } from '../data/PhoneV3ReviewProjection';
import { PhoneV3LocalAnnotation, applyLocalAnnotations, applyAnnotationRows, applyAnnotationConflicts,
  applyAnnotationConflictsToRows } from '../domain/PhoneV3LocalAnnotation';
import { PhoneV3LocalAudioFact, PhoneV3ProjectionRow, PhoneV3ReviewItem, PhoneV3SessionCard,
  PhoneV3Snapshot, PhoneV3Utterance } from '../domain/PhoneV3Models';
import { PhoneV3ProjectionRepositoryPort, PhoneV3RemotePort } from './PhoneV3Ports';
import { indexSessionUtterances, mergePhoneV3Sessions, parseProjectionObject,
  phoneV3Reminders } from './PhoneV3ProjectionMapping';

/** Pure projection reads and bounded session transcript pages. */
export class PhoneV3ProjectionQueries {
  private repository: PhoneV3ProjectionRepositoryPort;
  private remote: PhoneV3RemotePort;
  private cachedUtteranceRows: Map<string, Array<PhoneV3ProjectionRow>> | null = null;

  constructor(repository: PhoneV3ProjectionRepositoryPort, remote: PhoneV3RemotePort) {
    this.repository = repository;
    this.remote = remote;
  }

  invalidateUtteranceCache(): void { this.cachedUtteranceRows = null; }

  async searchTranscriptSessionIds(search: string): Promise<Array<string>> {
    if (this.repository.searchTranscriptSessionIds !== undefined) {
      return this.repository.searchTranscriptSessionIds(search);
    }
    const rows = await this.repository.projectionRows('utterance');
    const matches = new Set<string>();
    for (let row of rows) {
      const payload = validateV3UtteranceDto(parseProjectionObject(row));
      if (payload.text.toLocaleLowerCase().includes(search.toLocaleLowerCase()) ||
        (payload.speaker_label ?? '').toLocaleLowerCase().includes(search.toLocaleLowerCase())) {
        matches.add(payload.session_id);
      }
    }
    return Array.from(matches);
  }

  async loadUtteranceById(utteranceId: string): Promise<PhoneV3Utterance | undefined> {
    const rows = await this.repository.projectionRows('utterance', [utteranceId]);
    const grouped = indexSessionUtterances(rows);
    for (let values of grouped.values()) {
      const row = values.find((value: PhoneV3Utterance): boolean => value.utteranceId === utteranceId);
      if (row !== undefined) { return row; }
    }
    return undefined;
  }

  async loadDailyCache(): Promise<PhoneDailyCache> {
    const value = new PhoneDailyCache();
    value.events = (await this.repository.projectionRows('daily_event')).map(
      (row: PhoneV3ProjectionRow): PhoneDailyEvent => JSON.parse(row.payloadJson) as PhoneDailyEvent)
      .sort((a: PhoneDailyEvent, b: PhoneDailyEvent): number => Date.parse(a.start_at) - Date.parse(b.start_at));
    value.summaries = (await this.repository.projectionRows('daily_summary')).map(
      (row: PhoneV3ProjectionRow): PhoneDailySummary => JSON.parse(row.payloadJson) as PhoneDailySummary)
      .sort((a: PhoneDailySummary, b: PhoneDailySummary): number => b.summary_date.localeCompare(a.summary_date));
    return value;
  }

  async loadCached(localFacts: Array<PhoneV3LocalAudioFact>): Promise<PhoneV3Snapshot> {
    const recordings = await this.repository.projectionRows('recording_session');
    const processing = await this.repository.projectionRows('processing_run');
    const paged = this.repository.sessionUtteranceCounts !== undefined &&
      this.repository.sessionUtteranceRows !== undefined;
    const grouped = paged || this.repository.projectionUtterancesBySession === undefined ? null :
      this.cachedUtteranceRows ?? await this.repository.projectionUtterancesBySession();
    if (grouped !== null) { this.cachedUtteranceRows = grouped; }
    const utterances = paged ? [] : grouped === null ? await this.repository.projectionRows('utterance') : [];
    const reviews = await this.repository.projectionRows('review_item');
    const reminders = await this.repository.projectionRows('reminder');
    const links = await this.repository.localAudioLinks();
    const conflicts = await this.repository.conflictRows();
    const status = await this.repository.v3Status();
    const paired = await this.remote.isPaired();
    const commands = this.repository.reminderOperations === undefined ? [] : await this.repository.reminderOperations();
    const reminderValues = overlayReminderCommands(phoneV3Reminders(reminders), commands);
    const completions = await this.repository.localSessionCompletions();
    const sessions = mergePhoneV3Sessions(localFacts, links, recordings, processing, utterances,
      completions);
    const annotations = await this.repository.annotationOperations();
    if (paged) {
      const counts = await this.repository.sessionUtteranceCounts!();
      for (let card of sessions) { card.setPagedUtterances(counts.get(card.sessionId) ?? 0); }
    } else if (grouped === null) {
      applyLocalAnnotations(sessions, annotations);
      applyAnnotationConflicts(sessions, conflicts);
    } else {
      for (let card of sessions) {
        const rows = grouped.get(card.sessionId) ?? [];
        if (rows.length === 0) { continue; }
        card.setLazyUtterances(rows.map((row: PhoneV3ProjectionRow): string => row.resourceId),
          (): Array<PhoneV3Utterance> => indexSessionUtterances(rows).get(card.sessionId) ?? [],
          (): void => {
            applyLocalAnnotations([card], annotations);
            applyAnnotationConflicts([card], conflicts);
          },
          (offset: number, limit: number): Array<PhoneV3Utterance> => {
            const page = indexSessionUtterances(rows.slice(offset, offset + limit)).get(card.sessionId) ?? [];
            const indexed = new Map<string, PhoneV3Utterance>();
            for (let row of page) { indexed.set(row.utteranceId, row); }
            applyAnnotationRows(indexed, annotations);
            applyAnnotationConflictsToRows(indexed, conflicts);
            return page;
          });
      }
    }
    return new PhoneV3Snapshot(
      sessions,
      conflicts, status, paired, reminderValues, overlayPendingPurityReviews(phoneV3ReviewItems(reviews).filter(
        (item: PhoneV3ReviewItem): boolean => !pendingReminderReview(item, commands)),
        await this.repository.pendingPurityReviews()));
  }

  async loadSessionUtterancePage(card: PhoneV3SessionCard, targetCount: number): Promise<void> {
    if (this.repository.sessionUtteranceRows === undefined || card.sessionId.length === 0) { return; }
    while (card.utterances.length < Math.min(targetCount, card.utteranceCount)) {
      const loaded = card.utterances;
      const last = loaded.length > 0 ? loaded[loaded.length - 1] : undefined;
      const limit = Math.min(50, targetCount - loaded.length);
      const page = await this.repository.sessionUtteranceRows(
        card.sessionId, limit, last?.startMs ?? -1, last?.utteranceId ?? '');
      if (page.length === 0) { break; }
      const rows = indexSessionUtterances(page).get(card.sessionId) ?? [];
      const ids = rows.map((row: PhoneV3Utterance): string => row.utteranceId);
      const annotations = await this.repository.annotationOperations(ids);
      const conflicts = await this.repository.conflictRows();
      const indexed = new Map<string, PhoneV3Utterance>();
      for (let row of rows) { indexed.set(row.utteranceId, row); }
      applyAnnotationRows(indexed, annotations);
      applyAnnotationConflictsToRows(indexed, conflicts);
      card.appendUtterancePage(rows);
      if (card.utterances.length <= loaded.length) { break; }
      if (page.length < limit) { break; }
    }
  }

}
