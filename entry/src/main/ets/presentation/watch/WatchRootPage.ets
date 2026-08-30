import { common } from '@kit.AbilityKit';
import { WatchDeveloperPage } from './WatchDeveloperPage';
import { WatchHomePage } from './WatchHomePage';
import { WatchRecordingViewModel } from './WatchRecordingViewModel';
import { WatchWifiTransferPage } from './WatchWifiTransferPage';

@Component
export struct WatchRootPage {
  @State private viewModel: WatchRecordingViewModel = new WatchRecordingViewModel();
  @State private pageIndex: number = 1;
  private swiperController: SwiperController = new SwiperController();

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.viewModel.start(context);
  }

  onPageShow(): void {
    this.viewModel.onPageShow();
  }

  aboutToDisappear(): void {
    this.viewModel.stop();
  }

  build() {
    Swiper(this.swiperController) {
      WatchDeveloperPage({ viewModel: this.viewModel })
      WatchHomePage({ viewModel: this.viewModel })
      WatchWifiTransferPage({ viewModel: this.viewModel })
    }
    .index(this.pageIndex)
    .indicator(false)
    .loop(false)
    .vertical(true)
    .onChange((index: number): void => {
      this.pageIndex = index;
    })
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
