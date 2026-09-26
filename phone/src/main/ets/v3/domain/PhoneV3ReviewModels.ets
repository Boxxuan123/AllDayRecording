import { PhoneV3ReviewItem } from './PhoneV3Models';

export interface VoiceClipPayload {
  media_id?: string;
  start_ms?: number;
  end_ms?: number;
}

interface VoiceCandidatePayload {
  audio_content_key?: string;
  review_key?: string;
  evidence_utterances?: Array<PhoneV3VoiceEvidence>;
  prototype_id?: string;
  session_id?: string;
  speaker_track_id?: string;
  person_name?: string;
  quality_score?: number | null;
  best_score?: number | null;
  score_margin?: number | null;
  review_status?: string;
  audio_available?: boolean;
  audio_unavailable_reason?: string;
  audition_key?: string;
  representative_clips?: Array<VoiceClipPayload>;
}

interface VoiceReviewContextPayload {
  review_lane?: string;
  evidence_utterance_ids?: Array<string>;
  voice_mode?: string;
  voice_candidates?: Array<VoiceCandidatePayload>;
}

export class PhoneV3VoiceCandidate {
  audioContentKey: string = '';
  reviewKey: string = '';
  clips: Array<VoiceClipPayload> = [];
  evidence: Array<PhoneV3VoiceEvidence> = [];
  windowCount: number = 0;
  totalMs: number = 0;
  ranges: string = '';
  auditionKey: string = '';
  unavailableReason: string = '';
  prototypeId: string;
  sessionId: string;
  speakerTrackId: string;
  personName: string;
  qualityScore: number | null;
  bestScore: number | null;
  scoreMargin: number | null;
  reviewStatus: string;
  hasAudio: boolean;
  startMs: number;
  endMs: number;

  constructor(prototypeId: string, sessionId: string, speakerTrackId: string,
    personName: string, qualityScore: number | null, bestScore: number | null,
    scoreMargin: number | null, reviewStatus: string, hasAudio: boolean,
    startMs: number, endMs: number) {
    this.prototypeId = prototypeId;
    this.sessionId = sessionId;
    this.speakerTrackId = speakerTrackId;
    this.personName = personName;
    this.qualityScore = qualityScore;
    this.bestScore = bestScore;
    this.scoreMargin = scoreMargin;
    this.reviewStatus = reviewStatus;
    this.hasAudio = hasAudio;
    this.startMs = startMs;
    this.endMs = endMs;
  }
}

export function phoneV3VoiceMode(item: PhoneV3ReviewItem): string {
  try {
    const context = JSON.parse(item.contextJson) as VoiceReviewContextPayload;
    return typeof context.voice_mode === 'string' ? context.voice_mode : '';
  } catch (_error) {
    return '';
  }
}

export function phoneV3VoiceCandidates(item: PhoneV3ReviewItem): Array<PhoneV3VoiceCandidate> {
  let context: VoiceReviewContextPayload;
  try {
    context = JSON.parse(item.contextJson) as VoiceReviewContextPayload;
  } catch (_error) {
    return [];
  }
  if (!Array.isArray(context.voice_candidates)) {
    return [];
  }
  const values: Array<PhoneV3VoiceCandidate> = [];
  for (let index = 0; index < context.voice_candidates.length; index += 1) {
    const candidate = context.voice_candidates[index];
    if (typeof candidate.prototype_id !== 'string' || candidate.prototype_id.length === 0) {
      continue;
    }
    const clips = Array.isArray(candidate.representative_clips) ? candidate.representative_clips : [];
    const clip = clips.length > 0 ? clips[0] : undefined;
    const startMs = clip !== undefined && validOffset(clip.start_ms) ? clip.start_ms as number : 0;
    const endMs = clip !== undefined && validOffset(clip.end_ms) ? clip.end_ms as number : startMs + 6000;
    const result = new PhoneV3VoiceCandidate(
      candidate.prototype_id,
      typeof candidate.session_id === 'string' ? candidate.session_id : '',
      typeof candidate.speaker_track_id === 'string' ? candidate.speaker_track_id : '',
      typeof candidate.person_name === 'string' ? candidate.person_name : item.title,
      optionalScore(candidate.quality_score), optionalScore(candidate.best_score),
      optionalScore(candidate.score_margin),
      typeof candidate.review_status === 'string' ? candidate.review_status : 'pending',
      candidate.audio_available === true,
      startMs, endMs);
    result.windowCount = clips.length;
    result.clips = clips;
    result.evidence = candidate.evidence_utterances ?? [];
    result.reviewKey = candidate.review_key ?? '';
    result.auditionKey = candidate.audition_key ?? '';
    result.audioContentKey = candidate.audio_content_key ?? '';
    result.unavailableReason = candidate.audio_unavailable_reason ?? '请更新电脑端以提供完整试听';
    for (const window of clips) {
      if (validOffset(window.start_ms) && validOffset(window.end_ms)) {
        result.totalMs += (window.end_ms as number) - (window.start_ms as number);
        result.ranges += `${window.media_id}: ${(window.start_ms as number) / 1000}–${(window.end_ms as number) / 1000} 秒\n`;
      }
    }
    values.push(result);
  }
  values.sort((left: PhoneV3VoiceCandidate, right: PhoneV3VoiceCandidate): number =>
    sortableScore(left.bestScore) - sortableScore(right.bestScore) ||
      sortableScore(left.scoreMargin) - sortableScore(right.scoreMargin) ||
      left.prototypeId.localeCompare(right.prototypeId));
  return values;
}

export interface PhoneV3VoiceEvidence {
  utterance_id: string;
  revision: number;
  session_id: string;
  utterance_start_ms: number;
  utterance_end_ms: number;
  window_index: number;
  media_id: string;
  clip_start_ms: number;
  clip_end_ms: number;
  session_start_ms: number;
  session_end_ms: number;
}

export function phoneV3ReviewIsHistory(item: PhoneV3ReviewItem): boolean {
  try {
    const context = JSON.parse(item.contextJson) as VoiceReviewContextPayload;
    return context.voice_mode === 'accepted_grant' || context.review_lane === 'history';
  } catch (_) { return false; }
}

export function phoneV3PendingReviews(items: Array<PhoneV3ReviewItem>, filter: number = 0): Array<PhoneV3ReviewItem> {
  return items.filter((item: PhoneV3ReviewItem): boolean => !phoneV3ReviewIsHistory(item) &&
    (filter === 0 || filter === 1 && item.kind === 'voice_identity' || filter === 2 && item.kind === 'reminder' ||
      filter === 3 && (item.kind === 'person_memory' || item.kind === 'knowledge_proposal')));
}

export function phoneV3ReviewReason(reason: string): string {
  switch (reason) {
    case 'reminder_requires_confirmation': return '确认后才会创建并安排提醒';
    case 'durable_person_memory_requires_confirmation': return '确认后会作为跨天人物记忆保留';
    case 'trusted_memory_requires_confirmation': return '确认后才会写入可信事件记录';
    case 'voice_grant_management': return '撤回只停止此样本授权，不改变人物标注或其它样本';
    case 'voice_identity_requires_confirmation': return '每个声音样本都要单独听过再判断';
    case 'recurring_unknown_speaker_requires_confirmation': return '该未知声音已跨多次录音出现';
    default: return '这项操作会改变长期状态，需要你的判断';
  }
}

function optionalScore(value: number | null | undefined): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function sortableScore(value: number | null): number {
  return value === null ? -1 : value;
}

function validOffset(value: number | undefined): boolean {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

export function phoneV3ReviewEvidenceIds(item: PhoneV3ReviewItem): Array<string> {
  try {
    const context = JSON.parse(item.contextJson) as VoiceReviewContextPayload;
    return Array.isArray(context.evidence_utterance_ids) ? context.evidence_utterance_ids : [];
  } catch (_error) {
    return [];
  }
}
