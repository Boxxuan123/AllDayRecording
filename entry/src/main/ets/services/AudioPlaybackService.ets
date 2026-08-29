import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';

export type PlaybackStateHandler = (playing: boolean, message: string) => void;

export class AudioPlaybackService {
  private player: media.AVPlayer | undefined = undefined;
  private inputFd: number = -1;
  private stateHandler: PlaybackStateHandler;

  constructor(stateHandler: PlaybackStateHandler) {
    this.stateHandler = stateHandler;
  }

  async play(path: string): Promise<void> {
    if (!canIUse('SystemCapability.Multimedia.Media.AVPlayer')) {
      throw new Error('当前手表不支持 AVPlayer 本地播放能力');
    }
    await this.release();
    const inputFile = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    this.inputFd = inputFile.fd;
    const size = fileIo.statSync(path).size;

    try {
      const player = await media.createAVPlayer();
      this.player = player;
      await this.setSourceAndWaitForInitialized(player, this.inputFd, size);
      await player.prepare();
      player.setVolume(1.0);
      await player.play();
      this.stateHandler(true, '正在播放，请确认媒体音量');
    } catch (error) {
      const playbackError = error as BusinessError;
      await this.release();
      if (playbackError.code !== undefined) {
        throw new Error(`播放器状态异常（${playbackError.code}）`);
      }
      throw error instanceof Error ? error : new Error('无法打开录音文件');
    }
  }

  private setSourceAndWaitForInitialized(player: media.AVPlayer, fd: number, size: number): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let waitingForInitialized = true;

      player.on('stateChange', (state: media.AVPlayerState) => {
        if (state === 'initialized' && waitingForInitialized) {
          waitingForInitialized = false;
          resolve();
        } else if (state === 'playing') {
          this.stateHandler(true, '正在播放，请确认媒体音量');
        } else if (state === 'completed') {
          this.stateHandler(false, '播放完成');
          this.release();
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
        this.stateHandler(false, `播放失败：${message}`);
        this.release();
      });

      player.fdSrc = { fd: fd, offset: 0, length: size };
    });
  }

  async release(): Promise<void> {
    const player = this.player;
    this.player = undefined;
    if (player !== undefined) {
      try {
        await player.release();
      } catch (error) {
        // The player may already have released itself after an error.
      }
    }
    if (this.inputFd >= 0) {
      fileIo.closeSync(this.inputFd);
      this.inputFd = -1;
    }
  }
}
