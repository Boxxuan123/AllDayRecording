import { syncRequestBatch } from '../data/PhoneSyncBatch';
import { PHONE_V3_SOUND_KINDS, phoneV3SoundKindLabel } from '../domain/PhoneV3SoundKind';
import { PhoneV3LocalAnnotation, PhoneV3AnnotationSentence, applyLocalAnnotations, applyAnnotationConflicts, annotationRows } from '../domain/PhoneV3LocalAnnotation';
import {
  DeviceV3ClientOperation,
  DeviceV3PersonChoice,
  DeviceV3AnnotationRequest,
  DeviceV3AnnotationResponse,
  DeviceV3ReviewActionRequest,
  DeviceV3ReviewActionResponse,
  DeviceV3ReviewAudioResponse,
  DeviceV3SyncRequest
} from '../../computer/ComputerTransferProtocol';
import {
  V3_CONTRACT_VERSION,
  V3_PROJECTION_VERSION,
  validateV3ReminderDto,
  validateV3UtteranceDto
} from '../contracts/V3ContractModels';
import { applySyncResponse } from '../data/PhoneSyncProjection';
import { phoneV3ReviewItems, phoneV3ReviewSnapshotItems } from '../data/PhoneV3ReviewProjection';
import {
  PhoneV3LocalAudioFact,
  PhoneV3LocalAudioLink,
  PhoneV3ProjectionRow,
  PhoneV3Reminder,
  PhoneV3ReviewItem,
  PhoneV3SessionCard,
  PhoneV3Snapshot,
  PhoneV3Utterance
} from '../domain/PhoneV3Models';
import {
  PhoneV3AudioBackupPort,
  PhoneV3AudioBackupResult,
  PhoneV3LocalAudioRepositoryPort,
  PhoneV3ProjectionRepositoryPort,
  PhoneV3ReminderSchedulerPort,
  PhoneV3RemotePort
} from './PhoneV3Ports';

interface AnnotationTargetPayload { status: string; }
interface ReviewRemoteError { statusCode?: number; reviewRequestNotSent?: boolean; }

export class PhoneV3ReviewSubmissionError extends Error {
  committed: boolean;
  constructor(committed: boolean) {
    super(committed ? '结果已提交，状态待更新；请仅重试读取' : '请求结果尚未确认，请先核对电脑状态，不要重复提交');
    this.committed = committed;
  }
}

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

const activeSyncRepositories: Set<PhoneV3ProjectionRepositoryPort> = new Set<PhoneV3ProjectionRepositoryPort>();

export class PhoneV3SyncResult {
  batches: number;
  submittedOperations: number;
  finalCursor: string;
  backup: PhoneV3AudioBackupResult;
  remainingOperations: number = 0;
  completion: string = 'complete';
  pullPending: boolean = false;

  summary(): string {
    let reason = '全部完成';
    switch (this.completion) {
      case 'waiting': reason = '等待回执、依赖或人工处理'; break;
      case 'cancelled': reason = '已停止，稍后可继续'; break;
      case 'no_progress': reason = '电脑未返回进展，请稍后重试'; break;
      case 'budget_exhausted': reason = '已达本轮上限，请继续同步'; break;
    }
    return `${reason}；剩余 ${this.remainingOperations} 项${this.pullPending ? '，远端数据尚未拉取完' : ''}`;
  }

  constructor(batches: number, submittedOperations: number, finalCursor: string,
    backup: PhoneV3AudioBackupResult = new PhoneV3AudioBackupResult()) {
    this.batches = batches;
    this.submittedOperations = submittedOperations;
    this.finalCursor = finalCursor;
    this.backup = backup;
  }
}

export class PhoneV3UseCases {
  private syncActive: boolean = false;
  private syncCancelled: boolean = false;
  cancelSynchronize(): void { this.syncCancelled = true; }

  private repository: PhoneV3ProjectionRepositoryPort;
  private localAudio: PhoneV3LocalAudioRepositoryPort;
  private remote: PhoneV3RemotePort;
  private reminderScheduler: PhoneV3ReminderSchedulerPort | undefined;
  private audioBackup: PhoneV3AudioBackupPort | undefined;

  constructor(repository: PhoneV3ProjectionRepositoryPort,
    localAudio: PhoneV3LocalAudioRepositoryPort, remote: PhoneV3RemotePort,
    reminderScheduler?: PhoneV3ReminderSchedulerPort,
    audioBackup?: PhoneV3AudioBackupPort) {
    this.repository = repository;
    this.localAudio = localAudio;
    this.remote = remote;
    this.reminderScheduler = reminderScheduler;
    this.audioBackup = audioBackup;
  }

  async loadLocal(): Promise<Array<PhoneV3LocalAudioFact>> {
    return this.localAudio.list();
  }

  async loadCached(localFacts: Array<PhoneV3LocalAudioFact>): Promise<PhoneV3Snapshot> {
    const recordings = await this.repository.projectionRows('recording_session');
    const processing = await this.repository.projectionRows('processing_run');
    const utterances = await this.repository.projectionRows('utterance');
    const reviews = await this.repository.projectionRows('review_item');
    const reminders = await this.repository.projectionRows('reminder');
    const links = await this.repository.localAudioLinks();
    const conflicts = await this.repository.conflictRows();
    const status = await this.repository.v3Status();
    const paired = await this.remote.isPaired();
    const reminderValues = phoneV3Reminders(reminders);
    await this.reconcileReminders(reminderValues);
    const sessions = mergePhoneV3Sessions(localFacts, links, recordings, processing, utterances);
    applyLocalAnnotations(sessions, await this.repository.annotationOperations());
    applyAnnotationConflicts(sessions, conflicts);
    return new PhoneV3Snapshot(
      sessions,
      conflicts, status, paired, reminderValues, phoneV3ReviewItems(reviews));
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
      const payload = parseRecording(recordings[index]);
      if (payload.session_key === sessionKey) {
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

  async localPeople(): Promise<Array<DeviceV3PersonChoice>> {
    return this.repository.cachedPeople();
  }

  async queueSpeakerAnnotation(utterances: Array<PhoneV3Utterance>, personId: string,
    name: string): Promise<void> {
    await this.queueAnnotation(utterances, personId, name, true, '');
  }

  async queueSoundClassification(utterances: Array<PhoneV3Utterance>, soundKind: string): Promise<void> {
    await this.queueAnnotation(utterances, '', '', false, soundKind);
  }

  // One transaction for both dimensions. Helpers below never start nested transactions.
  async queueAnnotation(utterances: Array<PhoneV3Utterance>, personId: string, name: string,
    personChanged: boolean, soundKind: string): Promise<void> {
    if (utterances.length === 0 || utterances.length > 2000 ||
      (!personChanged && soundKind.length === 0) ||
      (soundKind.length > 0 && PHONE_V3_SOUND_KINDS.indexOf(soundKind) < 0)) {
      throw new Error('请选择 1 至 2000 个片段，并选择人物或声音类型');
    }
    const ids = new Set<string>(utterances.map((row: PhoneV3Utterance): string => row.utteranceId));
    if (ids.size !== utterances.length || utterances.some((row: PhoneV3Utterance): boolean => row.status !== 'active')) {
      throw new Error('选择包含重复或失效片段，请重新核对');
    }
    const selections = utterances.map((value: PhoneV3Utterance): PhoneV3AnnotationSentence => {
      return { utterance_id: value.utteranceId, revision: value.revision, text: value.text,
        speaker_label: value.speakerLabel ?? '未知说话人', sound_kind: value.soundKind,
        session_id: value.sessionId, start_ms: value.startMs, end_ms: value.endMs };
    });
    await this.repository.beginTransaction();
    try {
      const projections = await this.repository.projectionRows('utterance');
      const current = new Map<string, PhoneV3ProjectionRow>();
      for (let projection of projections) { if (ids.has(projection.resourceId)) { current.set(projection.resourceId, projection); } }
      for (let reviewed of utterances) {
        const projection = current.get(reviewed.utteranceId);
        if (projection === undefined || projection.revision !== reviewed.revision ||
          (JSON.parse(projection.payloadJson) as AnnotationTargetPayload).status !== 'active') {
          throw new Error('片段已变化或不存在，请重新打开核对后保存');
        }
      }
      if (personChanged) {
        const people = await this.repository.cachedPeople();
        const person = people.find((value: DeviceV3PersonChoice): boolean => value.person_id === personId);
        if (personId.length > 0 && person === undefined) { throw new Error('请重新选择人物'); }
        const label = person === undefined ? name.trim() : person.display_name;
        if (label.length === 0 || label.length > 100) { throw new Error('人物姓名应为 1 至 100 字'); }
        const choice: DeviceV3PersonChoice = person ?? { person_id: newOperationId(), display_name: label, local: true };
        const payload: PhoneV3LocalAnnotation = { selections: selections, person_name: label };
        if (choice.local) { payload.new_person_id = choice.person_id; payload.display_name = label; }
        else { payload.person_id = choice.person_id; }
        await this.repository.cachePeople([choice]);
        await this.enqueueAnnotationItems('speaker.assign', payload);
      }
      if (soundKind.length > 0) {
        await this.enqueueAnnotationItems('segment.classify', { selections: selections,
          person_name: phoneV3SoundKindLabel(soundKind), sound_kind: soundKind });
      }
      await this.repository.commit();
    } catch (error) {
      await this.repository.rollback();
      throw error instanceof Error ? error : new Error(JSON.stringify(error));
    }
  }

  private async enqueueAnnotationItems(kind: string, payload: PhoneV3LocalAnnotation): Promise<void> {
    const predecessors = await this.repository.annotationOperations();
    for (let selection of payload.selections) {
      const dependencies: Array<string> = [];
      for (let operation of predecessors) {
        if (operation.kind !== kind) { continue; }
        const previous = operation.payload as PhoneV3LocalAnnotation;
        if (previous.selections.some((row: PhoneV3AnnotationSentence): boolean =>
          row.utterance_id === selection.utterance_id)) { dependencies.push(operation.operation_id); }
      }
      const item: PhoneV3LocalAnnotation = { selections: [selection], person_name: payload.person_name,
        person_id: payload.person_id, new_person_id: payload.new_person_id,
        display_name: payload.display_name, sound_kind: payload.sound_kind, depends_on: dependencies };
      await this.repository.enqueue({ operation_id: newOperationId(), kind: kind,
        base_revision: null, payload: item });
    }
  }

  async annotationConflictRows(payload: PhoneV3LocalAnnotation): Promise<Array<PhoneV3Utterance>> {
    return annotationRows(mergePhoneV3Sessions([], [], await this.repository.projectionRows('recording_session'),
      [], await this.repository.projectionRows('utterance')), payload);
  }

  async resolveAnnotationConflict(operationId: string, keepLocal: boolean,
    reviewed: Array<PhoneV3Utterance> = []): Promise<void> {
    const conflicts = await this.repository.conflictRows();
    const conflict = conflicts.find((value): boolean => value.operationId === operationId);
    if (conflict === undefined || ['speaker.assign', 'segment.classify'].indexOf(conflict.kind) < 0) { throw new Error('此标注审核已处理'); }
    const payload = JSON.parse(conflict.payloadJson) as PhoneV3LocalAnnotation;
    if (keepLocal) {
      const rows = await this.annotationConflictRows(payload);
      if (rows.length !== payload.selections.length || rows.some((row: PhoneV3Utterance): boolean => row.status !== 'active')) {
        throw new Error('部分发言已被删除或重新转写，请保留电脑结果后，重新选择需要标注的发言');
      }
      if (reviewed.length !== rows.length || rows.some((row: PhoneV3Utterance): boolean =>
        !reviewed.some((value: PhoneV3Utterance): boolean => value.utteranceId === row.utteranceId && value.revision === row.revision))) {
        throw new Error('审核期间发言又有更新，请重新打开本项核对');
      }
      payload.selections = rows.map((value: PhoneV3Utterance): PhoneV3AnnotationSentence => {
        return { utterance_id: value.utteranceId, revision: value.revision,
          text: value.text, speaker_label: value.speakerLabel ?? '未知说话人', sound_kind: value.soundKind };
      });
    }
    await this.repository.beginTransaction();
    try {
      if (keepLocal) {
        await this.repository.enqueue({ operation_id: newOperationId(), kind: conflict.kind,
          base_revision: null, payload: payload });
      }
      await this.repository.removeConflict(operationId);
      await this.repository.commit();
    } catch (error) {
      await this.repository.rollback();
      throw error instanceof Error ? error : new Error(JSON.stringify(error));
    }
  }

  async refreshRemoteProjection(): Promise<void> {
    await this.synchronize((): void => {}, true);
  }

  async synchronize(onStatus: (message: string) => void = (): void => {},
    pullOnly: boolean = false): Promise<PhoneV3SyncResult> {
    if (this.syncActive || activeSyncRepositories.has(this.repository)) { throw new Error('同步正在进行'); }
    activeSyncRepositories.add(this.repository);
    this.syncActive = true;
    this.syncCancelled = false;
    try {
      const backup = pullOnly || this.audioBackup === undefined ? new PhoneV3AudioBackupResult() :
        await this.audioBackup.backup();
      onStatus("录音备份已完成，正在连接电脑同步转写与处理状态…");
      const session = await this.remote.connect();
      const status = await session.status();
      if (status.contract_version !== V3_CONTRACT_VERSION ||
        status.projection_version !== V3_PROJECTION_VERSION) {
        throw new Error('电脑 V3 Device API 版本与 Phone 投影不兼容');
      }
      let cursor = await this.repository.currentCursor();
      let hasMore = true;
      let batches = 0;
      let submitted = 0;
      let stopped = '';
      const attempted: Array<string> = [];
      while (!this.syncCancelled && batches < 100) {
        const pending = pullOnly ? [] : await this.repository.pendingOperations(500, attempted);
        const candidates: Array<DeviceV3ClientOperation> = pending.filter((op): boolean =>
          attempted.indexOf(op.operation_id) < 0).map((op): DeviceV3ClientOperation => {
          return { operation_id: op.operation_id, kind: op.kind,
            base_revision: op.base_revision, payload: op.payload };
        });
        if (!hasMore && candidates.length === 0) { break; }
        const request = syncRequestBatch(cursor, candidates);
        const operations = request.client_operations;
        onStatus(`正在同步转写与处理状态：第 ${batches + 1} 批`);
        const response = await session.sync(request);
        await applySyncResponse(this.repository, response);
        for (let op of operations) { attempted.push(op.operation_id); }
        submitted += response.receipts.filter((receipt): boolean => receipt.status === 'applied' &&
          operations.some((op): boolean => op.operation_id === receipt.operation_id)).length;
        batches += 1;
        hasMore = response.has_more;
        if (hasMore && response.next_cursor === cursor && response.changes.length === 0) {
          stopped = 'no_progress'; break;
        }
        cursor = response.next_cursor;
      }
      onStatus("正在获取最新审核结果…");
      const reviews = await session.reviews();
      await this.repository.replaceReviewItems(reviews.items);
      try {
        const people = await session.annotations({ action: 'people' });
        await this.repository.cachePeople(people.people ?? []);
      } catch (error) { /* Cached people remain usable while the computer is unavailable. */ }
      const result = new PhoneV3SyncResult(batches, submitted, cursor, backup);
      const statusAfter = await this.repository.v3Status();
      const conflicts = await this.repository.conflictRows();
      result.remainingOperations = statusAfter.pendingOperations + conflicts.length;
      result.pullPending = hasMore;
      result.completion = this.syncCancelled ? 'cancelled' : stopped ||
        (batches >= 100 ? 'budget_exhausted' : hasMore || result.remainingOperations > 0 ? 'waiting' : 'complete');
      onStatus(result.summary());
      return result;
    } catch (error) {
      const message = error instanceof Error ? error.message : JSON.stringify(error);
      await this.repository.markSyncFailure(message);
      throw new Error(message);
    } finally { this.syncActive = false; activeSyncRepositories.delete(this.repository); }
  }

  async rebuild(): Promise<PhoneV3SyncResult> {
    await this.repository.rebuildFromComputer();
    return this.synchronize();
  }

  async resolveReview(request: DeviceV3ReviewActionRequest): Promise<Array<PhoneV3ReviewItem>> {
    const session = await this.remote.connect();
    let response: DeviceV3ReviewActionResponse;
    try { response = await session.resolveReview(request); }
    catch (error) {
      if ((error as ReviewRemoteError).reviewRequestNotSent === true) { throw error as Error; }
      const status = (error as ReviewRemoteError).statusCode;
      if (status !== undefined && status >= 400 && status < 500) { throw error as Error; }
      throw new PhoneV3ReviewSubmissionError(false);
    }
    try { await this.repository.replaceReviewItems(response.reviews.items); }
    catch (_) { throw new PhoneV3ReviewSubmissionError(true); }
    return phoneV3ReviewSnapshotItems(response.reviews.items);
  }

  async refreshReviews(): Promise<Array<PhoneV3ReviewItem>> {
    const session = await this.remote.connect();
    const response = await session.reviews();
    await this.repository.replaceReviewItems(response.items);
    return phoneV3ReviewSnapshotItems(response.items);
  }

  async annotations(request: DeviceV3AnnotationRequest): Promise<DeviceV3AnnotationResponse> {
    const session = await this.remote.connect();
    const response = await session.annotations(request);
    if (response.people !== undefined) { await this.repository.cachePeople(response.people); }
    if (response.utterances !== undefined) {
      await this.repository.beginTransaction();
      try {
        for (let index = 0; index < response.utterances.length; index += 1) {
          const utterance = validateV3UtteranceDto(response.utterances[index]);
          await this.repository.applyChange({ sequence: 0, resource_type: 'utterance',
            resource_id: utterance.utterance_id, revision: utterance.revision,
            operation: 'upsert', resource: utterance });
        }
        await this.repository.commit();
      } catch (error) {
        await this.repository.rollback();
        throw error instanceof Error ? error : new Error(JSON.stringify(error));
      }
    }
    if (response.reviews !== undefined) {
      await this.repository.replaceReviewItems(response.reviews.items);
    }
    return response;
  }

  async loadReviewAudio(reviewId: string, prototypeId: string): Promise<DeviceV3ReviewAudioResponse> {
    const session = await this.remote.connect();
    return session.reviewAudio({ review_id: reviewId, prototype_id: prototypeId });
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
      local === undefined ? 0 : local.durationMs, uploadStatus(links, sessionId, sessionKey),
      processing === undefined ? 'not_started' : text(processing.payload.status, 'pending'),
      processing === undefined ? '' : text(processing.payload.current_stage, ''),
      processing === undefined ? 0 : numberValue(processing.payload.progress, 0),
      sessionUtterances(utteranceRows, sessionId)));
  }
  for (let localIndex = 0; localIndex < localFacts.length; localIndex += 1) {
    const local = localFacts[localIndex];
    const linkedId = linkedSessionId(links, local.sessionKey);
    if (hasSessionIdentity(cards, linkedId, local.sessionKey, local.localGroupKey)) {
      continue;
    }
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

function sessionUtterances(rows: Array<PhoneV3ProjectionRow>, sessionId: string): Array<PhoneV3Utterance> {
  const values: Array<PhoneV3Utterance> = [];
  for (let index = 0; index < rows.length; index += 1) {
    try {
      const payload = validateV3UtteranceDto(parseProjectionObject(rows[index]));
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
      throw projectionRowError(rows[index], 'utterance', error as Object);
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

function parseRecording(row: PhoneV3ProjectionRow): RecordingPayload {
  try {
    return parseProjectionObject(row) as RecordingPayload;
  } catch (error) {
    throw projectionRowError(row, 'recording_session', error as Object);
  }
}

function parseProjectionObject(row: PhoneV3ProjectionRow): Object {
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
