import { SymbolGlyphModifier, uiMaterial } from '@kit.ArkUI';
import { PhoneV3SessionCard, PhoneV3Utterance } from '../domain/PhoneV3Models';
import { PhoneV3HomePage } from './PhoneV3HomePage';
import { PhoneV3RemindersPage } from './PhoneV3RemindersPage';
import { PhoneV3RecallPage } from './PhoneV3RecallPage';
import { PhoneV3RecordingListPage } from './PhoneV3RecordingListPage';
import {
  PHONE_V3_FLOATING_TAB_BAR_BOTTOM_MARGIN,
  PHONE_V3_FLOATING_TAB_BAR_HEIGHT
} from './PhoneV3NativeUi';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';

@Component
export struct PhoneV3RootPage {
  onOpenVoice: (reviewId: string, history: boolean) => void = (): void => {};
  onOpenPurity: (reviewId: string, history: boolean) => void = (): void => {};
  onOpenAnnotation: (rows: Array<PhoneV3Utterance>, title: string) => void = (): void => {};
  onOpenAnnotationList: (rows: Array<PhoneV3Utterance>, title: string) => void = (): void => {};
  @ObjectLink viewModel: PhoneV3ViewModel;
  @Prop stateRevision: number = 0;
  @Link selectedTab: number;
  private tabsController: TabsController = new TabsController();
  onOpenReviews: () => void = (): void => {};
  onOpenPeople: () => void = (): void => {};
  onOpenSession: (session: PhoneV3SessionCard) => void = (_session: PhoneV3SessionCard): void => {};
  onOpenComputerTransfer: () => void = (): void => {};
  onOpenSync: () => void = (): void => {};
  onOpenReminders: () => void = (): void => {};
  onOpenDaily: () => void = (): void => {};
  onOpenProcessing: () => void = (): void => {};
  onOpenData: () => void = (): void => {};

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
        PhoneV3HomePage({ viewModel: this.viewModel, stateRevision: this.stateRevision,
          onOpenSession: this.onOpenSession, onOpenReviews: this.onOpenReviews,
          onOpenDaily: this.onOpenDaily, onOpenSync: this.onOpenSync,
          onOpenRecall: (): void => { this.selectedTab = 1; this.tabsController.changeIndex(1); },
          onOpenTasks: (): void => { this.selectedTab = 2; this.tabsController.changeIndex(2); } })
      }.tabBar(this.bottomTabStyle($r('app.string.tab_home'), $r('sys.symbol.house_fill')))
      TabContent() {
        PhoneV3RecallPage({ viewModel: this.viewModel, onOpenSession: this.onOpenSession, onOpenPeople: this.onOpenPeople })
      }.tabBar(this.bottomTabStyle($r('app.string.tab_recall'), $r('sys.symbol.magnifyingglass')))
      TabContent() {
        PhoneV3RemindersPage({ viewModel: this.viewModel, stateRevision: this.stateRevision,
          onOpenSession: this.onOpenSession, onOpenReviews: this.onOpenReviews })
      }.tabBar(this.bottomTabStyle($r('app.string.tab_tasks'), $r('sys.symbol.checkmark_circle_fill')))
      TabContent() {
        PhoneV3RecordingListPage({ viewModel: this.viewModel, stateRevision: this.stateRevision,
          onOpenSession: this.onOpenSession, onOpenBackupIssues: this.onOpenComputerTransfer })
      }.tabBar(this.bottomTabStyle($r('app.string.tab_recordings'), $r('sys.symbol.waveform')))
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

    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
