import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { taskpool } from '@kit.ArkTS';
import { prepareTransientReviewAudio } from './PhoneV3ReviewAudioWorker';
import { PhoneV3ReviewAudioCachePort } from '../application/PhoneV3Ports';
import { AudioPlaybackService } from 'common';
import { DeviceV3ReviewAudioResponse } from '../../computer/ComputerTransferProtocol';

const REVIEW_AUDIO_DIRECTORY: string = 'review-audio';

export class PhoneV3ReviewAudioPlayer {
  private directory: string;
  private player: AudioPlaybackService | undefined = undefined;
  private generation: number = 0;
  private currentPath: string = '';
  private cache?: PhoneV3ReviewAudioCachePort;

  constructor(context: common.UIAbilityContext, cache?: PhoneV3ReviewAudioCachePort) {
    this.cache = cache;
    this.directory = `${context.cacheDir}/${REVIEW_AUDIO_DIRECTORY}`;
  }

  async play(response: DeviceV3ReviewAudioResponse, onStarted: () => void,
    onCompleted: () => void = (): void => {},
    onFailure: (message: string) => void = (_message: string): void => {},
    onProgress: (position: number) => void = (_position: number): void => {}): Promise<void> {
    const generation = this.generation + 1;
    await this.release();
    if (generation !== this.generation) { return; }
    const local = response.local_audio_path ?? '';
    const leased = this.cache?.hasLease(local) === true;
    validateReviewAudio(response, leased);
    const path = leased ? local : await taskpool.execute(prepareTransientReviewAudio,
      this.directory, `${Date.now()}-${generation}`, response.data_base64url) as string;
    if (generation !== this.generation) { this.removeFile(path); return; }
    this.currentPath = path;
    let started: boolean = false;
    const player = new AudioPlaybackService((playing: boolean, message: string): void => {
      if (generation !== this.generation) { return; }
      if (playing && !started) { started = true; onStarted(); }
      if (message === '播放完成') {
        this.generation += 1;
        this.currentPath = '';
        player.release().then((): void => this.removeFile(path), (): void => this.removeFile(path));
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
    if (!path.startsWith(`${this.directory}/`)) { this.cache?.release(path); return; }
    fileIo.unlink(path).catch((): void => {});
  }
}

function validateReviewAudio(response: DeviceV3ReviewAudioResponse, leased: boolean): void {
  if (response.review_id.length === 0 || response.prototype_id.length === 0 ||
    (!leased && response.data_base64url.length === 0) || !Number.isSafeInteger(response.start_ms) ||
    !Number.isSafeInteger(response.end_ms) || response.start_ms < 0 ||
    response.end_ms <= response.start_ms) {
    throw new Error('电脑返回的声纹审核音频无效');
  }
}
