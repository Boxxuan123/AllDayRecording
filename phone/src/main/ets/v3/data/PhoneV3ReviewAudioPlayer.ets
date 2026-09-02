import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { AudioPlaybackService } from 'common';
import { decodeBase64Url, DeviceV3ReviewAudioResponse } from '../../computer/ComputerTransferProtocol';

const REVIEW_AUDIO_DIRECTORY: string = 'review-audio';
const MAX_REVIEW_AUDIO_BYTES: number = 16 * 1024 * 1024;

export class PhoneV3ReviewAudioPlayer {
  private directory: string;
  private player: AudioPlaybackService;
  private stopTimer: number = -1;
  private playbackStarted: (() => void) | undefined = undefined;

  constructor(context: common.UIAbilityContext) {
    this.directory = `${context.cacheDir}/${REVIEW_AUDIO_DIRECTORY}`;
    ensureDirectory(this.directory);
    this.player = new AudioPlaybackService((playing: boolean, _message: string): void => {
      const started = this.playbackStarted;
      if (playing && started !== undefined) {
        this.playbackStarted = undefined;
        started();
      }
    });
  }

  async play(response: DeviceV3ReviewAudioResponse, onStarted: () => void): Promise<void> {
    validateReviewAudio(response);
    const bytes = decodeBase64Url(response.data_base64url);
    if (bytes.length === 0 || bytes.length > MAX_REVIEW_AUDIO_BYTES) {
      throw new Error('声纹审核音频大小无效');
    }
    const extension = safeAudioExtension(response.format);
    const path = `${this.directory}/${safeFileName(response.prototype_id)}.${extension}`;
    writeBytes(path, bytes);
    this.playbackStarted = onStarted;
    try {
      await this.player.play(path, 0, response.start_ms);
    } catch (_error) {
      this.playbackStarted = undefined;
      throw new Error('播放声纹审核音频失败');
    }
    if (this.stopTimer >= 0) {
      clearTimeout(this.stopTimer);
    }
    const duration = Math.max(800, Math.min(15000, response.end_ms - response.start_ms));
    this.stopTimer = setTimeout((): void => {
      this.player.release().then((): void => {}, (): void => {});
      this.stopTimer = -1;
    }, duration);
  }

  async release(): Promise<void> {
    this.playbackStarted = undefined;
    if (this.stopTimer >= 0) {
      clearTimeout(this.stopTimer);
      this.stopTimer = -1;
    }
    await this.player.release();
  }
}

function validateReviewAudio(response: DeviceV3ReviewAudioResponse): void {
  if (response.review_id.length === 0 || response.prototype_id.length === 0 ||
    response.data_base64url.length === 0 || !Number.isSafeInteger(response.start_ms) ||
    !Number.isSafeInteger(response.end_ms) || response.start_ms < 0 ||
    response.end_ms <= response.start_ms) {
    throw new Error('电脑返回的声纹审核音频无效');
  }
}

function ensureDirectory(path: string): void {
  try {
    fileIo.mkdirSync(path);
  } catch (_error) {
    try {
      fileIo.statSync(path);
    } catch (error) {
      throw new Error('无法创建声纹审核音频缓存');
    }
  }
}

function writeBytes(path: string, bytes: Uint8Array): void {
  const file = fileIo.openSync(path,
    fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(file.fd, bytes.buffer);
  } finally {
    fileIo.closeSync(file.fd);
  }
}

function safeFileName(value: string): string {
  return value.replace(/[^A-Za-z0-9_-]/g, '_').substring(0, 120);
}

function safeAudioExtension(value: string): string {
  const normalized = value.toLowerCase();
  return ['wav', 'm4a', 'aac', 'mp3', 'flac', 'ogg'].indexOf(normalized) >= 0 ? normalized : 'audio';
}
