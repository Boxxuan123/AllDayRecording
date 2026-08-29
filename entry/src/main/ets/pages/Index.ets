import { deviceInfo } from '@kit.BasicServicesKit';
import { PhoneRootPage } from '../presentation/phone/PhoneRootPage';
import { WatchRootPage } from '../presentation/watch/WatchRootPage';

@Entry
@Component
struct Index {
  private isWearable: boolean = deviceInfo.deviceType === 'wearable';

  build() {
    if (this.isWearable) {
      WatchRootPage();
    } else {
      PhoneRootPage();
    }
  }
}
