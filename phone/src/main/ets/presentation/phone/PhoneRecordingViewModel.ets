import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  AudioPlaybackService,
  PhoneSyncUiState,
  PresentationLifecycleCoordinator,
  ReceivedRecordingFile,
  RecordingFile,
  WifiRecordingTransferService,
  WifiTransferBatchResult,
  WatchRecordingControlStatus,
  WatchSyncProgress,
  recordingErrorMessage,
  wifiRecordingTransferErrorMessage
} from 'common';
import {
  WearEngineRecordingReceiver,
  wearEngineErrorMessage
} from '../../services/RecordingTransferService';
import { ReceivedRecordingStore } from '../../services/ReceivedRecordingStore';
import {
  PhoneRecordingGroup,
  groupReceivedRecordings
} from './PhoneRecordingGroups';

@Observed
export class PhoneRecordingViewModel {
  status: string = '';
  isPlaying: boolean = false;
  latestRecording: RecordingFile | undefined = undefined;
  syncState: PhoneSyncUiState = new PhoneSyncUiState();
  receivedRecordingCount: number = 0;
  receivedRecordings: Array<ReceivedRecordingFile> = [];
  receivedRecordingGroups: Array<PhoneRecordingGroup> = [];
  selectedRecordingGroupKey: string = '';
  isControllingWatch: boolean = false;
  isReconnectingReceiver: boolean = false;
  remoteRecordingState: string = 'unknown';
  wifiStatus: string = '尚未开始 Wi-Fi 快传';
  wifiCapability: string = '正在检查 Wi-Fi 能力…';
  wifiProgress: number = 0;
  wifiReceiverReady: boolean = false;
  wifiBusy: boolean = false;
  wifiStopping: boolean = false;

  private context: common.UIAbilityContext | undefined = undefined;
  private playbackService: AudioPlaybackService | undefined = undefined;
  private transferReceiver: WearEngineRecordingReceiver | undefined = undefined;
  private wifiTransferService: WifiRecordingTransferService | undefined = undefined;
  private recordingStore: ReceivedRecordingStore | undefined = undefined;
  private lifecycle: PresentationLifecycleCoordinator = new PresentationLifecycleCoordinator();
  private lifecycleToken: number = -1;
  private startTask: Promise<void> | undefined = undefined;
  private cleanupTask: Promise<void> | undefined = undefined;

  start(context: common.UIAbilityContext): void {
    if (this.transferReceiver !== undefined || this.playbackService !== undefined || this.startTask !== undefined) {
      return;
    }
    this.context = context;
    this.lifecycleToken = this.lifecycle.activate();
    const token = this.lifecycleToken;
    const task = this.initializeAfterCleanup(context, token);
    this.startTask = task;
    task.then((): void => {
      this.clearStartTask(task);
    }, (error: Object): void => {
      this.clearStartTask(task);
      if (!this.lifecycle.isActive(token)) {
        return;
      }
      const businessError = error as BusinessError;
      console.error(`Wear Engine receiver start failed: code=${businessError.code}, message=${businessError.message}`);
      this.status = `连接失败：${wearEngineErrorMessage(error)}`;
    });
  }

  stop(): void {
    this.lifecycle.invalidate();
    this.lifecycleToken = -1;
    const receiver = this.transferReceiver;
    const wifiTransfer = this.wifiTransferService;
    const playback = this.playbackService;
    this.transferReceiver = undefined;
    this.wifiTransferService = undefined;
    this.recordingStore = undefined;
    this.playbackService = undefined;
    this.isPlaying = false;
    this.isControllingWatch = false;
    this.isReconnectingReceiver = false;
    this.wifiReceiverReady = false;
    this.wifiBusy = false;
    this.wifiStopping = false;
    this.wifiProgress = 0;
    this.syncState = new PhoneSyncUiState();
    const task = this.releaseResources(receiver, wifiTransfer, playback);
    this.cleanupTask = task;
    task.then((): void => {
      this.clearCleanupTask(task);
    }, (): void => {
      this.clearCleanupTask(task);
    });
  }

  requestWatchSync(): void {
    const receiver = this.transferReceiver;
    const token = this.lifecycleToken;
    if (receiver === undefined || this.syncState.inProgress || this.isReconnectingReceiver) {
      return;
    }
    receiver.requestWatchSync().then((): void => {
    }, (error: Object): void => {
      if (!this.lifecycle.isActive(token)) {
        return;
      }
      this.syncState = new PhoneSyncUiState();
      this.status = `同步请求失败：${wearEngineErrorMessage(error)}`;
    });
  }

  toggleWifiReceiver(): void {
    const service = this.wifiTransferService;
    if (service === undefined || this.wifiBusy || !this.lifecycle.isActive(this.lifecycleToken)) {
      return;
    }
    const wasReceiverReady = this.wifiReceiverReady;
    this.wifiBusy = true;
    this.wifiStopping = wasReceiverReady;
    const token = this.lifecycleToken;
    const task = this.toggleWifiReceiverAsync(service, this.transferReceiver);
    task.then((): void => {
      if (this.lifecycle.isActive(token)) {
        this.wifiBusy = false;
        this.wifiStopping = false;
      }
    }, (error: Object): void => {
      if (this.lifecycle.isActive(token)) {
        const detail = wifiRecordingTransferErrorMessage(error);
        if (wasReceiverReady) {
          this.wifiStatus = `停止 Wi-Fi 接收失败：${detail}`;
        } else if (this.wifiReceiverReady) {
          this.wifiStatus = `安全批次下发失败：${detail}；请停止接收后从手机重新发起`;
        } else {
          this.wifiStatus = `Wi-Fi 快传失败：${detail}`;
          this.wifiProgress = 0;
        }
        this.wifiBusy = false;
        this.wifiStopping = false;
      }
    });
  }

  requestWatchRecordingState(desiredState: string): void {
    const receiver = this.transferReceiver;
    const token = this.lifecycleToken;
    if (receiver === undefined || this.isControllingWatch || this.isReconnectingReceiver) {
      return;
    }
    receiver.requestRecordingState(desiredState).then((): void => {
    }, (error: Object): void => {
      if (!this.lifecycle.isActive(token)) {
        return;
      }
      this.isControllingWatch = false;
      this.status = `手机控制失败：${wearEngineErrorMessage(error)}`;
    });
  }

  reconnectReceiver(): void {
    if (this.isReconnectingReceiver || !this.lifecycle.isActive(this.lifecycleToken)) {
      return;
    }
    this.isReconnectingReceiver = true;
    const token = this.lifecycleToken;
    const task = this.reconnectReceiverAsync(token);
    task.then((): void => {
      if (this.lifecycle.isActive(token)) {
        this.isReconnectingReceiver = false;
      }
    }, (error: Object): void => {
      if (this.lifecycle.isActive(token)) {
        this.status = `重新连接失败：${wearEngineErrorMessage(error)}`;
        this.isReconnectingReceiver = false;
      }
    });
  }

  togglePlayback(): void {
    const playback = this.playbackService;
    const token = this.lifecycleToken;
    if (playback === undefined) {
      return;
    }
    const task = this.togglePlaybackAsync(playback);
    task.then((): void => {
    }, (error: Object): void => {
      if (this.lifecycle.isActive(token)) {
        this.status = `播放失败：${recordingErrorMessage(error)}`;
      }
    });
  }

  selectRecording(recording: ReceivedRecordingFile, showDeveloperStatus: boolean = false): void {
    this.selectedRecordingGroupKey = '';
    this.latestRecording = recording;
    if (showDeveloperStatus) {
      this.status = `已选择 ${recording.fileName}，可以试听`;
    }
  }

  selectRecordingGroup(group: PhoneRecordingGroup): void {
    if (group.recordings.length === 0) {
      return;
    }
    this.selectedRecordingGroupKey = group.key;
    this.latestRecording = group.recordings[0];
  }

  isRecordingGroupSelected(group: PhoneRecordingGroup): boolean {
    return this.selectedRecordingGroupKey === group.key;
  }

  syncButtonLabel(): string {
    if (!this.syncState.inProgress) {
      return '同步录音';
    }
    return this.syncState.total <= 0 ? '等待手表…' :
      `${this.syncState.received}/${this.syncState.total}`;
  }

  wifiButtonLabel(): string {
    if (this.wifiBusy) {
      if (this.wifiStopping) {
        return '正在停止…';
      }
      return this.wifiReceiverReady ? '自动传输中…' : '正在准备…';
    }
    return this.wifiReceiverReady ? '停止接收' : 'Wi-Fi 快传';
  }

  developerSyncButtonLabel(): string {
    if (!this.syncState.inProgress) {
      return '同步手表文件';
    }
    return this.syncState.total <= 0 ? '等待手表响应…' :
      `同步中 ${this.syncState.received}/${this.syncState.total}`;
  }

  transferStageLabel(): string {
    const state = this.syncState;
    if (state.transferStage === 'queued') {
      return '已排队，等待当前传输结束';
    }
    if (state.transferStage === 'preparing') {
      return state.automatic && state.transferIndex > 0 ?
        `自动队列准备发送第 ${state.transferIndex} 段` : '正在准备文件';
    }
    if (state.transferStage === 'transferring') {
      return state.automatic && state.transferIndex > 0 ?
        `自动队列正在发送第 ${state.transferIndex} 段` : '正在传输';
    }
    if (state.transferStage === 'saving') {
      return '传输完成，正在安全保存';
    }
    if (state.transferStage === 'waiting_ack') {
      return state.automatic && state.transferIndex > 0 ?
        `自动队列第 ${state.transferIndex} 段已保存，正在确认` :
        '手机已保存，正在确认回执';
    }
    return state.message.length > 0 ? state.message : '正在等待手表响应';
  }

  remoteStateLabel(): string {
    if (this.remoteRecordingState === 'recording') {
      return '正在录音';
    }
    if (this.remoteRecordingState === 'stopped') {
      return '录音已停止';
    }
    if (this.remoteRecordingState === 'pending_user_action') {
      return '等待手表确认';
    }
    return '正在确认手表状态';
  }

  userStatusMessage(): string {
    if (this.status.includes('失败') || this.status.includes('无法') || this.status.includes('错误')) {
      return '操作没有完成，请确认手机与手表已连接后重试';
    }
    if (this.remoteRecordingState === 'pending_user_action') {
      return '请在手表上点击录音通知';
    }
    return '保持手机与手表连接，可自动接收新录音';
  }

  private async startReceiver(context: common.UIAbilityContext, token: number,
    recordingStore: ReceivedRecordingStore): Promise<void> {
    const receiver = new WearEngineRecordingReceiver(context,
      (recording: ReceivedRecordingFile): void => {
        if (!this.lifecycle.isActive(token)) {
          return;
        }
        this.applyReceivedRecording(recording, receiver.getStoredRecordings());
      },
      (status: string): void => {
        if (this.lifecycle.isActive(token)) {
          this.status = status;
        }
      },
      (progress: WatchSyncProgress): void => {
        if (this.lifecycle.isActive(token)) {
          this.syncState = new PhoneSyncUiState(progress);
        }
      },
      (control: WatchRecordingControlStatus): void => {
        if (!this.lifecycle.isActive(token)) {
          return;
        }
        this.isControllingWatch = control.inProgress;
        if (control.actualState.length > 0) {
          this.remoteRecordingState = control.actualState;
        }
      }, recordingStore);
    const storedRecordings = receiver.getStoredRecordings();
    if (!this.lifecycle.isActive(token)) {
      return;
    }
    this.receivedRecordingCount = storedRecordings.length;
    this.receivedRecordings = storedRecordings.slice(0, 100);
    this.rebuildRecordingGroups(storedRecordings);
    if (storedRecordings.length > 0) {
      if (this.receivedRecordingGroups.length > 0) {
        this.selectRecordingGroup(this.receivedRecordingGroups[0]);
      } else {
        this.latestRecording = storedRecordings[0];
      }
    }
    this.transferReceiver = receiver;
    try {
      await receiver.start();
    } catch (error) {
      if (this.transferReceiver === receiver) {
        this.transferReceiver = undefined;
      }
      throw new Error(wearEngineErrorMessage(error));
    }
  }

  private async initializeAfterCleanup(context: common.UIAbilityContext, token: number): Promise<void> {
    const cleanup = this.cleanupTask;
    if (cleanup !== undefined) {
      try {
        await cleanup;
      } catch (error) {
        throw new Error('上一次手机接收器清理失败，已阻止重复注册');
      }
    }
    if (!this.lifecycle.isActive(token)) {
      return;
    }
    this.playbackService = new AudioPlaybackService((playing: boolean, message: string): void => {
      if (!this.lifecycle.isActive(token)) {
        return;
      }
      this.isPlaying = playing;
      this.status = message;
    });
    const recordingStore = new ReceivedRecordingStore(context.filesDir);
    this.recordingStore = recordingStore;
    this.initializeWifiTransfer(context, token, recordingStore);
    this.status = '正在连接已配对手表…';
    await this.startReceiver(context, token, recordingStore);
  }

  private async reconnectReceiverAsync(token: number): Promise<void> {
    this.syncState = new PhoneSyncUiState();
    const receiver = this.transferReceiver;
    if (receiver !== undefined) {
      await receiver.reconnect();
      return;
    }
    const context = this.context;
    if (context === undefined) {
      throw new Error('手机页面上下文尚未就绪');
    }
    this.status = '正在释放异常的 Wear Engine 通道…';
    await WearEngineRecordingReceiver.destroyChannel();
    if (!this.lifecycle.isActive(token)) {
      return;
    }
    this.status = 'Wear Engine 通道已重建，正在重新注册接收器…';
    const recordingStore = this.recordingStore === undefined ?
      new ReceivedRecordingStore(context.filesDir) : this.recordingStore;
    this.recordingStore = recordingStore;
    if (this.wifiTransferService === undefined) {
      this.initializeWifiTransfer(context, token, recordingStore);
    }
    await this.startReceiver(context, token, recordingStore);
  }

  private initializeWifiTransfer(context: common.UIAbilityContext, token: number,
    recordingStore: ReceivedRecordingStore): void {
    const service = new WifiRecordingTransferService(context,
      (status: string, progress: number): void => {
        if (!this.lifecycle.isActive(token)) {
          return;
        }
        this.wifiStatus = status;
        this.wifiProgress = progress;
      }, (recording: ReceivedRecordingFile): void => {
        if (!this.lifecycle.isActive(token)) {
          return;
        }
        const stored = recordingStore.recordVerified(recording);
        this.applyReceivedRecording(stored, recordingStore.list());
      }, (sourcePath: string, size: number): ReceivedRecordingFile | undefined => {
        return recordingStore.findWifiExisting(sourcePath, size);
      }, (result: WifiTransferBatchResult): void => {
        if (!this.lifecycle.isActive(token)) {
          return;
        }
        this.wifiReceiverReady = false;
        this.wifiStatus = `Wi-Fi 全量同步完成：新增 ${result.transferred} 个，手机已有 ${
          result.alreadyPresent} 个`;
      });
    this.wifiTransferService = service;
    this.wifiCapability = service.describeCapability();
  }

  private async toggleWifiReceiverAsync(service: WifiRecordingTransferService,
    receiver: WearEngineRecordingReceiver | undefined): Promise<void> {
    if (this.wifiReceiverReady) {
      await service.stopReceiver();
      this.wifiReceiverReady = false;
      this.wifiProgress = 0;
      return;
    }
    this.wifiCapability = service.describeCapability();
    if (receiver === undefined) {
      throw new Error('Wear Engine 控制通道尚未连接');
    }
    const credentials = await service.prepareReceiver();
    this.wifiReceiverReady = true;
    this.wifiStatus = '手机接收已就绪，正在自动唤醒手表并同步全部完整录音…';
    await receiver.requestWatchWifiTransfer(credentials);
  }

  private async togglePlaybackAsync(playback: AudioPlaybackService): Promise<void> {
    if (this.isPlaying) {
      await playback.release();
      this.isPlaying = false;
      this.status = '播放已停止';
      return;
    }
    const selectedGroup = this.findSelectedRecordingGroup();
    if (selectedGroup !== undefined) {
      const paths: Array<string> = [];
      for (let index = 0; index < selectedGroup.recordings.length; index += 1) {
        paths.push(selectedGroup.recordings[index].path);
      }
      await playback.playSequence(paths);
    } else if (this.latestRecording !== undefined) {
      await playback.play(this.latestRecording.path);
    }
  }

  private rebuildRecordingGroups(recordings: Array<ReceivedRecordingFile>,
    preferredRecordingPath: string = ''): void {
    this.receivedRecordingGroups = groupReceivedRecordings(recordings);
    if (preferredRecordingPath.length > 0) {
      for (let groupIndex = 0; groupIndex < this.receivedRecordingGroups.length; groupIndex += 1) {
        const group = this.receivedRecordingGroups[groupIndex];
        for (let recordingIndex = 0; recordingIndex < group.recordings.length; recordingIndex += 1) {
          if (group.recordings[recordingIndex].path === preferredRecordingPath) {
            this.selectRecordingGroup(group);
            return;
          }
        }
      }
    }
    if (this.findSelectedRecordingGroup() === undefined) {
      this.selectedRecordingGroupKey = '';
    }
  }

  private applyReceivedRecording(recording: ReceivedRecordingFile,
    storedRecordings: Array<ReceivedRecordingFile>): void {
    this.latestRecording = recording;
    const remaining: Array<ReceivedRecordingFile> = this.receivedRecordings.filter(
      (item: ReceivedRecordingFile): boolean => item.path !== recording.path);
    this.receivedRecordingCount = storedRecordings.length;
    this.receivedRecordings = [recording, ...remaining].slice(0, 100);
    this.rebuildRecordingGroups(storedRecordings, recording.path);
  }

  private findSelectedRecordingGroup(): PhoneRecordingGroup | undefined {
    for (let index = 0; index < this.receivedRecordingGroups.length; index += 1) {
      if (this.receivedRecordingGroups[index].key === this.selectedRecordingGroupKey) {
        return this.receivedRecordingGroups[index];
      }
    }
    return undefined;
  }

  private async releaseResources(receiver: WearEngineRecordingReceiver | undefined,
    wifiTransfer: WifiRecordingTransferService | undefined,
    playback: AudioPlaybackService | undefined): Promise<void> {
    try {
      if (receiver !== undefined) {
        await receiver.stop();
      }
    } finally {
      try {
        if (wifiTransfer !== undefined) {
          await wifiTransfer.shutdown();
        }
      } finally {
        if (playback !== undefined) {
          await playback.release();
        }
      }
    }
  }

  private clearStartTask(task: Promise<void>): void {
    if (this.startTask === task) {
      this.startTask = undefined;
    }
  }

  private clearCleanupTask(task: Promise<void>): void {
    if (this.cleanupTask === task) {
      this.cleanupTask = undefined;
    }
  }
}
