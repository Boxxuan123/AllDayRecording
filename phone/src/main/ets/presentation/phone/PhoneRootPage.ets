import { common } from '@kit.AbilityKit';
import {
  hdsMaterial,
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  HdsNavigation,
  TitleBarStyleOptions
} from '@kit.UIDesignKit';
import { PhoneV3SessionCard } from '../../v3/domain/PhoneV3Models';
import { PhoneV3RootPage } from '../../v3/presentation/PhoneV3RootPage';
import { PhoneV3SessionDetailPage } from '../../v3/presentation/PhoneV3SessionDetailPage';
import { phoneV3ImmersiveMaterial } from '../../v3/presentation/PhoneV3NativeUi';
import { phoneV3SessionTitle } from '../../v3/presentation/PhoneV3UiFormat';
import { PhoneV3ViewModel } from '../../v3/presentation/PhoneV3ViewModel';
import { PhoneComputerTransferPage } from './PhoneComputerTransferPage';
import { PhoneLegacyReadOnlyPage } from './PhoneLegacyReadOnlyPage';
import { PhoneRecordingV3DeviceAdapter } from './PhoneRecordingV3DeviceAdapter';
import { PhoneRecordingViewModel } from './PhoneRecordingViewModel';

const PHONE_COMPUTER_TRANSFER_ROUTE: string = 'phoneComputerTransfer';
const PHONE_LEGACY_ROUTE: string = 'phoneLegacyReadOnly';
const PHONE_V3_SESSION_ROUTE: string = 'phoneV3SessionDetail';

class PhoneComputerTransferRouteParams {
}

class PhoneLegacyRouteParams {
}

class PhoneV3SessionRouteParams {
  sessionId: string;

  constructor(sessionId: string) {
    this.sessionId = sessionId;
  }
}

@Component
export struct PhoneRootPage {
  @State private viewModel: PhoneRecordingViewModel = new PhoneRecordingViewModel();
  @State private v3ViewModel: PhoneV3ViewModel = new PhoneV3ViewModel();
  private navStack: NavPathStack = new NavPathStack();

  private immersiveTitleBarStyle(): TitleBarStyleOptions {
    return {
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
      },
      thermoCtrl: true
    };
  }

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.viewModel.start(context);
    this.v3ViewModel.start(context, new PhoneRecordingV3DeviceAdapter(this.viewModel));
  }

  aboutToDisappear(): void {
    this.v3ViewModel.stop();
    this.viewModel.stop();
  }

  private openComputerTransfer(): void {
    this.navStack.pushPath({
      name: PHONE_COMPUTER_TRANSFER_ROUTE,
      param: new PhoneComputerTransferRouteParams()
    });
  }

  private openLegacy(): void {
    this.navStack.pushPath({
      name: PHONE_LEGACY_ROUTE,
      param: new PhoneLegacyRouteParams()
    });
  }

  private openV3Session(session: PhoneV3SessionCard): void {
    this.v3ViewModel.selectSession(session);
    this.navStack.pushPath({
      name: PHONE_V3_SESSION_ROUTE,
      param: new PhoneV3SessionRouteParams(session.id)
    });
  }

  private v3DeleteMenuLabel(session: PhoneV3SessionCard): string {
    if (this.v3ViewModel.canDeleteLocalAudio(session)) {
      return '删除录音';
    }
    return session.localPaths.length > 0 ? '已同步电脑，不能删除' : '手机没有本地音频';
  }

  private v3SessionTitle(): string {
    const session = this.v3ViewModel.selectedSession();
    return session === undefined ? '录音' : phoneV3SessionTitle(session);
  }

  private confirmDeleteV3Session(session: PhoneV3SessionCard): void {
    if (!this.v3ViewModel.canDeleteLocalAudio(session)) {
      return;
    }
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '删除手机本地音频？',
        message: '这条录音尚未同步到电脑。删除后无法恢复。',
        buttons: [
          { text: '取消', color: $r('app.color.text_secondary') },
          { text: '删除', color: $r('app.color.brand_danger') }
        ]
      }).then((result): void => {
        if (result.index === 1) {
          this.v3ViewModel.deleteLocalAudio(session, (): void => {
            this.navStack.pop();
          });
        }
      }, (): void => {});
    } catch (_error) {
      this.v3ViewModel.state.error = '无法显示删除确认框，请重试';
    }
  }

  private showV3SessionMenu(): void {
    const session = this.v3ViewModel.selectedSession();
    if (session === undefined) {
      return;
    }
    const canDelete = this.v3ViewModel.canDeleteLocalAudio(session);
    try {
      this.getUIContext().getPromptAction().showActionMenu({
        title: '更多操作',
        buttons: [{
          text: this.v3DeleteMenuLabel(session),
          color: canDelete ? $r('app.color.brand_danger') : $r('app.color.text_secondary')
        }],
        systemMaterial: phoneV3ImmersiveMaterial()
      }).then((result): void => {
        if (result.index === 0 && canDelete) {
          this.confirmDeleteV3Session(session);
        }
      }, (): void => {});
    } catch (_error) {
      this.v3ViewModel.state.error = '无法显示更多操作，请重试';
    }
  }

  @Builder
  private destination(name: string, _param: Object) {
    if (name === PHONE_COMPUTER_TRANSFER_ROUTE) {
      HdsNavDestination() {
        PhoneComputerTransferPage()
      }
      .titleBar({
        enableComponentSafeArea: true,
        content: { title: { mainTitle: '电脑连接与备份' } },
        style: this.immersiveTitleBarStyle()
      })
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.page_background'))
    } else if (name === PHONE_LEGACY_ROUTE) {
      HdsNavDestination() {
        PhoneLegacyReadOnlyPage({ viewModel: this.viewModel })
      }
      .titleBar({
        enableComponentSafeArea: true,
        content: { title: { mainTitle: 'Legacy V2 只读回退' } },
        style: this.immersiveTitleBarStyle()
      })
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.page_background'))
    } else if (name === PHONE_V3_SESSION_ROUTE) {
      HdsNavDestination() {
        PhoneV3SessionDetailPage({ viewModel: this.v3ViewModel })
      }
      .titleBar({
        enableComponentSafeArea: true,
        content: {
          title: { mainTitle: this.v3SessionTitle() },
          menu: {
            maxCount: 1,
            value: [{
              content: {
                icon: $r('sys.media.ohos_ic_public_more'),
                label: '更多',
                action: (): void => this.showV3SessionMenu()
              }
            }]
          }
        },
        style: this.immersiveTitleBarStyle()
      })
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.page_background'))
    }
  }

  build() {
    HdsNavigation(this.navStack) {
      PhoneV3RootPage({
        viewModel: this.v3ViewModel,
        onOpenSession: (session: PhoneV3SessionCard): void => this.openV3Session(session),
        onOpenComputerTransfer: (): void => this.openComputerTransfer(),
        onOpenLegacy: (): void => this.openLegacy()
      })
    }
    .hideTitleBar(true)
    .navDestination(this.destination)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
  }
}
