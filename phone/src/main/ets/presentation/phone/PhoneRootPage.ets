import { common } from '@kit.AbilityKit';
import { ComponentContent, SymbolGlyphModifier, uiMaterial } from '@kit.ArkUI';
import {
  hdsMaterial, HdsNavDestination, HdsNavDestinationTitleMode, HdsNavigation
} from '@kit.UIDesignKit';
import { PhoneDeveloperPage } from './PhoneDeveloperPage';
import { PhoneComputerTransferPage } from './PhoneComputerTransferPage';
import { PhoneHomePage } from './PhoneHomePage';
import { PhoneRecordingHistoryPage } from './PhoneRecordingHistoryPage';
import { PhoneRecordingGroup } from './PhoneRecordingGroups';
import { PhoneRecordingPlaybackPage } from './PhoneRecordingPlaybackPage';
import { PhoneRecordingViewModel } from './PhoneRecordingViewModel';
import { PhoneSettingsPage } from './PhoneSettingsPage';

const PHONE_DEVELOPER_ROUTE: string = 'phoneDeveloper';
const PHONE_COMPUTER_TRANSFER_ROUTE: string = 'phoneComputerTransfer';
const PHONE_RECORDING_PLAYBACK_ROUTE: string = 'phoneRecordingPlayback';
const PHONE_PLAYBACK_MENU_BUTTON_ID: string = 'phone-playback-menu-button';

class PhonePlaybackMenuParams {
  onDelete: () => void;

  constructor(onDelete: () => void) {
    this.onDelete = onDelete;
  }
}

@Builder
function buildPhonePlaybackMenu(params: PhonePlaybackMenuParams) {
  Menu() {
    MenuItem({ content: '删除' })
      .onClick(params.onDelete)
  }
  .backgroundColor($r('app.color.surface_primary'))
  .borderRadius(16)
}

const phonePlaybackMenuBuilder: WrappedBuilder<[PhonePlaybackMenuParams]> =
  wrapBuilder(buildPhonePlaybackMenu);

class PhoneDeveloperRouteParams {
}

class PhoneComputerTransferRouteParams {
}

class PhoneRecordingPlaybackRouteParams {
  groupKey: string;

  constructor(groupKey: string) {
    this.groupKey = groupKey;
  }
}

@Component
export struct PhoneRootPage {
  @State private viewModel: PhoneRecordingViewModel = new PhoneRecordingViewModel();
  @State private selectedTab: number = 0;
  @State private playbackGroupKey: string = '';
  private tabsController: TabsController = new TabsController();
  private navStack: NavPathStack = new NavPathStack();
  private playbackMenuContent: ComponentContent<PhonePlaybackMenuParams> | undefined = undefined;

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

  private confirmPlaybackDelete(): void {
    const group = this.viewModel.recordingGroup(this.playbackGroupKey);
    if (group === undefined) {
      return;
    }
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '删除录音？',
        message: group.recordings.length > 1 ?
          '这条连续录音包含的全部音频都会被删除，且无法恢复。' : '删除后将无法恢复这条录音。',
        buttons: [
          { text: '取消', color: $r('app.color.text_secondary') },
          { text: '删除', color: $r('app.color.brand_danger') }
        ]
      }).then((result): void => {
        if (result.index === 1) {
          this.viewModel.deleteRecordingGroup(group as PhoneRecordingGroup, (): void => {
            this.navStack.pop();
          });
        }
      }, (): void => {
      });
    } catch (error) {
      this.viewModel.status = '无法显示删除确认框，请重试';
    }
  }

  private showPlaybackMenu(): void {
    this.playbackMenuContent = new ComponentContent<PhonePlaybackMenuParams>(
      this.getUIContext(), phonePlaybackMenuBuilder,
      new PhonePlaybackMenuParams((): void => this.confirmPlaybackDelete()));
    this.getUIContext().getPromptAction().openMenu(
      this.playbackMenuContent,
      { id: PHONE_PLAYBACK_MENU_BUTTON_ID },
      {
        systemMaterial: new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.THICK,
          interactive: true,
          lightEffect: {}
        })
      }).then((): void => {
      }, (): void => {
        this.viewModel.status = '无法显示操作菜单，请重试';
      });
  }

  @Builder
  private destination(name: string, _param: Object) {
    if (name === PHONE_DEVELOPER_ROUTE) {
      HdsNavDestination() {
        PhoneDeveloperPage({ viewModel: this.viewModel })
      }
      .titleBar({
        enableComponentSafeArea: true,
        content: {
          title: { mainTitle: '开发者界面' }
        }
      })
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.page_background'))
    } else if (name === PHONE_COMPUTER_TRANSFER_ROUTE) {
      HdsNavDestination() {
        PhoneComputerTransferPage({ recordingViewModel: this.viewModel })
      }
      .titleBar({
        enableComponentSafeArea: true,
        content: {
          title: { mainTitle: '电脑备份' }
        }
      })
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.page_background'))
    } else if (name === PHONE_RECORDING_PLAYBACK_ROUTE) {
      HdsNavDestination() {
        PhoneRecordingPlaybackPage({
          viewModel: this.viewModel,
          groupKey: (_param as PhoneRecordingPlaybackRouteParams).groupKey
        })
      }
      .titleBar({
        enableComponentSafeArea: true,
        style: {
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        },
        content: {
          title: { mainTitle: '录音播放' },
          menu: {
            value: [{
              content: {
                icon: $r('sys.media.ohos_ic_public_more'),
                label: '更多',
                componentId: PHONE_PLAYBACK_MENU_BUTTON_ID,
                isEnabled: this.viewModel.deletingRecordingGroupKey.length === 0,
                action: (): void => this.showPlaybackMenu()
              }
            }]
          }
        }
      })
      .titleMode(HdsNavDestinationTitleMode.MINI)
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
      PhoneRecordingHistoryPage({
        viewModel: this.viewModel,
        onOpenRecording: (groupKey: string): void => {
          this.playbackGroupKey = groupKey;
          this.navStack.pushPath({
            name: PHONE_RECORDING_PLAYBACK_ROUTE,
            param: new PhoneRecordingPlaybackRouteParams(groupKey)
          });
        }
      })
    }
    .tabBar(this.bottomTabStyle($r('app.string.tab_recordings'), $r('sys.symbol.waveform')))

    TabContent() {
      PhoneSettingsPage({
        viewModel: this.viewModel,
        onOpenComputerTransfer: (): void => {
          this.navStack.pushPath({
            name: PHONE_COMPUTER_TRANSFER_ROUTE,
            param: new PhoneComputerTransferRouteParams()
          });
        },
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
  }

  build() {
    HdsNavigation(this.navStack) {
      this.shell();
    }
    .hideTitleBar(true)
    .navDestination(this.destination)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
  }
}
