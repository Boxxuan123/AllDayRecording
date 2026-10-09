import { localBuildInfo, diagnosticText, copyDiagnostics, peerBuildReport } from 'common';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { PHONE_V3_UI_STATE_STORAGE_KEY, PhoneV3UiState } from './PhoneV3UiState';
import { PHONE_V3_FLOATING_TAB_BAR_CONTENT_END_OFFSET } from './PhoneV3NativeUi';

@Component
export struct PhoneV3MorePage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  @Prop stateRevision: number = 0;
  @State private aboutVisible: boolean = false;
  @State private showDiagnostics: boolean = false;
  onOpenSync: () => void = (): void => {};
  onOpenReminders: () => void = (): void => {};
  onOpenDaily: () => void = (): void => {};
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

  private peerVersion(component: string): string {
    const report = peerBuildReport(component);
    if (report.build === undefined) { return '尚未收到版本信息'; }
    return report.build.release_version +
      (report.state === 'reported' ? ' · 最近连接' : ' · 离线或信息已过期');
  }

  private buildTime(): string {
    const value = localBuildInfo('phone').built_at;
    if (value === null) { return '未知'; }
    const date = new Date(value);
    return date.getFullYear().toString() + '-' + (date.getMonth() + 1).toString().padStart(2, '0') +
      '-' + date.getDate().toString().padStart(2, '0') + ' ' +
      date.getHours().toString().padStart(2, '0') + ':' + date.getMinutes().toString().padStart(2, '0');
  }

  @Builder
  private diagnosticRow(label: string, value: string) {
    Row({ space: 20 }) {
      Text(label).fontSize(13).fontColor($r('app.color.text_secondary')).width(76)
      Text(value).fontSize(13).fontColor($r('app.color.text_primary'))
        .layoutWeight(1).textAlign(TextAlign.End).copyOption(CopyOptions.LocalDevice)
    }
    .width('100%').padding({ top: 14, bottom: 14 })
  }

  @Builder
  private aboutSheet() {
    Scroll() {
      Column({ space: 20 }) {
        Column({ space: 8 }) {
          Text('AllDay Recording').fontSize(24).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text('版本 ' + localBuildInfo('phone').release_version + ' · 构建 ' +
            (localBuildInfo('phone').build_version ?? '未知'))
            .fontSize(14).fontColor($r('app.color.text_secondary'))
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 8, bottom: 4 })

        Column() {
          this.diagnosticRow('构建时间', this.buildTime())
          Divider().color($r('app.color.surface_accent'))
          this.diagnosticRow('Git 提交', localBuildInfo('phone').git_commit.substring(0, 12))
          Divider().color($r('app.color.surface_accent'))
          this.diagnosticRow('构建状态', localBuildInfo('phone').dirty === true ?
            '包含本地修改' : localBuildInfo('phone').dirty === false ? '已发布构建' : '未知')
        }.width('100%').padding({ left: 16, right: 16 }).borderRadius(16)
          .backgroundColor($r('app.color.surface_primary'))

        Column({ space: 4 }) {
          Text('设备版本').fontSize(13).fontColor($r('app.color.text_secondary'))
            .width('100%')
          Column() {
            this.diagnosticRow('电脑', this.peerVersion('pc-backend'))
            Divider().color($r('app.color.surface_accent'))
            this.diagnosticRow('手表', this.peerVersion('watch'))
          }.width('100%').padding({ left: 16, right: 16 }).borderRadius(16)
            .backgroundColor($r('app.color.surface_primary'))
        }.width('100%').alignItems(HorizontalAlign.Start)

        Button('复制诊断信息', { type: ButtonType.ROUNDED_RECTANGLE })
          .width('100%').height(44).fontSize(14)
          .fontColor($r('app.color.brand_primary')).backgroundColor($r('app.color.surface_accent'))
          .onClick((): void => {
            copyDiagnostics('phone').then((): void => {
              this.getUIContext().getPromptAction().showToast({ message: '诊断信息已复制' });
            }).catch(() => {
              this.getUIContext().getPromptAction().showToast({ message: '复制失败，请展开并长按诊断文字复制' });
            });
          })
        Button(this.showDiagnostics ? '收起原始数据' : '查看原始诊断数据')
          .buttonStyle(ButtonStyleMode.TEXTUAL).width('100%').fontSize(12)
          .fontColor($r('app.color.text_secondary')).onClick((): void => {
            this.showDiagnostics = !this.showDiagnostics;
          })
        if (this.showDiagnostics) {
          Text(diagnosticText('phone')).fontSize(11).fontFamily('monospace')
            .fontColor($r('app.color.text_secondary')).copyOption(CopyOptions.LocalDevice).width('100%')
        }
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 24, right: 24, top: 24, bottom: 32 })
    }.width('100%').height('100%').align(Alignment.TopStart)
      .backgroundColor($r('app.color.page_background'))
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        this.sectionLabel('功能')
        this.menuRow($r('sys.symbol.calendar'), '每日总结', '查看每日事件和原始证据', this.onOpenDaily)
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
        this.menuRow($r('sys.symbol.info_circle'), '关于 AllDay',
          localBuildInfo('phone').release_version + ' · 版本与诊断', (): void => {
            this.showDiagnostics = false;
            this.aboutVisible = true;
          })
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
    .bindSheet($$this.aboutVisible, this.aboutSheet(), { height: SheetSize.LARGE, showClose: true })
  }
}
