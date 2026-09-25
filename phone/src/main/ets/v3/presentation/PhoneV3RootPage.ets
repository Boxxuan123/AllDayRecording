import { SymbolGlyphModifier, uiMaterial } from '@kit.ArkUI';
import { motion } from '@kit.MultimodalAwarenessKit';
import { PhoneV3SessionCard, PhoneV3Utterance } from '../domain/PhoneV3Models';
import { PhoneV3HomePage } from './PhoneV3HomePage';
import { PhoneV3MorePage } from './PhoneV3MorePage';
import { PhoneV3PeoplePage } from './PhoneV3PeoplePage';
import { PhoneV3RecordingListPage } from './PhoneV3RecordingListPage';
import { PhoneV3ReviewInboxPage } from './PhoneV3ReviewInboxPage';
import {
  PHONE_V3_BACKUP_ACTION_BOTTOM_MARGIN,
  PHONE_V3_BACKUP_ACTION_HEIGHT,
  PHONE_V3_FLOATING_TAB_BAR_BOTTOM_MARGIN,
  PHONE_V3_FLOATING_TAB_BAR_HEIGHT,
  phoneV3ImmersiveMaterial
} from './PhoneV3NativeUi';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';

@Component
export struct PhoneV3RootPage {
  onOpenVoice: (reviewId: string, history: boolean) => void = (): void => {};
  onOpenAnnotation: (rows: Array<PhoneV3Utterance>, title: string) => void = (): void => {};
  onOpenAnnotationList: (rows: Array<PhoneV3Utterance>, title: string) => void = (): void => {};
  @ObjectLink viewModel: PhoneV3ViewModel;
  @Prop stateRevision: number = 0;
  @Link selectedTab: number;
  @State private backupActionOnLeft: boolean = false;
  private tabsController: TabsController = new TabsController();
  private holdingHandSubscribed: boolean = false;
  private holdingHandChanged: Callback<motion.HoldingHandStatus> =
    (status: motion.HoldingHandStatus): void => {
      this.backupActionOnLeft = status === motion.HoldingHandStatus.LEFT_HAND_HELD;
    };
  onOpenSession: (session: PhoneV3SessionCard) => void = (_session: PhoneV3SessionCard): void => {};
  onOpenComputerTransfer: () => void = (): void => {};
  onOpenSync: () => void = (): void => {};
  onOpenReminders: () => void = (): void => {};
  onOpenProcessing: () => void = (): void => {};
  onOpenData: () => void = (): void => {};

  aboutToAppear(): void {
    this.subscribeToHoldingHand();
  }

  aboutToDisappear(): void {
    this.unsubscribeFromHoldingHand();
  }

  private subscribeToHoldingHand(): void {
    try {
      motion.on('holdingHandChanged', this.holdingHandChanged);
      this.holdingHandSubscribed = true;
    } catch (_error) {
      this.holdingHandSubscribed = false;
      this.backupActionOnLeft = false;
    }
  }

  private unsubscribeFromHoldingHand(): void {
    if (!this.holdingHandSubscribed) {
      return;
    }
    try {
      motion.off('holdingHandChanged', this.holdingHandChanged);
    } catch (_error) {
    }
    this.holdingHandSubscribed = false;
  }

  private openSession(session: PhoneV3SessionCard): void {
    this.onOpenSession(session);
  }

  private showsBackupAction(): boolean {
    return this.selectedTab >= 1 && this.selectedTab <= 3;
  }

  @Builder
  private backupAction() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      if (this.viewModel.busy) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(Color.White)
      } else {
        SymbolGlyph($r('sys.symbol.cloud_and_arrow_up'))
          .fontSize(23)
          .fontColor([Color.White])
      }
    }
    .width(PHONE_V3_BACKUP_ACTION_HEIGHT)
    .height(PHONE_V3_BACKUP_ACTION_HEIGHT)
    .systemMaterial(phoneV3ImmersiveMaterial())
    .enabled(!this.viewModel.busy && this.viewModel.snapshot.paired)
    .opacity(this.viewModel.snapshot.paired ? 1 : 0.55)
    .accessibilityText(this.viewModel.busy ? '正在备份到电脑' : '备份到电脑')
    .onClick((): void => this.viewModel.synchronize())
  }

  @Builder
  private handedBackupAction() {
    Column() {
      this.backupAction()
    }
    .width('100%')
    .height('100%')
    .padding({
      left: 20,
      right: 20,
      bottom: PHONE_V3_BACKUP_ACTION_BOTTOM_MARGIN
    })
    .justifyContent(FlexAlign.End)
    .alignItems(this.backupActionOnLeft ? HorizontalAlign.Start : HorizontalAlign.End)
    .animation({ duration: 320, curve: Curve.EaseInOut })
    .hitTestBehavior(HitTestMode.Transparent)
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
          stateRevision: this.stateRevision,
          onOpenSession: (session: PhoneV3SessionCard): void => this.openSession(session),
          onOpenReviews: (): void => {
            this.selectedTab = 2;
            this.tabsController.changeIndex(2);
          }
        })
      }
      .tabBar(this.bottomTabStyle($r('app.string.tab_home'), $r('sys.symbol.house_fill')))

      TabContent() {
        PhoneV3RecordingListPage({
          viewModel: this.viewModel,
          stateRevision: this.stateRevision,
          onOpenSession: (session: PhoneV3SessionCard): void => this.openSession(session)
        })
      }
      .tabBar(this.bottomTabStyle($r('app.string.tab_recordings'), $r('sys.symbol.waveform')))

      TabContent() {
        PhoneV3ReviewInboxPage({
          onOpenVoice: this.onOpenVoice,
          viewModel: this.viewModel,
          stateRevision: this.stateRevision,
          onOpenSession: (session: PhoneV3SessionCard): void => this.openSession(session)
        })
      }
      .tabBar(this.bottomTabStyle($r('app.string.tab_reviews'), $r('sys.symbol.checkmark_circle_fill')))

      TabContent() {
        PhoneV3PeoplePage({
          onOpenAnnotation: this.onOpenAnnotationList,
          viewModel: this.viewModel,
          stateRevision: this.stateRevision,
          onOpenSession: (session: PhoneV3SessionCard): void => this.openSession(session),
          onOpenReviews: (): void => {
            this.selectedTab = 2;
            this.tabsController.changeIndex(2);
          }
        })
      }
      .tabBar(this.bottomTabStyle($r('app.string.tab_people'), $r('sys.symbol.person_2_fill')))

      TabContent() {
        PhoneV3MorePage({
          viewModel: this.viewModel,
          stateRevision: this.stateRevision,
          onOpenSync: (): void => this.onOpenSync(),
          onOpenReminders: (): void => this.onOpenReminders(),
          onOpenProcessing: (): void => this.onOpenProcessing(),
          onOpenComputerConnection: (): void => this.onOpenComputerTransfer(),
          onOpenData: (): void => this.onOpenData()
        })
      }
      .tabBar(this.bottomTabStyle($r('app.string.tab_more'), $r('sys.symbol.ellipsis_circle')))
    }
    .barHeight(PHONE_V3_FLOATING_TAB_BAR_HEIGHT)
    .barOverlap(true)
    .barMode(BarMode.Fixed)
    .divider(null)
    .barFloatingStyle({
      barBottomMargin: PHONE_V3_FLOATING_TAB_BAR_BOTTOM_MARGIN,
      maskColor: $r('app.color.page_background'),
      adaptToHandedness: true,
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
    Stack({ alignContent: Alignment.TopStart }) {
      this.tabs()
      if (this.showsBackupAction()) {
        this.handedBackupAction()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
