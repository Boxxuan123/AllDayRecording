import { common } from '@kit.AbilityKit';
import { uiMaterial } from '@kit.ArkUI';
import { PhoneRecordingViewModel } from '../../presentation/phone/PhoneRecordingViewModel';
import { PhoneV3SessionCard } from '../domain/PhoneV3Models';
import { PhoneV3CacheConflictsPage } from './PhoneV3CacheConflictsPage';
import { PhoneV3HomePage } from './PhoneV3HomePage';
import { PhoneV3RecordingListPage } from './PhoneV3RecordingListPage';
import { PhoneV3SessionDetailPage } from './PhoneV3SessionDetailPage';
import { PhoneV3SyncCenterPage } from './PhoneV3SyncCenterPage';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';

@Component
export struct PhoneV3RootPage {
  @ObjectLink legacyViewModel: PhoneRecordingViewModel;
  @State private viewModel: PhoneV3ViewModel = new PhoneV3ViewModel();
  @State private selectedTab: number = 0;
  @State private detailOpen: boolean = false;
  onOpenComputerTransfer: () => void = (): void => {};

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.viewModel.start(context, this.legacyViewModel);
  }

  aboutToDisappear(): void {
    this.viewModel.stop();
  }

  private openSession(session: PhoneV3SessionCard): void {
    this.viewModel.selectSession(session);
    this.detailOpen = true;
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
        PhoneV3CacheConflictsPage({ viewModel: this.viewModel })
      }
      .tabBar('缓存')
    }
    .barHeight(62)
    .barOverlap(true)
    .barMode(BarMode.Fixed)
    .onChange((index: number): void => {
      this.selectedTab = index;
    })
    .barFloatingStyle({
      barBottomMargin: 12,
      maskColor: $r('app.color.page_background'),
      systemMaterial: new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        colorInvert: true,
        interactive: true,
        lightEffect: { color: undefined }
      })
    })
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      if (this.detailOpen) {
        PhoneV3SessionDetailPage({
          viewModel: this.viewModel,
          onBack: (): void => {
            this.viewModel.stopPlayback();
            this.detailOpen = false;
          }
        })
      } else {
        this.tabs()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
