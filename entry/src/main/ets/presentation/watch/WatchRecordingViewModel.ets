import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import {
  AudioPlaybackService,
  PresentationLifecycleCoordinator,
  RecordingFile,
  WifiTransferSessionCredentials,
  WifiRecordingTransferService,
  WifiTransferBatchCleanupResult,
  recordingErrorMessage,
  wifiRecordingTransferErrorMessage
} from 'common';
import {
  WearEngineRecordingSender,
  WatchRecordingControlResult,
  wearEngineErrorMessage
} from '../../services/RecordingTransferService';
import {
  InterruptedWavRecoveryResult,
  InterruptedWavRecoveryService
} from '../../services/InterruptedWavRecoveryService';
import { PcmSegmentedRecordingService } from '../../services/PcmSegmentedRecordingService';
import {
  PendingWatchRecordingStart,
  WatchRecordingStartFallback,
  WatchRecordingUiState
} from '../../services/WatchRecordingStartFallback';

@Observed
export class WatchRecordingViewModel {
  status: string = '';
  isRecording: boolean = false;
  isPlaying: boolean = false;
  elapsedSeconds: number = 0;
  activeSegmentIndex: number = 0;
  completedSegments: number = 0;
  hardwareOverflowCount: number = 0;
  latestRecording: RecordingFile | undefined = undefined;
  isSending: boolean = false;
  notificationEnabled: boolean = true;
  wifiStatus: string = '先在手机点击“Wi-Fi 快传”开始接收';
  wifiCapability: string = '正在检查 Wi-Fi 能力…';
  wifiProgress: number = 0;
  wifiSending: boolean = false;
  wifiRecording: RecordingFile | undefined = undefined;
  wifiRecordingCount: number = 0;
  wifiRecordingTotalBytes: number = 0;

  private context: common.UIAbilityContext | undefined = undefined;
  private recordingService: PcmSegmentedRecordingService | undefined = undefined;
  private playbackService: AudioPlaybackService | undefined = undefined;
  private transferSender: WearEngineRecordingSender | undefined = undefined;
  private wifiTransferService: WifiRecordingTransferService | undefined = undefined;
  private recordingStartFallback: WatchRecordingStartFallback | undefined = undefined;
  private lifecycle: PresentationLifecycleCoordinator = new PresentationLifecycleCoordinator();
  private lifecycleToken: number = -1;
  private pendingForegroundStartInProgress: boolean = false;
  private notificationPermissionCheckInProgress: boolean = false;
  private notificationPermissionRequested: boolean = false;
  private recordingActionInProgress: boolean = false;
  private timerId: number = -1;
  private recordingStartedAt: number = 0;
  private startTask: Promise<void> | undefined = undefined;
  private responderTask: Promise<void> | undefined = undefined;
  private cleanupTask: Promise<void> | undefined = undefined;

  start(context: common.UIAbilityContext): void {
    if (this.recordingService !== undefined || this.transferSender !== undefined || this.startTask !== undefined) {
      return;
    }
    this.context = context;
    this.lifecycleToken = this.lifecycle.activate();
    const token = this.lifecycleToken;
    const cleanup = this.cleanupTask;
    if (cleanup !== undefined) {
      const task = this.startAfterCleanup(cleanup, context, token);
      this.startTask = task;
      task.then((): void => {
        this.clearStartTask(task);
      }, (): void => {
        this.clearStartTask(task);
      });
      return;
    }
    this.initialize(context, token);
  }

  private initialize(context: common.UIAbilityContext, token: number): void {
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
    const wifiTransfer = new WifiRecordingTransferService(context,
      (status: string, progress: number): void => {
        if (!this.lifecycle.isActive(token)) {
          return;
        }
        this.wifiStatus = status;
        this.wifiProgress = progress;
      }, (): void => {
      });
    this.wifiTransferService = wifiTransfer;
    this.wifiCapability = wifiTransfer.describeCapability();
    this.refreshWifiRecording();

    const recoveryStatus = this.recoverInterruptedRecordings(context.filesDir);
    this.recordingService = new PcmSegmentedRecordingService(context, {
      onSegmentStarted: (segmentIndex: number, firstSample: number): void => {
        if (!this.lifecycle.isActive(token)) {
          return;
        }
        this.activeSegmentIndex = segmentIndex;
        this.status = `第 ${segmentIndex} 段 · 起始采样 ${firstSample}`;
      },
      onSegmentCompleted: (recording: RecordingFile, completedCount: number,
        _firstSample: number, sampleCount: number): void => {
        if (!this.lifecycle.isActive(token)) {
          return;
        }
        this.latestRecording = recording;
        this.refreshWifiRecording();
        this.completedSegments = completedCount;
        if (this.isRecording) {
          this.status = `第 ${completedCount} 段 ${sampleCount} 采样已封口`;
        }
        this.transferSender?.enqueueAutomatic(recording);
      },
      onSessionError: (message: string): void => {
        if (!this.lifecycle.isActive(token)) {
          return;
        }
        this.isRecording = false;
        this.stopTimer();
        this.status = `连续采集失败：${message}`;
      }
    });
    this.transferSender = new WearEngineRecordingSender(context, (status: string): void => {
      if (this.lifecycle.isActive(token)) {
        this.status = status;
      }
    }, (desiredState: string, requestId: string): Promise<WatchRecordingControlResult> =>
      this.applyPhoneRecordingControl(desiredState, requestId),
    (_requestId: string, credentials: WifiTransferSessionCredentials): Promise<string> =>
      this.performAllWifiTransfer(credentials));
    this.recordingStartFallback = new WatchRecordingStartFallback(context);
    WatchRecordingUiState.setForegroundListener((): void => {
      if (this.lifecycle.isActive(token)) {
        this.resumePendingPhoneRecordingStart();
      }
    });
    this.status = recoveryStatus.length > 0 ? recoveryStatus : '连续采集，按采样点每 1 分钟切 WAV';
    this.startSyncResponder(token);
    this.ensureNotificationEnabled();
    this.resumePendingPhoneRecordingStart();
  }

  onPageShow(): void {
    if (!this.lifecycle.isActive(this.lifecycleToken)) {
      return;
    }
    this.ensureNotificationEnabled();
    this.resumePendingPhoneRecordingStart();
  }

  stop(): void {
    this.lifecycle.invalidate();
    this.lifecycleToken = -1;
    WatchRecordingUiState.setForegroundListener(undefined);
    this.stopTimer();
    const sender = this.transferSender;
    const wifiTransfer = this.wifiTransferService;
    const recording = this.recordingService;
    const playback = this.playbackService;
    this.transferSender = undefined;
    this.wifiTransferService = undefined;
    this.recordingService = undefined;
    this.playbackService = undefined;
    this.recordingStartFallback = undefined;
    this.isPlaying = false;
    this.wifiSending = false;
    this.pendingForegroundStartInProgress = false;
    this.notificationPermissionCheckInProgress = false;
    this.recordingActionInProgress = false;
    const task = this.releaseResources(sender, wifiTransfer, recording, playback);
    this.cleanupTask = task;
    task.then((): void => {
      this.clearCleanupTask(task);
    }, (): void => {
      this.clearCleanupTask(task);
    });
  }

  toggleRecording(): void {
    if (this.recordingActionInProgress) {
      return;
    }
    this.recordingActionInProgress = true;
    const token = this.lifecycleToken;
    const wasRecording = this.isRecording;
    const task = wasRecording ? this.stopRecordingSession() : this.startRecordingSession();
    task.then((): void => {
      if (this.lifecycle.isActive(token)) {
        this.recordingActionInProgress = false;
      }
    }, (error: Object): void => {
      if (this.lifecycle.isActive(token)) {
        this.status = `${wasRecording ? '停止录音' : '录音'}失败：${recordingErrorMessage(error)}`;
        this.recordingActionInProgress = false;
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

  sendLatestRecording(): void {
    const sender = this.transferSender;
    const recording = this.latestRecording;
    if (sender === undefined || recording === undefined || this.isSending) {
      return;
    }
    this.isSending = true;
    this.status = '正在发送到手机，手表原文件会保留…';
    const token = this.lifecycleToken;
    sender.send(recording).then((): void => {
      if (this.lifecycle.isActive(token)) {
        this.status = '发送完成，手表原文件已保留';
        this.isSending = false;
      }
    }, (error: Object): void => {
      if (this.lifecycle.isActive(token)) {
        this.status = `发送失败，原文件已保留：${wearEngineErrorMessage(error)}`;
        this.isSending = false;
      }
    });
  }

  refreshWifiRecording(): void {
    const service = this.wifiTransferService;
    if (service === undefined) {
      return;
    }
    try {
      const recordings = service.findAllRecordings();
      const latest = service.findLatestRecording();
      this.wifiRecording = latest;
      this.wifiRecordingCount = recordings.length;
      this.wifiRecordingTotalBytes = 0;
      for (let index = 0; index < recordings.length; index += 1) {
        this.wifiRecordingTotalBytes += recordings[index].size;
      }
    } catch (error) {
      this.wifiStatus = `录音扫描失败：${wifiRecordingTransferErrorMessage(error as Object)}`;
    }
  }

  openNotificationSettings(): void {
    if (this.recordingStartFallback === undefined || this.notificationPermissionCheckInProgress) {
      return;
    }
    const token = this.lifecycleToken;
    const task = this.openNotificationSettingsAsync();
    task.then((): void => {
    }, (error: Object): void => {
      if (this.lifecycle.isActive(token)) {
        this.notificationEnabled = false;
        this.status = `无法打开通知设置：${recordingErrorMessage(error)}`;
        this.notificationPermissionCheckInProgress = false;
      }
    });
  }

  resetLatestRecording(): void {
    this.latestRecording = undefined;
    this.completedSegments = 0;
    this.activeSegmentIndex = 0;
    this.hardwareOverflowCount = 0;
    this.status = '连续采集，按采样点每 1 分钟切 WAV';
  }

  userStatusMessage(): string {
    if (!this.notificationEnabled) {
      return '开启通知后，可接收手机发来的录音请求';
    }
    if (this.status.includes('失败') || this.status.includes('无法') || this.status.includes('错误')) {
      return '操作没有完成，请重试或在开发者界面查看详情';
    }
    return this.isRecording ? '熄屏后仍会继续录音' : '录音只保存在你的设备中';
  }

  private recoverInterruptedRecordings(filesDirectory: string): string {
    try {
      const recovery: InterruptedWavRecoveryResult = InterruptedWavRecoveryService.recover(filesDirectory);
      if (recovery.recoveredCount === 0 && recovery.discardedEmptyCount === 0 && recovery.failureCount === 0) {
        return '';
      }
      let message = `恢复 ${recovery.recoveredCount} 段 · 空槽 ${recovery.discardedEmptyCount}`;
      if (recovery.failureCount > 0) {
        message += ` · 失败 ${recovery.failureCount}`;
      }
      return message;
    } catch (error) {
      return `中断片段扫描失败：${recordingErrorMessage(error)}`;
    }
  }

  private startSyncResponder(token: number): void {
    const sender = this.transferSender;
    if (sender === undefined) {
      return;
    }
    const task = sender.start();
    this.responderTask = task;
    task.then((): void => {
      this.clearResponderTask(task);
    }, (error: Object): void => {
      this.clearResponderTask(task);
      if (this.lifecycle.isActive(token)) {
        this.status = `手机同步监听失败：${wearEngineErrorMessage(error)}`;
      }
    });
  }

  private async startRecordingSession(): Promise<void> {
    const recording = this.recordingService;
    if (recording === undefined) {
      throw new Error('手表录音服务尚未就绪');
    }
    if (this.isRecording) {
      return;
    }
    if (!await this.requestMicrophonePermission()) {
      throw new Error('需要在手表上允许麦克风权限');
    }
    if (this.playbackService !== undefined) {
      await this.playbackService.release();
    }
    this.isPlaying = false;
    this.latestRecording = undefined;
    this.completedSegments = 0;
    this.activeSegmentIndex = 0;
    this.hardwareOverflowCount = 0;
    await recording.start();
    this.isRecording = true;
    this.elapsedSeconds = 0;
    this.recordingStartedAt = recording.getStartedAt();
    this.status = 'AudioCapturer 持续运行，可以熄屏';
    this.startTimer();
  }

  private async stopRecordingSession(): Promise<void> {
    const recording = this.recordingService;
    if (recording === undefined) {
      throw new Error('手表录音服务尚未就绪');
    }
    if (!this.isRecording) {
      return;
    }
    try {
      const finalRecording = await recording.stop();
      if (finalRecording !== undefined) {
        this.latestRecording = finalRecording;
      }
      this.completedSegments = recording.getCompletedCount();
      this.hardwareOverflowCount = recording.getHardwareOverflowCount();
      this.status = `完成 ${this.completedSegments} 段 · 硬件溢出 ${this.hardwareOverflowCount}`;
    } finally {
      this.isRecording = false;
      this.stopTimer();
    }
  }

  private async applyPhoneRecordingControl(desiredState: string,
    requestId: string): Promise<WatchRecordingControlResult> {
    if (desiredState === 'recording') {
      if (!this.isRecording && !WatchRecordingUiState.isForeground()) {
        if (this.recordingStartFallback === undefined) {
          throw new Error('手表通知启动服务尚未就绪');
        }
        await this.recordingStartFallback.requestUserForeground(requestId);
        return {
          actualState: 'pending_user_action',
          sessionId: '',
          message: '手表已收到请求，请在手表上点击录音通知'
        };
      }
      try {
        await this.startRecordingSession();
      } catch (error) {
        const message = recordingErrorMessage(error);
        if (message.includes('6800301')) {
          throw new Error('手表后台持续任务已请求，但系统仍拒绝开麦（6800301）');
        }
        throw new Error(message);
      }
      return {
        actualState: 'recording',
        sessionId: this.recordingService?.getStartedAt().toString() || requestId,
        message: '手机已启动手表录音'
      };
    }
    if (desiredState === 'stopped') {
      if (this.recordingStartFallback !== undefined) {
        await this.recordingStartFallback.clearPending();
      }
      await this.stopRecordingSession();
      return {
        actualState: 'stopped',
        sessionId: this.recordingService?.getStartedAt().toString() || requestId,
        message: '手表录音已停止，最后分片已封口'
      };
    }
    throw new Error('不支持的录音目标状态');
  }

  private async performAllWifiTransfer(credentials: WifiTransferSessionCredentials): Promise<string> {
    const service = this.wifiTransferService;
    if (service === undefined) {
      throw new Error('手表 Wi-Fi 快传服务尚未就绪');
    }
    if (this.wifiSending) {
      throw new Error('上一项 Wi-Fi 快传仍在进行');
    }
    this.refreshWifiRecording();
    const recordings = service.findAllRecordings();
    if (recordings.length === 0) {
      this.wifiStatus = '没有找到可同步的完整录音';
      throw new Error(this.wifiStatus);
    }
    this.wifiSending = true;
    this.wifiStatus = `已收到配对手机的一次性安全凭据，正在加密同步全部 ${recordings.length} 个录音…`;
    const token = this.lifecycleToken;
    try {
      const playback = this.playbackService;
      if (playback !== undefined && playback.hasActiveSession()) {
        await playback.release();
        this.isPlaying = false;
      }
      const result: WifiTransferBatchCleanupResult = await service.sendAllAndDeleteSources(recordings, credentials);
      this.transferSender?.removeWifiCleanedSources(result.cleanedSourcePaths);
      this.refreshWifiRecording();
      this.refreshLatestRecordingAfterWifiCleanup(service, result.cleanedSourcePaths);
      const message = `Wi-Fi 全量同步完成：新增 ${result.transferred} 个，手机已有 ${result.alreadyPresent} 个；` +
        `手表已删除 ${result.deleted} 个${result.alreadyAbsent > 0 ? `，${result.alreadyAbsent} 个原本已不存在` : ''}` +
        `${result.retained > 0 ? `，${result.retained} 个清理失败并保留` : ''}`;
      if (this.lifecycle.isActive(token)) {
        this.wifiStatus = message;
        this.wifiProgress = 100;
      }
      return message;
    } catch (error) {
      const message = wifiRecordingTransferErrorMessage(error as Object);
      if (this.lifecycle.isActive(token)) {
        this.wifiStatus = `Wi-Fi 快传失败，原文件已保留：${message}`;
        if (this.wifiProgress < 99) {
          this.wifiProgress = 0;
        }
      }
      throw new Error(message);
    } finally {
      if (this.lifecycle.isActive(token)) {
        this.wifiSending = false;
      }
    }
  }

  private refreshLatestRecordingAfterWifiCleanup(service: WifiRecordingTransferService,
    cleanedPaths: Array<string>): void {
    const latest = this.latestRecording;
    if (latest === undefined || cleanedPaths.indexOf(latest.path) < 0) {
      return;
    }
    this.latestRecording = service.findLatestRecording();
  }

  private resumePendingPhoneRecordingStart(): void {
    if (this.pendingForegroundStartInProgress || this.recordingStartFallback === undefined) {
      return;
    }
    this.pendingForegroundStartInProgress = true;
    const token = this.lifecycleToken;
    const task = this.resumePendingPhoneRecordingStartAsync();
    task.then((): void => {
      if (this.lifecycle.isActive(token)) {
        this.pendingForegroundStartInProgress = false;
      }
    }, (): void => {
      if (this.lifecycle.isActive(token)) {
        this.pendingForegroundStartInProgress = false;
      }
    });
  }

  private async resumePendingPhoneRecordingStartAsync(): Promise<void> {
    const fallback = this.recordingStartFallback;
    if (fallback === undefined) {
      return;
    }
    let pending: PendingWatchRecordingStart | undefined = undefined;
    try {
      pending = await fallback.takePending();
      if (pending === undefined) {
        return;
      }
      this.status = '已进入前台，正在执行手机录音请求…';
      await this.startRecordingSession();
      const result: WatchRecordingControlResult = {
        actualState: 'recording',
        sessionId: this.recordingService?.getStartedAt().toString() || pending.requestId,
        message: '已点击手表通知，录音已开始'
      };
      try {
        if (this.transferSender !== undefined) {
          await this.transferSender.reportRecordingControlResult(pending.requestId, 'recording', true, result);
        }
      } catch (error) {
        this.status = `录音已开始，手机最终回执待重连：${wearEngineErrorMessage(error)}`;
      }
    } catch (error) {
      const message = recordingErrorMessage(error);
      this.status = `通知启动录音失败：${message}`;
      if (pending !== undefined && this.transferSender !== undefined) {
        try {
          await this.transferSender.reportRecordingControlResult(pending.requestId, 'recording', false, {
            actualState: 'stopped',
            sessionId: '',
            message: message
          });
        } catch (reportError) {
          // The watch status remains visible even if the phone has disconnected.
        }
      }
    }
  }

  private ensureNotificationEnabled(): void {
    if (this.notificationPermissionCheckInProgress || this.recordingStartFallback === undefined) {
      return;
    }
    this.notificationPermissionCheckInProgress = true;
    const token = this.lifecycleToken;
    const task = this.ensureNotificationEnabledAsync();
    task.then((): void => {
      if (this.lifecycle.isActive(token)) {
        this.notificationPermissionCheckInProgress = false;
      }
    }, (error: Object): void => {
      if (this.lifecycle.isActive(token)) {
        this.notificationEnabled = false;
        this.status = `通知检查失败：${recordingErrorMessage(error)}`;
        this.notificationPermissionCheckInProgress = false;
      }
    });
  }

  private async ensureNotificationEnabledAsync(): Promise<void> {
    const fallback = this.recordingStartFallback;
    if (fallback === undefined) {
      return;
    }
    const enabled = await fallback.isNotificationEnabled();
    this.notificationEnabled = enabled;
    if (enabled || this.notificationPermissionRequested) {
      return;
    }
    this.notificationPermissionRequested = true;
    this.status = '请允许通知，用于接收手机录音请求';
    this.notificationEnabled = await fallback.requestNotificationAuthorization();
    this.status = this.notificationEnabled ? '通知已开启，可以接收手机录音请求' :
      '通知未开启，请点击“开启通知”';
  }

  private async openNotificationSettingsAsync(): Promise<void> {
    const fallback = this.recordingStartFallback;
    if (fallback === undefined) {
      return;
    }
    this.notificationPermissionCheckInProgress = true;
    this.status = '正在打开通知设置…';
    this.notificationEnabled = await fallback.openNotificationSettings();
    this.status = this.notificationEnabled ? '通知已开启，可以接收手机录音请求' :
      '通知仍未开启，请在系统窗口中允许';
    this.notificationPermissionCheckInProgress = false;
  }

  private async togglePlaybackAsync(playback: AudioPlaybackService): Promise<void> {
    if (this.isPlaying) {
      await playback.release();
      this.isPlaying = false;
      this.status = '播放已停止';
      return;
    }
    if (this.latestRecording !== undefined) {
      await playback.play(this.latestRecording.path);
    }
  }

  private async requestMicrophonePermission(): Promise<boolean> {
    const context = this.context;
    if (context === undefined) {
      return false;
    }
    const permissions: Array<Permissions> = ['ohos.permission.MICROPHONE'];
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      await atManager.requestPermissionsFromUser(context, permissions);
      const grantStatus = await atManager.checkAccessToken(context.applicationInfo.accessTokenId, permissions[0]);
      return grantStatus === 0;
    } catch (error) {
      return false;
    }
  }

  private startTimer(): void {
    this.stopTimer();
    const token = this.lifecycleToken;
    this.timerId = setInterval((): void => {
      if (!this.lifecycle.isActive(token)) {
        this.stopTimer();
        return;
      }
      this.elapsedSeconds = Math.max(0, Math.floor((Date.now() - this.recordingStartedAt) / 1000));
    }, 1000);
  }

  private stopTimer(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private async releaseResources(sender: WearEngineRecordingSender | undefined,
    wifiTransfer: WifiRecordingTransferService | undefined,
    recording: PcmSegmentedRecordingService | undefined,
    playback: AudioPlaybackService | undefined): Promise<void> {
    try {
      if (sender !== undefined) {
        await sender.stop();
      }
    } finally {
      try {
        if (wifiTransfer !== undefined) {
          await wifiTransfer.shutdown();
        }
      } finally {
        try {
          if (recording !== undefined) {
            await recording.release();
          }
        } finally {
          if (playback !== undefined) {
            await playback.release();
          }
        }
      }
    }
  }

  private async startAfterCleanup(cleanup: Promise<void>, context: common.UIAbilityContext,
    token: number): Promise<void> {
    try {
      await cleanup;
    } catch (error) {
      if (this.lifecycle.isActive(token)) {
        this.status = '上一次手表页面资源清理失败，已阻止重复启动';
      }
      return;
    }
    this.initialize(context, token);
  }

  private clearStartTask(task: Promise<void>): void {
    if (this.startTask === task) {
      this.startTask = undefined;
    }
  }

  private clearResponderTask(task: Promise<void>): void {
    if (this.responderTask === task) {
      this.responderTask = undefined;
    }
  }

  private clearCleanupTask(task: Promise<void>): void {
    if (this.cleanupTask === task) {
      this.cleanupTask = undefined;
    }
  }
}
