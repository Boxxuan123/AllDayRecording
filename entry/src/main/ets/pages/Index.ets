import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { SymbolGlyphModifier, uiMaterial } from '@kit.ArkUI';
import { AudioPlaybackService } from '../services/AudioPlaybackService';
import { InterruptedWavRecoveryResult, InterruptedWavRecoveryService } from
  '../services/InterruptedWavRecoveryService';
import { PcmSegmentedRecordingService } from '../services/PcmSegmentedRecordingService';
import {
  PendingWatchRecordingStart,
  WatchRecordingStartFallback,
  WatchRecordingUiState
} from '../services/WatchRecordingStartFallback';
import {
  WearEngineRecordingReceiver,
  WearEngineRecordingSender,
  WatchRecordingControlResult,
  wearEngineErrorMessage
} from '../services/RecordingTransferService';
import {
  ReceivedRecordingFile,
  RecordingFile,
  WatchRecordingControlStatus,
  WatchSyncProgress
} from '../models/RecordingModels';

const PHONE_DEVELOPER_ROUTE: string = 'phoneDeveloper';

class PhoneDeveloperRouteParams {
}

@Entry
@Component
struct Index {
  @State private status: string = '';
  @State private isRecording: boolean = false;
  @State private isPlaying: boolean = false;
  @State private elapsedSeconds: number = 0;
  @State private activeSegmentIndex: number = 0;
  @State private completedSegments: number = 0;
  @State private hardwareOverflowCount: number = 0;
  @State private latestRecording: RecordingFile | undefined = undefined;
  @State private isSending: boolean = false;
  @State private isSyncing: boolean = false;
  @State private syncTotal: number = 0;
  @State private syncReceived: number = 0;
  @State private syncSkipped: number = 0;
  @State private syncAlreadyReceived: number = 0;
  @State private syncScannedTotal: number = 0;
  @State private syncProgressMessage: string = '';
  @State private fileTransferActive: boolean = false;
  @State private fileTransferStage: string = 'idle';
  @State private fileTransferPercent: number = 0;
  @State private fileTransferName: string = '';
  @State private fileTransferredBytes: number = 0;
  @State private fileTransferSize: number = 0;
  @State private fileTransferIndex: number = 0;
  @State private fileTransferTotal: number = 0;
  @State private fileTransferAutomatic: boolean = false;
  @State private receivedRecordingCount: number = 0;
  @State private receivedRecordings: Array<ReceivedRecordingFile> = [];
  @State private isControllingWatch: boolean = false;
  @State private remoteRecordingState: string = 'unknown';
  @State private notificationEnabled: boolean = true;
  @State private selectedTab: number = 0;
  @State private watchPageIndex: number = 1;

  private isWearable: boolean = deviceInfo.deviceType === 'wearable';
  private recordingService: PcmSegmentedRecordingService | undefined = undefined;
  private playbackService: AudioPlaybackService | undefined = undefined;
  private transferSender: WearEngineRecordingSender | undefined = undefined;
  private transferReceiver: WearEngineRecordingReceiver | undefined = undefined;
  private recordingStartFallback: WatchRecordingStartFallback | undefined = undefined;
  private pendingForegroundStartInProgress: boolean = false;
  private notificationPermissionCheckInProgress: boolean = false;
  private notificationPermissionRequested: boolean = false;
  private tabsController: TabsController = new TabsController();
  private watchSwiperController: SwiperController = new SwiperController();
  private phoneNavStack: NavPathStack = new NavPathStack();
  private timerId: number = -1;
  private recordingStartedAt: number = 0;

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.playbackService = new AudioPlaybackService((playing: boolean, message: string) => {
      this.isPlaying = playing;
      this.status = message;
    });
    if (!this.isWearable) {
      this.status = '正在连接已配对手表…';
      this.startPhoneReceiver(context);
      return;
    }

    let recoveryStatus: string = '';
    try {
      const recovery: InterruptedWavRecoveryResult = InterruptedWavRecoveryService.recover(context.filesDir);
      if (recovery.recoveredCount > 0 || recovery.discardedEmptyCount > 0 || recovery.failureCount > 0) {
        recoveryStatus = `恢复 ${recovery.recoveredCount} 段 · 空槽 ${recovery.discardedEmptyCount}`;
        if (recovery.failureCount > 0) {
          recoveryStatus += ` · 失败 ${recovery.failureCount}`;
        }
      }
    } catch (error) {
      recoveryStatus = `中断片段扫描失败：${this.errorMessage(error)}`;
    }
    this.recordingService = new PcmSegmentedRecordingService(context, {
      onSegmentStarted: (segmentIndex: number, firstSample: number) => {
        this.activeSegmentIndex = segmentIndex;
        this.status = `第 ${segmentIndex} 段 · 起始采样 ${firstSample}`;
      },
      onSegmentCompleted: (recording: RecordingFile, completedCount: number,
        firstSample: number, sampleCount: number) => {
        this.latestRecording = recording;
        this.completedSegments = completedCount;
        if (this.isRecording) {
          this.status = `第 ${completedCount} 段 ${sampleCount} 采样已封口`;
        }
        this.transferSender?.enqueueAutomatic(recording);
      },
      onSessionError: (message: string) => {
        this.isRecording = false;
        this.stopTimer();
        this.status = `连续采集失败：${message}`;
      }
    });
    this.transferSender = new WearEngineRecordingSender(context, (status: string) => {
      this.status = status;
    }, (desiredState: string, requestId: string) => this.applyPhoneRecordingControl(desiredState, requestId));
    this.recordingStartFallback = new WatchRecordingStartFallback(context);
    WatchRecordingUiState.setForegroundListener(() => {
      this.resumePendingPhoneRecordingStart();
    });
    this.startWatchSyncResponder();
    this.status = recoveryStatus.length > 0 ? recoveryStatus : '连续采集，按采样点每 1 分钟切 WAV';
  }

  onPageShow(): void {
    if (this.isWearable) {
      this.ensureWatchNotificationEnabled();
      this.resumePendingPhoneRecordingStart();
    }
  }

  aboutToDisappear(): void {
    this.stopTimer();
    if (this.isWearable) {
      WatchRecordingUiState.setForegroundListener(undefined);
    }
    if (this.transferReceiver !== undefined) {
      this.transferReceiver.stop();
      this.transferReceiver = undefined;
    }
    if (this.transferSender !== undefined) {
      this.transferSender.stop();
      this.transferSender = undefined;
    }
    if (this.recordingService !== undefined) {
      this.recordingService.release();
    }
    if (this.playbackService !== undefined) {
      this.playbackService.release();
    }
  }

  private async startPhoneReceiver(context: common.UIAbilityContext): Promise<void> {
    if (this.transferReceiver !== undefined) {
      return;
    }
    const receiver = new WearEngineRecordingReceiver(context,
      (recording: ReceivedRecordingFile) => {
        this.latestRecording = recording;
        const remaining: Array<ReceivedRecordingFile> = [];
        for (let index = 0; index < this.receivedRecordings.length; index += 1) {
          if (this.receivedRecordings[index].path !== recording.path) {
            remaining.push(this.receivedRecordings[index]);
          }
        }
        this.receivedRecordingCount = receiver.getStoredRecordings().length;
        this.receivedRecordings = [recording, ...remaining].slice(0, 100);
      },
      (status: string) => {
        this.status = status;
      },
      (progress: WatchSyncProgress) => {
        this.isSyncing = progress.inProgress;
        this.syncTotal = progress.total;
        this.syncReceived = progress.received;
        this.syncSkipped = progress.skipped;
        this.syncAlreadyReceived = progress.alreadyReceived;
        this.syncScannedTotal = progress.scannedTotal !== undefined ? progress.scannedTotal : 0;
        this.syncProgressMessage = progress.message;
        this.fileTransferActive = progress.fileTransferActive === true;
        this.fileTransferStage = progress.transferStage !== undefined ? progress.transferStage : 'idle';
        this.fileTransferPercent = progress.transferPercent !== undefined ? progress.transferPercent : 0;
        this.fileTransferName = progress.transferFileName !== undefined ? progress.transferFileName : '';
        this.fileTransferredBytes = progress.transferredBytes !== undefined ? progress.transferredBytes : 0;
        this.fileTransferSize = progress.transferSize !== undefined ? progress.transferSize : 0;
        this.fileTransferIndex = progress.transferIndex !== undefined ? progress.transferIndex : 0;
        this.fileTransferTotal = progress.transferTotal !== undefined ? progress.transferTotal : 0;
        this.fileTransferAutomatic = progress.automatic === true;
      },
      (control: WatchRecordingControlStatus) => {
        this.isControllingWatch = control.inProgress;
        if (control.actualState.length > 0) {
          this.remoteRecordingState = control.actualState;
        }
      });
    const storedRecordings = receiver.getStoredRecordings();
    this.receivedRecordingCount = storedRecordings.length;
    this.receivedRecordings = storedRecordings.slice(0, 100);
    if (storedRecordings.length > 0) {
      this.latestRecording = storedRecordings[0];
    }
    this.transferReceiver = receiver;
    try {
      await receiver.start();
    } catch (error) {
      if (this.transferReceiver === receiver) {
        this.transferReceiver = undefined;
      }
      const businessError = error as BusinessError;
      console.error(`Wear Engine receiver start failed: code=${businessError.code}, message=${businessError.message}`);
      this.status = `连接失败：${wearEngineErrorMessage(error)}`;
    }
  }

  private async startWatchSyncResponder(): Promise<void> {
    if (this.transferSender === undefined) {
      return;
    }
    try {
      await this.transferSender.start();
    } catch (error) {
      this.status = `手机同步监听失败：${wearEngineErrorMessage(error)}`;
    }
  }

  private async requestWatchSync(): Promise<void> {
    if (this.transferReceiver === undefined || this.isSyncing) {
      return;
    }
    try {
      await this.transferReceiver.requestWatchSync();
    } catch (error) {
      this.resetSyncUiState();
      this.status = `同步请求失败：${wearEngineErrorMessage(error)}`;
    }
  }

  private async requestWatchRecordingState(desiredState: string): Promise<void> {
    if (this.transferReceiver === undefined || this.isControllingWatch) {
      return;
    }
    try {
      await this.transferReceiver.requestRecordingState(desiredState);
    } catch (error) {
      this.isControllingWatch = false;
      this.status = `手机控制失败：${wearEngineErrorMessage(error)}`;
    }
  }

  private async reconnectPhoneReceiver(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.resetSyncUiState();
    if (this.transferReceiver !== undefined) {
      await this.transferReceiver.stop();
      this.transferReceiver = undefined;
    }
    this.status = '正在重新注册 Wear Engine 接收器…';
    await this.startPhoneReceiver(context);
  }

  private resetSyncUiState(): void {
    this.isSyncing = false;
    this.syncTotal = 0;
    this.syncReceived = 0;
    this.syncSkipped = 0;
    this.syncAlreadyReceived = 0;
    this.syncScannedTotal = 0;
    this.syncProgressMessage = '';
    this.fileTransferActive = false;
    this.fileTransferStage = 'idle';
    this.fileTransferPercent = 0;
    this.fileTransferName = '';
    this.fileTransferredBytes = 0;
    this.fileTransferSize = 0;
    this.fileTransferIndex = 0;
    this.fileTransferTotal = 0;
    this.fileTransferAutomatic = false;
  }

  private syncButtonLabel(): string {
    if (!this.isSyncing) {
      return '同步录音';
    }
    if (this.syncTotal <= 0) {
      return '等待手表…';
    }
    return `${this.syncReceived}/${this.syncTotal}`;
  }

  private developerSyncButtonLabel(): string {
    if (!this.isSyncing) {
      return '同步手表文件';
    }
    if (this.syncTotal <= 0) {
      return '等待手表响应…';
    }
    return `同步中 ${this.syncReceived}/${this.syncTotal}`;
  }

  private transferStageLabel(): string {
    if (this.fileTransferStage === 'queued') {
      return '已排队，等待当前传输结束';
    }
    if (this.fileTransferStage === 'preparing') {
      return this.fileTransferAutomatic && this.fileTransferIndex > 0 ?
        `自动队列准备发送第 ${this.fileTransferIndex} 段` : '正在准备文件';
    }
    if (this.fileTransferStage === 'transferring') {
      return this.fileTransferAutomatic && this.fileTransferIndex > 0 ?
        `自动队列正在发送第 ${this.fileTransferIndex} 段` : '正在传输';
    }
    if (this.fileTransferStage === 'saving') {
      return '传输完成，正在安全保存';
    }
    if (this.fileTransferStage === 'waiting_ack') {
      return this.fileTransferAutomatic && this.fileTransferIndex > 0 ?
        `自动队列第 ${this.fileTransferIndex} 段已保存，正在确认` : '手机已保存，正在确认回执';
    }
    return this.syncProgressMessage.length > 0 ? this.syncProgressMessage : '正在等待手表响应';
  }

  @Builder
  private syncTransferProgressView() {
    if (this.isSyncing || this.fileTransferActive) {
      Column({ space: 7 }) {
        Row({ space: 8 }) {
          Text(this.transferStageLabel())
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          Text(`${this.fileTransferPercent}%`)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.brand_primary'))
        }
        .width('100%')

        Progress({ value: this.fileTransferPercent, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(6)
          .color($r('app.color.brand_primary'))
          .backgroundColor($r('app.color.surface_secondary'))

        if (this.fileTransferName.length > 0) {
          Text(`${this.fileTransferName}${this.fileTransferSize > 0 ?
            ` · ${this.formatSize(this.fileTransferredBytes)} / ${this.formatSize(this.fileTransferSize)}` : ''}`)
            .width('100%')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor($r('app.color.surface_progress'))
      .borderRadius(10)
    }
  }

  private async sendLatestRecording(): Promise<void> {
    if (this.transferSender === undefined || this.latestRecording === undefined || this.isSending) {
      return;
    }
    const recording = this.latestRecording;
    this.isSending = true;
    this.status = '正在发送到手机，手表原文件会保留…';
    try {
      await this.transferSender.send(recording);
      this.status = '发送完成，手表原文件已保留';
    } catch (error) {
      this.status = `发送失败，原文件已保留：${wearEngineErrorMessage(error)}`;
    } finally {
      this.isSending = false;
    }
  }

  private async startRecordingSession(): Promise<void> {
    if (this.recordingService === undefined) {
      throw new Error('手表录音服务尚未就绪');
    }
    if (this.isRecording) {
      return;
    }
    const granted = await this.requestMicrophonePermission();
    if (!granted) {
      throw new Error('需要在手表上允许麦克风权限');
    }
    await this.playbackService?.release();
    this.isPlaying = false;
    this.latestRecording = undefined;
    this.completedSegments = 0;
    this.activeSegmentIndex = 0;
    this.hardwareOverflowCount = 0;
    await this.recordingService.start();
    this.isRecording = true;
    this.elapsedSeconds = 0;
    this.recordingStartedAt = this.recordingService.getStartedAt();
    this.status = 'AudioCapturer 持续运行，可以熄屏';
    this.startTimer();
  }

  private async stopRecordingSession(): Promise<void> {
    if (this.recordingService === undefined) {
      throw new Error('手表录音服务尚未就绪');
    }
    if (!this.isRecording) {
      return;
    }
    try {
      const finalRecording = await this.recordingService.stop();
      if (finalRecording !== undefined) {
        this.latestRecording = finalRecording;
      }
      this.completedSegments = this.recordingService.getCompletedCount();
      this.hardwareOverflowCount = this.recordingService.getHardwareOverflowCount();
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
        const message = this.errorMessage(error);
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
      await this.recordingStartFallback?.clearPending();
      await this.stopRecordingSession();
      return {
        actualState: 'stopped',
        sessionId: this.recordingService?.getStartedAt().toString() || requestId,
        message: '手表录音已停止，最后分片已封口'
      };
    }
    throw new Error('不支持的录音目标状态');
  }

  private async resumePendingPhoneRecordingStart(): Promise<void> {
    if (this.pendingForegroundStartInProgress || this.recordingStartFallback === undefined) {
      return;
    }
    this.pendingForegroundStartInProgress = true;
    let pending: PendingWatchRecordingStart | undefined = undefined;
    try {
      pending = await this.recordingStartFallback.takePending();
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
        await this.transferSender?.reportRecordingControlResult(pending.requestId, 'recording', true, result);
      } catch (error) {
        this.status = `录音已开始，手机最终回执待重连：${wearEngineErrorMessage(error)}`;
      }
    } catch (error) {
      const message = this.errorMessage(error);
      this.status = `通知启动录音失败：${message}`;
      if (pending !== undefined) {
        try {
          await this.transferSender?.reportRecordingControlResult(pending.requestId, 'recording', false, {
            actualState: 'stopped',
            sessionId: '',
            message: message
          });
        } catch (reportError) {
          // The watch status remains visible even if the phone has disconnected.
        }
      }
    } finally {
      this.pendingForegroundStartInProgress = false;
    }
  }

  private async ensureWatchNotificationEnabled(): Promise<void> {
    if (this.notificationPermissionCheckInProgress || this.recordingStartFallback === undefined) {
      return;
    }
    this.notificationPermissionCheckInProgress = true;
    try {
      const enabled = await this.recordingStartFallback.isNotificationEnabled();
      this.notificationEnabled = enabled;
      if (enabled || this.notificationPermissionRequested) {
        return;
      }
      this.notificationPermissionRequested = true;
      this.status = '请允许通知，用于接收手机录音请求';
      this.notificationEnabled = await this.recordingStartFallback.requestNotificationAuthorization();
      this.status = this.notificationEnabled ? '通知已开启，可以接收手机录音请求' :
        '通知未开启，请点击“开启通知”';
    } catch (error) {
      this.notificationEnabled = false;
      this.status = `通知检查失败：${this.errorMessage(error)}`;
    } finally {
      this.notificationPermissionCheckInProgress = false;
    }
  }

  private async openWatchNotificationSettings(): Promise<void> {
    if (this.recordingStartFallback === undefined || this.notificationPermissionCheckInProgress) {
      return;
    }
    this.notificationPermissionCheckInProgress = true;
    this.status = '正在打开通知设置…';
    try {
      this.notificationEnabled = await this.recordingStartFallback.openNotificationSettings();
      this.status = this.notificationEnabled ? '通知已开启，可以接收手机录音请求' :
        '通知仍未开启，请在系统窗口中允许';
    } catch (error) {
      this.notificationEnabled = false;
      this.status = `无法打开通知设置：${this.errorMessage(error)}`;
    } finally {
      this.notificationPermissionCheckInProgress = false;
    }
  }

  private async toggleRecording(): Promise<void> {
    try {
      if (this.isRecording) {
        await this.stopRecordingSession();
      } else {
        await this.startRecordingSession();
      }
    } catch (error) {
      this.status = `${this.isRecording ? '停止录音' : '录音'}失败：${this.errorMessage(error)}`;
    }
  }

  private async togglePlayback(): Promise<void> {
    if (this.playbackService === undefined) {
      return;
    }
    if (this.isPlaying) {
      await this.playbackService.release();
      this.isPlaying = false;
      this.status = '播放已停止';
      return;
    }
    if (this.latestRecording === undefined) {
      return;
    }
    try {
      await this.playbackService.play(this.latestRecording.path);
    } catch (error) {
      this.status = `播放失败：${this.errorMessage(error)}`;
    }
  }

  private async requestMicrophonePermission(): Promise<boolean> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
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

  private stopTimer(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private startTimer(): void {
    this.stopTimer();
    this.timerId = setInterval(() => {
      this.elapsedSeconds = Math.max(0, Math.floor((Date.now() - this.recordingStartedAt) / 1000));
    }, 1000);
  }

  private errorMessage(error: Object): string {
    return error instanceof Error ? error.message : JSON.stringify(error);
  }

  private formatDuration(durationMs: number): string {
    const seconds = Math.max(0, Math.floor(durationMs / 1000));
    const minutesPart = Math.floor(seconds / 60).toString().padStart(2, '0');
    const secondsPart = (seconds % 60).toString().padStart(2, '0');
    return `${minutesPart}:${secondsPart}`;
  }

  private formatSize(size: number): string {
    if (size < 1024) {
      return `${size} B`;
    }
    if (size < 1024 * 1024) {
      return `${(size / 1024).toFixed(1)} KB`;
    }
    return `${(size / 1024 / 1024).toFixed(1)} MB`;
  }

  private remoteStateLabel(): string {
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

  private userStatusMessage(): string {
    if (this.isWearable) {
      if (!this.notificationEnabled) {
        return '开启通知后，可接收手机发来的录音请求';
      }
      if (this.status.includes('失败') || this.status.includes('无法') || this.status.includes('错误')) {
        return '操作没有完成，请重试或在开发者界面查看详情';
      }
      return this.isRecording ? '熄屏后仍会继续录音' : '录音只保存在你的设备中';
    }
    if (this.status.includes('失败') || this.status.includes('无法') || this.status.includes('错误')) {
      return '操作没有完成，请确认手机与手表已连接后重试';
    }
    if (this.remoteRecordingState === 'pending_user_action') {
      return '请在手表上点击录音通知';
    }
    return '保持手机与手表连接，可自动接收新录音';
  }

  private formatReceivedAt(timestamp: number): string {
    const date = new Date(timestamp);
    const month = (date.getMonth() + 1).toString().padStart(2, '0');
    const day = date.getDate().toString().padStart(2, '0');
    const hour = date.getHours().toString().padStart(2, '0');
    const minute = date.getMinutes().toString().padStart(2, '0');
    return `${month}月${day}日 ${hour}:${minute}`;
  }

  private bottomTabBar(label: Resource, symbol: Resource): BottomTabBarStyle {
    const normal = new SymbolGlyphModifier(symbol)
      .fontColor([$r('app.color.text_secondary')]);
    const selected = new SymbolGlyphModifier(symbol)
      .fontColor([$r('app.color.brand_primary')]);
    return new BottomTabBarStyle({ normal: normal, selected: selected }, label)
      .labelStyle({
        selectedColor: $r('app.color.brand_primary'),
        unselectedColor: $r('app.color.text_secondary')
      });
  }

  @Builder
  private developerView() {
    Column({ space: 6 }) {
      if (!this.isWearable) {
        Column({ space: 12 }) {
          Text('手表录音与文件同步')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))

          Text(`手机可拉起手表 · 当前状态：${this.remoteRecordingState === 'recording' ? '录音中' :
            this.remoteRecordingState === 'stopped' ? '已停止' :
              this.remoteRecordingState === 'pending_user_action' ? '等待手表点击通知' : '待确认'}`)
            .fontSize(14)
            .fontColor($r('app.color.text_tertiary'))

          Row({ space: 10 }) {
            Button(this.isControllingWatch ? '控制中…' : '启动手表录音', { type: ButtonType.Capsule })
              .layoutWeight(1)
              .height(44)
              .backgroundColor($r('app.color.button_success'))
              .enabled(!this.isControllingWatch && this.remoteRecordingState !== 'recording')
              .onClick(() => this.requestWatchRecordingState('recording'))

            Button('停止手表录音', { type: ButtonType.Capsule })
              .layoutWeight(1)
              .height(44)
              .backgroundColor($r('app.color.brand_danger'))
              .enabled(!this.isControllingWatch)
              .onClick(() => this.requestWatchRecordingState('stopped'))
          }
          .width('100%')

          Button(this.developerSyncButtonLabel(), { type: ButtonType.Capsule })
            .width('100%')
            .height(48)
            .backgroundColor($r('app.color.brand_primary'))
            .enabled(!this.isSyncing)
            .onClick(() => this.requestWatchSync())

          this.syncTransferProgressView()

          Row({ space: 10 }) {
            if (this.latestRecording !== undefined) {
              Button(this.isPlaying ? '停止播放' : '试听选中文件', { type: ButtonType.Capsule })
                .layoutWeight(1)
                .height(40)
                .backgroundColor(this.isPlaying ?
                  $r('app.color.brand_danger') : $r('app.color.button_neutral'))
                .onClick(() => this.togglePlayback())
            }

            Button('重新连接', { type: ButtonType.Capsule })
              .layoutWeight(1)
              .height(40)
              .fontColor($r('app.color.brand_primary'))
              .backgroundColor($r('app.color.surface_accent'))
              .onClick(() => this.reconnectPhoneReceiver())
          }
          .width('100%')

          Text(`手机已保存 ${this.receivedRecordingCount} 个文件` +
            `${this.syncScannedTotal > 0 ? ` · 手表扫描 ${this.syncScannedTotal} 个` : ''}` +
            `${this.syncSkipped > 0 ? ` · 无效 ${this.syncSkipped}` : ''}`)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))

          if (this.receivedRecordings.length === 0) {
            Text('文件保存在手机应用私有目录 synced_from_watch；保持本页打开可自动接收')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
          } else {
            List({ space: 8 }) {
              ForEach(this.receivedRecordings, (recording: ReceivedRecordingFile) => {
                ListItem() {
                  Column({ space: 4 }) {
                    Text(recording.fileName)
                      .width('100%')
                      .fontSize(15)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })

                    Text(`${this.formatSize(recording.size)} · ${recording.sourcePath}`)
                      .width('100%')
                      .fontSize(12)
                      .fontColor($r('app.color.text_secondary'))
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .width('100%')
                  .padding(12)
                  .alignItems(HorizontalAlign.Start)
                  .backgroundColor(this.latestRecording?.path === recording.path ?
                    $r('app.color.surface_accent') : $r('app.color.surface_primary'))
                  .borderRadius(12)
                }
                .onClick(() => {
                  this.latestRecording = recording;
                  this.status = `已选择 ${recording.fileName}，可以试听`;
                })
              }, (recording: ReceivedRecordingFile) => recording.path)
            }
            .width('100%')
            .layoutWeight(1)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      } else if (this.isRecording) {
        Text('连续 PCM 采集中')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        Text(this.formatDuration(this.elapsedSeconds * 1000))
          .fontSize(30)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.brand_danger'))

        Text(`第 ${this.activeSegmentIndex} 段 · 已封口 ${this.completedSegments} 段 · 自动同步`)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))

        Button('停止测试', { type: ButtonType.Capsule })
          .width(128)
          .height(44)
          .backgroundColor($r('app.color.brand_danger'))
          .onClick(() => this.toggleRecording())
      } else if (this.latestRecording === undefined) {
        Text('PCM 无缝分段测试')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        Text('16 kHz · 单声道 · 1 分钟 WAV')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))

        Button('开始 PCM 测试', { type: ButtonType.Capsule })
          .width(128)
          .height(44)
          .backgroundColor($r('app.color.brand_primary'))
          .onClick(() => this.toggleRecording())

      } else {
        Text(this.isPlaying ? '正在试听末段' : 'PCM 测试完成')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        Text(`共 ${this.completedSegments} 段 · 溢出 ${this.hardwareOverflowCount}`)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))

        Button(this.isSending ? '正在发送…' : '发送到手机', { type: ButtonType.Capsule })
          .width(128)
          .height(42)
          .backgroundColor($r('app.color.brand_primary'))
          .enabled(!this.isSending)
          .onClick(() => this.sendLatestRecording())

        Row({ space: 8 }) {
          Button(this.isPlaying ? '停止' : '试听', { type: ButtonType.Capsule })
            .width(72)
            .height(30)
            .fontSize(13)
            .fontColor($r('app.color.brand_primary'))
            .backgroundColor($r('app.color.surface_accent'))
            .onClick(() => this.togglePlayback())

          Button('重录', { type: ButtonType.Capsule })
            .width(72)
            .height(30)
            .fontSize(13)
            .fontColor($r('app.color.brand_primary'))
            .backgroundColor($r('app.color.surface_accent'))
            .onClick(() => {
              this.latestRecording = undefined;
              this.completedSegments = 0;
              this.activeSegmentIndex = 0;
              this.hardwareOverflowCount = 0;
              this.status = '连续采集，按采样点每 1 分钟切 WAV';
            })
        }
      }

      if (this.isWearable && !this.notificationEnabled && !this.isRecording) {
        Button('开启通知', { type: ButtonType.Capsule })
          .width(108)
          .height(30)
          .fontSize(13)
          .fontColor($r('app.color.on_emphasis'))
          .backgroundColor($r('app.color.brand_warning'))
          .onClick(() => this.openWatchNotificationSettings())
      }

      Text(this.status)
        .width(this.isWearable ? 160 : 320)
        .fontSize(this.isWearable ? 10 : 14)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(2)

      if (this.isWearable) {
        Text('上滑返回首页')
          .fontSize(9)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(this.isWearable ? FlexAlign.Center : FlexAlign.Start)
    .padding({ left: 20, right: 20, top: 28, bottom: 28 })
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  private phoneHome() {
    Column({ space: 18 }) {
      Column({ space: 4 }) {
        Text('全天录音')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        Text('从手机控制手表，录音自动安全保存')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: 14 }) {
        Row() {
          Text('手表状态')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)

          Text(this.remoteStateLabel())
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.remoteRecordingState === 'recording' ?
              $r('app.color.brand_success') : $r('app.color.text_primary'))
        }
        .width('100%')

        Button(this.isControllingWatch ? '正在等待手表…' :
          this.remoteRecordingState === 'recording' ? '停止并保存' : '开始录音',
        { type: ButtonType.Capsule })
          .width('100%')
          .height(52)
          .fontSize(17)
          .fontColor($r('app.color.on_emphasis'))
          .backgroundColor(this.remoteRecordingState === 'recording' ?
            $r('app.color.brand_danger') : $r('app.color.brand_primary'))
          .enabled(!this.isControllingWatch)
          .onClick(() => this.requestWatchRecordingState(
            this.remoteRecordingState === 'recording' ? 'stopped' : 'recording'))

        Text(this.userStatusMessage())
          .width('100%')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
          .maxLines(2)
      }
      .width('100%')
      .padding(18)
      .backgroundColor($r('app.color.surface_primary'))
      .borderRadius(18)

      Column({ space: 8 }) {
        Text('录音记录')
          .width('100%')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))

        Text(this.receivedRecordingCount > 0 ?
          `手机已保存 ${this.receivedRecordingCount} 个录音，可在“录音记录”中同步和试听。` :
          '完成录音后，可在“录音记录”中同步到手机。')
          .width('100%')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.surface_primary'))
      .borderRadius(14)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 24, bottom: 92 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  private phoneRecordingHistory() {
    Column({ space: 16 }) {
      Column({ space: 4 }) {
        Text('录音记录')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        Text('同步并试听已经保存到手机的录音')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Row() {
        Text(`我的录音  ${this.receivedRecordingCount}`)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Button(this.syncButtonLabel(), { type: ButtonType.Capsule })
          .height(36)
          .fontSize(14)
          .fontColor($r('app.color.brand_primary'))
          .backgroundColor($r('app.color.surface_accent'))
          .enabled(!this.isSyncing)
          .onClick(() => this.requestWatchSync())
      }
      .width('100%')

      this.syncTransferProgressView()

      if (this.receivedRecordings.length === 0) {
        Column({ space: 8 }) {
          Text('还没有录音')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))

          Text('完成手表录音后，点击“同步录音”即可在这里试听')
            .width('100%')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.receivedRecordings, (recording: ReceivedRecordingFile) => {
            ListItem() {
              Row({ space: 12 }) {
                Column({ space: 5 }) {
                  Text(this.formatReceivedAt(recording.receivedAt))
                    .width('100%')
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))

                  Text(`${this.formatDuration(recording.durationMs)} · ${this.formatSize(recording.size)}`)
                    .width('100%')
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Text(this.latestRecording?.path === recording.path ? '已选择' : '选择')
                  .fontSize(13)
                  .fontColor($r('app.color.brand_primary'))
              }
              .width('100%')
              .padding(15)
              .backgroundColor(this.latestRecording?.path === recording.path ?
                $r('app.color.surface_accent') : $r('app.color.surface_primary'))
              .borderRadius(14)
            }
            .onClick(() => {
              this.latestRecording = recording;
            })
          }, (recording: ReceivedRecordingFile) => recording.path)
        }
        .width('100%')
        .layoutWeight(1)

        Button(this.isPlaying ? '停止播放' : '播放选中的录音', { type: ButtonType.Capsule })
          .width('100%')
          .height(46)
          .fontSize(16)
          .backgroundColor(this.isPlaying ?
            $r('app.color.brand_danger') : $r('app.color.button_neutral'))
          .enabled(this.latestRecording !== undefined)
          .onClick(() => this.togglePlayback())
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 24, bottom: 92 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  private watchHome() {
    Column({ space: 7 }) {
      Text('全天录音')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))

      if (this.isRecording) {
        Text('正在录音')
          .fontSize(12)
          .fontColor($r('app.color.brand_danger'))

        Text(this.formatDuration(this.elapsedSeconds * 1000))
          .fontSize(30)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))

        Text(`已安全保存 ${this.completedSegments} 段`)
          .fontSize(10)
          .fontColor($r('app.color.text_secondary'))

        Button('停止并保存', { type: ButtonType.Capsule })
          .width(132)
          .height(44)
          .fontSize(15)
          .backgroundColor($r('app.color.brand_danger'))
          .onClick(() => this.toggleRecording())
      } else if (this.latestRecording === undefined) {
        Text('需要时轻点开始\n熄屏后也会继续记录')
          .width(158)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)

        Button('开始录音', { type: ButtonType.Capsule })
          .width(132)
          .height(46)
          .fontSize(16)
          .backgroundColor($r('app.color.brand_primary'))
          .onClick(() => this.toggleRecording())
      } else {
        Text(this.isPlaying ? '正在播放' : '录音已保存')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isPlaying ? $r('app.color.brand_primary') : $r('app.color.brand_success'))

        Text(this.formatDuration(this.elapsedSeconds * 1000))
          .fontSize(24)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))

        Button(this.isSending ? '正在发送…' : '发送到手机', { type: ButtonType.Capsule })
          .width(132)
          .height(40)
          .fontSize(14)
          .backgroundColor($r('app.color.brand_primary'))
          .enabled(!this.isSending)
          .onClick(() => this.sendLatestRecording())

        Row({ space: 8 }) {
          Button(this.isPlaying ? '停止' : '试听', { type: ButtonType.Capsule })
            .width(68)
            .height(28)
            .fontSize(12)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.surface_secondary'))
            .onClick(() => this.togglePlayback())

          Button('再次录音', { type: ButtonType.Capsule })
            .width(82)
            .height(28)
            .fontSize(12)
            .fontColor($r('app.color.brand_primary'))
            .backgroundColor($r('app.color.surface_accent'))
            .onClick(() => this.toggleRecording())
        }
      }

      Text(this.userStatusMessage())
        .width(158)
        .fontSize(9)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(2)

      if (!this.notificationEnabled && !this.isRecording) {
        Button('开启通知', { type: ButtonType.Capsule })
          .width(92)
          .height(28)
          .fontSize(12)
          .fontColor($r('app.color.on_emphasis'))
          .backgroundColor($r('app.color.brand_warning'))
          .onClick(() => this.openWatchNotificationSettings())
      }

      Text('下滑进入开发者界面')
        .fontSize(9)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 18, right: 18, top: 22, bottom: 22 })
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  private phoneSettings() {
    Column({ space: 16 }) {
      Text('应用设置')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))

      Column({ space: 6 }) {
        Text('录音与存储')
          .width('100%')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))

        Text('手表录音按固定时长安全分段，并自动保留原文件。同步到手机后可直接试听。')
          .width('100%')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.surface_primary'))
      .borderRadius(14)

      Button('开发者界面', { type: ButtonType.Capsule })
        .width('100%')
        .height(48)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.surface_secondary'))
        .onClick(() => {
          this.phoneNavStack.pushPath({
            name: PHONE_DEVELOPER_ROUTE,
            param: new PhoneDeveloperRouteParams()
          });
        })

      Text('包含连接状态、分段计数、溢出统计和原始诊断信息')
        .width('100%')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(2)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .padding({ left: 20, right: 20, top: 24, bottom: 92 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  private phoneDestination(name: string, param: Object) {
    if (name === PHONE_DEVELOPER_ROUTE) {
      NavDestination() {
        this.developerView();
      }
      .title('开发者界面')
      .backgroundColor($r('app.color.page_background'))
    }
  }

  @Builder
  private phoneShell() {
    if (deviceInfo.apiAvailable('26.0.0')) {
      Tabs({ barPosition: BarPosition.End, controller: this.tabsController, index: this.selectedTab }) {
        TabContent() {
          this.phoneHome();
        }
        .tabBar(this.bottomTabBar($r('app.string.tab_home'), $r('sys.symbol.house_fill')))

        TabContent() {
          this.phoneRecordingHistory();
        }
        .tabBar(this.bottomTabBar($r('app.string.tab_recordings'), $r('sys.symbol.waveform')))

        TabContent() {
          this.phoneSettings();
        }
        .tabBar(this.bottomTabBar($r('app.string.tab_settings'), $r('sys.symbol.gearshape')))
      }
      .barHeight(64)
      .onChange((index: number) => {
        this.selectedTab = index;
      })
      .barOverlap(true)
      .vertical(false)
      .barMode(BarMode.Fixed)
      .barFloatingStyle({
        barBottomMargin: 14,
        maskColor: $r('app.color.page_background'),
        systemMaterial: new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.THIN,
          colorInvert: true,
          interactive: true,
          lightEffect: { color: undefined }
        })
      })
      .width('100%')
      .height('100%')
    } else {
      Tabs({ barPosition: BarPosition.End, controller: this.tabsController, index: this.selectedTab }) {
        TabContent() {
          this.phoneHome();
        }
        .tabBar(this.bottomTabBar($r('app.string.tab_home'), $r('sys.symbol.house_fill')))

        TabContent() {
          this.phoneRecordingHistory();
        }
        .tabBar(this.bottomTabBar($r('app.string.tab_recordings'), $r('sys.symbol.waveform')))

        TabContent() {
          this.phoneSettings();
        }
        .tabBar(this.bottomTabBar($r('app.string.tab_settings'), $r('sys.symbol.gearshape')))
      }
      .barHeight(64)
      .onChange((index: number) => {
        this.selectedTab = index;
      })
      .barOverlap(true)
      .vertical(false)
      .barMode(BarMode.Fixed)
      .barBackgroundColor(Color.Transparent)
      .barBackgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .width('100%')
      .height('100%')
    }
  }

  @Builder
  private watchShell() {
    Swiper(this.watchSwiperController) {
      this.developerView();
      this.watchHome();
    }
    .index(this.watchPageIndex)
    .indicator(false)
    .loop(false)
    .vertical(true)
    .onChange((index: number) => {
      this.watchPageIndex = index;
    })
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  build() {
    if (this.isWearable) {
      this.watchShell();
    } else {
      Navigation(this.phoneNavStack) {
        this.phoneShell();
      }
      .hideTitleBar(true)
      .navDestination(this.phoneDestination)
      .mode(NavigationMode.Stack)
      .width('100%')
      .height('100%')
    }
  }
}
