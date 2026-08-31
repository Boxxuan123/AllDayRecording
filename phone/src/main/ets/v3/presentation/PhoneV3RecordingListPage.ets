import { PhoneV3SessionCard } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import {
  phoneV3ComputerStage,
  phoneV3SessionMeta,
  phoneV3SessionTitle,
  phoneV3UpdatedLabel
} from './PhoneV3UiFormat';

@Component
export struct PhoneV3RecordingListPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  onOpenSession: (session: PhoneV3SessionCard) => void = (_session: PhoneV3SessionCard): void => {};

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
  private row(session: PhoneV3SessionCard) {
    Column({ space: 8 }) {
      Row() {
        Column({ space: 4 }) {
          Text(phoneV3SessionTitle(session))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(phoneV3SessionMeta(session))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .onClick((): void => this.onOpenSession(session))

        if (session.localPaths.length > 0) {
          Button(this.viewModel.canDeleteLocalAudio(session) ? '删除' : '已保护',
          { type: ButtonType.Capsule })
          .height(36)
          .fontSize(12)
          .fontColor(this.viewModel.canDeleteLocalAudio(session) ?
            $r('app.color.brand_danger') : $r('app.color.text_secondary'))
          .backgroundColor($r('app.color.surface_secondary'))
          .enabled(this.viewModel.canDeleteLocalAudio(session) && !this.viewModel.state.busy)
          .accessibilityText(this.viewModel.canDeleteLocalAudio(session) ?
            '删除未同步到电脑的本地音频' : '已同步到电脑，不能删除')
          .onClick((): void => this.confirmDelete(session))
        }

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(18)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width('100%')

      Row({ space: 8 }) {
        Text(session.localPaths.length > 0 ? '可离线播放' : '仅电脑投影')
          .fontSize(12)
          .fontColor(session.localPaths.length > 0 ? $r('app.color.brand_primary') :
            $r('app.color.text_secondary'))
        Text(phoneV3ComputerStage(session))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      Text(phoneV3UpdatedLabel(session.updatedAt))
        .width('100%')
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
      if (session.localPaths.length > 0) {
        Text(this.viewModel.canDeleteLocalAudio(session) ?
          '尚未同步到电脑 · 可删除本地音频' : '已同步到电脑 · 本地音频受保护')
          .width('100%')
          .fontSize(11)
          .fontColor(this.viewModel.canDeleteLocalAudio(session) ?
            $r('app.color.brand_danger') : $r('app.color.brand_success'))
      }
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.surface_primary'))
    .borderRadius(14)
  }

  build() {
    Column({ space: 14 }) {
      Row() {
        Column({ space: 3 }) {
          Text('录音')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('本地音频与电脑状态已合并')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Button('刷新', { type: ButtonType.Capsule })
          .backgroundColor($r('app.color.surface_secondary'))
          .fontColor($r('app.color.text_primary'))
          .onClick((): void => this.viewModel.refresh())
      }
      .width('100%')

      if (this.viewModel.state.error.length > 0) {
        Text(this.viewModel.state.error)
          .width('100%')
          .padding(12)
          .fontSize(13)
          .fontColor($r('app.color.brand_danger'))
          .backgroundColor($r('app.color.surface_primary'))
          .borderRadius(12)
      }

      if (this.viewModel.state.snapshot.sessions.length === 0) {
        Text('手机上还没有录音，Watch 接收完成后会自动显示在这里。')
          .width('100%')
          .layoutWeight(1)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
      } else {
        List({ space: 10 }) {
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
    .padding({ left: 18, right: 18, top: 22, bottom: 90 })
    .backgroundColor($r('app.color.page_background'))
  }
}
