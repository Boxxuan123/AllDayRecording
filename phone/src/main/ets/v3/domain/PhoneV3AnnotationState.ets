import { phoneV3SoundKindLabel } from './PhoneV3SoundKind';

interface Fact { person_id?: string; state?: string; }
interface FactIds { person?: Array<string>; sound?: Array<string>; }
interface Dimensions { person?: Array<string>; sound?: Array<string>; }
interface Review { dimensions?: Dimensions; }
interface Evidence {
  person_annotation?: Fact;
  annotation_fact_ids?: FactIds;
  annotation_outdated?: Array<string>;
  annotation_review?: Review;
}
export class PhoneV3AnnotationFacts {
  person: string = '';
  sound: string = '';
  reason: string = '';
}
// Derived once when a projection row is materialized, never on playback ticks.
export function annotationFacts(evidenceJson: string): PhoneV3AnnotationFacts {
  const result = new PhoneV3AnnotationFacts();
  try {
    const evidence = JSON.parse(evidenceJson) as Evidence;
    const fact = evidence.person_annotation;
    if (fact?.person_id && (fact.state === undefined || fact.state === 'active')) { result.person = 'synced'; }
    if ((evidence.annotation_fact_ids?.sound?.length ?? 0) > 0) { result.sound = 'synced'; }
    if (evidence.annotation_outdated?.includes('person') || evidence.annotation_review?.dimensions?.person !== undefined ||
      (fact?.state !== undefined && fact.state !== 'active')) { result.person = 'review'; }
    if (evidence.annotation_outdated?.includes('sound') || evidence.annotation_review?.dimensions?.sound !== undefined) {
      result.sound = 'review';
    }
    if (result.person === 'review' || result.sound === 'review') { result.reason = '来源或人工判断已变化，请重新核对'; }
  } catch (error) { result.reason = '标注依据无法读取，请刷新'; }
  return result;
}
export interface AnnotationRow {
  annotationFacts: PhoneV3AnnotationFacts;
  annotationPersonId: string;
  speakerLabel: string | null;
  soundKind: string;
  status: string;
}
export class PhoneV3AnnotationState {
  done: boolean = false;
  review: boolean = false;
  result: string = '';
  sync: string = '';
  reason: string = '';
}
export function phoneV3AnnotationState(row: AnnotationRow): PhoneV3AnnotationState {
  const result = new PhoneV3AnnotationState();
  const facts = row.annotationFacts;
  result.review = facts.person === 'review' || facts.sound === 'review' || row.status !== 'active';
  result.done = !result.review && (facts.person.length > 0 || facts.sound.length > 0);
  const labels: Array<string> = [];
  if (facts.person.length > 0) { labels.push(`人物${facts.person === 'review' ? '待复核' : '已确认'}：${row.speakerLabel ?? '已选人物'}`); }
  if (facts.sound.length > 0) { labels.push(`${facts.sound === 'review' ? '声音待复核' : '已标记'}：${phoneV3SoundKindLabel(row.soundKind)}`); }
  result.result = labels.join(' · ') || '待标注';
  result.reason = row.status !== 'active' ? '片段来源已失效，请到审核处理' : facts.reason;
  const states = [facts.person, facts.sound];
  result.sync = states.includes('failed') ? '已在手机保存·同步失败，请重试同步' :
    states.includes('pending') ? '已在手机保存·待同步到电脑' :
    states.includes('accepted') ? '电脑已接收，结果更新中' : result.done ? '已同步' : '';
  return result;
}
export function phoneV3AnnotationLabel(row: AnnotationRow): string {
  const state = phoneV3AnnotationState(row);
  return `${state.review ? '需复核 · ' : ''}${state.result}${state.sync ? ' · ' + state.sync : ''}`;
}

// Rebuild UI items only when their materialized content changes, never on playback.
export function phoneV3AnnotationKey(row: AnnotationRow, id: string, revision: number): string {
  return `${id}:${revision}:${row.annotationPersonId}:${row.speakerLabel}:${row.soundKind}:${row.status}:${row.annotationFacts.person}:${row.annotationFacts.sound}`;
}
