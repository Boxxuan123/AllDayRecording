import { PhoneRecordingViewModel } from '../../presentation/phone/PhoneRecordingViewModel';
import { PhoneV3DeviceBridgePort } from '../application/PhoneV3Ports';
import { PhoneV3DeviceState } from '../domain/PhoneV3Models';

export class PhoneV3LegacyBridge implements PhoneV3DeviceBridgePort {
  private viewModel: PhoneRecordingViewModel;

  constructor(viewModel: PhoneRecordingViewModel) {
    this.viewModel = viewModel;
  }

  state(): PhoneV3DeviceState {
    return new PhoneV3DeviceState(
      this.viewModel.remoteStateLabel(), this.viewModel.syncState.inProgress,
      this.viewModel.syncState.received, this.viewModel.syncState.total,
      this.viewModel.isPlaying, this.viewModel.isPlaybackBusy,
      this.viewModel.playbackPositionMs, this.viewModel.playbackDurationMs);
  }

  selectSession(sessionKey: string): void {
    const group = this.viewModel.recordingGroup(sessionKey);
    if (group !== undefined) {
      this.viewModel.selectRecordingGroup(group);
    }
  }

  togglePlayback(): void {
    this.viewModel.togglePlayback();
  }

  seekPlayback(positionMs: number): void {
    this.viewModel.seekPlayback(positionMs);
  }

  stopPlayback(): void {
    this.viewModel.stopPlayback();
  }

  requestWatchSync(): void {
    this.viewModel.requestWatchSync();
  }
}
