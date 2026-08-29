import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import {
  WATCH_RECORDING_START_ACTION,
  WatchRecordingUiState
} from '../services/WatchRecordingStartFallback';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', 'Ability onCreate action=%{public}s', want.action || '');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', 'Ability onNewWant action=%{public}s', want.action || '');
    if (want.action === WATCH_RECORDING_START_ACTION) {
      WatchRecordingUiState.notifyForegroundRequest();
    }
  }

  onDestroy(): void {
    WatchRecordingUiState.setForeground(false);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      try {
        const colorMode = deviceInfo.deviceType === 'wearable' ?
          ConfigurationConstant.ColorMode.COLOR_MODE_DARK :
          ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
        this.context.getApplicationContext().setColorMode(colorMode);
      } catch (colorModeError) {
        hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s',
          JSON.stringify(colorModeError));
      }
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    WatchRecordingUiState.setForeground(true);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    WatchRecordingUiState.setForeground(false);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
