import { PhoneV3SessionCard } from '../domain/PhoneV3Models';
import { PhoneV3CacheConflictsPage } from './PhoneV3CacheConflictsPage';
import { PhoneV3HomePage } from './PhoneV3HomePage';
import { PhoneV3RecordingListPage } from './PhoneV3RecordingListPage';
import { PhoneV3SyncCenterPage } from './PhoneV3SyncCenterPage';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';

@Component
export struct PhoneV3RootPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  @State private selectedTab: number = 0;
  onOpenSession: (session: PhoneV3SessionCard) => void = (_session: PhoneV3SessionCard): void => {};
  onOpenComputerTransfer: () => void = (): void => {};
  onOpenLegacy: () => void = (): void => {};

  private openSession(session: PhoneV3SessionCard): void {
    this.onOpenSession(session);
  }

  @Builder
  private tabs() {
    Tabs({ barPosition: BarPosition.End, index: this.selectedTab }) {
      TabContent() {
        PhoneV3HomePage({
          viewModel: this.viewModel,
          onOpenSession: (session: PhoneV3SessionCard): void => this.openSession(session)
        })
      }
      .tabBar('首页')

      TabContent() {
        PhoneV3RecordingListPage({
          viewModel: this.viewModel,
          onOpenSession: (session: PhoneV3SessionCard): void => this.openSession(session)
        })
      }
      .tabBar('录音')

      TabContent() {
        PhoneV3SyncCenterPage({
          viewModel: this.viewModel,
          onOpenComputerConnection: (): void => this.onOpenComputerTransfer()
        })
      }
      .tabBar('同步')

      TabContent() {
        PhoneV3CacheConflictsPage({
          viewModel: this.viewModel,
          onOpenLegacy: (): void => this.onOpenLegacy()
        })
      }
      .tabBar('缓存')
    }
    .barHeight(62)
    .barOverlap(true)
    .barMode(BarMode.Fixed)
    .onChange((index: number): void => {
      this.selectedTab = index;
    })
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() { this.tabs() }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
