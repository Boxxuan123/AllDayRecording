import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { RecordingFile } from '../models/RecordingModels';
import {
  AudioCaptureDiagnostics,
  AudioCaptureLifecycle
} from '../recording/AudioCaptureLifecycle';
import { AudioRecordingBackgroundTask } from '../recording/AudioRecordingBackgroundTask';
import {
  PCM_RECORDING_MAX_QUEUED_BYTES,
  PCM_RECORDING_SEGMENT_BYTES,
  PCM_RECORDING_SEGMENT_SAMPLES,
  PcmSessionMetrics,
  pcmRecordingSessionDirectory
} from '../recording/PcmRecordingContract';
import { PcmSessionSummaryStore } from '../recording/PcmSessionSummaryStore';
import { WavSegmentSlot } from '../recording/WavSegmentSlot';
import { PCM_BYTES_PER_SAMPLE } from '../shared/io/WavFormat';

export interface PcmSegmentedRecordingCallbacks {
  onSegmentStarted: (segmentIndex: number, firstSample: number) => void;
  onSegmentCompleted: (recording: RecordingFile, completedCount: number,
    firstSample: number, sampleCount: number) => void;
  onSessionError: (message: string) => void;
}

export class PcmSegmentedRecordingService {
  private context: common.UIAbilityContext;
  private callbacks: PcmSegmentedRecordingCallbacks;
  private captureLifecycle: AudioCaptureLifecycle;
  private backgroundTask: AudioRecordingBackgroundTask;
  private summaryStore: PcmSessionSummaryStore = new PcmSessionSummaryStore();
  private activeSlot: WavSegmentSlot | undefined = undefined;
  private standbySlot: WavSegmentSlot | undefined = undefined;
  private queuedBuffers: Array<ArrayBuffer> = [];
  private queuedPcmBytes: number = 0;
  private drainScheduled: boolean = false;
  private drainInProgress: boolean = false;
  private drainWaiters: Array<() => void> = [];
  private acceptingData: boolean = false;
  private sessionActive: boolean = false;
  private stopping: boolean = false;
  private abortScheduled: boolean = false;
  private failureMessage: string = '';
  private sessionStartedAt: number = 0;
  private sessionDirectory: string = '';
  private nextSegmentIndex: number = 1;
  private totalPcmBytes: number = 0;
  private lastCompleted: RecordingFile | undefined = undefined;
  private hardwareOverflowCount: number = 0;
  private softwareQueueOverflowCount: number = 0;
  private capturerFramePosition: number = -1;
  private capturerBufferSizeBytes: number = 0;

  constructor(context: common.UIAbilityContext, callbacks: PcmSegmentedRecordingCallbacks) {
    this.context = context;
    this.callbacks = callbacks;
    this.captureLifecycle = new AudioCaptureLifecycle((buffer: ArrayBuffer): void => {
      this.enqueueCapturedBuffer(buffer);
    });
    this.backgroundTask = new AudioRecordingBackgroundTask(context, 1002);
  }

  async start(): Promise<void> {
    if (this.sessionActive || this.captureLifecycle.isPrepared()) {
      throw new Error('连续 PCM 录音已经开始');
    }
    this.captureLifecycle.ensureSupported();

    this.resetSessionState();
    this.sessionStartedAt = Date.now();
    this.sessionDirectory = pcmRecordingSessionDirectory(this.context.filesDir, this.sessionStartedAt);
    fileIo.mkdirSync(this.sessionDirectory);

    try {
      this.activeSlot = this.createWavSlot(this.nextSegmentIndex, 0);
      this.nextSegmentIndex += 1;
      this.standbySlot = this.createWavSlot(this.nextSegmentIndex, PCM_RECORDING_SEGMENT_SAMPLES);
      this.nextSegmentIndex += 1;
      await this.captureLifecycle.prepare();
      this.acceptingData = true;
      this.sessionActive = true;
      await this.backgroundTask.start();
      await this.captureLifecycle.start();
      this.callbacks.onSegmentStarted(1, 0);
    } catch (error) {
      this.acceptingData = false;
      this.sessionActive = false;
      this.queuedBuffers = [];
      this.queuedPcmBytes = 0;
      await this.captureLifecycle.release();
      this.discardSlot(this.activeSlot);
      this.discardSlot(this.standbySlot);
      this.activeSlot = undefined;
      this.standbySlot = undefined;
      await this.backgroundTask.stop();
      throw new Error(`无法启动连续 PCM 录音：${this.businessErrorMessage(error)}`);
    }
  }

  async stop(): Promise<RecordingFile | undefined> {
    if (!this.sessionActive || !this.captureLifecycle.isPrepared() || this.stopping) {
      throw new Error('当前没有可停止的连续 PCM 会话');
    }
    this.stopping = true;

    try {
      this.applyCaptureDiagnostics(this.captureLifecycle.readDiagnostics());
      await this.captureLifecycle.stop();
      this.acceptingData = false;
      this.captureLifecycle.detachReadData();
      await this.waitForDrain();
      if (this.failureMessage.length > 0) {
        throw new Error(this.failureMessage);
      }

      const active = this.activeSlot;
      this.activeSlot = undefined;
      if (active !== undefined) {
        if (active.getPcmBytes() > 0) {
          this.publishCompletedSlot(active);
        } else {
          this.discardSlot(active);
        }
      }
      this.discardSlot(this.standbySlot);
      this.standbySlot = undefined;
      this.writeSessionSummary();
      return this.lastCompleted;
    } finally {
      this.acceptingData = false;
      this.sessionActive = false;
      this.stopping = false;
      await this.captureLifecycle.release();
      this.closeSlotWithoutRemoving(this.activeSlot);
      this.closeSlotWithoutRemoving(this.standbySlot);
      await this.backgroundTask.stop();
    }
  }

  async release(): Promise<void> {
    if (this.sessionActive && !this.stopping && this.captureLifecycle.isPrepared()) {
      try {
        await this.stop();
        return;
      } catch (error) {
        // Fall through to best-effort cleanup while retaining .part evidence.
      }
    }
    this.acceptingData = false;
    this.sessionActive = false;
    await this.captureLifecycle.release();
    this.closeSlotWithoutRemoving(this.activeSlot);
    this.closeSlotWithoutRemoving(this.standbySlot);
    await this.backgroundTask.stop();
  }

  getStartedAt(): number {
    return this.sessionStartedAt;
  }

  getSessionDirectory(): string {
    return this.sessionDirectory;
  }

  getCompletedCount(): number {
    return this.summaryStore.getCompletedCount();
  }

  getTotalSamples(): number {
    return this.totalPcmBytes / PCM_BYTES_PER_SAMPLE;
  }

  getHardwareOverflowCount(): number {
    return this.hardwareOverflowCount;
  }

  private resetSessionState(): void {
    this.queuedBuffers = [];
    this.queuedPcmBytes = 0;
    this.drainScheduled = false;
    this.drainInProgress = false;
    this.drainWaiters = [];
    this.acceptingData = false;
    this.stopping = false;
    this.abortScheduled = false;
    this.failureMessage = '';
    this.nextSegmentIndex = 1;
    this.totalPcmBytes = 0;
    this.lastCompleted = undefined;
    this.summaryStore.reset();
    this.hardwareOverflowCount = 0;
    this.softwareQueueOverflowCount = 0;
    this.capturerFramePosition = -1;
    this.capturerBufferSizeBytes = 0;
  }

  private enqueueCapturedBuffer(buffer: ArrayBuffer): void {
    if (!this.acceptingData || this.failureMessage.length > 0 || buffer.byteLength === 0) {
      return;
    }
    if (buffer.byteLength % PCM_BYTES_PER_SAMPLE !== 0) {
      this.failSession('AudioCapturer 返回了非完整 S16LE 采样');
      return;
    }
    if (this.queuedPcmBytes + buffer.byteLength > PCM_RECORDING_MAX_QUEUED_BYTES) {
      this.softwareQueueOverflowCount += 1;
      this.failSession('PCM 写入队列超过 5 秒，已停止以避免静默丢音频');
      return;
    }

    const copy = new ArrayBuffer(buffer.byteLength);
    new Uint8Array(copy).set(new Uint8Array(buffer));
    this.queuedBuffers.push(copy);
    this.queuedPcmBytes += copy.byteLength;
    this.scheduleDrain();
  }

  private scheduleDrain(): void {
    if (this.drainScheduled || this.drainInProgress) {
      return;
    }
    this.drainScheduled = true;
    setTimeout(() => {
      this.drainScheduled = false;
      this.drainQueuedBuffers();
    }, 0);
  }

  private drainQueuedBuffers(): void {
    if (this.drainInProgress) {
      return;
    }
    this.drainInProgress = true;
    try {
      while (this.queuedBuffers.length > 0 && this.failureMessage.length === 0) {
        const data = this.queuedBuffers.shift();
        if (data === undefined) {
          continue;
        }
        this.queuedPcmBytes -= data.byteLength;
        this.writeCapturedData(data);
      }
    } catch (error) {
      this.failSession(this.businessErrorMessage(error));
    } finally {
      this.drainInProgress = false;
      if (this.queuedBuffers.length > 0 && this.failureMessage.length === 0) {
        this.scheduleDrain();
      } else {
        this.notifyDrainIdle();
      }
    }
  }

  private writeCapturedData(data: ArrayBuffer): void {
    let offset: number = 0;
    const completedSlots: Array<WavSegmentSlot> = [];
    while (offset < data.byteLength) {
      const active = this.activeSlot;
      if (active === undefined) {
        throw new Error('没有活动 WAV 文件槽');
      }
      const available = PCM_RECORDING_SEGMENT_BYTES - active.getPcmBytes();
      const length = Math.min(available, data.byteLength - offset);
      const piece = data.slice(offset, offset + length);
      active.write(piece);
      this.totalPcmBytes += length;
      offset += length;

      if (active.getPcmBytes() === PCM_RECORDING_SEGMENT_BYTES) {
        const completed = this.swapToStandbySlot();
        completedSlots.push(completed);
      }
    }

    for (let index = 0; index < completedSlots.length; index += 1) {
      this.publishCompletedSlot(completedSlots[index]);
    }
    this.ensureStandbySlot();
  }

  private swapToStandbySlot(): WavSegmentSlot {
    const completed = this.activeSlot;
    const next = this.standbySlot;
    if (completed === undefined || next === undefined) {
      throw new Error('WAV 双缓冲文件槽不完整');
    }
    this.activeSlot = next;
    this.standbySlot = undefined;
    this.callbacks.onSegmentStarted(next.index, next.firstSample);
    return completed;
  }

  private ensureStandbySlot(): void {
    if (this.standbySlot !== undefined || this.activeSlot === undefined || !this.sessionActive) {
      return;
    }
    const firstSample = this.activeSlot.firstSample + PCM_RECORDING_SEGMENT_SAMPLES;
    this.standbySlot = this.createWavSlot(this.nextSegmentIndex, firstSample);
    this.nextSegmentIndex += 1;
  }

  private createWavSlot(index: number, firstSample: number): WavSegmentSlot {
    return new WavSegmentSlot(this.sessionDirectory, index, firstSample);
  }

  private publishCompletedSlot(slot: WavSegmentSlot): void {
    const recording = slot.finalize();
    const pcmBytes = slot.getPcmBytes();
    const sampleCount = pcmBytes / PCM_BYTES_PER_SAMPLE;
    this.lastCompleted = recording;
    this.summaryStore.append(recording, slot.index, slot.firstSample, sampleCount, pcmBytes);
    this.callbacks.onSegmentCompleted(recording, this.summaryStore.getCompletedCount(),
      slot.firstSample, sampleCount);
  }

  private discardSlot(slot: WavSegmentSlot | undefined): void {
    if (slot === undefined) {
      return;
    }
    slot.discard();
  }

  private waitForDrain(): Promise<void> {
    if (!this.drainScheduled && !this.drainInProgress && this.queuedBuffers.length === 0) {
      return Promise.resolve();
    }
    return new Promise<void>((resolve: () => void) => {
      this.drainWaiters.push(resolve);
    });
  }

  private notifyDrainIdle(): void {
    if (this.drainScheduled || this.drainInProgress || this.queuedBuffers.length > 0) {
      return;
    }
    while (this.drainWaiters.length > 0) {
      const resolve = this.drainWaiters.shift();
      if (resolve !== undefined) {
        resolve();
      }
    }
  }

  private failSession(message: string): void {
    if (this.failureMessage.length > 0) {
      return;
    }
    this.failureMessage = message;
    this.acceptingData = false;
    this.callbacks.onSessionError(message);
    if (!this.abortScheduled) {
      this.abortScheduled = true;
      setTimeout(() => {
        this.abortAfterFailure();
      }, 0);
    }
  }

  private async abortAfterFailure(): Promise<void> {
    this.sessionActive = false;
    this.queuedBuffers = [];
    this.queuedPcmBytes = 0;
    this.notifyDrainIdle();
    await this.captureLifecycle.release();
    this.closeSlotWithoutRemoving(this.activeSlot);
    this.closeSlotWithoutRemoving(this.standbySlot);
    await this.backgroundTask.stop();
  }

  private closeSlotWithoutRemoving(slot: WavSegmentSlot | undefined): void {
    if (slot === undefined) {
      return;
    }
    slot.closePreservingPart();
  }

  private applyCaptureDiagnostics(diagnostics: AudioCaptureDiagnostics): void {
    this.hardwareOverflowCount = diagnostics.hardwareOverflowCount;
    this.capturerFramePosition = diagnostics.framePosition;
    this.capturerBufferSizeBytes = diagnostics.bufferSizeBytes;
  }

  private writeSessionSummary(): void {
    const metrics: PcmSessionMetrics = {
      sessionStartedAt: this.sessionStartedAt,
      totalSamples: this.getTotalSamples(),
      hardwareOverflowCount: this.hardwareOverflowCount,
      softwareQueueOverflowCount: this.softwareQueueOverflowCount,
      capturerFramePosition: this.capturerFramePosition,
      capturerBufferSizeBytes: this.capturerBufferSizeBytes
    };
    this.summaryStore.write(this.sessionDirectory, metrics);
  }

  private businessErrorMessage(error: Object): string {
    const businessError = error as BusinessError;
    if (businessError.code !== undefined) {
      return `${businessError.message || '连续 PCM 录音失败'}（${businessError.code}）`;
    }
    return error instanceof Error ? error.message : '连续 PCM 录音失败';
  }
}
