import { common, wantAgent } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { fileIo } from '@kit.CoreFileKit';
import { RecordingFile } from '../models/RecordingModels';

const SAMPLE_RATE: number = 16000;
const CHANNEL_COUNT: number = 1;
const BITS_PER_SAMPLE: number = 16;
const BYTES_PER_SAMPLE: number = BITS_PER_SAMPLE / 8;
const SEGMENT_SECONDS: number = 60;
const SEGMENT_SAMPLES: number = SAMPLE_RATE * SEGMENT_SECONDS;
const SEGMENT_PCM_BYTES: number = SEGMENT_SAMPLES * BYTES_PER_SAMPLE;
const WAV_HEADER_BYTES: number = 44;
const MAX_QUEUED_PCM_BYTES: number = SAMPLE_RATE * BYTES_PER_SAMPLE * 5;

export interface PcmSegmentedRecordingCallbacks {
  onSegmentStarted: (segmentIndex: number, firstSample: number) => void;
  onSegmentCompleted: (recording: RecordingFile, completedCount: number,
    firstSample: number, sampleCount: number) => void;
  onSessionError: (message: string) => void;
}

interface WavFileSlot {
  index: number;
  firstSample: number;
  pcmBytes: number;
  fd: number;
  partPath: string;
  finalPath: string;
}

interface PcmSegmentEvidence {
  index: number;
  fileName: string;
  firstSample: number;
  sampleCount: number;
  pcmBytes: number;
}

interface PcmSessionSummary {
  format: string;
  sessionStartedAt: number;
  sampleRate: number;
  channels: number;
  bitsPerSample: number;
  segmentSamples: number;
  totalSamples: number;
  completedSegments: number;
  continuityValid: boolean;
  hardwareOverflowCount: number;
  softwareQueueOverflowCount: number;
  capturerFramePosition: number;
  capturerBufferSizeBytes: number;
  segments: Array<PcmSegmentEvidence>;
}

export class PcmSegmentedRecordingService {
  private context: common.UIAbilityContext;
  private callbacks: PcmSegmentedRecordingCallbacks;
  private capturer: audio.AudioCapturer | undefined = undefined;
  private readDataHandler: (buffer: ArrayBuffer) => void;
  private activeSlot: WavFileSlot | undefined = undefined;
  private standbySlot: WavFileSlot | undefined = undefined;
  private queuedBuffers: Array<ArrayBuffer> = [];
  private queuedPcmBytes: number = 0;
  private drainScheduled: boolean = false;
  private drainInProgress: boolean = false;
  private drainWaiters: Array<() => void> = [];
  private acceptingData: boolean = false;
  private sessionActive: boolean = false;
  private stopping: boolean = false;
  private abortScheduled: boolean = false;
  private backgroundTaskActive: boolean = false;
  private failureMessage: string = '';
  private sessionStartedAt: number = 0;
  private sessionDirectory: string = '';
  private nextSegmentIndex: number = 1;
  private completedCount: number = 0;
  private totalPcmBytes: number = 0;
  private lastCompleted: RecordingFile | undefined = undefined;
  private evidence: Array<PcmSegmentEvidence> = [];
  private hardwareOverflowCount: number = 0;
  private softwareQueueOverflowCount: number = 0;
  private capturerFramePosition: number = -1;
  private capturerBufferSizeBytes: number = 0;

  constructor(context: common.UIAbilityContext, callbacks: PcmSegmentedRecordingCallbacks) {
    this.context = context;
    this.callbacks = callbacks;
    this.readDataHandler = (buffer: ArrayBuffer): void => {
      this.enqueueCapturedBuffer(buffer);
    };
  }

  async start(): Promise<void> {
    if (this.sessionActive || this.capturer !== undefined) {
      throw new Error('连续 PCM 录音已经开始');
    }
    if (!canIUse('SystemCapability.Multimedia.Audio.Capturer')) {
      throw new Error('当前手表不支持 AudioCapturer');
    }

    this.resetSessionState();
    this.sessionStartedAt = Date.now();
    this.sessionDirectory = `${this.context.filesDir}/pcm_gap_test_${this.sessionStartedAt}`;
    fileIo.mkdirSync(this.sessionDirectory);

    try {
      this.activeSlot = this.createWavSlot(this.nextSegmentIndex, 0);
      this.nextSegmentIndex += 1;
      this.standbySlot = this.createWavSlot(this.nextSegmentIndex, SEGMENT_SAMPLES);
      this.nextSegmentIndex += 1;

      const options: audio.AudioCapturerOptions = {
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        capturerInfo: {
          source: audio.SourceType.SOURCE_TYPE_MIC,
          capturerFlags: 0
        }
      };
      const capturer = await audio.createAudioCapturer(options);
      this.capturer = capturer;
      this.capturerBufferSizeBytes = await capturer.getBufferSize();
      capturer.on('readData', this.readDataHandler);
      this.acceptingData = true;
      this.sessionActive = true;
      await this.startBackgroundRecording();
      await capturer.start();
      this.callbacks.onSegmentStarted(1, 0);
    } catch (error) {
      this.acceptingData = false;
      this.sessionActive = false;
      this.queuedBuffers = [];
      this.queuedPcmBytes = 0;
      await this.releaseCapturerOnly();
      this.discardSlot(this.activeSlot);
      this.discardSlot(this.standbySlot);
      this.activeSlot = undefined;
      this.standbySlot = undefined;
      await this.stopBackgroundRecording();
      throw new Error(`无法启动连续 PCM 录音：${this.businessErrorMessage(error)}`);
    }
  }

  async stop(): Promise<RecordingFile | undefined> {
    if (!this.sessionActive || this.capturer === undefined || this.stopping) {
      throw new Error('当前没有可停止的连续 PCM 会话');
    }
    this.stopping = true;
    const capturer = this.capturer;

    try {
      this.readCapturerDiagnostics(capturer);
      await capturer.stop();
      this.acceptingData = false;
      capturer.off('readData', this.readDataHandler);
      await this.waitForDrain();
      if (this.failureMessage.length > 0) {
        throw new Error(this.failureMessage);
      }

      const active = this.activeSlot;
      this.activeSlot = undefined;
      if (active !== undefined) {
        if (active.pcmBytes > 0) {
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
      await this.releaseCapturerOnly();
      this.closeSlotWithoutRemoving(this.activeSlot);
      this.closeSlotWithoutRemoving(this.standbySlot);
      await this.stopBackgroundRecording();
    }
  }

  async release(): Promise<void> {
    if (this.sessionActive && !this.stopping && this.capturer !== undefined) {
      try {
        await this.stop();
        return;
      } catch (error) {
        // Fall through to best-effort cleanup while retaining .part evidence.
      }
    }
    this.acceptingData = false;
    this.sessionActive = false;
    await this.releaseCapturerOnly();
    this.closeSlotWithoutRemoving(this.activeSlot);
    this.closeSlotWithoutRemoving(this.standbySlot);
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

  getTotalSamples(): number {
    return this.totalPcmBytes / BYTES_PER_SAMPLE;
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
    this.completedCount = 0;
    this.totalPcmBytes = 0;
    this.lastCompleted = undefined;
    this.evidence = [];
    this.hardwareOverflowCount = 0;
    this.softwareQueueOverflowCount = 0;
    this.capturerFramePosition = -1;
    this.capturerBufferSizeBytes = 0;
  }

  private enqueueCapturedBuffer(buffer: ArrayBuffer): void {
    if (!this.acceptingData || this.failureMessage.length > 0 || buffer.byteLength === 0) {
      return;
    }
    if (buffer.byteLength % BYTES_PER_SAMPLE !== 0) {
      this.failSession('AudioCapturer 返回了非完整 S16LE 采样');
      return;
    }
    if (this.queuedPcmBytes + buffer.byteLength > MAX_QUEUED_PCM_BYTES) {
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
    const completedSlots: Array<WavFileSlot> = [];
    while (offset < data.byteLength) {
      const active = this.activeSlot;
      if (active === undefined) {
        throw new Error('没有活动 WAV 文件槽');
      }
      const available = SEGMENT_PCM_BYTES - active.pcmBytes;
      const length = Math.min(available, data.byteLength - offset);
      const piece = data.slice(offset, offset + length);
      this.writeAll(active.fd, piece);
      active.pcmBytes += length;
      this.totalPcmBytes += length;
      offset += length;

      if (active.pcmBytes === SEGMENT_PCM_BYTES) {
        const completed = this.swapToStandbySlot();
        completedSlots.push(completed);
      }
    }

    for (let index = 0; index < completedSlots.length; index += 1) {
      this.publishCompletedSlot(completedSlots[index]);
    }
    this.ensureStandbySlot();
  }

  private swapToStandbySlot(): WavFileSlot {
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
    const firstSample = this.activeSlot.firstSample + SEGMENT_SAMPLES;
    this.standbySlot = this.createWavSlot(this.nextSegmentIndex, firstSample);
    this.nextSegmentIndex += 1;
  }

  private createWavSlot(index: number, firstSample: number): WavFileSlot {
    const indexText = index.toString().padStart(6, '0');
    const sampleText = firstSample.toString().padStart(12, '0');
    const fileName = `segment_${indexText}_first_${sampleText}.wav`;
    const finalPath = `${this.sessionDirectory}/${fileName}`;
    const partPath = `${finalPath}.part`;
    const outputFile = fileIo.openSync(partPath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    const slot: WavFileSlot = {
      index: index,
      firstSample: firstSample,
      pcmBytes: 0,
      fd: outputFile.fd,
      partPath: partPath,
      finalPath: finalPath
    };
    this.writeAll(slot.fd, this.createWavHeader(0));
    return slot;
  }

  private publishCompletedSlot(slot: WavFileSlot): void {
    const recording = this.finalizeSlot(slot);
    const sampleCount = slot.pcmBytes / BYTES_PER_SAMPLE;
    this.completedCount += 1;
    this.lastCompleted = recording;
    const evidence: PcmSegmentEvidence = {
      index: slot.index,
      fileName: recording.fileName,
      firstSample: slot.firstSample,
      sampleCount: sampleCount,
      pcmBytes: slot.pcmBytes
    };
    this.evidence.push(evidence);
    this.callbacks.onSegmentCompleted(recording, this.completedCount, slot.firstSample, sampleCount);
  }

  private finalizeSlot(slot: WavFileSlot): RecordingFile {
    try {
      fileIo.lseek(slot.fd, 0, fileIo.WhenceType.SEEK_SET);
      this.writeAll(slot.fd, this.createWavHeader(slot.pcmBytes));
      fileIo.fsyncSync(slot.fd);
      fileIo.closeSync(slot.fd);
      slot.fd = -1;
      fileIo.renameSync(slot.partPath, slot.finalPath);
      const stat = fileIo.statSync(slot.finalPath);
      const pathParts = slot.finalPath.split('/');
      return {
        fileName: pathParts[pathParts.length - 1],
        path: slot.finalPath,
        size: stat.size,
        durationMs: Math.round(slot.pcmBytes * 1000 / (SAMPLE_RATE * BYTES_PER_SAMPLE))
      };
    } catch (error) {
      this.closeSlotWithoutRemoving(slot);
      throw new Error(`WAV 封口失败：${this.businessErrorMessage(error)}`);
    }
  }

  private discardSlot(slot: WavFileSlot | undefined): void {
    if (slot === undefined) {
      return;
    }
    if (slot.fd >= 0) {
      try {
        fileIo.closeSync(slot.fd);
      } catch (error) {
        // Continue removing the unused placeholder file.
      }
      slot.fd = -1;
    }
    try {
      fileIo.unlinkSync(slot.partPath);
    } catch (error) {
      // The placeholder may already have been finalized or removed.
    }
  }

  private createWavHeader(pcmBytes: number): ArrayBuffer {
    const buffer = new ArrayBuffer(WAV_HEADER_BYTES);
    const header = new Uint8Array(buffer);
    this.writeAscii(header, 0, 'RIFF');
    this.writeUint32Le(header, 4, 36 + pcmBytes);
    this.writeAscii(header, 8, 'WAVE');
    this.writeAscii(header, 12, 'fmt ');
    this.writeUint32Le(header, 16, 16);
    this.writeUint16Le(header, 20, 1);
    this.writeUint16Le(header, 22, CHANNEL_COUNT);
    this.writeUint32Le(header, 24, SAMPLE_RATE);
    this.writeUint32Le(header, 28, SAMPLE_RATE * CHANNEL_COUNT * BYTES_PER_SAMPLE);
    this.writeUint16Le(header, 32, CHANNEL_COUNT * BYTES_PER_SAMPLE);
    this.writeUint16Le(header, 34, BITS_PER_SAMPLE);
    this.writeAscii(header, 36, 'data');
    this.writeUint32Le(header, 40, pcmBytes);
    return buffer;
  }

  private writeAscii(target: Uint8Array, offset: number, value: string): void {
    for (let index = 0; index < value.length; index += 1) {
      target[offset + index] = value.charCodeAt(index);
    }
  }

  private writeUint16Le(target: Uint8Array, offset: number, value: number): void {
    target[offset] = value & 0xff;
    target[offset + 1] = (value >>> 8) & 0xff;
  }

  private writeUint32Le(target: Uint8Array, offset: number, value: number): void {
    target[offset] = value & 0xff;
    target[offset + 1] = (value >>> 8) & 0xff;
    target[offset + 2] = (value >>> 16) & 0xff;
    target[offset + 3] = (value >>> 24) & 0xff;
  }

  private writeAll(fd: number, buffer: ArrayBuffer): void {
    let remaining: ArrayBuffer = buffer;
    while (remaining.byteLength > 0) {
      const written = fileIo.writeSync(fd, remaining);
      if (written <= 0) {
        throw new Error('写入 WAV 文件失败');
      }
      if (written === remaining.byteLength) {
        return;
      }
      remaining = remaining.slice(written);
    }
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
    await this.releaseCapturerOnly();
    this.closeSlotWithoutRemoving(this.activeSlot);
    this.closeSlotWithoutRemoving(this.standbySlot);
    await this.stopBackgroundRecording();
  }

  private closeSlotWithoutRemoving(slot: WavFileSlot | undefined): void {
    if (slot === undefined || slot.fd < 0) {
      return;
    }
    try {
      fileIo.closeSync(slot.fd);
    } catch (error) {
      // Preserve the original failure while leaving .part as crash evidence.
    }
    slot.fd = -1;
  }

  private readCapturerDiagnostics(capturer: audio.AudioCapturer): void {
    try {
      this.hardwareOverflowCount = capturer.getOverflowCountSync();
    } catch (error) {
      this.hardwareOverflowCount = -1;
    }
    try {
      this.capturerFramePosition = capturer.getAudioTimestampInfoSync().framePos;
    } catch (error) {
      this.capturerFramePosition = -1;
    }
  }

  private writeSessionSummary(): void {
    const summary: PcmSessionSummary = {
      format: 'AllDayRecording PCM gap test v1',
      sessionStartedAt: this.sessionStartedAt,
      sampleRate: SAMPLE_RATE,
      channels: CHANNEL_COUNT,
      bitsPerSample: BITS_PER_SAMPLE,
      segmentSamples: SEGMENT_SAMPLES,
      totalSamples: this.getTotalSamples(),
      completedSegments: this.completedCount,
      continuityValid: this.isEvidenceContinuous(),
      hardwareOverflowCount: this.hardwareOverflowCount,
      softwareQueueOverflowCount: this.softwareQueueOverflowCount,
      capturerFramePosition: this.capturerFramePosition,
      capturerBufferSizeBytes: this.capturerBufferSizeBytes,
      segments: this.evidence
    };
    const summaryPath = `${this.sessionDirectory}/session_summary.json`;
    const output = fileIo.openSync(summaryPath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(output.fd, JSON.stringify(summary, null, 2));
      fileIo.fsyncSync(output.fd);
    } finally {
      fileIo.closeSync(output.fd);
    }
  }

  private isEvidenceContinuous(): boolean {
    let expectedFirstSample: number = 0;
    for (let index = 0; index < this.evidence.length; index += 1) {
      const segment = this.evidence[index];
      if (segment.firstSample !== expectedFirstSample) {
        return false;
      }
      expectedFirstSample += segment.sampleCount;
    }
    return expectedFirstSample === this.getTotalSamples() &&
      this.hardwareOverflowCount === 0 && this.softwareQueueOverflowCount === 0;
  }

  private async releaseCapturerOnly(): Promise<void> {
    const capturer = this.capturer;
    this.capturer = undefined;
    if (capturer === undefined) {
      return;
    }
    try {
      capturer.off('readData', this.readDataHandler);
    } catch (error) {
      // Continue releasing a partially initialized capturer.
    }
    try {
      await capturer.stop();
    } catch (error) {
      // The capturer may already be stopped.
    }
    try {
      await capturer.release();
    } catch (error) {
      // Best-effort cleanup after an interrupted capture session.
    }
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
      requestCode: 1002,
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
      // The system may already have canceled the task.
    } finally {
      this.backgroundTaskActive = false;
    }
  }

  private businessErrorMessage(error: Object): string {
    const businessError = error as BusinessError;
    if (businessError.code !== undefined) {
      return `${businessError.message || '连续 PCM 录音失败'}（${businessError.code}）`;
    }
    return error instanceof Error ? error.message : '连续 PCM 录音失败';
  }
}
