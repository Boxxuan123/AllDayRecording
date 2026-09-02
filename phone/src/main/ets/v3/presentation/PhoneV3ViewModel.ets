import { common } from '@kit.AbilityKit';
import { DeviceV3ReviewActionRequest } from '../../computer/ComputerTransferProtocol';
import { PhoneV3UseCases, mergePhoneV3Sessions } from '../application/PhoneV3UseCases';
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
  snapshot: PhoneV3Snapshot = new PhoneV3Snapshot();
  device: PhoneV3DeviceState = new PhoneV3DeviceState();
  selectedSessionId: string = '';
  localReady: boolean = false;
  cacheReady: boolean = false;
  busy: boolean = false;
  message: string = '正在读取手机录音…';
  error: string = '';
  private useCases: PhoneV3UseCases | undefined = undefined;
  private reviewAudioPlayer: PhoneV3ReviewAudioPlayer | undefined = undefined;
  private playedReviewSampleKeys: Array<string> = [];
  private bridge: PhoneV3DeviceBridgePort | undefined = undefined;
  private localFacts: Array<PhoneV3LocalAudioFact> = [];
  private timerId: number = -1;
  private started: boolean = false;
  private refreshing: boolean = false;
  private refreshQueued: boolean = false;
  private lastRetryAction: PhoneV3RetryAction = PhoneV3RetryAction.NONE;
  private lastDesiredRecordingState: string = 'recording';
  private localAudioListener: () => void = (): void => this.onLocalAudioChanged();
  private stateChangeListener: () => void = (): void => {};

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
    useCases.synchronize().then((result): Promise<void> => {
      this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SUCCESS, undefined, undefined,
        `备份完成：新增 ${result.backup.uploadedFiles} 个文件，电脑已有 ${result.backup.skippedFiles} 个；` +
        `状态同步 ${result.batches} 批，游标 ${result.finalCursor}`));
      return this.refreshSnapshot();
    }).catch((error: Object): void => this.fail(error));
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
    if (useCases === undefined || this.busy) {
      return;
    }
    const request: DeviceV3ReviewActionRequest = { review_id: reviewId, action: action };
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
    useCases.resolveReview(request).then((reviewItems): void => {
      const current = this.snapshot;
      const snapshot = new PhoneV3Snapshot(
        current.sessions, current.conflicts, current.sync, current.paired,
        current.reminders, reviewItems);
      this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SNAPSHOT_READY,
        snapshot, undefined, '审核结果已保存到电脑'));
      onResolved();
    }).catch((error: Object): void => this.fail(error));
  }

  reviewSampleWasPlayed(reviewId: string, prototypeId: string): boolean {
    return this.playedReviewSampleKeys.indexOf(`${reviewId}:${prototypeId}`) >= 0;
  }

  playReviewSample(reviewId: string, prototypeId: string,
    onStarted: () => void = (): void => {}): void {
    const useCases = this.useCases;
    const player = this.reviewAudioPlayer;
    if (useCases === undefined || player === undefined || this.busy) {
      return;
    }
    this.lastRetryAction = PhoneV3RetryAction.NONE;
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.BUSY,
      undefined, undefined, '正在从电脑读取声音样本…'));
    useCases.loadReviewAudio(reviewId, prototypeId).then((response): Promise<void> =>
      player.play(response, (): void => {
        if (!this.reviewSampleWasPlayed(reviewId, prototypeId)) {
          this.playedReviewSampleKeys = this.playedReviewSampleKeys.concat([`${reviewId}:${prototypeId}`]);
        }
        onStarted();
        this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SUCCESS,
          undefined, undefined, '样本已开始播放，可以确认或拒绝'));
      })).catch((error: Object): void => this.fail(error));
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
    this.bridge?.stopPlayback();
    this.refreshDeviceState();
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
        new PhoneV3ReminderScheduler(context), new PhoneV3ComputerBackup(context, repository));
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

  private refreshDeviceState(): void {
    const bridge = this.bridge;
    if (bridge === undefined) {
      return;
    }
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.DEVICE_CHANGED,
      undefined, bridge.state()));
  }

  private onLocalAudioChanged(): void {
    if (this.refreshing || this.useCases === undefined) {
      this.refreshQueued = true;
      return;
    }
    this.refresh();
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
    const next = reducePhoneV3Ui(this.currentUiState(), action);
    // Keep the values that drive ArkUI directly on this @Observed object. A nested
    // `state.snapshot` replacement was not invalidating an already-rendered tab,
    // which left Home on its local-only bootstrap data after cache loading finished.
    this.snapshot = next.snapshot;
    this.device = next.device;
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
