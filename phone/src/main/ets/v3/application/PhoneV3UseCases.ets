import { annotationTiming } from './PhoneAnnotationTiming';
import { syncRequestBatch, PhoneSyncBatchPolicy, jsonBytes } from '../data/PhoneSyncBatch';
import { PhonePendingOperation } from '../data/PhoneSyncProjection';
import { PHONE_V3_SOUND_KINDS, phoneV3SoundKindLabel } from '../domain/PhoneV3SoundKind';
import { PhoneV3Evidence } from '../domain/PhoneV3PersonFact';
import { PhoneV3LocalAnnotation, PhoneV3AnnotationSentence, applyLocalAnnotations, applyAnnotationRows, applyAnnotationConflicts, applyAnnotationConflictsToRows, annotationRows } from '../domain/PhoneV3LocalAnnotation';
import {
  DeviceV3ClientOperation,
  DeviceV3PersonChoice,
  DeviceV3AnnotationRequest,
  DeviceV3AnnotationResponse,
  DeviceV3ReviewActionRequest,
  DeviceV3ReviewActionResponse,
  DeviceV3ReviewAudioResponse,
  DeviceV3ReviewSnapshot,
  DeviceV3SyncRequest
} from '../../computer/ComputerTransferProtocol';
import {
  V3_CONTRACT_VERSION,
  V3_PROJECTION_VERSION,
  validateV3ReminderDto,
  validateV3UtteranceDto
} from '../contracts/V3ContractModels';
import { applySyncResponse } from '../data/PhoneSyncProjection';
import { phoneV3ReviewItems, phoneV3ReviewSnapshotItems, overlayPendingPurityReviews } from '../data/PhoneV3ReviewProjection';
import { phoneV3VoiceCandidates } from '../domain/PhoneV3ReviewModels';
import { validateReviewSample } from '../domain/PhoneV3ReviewAudioValidation';
import {
  PhoneSessionCompletionRecord,
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
import { PhoneV3ReviewAudioCachePort } from './PhoneV3Ports';

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
  operationIds: Array<string> = [];
  receiptStates: Array<string> = [];
  changed: boolean = false;
  utteranceIds: Array<string> = [];
  requiresReload: boolean = false;
  reviewsChanged: boolean = false;
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
  private syncBatchPolicy: PhoneSyncBatchPolicy = new PhoneSyncBatchPolicy();
  private reviewVersion: string | undefined = undefined;
  private peopleVersion: string | undefined = undefined;
  onCommitted: (result: PhoneV3SyncResult) => void = (): void => {};
  private publishCommitted(result: PhoneV3SyncResult): void {
    try { this.onCommitted(result); }
    catch (_) { console.warn('[sync] committed notification deferred; durable projection retained'); }
  }

  private reviewAudioCache?: PhoneV3ReviewAudioCachePort;
  private purityAudioCache?: PhoneV3ReviewAudioCachePort;
  private purityFlush: Promise<void> | undefined = undefined;
  private voiceFlush: Promise<void> | undefined = undefined;
  private purityPack: Promise<void> | undefined = undefined;
  private purityPackAgain: boolean = false;
  private syncActive: boolean = false;
  private syncCancelled: boolean = false;
  cancelSynchronize(): void { this.syncCancelled = true; }

  async backupRecordings(): Promise<PhoneV3AudioBackupResult> {
    return this.audioBackup === undefined ? new PhoneV3AudioBackupResult() : this.audioBackup.backup();
  }

  private repository: PhoneV3ProjectionRepositoryPort;
  private localAudio: PhoneV3LocalAudioRepositoryPort;
  private remote: PhoneV3RemotePort;
  private reminderScheduler: PhoneV3ReminderSchedulerPort | undefined;
  private audioBackup: PhoneV3AudioBackupPort | undefined;
  private cachedUtteranceRows: Map<string, Array<PhoneV3ProjectionRow>> | null = null;

  constructor(repository: PhoneV3ProjectionRepositoryPort,
    localAudio: PhoneV3LocalAudioRepositoryPort, remote: PhoneV3RemotePort,
    reminderScheduler?: PhoneV3ReminderSchedulerPort,
    audioBackup?: PhoneV3AudioBackupPort, reviewAudioCache?: PhoneV3ReviewAudioCachePort,
    purityAudioCache?: PhoneV3ReviewAudioCachePort) {
    this.reviewAudioCache = reviewAudioCache;
    this.purityAudioCache = purityAudioCache;
    this.repository = repository;
    this.localAudio = localAudio;
    this.remote = remote;
    this.reminderScheduler = reminderScheduler;
    this.audioBackup = audioBackup;
  }

  async loadLocal(): Promise<Array<PhoneV3LocalAudioFact>> {
    return this.localAudio.list();
  }

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

  async loadCached(localFacts: Array<PhoneV3LocalAudioFact>): Promise<PhoneV3Snapshot> {
    const recordings = await this.repository.projectionRows('recording_session');
    const processing = await this.repository.projectionRows('processing_run');
    const grouped = this.repository.projectionUtterancesBySession === undefined ? null :
      this.cachedUtteranceRows ?? await this.repository.projectionUtterancesBySession();
    if (grouped !== null) { this.cachedUtteranceRows = grouped; }
    const utterances = grouped === null ? await this.repository.projectionRows('utterance') : [];
    const reviews = await this.repository.projectionRows('review_item');
    const reminders = await this.repository.projectionRows('reminder');
    const links = await this.repository.localAudioLinks();
    const conflicts = await this.repository.conflictRows();
    const status = await this.repository.v3Status();
    const paired = await this.remote.isPaired();
    const reminderValues = phoneV3Reminders(reminders);
    await this.reconcileReminders(reminderValues);
    const completions = await this.repository.localSessionCompletions();
    const sessions = mergePhoneV3Sessions(localFacts, links, recordings, processing, utterances,
      completions);
    const annotations = await this.repository.annotationOperations();
    if (grouped === null) {
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
      conflicts, status, paired, reminderValues, await this.withPendingPurity(phoneV3ReviewItems(reviews)));
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

  async refreshUtterances(snapshot: PhoneV3Snapshot, ids: Array<string>): Promise<PhoneV3Snapshot> {
    this.cachedUtteranceRows = null;
    const rows = await this.repository.projectionRows('utterance', ids);
    const operations = await this.repository.annotationOperations(ids);
    const status = await this.repository.v3Status();
    const changed = new Set<string>(ids);
    const bySession = indexSessionUtterances(rows);
    const sessions = snapshot.sessions.map((session: PhoneV3SessionCard): PhoneV3SessionCard => {
      const fresh = bySession.get(session.sessionId) ?? [];
      if (fresh.length === 0 && !ids.some((id: string): boolean => session.hasUtterance(id))) { return session; }
      const merged = session.utterances.filter((row): boolean => !changed.has(row.utteranceId)).concat(fresh);
      merged.sort((a,b): number => a.startMs-b.startMs || a.utteranceId.localeCompare(b.utteranceId));
      const index = new Map<string, PhoneV3Utterance>();
      for (let row of fresh) { index.set(row.utteranceId,row); }
      applyAnnotationRows(index, operations);
      return new PhoneV3SessionCard(session.id,session.sessionId,session.sessionKey,session.localGroupKey,
        session.capturedStart,session.startedAt,session.deviceName,session.state,session.statusCode,session.progress,
        session.revision,session.updatedAt,session.localPaths,session.sizeBytes,session.durationMs,session.uploadStatus,
        session.processingStatus,session.processingStage,session.processingProgress,merged);
    });
    return new PhoneV3Snapshot(sessions,snapshot.conflicts,status,snapshot.paired,snapshot.reminders,snapshot.reviewItems);
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
    await this.repository.beginTransaction();
    try { await this.repository.enqueue(operation); await this.repository.commit(); }
    catch (error) { await this.repository.rollback(); throw error as Error; }
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
    personChanged: boolean, soundKind: string): Promise<Array<PhonePendingOperation>> {
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
    const committed: Array<PhonePendingOperation> = [];
    await this.repository.beginTransaction();
    try {
      const projections = await this.repository.projectionRows('utterance', Array.from(ids));
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
        const people = personId.length > 0 ? await this.repository.cachedPeople(personId) : [];
        const person = people.find((value: DeviceV3PersonChoice): boolean => value.person_id === personId);
        if (personId.length > 0 && person === undefined) { throw new Error('请重新选择人物'); }
        const label = person === undefined ? name.trim() : person.display_name;
        if (label.length === 0 || label.length > 100) { throw new Error('人物姓名应为 1 至 100 字'); }
        const choice: DeviceV3PersonChoice = person ?? { person_id: newOperationId(), display_name: label, local: true };
        const payload: PhoneV3LocalAnnotation = { selections: selections, person_name: label };
        if (choice.local) { payload.new_person_id = choice.person_id; payload.display_name = label; }
        else { payload.person_id = choice.person_id; }
        await this.repository.cachePeople([choice]);
        committed.push(...await this.enqueueAnnotationItems('speaker.assign', payload));
      }
      if (soundKind.length > 0) {
        committed.push(...await this.enqueueAnnotationItems('segment.classify', { selections: selections,
          person_name: phoneV3SoundKindLabel(soundKind), sound_kind: soundKind }));
      }
      await this.repository.commit();
      annotationTiming('T0-local-commit', committed.map((op): string => op.operation_id));
      return committed;
    } catch (error) {
      await this.repository.rollback();
      throw error instanceof Error ? error : new Error(JSON.stringify(error));
    }
  }

  private async enqueueAnnotationItems(kind: string, payload: PhoneV3LocalAnnotation): Promise<Array<PhonePendingOperation>> {
    const predecessors = await this.repository.annotationOperations(payload.selections.map((row): string => row.utterance_id));
    const committed: Array<PhonePendingOperation> = [];
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
      const operation: PhonePendingOperation = { operation_id: newOperationId(), kind: kind,
        base_revision: null, payload: item, attempt_count: 0 };
      await this.repository.enqueue(operation);
      committed.push(operation);
    }
    return committed;
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
    pullOnly: boolean = false, maxBatches: number = 100): Promise<PhoneV3SyncResult> {
    if (this.syncActive || activeSyncRepositories.has(this.repository)) { throw new Error('同步正在进行'); }
    activeSyncRepositories.add(this.repository);
    this.syncActive = true;
    this.syncCancelled = false;
    let dispatched: Array<string> = [];
    try {
      const backup = new PhoneV3AudioBackupResult();
      let changed = false;
      const utteranceIds = new Set<string>();
      let requiresReload = false;
      const statusBefore = await this.repository.v3Status();
      const pendingBefore = statusBefore.pendingOperations + (statusBefore.confirmedOperations ?? 0);
      onStatus('正在同步标注与电脑状态…');
      const session = await this.remote.connect();
      const status = await session.status();
      if ((status.contract_version !== V3_CONTRACT_VERSION && status.contract_version !== '3.7.0') ||
        status.projection_version !== V3_PROJECTION_VERSION) {
        throw new Error('电脑 V3 Device API 版本与 Phone 投影不兼容');
      }
      let cursor = await this.repository.currentCursor();
      const adaptive = (status.sync_features ?? []).indexOf('adaptive-batch-v1') >= 0;
      const bootstrap = (status.sync_features ?? []).indexOf('snapshot-v1') >= 0;
      const policy = this.syncBatchPolicy;
      let hasMore = true;
      let batches = 0;
      let submitted = 0;
      let stopped = '';
      const attempted: Array<string> = [];
      while (!this.syncCancelled && batches < maxBatches) {
        const pending = pullOnly ? [] : await this.repository.pendingOperations(adaptive ? policy.operations : 32, attempted);
        if (batches === 0) { annotationTiming('T1-schedule-complete', pending.map((op): string => op.operation_id)); }
        const candidates: Array<DeviceV3ClientOperation> = pending.filter((op): boolean =>
          attempted.indexOf(op.operation_id) < 0).map((op): DeviceV3ClientOperation => {
          return { operation_id: op.operation_id, kind: op.kind,
            base_revision: op.base_revision, payload: op.payload };
        });
        if (!hasMore && candidates.length === 0) { break; }
        const request = syncRequestBatch(cursor, candidates, adaptive ? policy.operations : 32,
          adaptive ? policy.pullLimit : 500, adaptive ? policy.pullBytes : undefined, bootstrap);
        const operations = request.client_operations;
        onStatus(`正在同步转写与处理状态：第 ${batches + 1} 批`);
        dispatched = operations.map((operation): string => operation.operation_id);
        annotationTiming('T2-sync-dispatch', dispatched);
        const response = await session.sync(request);
        annotationTiming('T4-response-decoded', dispatched);
        const commitStarted = Date.now();
        await applySyncResponse(this.repository, response);
        if (response.changes.some((change): boolean => change.resource_type === 'utterance')) {
          this.cachedUtteranceRows = null;
        }
        // The transaction is durable. UI/network failures must never mark it failed.
        dispatched = [];
        if (adaptive) {
          policy.observe(operations.length, jsonBytes(JSON.stringify(request)), response.transaction_ms,
            response.changes.length, jsonBytes(JSON.stringify(response)), Date.now() - commitStarted);
        }
        const committed = new PhoneV3SyncResult(1, response.receipts.length, response.next_cursor, backup);
        committed.changed = response.receipts.length > 0 || response.changes.length > 0;
        committed.operationIds = response.receipts.map((receipt): string => receipt.operation_id);
        committed.receiptStates = response.receipts.map((receipt): string => receipt.status);
        committed.utteranceIds = response.changes.filter((change): boolean => change.resource_type === 'utterance')
          .map((change): string => change.resource_id);
        for (let op of operations) {
          if (!response.receipts.some((receipt): boolean => receipt.operation_id === op.operation_id)) { continue; }
          const payload = op.payload as PhoneV3LocalAnnotation;
          for (let selection of payload.selections ?? []) { committed.utteranceIds.push(selection.utterance_id); }
          if (op.kind === 'utterance.correct') { committed.utteranceIds.push((op.payload as UtteranceCorrectionPayload).utterance_id); }
        }
        committed.utteranceIds = Array.from(new Set<string>(committed.utteranceIds));
        committed.requiresReload = response.receipts.some((receipt): boolean => receipt.status !== 'applied') ||
          response.changes.some((change): boolean => change.resource_type !== 'utterance');
        if (response.changes.some((change): boolean => change.resource_type === 'review_item')) { this.reviewVersion = undefined; }
        for (let id of committed.utteranceIds) { utteranceIds.add(id); }
        requiresReload = requiresReload || committed.requiresReload;
        annotationTiming('T5-receipt-commit', committed.operationIds);
        if (committed.changed) { this.publishCommitted(committed); }
        changed = changed || response.changes.length > 0 || response.receipts.length > 0;
        for (let change of response.changes) {
          if (change.resource_type === 'utterance') { utteranceIds.add(change.resource_id); }
          else { requiresReload = true; }
        }
        if (response.receipts.some((receipt): boolean => receipt.status !== 'applied')) { requiresReload = true; }
        dispatched = [];
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
      const result = new PhoneV3SyncResult(batches, submitted, cursor, backup);
      const statusAfter = await this.repository.v3Status();
      // An empty pull can retire an already-applied overlay once its projection is visible.
      // This local change must invalidate the UI even without a new server change/receipt.
      if (pendingBefore !== statusAfter.pendingOperations + (statusAfter.confirmedOperations ?? 0)) {
        changed = true;
        if (utteranceIds.size === 0) { requiresReload = true; }
      }
      result.changed = changed;
      result.utteranceIds = Array.from(utteranceIds); result.requiresReload = requiresReload;
      const conflicts = await this.repository.conflictRows();
      result.remainingOperations = statusAfter.pendingOperations + conflicts.length;
      result.pullPending = hasMore;
      result.completion = this.syncCancelled ? 'cancelled' : stopped ||
        (batches >= maxBatches ? 'budget_exhausted' : hasMore || result.remainingOperations > 0 ? 'waiting' : 'complete');
      onStatus(result.summary());
      return result;
    } catch (error) {
      const message = error instanceof Error ? error.message : JSON.stringify(error);
      await this.repository.markSyncFailure(message, dispatched);
      throw error instanceof Error ? error : new Error(message);
    } finally { this.syncActive = false; activeSyncRepositories.delete(this.repository); }
  }

  async refreshSupplementary(): Promise<void> {
    await this.flushVoiceReviews().catch((): void => {});
    await this.flushPurityReviews().catch((): void => {});
    const session = await this.remote.connect();
    const reviews = await session.reviews();
    const reviewsChanged = await this.storeReviews(reviews);
    if (reviewsChanged) {
      const committed = new PhoneV3SyncResult(0, 0, '', new PhoneV3AudioBackupResult());
      committed.changed = true; committed.reviewsChanged = true;
      this.publishCommitted(committed);
    }
    this.preparePurityAudioPack(reviewsChanged).catch((): void => {});
    const people = await session.annotations({ action: 'people' });
    if (people.version === undefined || people.version !== this.peopleVersion) {
      await this.cacheRemotePeople(people.people ?? []);
      this.peopleVersion = people.version;
    }
  }

  private async storeReviews(reviews: DeviceV3ReviewSnapshot): Promise<boolean> {
    if (reviews.version !== undefined && reviews.version === this.reviewVersion) { return false; }
    const changed = await this.repository.replaceReviewItems(reviews.items);
    this.reviewVersion = reviews.version;
    return changed;
  }

  async refreshReviewSnapshot(snapshot: PhoneV3Snapshot): Promise<PhoneV3Snapshot> {
    const reviews = phoneV3ReviewItems(await this.repository.projectionRows('review_item'));
    return new PhoneV3Snapshot(snapshot.sessions, snapshot.conflicts, snapshot.sync,
      snapshot.paired, snapshot.reminders, await this.withPendingPurity(reviews));
  }

  private async withPendingPurity(items: Array<PhoneV3ReviewItem>): Promise<Array<PhoneV3ReviewItem>> {
    return overlayPendingPurityReviews(items, await this.repository.pendingPurityReviews());
  }

  async pendingVoiceReviews(): Promise<Array<DeviceV3ReviewActionRequest>> {
    return this.repository.pendingVoiceReviews();
  }

  async queueVoiceReview(request: DeviceV3ReviewActionRequest): Promise<void> {
    request.operation_id = newOperationId();
    await this.repository.enqueueVoiceReview(request);
  }

  flushVoiceReviews(): Promise<void> {
    if (this.voiceFlush !== undefined) { return this.voiceFlush; }
    const run = async (): Promise<void> => {
      const pending = await this.repository.pendingVoiceReviews();
      let failure: Error | undefined = undefined;
      for (const request of pending) {
        try {
          const session = await this.remote.connect();
          const response = await session.resolveReview(request);
          await this.storeReviews(response.reviews);
          await this.repository.removeVoiceReview(request.operation_id ?? '');
          const committed = new PhoneV3SyncResult(0, 0, '', new PhoneV3AudioBackupResult());
          committed.changed = true; committed.reviewsChanged = true;
          this.publishCommitted(committed);
        } catch (error) {
          failure = error instanceof Error ? error : new Error(JSON.stringify(error));
        }
      }
      if (failure !== undefined) { throw failure; }
    };
    this.voiceFlush = run().finally((): void => { this.voiceFlush = undefined; });
    return this.voiceFlush;
  }

  async queuePurityReview(request: DeviceV3ReviewActionRequest): Promise<Array<PhoneV3ReviewItem>> {
    request.operation_id = newOperationId();
    await this.repository.enqueuePurityReview(request);
    const items = await this.withPendingPurity(phoneV3ReviewItems(await this.repository.projectionRows('review_item')));
    this.flushPurityReviews().catch((): void => {});
    return items;
  }

  flushPurityReviews(): Promise<void> {
    if (this.purityFlush !== undefined) { return this.purityFlush; }
    const run = async (): Promise<void> => {
      const pending = await this.repository.pendingPurityReviews();
      let failure: Error | undefined = undefined;
      const blockedReviews = new Set<string>();
      for (const request of pending) {
        if (blockedReviews.has(request.review_id)) { continue; }
        try {
          const session = await this.remote.connect();
          const response = await session.resolveReview(request);
          await this.storeReviews(response.reviews);
          await this.repository.removePurityReview(request.operation_id ?? '');
          const committed = new PhoneV3SyncResult(0, 0, '', new PhoneV3AudioBackupResult());
          committed.changed = true; committed.reviewsChanged = true;
          this.publishCommitted(committed);
        } catch (error) {
          blockedReviews.add(request.review_id);
          failure = error instanceof Error ? error : new Error(JSON.stringify(error));
        }
      }
      if (failure !== undefined) { throw failure; }
    };
    this.purityFlush = run().finally((): void => { this.purityFlush = undefined; });
    return this.purityFlush;
  }

  async rebuild(): Promise<PhoneV3SyncResult> {
    this.reviewVersion = undefined; this.peopleVersion = undefined;
    this.cachedUtteranceRows = null;
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
    try { await this.storeReviews(response.reviews); }
    catch (_) { throw new PhoneV3ReviewSubmissionError(true); }
    return this.withPendingPurity(phoneV3ReviewSnapshotItems(response.reviews.items));
  }

  async refreshReviews(): Promise<Array<PhoneV3ReviewItem>> {
    if (this.purityFlush !== undefined) {
      return this.withPendingPurity(phoneV3ReviewItems(await this.repository.projectionRows('review_item')));
    }
    const session = await this.remote.connect();
    const response = await session.reviews();
    await this.storeReviews(response);
    this.preparePurityAudioPack().catch((): void => {});
    return this.withPendingPurity(phoneV3ReviewSnapshotItems(response.items));
  }

  async annotations(request: DeviceV3AnnotationRequest): Promise<DeviceV3AnnotationResponse> {
    const session = await this.remote.connect();
    const response = await session.annotations(request);
    if (response.people !== undefined) { await this.cacheRemotePeople(response.people); }
    if (response.utterances !== undefined) {
      this.cachedUtteranceRows = null;
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
      await this.storeReviews(response.reviews);
    }
    return response;
  }

  async loadReviewAudio(reviewId: string, prototypeId: string, prefetch: boolean = false): Promise<DeviceV3ReviewAudioResponse> {
    const items = phoneV3ReviewItems(await this.repository.projectionRows('review_item', [reviewId]));
    const item = items.find((value): boolean => value.reviewId === reviewId);
    const cache = item?.kind === 'speaker_profile_purity' || item?.kind === 'blind_identity_review' ? this.purityAudioCache : this.reviewAudioCache;
    if (cache === undefined || this.remote.audioNamespace === undefined) {
      const session = await this.remote.connect();
      return session.reviewAudio({ review_id: reviewId, prototype_id: prototypeId });
    }
    const namespace = await this.remote.audioNamespace();
    if (!namespace) { await cache.clear(); throw new Error('请先连接受信任的电脑'); }
    const candidate = item === undefined ? undefined : phoneV3VoiceCandidates(item).find((value): boolean => value.prototypeId === prototypeId);
    if (candidate === undefined || !candidate.hasAudio) { throw new Error('当前样本已不可用'); }
    const download = async (): Promise<DeviceV3ReviewAudioResponse> => {
      const session = await this.remote.connect();
      const response = await session.reviewAudio({ review_id: reviewId, prototype_id: prototypeId,
        audition_key: candidate.auditionKey, audio_content_key: candidate.audioContentKey, prefetch: prefetch });
      validateReviewSample(response, reviewId, candidate);
      if (await this.remote.audioNamespace!() !== namespace) { throw new Error('电脑身份已变化'); }
      return response;
    };
    // Old metadata stays playable online, but cannot establish a persistent key.
    if (!candidate.audioContentKey) {
      if (prefetch) { throw new Error('旧版本不预取'); }
      const session = await this.remote.connect();
      return session.reviewAudio({ review_id: reviewId, prototype_id: prototypeId });
    }
    const response = await cache.prepare(namespace, candidate.audioContentKey, download, prefetch);
    response.review_id = reviewId; response.prototype_id = prototypeId;
    // Content can be shared by different prototypes. Rebind only presentation
    // metadata; ordered windows/content identity are still validated below.
    response.audition_key = candidate.auditionKey;
    try {
      validateReviewSample(response, reviewId, candidate);
      if (await this.remote.audioNamespace() !== namespace) { throw new Error('电脑身份已变化'); }
      return response;
    } catch (error) { if (!prefetch) { cache.release(response.local_audio_path ?? ''); } throw error as Error; }
  }

  async loadPurityContext(reviewId: string, taskId: string, prefetch: boolean = false): Promise<DeviceV3ReviewAudioResponse> {
    const items = phoneV3ReviewItems(await this.repository.projectionRows('review_item', [reviewId]));
    const item = items.find((value): boolean => value.reviewId === reviewId);
    const candidate = item === undefined ? undefined : phoneV3VoiceCandidates(item).find((value): boolean => value.prototypeId === taskId);
    if (candidate === undefined || !candidate.contextAudioContentKey) { throw new Error('上下文原音尚未准备好'); }
    const cache = this.purityAudioCache;
    if (cache === undefined || this.remote.audioNamespace === undefined) { throw new Error('上下文离线缓存不可用'); }
    const namespace = await this.remote.audioNamespace();
    if (!namespace) { throw new Error('请先连接受信任的电脑'); }
    const response = await cache.prepare(namespace, candidate.contextAudioContentKey, async (): Promise<DeviceV3ReviewAudioResponse> => {
      const session = await this.remote.connect();
      const value = await session.reviewAudio({ review_id: reviewId, prototype_id: taskId,
        audio_content_key: candidate.contextAudioContentKey, context: true, prefetch: prefetch });
      if (value.audio_content_key !== candidate.contextAudioContentKey || await this.remote.audioNamespace!() !== namespace) {
        throw new Error('上下文原音已变化');
      }
      return value;
    }, prefetch);
    response.review_id = reviewId; response.prototype_id = taskId;
    return response;
  }

  preparePurityAudioPack(rerunIfActive: boolean = false): Promise<void> {
    if (this.purityPack !== undefined) {
      if (rerunIfActive) { this.purityPackAgain = true; }
      return this.purityPack;
    }
    const run = async (): Promise<void> => {
      const items = phoneV3ReviewItems(await this.repository.projectionRows('review_item'));
      const total = items.filter((item: PhoneV3ReviewItem): boolean => item.kind === 'speaker_profile_purity' || item.kind === 'blind_identity_review').length;
      let prepared = 0;
      for (const item of items) {
        if (item.kind !== 'speaker_profile_purity' && item.kind !== 'blind_identity_review') { continue; }
        const candidate = phoneV3VoiceCandidates(item)[0];
        if (candidate === undefined || !candidate.hasAudio) { continue; }
        try {
          await this.loadReviewAudio(item.reviewId, candidate.prototypeId, true);
          if (!candidate.contextAudioContentKey) { continue; }
          await this.loadPurityContext(item.reviewId, candidate.prototypeId, true);
        } catch (error) {
          console.warn(`[purity-audio] interrupted after ${prepared}/${total}`);
          throw error as Error;
        }
        prepared += 1;
        if (prepared % 20 === 0 || prepared === total) { console.info(`[purity-audio] prepared ${prepared}/${total}`); }
      }
      console.info(`[purity-audio] pass complete ${prepared}/${total}`);
    };
    this.purityPack = run().finally((): void => {
      this.purityPack = undefined;
      if (this.purityPackAgain) {
        this.purityPackAgain = false;
        this.preparePurityAudioPack().catch((): void => {});
      }
    });
    return this.purityPack;
  }

  releaseReviewAudio(response: DeviceV3ReviewAudioResponse): void {
    this.reviewAudioCache?.release(response.local_audio_path ?? '');
    this.purityAudioCache?.release(response.local_audio_path ?? '');
  }
  cancelReviewPrefetch(): void { this.reviewAudioCache?.cancelPrefetch(); }
  async clearReviewAudio(): Promise<void> { await this.reviewAudioCache?.clear(); }

  private async cacheRemotePeople(people: Array<DeviceV3PersonChoice>): Promise<void> {
    const cached = await this.repository.cachedPeople();
    const changed = people.filter((person): boolean => !cached.some((old): boolean =>
      old.person_id === person.person_id && old.display_name === person.display_name && old.local === person.local));
    if (changed.length === 0) { return; }
    await this.repository.beginTransaction();
    try { await this.repository.cachePeople(changed); await this.repository.commit(); }
    catch (error) { await this.repository.rollback(); throw error as Error; }
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

function indexSessionUtterances(rows: Array<PhoneV3ProjectionRow>): Map<string, Array<PhoneV3Utterance>> {
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
