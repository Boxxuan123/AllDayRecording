import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { RecordingFile } from '../models/RecordingModels';

export interface SegmentedRecordingCallbacks {
  onSegmentStarted: (segmentIndex: number, startedAt: number) => void;
  onSegmentCompleted: (recording: RecordingFile, completedCount: number) => void;
  onSessionError: (message: string) => void;
}

export class AudioRecordingService {
  private context: common.UIAbilityContext;
  private callbacks: SegmentedRecordingCallbacks;
  private recorder: media.AVRecorder | undefined = undefined;
  private outputFd: number = -1;
  private outputPath: string = '';
  private finalOutputPath: string = '';
  private segmentStartedAt: number = 0;
  private sessionStartedAt: number = 0;
  private sessionDirectory: string = '';
  private segmentDurationMs: number = 5000;
  private nextSegmentIndex: number = 1;
  private completedCount: number = 0;
  private lastCompleted: RecordingFile | undefined = undefined;
  private rotationTimerId: number = -1;
  private rotationPromise: Promise<void> | undefined = undefined;
  private sessionActive: boolean = false;
  private backgroundTaskActive: boolean = false;

  constructor(context: common.UIAbilityContext, callbacks: SegmentedRecordingCallbacks) {
    this.context = context;
    this.callbacks = callbacks;
  }

  async start(segmentDurationMs: number): Promise<void> {
    if (this.sessionActive || this.recorder !== undefined || this.rotationPromise !== undefined) {
      throw new Error('分段录音已经开始');
    }
    if (!canIUse('SystemCapability.Multimedia.Media.AVRecorder')) {
      throw new Error('当前手表不支持 AVRecorder 录音能力');
    }
    if (segmentDurationMs !== 5000 && segmentDurationMs !== 10000) {
      throw new Error('测试分段时长只能是 5 秒或 10 秒');
    }

    this.segmentDurationMs = segmentDurationMs;
    this.sessionStartedAt = Date.now();
    this.sessionDirectory = `${this.context.filesDir}/gap_test_${this.sessionStartedAt}`;
    fileIo.mkdirSync(this.sessionDirectory);
    this.nextSegmentIndex = 1;
    this.completedCount = 0;
    this.lastCompleted = undefined;
    this.sessionActive = true;

    try {
      await this.startNextSegment();
      await this.startBackgroundRecording();
      this.scheduleRotation();
    } catch (error) {
      this.sessionActive = false;
      this.clearRotationTimer();
      await this.releaseRecorderOnly();
      await this.stopBackgroundRecording();
      throw new Error(`无法启动分段录音：${this.businessErrorMessage(error)}`);
    }
  }

  async stop(): Promise<RecordingFile | undefined> {
    if (!this.sessionActive && this.recorder === undefined && this.rotationPromise === undefined) {
      throw new Error('当前没有分段录音会话');
    }

    this.sessionActive = false;
    this.clearRotationTimer();
    const activeRotation = this.rotationPromise;
    if (activeRotation !== undefined) {
      await activeRotation;
    }

    try {
      if (this.recorder !== undefined) {
        const recording = await this.sealCurrentSegment();
        this.publishCompletedSegment(recording);
      }
      return this.lastCompleted;
    } finally {
      await this.stopBackgroundRecording();
    }
  }

  async release(): Promise<void> {
    this.sessionActive = false;
    this.clearRotationTimer();
    const activeRotation = this.rotationPromise;
    if (activeRotation !== undefined) {
      try {
        await activeRotation;
      } catch (error) {
        // Continue releasing the current recorder after an interrupted rotation.
      }
    }
    if (this.recorder !== undefined) {
      try {
        const recording = await this.sealCurrentSegment();
        this.publishCompletedSegment(recording);
      } catch (error) {
        await this.releaseRecorderOnly();
      }
    }
    await this.stopBackgroundRecording();
  }

  getStartedAt(): number {
    return this.sessionStartedAt;
  }

  getSessionDirectory(): string {
    return this.sessionDirectory;
  }

  getCompletedCount(): number {
    return this.completedCount;
  }

  private async startNextSegment(): Promise<void> {
    if (this.recorder !== undefined) {
      throw new Error('上一录音段尚未结束');
    }

    const segmentIndex = this.nextSegmentIndex;
    const requestedAt = Date.now();
    const indexText = segmentIndex.toString().padStart(6, '0');
    const baseName = `segment_${indexText}_start_${requestedAt}.m4a`;
    this.finalOutputPath = `${this.sessionDirectory}/${baseName}`;
    this.outputPath = `${this.finalOutputPath}.part`;
    const outputFile = fileIo.openSync(this.outputPath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    this.outputFd = outputFile.fd;

    let recorder: media.AVRecorder | undefined = undefined;
    let recordingStarted: boolean = false;
    try {
      recorder = await media.createAVRecorder();
      const config: media.AVRecorderConfig = {
        audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC,
        profile: {
          audioBitrate: 64000,
          audioChannels: 1,
          audioCodec: media.CodecMimeType.AUDIO_AAC,
          audioSampleRate: 16000,
          fileFormat: media.ContainerFormatType.CFT_MPEG_4A
        },
        url: `fd://${this.outputFd}`
      };
      await recorder.prepare(config);
      await recorder.start();
      recordingStarted = true;
      this.recorder = recorder;
      this.segmentStartedAt = Date.now();
      this.nextSegmentIndex += 1;
      this.callbacks.onSegmentStarted(segmentIndex, this.segmentStartedAt);
    } catch (error) {
      if (recorder !== undefined) {
        try {
          if (recordingStarted) {
            await recorder.stop();
          }
          await recorder.release();
        } catch (releaseError) {
          // Preserve the original recorder start failure.
        }
      }
      this.recorder = undefined;
      this.closeOutput();
      throw new Error(this.businessErrorMessage(error));
    }
  }

  private async sealCurrentSegment(): Promise<RecordingFile> {
    const recorder = this.recorder;
    if (recorder === undefined) {
      throw new Error('当前没有可封口的录音段');
    }

    const startedAt = this.segmentStartedAt;
    const partPath = this.outputPath;
    const finalPath = this.finalOutputPath;
    let stoppedAt: number = Date.now();
    try {
      await recorder.stop();
      stoppedAt = Date.now();
    } finally {
      try {
        await recorder.release();
      } finally {
        this.recorder = undefined;
        this.closeOutput();
      }
    }

    const partStat = fileIo.statSync(partPath);
    if (partStat.size <= 0) {
      throw new Error('分段录音文件为空');
    }
    fileIo.renameSync(partPath, finalPath);
    const finalStat = fileIo.statSync(finalPath);
    const pathParts = finalPath.split('/');
    return {
      fileName: pathParts[pathParts.length - 1],
      path: finalPath,
      size: finalStat.size,
      durationMs: Math.max(0, stoppedAt - startedAt)
    };
  }

  private publishCompletedSegment(recording: RecordingFile): void {
    this.completedCount += 1;
    this.lastCompleted = recording;
    this.callbacks.onSegmentCompleted(recording, this.completedCount);
  }

  private scheduleRotation(): void {
    this.clearRotationTimer();
    if (!this.sessionActive || this.recorder === undefined) {
      return;
    }
    const targetTime = this.segmentStartedAt + this.segmentDurationMs;
    const delayMs = Math.max(0, targetTime - Date.now());
    this.rotationTimerId = setTimeout(() => {
      this.rotationTimerId = -1;
      const rotation = this.rotateSegment().catch(async (error: Object) => {
        await this.handleRotationFailure(error);
      });
      this.rotationPromise = rotation;
      rotation.then(() => {
        if (this.rotationPromise === rotation) {
          this.rotationPromise = undefined;
        }
      });
    }, delayMs);
  }

  private async rotateSegment(): Promise<void> {
    if (!this.sessionActive || this.recorder === undefined) {
      return;
    }
    const completed = await this.sealCurrentSegment();
    this.publishCompletedSegment(completed);
    if (!this.sessionActive) {
      return;
    }
    await this.startNextSegment();
    if (this.sessionActive) {
      this.scheduleRotation();
    }
  }

  private async handleRotationFailure(error: Object): Promise<void> {
    this.sessionActive = false;
    this.clearRotationTimer();
    await this.releaseRecorderOnly();
    await this.stopBackgroundRecording();
    this.callbacks.onSessionError(this.businessErrorMessage(error));
  }

  private clearRotationTimer(): void {
    if (this.rotationTimerId >= 0) {
      clearTimeout(this.rotationTimerId);
      this.rotationTimerId = -1;
    }
  }

  private async releaseRecorderOnly(): Promise<void> {
    const recorder = this.recorder;
    this.recorder = undefined;
    if (recorder !== undefined) {
      try {
        await recorder.stop();
      } catch (error) {
        // The recorder may not have reached the started state.
      }
      try {
        await recorder.release();
      } catch (error) {
        // Continue closing the output descriptor.
      }
    }
    this.closeOutput();
  }

  private async startBackgroundRecording(): Promise<void> {
    if (!canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
      throw new Error('当前手表不支持录音持续任务');
    }
    const notificationWantAgent = await wantAgent.getWantAgent({
      wants: [{
        bundleName: this.context.applicationInfo.name,
        abilityName: 'EntryAbility'
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 1001,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    await backgroundTaskManager.startBackgroundRunning(
      this.context,
      backgroundTaskManager.BackgroundMode.AUDIO_RECORDING,
      notificationWantAgent
    );
    this.backgroundTaskActive = true;
  }

  private async stopBackgroundRecording(): Promise<void> {
    if (!this.backgroundTaskActive) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
    } catch (error) {
      // The system may already have canceled the task after recording stopped.
    } finally {
      this.backgroundTaskActive = false;
    }
  }

  private businessErrorMessage(error: Object): string {
    const businessError = error as BusinessError;
    if (businessError.code !== undefined) {
      return `${businessError.message || '分段录音失败'}（${businessError.code}）`;
    }
    return error instanceof Error ? error.message : '分段录音失败';
  }

  private closeOutput(): void {
    if (this.outputFd >= 0) {
      fileIo.closeSync(this.outputFd);
      this.outputFd = -1;
    }
  }
}
