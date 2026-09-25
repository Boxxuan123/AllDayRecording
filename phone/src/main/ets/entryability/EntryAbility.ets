import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'PhoneEntryAbility';

export default class EntryAbility extends UIAbility {
  onBackground(): void { AppStorage.setOrCreate<boolean>('phoneForeground', false); }
  onForeground(): void { AppStorage.setOrCreate<boolean>('phoneForeground', true); }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load Phone root page. Cause: %{public}s',
          JSON.stringify(err));
      }
    });
  }
}
