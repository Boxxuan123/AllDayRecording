import { SymbolGlyphModifier, uiMaterial } from '@kit.ArkUI';
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
  private tabsController: TabsController = new TabsController();
  onOpenSession: (session: PhoneV3SessionCard) => void = (_session: PhoneV3SessionCard): void => {};
  onOpenComputerTransfer: () => void = (): void => {};

  private openSession(session: PhoneV3SessionCard): void {
    this.onOpenSession(session);
  }

  private bottomTabStyle(label: Resource, symbol: Resource): BottomTabBarStyle {
    const normal = new SymbolGlyphModifier(symbol)
      .fontColor([$r('app.color.text_secondary')]);
    const selected = new SymbolGlyphModifier(symbol)
      .fontColor([$r('app.color.brand_primary')]);
    return new BottomTabBarStyle({ normal: normal, selected: selected }, label)
      .labelStyle({
        selectedColor: $r('app.color.brand_primary'),
        unselectedColor: $r('app.color.text_secondary')
      });
  }

  @Builder
  private tabs() {
    Tabs({ barPosition: BarPosition.End, controller: this.tabsController, index: this.selectedTab }) {
      TabContent() {
        PhoneV3HomePage({
          viewModel: this.viewModel,
          onOpenSession: (session: PhoneV3SessionCard): void => this.openSession(session)
        })
      }
      .tabBar(this.bottomTabStyle($r('app.string.tab_home'), $r('sys.symbol.house_fill')))

      TabContent() {
        PhoneV3RecordingListPage({
          viewModel: this.viewModel,
          onOpenSession: (session: PhoneV3SessionCard): void => this.openSession(session)
        })
      }
      .tabBar(this.bottomTabStyle($r('app.string.tab_recordings'), $r('sys.symbol.waveform')))

      TabContent() {
        PhoneV3SyncCenterPage({
          viewModel: this.viewModel,
          onOpenComputerConnection: (): void => this.onOpenComputerTransfer()
        })
      }
      .tabBar(this.bottomTabStyle($r('app.string.tab_sync'), $r('sys.symbol.arrow_2_circlepath')))

      TabContent() {
        PhoneV3CacheConflictsPage({ viewModel: this.viewModel })
      }
      .tabBar(this.bottomTabStyle($r('app.string.tab_more'), $r('sys.symbol.gearshape')))
    }
    .barHeight(62)
    .barOverlap(true)
    .barMode(BarMode.Fixed)
    .divider(null)
    .barFloatingStyle({
      barBottomMargin: 14,
      maskColor: $r('app.color.page_background'),
      systemMaterial: new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        colorInvert: true,
        interactive: true,
        lightEffect: { color: undefined }
      })
    })
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
