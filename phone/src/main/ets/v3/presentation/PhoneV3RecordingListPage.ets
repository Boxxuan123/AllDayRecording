import { phoneV3PendingReviews } from '../domain/PhoneV3ReviewModels';
import {
  ExceptionPromptV2,
  MarginTypeV2,
  PromptOptionsV2,
  SymbolGlyphModifier
} from '@kit.ArkUI';
import { PhoneV3SessionCard } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { PHONE_V3_UI_STATE_STORAGE_KEY, PhoneV3UiState } from './PhoneV3UiState';
import {
  phoneV3SessionMeta,
  phoneV3SessionTitle,
  phoneV3TranscriptSummary
} from './PhoneV3UiFormat';
import {
  PHONE_V3_BACKUP_ACTION_CONTENT_END_OFFSET,
  phoneV3ImmersiveMaterial
} from './PhoneV3NativeUi';

@Component
export struct PhoneV3RecordingListPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  @Prop stateRevision: number = 0;
  @State private searchText: string = '';
  @State private filterIndex: number = 0;
  onOpenSession: (session: PhoneV3SessionCard) => void = (_session: PhoneV3SessionCard): void => {};

  private currentUiState(): PhoneV3UiState {
    const state = AppStorage.get<PhoneV3UiState>(PHONE_V3_UI_STATE_STORAGE_KEY);
    return this.stateRevision >= 0 && state !== undefined ? state : new PhoneV3UiState();
  }

  private reviewCount(session: PhoneV3SessionCard): number {
    return phoneV3PendingReviews(this.currentUiState().snapshot.reviewItems).filter((item): boolean =>
      item.sessionId !== null && item.sessionId === session.sessionId).length;
  }

  private visibleSessions(): Array<PhoneV3SessionCard> {
    const search = this.searchText.trim().toLocaleLowerCase();
    return this.currentUiState().snapshot.sessions.filter((session: PhoneV3SessionCard): boolean => {
      if (this.filterIndex === 1 && this.reviewCount(session) === 0) {
        return false;
      }
      if (this.filterIndex === 2 &&
        session.processingStatus !== 'running' && session.processingStatus !== 'queued') {
        return false;
      }
      if (this.filterIndex === 3 && session.sessionId.length > 0) {
        return false;
      }
      if (search.length === 0) {
        return true;
      }
      if (phoneV3SessionTitle(session).toLocaleLowerCase().includes(search) ||
        session.sessionId.toLocaleLowerCase().includes(search) ||
        session.capturedStart.toLocaleLowerCase().includes(search)) {
        return true;
      }
      return session.utterances.some((utterance): boolean =>
        utterance.text.toLocaleLowerCase().includes(search) ||
        (utterance.speakerLabel ?? '').toLocaleLowerCase().includes(search));
    });
  }

  @Builder
  private filterButton(index: number, label: string) {
    Button(label, { type: ButtonType.Normal })
      .layoutWeight(1)
      .height(38)
      .fontSize(13)
      .fontWeight(this.filterIndex === index ? FontWeight.Medium : FontWeight.Regular)
      .fontColor(this.filterIndex === index ? Color.White : $r('app.color.text_secondary'))
      .backgroundColor(this.filterIndex === index ?
        $r('app.color.brand_primary') : Color.Transparent)
      .borderRadius(19)
      .onClick((): void => {
        this.filterIndex = index;
      })
  }

  private storageLabel(session: PhoneV3SessionCard): string {
    if (session.sessionId.length > 0) {
      return '已同步电脑';
    }
    if (session.uploadStatus === 'uploaded') {
      return '等待电脑入库';
    }
    return session.localPaths.length > 0 ? '仅手机' : '无本地音频';
  }

  private deleteMenuLabel(session: PhoneV3SessionCard): string {
    if (this.viewModel.canDeleteLocalAudio(session)) {
      return '删除录音';
    }
    return session.localPaths.length > 0 ? '已同步电脑，不能删除' : '手机没有本地音频';
  }

  private confirmDelete(session: PhoneV3SessionCard): void {
    if (!this.viewModel.canDeleteLocalAudio(session)) {
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
          this.viewModel.deleteLocalAudio(session);
        }
      }, (): void => {});
    } catch (_error) {
      this.viewModel.reportUiError('无法显示删除确认框，请重试');
    }
  }

  @Builder
  private sessionMenu(session: PhoneV3SessionCard) {
    Menu() {
      MenuItem({ content: this.deleteMenuLabel(session) })
        .enabled(this.viewModel.canDeleteLocalAudio(session) && !this.currentUiState().busy)
        .onClick((): void => this.confirmDelete(session))
    }
    .backgroundColor($r('app.color.surface_primary'))
    .borderRadius(14)
  }

  @Builder
  private moreButton(session: PhoneV3SessionCard) {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      if (this.currentUiState().busy && this.viewModel.computerSyncActive &&
        session.uploadStatus !== 'uploaded' &&
        this.viewModel.completedSessionKeys.indexOf(session.sessionKey) < 0) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color($r('app.color.text_secondary'))
      } else {
        Image($r('sys.media.ohos_ic_public_more'))
          .width(20)
          .height(20)
          .fillColor($r('app.color.text_secondary'))
      }
    }
    .width(36)
    .height(36)
    .buttonStyle(ButtonStyleMode.TEXTUAL)
    .accessibilityText('更多录音操作')
    .enabled(!this.currentUiState().busy)
    .bindMenu(this.sessionMenu(session), {
      systemMaterial: phoneV3ImmersiveMaterial()
    })
  }

  @Builder
  private row(session: PhoneV3SessionCard) {
    Row({ space: 8 }) {
      Column({ space: 4 }) {
        Text(phoneV3SessionTitle(session))
          .width('100%')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${phoneV3SessionMeta(session)} · ${this.storageLabel(session)}`)
          .width('100%')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.viewModel.computerSyncActive || this.viewModel.completedSessionKeys.indexOf(session.sessionKey) >= 0) {
          Text(session.uploadStatus === 'uploaded' || this.viewModel.completedSessionKeys.indexOf(session.sessionKey) >= 0 ?
            '已备份完成' : this.viewModel.computerProgress.sessionKey === session.sessionKey ?
            '正在同步此录音' : '等待同步')
            .fontSize(12)
            .fontColor($r('app.color.brand_primary'))
        }
        Text(phoneV3TranscriptSummary(session))
          .width('100%')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .onClick((): void => this.onOpenSession(session))

      if (this.reviewCount(session) > 0) {
        Text(`${this.reviewCount(session)} 待审核`)
          .fontSize(11)
          .fontColor($r('app.color.brand_warning'))
      }

      this.moreButton(session)
    }
    .width('100%')
    .padding({ left: 14, right: 8, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('app.color.surface_primary'))
    .borderRadius(14)
  }

  build() {
    Column({ space: 12 }) {
      TextInput({ text: this.searchText, placeholder: '搜索日期、转写、人物或 Session ID' })
        .width('100%')
        .height(46)
        .fontSize(16)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(14)
        .onChange((value: string): void => {
          this.searchText = value;
        })

      Row({ space: 2 }) {
        this.filterButton(0, '全部')
        this.filterButton(1, '待审核')
        this.filterButton(2, '处理中')
        this.filterButton(3, '仅手机')
      }
      .width('100%')
      .padding(3)
      .borderRadius(22)
      .backgroundColor($r('app.color.surface_secondary'))

      if (this.viewModel.computerProgress.totalFiles > 0) {
        Text(this.currentUiState().message)
          .width('100%').fontSize(12).maxLines(4)
        if (this.viewModel.computerProgress.activeFiles.length > 0) {
          Text('并行文件：\n' + this.viewModel.computerProgress.activeFiles.join('\n'))
            .width('100%').fontSize(11).maxLines(6)
        }
        Progress({ value: this.viewModel.computerProgress.percent(), total: 100, type: ProgressType.Linear })
          .width('100%')
      }
      if (this.currentUiState().error.length > 0) {
        ExceptionPromptV2({
          options: new PromptOptionsV2({
            marginType: MarginTypeV2.DEFAULT_MARGIN,
            marginTop: 0,
            symbolStyle: new SymbolGlyphModifier($r('sys.symbol.exclamationmark_circle_fill')),
            tip: this.currentUiState().error,
            actionText: this.viewModel.canRetry() ? '重试' : undefined,
            isShown: true
          }),
          onActionTextClick: (): void => this.viewModel.retryLastAction()
        })
          .width('100%')
      }

      if (this.visibleSessions().length === 0) {
        Column({ space: 12 }) {
          Stack() {
            SymbolGlyph(this.currentUiState().snapshot.sessions.length === 0 ?
              $r('sys.symbol.waveform') : $r('sys.symbol.magnifyingglass'))
              .fontSize(32)
              .fontColor([$r('app.color.brand_primary')])
          }
          .width(68)
          .height(68)
          .borderRadius(34)
          .backgroundColor($r('app.color.surface_accent'))
          Text(this.currentUiState().snapshot.sessions.length === 0 ? '还没有录音' : '没有匹配的录音')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.currentUiState().snapshot.sessions.length === 0 ?
            '手表录音接收完成后，会自动出现在这里' : '可以换一个关键词或筛选条件')
            .width('100%')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
          if (this.currentUiState().snapshot.sessions.length > 0) {
            Button('清除搜索和筛选', { type: ButtonType.Capsule })
              .height(40)
              .margin({ top: 4 })
              .buttonStyle(ButtonStyleMode.TEXTUAL)
              .onClick((): void => {
                this.searchText = '';
                this.filterIndex = 0;
              })
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 28, bottom: 28 })
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(20)
      } else {
        List({ space: 8 }) {
          ForEach(this.visibleSessions(), (session: PhoneV3SessionCard) => {
            ListItem() { this.row(session) }
          }, (session: PhoneV3SessionCard): string => session.id)
        }
        .width('100%')
        .layoutWeight(1)
        .contentEndOffset(PHONE_V3_BACKUP_ACTION_CONTENT_END_OFFSET)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 8 })
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Start)
    .align(Alignment.TopStart)
    .backgroundColor($r('app.color.page_background'))
  }
}
