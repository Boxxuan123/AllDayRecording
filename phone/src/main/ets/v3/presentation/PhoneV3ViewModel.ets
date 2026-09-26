import { phoneV3VoiceCandidates } from '../domain/PhoneV3ReviewModels';
import { validateReviewSample } from '../domain/PhoneV3ReviewAudioValidation';
import { PhoneV3ReviewAudioCache } from '../data/PhoneV3ReviewAudioCache';
import { PhoneV3VoiceTask } from '../domain/PhoneV3VoiceReviewTask';
import { PhoneV3LocalAnnotation, applyAnnotationRows } from '../domain/PhoneV3LocalAnnotation';
import { indexedUtterances, retainAnnotationIndex } from '../domain/PhoneV3AnnotationIndex';
import { ComputerUploadProgress } from '../../computer/ComputerRecordingUploadService';
import { common } from '@kit.AbilityKit';
import { PhoneSyncCoordinator, PhoneSyncWorkResult, PhoneSyncCoordinatorPort } from '../application/PhoneSyncCoordinator';
import { PhoneSyncEnvironment } from '../runtime/PhoneSyncEnvironment';
import { DeviceV3ReviewActionRequest, DeviceV3PersonChoice, DeviceV3AnnotationStatus } from '../../computer/ComputerTransferProtocol';
import { PhoneV3UseCases, PhoneV3ReviewSubmissionError, mergePhoneV3Sessions } from '../application/PhoneV3UseCases';
import { phoneV3VoiceTasks, PhoneV3VoiceEvidenceIndex, phoneV3EvidencePending } from '../domain/PhoneV3VoiceReviewTask';
import { PhoneV3DeviceBridgePort } from '../application/PhoneV3Ports';
import { PhoneProjectionRepository } from '../data/PhoneProjectionRepository';
import { PhoneV3ComputerBackup } from '../data/PhoneV3ComputerBackup';
import { PhoneV3DeviceRemote } from '../data/PhoneV3DeviceRemote';
import { PhoneV3LocalAudioRepository } from '../data/PhoneV3LocalAudioRepository';
import { PhoneV3ReminderScheduler } from '../data/PhoneV3ReminderScheduler';
import { PhoneV3ReviewAudioPlayer } from '../data/PhoneV3ReviewAudioPlayer';
import {
  PhoneV3DeviceState,
  PhoneV3LocalAudioFact,
  PhoneV3SessionCard,
  PhoneV3Snapshot,
  PhoneV3SyncStatus,
  PhoneV3Utterance
} from '../domain/PhoneV3Models';
import {
  PhoneV3UiAction,
  PhoneV3UiActionType,
  PhoneV3UiState,
  PHONE_V3_UI_STATE_STORAGE_KEY,
  reducePhoneV3Ui,
  selectedPhoneV3Session
} from './PhoneV3UiState';

enum PhoneV3RetryAction {
  NONE,
  WATCH_SYNC,
  WATCH_CONTROL,
  WIFI_TRANSFER,
  RECONNECT,
  COMPUTER_SYNC,
  REBUILD,
  PLAYBACK
}

class PhoneV3PendingReview {
  reviewId: string;
  prototypeId: string;
  action: string;
  state: string;
  constructor(reviewId: string, prototypeId: string, action: string, state: string) {
    this.reviewId = reviewId; this.prototypeId = prototypeId; this.action = action; this.state = state;
  }
}

@Observed
export class PhoneV3ViewModel {
  private reviewSubmissions: Map<string, PhoneV3PendingReview> = new Map<string, PhoneV3PendingReview>();
  snapshot: PhoneV3Snapshot = new PhoneV3Snapshot();
  device: PhoneV3DeviceState = new PhoneV3DeviceState();
  selectedSessionId: string = '';
  localReady: boolean = false;
  cacheReady: boolean = false;
  busy: boolean = false;
  annotationRefreshing: boolean = false;
  annotationSaving: boolean = false;
  private annotationRefreshTask: Promise<void> | undefined = undefined;
  computerProgress: ComputerUploadProgress = new ComputerUploadProgress('', 0, 0, 0, 0);
  completedSessionKeys: Array<string> = [];
  computerSyncActive: boolean = false;
  computerSyncMessage: string = '';
  computerSyncError: string = '';
  backupActive: boolean = false;
  backupMessage: string = '';
  backupError: string = '';
  syncPaused: boolean = false;
  lightSuccessAt: number = 0;
  backupSuccessAt: number = 0;
  private coordinator: PhoneSyncCoordinator | undefined = undefined;
  private syncEnvironment: PhoneSyncEnvironment | undefined = undefined;
  private foreground: boolean = true;
  private retirement: Promise<void> = Promise.resolve();
  private syncProjectionDirty: boolean = false;
  private syncRefreshRunning: boolean = false;
  private snapshotGeneration: number = 0;
  private lifecycleGeneration: number = 0;
  private lastProgressAt: number = 0;
  message: string = '正在读取手机录音…';
  error: string = '';
  private useCases: PhoneV3UseCases | undefined = undefined;
  private reviewAudioPlayer: PhoneV3ReviewAudioPlayer | undefined = undefined;
  private reviewPageActive: boolean = false;
  private reviewWindow: Array<PhoneV3VoiceTask> = [];
  private prefetchIdentity: string = '';
  private prefetchGeneration: number = 0;
  private reviewAudioStates: Map<string, string> = new Map<string, string>();
  private audioLoading: boolean = false;
  private annotationAudioPlaying: boolean = false;
  private annotationAudioSource: PhoneV3Utterance | undefined = undefined;
  private auditionReviewId: string = '';
  private auditionReviewEvidence: string = '';
  private audioRequestGeneration: number = 0;
  reviewPlaybackRange: string = '';
  reviewPlaybackPrototype: string = '';
  private playedReviewSampleKeys: Array<string> = [];
  private bridge: PhoneV3DeviceBridgePort | undefined = undefined;
  private localFacts: Array<PhoneV3LocalAudioFact> = [];
  private timerId: number = -1;
  private localRefreshTimer: number = -1;
  private started: boolean = false;
  private refreshing: boolean = false;
  private refreshQueued: boolean = false;
  private lastRetryAction: PhoneV3RetryAction = PhoneV3RetryAction.NONE;
  private lastDesiredRecordingState: string = 'recording';
  private localAudioListener: () => void = (): void => this.onLocalAudioChanged();
  private stateChangeListener: () => void = (): void => {};

  constructor(useCases?: PhoneV3UseCases, reviewAudioPlayer?: PhoneV3ReviewAudioPlayer, bridge?: PhoneV3DeviceBridgePort) {
    this.useCases = useCases; this.reviewAudioPlayer = reviewAudioPlayer;
    this.bridge = bridge;
  }

  setStateChangeListener(listener: () => void): void {
    this.stateChangeListener = listener;
  }

  start(context: common.UIAbilityContext, deviceBridge: PhoneV3DeviceBridgePort): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.bridge = deviceBridge;
    this.bridge.addLocalAudioChangeListener(this.localAudioListener);
    this.timerId = setInterval((): void => this.refreshDeviceState(), 500);
    this.initialize(context);
  }

  stop(): void {
    this.coordinator?.stop();
    this.retirement = this.coordinator?.whenIdle() ?? Promise.resolve();
    this.syncEnvironment?.stop();
    this.lifecycleGeneration += 1;
    this.snapshotGeneration += 1;
    this.useCases?.cancelSynchronize();
    this.started = false;
    this.playedReviewSampleKeys = [];
    this.reviewPlaybackRange = '';
    this.reviewPlaybackPrototype = '';
    this.audioRequestGeneration += 1;
    if (this.localRefreshTimer >= 0) {
      clearTimeout(this.localRefreshTimer);
      this.localRefreshTimer = -1;
    }
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    this.bridge?.removeLocalAudioChangeListener(this.localAudioListener);
    this.bridge?.stopPlayback();
    this.reviewAudioPlayer?.release().then((): void => {}, (): void => {});
    this.stateChangeListener = (): void => {};
  }

  selectedSession(): PhoneV3SessionCard | undefined {
    return selectedPhoneV3Session(this.currentUiState());
  }

  resolveCurrentSession(candidate: PhoneV3SessionCard): PhoneV3SessionCard {
    for (let index = 0; index < this.snapshot.sessions.length; index += 1) {
      const current = this.snapshot.sessions[index];
      if (current.id === candidate.id ||
        (candidate.sessionId.length > 0 && current.sessionId === candidate.sessionId) ||
        (candidate.sessionKey.length > 0 && current.sessionKey === candidate.sessionKey) ||
        (candidate.localGroupKey.length > 0 && current.localGroupKey === candidate.localGroupKey)) {
        return current;
      }
    }
    return candidate;
  }

  selectSession(session: PhoneV3SessionCard): void {
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SESSION_SELECTED,
      undefined, undefined, session.id));
    if (session.localGroupKey.length > 0) {
      this.bridge?.selectSession(session.localGroupKey);
    }
    this.refreshDeviceState();
  }

  refresh(): void {
    if (this.refreshing) {
      this.refreshQueued = true;
      return;
    }
    if (this.useCases === undefined) {
      this.refreshQueued = true;
      return;
    }
    this.refreshing = true;
    this.refreshSnapshot().then((): void => {
      this.finishRefresh();
    }, (error: Object): void => {
      this.fail(error);
      this.finishRefresh();
    });
  }

  synchronize(): void {
    if (this.coordinator !== undefined) { this.coordinator.trigger(true, true); return; }
    const useCases = this.useCases;
    if (useCases === undefined || this.busy || this.computerSyncActive || this.annotationRefreshing) {
      return;
    }
    const generation = this.lifecycleGeneration;
    this.computerSyncError = '';
    this.computerSyncMessage = '正在同步标注与电脑状态…';
    this.computerProgress = new ComputerUploadProgress('', 0, 0, 0, 0);
    this.completedSessionKeys = [];
    this.computerSyncActive = true;
    this.stateChangeListener();
    useCases.synchronize((message: string): void => {
      if (generation !== this.lifecycleGeneration) { return; }
      this.computerSyncMessage = message;
      this.stateChangeListener();
    }).then(async (result): Promise<void> => {
      if (generation !== this.lifecycleGeneration) { return; }
      await this.refreshSnapshot();
      if (generation !== this.lifecycleGeneration) { return; }
      this.computerSyncMessage = `状态同步 ${result.batches} 批；${result.summary()}`;
    }).catch((error: Object): void => {
      if (generation === this.lifecycleGeneration) {
        this.computerSyncError = error instanceof Error ? error.message : '同步失败';
      }
    }).finally((): void => { this.computerSyncActive = false; this.stateChangeListener(); });
  }

  cancelSynchronize(): void {
    this.coordinator?.pause(); this.useCases?.cancelSynchronize(); this.syncPaused = true;
    this.syncEnvironment?.setPaused(true).catch((error: Object): void => { this.computerSyncError = '暂停设置未保存'; });
  }

  resumeSynchronize(): void {
    this.syncPaused = false; this.coordinator?.resume();
    this.syncEnvironment?.setPaused(false).catch((error: Object): void => { this.computerSyncError = '继续设置未保存'; });
  }

  setForeground(value: boolean): void {
    this.foreground = value; this.coordinator?.setForeground(value);
    if (this.reviewPageActive) { this.setReviewAudioWindow(this.reviewWindow); }
    if (!value) { this.stopPlayback(); }
    if (!value) { this.stopPlayback(); }
    else { this.refreshCommittedSync().catch((error: Object): void => this.fail(error)); }
  }

  async startForegroundSync(context: common.UIAbilityContext, preferencesName: string = 'phone_foreground_sync'): Promise<void> {
    const generation = this.lifecycleGeneration;
    this.syncEnvironment?.stop();
    const environment = new PhoneSyncEnvironment(context, preferencesName);
    this.syncEnvironment = environment;
    this.syncPaused = await environment.paused();
    if (generation !== this.lifecycleGeneration) { environment.stop(); return; }
    this.startCoordinator();
    environment.start((): void => this.coordinator?.trigger(true));
  }

  private startCoordinator(): void {
    this.coordinator?.stop();
    const generation = this.lifecycleGeneration;
    const useCases = this.useCases;
    if (useCases === undefined) { return; }
    const port: PhoneSyncCoordinatorPort = {
      light: async (): Promise<PhoneSyncWorkResult> => {
        if (!this.snapshot.paired) { return new PhoneSyncWorkResult(false, 120000, false); }
        const result = await useCases.synchronize((message: string): void => {
          if (generation === this.lifecycleGeneration) { this.computerSyncMessage = message; }
        }, false, 4);
        if (generation !== this.lifecycleGeneration) { return new PhoneSyncWorkResult(false, 0, false); }
        const requiresReload = this.syncProjectionDirty || result.requiresReload;
        this.syncProjectionDirty = this.syncProjectionDirty || result.changed;
        await this.refreshCommittedSync(requiresReload ? [] : result.utteranceIds);
        this.computerSyncMessage = result.summary();
        const processing = this.snapshot.sessions.some((session): boolean =>
          ['queued', 'running', 'pending'].indexOf(session.processingStatus) >= 0);
        return new PhoneSyncWorkResult(result.completion === 'budget_exhausted',
          result.remainingOperations > 0 || processing || this.backupActive || this.reviewPageActive ? 15000 : 120000);
      },
      backup: async (): Promise<PhoneSyncWorkResult> => {
        if (!this.snapshot.paired) { return new PhoneSyncWorkResult(false, 0, false); }
        if (this.syncEnvironment === undefined || !await this.syncEnvironment.wifi()) {
          this.backupMessage = '等待 Wi-Fi 后备份录音'; return new PhoneSyncWorkResult(false, 30000, false);
        }
        this.backupMessage = '正在备份录音…';
        const result = await useCases.backupRecordings();
        if (generation !== this.lifecycleGeneration) { return new PhoneSyncWorkResult(false, 0, false); }
        this.backupMessage = result.more ? '本会话备份完成，仍有录音待备份' : '录音备份完成';
        return new PhoneSyncWorkResult(result.more);
      },
      cancelLight: (): void => useCases.cancelSynchronize(),
      changed: (): void => {
        if (generation !== this.lifecycleGeneration) { return; }
        const coordinator = this.coordinator;
        if (coordinator === undefined) { return; }
        this.computerSyncActive = coordinator.light.running;
        this.backupActive = coordinator.backup.running;
        this.computerSyncError = coordinator.light.error;
        this.backupError = coordinator.backup.error;
        this.syncPaused = coordinator.paused;
        this.lightSuccessAt = coordinator.light.successAt;
        this.backupSuccessAt = coordinator.backup.successAt;
        this.stateChangeListener();
      }
    };
    const coordinator = new PhoneSyncCoordinator(port);
    this.coordinator = coordinator;
    if (this.syncPaused) { coordinator.pause(); }
    coordinator.setForeground(this.foreground);
    coordinator.trigger(true);
  }

  loadSampleStatus(ids: Array<string>, retry: boolean,
    onLoaded: (items: Array<DeviceV3AnnotationStatus>) => void): void {
    this.useCases?.annotations({ action: retry ? 'retry_samples' : 'status', utterance_ids: ids })
      .then((result): void => onLoaded(result.items ?? []))
      .catch((error: Object): void => this.fail(error));
  }

  correctUtterance(utterance: PhoneV3Utterance, text: string,
    speakerTrackId: string | null, identity: string,
    onQueued: () => void = (): void => {}): void {
    const useCases = this.useCases;
    if (useCases === undefined || this.busy) {
      return;
    }
    this.lastRetryAction = PhoneV3RetryAction.COMPUTER_SYNC;
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.BUSY,
      undefined, undefined, '正在保存离线校正…'));
    useCases.queueUtteranceCorrection(utterance, text, speakerTrackId, identity).then((): Promise<void> => {
      this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SUCCESS,
        undefined, undefined, '校正已保存到 outbox，连接电脑后可同步'));
      onQueued();
      this.coordinator?.trigger();
      return this.refreshSnapshot();
    }).catch((error: Object): void => this.fail(error));
  }

  private reviewObjectKey(reviewId: string, prototypeId: string): string {
    return prototypeId ? `prototype:${prototypeId}` : `review:${reviewId}`;
  }

  reviewSubmissionState(reviewId: string, prototypeId: string = ''): string {
    return this.reviewSubmissions.get(this.reviewObjectKey(reviewId, prototypeId))?.state ?? '';
  }

  reviewSubmissionMessage(reviewId: string, prototypeId: string = ''): string {
    const state = this.reviewSubmissionState(reviewId, prototypeId);
    return state === 'sending' ? '此项正在提交，请等待结果' : state === 'committed' ? '此项结果已提交，状态待更新；请核对结果' :
      state === 'unknown' ? '此项结果尚未确认，请先核对结果；不会重复提交' : '';
  }

  resolveReview(reviewId: string, action: string, prototypeId: string = '',
    displayName: string = '', onResolved: () => void = (): void => {}): void {
    const useCases = this.useCases;
    if (useCases === undefined || this.busy) {
      return;
    }
    if (this.reviewSubmissionState(reviewId, prototypeId)) {
      this.fail(new Error(this.reviewSubmissionMessage(reviewId, prototypeId))); return;
    }
    if (prototypeId.length > 0 && (action === 'confirm' || action === 'reject') &&
      !this.reviewSampleWasPlayed(reviewId, prototypeId)) { return; }
    const request: DeviceV3ReviewActionRequest = { review_id: reviewId, action: action };
    const task = phoneV3VoiceTasks(this.snapshot.reviewItems, action === 'retract').find(
      (value): boolean => value.item.reviewId === reviewId && value.candidate.prototypeId === prototypeId);
    if (prototypeId && task !== undefined) {
      const index = new PhoneV3VoiceEvidenceIndex(); index.update(this.snapshot.sessions);
      if (action !== 'retract' && (index.sourceChanged(task.candidate) || phoneV3EvidencePending(index.resolve(task.candidate)))) {
        this.fail(new Error('依据已修改，等待同步/样本更新')); return;
      }
      if (task.candidate.reviewKey) { request.expected_review_key = task.candidate.reviewKey; }
    }
    if (prototypeId.length > 0) {
      request.prototype_id = prototypeId;
    }
    if (displayName.trim().length > 0) {
      request.display_name = displayName.trim();
    }
    if (action === 'ignore' || action === 'reject') {
      request.reason = '手机审核未采纳';
    }
    this.lastRetryAction = PhoneV3RetryAction.NONE;
    const objectKey = this.reviewObjectKey(reviewId, prototypeId);
    this.reviewSubmissions.set(objectKey, new PhoneV3PendingReview(reviewId, prototypeId, action, 'sending'));
    const lifecycle = this.lifecycleGeneration;
    this.stateChangeListener();
    useCases.resolveReview(request).then((reviewItems): void => {
      this.reviewSubmissions.delete(objectKey);
      if (lifecycle !== this.lifecycleGeneration) { return; }
      const current = this.snapshot;
      const snapshot = new PhoneV3Snapshot(
        current.sessions, current.conflicts, current.sync, current.paired,
        current.reminders, reviewItems);
      this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SNAPSHOT_READY,
        snapshot, undefined, '审核结果已保存到电脑'));
      onResolved();
    }).catch((error: Object): void => {
      if (error instanceof PhoneV3ReviewSubmissionError) {
        this.reviewSubmissions.set(objectKey, new PhoneV3PendingReview(reviewId, prototypeId, action, error.committed ? 'committed' : 'unknown'));
      } else { this.reviewSubmissions.delete(objectKey); }
      if (lifecycle === this.lifecycleGeneration) { this.fail(error); }
    });
  }

  refreshVoiceReviews(onLoaded: () => void = (): void => {}): void {
    if (this.useCases === undefined || this.busy) { return; }
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.BUSY, undefined, undefined, '正在核对电脑审核状态…'));
    this.useCases.refreshReviews().then((items): void => {
      const current = this.snapshot;
      this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SNAPSHOT_READY,
        new PhoneV3Snapshot(current.sessions, current.conflicts, current.sync, current.paired, current.reminders, items)));
      const all = phoneV3VoiceTasks(items).concat(phoneV3VoiceTasks(items, true));
      this.reviewSubmissions.forEach((pending: PhoneV3PendingReview, key: string): void => {
        if (pending.state === 'sending') { return; }
        const task = all.find((value): boolean => value.candidate.prototypeId === pending.prototypeId);
        const expected = pending.action === 'confirm' ? 'confirmed' : pending.action === 'reject' ? 'rejected' : pending.action;
        const resolved = pending.prototypeId ? task === undefined || task.candidate.reviewStatus === expected :
          !items.some((item): boolean => item.reviewId === pending.reviewId);
        if (pending.state === 'committed' || resolved) { this.reviewSubmissions.delete(key); }
      });
      onLoaded(); this.stateChangeListener();
    }).catch((error: Object): void => this.fail(error));
  }

  reviewSampleWasPlayed(reviewId: string, prototypeId: string): boolean {
    return this.playedReviewSampleKeys.indexOf(`${reviewId}:${prototypeId}`) >= 0;
  }

  refreshAnnotationData(): void {
    if (this.coordinator !== undefined) { this.coordinator.trigger(false, true); return; }
    const useCases = this.useCases;
    if (useCases === undefined || this.busy || this.computerSyncActive || this.annotationRefreshTask !== undefined) {
      return;
    }
    this.annotationRefreshing = true;
    const task = useCases.refreshRemoteProjection().then(async (): Promise<void> => {
      await this.refreshSnapshot();
    });
    this.annotationRefreshTask = task;
    this.stateChangeListener();
    task.then((): void => {
      this.annotationRefreshTask = undefined;
      this.annotationRefreshing = false;
      this.stateChangeListener();
    }, (error: Object): void => {
      this.annotationRefreshTask = undefined;
      this.annotationRefreshing = false;
      if (!this.busy) {
        this.fail(error);
      }
      this.stateChangeListener();
    });
  }

  loadPeople(onLoaded: (people: Array<DeviceV3PersonChoice>) => void): void {
    const useCases = this.useCases;
    if (useCases === undefined) { return; }
    useCases.localPeople().then((people): void => {
      onLoaded(people);
      // People refresh belongs to explicit sync, never editor open or save completion.
    }).catch((error: Object): void => this.fail(error));
  }

  assignUtterances(utterances: Array<PhoneV3Utterance>, personId: string, name: string,
    onSaved: () => void): void {
    this.saveAnnotation(utterances, personId, name, true, '', (_refreshed: boolean): void => onSaved());
  }

  classifyUtterances(utterances: Array<PhoneV3Utterance>, soundKind: string, onSaved: () => void): void {
    this.saveAnnotation(utterances, '', '', false, soundKind, (_refreshed: boolean): void => onSaved());
  }

  saveAnnotation(utterances: Array<PhoneV3Utterance>, personId: string, name: string,
    personChanged: boolean, soundKind: string, onSaved: (refreshed: boolean) => void): void {
    const useCases = this.useCases;
    if (useCases === undefined || this.annotationSaving || utterances.length === 0) { return; }
    const targets = utterances.slice();
    const lifecycle = this.lifecycleGeneration;
    this.snapshotGeneration += 1;
    this.annotationSaving = true;
    this.stateChangeListener();
    useCases.queueAnnotation(targets, personId, name, personChanged, soundKind).then((operations): void => {
      this.snapshotGeneration += 1;
      try {
        const current = this.snapshot;
        const sessions = current.sessions.slice();
        applyAnnotationRows(indexedUtterances(current.sessions), operations);
        retainAnnotationIndex(current.sessions, sessions);
        const status = current.sync;
        this.snapshot = new PhoneV3Snapshot(sessions, current.conflicts,
          new PhoneV3SyncStatus(status.cursor, status.lastServerTime, status.lastError,
            status.pendingOperations + operations.length, status.retryCount),
          current.paired, current.reminders, current.reviewItems);
        if (lifecycle !== this.lifecycleGeneration) { return; }
        this.clearError('已在手机保存，待同步到电脑');
        onSaved(true);
        this.coordinator?.trigger();
      } catch (error) {
        this.fail(new Error('已在手机保存，但读取结果失败；请重试读取，不必重复标注'));
        if (lifecycle === this.lifecycleGeneration) { onSaved(false); }
      }
    }).catch((error: Object): void => this.fail(new Error(`数据库保存失败：${error instanceof Error ? error.message : JSON.stringify(error)}`)))
      .finally((): void => {
        this.annotationSaving = false;
        this.stateChangeListener();
        if (lifecycle === this.lifecycleGeneration) {
          this.refreshCommittedSync().catch((error: Object): void => this.fail(error));
        }
      });
  }

  reloadAnnotationResult(onLoaded: () => void): void {
    this.refreshSnapshot().then(onLoaded).catch((error: Object): void => this.fail(error));
  }

  loadAnnotationConflict(payload: PhoneV3LocalAnnotation, onLoaded: (rows: Array<PhoneV3Utterance>) => void): void {
    this.useCases?.annotationConflictRows(payload).then(onLoaded).catch((error: Object): void => this.fail(error));
  }

  resolveAnnotationConflict(operationId: string, keepLocal: boolean, reviewed: Array<PhoneV3Utterance>): void {
    const useCases = this.useCases;
    if (useCases === undefined || this.annotationSaving) { return; }
    this.annotationSaving = true;
    this.stateChangeListener();
    useCases.resolveAnnotationConflict(operationId, keepLocal, reviewed).then(async (): Promise<void> => {
      await this.refreshSnapshot();
      if (!this.busy) { this.clearError(keepLocal ? '已保留本地选择，等待再次同步' : '已保留电脑结果'); }
    }).catch((error: Object): void => this.fail(error)).finally((): void => {
      this.annotationSaving = false;
      this.stateChangeListener();
    });
  }

  annotationPlaybackState(): string {
    return this.audioLoading ? '正在加载' : this.annotationAudioPlaying || this.device.isPlaying ? '正在播放' :
      this.device.playbackBusy ? '正在加载' : '';
  }

  playUtterance(utterance: PhoneV3Utterance, withContext: boolean = false): void {
    const session = this.snapshot.sessions.find((value: PhoneV3SessionCard): boolean =>
      value.sessionId === utterance.sessionId);
    if (session === undefined || this.busy || this.device.playbackBusy) {
      return;
    }
    this.playedReviewSampleKeys = [];
    this.auditionReviewId = '';
    this.annotationAudioSource = utterance;
    this.reviewPlaybackRange = '';
    this.reviewPlaybackPrototype = '';
    const generation = ++this.audioRequestGeneration;
    const startMs = withContext ? Math.max(0, utterance.startMs - 3000) : utterance.startMs;
    const endMs = withContext ? Math.min(session.durationMs > 0 ? session.durationMs : utterance.endMs,
      utterance.endMs + 3000) : utterance.endMs;
    this.reviewAudioPlayer?.release().then((): void => {}, (): void => {});
    if (session.localPaths.length > 0 && session.localGroupKey.length > 0) {
      this.bridge?.playRange(session.localGroupKey, startMs, endMs);
      this.refreshDeviceState();
      return;
    }
    const useCases = this.useCases;
    const player = this.reviewAudioPlayer;
    if (useCases === undefined || player === undefined) {
      return;
    }
    this.bridge?.stopPlayback();
    this.audioLoading = true;
    this.stateChangeListener();
    useCases.annotations({ action: 'audio', session_id: utterance.sessionId,
      start_ms: startMs, end_ms: endMs }).then(async (response): Promise<void> => {
      if (generation !== this.audioRequestGeneration) {
        return;
      }
      if (response.audio === undefined) {
        throw new Error('电脑未返回片段音频');
      }
      await player.play(response.audio, (): void => {
        if (generation !== this.audioRequestGeneration) { return; }
        this.audioLoading = false;
        this.annotationAudioPlaying = true;
        this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SUCCESS, undefined, undefined, '正在播放所选片段'));
      }, (): void => {
        if (generation !== this.audioRequestGeneration) { return; }
        this.annotationAudioPlaying = false;
        this.stateChangeListener();
      }, (message: string): void => {
        if (generation !== this.audioRequestGeneration) { return; }
        this.annotationAudioPlaying = false;
        this.audioLoading = false;
        this.fail(new Error(message));
      });
    }).catch((error: Object): void => {
      if (generation === this.audioRequestGeneration) { this.audioLoading = false; this.fail(error); }
    });
  }

  setReviewAudioWindow(tasks: Array<PhoneV3VoiceTask>, active: boolean = true): void {
    this.reviewWindow = tasks;
    const becameActive = active && !this.reviewPageActive;
    this.reviewPageActive = active;
    if (becameActive) { this.coordinator?.trigger(false); }
    const selected = active && this.foreground ? tasks.slice(0, 3) : [];
    const identity = selected.map((task: PhoneV3VoiceTask): string => `${task.key}:${task.fingerprint}`).join('|');
    if (identity === this.prefetchIdentity) { return; }
    this.prefetchIdentity = identity;
    const generation = ++this.prefetchGeneration;
    const useCases = this.useCases;
    useCases?.cancelReviewPrefetch();
    this.reviewAudioStates.clear();
    let next: Promise<void> = Promise.resolve();
    for (const task of selected) {
      if (!task.candidate.hasAudio || !task.candidate.audioContentKey) { continue; }
      next = next.then(async (): Promise<void> => {
        if (generation !== this.prefetchGeneration || useCases === undefined) { return; }
        this.reviewAudioStates.set(task.key, '正在准备试听');
        this.stateChangeListener();
        try {
          await useCases.loadReviewAudio(task.item.reviewId, task.candidate.prototypeId, true);
          if (generation === this.prefetchGeneration) { this.reviewAudioStates.set(task.key, '已缓存，可离线试听'); }
        } catch (_error) {
          if (generation === this.prefetchGeneration) { this.reviewAudioStates.set(task.key, '点击准备试听'); }
        }
        if (generation === this.prefetchGeneration) { this.stateChangeListener(); }
      });
    }
  }

  reviewAudioState(key: string): string { return this.reviewAudioStates.get(key) ?? '点击准备试听'; }

  playReviewSample(reviewId: string, prototypeId: string,
    onCompleted: () => void = (): void => {}): void {
    const useCases = this.useCases;
    const player = this.reviewAudioPlayer;
    if (useCases === undefined || player === undefined || this.busy) {
      return;
    }
    this.playedReviewSampleKeys = [];
    this.annotationAudioSource = undefined;
    this.auditionReviewId = reviewId;
    this.auditionReviewEvidence = JSON.stringify(this.snapshot.reviewItems.find((item): boolean => item.reviewId === reviewId));
    this.reviewPlaybackRange = '';
    this.reviewPlaybackPrototype = '';
    const generation = ++this.audioRequestGeneration;
    player.release().then((): void => {}, (): void => {});
    this.bridge?.stopPlayback();
    this.audioLoading = true;
    this.lastRetryAction = PhoneV3RetryAction.NONE;
    this.stateChangeListener();
    useCases.loadReviewAudio(reviewId, prototypeId).then(async (response): Promise<void> => {
      if (generation !== this.audioRequestGeneration) {
        useCases.releaseReviewAudio?.(response);
        return;
      }
      const item = this.snapshot.reviewItems.find((value): boolean => value.reviewId === reviewId);
      const candidate = item === undefined ? undefined : phoneV3VoiceCandidates(item).find(
        (value): boolean => value.prototypeId === prototypeId);
      try {
        if (candidate === undefined) { throw new Error('当前样本已变化，请刷新后重新完整试听'); }
        validateReviewSample(response, reviewId, candidate);
      } catch (error) { useCases.releaseReviewAudio?.(response); throw error as Error; }
      await player.play(response, (): void => {
        if (generation !== this.audioRequestGeneration) { return; }
        this.audioLoading = false;
        this.reviewPlaybackPrototype = prototypeId;
        this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SUCCESS,
          undefined, undefined, '正在完整串播，播放结束后才能确认'));
      }, (): void => {
        if (generation !== this.audioRequestGeneration) { return; }
        this.playedReviewSampleKeys = [`${reviewId}:${prototypeId}`];
        this.reviewPlaybackRange = '';
        this.reviewPlaybackPrototype = '';
        onCompleted();
        this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SUCCESS,
          undefined, undefined, '所有窗口已播放完成，可以确认或拒绝'));
      }, (message: string): void => {
        if (generation === this.audioRequestGeneration) {
          this.playedReviewSampleKeys = []; this.reviewPlaybackRange = ''; this.reviewPlaybackPrototype = ''; this.fail(new Error(message));
        }
      }, (position: number): void => {
        if (generation !== this.audioRequestGeneration || response.windows === undefined) { return; }
        const window = response.windows.find((value): boolean => position >= value.playback_start_ms &&
          position < value.playback_start_ms + value.end_ms - value.start_ms);
        if (window !== undefined) {
          const label = `正在播放第 ${response.windows.indexOf(window) + 1} / ${response.windows.length} 段窗口`;
          if (label !== this.reviewPlaybackRange) { this.reviewPlaybackRange = label; this.stateChangeListener(); }
        }
      });
    }).catch((error: Object): void => {
      if (generation === this.audioRequestGeneration) { this.audioLoading = false; this.fail(error); }
    });
  }

  rebuild(): void {
    const useCases = this.useCases;
    if (useCases === undefined || this.busy || this.computerSyncActive || this.annotationSaving) {
      return;
    }
    if (this.coordinator !== undefined && !this.syncPaused) {
      this.computerSyncError = '请先暂停自动同步，再重新获取电脑数据';
      this.stateChangeListener();
      return;
    }
    this.lastRetryAction = PhoneV3RetryAction.REBUILD;
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.BUSY,
      undefined, undefined, '正在保留离线状态并重建电脑投影…'));
    const idle = this.coordinator?.whenIdle() ?? Promise.resolve();
    idle.then(() => useCases.rebuild()).then((result): Promise<void> => {
      this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SUCCESS, undefined, undefined,
        `投影重建完成：${result.batches} 批，游标 ${result.finalCursor}`));
      return this.refreshSnapshot();
    }).catch((error: Object): void => this.fail(error));
  }

  requestWatchSync(): void {
    this.lastRetryAction = PhoneV3RetryAction.WATCH_SYNC;
    this.clearError('正在请求 Watch 同步…');
    this.bridge?.requestWatchSync();
    this.refreshDeviceState();
  }

  requestWatchRecordingState(desiredState: string): void {
    this.lastDesiredRecordingState = desiredState;
    this.lastRetryAction = PhoneV3RetryAction.WATCH_CONTROL;
    this.clearError(desiredState === 'recording' ? '正在请求手表开始录音…' : '正在请求手表停止并保存…');
    this.bridge?.requestWatchRecordingState(desiredState);
    this.refreshDeviceState();
  }

  toggleWifiReceiver(): void {
    this.lastRetryAction = PhoneV3RetryAction.WIFI_TRANSFER;
    this.clearError(this.device.wifi.ready ? '正在停止 Wi-Fi 快传…' : '正在准备 Wi-Fi 快传…');
    this.bridge?.toggleWifiReceiver();
    this.refreshDeviceState();
  }

  reconnectReceiver(): void {
    this.lastRetryAction = PhoneV3RetryAction.RECONNECT;
    this.clearError('正在重新连接手表…');
    this.bridge?.reconnectReceiver();
    this.refreshDeviceState();
  }

  togglePlayback(): void {
    this.annotationAudioSource = undefined;
    this.auditionReviewId = '';
    this.playedReviewSampleKeys = [];
    this.reviewPlaybackRange = '';
    this.reviewPlaybackPrototype = '';
    this.audioRequestGeneration += 1;
    this.reviewAudioPlayer?.release().then((): void => {}, (): void => {});
    this.lastRetryAction = PhoneV3RetryAction.PLAYBACK;
    this.clearError('正在更新播放状态…');
    this.bridge?.togglePlayback();
    this.refreshDeviceState();
  }

  seekPlayback(positionMs: number): void {
    this.bridge?.seekPlayback(positionMs);
    this.refreshDeviceState();
  }

  playbackGeneration(): number { return this.audioRequestGeneration; }

  stopPlayback(expectedGeneration?: number): void {
    if (expectedGeneration !== undefined && expectedGeneration !== this.audioRequestGeneration) { return; }
    this.annotationAudioSource = undefined;
    this.auditionReviewId = '';
    this.auditionReviewEvidence = '';
    this.annotationAudioPlaying = false;
    this.playedReviewSampleKeys = [];
    this.reviewPlaybackRange = '';
    this.reviewPlaybackPrototype = '';
    this.audioRequestGeneration += 1;
    if (this.audioLoading) {
      this.audioLoading = false;
      this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SUCCESS, undefined, undefined, '已取消试听'));
    }
    this.reviewAudioPlayer?.release().then((): void => {}, (): void => {});
    this.bridge?.stopPlayback();
    this.refreshDeviceState();
    this.stateChangeListener();
  }

  canDeleteLocalAudio(session: PhoneV3SessionCard): boolean {
    return session.localPaths.length > 0 && session.sessionId.length === 0 && session.uploadStatus !== 'uploaded';
  }

  localDeleteProtection(session: PhoneV3SessionCard): string {
    if (session.localPaths.length === 0) {
      return '手机上没有可删除的本地音频';
    }
    if (session.sessionId.length > 0 || session.uploadStatus === 'uploaded') {
      return '该录音已经同步到电脑，为避免误删已受保护';
    }
    return '仅删除手机上的本地音频，删除后无法恢复';
  }

  deleteLocalAudio(session: PhoneV3SessionCard, onDeleted: () => void = (): void => {}): void {
    const bridge = this.bridge;
    const useCases = this.useCases;
    if (bridge === undefined || useCases === undefined || this.busy) {
      return;
    }
    if (!this.canDeleteLocalAudio(session)) {
      this.lastRetryAction = PhoneV3RetryAction.NONE;
      this.fail(new Error(this.localDeleteProtection(session)));
      return;
    }
    this.lastRetryAction = PhoneV3RetryAction.NONE;
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.BUSY,
      undefined, undefined, '正在确认录音尚未同步到电脑…'));
    useCases.localAudioIsProtected(session.sessionKey).then(async (protectedAudio: boolean): Promise<void> => {
      if (protectedAudio) {
        throw new Error('该录音已经同步到电脑，禁止删除手机本地音频');
      }
      await this.reviewAudioPlayer?.release();
      await useCases.clearReviewAudio();
      return bridge.deleteLocalSession(session.localGroupKey);
    }).then((): void => {
      this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SUCCESS,
        undefined, undefined, '手机本地音频已删除'));
      this.refresh();
      onDeleted();
    }, (error: Object): void => this.fail(error));
  }

  canRetry(): boolean {
    return this.lastRetryAction !== PhoneV3RetryAction.NONE;
  }

  reportUiError(message: string): void {
    this.lastRetryAction = PhoneV3RetryAction.NONE;
    this.fail(new Error(message));
  }

  retryLastAction(): void {
    switch (this.lastRetryAction) {
      case PhoneV3RetryAction.WATCH_SYNC:
        this.requestWatchSync();
        return;
      case PhoneV3RetryAction.WATCH_CONTROL:
        this.requestWatchRecordingState(this.lastDesiredRecordingState);
        return;
      case PhoneV3RetryAction.WIFI_TRANSFER:
        this.clearError('正在重新准备 Wi-Fi 快传…');
        this.bridge?.retryWifiReceiver();
        this.refreshDeviceState();
        return;
      case PhoneV3RetryAction.RECONNECT:
        this.reconnectReceiver();
        return;
      case PhoneV3RetryAction.COMPUTER_SYNC:
        this.synchronize();
        return;
      case PhoneV3RetryAction.REBUILD:
        this.rebuild();
        return;
      case PhoneV3RetryAction.PLAYBACK:
        this.togglePlayback();
        return;
      default:
        return;
    }
  }

  private async initialize(context: common.UIAbilityContext): Promise<void> {
    const lifecycle = this.lifecycleGeneration;
    try {
      await this.retirement;
      if (lifecycle !== this.lifecycleGeneration) { return; }
      const audioCache = new PhoneV3ReviewAudioCache(context);
      this.reviewAudioPlayer = new PhoneV3ReviewAudioPlayer(context, audioCache);
      const local = new PhoneV3LocalAudioRepository(context.filesDir);
      this.localFacts = await local.list();
      this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.LOCAL_READY,
        new PhoneV3Snapshot(mergePhoneV3Sessions(this.localFacts, [], [], [], [])),
        undefined, `手机本地已有 ${this.localFacts.length} 条录音`));
      const repository = await PhoneProjectionRepository.open(context);
      this.useCases = new PhoneV3UseCases(repository, local, new PhoneV3DeviceRemote(context),
        new PhoneV3ReminderScheduler(context), new PhoneV3ComputerBackup(context, repository, (progress: ComputerUploadProgress): void => {
          if (lifecycle !== this.lifecycleGeneration) { return; }
          const now = Date.now();
          if (!progress.sessionCompleted && now - this.lastProgressAt < 150) { return; }
          this.lastProgressAt = now;
          this.computerProgress = progress;
          if (progress.sessionCompleted) {
            this.completedSessionKeys = this.completedSessionKeys.concat([progress.sessionKey]);
          }
          this.backupMessage = `${progress.message} · 文件 ${progress.completedFiles}/${progress.totalFiles} · ${progress.percent()}%`;
          this.stateChangeListener();
        }), audioCache);
      await this.refreshSnapshot();
      if (lifecycle !== this.lifecycleGeneration) { return; }
      await this.startForegroundSync(context);
      if (this.refreshQueued) {
        this.refreshQueued = false;
        this.refresh();
      }
    } catch (error) {
      this.fail(error as Object);
    }
  }

  // A committed projection is local work, even when the next network request fails.
  // Keep one reader and retain invalidated work until the conflicting save finishes.
  private async refreshCommittedSync(ids: Array<string> = []): Promise<void> {
    const useCases = this.useCases;
    if (useCases === undefined || this.syncRefreshRunning) { return; }
    const lifecycle = this.lifecycleGeneration;
    this.syncRefreshRunning = true;
    try {
      while (this.syncProjectionDirty && !this.annotationSaving && this.foreground && lifecycle === this.lifecycleGeneration) {
        this.syncProjectionDirty = false;
        const revision = this.snapshotGeneration;
        if (ids.length > 0) {
          this.snapshotGeneration += 1;
          const fresh = await useCases.refreshUtterances(this.snapshot, ids);
          if (this.snapshotGeneration === revision + 1 && !this.annotationSaving && lifecycle === this.lifecycleGeneration && this.foreground) {
            this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SNAPSHOT_READY, fresh));
          }
        } else { await this.refreshSnapshot(false); }
        this.syncProjectionDirty = this.syncProjectionDirty || this.snapshotGeneration !== revision + 1 || this.annotationSaving || !this.foreground;
        ids = [];
      }
    } catch (error) {
      this.syncProjectionDirty = true;
      throw error as Error;
    } finally { this.syncRefreshRunning = false; }
  }

  private async refreshSnapshot(scanLocal: boolean = true): Promise<void> {
    const generation = ++this.snapshotGeneration;
    const useCases = this.useCases;
    if (useCases === undefined) {
      return;
    }
    if (scanLocal) { this.localFacts = await useCases.loadLocal(); }
    const snapshot = await useCases.loadCached(this.localFacts);
    if (generation !== this.snapshotGeneration || this.annotationSaving) { return; }
    indexedUtterances(snapshot.sessions);
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SNAPSHOT_READY, snapshot,
      undefined, `已合并 ${snapshot.sessions.length} 条会话；最后游标 ${snapshot.sync.cursor}`));
  }

  private validateAuditionSource(snapshot: PhoneV3Snapshot): void {
    const source = this.annotationAudioSource;
    if (source !== undefined) {
      const session = snapshot.sessions.find((item): boolean => item.sessionId === source.sessionId);
      const fresh = session?.utterances.find((row): boolean => row.utteranceId === source.utteranceId);
      const oldSession = this.snapshot.sessions.find((item): boolean => item.sessionId === source.sessionId);
      if (fresh === undefined || fresh.status !== 'active' || fresh.revision !== source.revision ||
        fresh.startMs !== source.startMs || fresh.endMs !== source.endMs ||
        JSON.stringify(session?.localPaths) !== JSON.stringify(oldSession?.localPaths)) {
        this.stopPlayback();
      }
    }
    if (this.auditionReviewId) {
      const task = phoneV3VoiceTasks(snapshot.reviewItems).find((item): boolean =>
        item.item.reviewId === this.auditionReviewId && (item.candidate.prototypeId === this.reviewPlaybackPrototype ||
          this.playedReviewSampleKeys.includes(item.key)));
      if (task !== undefined) {
        const index = new PhoneV3VoiceEvidenceIndex(); index.update(snapshot.sessions);
        if (index.sourceChanged(task.candidate) || phoneV3EvidencePending(index.resolve(task.candidate))) {
          this.stopPlayback();
        }
      }
    }
    // The review includes sample windows, audition key, revision and grant context.
    // Keep a completed credential only while that exact review evidence remains current.
    if (this.auditionReviewId && this.auditionReviewEvidence !== JSON.stringify(
      snapshot.reviewItems.find((item): boolean => item.reviewId === this.auditionReviewId))) {
      this.stopPlayback();
    }
  }

  private refreshDeviceState(): void {
    const bridge = this.bridge;
    if (bridge === undefined) {
      return;
    }
    const device = bridge.state();
    if (JSON.stringify(device) === JSON.stringify(this.device)) {
      return;
    }
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.DEVICE_CHANGED,
      undefined, device));
  }

  private onLocalAudioChanged(): void {
    this.coordinator?.trigger(true);
    if (this.localRefreshTimer >= 0) {
      return;
    }
    this.localRefreshTimer = setTimeout((): void => {
      this.localRefreshTimer = -1;
      this.refresh();
    }, 1500);
  }

  private finishRefresh(): void {
    this.refreshing = false;
    if (this.refreshQueued) {
      this.refreshQueued = false;
      this.refresh();
    }
  }

  private clearError(message: string): void {
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SUCCESS, undefined, undefined, message));
  }

  private dispatch(action: PhoneV3UiAction): void {
    if (action.type === PhoneV3UiActionType.SNAPSHOT_READY && action.snapshot !== undefined) {
      this.validateAuditionSource(action.snapshot);
    }
    const next = reducePhoneV3Ui(this.currentUiState(), action);
    // Keep the values that drive ArkUI directly on this @Observed object. A nested
    // `state.snapshot` replacement was not invalidating an already-rendered tab,
    // which left Home on its local-only bootstrap data after cache loading finished.
    if (this.snapshot !== next.snapshot) {
      this.snapshot = next.snapshot;
    }
    if (this.device !== next.device) {
      this.device = next.device;
    }
    this.selectedSessionId = next.selectedSessionId;
    this.localReady = next.localReady;
    this.cacheReady = next.cacheReady;
    this.busy = next.busy;
    this.message = next.message;
    this.error = next.error;
    AppStorage.setOrCreate<PhoneV3UiState>(PHONE_V3_UI_STATE_STORAGE_KEY, next);
    this.stateChangeListener();
  }

  private currentUiState(): PhoneV3UiState {
    return new PhoneV3UiState(this.snapshot, this.device, this.selectedSessionId,
      this.localReady, this.cacheReady, this.busy, this.message, this.error);
  }

  private fail(error: Object): void {
    const message = error instanceof Error ? error.message : JSON.stringify(error);
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.FAILURE, undefined, undefined, message));
  }
}
