import {
  DeviceV3ClientOperation,
  DeviceV3SyncRequest
} from '../../computer/ComputerTransferProtocol';
import {
  V3_CONTRACT_VERSION,
  V3_PROJECTION_VERSION,
  validateV3ReminderDto,
  validateV3UtteranceDto
} from '../contracts/V3ContractModels';
import { applySyncResponse } from '../data/PhoneSyncProjection';
import {
  PhoneV3LocalAudioFact,
  PhoneV3LocalAudioLink,
  PhoneV3ProjectionRow,
  PhoneV3Reminder,
  PhoneV3SessionCard,
  PhoneV3Snapshot,
  PhoneV3Utterance
} from '../domain/PhoneV3Models';
import {
  PhoneV3LocalAudioRepositoryPort,
  PhoneV3ProjectionRepositoryPort,
  PhoneV3ReminderSchedulerPort,
  PhoneV3RemotePort
} from './PhoneV3Ports';

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

interface UtteranceCorrectionPayload {
  utterance_id: string;
  text: string;
  speaker_track_id: string | null;
  identity: string;
}

export class PhoneV3SyncResult {
  batches: number;
  submittedOperations: number;
  finalCursor: string;

  constructor(batches: number, submittedOperations: number, finalCursor: string) {
    this.batches = batches;
    this.submittedOperations = submittedOperations;
    this.finalCursor = finalCursor;
  }
}

export class PhoneV3UseCases {
  private repository: PhoneV3ProjectionRepositoryPort;
  private localAudio: PhoneV3LocalAudioRepositoryPort;
  private remote: PhoneV3RemotePort;
  private reminderScheduler: PhoneV3ReminderSchedulerPort | undefined;

  constructor(repository: PhoneV3ProjectionRepositoryPort,
    localAudio: PhoneV3LocalAudioRepositoryPort, remote: PhoneV3RemotePort,
    reminderScheduler?: PhoneV3ReminderSchedulerPort) {
    this.repository = repository;
    this.localAudio = localAudio;
    this.remote = remote;
    this.reminderScheduler = reminderScheduler;
  }

  async loadLocal(): Promise<Array<PhoneV3LocalAudioFact>> {
    return this.localAudio.list();
  }

  async loadCached(localFacts: Array<PhoneV3LocalAudioFact>): Promise<PhoneV3Snapshot> {
    const recordings = await this.repository.projectionRows('recording_session');
    const processing = await this.repository.projectionRows('processing_run');
    const utterances = await this.repository.projectionRows('utterance');
    const reminders = await this.repository.projectionRows('reminder');
    const links = await this.repository.localAudioLinks();
    const conflicts = await this.repository.conflictRows();
    const status = await this.repository.v3Status();
    const paired = await this.remote.isPaired();
    const reminderValues = phoneV3Reminders(reminders);
    await this.reconcileReminders(reminderValues);
    return new PhoneV3Snapshot(
      mergePhoneV3Sessions(localFacts, links, recordings, processing, utterances),
      conflicts, status, paired, reminderValues);
  }

  async localAudioIsProtected(sessionKey: string): Promise<boolean> {
    const links = await this.repository.localAudioLinks();
    for (let index = 0; index < links.length; index += 1) {
      if (links[index].sessionKey === sessionKey &&
        (links[index].sessionId.length > 0 || links[index].uploadStatus === 'uploaded')) {
        return true;
      }
    }
    const recordings = await this.repository.projectionRows('recording_session');
    for (let index = 0; index < recordings.length; index += 1) {
      const payload = parseRecording(recordings[index].payloadJson);
      if (payload !== undefined && payload.session_key === sessionKey) {
        return true;
      }
    }
    return false;
  }

  async queueUtteranceCorrection(utterance: PhoneV3Utterance,
    textValue: string, speakerTrackId: string | null, identity: string): Promise<void> {
    const text = textValue.trim();
    if (text.length === 0) {
      throw new Error('utterance 校正文本不能为空');
    }
    if (['self', 'not_self', 'unknown'].indexOf(identity) < 0) {
      throw new Error('utterance 本人身份无效');
    }
    if (text === utterance.text && speakerTrackId === utterance.speakerTrackId &&
      identity === utterance.identity) {
      throw new Error('utterance 校正没有产生变化');
    }
    const payload: UtteranceCorrectionPayload = {
      utterance_id: utterance.utteranceId,
      text: text,
      speaker_track_id: speakerTrackId,
      identity: identity
    };
    const operation: DeviceV3ClientOperation = {
      operation_id: newOperationId(),
      kind: 'utterance.correct',
      base_revision: utterance.revision,
      payload: payload
    };
    await this.repository.enqueue(operation);
  }

  async synchronize(): Promise<PhoneV3SyncResult> {
    try {
      const session = await this.remote.connect();
      const status = await session.status();
      if (status.contract_version !== V3_CONTRACT_VERSION ||
        status.projection_version !== V3_PROJECTION_VERSION) {
        throw new Error('电脑 V3 Device API 版本与 Phone 投影不兼容');
      }
      const pending = await this.repository.pendingOperations(500);
      const operations: Array<DeviceV3ClientOperation> = [];
      for (let index = 0; index < pending.length; index += 1) {
        operations.push({
          operation_id: pending[index].operation_id,
          kind: pending[index].kind,
          base_revision: pending[index].base_revision,
          payload: pending[index].payload
        });
      }
      let cursor = await this.repository.currentCursor();
      let hasMore = true;
      let batches = 0;
      while (hasMore) {
        if (batches >= 100) {
          throw new Error('V3 增量同步批次过多，请稍后重试');
        }
        const request: DeviceV3SyncRequest = {
          projection_version: V3_PROJECTION_VERSION,
          cursor: cursor === 'cursor-0' ? null : cursor,
          client_operations: batches === 0 ? operations : [],
          pull_limit: 500
        };
        const response = await session.sync(request);
        await applySyncResponse(this.repository, response);
        cursor = response.next_cursor;
        hasMore = response.has_more;
        batches += 1;
      }
      return new PhoneV3SyncResult(batches, operations.length, cursor);
    } catch (error) {
      const message = error instanceof Error ? error.message : JSON.stringify(error);
      await this.repository.markSyncFailure(message);
      throw new Error(message);
    }
  }

  async rebuild(): Promise<PhoneV3SyncResult> {
    await this.repository.rebuildFromComputer();
    return this.synchronize();
  }

  private async reconcileReminders(reminders: Array<PhoneV3Reminder>): Promise<void> {
    if (this.reminderScheduler === undefined) {
      return;
    }
    try {
      await this.reminderScheduler.reconcile(reminders);
    } catch (error) {
      // Notification permission is optional; the durable in-app reminder list remains available.
    }
  }
}

export function mergePhoneV3Sessions(localFacts: Array<PhoneV3LocalAudioFact>,
  links: Array<PhoneV3LocalAudioLink>, recordingRows: Array<PhoneV3ProjectionRow>,
  processingRows: Array<PhoneV3ProjectionRow>,
  utteranceRows: Array<PhoneV3ProjectionRow>): Array<PhoneV3SessionCard> {
  const cards: Array<PhoneV3SessionCard> = [];
  for (let rowIndex = 0; rowIndex < recordingRows.length; rowIndex += 1) {
    const row = recordingRows[rowIndex];
    const payload = parseRecording(row.payloadJson);
    if (payload === undefined) {
      continue;
    }
    const sessionId = text(payload.session_id, row.resourceId);
    const sessionKey = text(payload.session_key, linkedSessionKey(links, sessionId));
    const local = findLocal(localFacts, links, sessionId, sessionKey);
    const processing = latestProcessing(processingRows, sessionId);
    const capturedStart = text(payload.captured_start, '');
    const startedAt = capturedStart.length > 0 ? Date.parse(capturedStart) :
      local === undefined ? row.updatedAt : local.startedAt;
    cards.push(new PhoneV3SessionCard(
      sessionId, sessionId, sessionKey, local === undefined ? '' : local.localGroupKey, capturedStart,
      Number.isFinite(startedAt) ? startedAt : row.updatedAt,
      text(payload.device_name, 'Watch'), text(payload.state, 'unknown'),
      text(payload.status_code, 'pending'), numberValue(payload.progress, 0),
      numberValue(payload.revision, row.revision), row.updatedAt,
      local === undefined ? [] : local.paths.slice(), local === undefined ? 0 : local.sizeBytes,
      local === undefined ? 0 : local.durationMs, uploadStatus(links, sessionId, sessionKey),
      processing === undefined ? 'not_started' : text(processing.payload.status, 'pending'),
      processing === undefined ? '' : text(processing.payload.current_stage, ''),
      processing === undefined ? 0 : numberValue(processing.payload.progress, 0),
      sessionUtterances(utteranceRows, sessionId)));
  }
  for (let localIndex = 0; localIndex < localFacts.length; localIndex += 1) {
    const local = localFacts[localIndex];
    if (hasLocal(cards, local.sessionKey)) {
      continue;
    }
    const linkedId = linkedSessionId(links, local.sessionKey);
    cards.push(new PhoneV3SessionCard(
      linkedId.length > 0 ? linkedId : local.sessionKey,
      linkedId, local.sessionKey, local.localGroupKey, '', local.startedAt, 'Watch', 'local',
      linkedId.length > 0 ? 'uploaded' : 'phone_only', 0, 0, local.receivedAt,
      local.paths.slice(), local.sizeBytes, local.durationMs,
      uploadStatus(links, linkedId, local.sessionKey), 'not_started', '', 0, []));
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
    try {
      const payload = JSON.parse(rows[index].payloadJson) as ProcessingPayload;
      if (payload.session_id === sessionId && (match === undefined || rows[index].updatedAt > match.updatedAt)) {
        match = new ProcessingMatch(payload, rows[index].updatedAt);
      }
    } catch (error) {
    }
  }
  return match;
}

function sessionUtterances(rows: Array<PhoneV3ProjectionRow>, sessionId: string): Array<PhoneV3Utterance> {
  const values: Array<PhoneV3Utterance> = [];
  for (let index = 0; index < rows.length; index += 1) {
    try {
      const payload = validateV3UtteranceDto(JSON.parse(rows[index].payloadJson) as Object);
      if (payload.session_id !== sessionId) {
        continue;
      }
      values.push(new PhoneV3Utterance(
        payload.utterance_id, sessionId, payload.speaker_track_id, payload.speaker_label,
        payload.original_speaker_track_id, payload.original_speaker_label,
        payload.identity, payload.original_identity, JSON.stringify(payload.identity_evidence),
        payload.start_ms, payload.end_ms, payload.start_at, payload.end_at,
        payload.text, payload.original_text, payload.revision, payload.status,
        JSON.stringify(payload.evidence)));
    } catch (error) {
    }
  }
  values.sort((left: PhoneV3Utterance, right: PhoneV3Utterance): number =>
    left.startMs - right.startMs || left.utteranceId.localeCompare(right.utteranceId));
  return values;
}

function phoneV3Reminders(rows: Array<PhoneV3ProjectionRow>): Array<PhoneV3Reminder> {
  const values: Array<PhoneV3Reminder> = [];
  for (let index = 0; index < rows.length; index += 1) {
    try {
      const payload = validateV3ReminderDto(JSON.parse(rows[index].payloadJson) as Object);
      values.push(new PhoneV3Reminder(
        payload.event_id, payload.session_id, payload.event_revision,
        payload.source_candidate_id, payload.title, payload.actor_person_id,
        payload.commitment_direction, payload.related_person_ids.slice(),
        payload.scheduled_at, payload.location, payload.status, payload.updated_at));
    } catch (error) {
    }
  }
  values.sort((left: PhoneV3Reminder, right: PhoneV3Reminder): number =>
    Date.parse(left.scheduledAt) - Date.parse(right.scheduledAt) ||
      left.eventId.localeCompare(right.eventId));
  return values;
}

const ULID_ALPHABET: string = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
let lastOperationTime: number = 0;
let operationSequence: number = 0;

function newOperationId(): string {
  const current = Date.now();
  operationSequence = current === lastOperationTime ? (operationSequence + 1) % 1024 : 0;
  lastOperationTime = current;
  let time = current;
  let prefix = '';
  for (let index = 0; index < 10; index += 1) {
    prefix = ULID_ALPHABET.charAt(time % 32) + prefix;
    time = Math.floor(time / 32);
  }
  let suffix = '';
  for (let index = 0; index < 14; index += 1) {
    suffix += ULID_ALPHABET.charAt(Math.floor(Math.random() * 32));
  }
  suffix += ULID_ALPHABET.charAt(Math.floor(operationSequence / 32));
  suffix += ULID_ALPHABET.charAt(operationSequence % 32);
  return prefix + suffix;
}

function parseRecording(value: string): RecordingPayload | undefined {
  try {
    return JSON.parse(value) as RecordingPayload;
  } catch (error) {
    return undefined;
  }
}

function findLocal(facts: Array<PhoneV3LocalAudioFact>, links: Array<PhoneV3LocalAudioLink>,
  sessionId: string, sessionKey: string): PhoneV3LocalAudioFact | undefined {
  const linkedKey = sessionKey.length > 0 ? sessionKey : linkedSessionKey(links, sessionId);
  for (let index = 0; index < facts.length; index += 1) {
    if (facts[index].sessionKey === linkedKey) {
      return facts[index];
    }
  }
  return undefined;
}

function hasLocal(cards: Array<PhoneV3SessionCard>, sessionKey: string): boolean {
  for (let index = 0; index < cards.length; index += 1) {
    if (cards[index].sessionKey === sessionKey && cards[index].localPaths.length > 0) {
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

function uploadStatus(links: Array<PhoneV3LocalAudioLink>, sessionId: string, sessionKey: string): string {
  let value = 'local';
  for (let index = 0; index < links.length; index += 1) {
    if ((sessionId.length > 0 && links[index].sessionId === sessionId) ||
      (sessionKey.length > 0 && links[index].sessionKey === sessionKey)) {
      value = links[index].uploadStatus;
    }
  }
  return value;
}

function text(value: string | undefined, fallback: string): string {
  return typeof value === 'string' && value.length > 0 ? value : fallback;
}

function numberValue(value: number | undefined, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
}
