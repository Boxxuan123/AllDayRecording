import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';

export type PlaybackStateHandler = (playing: boolean, message: string) => void;
export type PlaybackProgressHandler = (positionMs: number, durationMs: number) => void;

export class AudioPlaybackService {
  private player: media.AVPlayer | undefined = undefined;
  private inputFd: number = -1;
  private stateHandler: PlaybackStateHandler;
  private progressHandler: PlaybackProgressHandler | undefined = undefined;
  private sequencePaths: Array<string> = [];
  private sequenceDurations: Array<number> = [];
  private sequenceIndex: number = 0;
  private totalDurationMs: number = 0;
  private playbackGeneration: number = 0;

  constructor(stateHandler: PlaybackStateHandler, progressHandler?: PlaybackProgressHandler) {
    this.stateHandler = stateHandler;
    this.progressHandler = progressHandler;
  }

  async play(path: string, durationMs: number = 0, startPositionMs: number = 0): Promise<void> {
    await this.playSequence([path], [durationMs], startPositionMs);
  }

  async playSequence(paths: Array<string>, durations: Array<number> = [],
    startPositionMs: number = 0): Promise<void> {
    if (!canIUse('SystemCapability.Multimedia.Media.AVPlayer')) {
      throw new Error('当前设备不支持 AVPlayer 本地播放能力');
    }
    if (paths.length === 0) {
      throw new Error('没有可播放的录音文件');
    }
    await this.release();
    this.sequencePaths = paths.slice();
    this.sequenceDurations = [];
    for (let index = 0; index < paths.length; index += 1) {
      const duration = index < durations.length ? durations[index] : 0;
      this.sequenceDurations.push(Math.max(0, duration));
    }
    this.recalculateTotalDuration();
    const clampedPosition = this.clampPosition(startPositionMs);
    this.sequenceIndex = this.sequenceIndexForPosition(clampedPosition);
    const generation = this.playbackGeneration;
    this.notifyProgress(clampedPosition);
    await this.playCurrentSequenceItem(generation,
      clampedPosition - this.durationBeforeIndex(this.sequenceIndex), true);
  }

  async pause(): Promise<boolean> {
    const player = this.player;
    if (player === undefined || player.state !== 'playing') {
      return false;
    }
    try {
      await player.pause();
      this.stateHandler(false, '播放已暂停');
      return true;
    } catch (error) {
      throw playbackFileError(error);
    }
  }

  async resume(): Promise<boolean> {
    const player = this.player;
    if (player === undefined || (player.state !== 'paused' && player.state !== 'prepared')) {
      return false;
    }
    try {
      await player.play();
      this.stateHandler(true, '正在播放');
      return true;
    } catch (error) {
      throw playbackFileError(error);
    }
  }

  hasActiveSession(): boolean {
    return this.sequencePaths.length > 0;
  }

  async seekTo(positionMs: number): Promise<boolean> {
    if (this.sequencePaths.length === 0) {
      return false;
    }
    const clampedPosition = this.clampPosition(positionMs);
    const targetIndex = this.sequenceIndexForPosition(clampedPosition);
    const targetItemPosition = clampedPosition - this.durationBeforeIndex(targetIndex);
    const player = this.player;
    if (targetIndex === this.sequenceIndex && player !== undefined &&
      (player.state === 'prepared' || player.state === 'playing' || player.state === 'paused' ||
        player.state === 'completed')) {
      player.seek(targetItemPosition, media.SeekMode.SEEK_CLOSEST);
      this.notifyProgress(clampedPosition);
      return true;
    }
    const shouldContinuePlaying = player !== undefined && player.state === 'playing';
    const generation = this.playbackGeneration;
    await this.releaseCurrentPlayer(player);
    if (generation !== this.playbackGeneration) {
      return false;
    }
    this.sequenceIndex = targetIndex;
    this.notifyProgress(clampedPosition);
    await this.playCurrentSequenceItem(generation, targetItemPosition, shouldContinuePlaying);
    return true;
  }

  private async playCurrentSequenceItem(generation: number, startPositionMs: number = 0,
    autoPlay: boolean = true): Promise<void> {
    if (generation !== this.playbackGeneration || this.sequenceIndex >= this.sequencePaths.length) {
      return;
    }
    const path = this.sequencePaths[this.sequenceIndex];
    const inputFile = openPlaybackFile(path);
    this.inputFd = inputFile.fd;
    const size = statPlaybackFile(path);
    try {
      const player = await media.createAVPlayer();
      if (generation !== this.playbackGeneration) {
        await player.release();
        return;
      }
      this.player = player;
      await this.setSourceAndWaitForInitialized(player, this.inputFd, size, generation);
      if (generation !== this.playbackGeneration || this.player !== player) {
        return;
      }
      await player.prepare();
      this.updateSequenceDuration(this.sequenceIndex, player.duration);
      player.setVolume(1.0);
      if (startPositionMs > 0) {
        player.seek(Math.min(startPositionMs, player.duration), media.SeekMode.SEEK_CLOSEST);
      }
      this.notifyProgress(this.durationBeforeIndex(this.sequenceIndex) + startPositionMs);
      if (autoPlay) {
        await player.play();
        this.stateHandler(true, '正在播放');
      } else {
        this.stateHandler(false, '播放已暂停');
      }
    } catch (error) {
      const playbackError = error as BusinessError;
      await this.release();
      if (playbackError.code !== undefined) {
        throw new Error(`播放器状态异常（${playbackError.code}）`);
      }
      throw error instanceof Error ? error : new Error('无法打开录音文件');
    }
  }

  private setSourceAndWaitForInitialized(player: media.AVPlayer, fd: number, size: number,
    generation: number): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let waitingForInitialized = true;

      player.on('stateChange', (state: media.AVPlayerState) => {
        if (state === 'initialized' && waitingForInitialized) {
          waitingForInitialized = false;
          resolve();
        } else if (state === 'playing' && generation === this.playbackGeneration && this.player === player) {
          this.stateHandler(true, '正在播放');
        } else if (state === 'paused' && generation === this.playbackGeneration && this.player === player) {
          this.stateHandler(false, '播放已暂停');
        } else if (state === 'completed') {
          this.handleSequenceItemCompleted(player, generation).then((): void => {
          }, (error: Object): void => {
            this.handleSequenceFailure(player, generation, playbackErrorMessage(error));
          });
        } else if (state === 'error' && waitingForInitialized) {
          waitingForInitialized = false;
          reject(new Error('播放器初始化失败'));
        }
      });

      player.on('error', (error: BusinessError) => {
        const message = error.code !== undefined ? `${error.message}（${error.code}）` : error.message;
        if (waitingForInitialized) {
          waitingForInitialized = false;
          reject(new Error(message));
          return;
        }
        this.handleSequenceFailure(player, generation, message);
      });

      player.on('timeUpdate', (positionMs: number) => {
        if (generation === this.playbackGeneration && this.player === player) {
          this.notifyProgress(this.durationBeforeIndex(this.sequenceIndex) + positionMs);
        }
      });

      player.on('durationUpdate', (durationMs: number) => {
        if (generation === this.playbackGeneration && this.player === player) {
          this.updateSequenceDuration(this.sequenceIndex, durationMs);
          this.notifyProgress(this.durationBeforeIndex(this.sequenceIndex) + player.currentTime);
        }
      });

      player.fdSrc = { fd: fd, offset: 0, length: size };
    });
  }

  private async handleSequenceItemCompleted(player: media.AVPlayer, generation: number): Promise<void> {
    if (generation !== this.playbackGeneration || this.player !== player) {
      return;
    }
    this.notifyProgress(this.durationBeforeIndex(this.sequenceIndex) + this.sequenceDurations[this.sequenceIndex]);
    await this.releaseCurrentPlayer(player);
    if (generation !== this.playbackGeneration) {
      return;
    }
    this.sequenceIndex += 1;
    if (this.sequenceIndex < this.sequencePaths.length) {
      await this.playCurrentSequenceItem(generation, 0, true);
      return;
    }
    this.sequencePaths = [];
    this.sequenceDurations = [];
    this.sequenceIndex = 0;
    this.notifyProgress(this.totalDurationMs);
    this.stateHandler(false, '播放完成');
  }

  private handleSequenceFailure(player: media.AVPlayer, generation: number, message: string): void {
    if (generation !== this.playbackGeneration || this.player !== player) {
      return;
    }
    this.stateHandler(false, `播放失败：${message}`);
    this.release().then((): void => {
    }, (): void => {
    });
  }

  async release(): Promise<void> {
    this.playbackGeneration += 1;
    this.sequencePaths = [];
    this.sequenceDurations = [];
    this.sequenceIndex = 0;
    const player = this.player;
    await this.releaseCurrentPlayer(player);
    this.notifyProgress(0);
  }

  private updateSequenceDuration(index: number, durationMs: number): void {
    if (index < 0 || index >= this.sequenceDurations.length || durationMs <= 0) {
      return;
    }
    this.sequenceDurations[index] = durationMs;
    this.recalculateTotalDuration();
  }

  private recalculateTotalDuration(): void {
    this.totalDurationMs = 0;
    for (let index = 0; index < this.sequenceDurations.length; index += 1) {
      this.totalDurationMs += this.sequenceDurations[index];
    }
  }

  private durationBeforeIndex(targetIndex: number): number {
    let durationMs = 0;
    for (let index = 0; index < targetIndex && index < this.sequenceDurations.length; index += 1) {
      durationMs += this.sequenceDurations[index];
    }
    return durationMs;
  }

  private sequenceIndexForPosition(positionMs: number): number {
    if (this.sequencePaths.length === 0 || this.totalDurationMs <= 0) {
      return 0;
    }
    let elapsedMs = 0;
    for (let index = 0; index < this.sequenceDurations.length; index += 1) {
      elapsedMs += this.sequenceDurations[index];
      if (positionMs < elapsedMs || index === this.sequenceDurations.length - 1) {
        return index;
      }
    }
    return this.sequencePaths.length - 1;
  }

  private clampPosition(positionMs: number): number {
    if (this.totalDurationMs <= 0) {
      return Math.max(0, positionMs);
    }
    return Math.max(0, Math.min(positionMs, this.totalDurationMs));
  }

  private notifyProgress(positionMs: number): void {
    if (this.progressHandler !== undefined) {
      this.progressHandler(this.clampPosition(positionMs), this.totalDurationMs);
    }
  }

  private async releaseCurrentPlayer(player: media.AVPlayer | undefined): Promise<void> {
    this.player = undefined;
    if (player !== undefined) {
      try {
        await player.release();
      } catch (error) {
        // The player may already have released itself after an error.
      }
    }
    if (this.inputFd >= 0) {
      const inputFd = this.inputFd;
      this.inputFd = -1;
      closePlaybackFile(inputFd);
    }
  }
}

function openPlaybackFile(path: string): fileIo.File {
  try {
    return fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
  } catch (error) {
    throw playbackFileError(error);
  }
}

function statPlaybackFile(path: string): number {
  try {
    return fileIo.statSync(path).size;
  } catch (error) {
    throw playbackFileError(error);
  }
}

function closePlaybackFile(fd: number): void {
  try {
    fileIo.closeSync(fd);
  } catch (error) {
    throw playbackFileError(error);
  }
}

function playbackFileError(error: Object): Error {
  return error instanceof Error ? error : new Error(JSON.stringify(error));
}

function playbackErrorMessage(error: Object): string {
  return error instanceof Error ? error.message : JSON.stringify(error);
}
