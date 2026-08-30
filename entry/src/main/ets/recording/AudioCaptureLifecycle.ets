import { audio } from '@kit.AudioKit';

export interface AudioCaptureDiagnostics {
  hardwareOverflowCount: number;
  framePosition: number;
  bufferSizeBytes: number;
}

export class AudioCaptureLifecycle {
  private capturer: audio.AudioCapturer | undefined = undefined;
  private readDataHandler: (buffer: ArrayBuffer) => void;
  private bufferSizeBytes: number = 0;

  constructor(readDataHandler: (buffer: ArrayBuffer) => void) {
    this.readDataHandler = readDataHandler;
  }

  isPrepared(): boolean {
    return this.capturer !== undefined;
  }

  ensureSupported(): void {
    if (!canIUse('SystemCapability.Multimedia.Audio.Capturer')) {
      throw new Error('当前手表不支持 AudioCapturer');
    }
  }

  async prepare(): Promise<void> {
    if (this.capturer !== undefined) {
      throw new Error('AudioCapturer 已经创建');
    }
    this.ensureSupported();
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
    try {
      const capturer = await audio.createAudioCapturer(options);
      this.capturer = capturer;
      this.bufferSizeBytes = await capturer.getBufferSize();
      capturer.on('readData', this.readDataHandler);
    } catch (error) {
      throw captureError(error);
    }
  }

  async start(): Promise<void> {
    const capturer = this.requiredCapturer();
    await capturer.start();
  }

  readDiagnostics(): AudioCaptureDiagnostics {
    const capturer = this.requiredCapturer();
    let hardwareOverflowCount: number = -1;
    let framePosition: number = -1;
    try {
      hardwareOverflowCount = capturer.getOverflowCountSync();
    } catch (error) {
      hardwareOverflowCount = -1;
    }
    try {
      framePosition = capturer.getAudioTimestampInfoSync().framePos;
    } catch (error) {
      framePosition = -1;
    }
    return {
      hardwareOverflowCount: hardwareOverflowCount,
      framePosition: framePosition,
      bufferSizeBytes: this.bufferSizeBytes
    };
  }

  async stop(): Promise<void> {
    const capturer = this.requiredCapturer();
    await capturer.stop();
  }

  detachReadData(): void {
    const capturer = this.requiredCapturer();
    try {
      capturer.off('readData', this.readDataHandler);
    } catch (error) {
      throw captureError(error);
    }
  }

  async release(): Promise<void> {
    const capturer = this.capturer;
    this.capturer = undefined;
    this.bufferSizeBytes = 0;
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

  private requiredCapturer(): audio.AudioCapturer {
    if (this.capturer === undefined) {
      throw new Error('AudioCapturer 尚未创建');
    }
    return this.capturer;
  }
}

function captureError(error: Object): Error {
  return error instanceof Error ? error : new Error(JSON.stringify(error));
}
