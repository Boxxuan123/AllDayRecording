import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';

export type PlaybackStateHandler = (playing: boolean, message: string) => void;

export class AudioPlaybackService {
  private player: media.AVPlayer | undefined = undefined;
  private inputFd: number = -1;
  private stateHandler: PlaybackStateHandler;
  private sequencePaths: Array<string> = [];
  private sequenceIndex: number = 0;
  private playbackGeneration: number = 0;

  constructor(stateHandler: PlaybackStateHandler) {
    this.stateHandler = stateHandler;
  }

  async play(path: string): Promise<void> {
    await this.playSequence([path]);
  }

  async playSequence(paths: Array<string>): Promise<void> {
    if (!canIUse('SystemCapability.Multimedia.Media.AVPlayer')) {
      throw new Error('当前设备不支持 AVPlayer 本地播放能力');
    }
    if (paths.length === 0) {
      throw new Error('没有可播放的录音文件');
    }
    await this.release();
    this.sequencePaths = paths.slice();
    this.sequenceIndex = 0;
    const generation = this.playbackGeneration;
    await this.playCurrentSequenceItem(generation);
  }

  private async playCurrentSequenceItem(generation: number): Promise<void> {
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
      player.setVolume(1.0);
      await player.play();
      this.stateHandler(true, this.sequencePaths.length > 1 ?
        `正在播放第 ${this.sequenceIndex + 1}/${this.sequencePaths.length} 段` : '正在播放，请确认媒体音量');
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
        } else if (state === 'playing') {
          this.stateHandler(true, this.sequencePaths.length > 1 ?
            `正在播放第 ${this.sequenceIndex + 1}/${this.sequencePaths.length} 段` :
            '正在播放，请确认媒体音量');
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

      player.fdSrc = { fd: fd, offset: 0, length: size };
    });
  }

  private async handleSequenceItemCompleted(player: media.AVPlayer, generation: number): Promise<void> {
    if (generation !== this.playbackGeneration || this.player !== player) {
      return;
    }
    await this.releaseCurrentPlayer(player);
    if (generation !== this.playbackGeneration) {
      return;
    }
    this.sequenceIndex += 1;
    if (this.sequenceIndex < this.sequencePaths.length) {
      await this.playCurrentSequenceItem(generation);
      return;
    }
    this.sequencePaths = [];
    this.sequenceIndex = 0;
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
    this.sequenceIndex = 0;
    const player = this.player;
    await this.releaseCurrentPlayer(player);
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
