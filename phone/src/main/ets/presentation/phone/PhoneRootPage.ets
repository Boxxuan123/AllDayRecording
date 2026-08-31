import { common } from '@kit.AbilityKit';
import { HdsNavDestination, HdsNavDestinationTitleMode, HdsNavigation } from '@kit.UIDesignKit';
import { PhoneV3SessionCard } from '../../v3/domain/PhoneV3Models';
import { PhoneV3RootPage } from '../../v3/presentation/PhoneV3RootPage';
import { PhoneV3SessionDetailPage } from '../../v3/presentation/PhoneV3SessionDetailPage';
import { PhoneV3ViewModel } from '../../v3/presentation/PhoneV3ViewModel';
import { PhoneComputerTransferPage } from './PhoneComputerTransferPage';
import { PhoneLegacyReadOnlyPage } from './PhoneLegacyReadOnlyPage';
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

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.viewModel.start(context);
    this.v3ViewModel.start(context, this.viewModel);
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

  @Builder
  private destination(name: string, _param: Object) {
    if (name === PHONE_COMPUTER_TRANSFER_ROUTE) {
      HdsNavDestination() {
        PhoneComputerTransferPage({ recordingViewModel: this.viewModel })
      }
      .titleBar({
        enableComponentSafeArea: true,
        content: { title: { mainTitle: '电脑连接与备份' } }
      })
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.page_background'))
    } else if (name === PHONE_LEGACY_ROUTE) {
      HdsNavDestination() {
        PhoneLegacyReadOnlyPage({ viewModel: this.viewModel })
      }
      .titleBar({
        enableComponentSafeArea: true,
        content: { title: { mainTitle: 'Legacy V2 只读回退' } }
      })
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.page_background'))
    } else if (name === PHONE_V3_SESSION_ROUTE) {
      HdsNavDestination() {
        PhoneV3SessionDetailPage({
          viewModel: this.v3ViewModel,
          onDeleted: (): void => {
            this.navStack.pop();
          }
        })
      }
      .titleBar({
        enableComponentSafeArea: true,
        content: { title: { mainTitle: '会话详情' } }
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
