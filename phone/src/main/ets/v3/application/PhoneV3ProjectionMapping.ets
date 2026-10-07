import { validateV3UtteranceDto, validateV3ReminderDto } from '../contracts/V3ContractModels';
import { PhoneV3Evidence } from '../domain/PhoneV3PersonFact';
import { PhoneSessionCompletionRecord, PhoneV3LocalAudioFact, PhoneV3LocalAudioLink,
  PhoneV3ProjectionRow, PhoneV3Reminder, PhoneV3SessionCard, PhoneV3Utterance } from '../domain/PhoneV3Models';

interface RecordingPayload {
  session_id?: string;
  session_key?: string;
  captured_start?: string;
  device_name?: string;
  state?: string;
  status_code?: string;
  progress?: number;
  revision?: number;
}

interface ProcessingPayload {
  session_id?: string;
  status?: string;
  current_stage?: string;
  progress?: number;
}

export function mergePhoneV3Sessions(localFacts: Array<PhoneV3LocalAudioFact>,
  links: Array<PhoneV3LocalAudioLink>, recordingRows: Array<PhoneV3ProjectionRow>,
  processingRows: Array<PhoneV3ProjectionRow>,
  utteranceRows: Array<PhoneV3ProjectionRow>,
  completions: Array<PhoneSessionCompletionRecord> = []): Array<PhoneV3SessionCard> {
  const cards: Array<PhoneV3SessionCard> = [];
  const bySession = indexSessionUtterances(utteranceRows);
  for (let rowIndex = 0; rowIndex < recordingRows.length; rowIndex += 1) {
    const row = recordingRows[rowIndex];
    const payload = parseRecording(row);
    const sessionId = text(payload.session_id, row.resourceId);
    const payloadSessionKey = text(payload.session_key, '');
    const boundSessionKey = linkedSessionKey(links, sessionId);
    // The persisted phone/computer link is the authoritative identity mapping.
    // A computer projection can temporarily retain an older session_key after a
    // rebound; preferring that stale value creates a second, transcript-less card.
    const projectedSessionKey = boundSessionKey.length > 0 ? boundSessionKey : payloadSessionKey;
    const local = findLocal(localFacts, links, sessionId, projectedSessionKey);
    const sessionKey = local === undefined ? projectedSessionKey : local.sessionKey;
    const processing = latestProcessing(processingRows, sessionId);
    const capturedStart = text(payload.captured_start, '');
    const startedAt = capturedStart.length > 0 ? Date.parse(capturedStart) :
      local === undefined ? row.updatedAt : local.startedAt;
    if (hasSessionIdentity(cards, sessionId, sessionKey,
      local === undefined ? '' : local.localGroupKey)) {
      continue;
    }
    cards.push(new PhoneV3SessionCard(
      sessionId, sessionId, sessionKey, local === undefined ? '' : local.localGroupKey, capturedStart,
      Number.isFinite(startedAt) ? startedAt : row.updatedAt,
      text(payload.device_name, 'Watch'), text(payload.state, 'unknown'),
      text(payload.status_code, 'pending'), numberValue(payload.progress, 0),
      numberValue(payload.revision, row.revision), row.updatedAt,
      local === undefined ? [] : local.paths.slice(), local === undefined ? 0 : local.sizeBytes,
      local === undefined ? 0 : local.durationMs, uploadStatus(links, completions, sessionId,
        sessionKey, local === undefined ? [] : local.paths),
      processing === undefined ? 'not_started' : text(processing.payload.status, 'pending'),
      processing === undefined ? '' : text(processing.payload.current_stage, ''),
      processing === undefined ? 0 : numberValue(processing.payload.progress, 0),
      bySession.get(sessionId) ?? []));
  }
  for (let localIndex = 0; localIndex < localFacts.length; localIndex += 1) {
    const local = localFacts[localIndex];
    const linkedId = linkedSessionId(links, local.sessionKey);
    if (hasSessionIdentity(cards, linkedId, local.sessionKey, local.localGroupKey)) {
      continue;
    }
    const localUploadStatus = uploadStatus(links, completions, linkedId,
      local.sessionKey, local.paths);
    cards.push(new PhoneV3SessionCard(
      linkedId.length > 0 ? linkedId : local.sessionKey,
      linkedId, local.sessionKey, local.localGroupKey, '', local.startedAt, 'Watch', 'local',
      localUploadStatus === 'uploaded' ? 'uploaded' : 'phone_only', 0, 0, local.receivedAt,
      local.paths.slice(), local.sizeBytes, local.durationMs,
      localUploadStatus,
      'not_started', '', 0, []));
  }
  cards.sort((left: PhoneV3SessionCard, right: PhoneV3SessionCard): number =>
    right.startedAt - left.startedAt || right.updatedAt - left.updatedAt);
  return cards;
}

class ProcessingMatch {
  payload: ProcessingPayload;
  updatedAt: number;

  constructor(payload: ProcessingPayload, updatedAt: number) {
    this.payload = payload;
    this.updatedAt = updatedAt;
  }
}

function latestProcessing(rows: Array<PhoneV3ProjectionRow>, sessionId: string): ProcessingMatch | undefined {
  let match: ProcessingMatch | undefined = undefined;
  for (let index = 0; index < rows.length; index += 1) {
    let payload: ProcessingPayload;
    try {
      payload = parseProjectionObject(rows[index]) as ProcessingPayload;
    } catch (error) {
      throw projectionRowError(rows[index], 'processing_run', error as Object);
    }
    if (payload.session_id === sessionId && (match === undefined || rows[index].updatedAt > match.updatedAt)) {
      match = new ProcessingMatch(payload, rows[index].updatedAt);
    }
  }
  return match;
}

export function indexSessionUtterances(rows: Array<PhoneV3ProjectionRow>): Map<string, Array<PhoneV3Utterance>> {
  const bySession = new Map<string, Array<PhoneV3Utterance>>();
  for (let index = 0; index < rows.length; index += 1) {
    try {
      const payload = validateV3UtteranceDto(parseProjectionObject(rows[index]));
      const sessionId = payload.session_id;
      const values = bySession.get(sessionId) ?? [];
      bySession.set(sessionId, values);
      values.push(new PhoneV3Utterance(
        payload.utterance_id, sessionId, payload.speaker_track_id, payload.speaker_label,
        payload.original_speaker_track_id, payload.original_speaker_label,
        payload.identity, payload.original_identity, JSON.stringify(payload.identity_evidence),
        payload.start_ms, payload.end_ms, payload.start_at, payload.end_at,
        payload.text, payload.original_text, payload.revision, payload.status,
        JSON.stringify(payload.evidence), payload.evidence as PhoneV3Evidence));
    } catch (error) {
      throw projectionRowError(rows[index], 'utterance', error as Object);
    }
  }
  for (let values of bySession.values()) {
    values.sort((left: PhoneV3Utterance, right: PhoneV3Utterance): number =>
      left.startMs - right.startMs || left.utteranceId.localeCompare(right.utteranceId));
  }
  return bySession;
}

export function phoneV3Reminders(rows: Array<PhoneV3ProjectionRow>): Array<PhoneV3Reminder> {
  const values: Array<PhoneV3Reminder> = [];
  for (let index = 0; index < rows.length; index += 1) {
    try {
      const payload = validateV3ReminderDto(parseProjectionObject(rows[index]));
      values.push(new PhoneV3Reminder(
        payload.event_id, payload.session_id, payload.event_revision,
        payload.source_candidate_id, payload.title, payload.actor_person_id,
        payload.commitment_direction, payload.related_person_ids.slice(),
        payload.scheduled_at, payload.location, payload.status, payload.updated_at));
    } catch (error) {
      throw projectionRowError(rows[index], 'reminder', error as Object);
    }
  }
  values.sort((left: PhoneV3Reminder, right: PhoneV3Reminder): number =>
    Date.parse(left.scheduledAt) - Date.parse(right.scheduledAt) ||
      left.eventId.localeCompare(right.eventId));
  return values;
}

export function parseRecording(row: PhoneV3ProjectionRow): RecordingPayload {
  try {
    return parseProjectionObject(row) as RecordingPayload;
  } catch (error) {
    throw projectionRowError(row, 'recording_session', error as Object);
  }
}

export function parseProjectionObject(row: PhoneV3ProjectionRow): Object {
  const value = JSON.parse(row.payloadJson) as Object;
  if (value === null || Array.isArray(value) || typeof value !== 'object') {
    throw new Error('payload 必须是 JSON 对象');
  }
  return value;
}

function projectionRowError(row: PhoneV3ProjectionRow, resourceType: string, error: Object): Error {
  const detail = error instanceof Error ? error.message : JSON.stringify(error);
  return new Error(`V3 ${resourceType} 投影 ${row.resourceId} 无法解析：${detail}`);
}

function findLocal(facts: Array<PhoneV3LocalAudioFact>, links: Array<PhoneV3LocalAudioLink>,
  sessionId: string, sessionKey: string): PhoneV3LocalAudioFact | undefined {
  for (let index = 0; index < facts.length; index += 1) {
    if (sessionKey.length > 0 && facts[index].sessionKey === sessionKey) {
      return facts[index];
    }
  }
  for (let linkIndex = 0; linkIndex < links.length; linkIndex += 1) {
    if (sessionId.length === 0 || links[linkIndex].sessionId !== sessionId) {
      continue;
    }
    for (let factIndex = 0; factIndex < facts.length; factIndex += 1) {
      if (facts[factIndex].sessionKey === links[linkIndex].sessionKey) {
        return facts[factIndex];
      }
    }
  }
  return undefined;
}

function hasSessionIdentity(cards: Array<PhoneV3SessionCard>, sessionId: string,
  sessionKey: string, localGroupKey: string): boolean {
  for (let index = 0; index < cards.length; index += 1) {
    if ((sessionId.length > 0 && cards[index].sessionId === sessionId) ||
      (sessionKey.length > 0 && cards[index].sessionKey === sessionKey) ||
      (localGroupKey.length > 0 && cards[index].localGroupKey === localGroupKey)) {
      return true;
    }
  }
  return false;
}

function linkedSessionId(links: Array<PhoneV3LocalAudioLink>, sessionKey: string): string {
  for (let index = 0; index < links.length; index += 1) {
    if (links[index].sessionKey === sessionKey && links[index].sessionId.length > 0) {
      return links[index].sessionId;
    }
  }
  return '';
}

function linkedSessionKey(links: Array<PhoneV3LocalAudioLink>, sessionId: string): string {
  for (let index = 0; index < links.length; index += 1) {
    if (links[index].sessionId === sessionId) {
      return links[index].sessionKey;
    }
  }
  return '';
}

function uploadStatus(links: Array<PhoneV3LocalAudioLink>,
  completions: Array<PhoneSessionCompletionRecord>, sessionId: string, sessionKey: string,
  localPaths: Array<string>): string {
  let value = 'local';
  for (let index = 0; index < links.length; index += 1) {
    if ((sessionId.length > 0 && links[index].sessionId === sessionId) ||
      (sessionKey.length > 0 && links[index].sessionKey === sessionKey)) {
      value = links[index].uploadStatus === 'uploaded' ? 'file_uploaded' : links[index].uploadStatus;
    }
  }
  const receipt = completions.find((record: PhoneSessionCompletionRecord): boolean =>
    record.sessionKey === sessionKey && record.manifestSha256.length === 64);
  if (localPaths.length === 0) {
    return sessionId.length > 0 ? 'uploaded' : value;
  }
  const allFilesAcknowledged = localPaths.every((path: string): boolean =>
    links.some((link: PhoneV3LocalAudioLink): boolean => link.sessionKey === sessionKey &&
      link.localPath === path && link.uploadStatus === 'uploaded' && /^[0-9a-fA-F]{64}$/.test(link.sha256)));
  if (receipt !== undefined && receipt.completedSegments === localPaths.length && allFilesAcknowledged) {
    return 'uploaded';
  }
  return value;
}

function text(value: string | undefined, fallback: string): string {
  return typeof value === 'string' && value.length > 0 ? value : fallback;
}

function numberValue(value: number | undefined, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
}
