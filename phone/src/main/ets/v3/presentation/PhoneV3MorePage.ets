import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { PHONE_V3_UI_STATE_STORAGE_KEY, PhoneV3UiState } from './PhoneV3UiState';
import { PHONE_V3_FLOATING_TAB_BAR_CONTENT_END_OFFSET } from './PhoneV3NativeUi';

@Component
export struct PhoneV3MorePage {
  viewModel: PhoneV3ViewModel = new PhoneV3ViewModel();
  @Prop stateRevision: number = 0;
  onOpenSync: () => void = (): void => {};
  onOpenReminders: () => void = (): void => {};
  onOpenProcessing: () => void = (): void => {};
  onOpenComputerConnection: () => void = (): void => {};
  onOpenData: () => void = (): void => {};

  private currentUiState(): PhoneV3UiState {
    const state = AppStorage.get<PhoneV3UiState>(PHONE_V3_UI_STATE_STORAGE_KEY);
    return this.stateRevision >= 0 && state !== undefined ? state : new PhoneV3UiState();
  }

  private syncDetail(): string {
    const pending = this.currentUiState().snapshot.sync.pendingOperations;
    const problems = this.currentUiState().snapshot.conflicts.length;
    if (pending === 0 && problems === 0) {
      return '已是最新状态';
    }
    if (pending === 0) {
      return `${problems} 项需要处理`;
    }
    if (problems === 0) {
      return `${pending} 项待备份`;
    }
    return `${pending} 项待备份 · ${problems} 项需要处理`;
  }

  private processingDetail(): string {
    const running = this.currentUiState().snapshot.sessions.filter((session): boolean =>
      session.processingStatus === 'running').length;
    return running > 0 ? `${running} 项处理中` : '当前没有处理任务';
  }

  @Builder
  private sectionLabel(title: string) {
    Text(title)
      .width('100%')
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_secondary'))
      .padding({ left: 4, top: 8 })
  }

  @Builder
  private menuRow(symbol: Resource, title: string, detail: string, action: () => void) {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph(symbol)
          .fontSize(21)
          .fontColor([$r('app.color.brand_primary')])
      }
      .width(42)
      .height(42)
      .borderRadius(13)
      .backgroundColor($r('app.color.surface_accent'))
      Column({ space: 4 }) {
        Text(title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text(detail)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(17)
        .fontColor([$r('app.color.text_secondary')])
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.surface_primary'))
    .borderRadius(14)
    .onClick(action)
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        this.sectionLabel('功能')
        this.menuRow($r('sys.symbol.arrow_2_circlepath'), '同步与备份',
          this.syncDetail(), this.onOpenSync)
        this.menuRow($r('sys.symbol.bell'), '提醒',
          `${this.currentUiState().snapshot.reminders.length} 条已确认提醒`, this.onOpenReminders)
        this.menuRow($r('sys.symbol.hourglass'), '转写与处理',
          this.processingDetail(), this.onOpenProcessing)

        this.sectionLabel('设备与数据')
        this.menuRow($r('sys.symbol.computer'), '电脑连接',
          this.currentUiState().snapshot.paired ? '已连接 · 管理电脑' : '扫码连接电脑',
          this.onOpenComputerConnection)
        this.menuRow($r('sys.symbol.checkmark_shield'), '存储与数据安全',
          `${this.currentUiState().snapshot.sessions.length} 条录音 · 原始录音不会自动删除`, this.onOpenData)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8 })
      .alignItems(HorizontalAlign.Start)
    }
    .contentEndOffset(PHONE_V3_FLOATING_TAB_BAR_CONTENT_END_OFFSET)
    .align(Alignment.TopStart)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
