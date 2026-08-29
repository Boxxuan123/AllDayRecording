import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { SymbolGlyphModifier, uiMaterial } from '@kit.ArkUI';
import { PhoneDeveloperPage } from './PhoneDeveloperPage';
import { PhoneHomePage } from './PhoneHomePage';
import { PhoneRecordingHistoryPage } from './PhoneRecordingHistoryPage';
import { PhoneRecordingViewModel } from './PhoneRecordingViewModel';
import { PhoneSettingsPage } from './PhoneSettingsPage';

const PHONE_DEVELOPER_ROUTE: string = 'phoneDeveloper';

class PhoneDeveloperRouteParams {
}

@Component
export struct PhoneRootPage {
  @State private viewModel: PhoneRecordingViewModel = new PhoneRecordingViewModel();
  @State private selectedTab: number = 0;
  private tabsController: TabsController = new TabsController();
  private navStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.viewModel.start(context);
  }

  aboutToDisappear(): void {
    this.viewModel.stop();
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
  private destination(name: string, _param: Object) {
    if (name === PHONE_DEVELOPER_ROUTE) {
      NavDestination() {
        PhoneDeveloperPage({ viewModel: this.viewModel })
      }
      .title('开发者界面')
      .backgroundColor($r('app.color.page_background'))
    }
  }

  @Builder
  private tabContents() {
    TabContent() {
      PhoneHomePage({ viewModel: this.viewModel })
    }
    .tabBar(this.bottomTabStyle($r('app.string.tab_home'), $r('sys.symbol.house_fill')))

    TabContent() {
      PhoneRecordingHistoryPage({ viewModel: this.viewModel })
    }
    .tabBar(this.bottomTabStyle($r('app.string.tab_recordings'), $r('sys.symbol.waveform')))

    TabContent() {
      PhoneSettingsPage({
        viewModel: this.viewModel,
        onOpenDeveloper: (): void => {
          this.navStack.pushPath({
            name: PHONE_DEVELOPER_ROUTE,
            param: new PhoneDeveloperRouteParams()
          });
        }
      })
    }
    .tabBar(this.bottomTabStyle($r('app.string.tab_settings'), $r('sys.symbol.gearshape')))
  }

  @Builder
  private shell() {
    if (deviceInfo.apiAvailable('26.0.0')) {
      Tabs({ barPosition: BarPosition.End, controller: this.tabsController, index: this.selectedTab }) {
        this.tabContents();
      }
      .barHeight(64)
      .onChange((index: number): void => {
        this.selectedTab = index;
      })
      .barOverlap(true)
      .vertical(false)
      .barMode(BarMode.Fixed)
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
      .width('100%')
      .height('100%')
    } else {
      Tabs({ barPosition: BarPosition.End, controller: this.tabsController, index: this.selectedTab }) {
        this.tabContents();
      }
      .barHeight(64)
      .onChange((index: number): void => {
        this.selectedTab = index;
      })
      .barOverlap(true)
      .vertical(false)
      .barMode(BarMode.Fixed)
      .barBackgroundColor(Color.Transparent)
      .barBackgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .width('100%')
      .height('100%')
    }
  }

  build() {
    Navigation(this.navStack) {
      this.shell();
    }
    .hideTitleBar(true)
    .navDestination(this.destination)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
  }
}
