import { common, wantAgent } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { notificationManager } from '@kit.NotificationKit';
import { vibrator } from '@kit.SensorServiceKit';

const PREFERENCES_NAME = 'watch_recording_start_fallback';
const PENDING_REQUEST_ID_KEY = 'pending_request_id';
const PENDING_CREATED_AT_KEY = 'pending_created_at';
const START_NOTIFICATION_ID = 2001;
const START_NOTIFICATION_REQUEST_CODE = 2001;
const PENDING_EXPIRY_MS = 5 * 60 * 1000;
export const WATCH_RECORDING_START_ACTION = 'AllDayRecording.action.START_PENDING_RECORDING';

export interface PendingWatchRecordingStart {
  requestId: string;
  createdAt: number;
}

export class WatchRecordingUiState {
  private static foreground: boolean = false;
  private static foregroundListener: (() => void) | undefined = undefined;

  static setForeground(foreground: boolean): void {
    WatchRecordingUiState.foreground = foreground;
    if (foreground) {
      WatchRecordingUiState.notifyForegroundRequest();
    }
  }

  static isForeground(): boolean {
    return WatchRecordingUiState.foreground;
  }

  static setForegroundListener(listener: (() => void) | undefined): void {
    WatchRecordingUiState.foregroundListener = listener;
  }

  static notifyForegroundRequest(): void {
    WatchRecordingUiState.foregroundListener?.();
  }
}

export class WatchRecordingStartFallback {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async requestUserForeground(requestId: string): Promise<void> {
    if (requestId.length === 0) {
      throw new Error('录音请求号为空');
    }
    const notificationEnabled = await this.isNotificationEnabled();
    if (!notificationEnabled) {
      await this.vibrateBestEffort();
      throw new Error('手表通知未开启，请先在手表前台打开应用并允许通知（1600004）');
    }
    await this.savePending({
      requestId: requestId,
      createdAt: Date.now()
    });
    try {
      await this.publishStartNotification();
    } catch (error) {
      await this.clearPending();
      throw error instanceof Error ? error : new Error(JSON.stringify(error));
    }
    await this.vibrateBestEffort();
  }

  async isNotificationEnabled(): Promise<boolean> {
    try {
      return await notificationManager.isNotificationEnabled();
    } catch (error) {
      return false;
    }
  }

  async requestNotificationAuthorization(): Promise<boolean> {
    if (await this.isNotificationEnabled()) {
      return true;
    }
    try {
      await notificationManager.requestEnableNotification(this.context);
    } catch (error) {
      // A rejected first prompt must be recovered from the app notification settings page.
    }
    return this.isNotificationEnabled();
  }

  async openNotificationSettings(): Promise<boolean> {
    try {
      if (canIUse('SystemCapability.Notification.NotificationSettings')) {
        await notificationManager.openNotificationSettings(this.context);
      } else {
        await notificationManager.requestEnableNotification(this.context);
      }
    } catch (error) {
      // The caller displays the resulting disabled state and retry guidance.
    }
    return this.isNotificationEnabled();
  }

  async takePending(): Promise<PendingWatchRecordingStart | undefined> {
    try {
      const store = await preferences.getPreferences(this.context, PREFERENCES_NAME);
      const requestIdValue = await store.get(PENDING_REQUEST_ID_KEY, '');
      const createdAtValue = await store.get(PENDING_CREATED_AT_KEY, 0);
      const requestId = typeof requestIdValue === 'string' ? requestIdValue : '';
      const createdAt = typeof createdAtValue === 'number' ? createdAtValue : 0;
      if (requestId.length === 0) {
        return undefined;
      }
      await this.clearPending();
      if (createdAt <= 0 || Date.now() - createdAt > PENDING_EXPIRY_MS) {
        return undefined;
      }
      return {
        requestId: requestId,
        createdAt: createdAt
      };
    } catch (error) {
      throw fallbackError(error);
    }
  }

  async clearPending(): Promise<void> {
    try {
      const store = await preferences.getPreferences(this.context, PREFERENCES_NAME);
      await store.delete(PENDING_REQUEST_ID_KEY);
      await store.delete(PENDING_CREATED_AT_KEY);
      await store.flush();
    } catch (error) {
      throw fallbackError(error);
    }
    try {
      await notificationManager.cancel(START_NOTIFICATION_ID);
    } catch (error) {
      // The notification may already have been dismissed by the user's tap.
    }
  }

  private async savePending(pending: PendingWatchRecordingStart): Promise<void> {
    try {
      const store = await preferences.getPreferences(this.context, PREFERENCES_NAME);
      await store.put(PENDING_REQUEST_ID_KEY, pending.requestId);
      await store.put(PENDING_CREATED_AT_KEY, pending.createdAt);
      await store.flush();
    } catch (error) {
      throw fallbackError(error);
    }
  }

  private async publishStartNotification(): Promise<void> {
    try {
      const notificationWantAgent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: this.context.applicationInfo.name,
          moduleName: 'entry',
          abilityName: 'EntryAbility',
          action: WATCH_RECORDING_START_ACTION
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: START_NOTIFICATION_REQUEST_CODE,
        actionFlags: [wantAgent.WantAgentFlags.CANCEL_PRESENT_FLAG]
      });
      const request: notificationManager.NotificationRequest = {
        id: START_NOTIFICATION_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: '手机请求开始录音',
            text: '点此进入手表应用并自动开始录音'
          }
        },
        wantAgent: notificationWantAgent,
        actionButtons: [{
          title: '开始录音',
          wantAgent: notificationWantAgent
        }],
        tapDismissed: true,
        isAlertOnce: true,
        autoDeletedTime: Date.now() + PENDING_EXPIRY_MS
      };
      await notificationManager.publish(request);
    } catch (error) {
      throw fallbackError(error);
    }
  }

  private async vibrateBestEffort(): Promise<void> {
    if (!canIUse('SystemCapability.Sensors.MiscDevice')) {
      return;
    }
    try {
      await vibrator.startVibration({
        type: 'time',
        duration: 350
      }, {
        usage: 'notification'
      });
    } catch (error) {
      // The visible notification remains the authoritative user-action path.
    }
  }
}

function fallbackError(error: Object): Error {
  return error instanceof Error ? error : new Error(JSON.stringify(error));
}
