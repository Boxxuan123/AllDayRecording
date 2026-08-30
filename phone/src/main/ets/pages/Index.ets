import { PhoneRootPage } from '../presentation/phone/PhoneRootPage';

@Entry
@Component
struct Index {
  build() {
    Column() {
      PhoneRootPage();
    }
    .width('100%')
    .height('100%')
  }
}
