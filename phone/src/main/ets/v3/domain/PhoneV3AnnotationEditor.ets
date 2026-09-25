import { PhoneV3AnnotationIndex } from './PhoneV3AnnotationIndex';
import { phoneV3AnnotationState } from './PhoneV3AnnotationState';
import { PhoneV3SessionCard, PhoneV3Utterance } from './PhoneV3Models';

// Browser state only: completion always comes from materialized persistent facts.
export class PhoneV3AnnotationEditor {
  private index: PhoneV3AnnotationIndex = new PhoneV3AnnotationIndex();
  private scope: Map<string, PhoneV3Utterance> = new Map<string, PhoneV3Utterance>();
  private selections: Map<string, PhoneV3Utterance> = new Map<string, PhoneV3Utterance>();
  rows: Array<PhoneV3Utterance> = [];
  filtered: Array<PhoneV3Utterance> = [];
  pageRows: Array<PhoneV3Utterance> = [];
  selectedPageRows: Array<PhoneV3Utterance> = [];
  selectionPage: number = 0;
  selectionPages: number = 1;
  current: PhoneV3Utterance | undefined = undefined;
  doneMode: boolean = false;
  batch: boolean = false;
  query: string = '';
  page: number = 0;
  pages: number = 1;
  pending: number = 0;
  done: number = 0;
  hidden: number = 0;
  selectedCount: number = 0;
  changed: boolean = false;

  open(targets: Array<PhoneV3Utterance>, sessions: Array<PhoneV3SessionCard>): void {
    this.scope = new Map<string, PhoneV3Utterance>();
    for (let row of targets) { this.scope.set(row.utteranceId, row); }
    this.index.setTargets(targets);
    this.update(sessions);
    if (targets.length === 1) {
      const row = this.rows.find((value: PhoneV3Utterance): boolean => value.utteranceId === targets[0].utteranceId);
      if (row !== undefined) { this.doneMode = phoneV3AnnotationState(row).done; this.focus(row); }
    }
    this.filter();
    if (!this.doneMode && this.current === undefined) { this.focus(this.filtered[0]); }
  }

  update(sessions: Array<PhoneV3SessionCard>): boolean {
    if (!this.index.update(sessions)) { return false; }
    const available = new Map<string, PhoneV3Utterance>();
    for (let row of this.index.rows) { available.set(row.utteranceId, row); this.scope.set(row.utteranceId, row); }
    this.rows = Array.from(this.scope.values()).map((row: PhoneV3Utterance): PhoneV3Utterance =>
      available.get(row.utteranceId) ?? missingRow(row));
    this.done = this.rows.filter((row: PhoneV3Utterance): boolean => phoneV3AnnotationState(row).done).length;
    this.pending = this.rows.length - this.done;
    // Keep the reviewed object/version until the user explicitly reopens it.
    const freshRows = new Map<string, PhoneV3Utterance>();
    for (let row of this.rows) { freshRows.set(row.utteranceId, row); }
    this.changed = this.targets().some((row: PhoneV3Utterance): boolean => {
      const fresh = freshRows.get(row.utteranceId);
      return fresh === undefined || fresh.revision !== row.revision || fresh.status !== row.status;
    });
    this.filter();
    return true;
  }

  filter(): void {
    const query = this.query.trim().toLowerCase();
    this.filtered = this.rows.filter((row: PhoneV3Utterance): boolean => phoneV3AnnotationState(row).done === this.doneMode &&
      (query.length === 0 || row.text.toLowerCase().includes(query) || row.startAt.includes(query)));
    if (!this.doneMode) { this.filtered.sort((a: PhoneV3Utterance, b: PhoneV3Utterance): number =>
      Number(phoneV3AnnotationState(b).review) - Number(phoneV3AnnotationState(a).review)); }
    this.pages = Math.max(1, Math.ceil(this.filtered.length / 20));
    this.page = Math.min(this.page, this.pages - 1);
    this.pageRows = this.filtered.slice(this.page * 20, this.page * 20 + 20);
    const visibleIds = new Set<string>(this.filtered.map((row: PhoneV3Utterance): string => row.utteranceId));
    this.hidden = Array.from(this.selections.keys()).filter((id: string): boolean => !visibleIds.has(id)).length;
    this.selectedCount = this.selections.size;
    this.selectionPages = Math.max(1, Math.ceil(this.selectedCount / 20));
    this.selectionPage = Math.min(this.selectionPage, this.selectionPages - 1);
    this.selectedPageRows = Array.from(this.selections.values()).slice(this.selectionPage * 20, this.selectionPage * 20 + 20);
  }

  focus(row: PhoneV3Utterance | undefined): void { this.current = row; this.changed = false; }
  move(delta: number): void {
    if (this.filtered.length === 0) { this.focus(undefined); return; }
    const index = this.filtered.findIndex((row: PhoneV3Utterance): boolean => row.utteranceId === this.current?.utteranceId);
    this.focus(this.filtered[(index + delta + this.filtered.length) % this.filtered.length]);
  }
  switchMode(done: boolean): void {
    this.doneMode = done; this.batch = false; this.selections.clear(); this.page = 0;
    this.filter(); this.focus(done ? undefined : this.filtered[0]);
  }
  setBatch(value: boolean): void {
    this.batch = value; this.selections.clear(); this.filter();
    this.focus(value ? undefined : this.filtered[0]);
  }
  choose(row: PhoneV3Utterance, checked: boolean): void {
    if (checked && !phoneV3AnnotationState(row).done) { this.selections.set(row.utteranceId, row); }
    else { this.selections.delete(row.utteranceId); }
    this.filter();
  }
  isSelected(id: string): boolean { return this.selections.has(id); }
  selectFiltered(): void {
    for (let row of this.filtered) { if (!phoneV3AnnotationState(row).done) { this.selections.set(row.utteranceId, row); } }
    this.filter();
  }
  targets(): Array<PhoneV3Utterance> { return this.batch ? Array.from(this.selections.values()) : this.current ? [this.current] : []; }
  saved(ids: Array<string>): void {
    for (let id of ids) { this.selections.delete(id); }
    this.filter();
    if (!this.batch) { this.focus(this.doneMode ? this.rows.find((row: PhoneV3Utterance): boolean => row.utteranceId === ids[0]) : this.filtered[0]); }
  }
}

// A removed source remains visible for this open scope, but can never count as done.
function missingRow(row: PhoneV3Utterance): PhoneV3Utterance {
  const missing = new PhoneV3Utterance(row.utteranceId, row.sessionId, row.speakerTrackId,
    row.speakerLabel, row.originalSpeakerTrackId, row.originalSpeakerLabel, row.identity,
    row.originalIdentity, row.identityEvidenceJson, row.startMs, row.endMs, row.startAt,
    row.endAt, row.text, row.originalText, row.revision, 'stale', row.evidenceJson);
  missing.annotationPersonId = row.annotationPersonId;
  missing.annotationFacts = row.annotationFacts;
  missing.soundKind = row.soundKind;
  return missing;
}
