import { commonEventManager } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { requireRecordingDiagnosticsEnabled } from './RecordingDiagnosticsPolicy';

const DOMAIN: number = 0x0000;
const TAG: string = 'SleepModeProbe';

export function sleepModeProbeDiagnosticName(): string {
  return 'sleep_mode_probe';
}

export interface SleepModeProbeCallbacks {
  onStarted: (logPath: string) => void;
  onEvent: (eventName: string, eventCount: number) => void;
  onError: (message: string) => void;
}

interface SleepModeProbeRecord {
  timestamp: number;
  kind: string;
  event: string;
  code?: number;
  data?: string;
}

export class SleepModeProbeService {
  private callbacks: SleepModeProbeCallbacks;
  private filesDirectory: string;
  private subscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;
  private logFd: number = -1;
  private logPath: string = '';
  private eventCount: number = 0;
  private eventHandler: (data: commonEventManager.CommonEventData) => void;

  constructor(filesDirectory: string, callbacks: SleepModeProbeCallbacks) {
    requireRecordingDiagnosticsEnabled();
    this.filesDirectory = filesDirectory;
    this.callbacks = callbacks;
    this.eventHandler = (data: commonEventManager.CommonEventData): void => {
      this.handleEvent(data);
    };
  }

  async start(): Promise<void> {
    if (this.subscriber !== undefined) {
      return;
    }
    if (!canIUse('SystemCapability.Notification.CommonEvent')) {
      throw new Error('当前手表不支持公共事件订阅');
    }

    const events: Array<string> = [
      commonEventManager.Support.COMMON_EVENT_ENTER_FORCE_SLEEP,
      commonEventManager.Support.COMMON_EVENT_EXIT_FORCE_SLEEP,
      commonEventManager.Support.COMMON_EVENT_ENTER_HIBERNATE,
      commonEventManager.Support.COMMON_EVENT_EXIT_HIBERNATE,
      commonEventManager.Support.COMMON_EVENT_DEVICE_IDLE_MODE_CHANGED,
      commonEventManager.Support.COMMON_EVENT_POWER_SAVE_MODE_CHANGED,
      commonEventManager.Support.COMMON_EVENT_SCREEN_OFF,
      commonEventManager.Support.COMMON_EVENT_SCREEN_ON
    ];

    this.eventCount = 0;
    this.logPath = `${this.filesDirectory}/sleep_mode_probe_${Date.now()}.jsonl`;
    try {
      const output = fileIo.openSync(this.logPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.APPEND);
      this.logFd = output.fd;
      const subscriber = await commonEventManager.createSubscriber({ events: events });
      await commonEventManager.subscribeToEvent(subscriber, this.eventHandler);
      this.subscriber = subscriber;
      this.appendRecord({
        timestamp: Date.now(),
        kind: 'probe_started',
        event: ''
      });
      this.callbacks.onStarted(this.logPath);
    } catch (error) {
      this.closeLog();
      throw new Error(`联动探针订阅失败：${this.errorMessage(error)}`);
    }
  }

  async stop(): Promise<void> {
    const subscriber = this.subscriber;
    this.subscriber = undefined;
    if (subscriber !== undefined) {
      try {
        await new Promise<void>((resolve: () => void) => {
          commonEventManager.unsubscribe(subscriber, () => resolve());
        });
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'unsubscribe failed: %{public}s', this.errorMessage(error));
      }
    }
    if (this.logFd >= 0) {
      this.appendRecord({
        timestamp: Date.now(),
        kind: 'probe_stopped',
        event: ''
      });
    }
    this.closeLog();
  }

  getLogPath(): string {
    return this.logPath;
  }

  private handleEvent(data: commonEventManager.CommonEventData): void {
    this.eventCount += 1;
    const record: SleepModeProbeRecord = {
      timestamp: Date.now(),
      kind: 'common_event',
      event: data.event,
      code: data.code,
      data: data.data
    };
    this.appendRecord(record);
    hilog.info(DOMAIN, TAG, '%{public}s', JSON.stringify(record));
    this.callbacks.onEvent(data.event, this.eventCount);
  }

  private appendRecord(record: SleepModeProbeRecord): void {
    if (this.logFd < 0) {
      return;
    }
    try {
      fileIo.writeSync(this.logFd, `${JSON.stringify(record)}\n`);
      fileIo.fsyncSync(this.logFd);
    } catch (error) {
      const message = `联动探针日志写入失败：${this.errorMessage(error)}`;
      hilog.error(DOMAIN, TAG, '%{public}s', message);
      this.callbacks.onError(message);
    }
  }

  private closeLog(): void {
    if (this.logFd < 0) {
      return;
    }
    try {
      fileIo.closeSync(this.logFd);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'close log failed: %{public}s', this.errorMessage(error));
    } finally {
      this.logFd = -1;
    }
  }

  private errorMessage(error: Object): string {
    return error instanceof Error ? error.message : JSON.stringify(error);
  }
}
