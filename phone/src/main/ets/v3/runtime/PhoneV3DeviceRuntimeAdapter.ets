import { PhoneV3DeviceBridgePort } from '../application/PhoneV3Ports';
import {
  PhoneV3DeviceState,
  PhoneV3FileTransferState,
  PhoneV3WifiState
} from '../domain/PhoneV3Models';
import { PhoneV3DeviceRuntime } from './PhoneV3DeviceRuntime';

// Keeps ArkUI-facing state mapping outside the native device runtime.
export class PhoneV3DeviceRuntimeAdapter implements PhoneV3DeviceBridgePort {
  private runtime: PhoneV3DeviceRuntime;

  constructor(runtime: PhoneV3DeviceRuntime) {
    this.runtime = runtime;
  }

  state(): PhoneV3DeviceState {
    const sync = this.runtime.syncState;
    const status = this.runtime.status;
    return new PhoneV3DeviceState(
      this.runtime.remoteStateLabel(), sync.inProgress,
      sync.received, sync.total,
      this.runtime.isPlaying, this.runtime.isPlaybackBusy,
      this.runtime.playbackPositionMs, this.runtime.playbackDurationMs,
      this.runtime.remoteRecordingState, this.runtime.isControllingWatch,
      this.runtime.isReconnectingReceiver,
      new PhoneV3FileTransferState(sync.fileTransferActive, this.runtime.transferStageLabel(),
        sync.transferPercent, sync.transferFileName, sync.transferredBytes, sync.transferSize,
        sync.transferIndex, sync.transferTotal, sync.message, statusError(sync.message)),
      new PhoneV3WifiState(this.runtime.wifiReceiverReady, this.runtime.wifiBusy,
        this.runtime.wifiStopping, this.runtime.wifiProgress, this.runtime.wifiStatus,
        this.runtime.wifiCapability, statusError(this.runtime.wifiStatus)),
      status, statusError(status));
  }

  selectSession(sessionKey: string): void {
    const group = this.runtime.recordingGroup(sessionKey);
    if (group !== undefined) {
      this.runtime.selectRecordingGroup(group);
    }
  }

  togglePlayback(): void {
    this.runtime.clearOperationStatus();
    this.runtime.togglePlayback();
  }

  seekPlayback(positionMs: number): void {
    this.runtime.clearOperationStatus();
    this.runtime.seekPlayback(positionMs);
  }

  stopPlayback(): void {
    this.runtime.stopPlayback();
  }

  requestWatchSync(): void {
    this.runtime.clearOperationStatus();
    this.runtime.requestWatchSync();
  }

  requestWatchRecordingState(desiredState: string): void {
    this.runtime.clearOperationStatus();
    this.runtime.requestWatchRecordingState(desiredState);
  }

  toggleWifiReceiver(): void {
    this.runtime.clearOperationStatus();
    this.runtime.toggleWifiReceiver();
  }

  retryWifiReceiver(): void {
    this.runtime.clearOperationStatus();
    this.runtime.retryWifiReceiver();
  }

  reconnectReceiver(): void {
    this.runtime.clearOperationStatus();
    this.runtime.reconnectReceiver();
  }

  deleteLocalSession(localGroupKey: string): Promise<void> {
    const group = this.runtime.recordingGroup(localGroupKey);
    if (group === undefined) {
      return new Promise<void>((_resolve: () => void, reject: (error: Object) => void): void => {
        reject(new Error('手机本地录音已经不存在'));
      });
    }
    return new Promise<void>((resolve: () => void, reject: (error: Object) => void): void => {
      this.runtime.deleteRecordingGroup(group, resolve, reject);
    });
  }

  addLocalAudioChangeListener(listener: () => void): void {
    this.runtime.addLocalAudioChangeListener(listener);
  }

  removeLocalAudioChangeListener(listener: () => void): void {
    this.runtime.removeLocalAudioChangeListener(listener);
  }
}

function statusError(status: string): string {
  if (status.includes('失败') || status.includes('无法') || status.includes('错误') ||
    status.includes('未连接') || status.includes('未找到') || status.includes('不支持') ||
    status.includes('拒绝') || status.includes('超时')) {
    return status;
  }
  return '';
}
