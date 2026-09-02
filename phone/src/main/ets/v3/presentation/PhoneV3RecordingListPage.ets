import {
  ExceptionPromptV2,
  MarginTypeV2,
  PromptOptionsV2,
  SymbolGlyphModifier
} from '@kit.ArkUI';
import { PhoneV3SessionCard } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import {
  phoneV3SessionMeta,
  phoneV3SessionTitle
} from './PhoneV3UiFormat';
import { phoneV3ImmersiveMaterial } from './PhoneV3NativeUi';

@Component
export struct PhoneV3RecordingListPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  onOpenSession: (session: PhoneV3SessionCard) => void = (_session: PhoneV3SessionCard): void => {};

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
      this.viewModel.state.error = '无法显示删除确认框，请重试';
    }
  }

  @Builder
  private sessionMenu(session: PhoneV3SessionCard) {
    Menu() {
      MenuItem({ content: this.deleteMenuLabel(session) })
        .enabled(this.viewModel.canDeleteLocalAudio(session) && !this.viewModel.state.busy)
        .onClick((): void => this.confirmDelete(session))
    }
    .backgroundColor($r('app.color.surface_primary'))
    .borderRadius(14)
  }

  @Builder
  private moreButton(session: PhoneV3SessionCard) {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      if (this.viewModel.state.busy) {
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
    .enabled(!this.viewModel.state.busy)
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
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .onClick((): void => this.onOpenSession(session))

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
      Row() {
        Text('录音')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text(`${this.viewModel.state.snapshot.sessions.length} 条`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')

      if (this.viewModel.state.error.length > 0) {
        ExceptionPromptV2({
          options: new PromptOptionsV2({
            marginType: MarginTypeV2.DEFAULT_MARGIN,
            marginTop: 0,
            symbolStyle: new SymbolGlyphModifier($r('sys.symbol.exclamationmark_circle_fill')),
            tip: this.viewModel.state.error,
            actionText: this.viewModel.canRetry() ? '重试' : undefined,
            isShown: true
          }),
          onActionTextClick: (): void => this.viewModel.retryLastAction()
        })
          .width('100%')
      }

      if (this.viewModel.state.snapshot.sessions.length === 0) {
        Column({ space: 14 }) {
          Stack() {
            SymbolGlyph($r('sys.symbol.waveform'))
              .fontSize(38)
              .fontColor([$r('app.color.brand_primary')])
          }
          .width(84)
          .height(84)
          .borderRadius(42)
          .backgroundColor($r('app.color.surface_accent'))
          Text('还没有录音')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text('手表录音接收完成后，会自动出现在这里')
            .width('100%')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
        }
          .width('100%')
          .padding({ top: 24 })
      } else {
        List({ space: 8 }) {
          ForEach(this.viewModel.state.snapshot.sessions, (session: PhoneV3SessionCard) => {
            ListItem() { this.row(session) }
          }, (session: PhoneV3SessionCard): string => session.id)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 100 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.page_background'))
  }
}
