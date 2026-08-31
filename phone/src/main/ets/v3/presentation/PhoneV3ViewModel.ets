import { common } from '@kit.AbilityKit';
import { PhoneRecordingViewModel } from '../../presentation/phone/PhoneRecordingViewModel';
import { PhoneV3UseCases, mergePhoneV3Sessions } from '../application/PhoneV3UseCases';
import { PhoneV3DeviceBridgePort } from '../application/PhoneV3Ports';
import { PhoneProjectionRepository } from '../data/PhoneProjectionRepository';
import { PhoneV3DeviceRemote } from '../data/PhoneV3DeviceRemote';
import { PhoneV3LocalAudioRepository } from '../data/PhoneV3LocalAudioRepository';
import { PhoneV3LocalAudioFact, PhoneV3SessionCard, PhoneV3Snapshot } from '../domain/PhoneV3Models';
import { PhoneV3LegacyBridge } from './PhoneV3LegacyBridge';
import {
  PhoneV3UiAction,
  PhoneV3UiActionType,
  PhoneV3UiState,
  reducePhoneV3Ui,
  selectedPhoneV3Session
} from './PhoneV3UiState';

@Observed
export class PhoneV3ViewModel {
  state: PhoneV3UiState = new PhoneV3UiState();
  private useCases: PhoneV3UseCases | undefined = undefined;
  private bridge: PhoneV3DeviceBridgePort | undefined = undefined;
  private localFacts: Array<PhoneV3LocalAudioFact> = [];
  private timerId: number = -1;
  private started: boolean = false;
  private refreshing: boolean = false;

  start(context: common.UIAbilityContext, legacy: PhoneRecordingViewModel): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.bridge = new PhoneV3LegacyBridge(legacy);
    this.timerId = setInterval((): void => this.refreshDeviceState(), 500);
    this.initialize(context);
  }

  stop(): void {
    this.started = false;
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    this.bridge?.stopPlayback();
  }

  selectedSession(): PhoneV3SessionCard | undefined {
    return selectedPhoneV3Session(this.state);
  }

  selectSession(session: PhoneV3SessionCard): void {
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SESSION_SELECTED,
      undefined, undefined, session.id));
    if (session.localGroupKey.length > 0) {
      this.bridge?.selectSession(session.localGroupKey);
    }
    this.refreshDeviceState();
  }

  refresh(): void {
    if (this.refreshing || this.useCases === undefined) {
      return;
    }
    this.refreshing = true;
    this.refreshSnapshot().then((): void => {
      this.refreshing = false;
    }, (error: Object): void => {
      this.refreshing = false;
      this.fail(error);
    });
  }

  synchronize(): void {
    const useCases = this.useCases;
    if (useCases === undefined || this.state.busy) {
      return;
    }
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.BUSY,
      undefined, undefined, '正在发现电脑并同步增量状态…'));
    useCases.synchronize().then((result): Promise<void> => {
      this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SUCCESS, undefined, undefined,
        `同步完成：${result.batches} 批，游标 ${result.finalCursor}`));
      return this.refreshSnapshot();
    }).catch((error: Object): void => this.fail(error));
  }

  rebuild(): void {
    const useCases = this.useCases;
    if (useCases === undefined || this.state.busy) {
      return;
    }
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.BUSY,
      undefined, undefined, '正在保留离线状态并重建电脑投影…'));
    useCases.rebuild().then((result): Promise<void> => {
      this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SUCCESS, undefined, undefined,
        `投影重建完成：${result.batches} 批，游标 ${result.finalCursor}`));
      return this.refreshSnapshot();
    }).catch((error: Object): void => this.fail(error));
  }

  requestWatchSync(): void {
    this.bridge?.requestWatchSync();
    this.refreshDeviceState();
  }

  togglePlayback(): void {
    this.bridge?.togglePlayback();
    this.refreshDeviceState();
  }

  seekPlayback(positionMs: number): void {
    this.bridge?.seekPlayback(positionMs);
    this.refreshDeviceState();
  }

  stopPlayback(): void {
    this.bridge?.stopPlayback();
    this.refreshDeviceState();
  }

  private async initialize(context: common.UIAbilityContext): Promise<void> {
    try {
      const local = new PhoneV3LocalAudioRepository(context.filesDir);
      this.localFacts = await local.list();
      this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.LOCAL_READY,
        new PhoneV3Snapshot(mergePhoneV3Sessions(this.localFacts, [], [], [], [])),
        undefined, `手机本地已有 ${this.localFacts.length} 条录音`));
      const repository = await PhoneProjectionRepository.open(context);
      this.useCases = new PhoneV3UseCases(repository, local, new PhoneV3DeviceRemote(context));
      await this.refreshSnapshot();
    } catch (error) {
      this.fail(error as Object);
    }
  }

  private async refreshSnapshot(): Promise<void> {
    const useCases = this.useCases;
    if (useCases === undefined) {
      return;
    }
    this.localFacts = await useCases.loadLocal();
    const snapshot = await useCases.loadCached(this.localFacts);
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.SNAPSHOT_READY, snapshot,
      undefined, `已合并 ${snapshot.sessions.length} 条会话；最后游标 ${snapshot.sync.cursor}`));
  }

  private refreshDeviceState(): void {
    const bridge = this.bridge;
    if (bridge === undefined) {
      return;
    }
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.DEVICE_CHANGED,
      undefined, bridge.state()));
  }

  private dispatch(action: PhoneV3UiAction): void {
    this.state = reducePhoneV3Ui(this.state, action);
  }

  private fail(error: Object): void {
    const message = error instanceof Error ? error.message : JSON.stringify(error);
    this.dispatch(new PhoneV3UiAction(PhoneV3UiActionType.FAILURE, undefined, undefined, message));
  }
}
