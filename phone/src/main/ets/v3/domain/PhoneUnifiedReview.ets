import { PhoneDailyEvidence, PhoneDailyParticipant } from './PhoneV3DailyModels';
export interface PhoneUnifiedRef { evidence_id: string; quote: string; }
export interface PhoneUnifiedClaim { section: string; text: string; certainty: string; perspective: string; evidence: Array<PhoneUnifiedRef>; event_ids: Array<string>; }
export interface PhoneUnifiedEvidence { evidence_id: string; source_type: string; text: string; revision: number; speaker?: string; sent_at?: number; platform?: string; record_id?: string; conversation_label?: string; context?: Object; session_id?: string; utterance_id?: string; start_ms?: number; end_ms?: number; start_at?: string; end_at?: string; participant?: PhoneDailyParticipant; }
export interface PhoneUnifiedCoverage { chat_records_in_day: number; chat_records_selected: number; chat_records_excluded: number; recording_events: number; recording_evidence: number; period_start: string; period_end: string; scope: string; missing_sources: Array<string>; }
export interface PhoneUnifiedReview { date: string; timezone: string; status: string; generated_at?: string; error?: string; coverage: PhoneUnifiedCoverage; claims: Array<PhoneUnifiedClaim>; evidence: Array<PhoneUnifiedEvidence>; limitations: Array<string>; }
export function unifiedRecordingEvidence(e: PhoneUnifiedEvidence): PhoneDailyEvidence | undefined {
  if(e.source_type !== 'recording' || e.session_id === undefined || e.utterance_id === undefined || e.start_ms === undefined || e.end_ms === undefined || e.start_at === undefined || e.end_at === undefined || e.participant === undefined) { return undefined; }
  return { session_id:e.session_id, utterance_id:e.utterance_id, revision:e.revision, start_ms:e.start_ms, end_ms:e.end_ms, start_at:e.start_at, end_at:e.end_at, text:e.text, participant:e.participant };
}
export function unifiedEvidenceForClaim(review: PhoneUnifiedReview, claim: PhoneUnifiedClaim): Array<PhoneUnifiedEvidence> {
  return review.evidence.filter((e: PhoneUnifiedEvidence): boolean => claim.evidence.some((r: PhoneUnifiedRef): boolean => r.evidence_id === e.evidence_id));
}
