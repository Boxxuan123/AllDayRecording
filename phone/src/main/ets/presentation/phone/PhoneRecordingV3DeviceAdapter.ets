import { PhoneV3DeviceBridgePort } from '../../v3/application/PhoneV3Ports';
import {
  PhoneV3DeviceState,
  PhoneV3FileTransferState,
  PhoneV3WifiState
} from '../../v3/domain/PhoneV3Models';
import { PhoneRecordingViewModel } from './PhoneRecordingViewModel';

export class PhoneRecordingV3DeviceAdapter implements PhoneV3DeviceBridgePort {
  private viewModel: PhoneRecordingViewModel;

  constructor(viewModel: PhoneRecordingViewModel) {
    this.viewModel = viewModel;
  }

  state(): PhoneV3DeviceState {
    const sync = this.viewModel.syncState;
    const status = this.viewModel.status;
    return new PhoneV3DeviceState(
      this.viewModel.remoteStateLabel(), sync.inProgress,
      sync.received, sync.total,
      this.viewModel.isPlaying, this.viewModel.isPlaybackBusy,
      this.viewModel.playbackPositionMs, this.viewModel.playbackDurationMs,
      this.viewModel.remoteRecordingState, this.viewModel.isControllingWatch,
      this.viewModel.isReconnectingReceiver,
      new PhoneV3FileTransferState(sync.fileTransferActive, this.viewModel.transferStageLabel(),
        sync.transferPercent, sync.transferFileName, sync.transferredBytes, sync.transferSize,
        sync.transferIndex, sync.transferTotal, sync.message, statusError(sync.message)),
      new PhoneV3WifiState(this.viewModel.wifiReceiverReady, this.viewModel.wifiBusy,
        this.viewModel.wifiStopping, this.viewModel.wifiProgress, this.viewModel.wifiStatus,
        this.viewModel.wifiCapability, statusError(this.viewModel.wifiStatus)),
      status, statusError(status));
  }

  selectSession(sessionKey: string): void {
    const group = this.viewModel.recordingGroup(sessionKey);
    if (group !== undefined) {
      this.viewModel.selectRecordingGroup(group);
    }
  }

  togglePlayback(): void {
    this.viewModel.clearOperationStatus();
    this.viewModel.togglePlayback();
  }

  seekPlayback(positionMs: number): void {
    this.viewModel.clearOperationStatus();
    this.viewModel.seekPlayback(positionMs);
  }

  stopPlayback(): void {
    this.viewModel.stopPlayback();
  }

  requestWatchSync(): void {
    this.viewModel.clearOperationStatus();
    this.viewModel.requestWatchSync();
  }

  requestWatchRecordingState(desiredState: string): void {
    this.viewModel.clearOperationStatus();
    this.viewModel.requestWatchRecordingState(desiredState);
  }

  toggleWifiReceiver(): void {
    this.viewModel.clearOperationStatus();
    this.viewModel.toggleWifiReceiver();
  }

  retryWifiReceiver(): void {
    this.viewModel.clearOperationStatus();
    this.viewModel.retryWifiReceiver();
  }

  reconnectReceiver(): void {
    this.viewModel.clearOperationStatus();
    this.viewModel.reconnectReceiver();
  }

  deleteLocalSession(localGroupKey: string): Promise<void> {
    const group = this.viewModel.recordingGroup(localGroupKey);
    if (group === undefined) {
      return new Promise<void>((_resolve: () => void, reject: (error: Object) => void): void => {
        reject(new Error('手机本地录音已经不存在'));
      });
    }
    return new Promise<void>((resolve: () => void, reject: (error: Object) => void): void => {
      this.viewModel.deleteRecordingGroup(group, resolve, reject);
    });
  }

  addLocalAudioChangeListener(listener: () => void): void {
    this.viewModel.addLocalAudioChangeListener(listener);
  }

  removeLocalAudioChangeListener(listener: () => void): void {
    this.viewModel.removeLocalAudioChangeListener(listener);
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
