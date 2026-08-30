import { WatchRootPage } from '../presentation/watch/WatchRootPage';

@Entry
@Component
struct Index {
  build() {
    Column() {
      WatchRootPage();
    }
    .width('100%')
    .height('100%')
  }
}
