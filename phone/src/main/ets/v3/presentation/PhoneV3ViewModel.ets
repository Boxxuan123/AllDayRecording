import { phoneV3VoiceCandidates } from '../domain/PhoneV3ReviewModels';
import { PhoneV3LocalAnnotation } from '../domain/PhoneV3LocalAnnotation';
import { ComputerUploadProgress } from '../../computer/ComputerRecordingUploadService';
import { common } from '@kit.AbilityKit';
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

@Observed
export class PhoneV3ViewModel {
  reviewSubmissionKey: string = '';
  reviewSubmissionAction: string = '';
  reviewSubmissionState: string = '';
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
  message: string = '正在读取手机录音…';
  error: string = '';
  private useCases: PhoneV3UseCases | undefined = undefined;
  private reviewAudioPlayer: PhoneV3ReviewAudioPlayer | undefined = undefined;
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

  constructor(useCases?: PhoneV3UseCases, reviewAudioPlayer?: PhoneV3ReviewAudioPlayer) {
    this.useCases = useCases; this.reviewAudioPlayer = reviewAudioPlayer;
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
    const useCases = this.useCases;
    if (useCases === undefined || this.busy) {
      return;
    }
    this.lastRetryAction = PhoneV3RetryAction.COMPUTER_SYNC;
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.BUSY,
      undefined, undefined, '正在发现电脑并同步增量状态…'));
    this.computerProgress = new ComputerUploadProgress('', 0, 0, 0, 0);
    this.completedSessionKeys = [];
    this.computerSyncActive = true;
    useCases.synchronize((message: string): void => {
      this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.BUSY, undefined, undefined, message));
    }).then(async (result): Promise<void> => {
      await this.refreshSnapshot();
      this.computerSyncActive = false;
      this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SUCCESS, undefined, undefined,
        `备份完成：新增 ${result.backup.uploadedFiles} 个文件，电脑已有 ${result.backup.skippedFiles} 个；` +
        `状态同步 ${result.batches} 批；${result.summary()}`));
    }).catch((error: Object): void => this.fail(error));
  }

  cancelSynchronize(): void { this.useCases?.cancelSynchronize(); }

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
      return this.refreshSnapshot();
    }).catch((error: Object): void => this.fail(error));
  }

  resolveReview(reviewId: string, action: string, prototypeId: string = '',
    displayName: string = '', onResolved: () => void = (): void => {}): void {
    const useCases = this.useCases;
    if (useCases === undefined || this.busy || this.reviewSubmissionState.length > 0) {
      return;
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
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.BUSY,
      undefined, undefined, '正在提交审核判断…'));
    this.reviewSubmissionKey = `${reviewId}:${prototypeId}`;
    this.reviewSubmissionAction = action;
    useCases.resolveReview(request).then((reviewItems): void => {
      const current = this.snapshot;
      const snapshot = new PhoneV3Snapshot(
        current.sessions, current.conflicts, current.sync, current.paired,
        current.reminders, reviewItems);
      this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SNAPSHOT_READY,
        snapshot, undefined, '审核结果已保存到电脑'));
      onResolved();
    }).catch((error: Object): void => {
      if (error instanceof PhoneV3ReviewSubmissionError) {
        this.reviewSubmissionState = error.committed ? 'committed' : 'unknown';
      }
      this.fail(error);
    });
  }

  refreshVoiceReviews(onLoaded: () => void = (): void => {}): void {
    if (this.useCases === undefined || this.busy) { return; }
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.BUSY, undefined, undefined, '正在核对电脑审核状态…'));
    this.useCases.refreshReviews().then((items): void => {
      const current = this.snapshot;
      this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SNAPSHOT_READY,
        new PhoneV3Snapshot(current.sessions, current.conflicts, current.sync, current.paired, current.reminders, items)));
      if (this.reviewSubmissionState === 'committed') { this.reviewSubmissionState = ''; }
      else if (this.reviewSubmissionState === 'unknown') {
        const all = phoneV3VoiceTasks(items).concat(phoneV3VoiceTasks(items, true));
        const task = all.find((value): boolean => value.key === this.reviewSubmissionKey);
        const expected = this.reviewSubmissionAction === 'confirm' ? 'confirmed' :
          this.reviewSubmissionAction === 'reject' ? 'rejected' : this.reviewSubmissionAction;
        if (task === undefined || task.candidate.reviewStatus === expected) { this.reviewSubmissionState = ''; }
        else { this.error = '结果尚未确认，请稍后再次核对；不会重复提交'; }
      }
      onLoaded(); this.stateChangeListener();
    }).catch((error: Object): void => this.fail(error));
  }

  reviewSampleWasPlayed(reviewId: string, prototypeId: string): boolean {
    return this.playedReviewSampleKeys.indexOf(`${reviewId}:${prototypeId}`) >= 0;
  }

  refreshAnnotationData(): void {
    const useCases = this.useCases;
    if (useCases === undefined || this.busy || this.annotationRefreshTask !== undefined) {
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
      // Opening the editor never waits for the computer or starts a full sync.
      useCases.annotations({ action: 'people' }).then(async (): Promise<void> => {
        onLoaded(await useCases.localPeople());
      }).catch((): void => {});
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
    this.annotationSaving = true;
    this.stateChangeListener();
    useCases.queueAnnotation(targets, personId, name, personChanged, soundKind).then(async (): Promise<void> => {
      try {
        await this.refreshSnapshot();
        this.clearError('已在手机保存，待同步到电脑');
        onSaved(true);
      } catch (error) {
        this.fail(new Error('已在手机保存，但读取结果失败；请重试读取，不必重复标注'));
        onSaved(false);
      }
    }).catch((error: Object): void => this.fail(new Error(`数据库保存失败：${error instanceof Error ? error.message : JSON.stringify(error)}`)))
      .finally((): void => {
        this.annotationSaving = false;
        this.stateChangeListener();
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
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.BUSY, undefined, undefined, '正在从电脑读取对应时间的录音…'));
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
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.BUSY,
      undefined, undefined, '正在从电脑读取声音样本…'));
    useCases.loadReviewAudio(reviewId, prototypeId).then(async (response): Promise<void> => {
      if (generation !== this.audioRequestGeneration) {
        return;
      }
      const item = this.snapshot.reviewItems.find((value): boolean => value.reviewId === reviewId);
      const candidate = item === undefined ? undefined : phoneV3VoiceCandidates(item).find(
        (value): boolean => value.prototypeId === prototypeId);
      if (response.complete_sample !== true || response.review_id !== reviewId || response.prototype_id !== prototypeId ||
        candidate === undefined || candidate.auditionKey.length === 0 || response.audition_key !== candidate.auditionKey ||
        response.end_ms - response.start_ms !== candidate.totalMs || response.windows === undefined ||
        response.windows.length !== candidate.windowCount || response.windows.some((window, index: number): boolean => {
          const clip = candidate.clips[index];
          return clip === undefined || window.media_id !== clip.media_id || window.start_ms !== clip.start_ms || window.end_ms !== clip.end_ms ||
            window.playback_start_ms !== candidate.clips.slice(0, index).reduce((total: number, previous): number => total + (previous.end_ms ?? 0) - (previous.start_ms ?? 0), 0);
        })) {
        throw new Error('样本已变化或电脑未提供完整试听，请刷新后重试');
      }
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
    if (useCases === undefined || this.busy) {
      return;
    }
    this.lastRetryAction = PhoneV3RetryAction.REBUILD;
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.BUSY,
      undefined, undefined, '正在保留离线状态并重建电脑投影…'));
    useCases.rebuild().then((result): Promise<void> => {
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

  stopPlayback(): void {
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
    useCases.localAudioIsProtected(session.sessionKey).then((protectedAudio: boolean): Promise<void> => {
      if (protectedAudio) {
        throw new Error('该录音已经同步到电脑，禁止删除手机本地音频');
      }
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
    try {
      this.reviewAudioPlayer = new PhoneV3ReviewAudioPlayer(context);
      const local = new PhoneV3LocalAudioRepository(context.filesDir);
      this.localFacts = await local.list();
      this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.LOCAL_READY,
        new PhoneV3Snapshot(mergePhoneV3Sessions(this.localFacts, [], [], [], [])),
        undefined, `手机本地已有 ${this.localFacts.length} 条录音`));
      const repository = await PhoneProjectionRepository.open(context);
      this.useCases = new PhoneV3UseCases(repository, local, new PhoneV3DeviceRemote(context),
        new PhoneV3ReminderScheduler(context), new PhoneV3ComputerBackup(context, repository, (progress: ComputerUploadProgress): void => {
          this.computerProgress = progress;
          if (progress.sessionCompleted) {
            this.completedSessionKeys = this.completedSessionKeys.concat([progress.sessionKey]);
          }
          this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.BUSY, undefined, undefined,
            `${progress.message} · 文件 ${progress.completedFiles}/${progress.totalFiles} · ${progress.percent()}%`));
        }));
      await this.refreshSnapshot();
      if (this.refreshQueued) {
        this.refreshQueued = false;
        this.refresh();
      }
    } catch (error) {
      this.fail(error as Object);
    }
  }

  private async refreshSnapshot(): Promise<void> {
    const useCases = this.useCases;
    if (useCases === undefined) {
      return;
    }
    this.localFacts = await useCases.loadLocal();
    const snapshot = await useCases.loadCached(this.localFacts);
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
    if ((this.computerSyncActive || (this.annotationRefreshing && this.busy)) &&
      action.type === PhoneV3UiActionType.SNAPSHOT_READY) {
      next.busy = true;
      next.message = this.message;
      next.error = this.error;
    }
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
    this.computerSyncActive = false;
    const message = error instanceof Error ? error.message : JSON.stringify(error);
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.FAILURE, undefined, undefined, message));
  }
}
