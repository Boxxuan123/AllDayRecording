import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { AudioPlaybackService } from 'common';
import { decodeBase64Url, DeviceV3ReviewAudioResponse } from '../../computer/ComputerTransferProtocol';

const REVIEW_AUDIO_DIRECTORY: string = 'review-audio';
const MAX_REVIEW_AUDIO_BYTES: number = 16 * 1024 * 1024;

export class PhoneV3ReviewAudioPlayer {
  private directory: string;
  private player: AudioPlaybackService | undefined = undefined;
  private generation: number = 0;
  private currentPath: string = '';

  constructor(context: common.UIAbilityContext) {
    this.directory = `${context.cacheDir}/${REVIEW_AUDIO_DIRECTORY}`;
    ensureDirectory(this.directory);
  }

  async play(response: DeviceV3ReviewAudioResponse, onStarted: () => void,
    onCompleted: () => void = (): void => {},
    onFailure: (message: string) => void = (_message: string): void => {},
    onProgress: (position: number) => void = (_position: number): void => {}): Promise<void> {
    const generation = this.generation + 1;
    await this.release();
    if (generation !== this.generation) { return; }
    validateReviewAudio(response);
    const bytes = decodeBase64Url(response.data_base64url);
    if (bytes.length === 0 || bytes.length > MAX_REVIEW_AUDIO_BYTES) {
      throw new Error('声纹审核音频大小无效');
    }
    const path = `${this.directory}/${safeFileName(response.prototype_id)}-${generation}.${safeAudioExtension(response.format)}`;
    writeBytes(path, bytes);
    this.currentPath = path;
    let started: boolean = false;
    const player = new AudioPlaybackService((playing: boolean, message: string): void => {
      if (generation !== this.generation) { return; }
      if (playing && !started) { started = true; onStarted(); }
      if (message === '播放完成') {
        this.generation += 1;
        this.removeFile(path);
        onCompleted();
      } else if (message.startsWith('播放失败') || message === '播放已暂停') {
        this.release().then((): void => {}, (): void => {});
        onFailure(message);
      }
    }, (position: number, _duration: number): void => {
      if (generation === this.generation) { onProgress(position); }
    });
    this.player = player;
    try {
      await player.play(path, response.end_ms - response.start_ms, response.start_ms);
    } catch (_error) {
      if (generation === this.generation) { await this.release(); }
      throw new Error('播放声纹审核音频失败');
    }
  }

  async release(): Promise<void> {
    this.generation += 1;
    const player = this.player;
    const path = this.currentPath;
    this.player = undefined;
    this.currentPath = '';
    if (player !== undefined) { await player.release(); }
    this.removeFile(path);
  }

  private removeFile(path: string): void {
    if (path.length === 0) { return; }
    try { fileIo.unlinkSync(path); } catch (_error) {}
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
