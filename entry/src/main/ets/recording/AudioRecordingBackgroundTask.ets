import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';

export class AudioRecordingBackgroundTask {
  private context: common.UIAbilityContext;
  private requestCode: number;
  private active: boolean = false;

  constructor(context: common.UIAbilityContext, requestCode: number) {
    this.context = context;
    this.requestCode = requestCode;
  }

  async start(): Promise<void> {
    if (this.active) {
      return;
    }
    if (!canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
      throw new Error('当前手表不支持录音持续任务');
    }
    try {
      const notificationWantAgent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: this.context.applicationInfo.name,
          abilityName: 'EntryAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: this.requestCode,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      await backgroundTaskManager.startBackgroundRunning(
        this.context,
        backgroundTaskManager.BackgroundMode.AUDIO_RECORDING,
        notificationWantAgent
      );
      this.active = true;
    } catch (error) {
      throw backgroundTaskError(error);
    }
  }

  async stop(): Promise<void> {
    if (!this.active) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
    } catch (error) {
      // The system may already have canceled the task.
    } finally {
      this.active = false;
    }
  }
}

function backgroundTaskError(error: Object): Error {
  return error instanceof Error ? error : new Error(JSON.stringify(error));
}
