import { common } from '@kit.AbilityKit';
import {
  hdsMaterial,
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  HdsNavigation,
  HdsNavigationMenuItemOptions,
  HdsNavigationTitleMode,
  TitleBarStyleOptions
} from '@kit.UIDesignKit';
import { PhoneV3SessionCard } from '../../v3/domain/PhoneV3Models';
import { PhoneV3CacheConflictsPage } from '../../v3/presentation/PhoneV3CacheConflictsPage';
import { PhoneV3DataPage } from '../../v3/presentation/PhoneV3DataPage';
import { PhoneV3ProcessingCenterPage } from '../../v3/presentation/PhoneV3ProcessingCenterPage';
import { PhoneV3RemindersPage } from '../../v3/presentation/PhoneV3RemindersPage';
import { PhoneV3RootPage } from '../../v3/presentation/PhoneV3RootPage';
import { PhoneV3SessionDetailPage } from '../../v3/presentation/PhoneV3SessionDetailPage';
import { PhoneV3SyncCenterPage } from '../../v3/presentation/PhoneV3SyncCenterPage';
import { phoneV3ImmersiveMaterial } from '../../v3/presentation/PhoneV3NativeUi';
import { phoneV3SessionTitle } from '../../v3/presentation/PhoneV3UiFormat';
import { PhoneV3ViewModel } from '../../v3/presentation/PhoneV3ViewModel';
import { PhoneV3DeviceRuntime } from '../../v3/runtime/PhoneV3DeviceRuntime';
import { PhoneV3DeviceRuntimeAdapter } from '../../v3/runtime/PhoneV3DeviceRuntimeAdapter';
import { PhoneComputerTransferPage } from './PhoneComputerTransferPage';

const PHONE_COMPUTER_TRANSFER_ROUTE: string = 'phoneComputerTransfer';
const PHONE_V3_SESSION_ROUTE: string = 'phoneV3SessionDetail';
const PHONE_V3_SYNC_ROUTE: string = 'phoneV3Sync';
const PHONE_V3_CONFLICTS_ROUTE: string = 'phoneV3Conflicts';
const PHONE_V3_REMINDERS_ROUTE: string = 'phoneV3Reminders';
const PHONE_V3_PROCESSING_ROUTE: string = 'phoneV3Processing';
const PHONE_V3_DATA_ROUTE: string = 'phoneV3Data';

class PhoneComputerTransferRouteParams {
}

class PhoneV3SessionRouteParams {
  session: PhoneV3SessionCard;
  title: string;

  constructor(session: PhoneV3SessionCard) {
    this.session = session;
    this.title = phoneV3SessionTitle(session);
  }
}

class PhoneV3SecondaryRouteParams {
}

@Component
export struct PhoneRootPage {
  @State private deviceRuntime: PhoneV3DeviceRuntime = new PhoneV3DeviceRuntime();
  @State private v3ViewModel: PhoneV3ViewModel = new PhoneV3ViewModel();
  @State private v3StateRevision: number = 0;
  @State private selectedMainTab: number = 0;
  @StorageLink('phoneForeground') @Watch('foregroundChanged') private foreground: boolean = true;
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

  private mainTitleText(): string {
    if (this.selectedMainTab === 0) {
      return '全天录音';
    }
    if (this.selectedMainTab === 1) {
      return '录音';
    }
    if (this.selectedMainTab === 2) {
      return '审核';
    }
    if (this.selectedMainTab === 3) {
      return '人物';
    }
    return '更多';
  }

  private mainMenuItems(): Array<HdsNavigationMenuItemOptions> {
    if (this.selectedMainTab === 0) {
      return [{
        content: {
          icon: $r('sys.symbol.arrow_2_circlepath'),
          label: '同步与备份',
          action: (): void => this.openSecondary(PHONE_V3_SYNC_ROUTE)
        }
      }];
    }
    return [];
  }

  private foregroundChanged(): void {
    if (!this.foreground) { this.v3ViewModel.stopPlayback(); }
  }

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.v3ViewModel.setStateChangeListener((): void => {
      this.v3StateRevision += 1;
    });
    this.deviceRuntime.start(context);
    this.v3ViewModel.start(context, new PhoneV3DeviceRuntimeAdapter(this.deviceRuntime));
  }

  aboutToDisappear(): void {
    this.v3ViewModel.stop();
    this.deviceRuntime.stop();
  }

  private openComputerTransfer(): void {
    this.navStack.pushPath({
      name: PHONE_COMPUTER_TRANSFER_ROUTE,
      param: new PhoneComputerTransferRouteParams()
    });
  }

  private openV3Session(session: PhoneV3SessionCard): void {
    const current = this.v3ViewModel.resolveCurrentSession(session);
    this.v3ViewModel.selectSession(current);
    this.navStack.pushPath({
      name: PHONE_V3_SESSION_ROUTE,
      param: new PhoneV3SessionRouteParams(current)
    });
  }

  private openSecondary(name: string): void {
    this.navStack.pushPath({
      name: name,
      param: new PhoneV3SecondaryRouteParams()
    });
  }

  private v3DeleteMenuLabel(session: PhoneV3SessionCard): string {
    if (this.v3ViewModel.canDeleteLocalAudio(session)) {
      return '删除录音';
    }
    return session.localPaths.length > 0 ? '已同步电脑，不能删除' : '手机没有本地音频';
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
      this.v3ViewModel.reportUiError('无法显示删除确认框，请重试');
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
      this.v3ViewModel.reportUiError('无法显示更多操作，请重试');
    }
  }

  @Builder
  private destination(name: string, param: Object) {
    if (name === PHONE_COMPUTER_TRANSFER_ROUTE) {
      HdsNavDestination() {
        PhoneComputerTransferPage()
      }
      .titleBar({
        enableComponentSafeArea: true,
        content: { title: { mainTitle: '电脑连接' } },
        style: this.immersiveTitleBarStyle()
      })
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.page_background'))
    } else if (name === PHONE_V3_SYNC_ROUTE) {
      HdsNavDestination() {
        PhoneV3SyncCenterPage({
          viewModel: this.v3ViewModel,
          onOpenComputerConnection: (): void => this.openComputerTransfer(),
          onOpenConflicts: (): void => this.openSecondary(PHONE_V3_CONFLICTS_ROUTE)
        })
      }
      .titleBar({
        enableComponentSafeArea: true,
        content: { title: { mainTitle: '同步与备份' } },
        style: this.immersiveTitleBarStyle()
      })
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.page_background'))
    } else if (name === PHONE_V3_CONFLICTS_ROUTE) {
      HdsNavDestination() {
        PhoneV3CacheConflictsPage({ viewModel: this.v3ViewModel })
      }
      .titleBar({
        enableComponentSafeArea: true,
        content: { title: { mainTitle: '同步问题' } },
        style: this.immersiveTitleBarStyle()
      })
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.page_background'))
    } else if (name === PHONE_V3_REMINDERS_ROUTE) {
      HdsNavDestination() {
        PhoneV3RemindersPage({
          viewModel: this.v3ViewModel,
          onOpenSession: (session: PhoneV3SessionCard): void => this.openV3Session(session)
        })
      }
      .titleBar({
        enableComponentSafeArea: true,
        content: { title: { mainTitle: '提醒' } },
        style: this.immersiveTitleBarStyle()
      })
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.page_background'))
    } else if (name === PHONE_V3_PROCESSING_ROUTE) {
      HdsNavDestination() {
        PhoneV3ProcessingCenterPage({
          viewModel: this.v3ViewModel,
          onOpenSession: (session: PhoneV3SessionCard): void => this.openV3Session(session)
        })
      }
      .titleBar({
        enableComponentSafeArea: true,
        content: { title: { mainTitle: '转写与处理' } },
        style: this.immersiveTitleBarStyle()
      })
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.page_background'))
    } else if (name === PHONE_V3_DATA_ROUTE) {
      HdsNavDestination() {
        PhoneV3DataPage({
          viewModel: this.v3ViewModel,
          onOpenConflicts: (): void => this.openSecondary(PHONE_V3_CONFLICTS_ROUTE)
        })
      }
      .titleBar({
        enableComponentSafeArea: true,
        content: { title: { mainTitle: '存储与数据安全' } },
        style: this.immersiveTitleBarStyle()
      })
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.page_background'))
    } else if (name === PHONE_V3_SESSION_ROUTE) {
      HdsNavDestination() {
        PhoneV3SessionDetailPage({
          viewModel: this.v3ViewModel,
          stateRevision: this.v3StateRevision,
          routeSession: (param as PhoneV3SessionRouteParams).session
        })
      }
      .titleBar({
        enableComponentSafeArea: true,
        content: {
          title: { mainTitle: (param as PhoneV3SessionRouteParams).title },
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
        stateRevision: this.v3StateRevision,
        selectedTab: $selectedMainTab,
        onOpenSession: (session: PhoneV3SessionCard): void => this.openV3Session(session),
        onOpenComputerTransfer: (): void => this.openComputerTransfer(),
        onOpenSync: (): void => this.openSecondary(PHONE_V3_SYNC_ROUTE),
        onOpenReminders: (): void => this.openSecondary(PHONE_V3_REMINDERS_ROUTE),
        onOpenProcessing: (): void => this.openSecondary(PHONE_V3_PROCESSING_ROUTE),
        onOpenData: (): void => this.openSecondary(PHONE_V3_DATA_ROUTE)
      })
    }
    .titleBar({
      enableComponentSafeArea: true,
      content: {
        title: {
          mainTitle: this.mainTitleText()
        },
        menu: {
          maxCount: 1,
          value: this.mainMenuItems()
        }
      },
      style: this.immersiveTitleBarStyle()
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(true)
    .hideTitleBar(false)
    .navDestination(this.destination)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
  }
}
