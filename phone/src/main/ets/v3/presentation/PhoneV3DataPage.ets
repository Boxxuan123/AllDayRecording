import { formatRecordingSize } from 'common';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';

@Component
export struct PhoneV3DataPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  onOpenConflicts: () => void = (): void => {};

  private totalBytes(): number {
    return this.viewModel.snapshot.sessions.reduce((total: number, session): number =>
      total + session.sizeBytes, 0);
  }

  @Builder
  private metric(label: string, value: string) {
    Column({ space: 5 }) {
      Text(value)
        .fontSize(23)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .layoutWeight(1)
    .padding(14)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.surface_primary'))
    .borderRadius(14)
  }

  @Builder
  private protectionRow(text: string) {
    Row({ space: 9 }) {
      SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
        .fontSize(17)
        .fontColor([$r('app.color.brand_primary')])
      Text(text)
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Row({ space: 10 }) {
          this.metric('本机录音', formatRecordingSize(this.totalBytes()))
          this.metric('录音条数', this.viewModel.snapshot.sessions.length.toString())
        }
        .width('100%')
        Row({ space: 10 }) {
          this.metric('待备份修改', this.viewModel.snapshot.sync.pendingOperations.toString())
          this.metric('同步问题', this.viewModel.snapshot.conflicts.length.toString())
        }
        .width('100%')

        Column({ space: 11 }) {
          Text('数据保护')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          this.protectionRow('录音和播放无需连接电脑')
          this.protectionRow('未备份的修改会保存在手机上')
          this.protectionRow('手机原始录音不会自动删除')
          this.protectionRow('电脑数据缓存可以重新获取')
          Text('转写和智能处理由电脑完成；电脑离线不会影响手机录音和播放。')
            .width('100%')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .padding({ top: 2 })
          Button('查看同步问题', { type: ButtonType.Capsule })
            .width('100%')
            .height(44)
            .enabled(this.viewModel.snapshot.conflicts.length > 0)
            .buttonStyle(ButtonStyleMode.NORMAL)
            .onClick((): void => this.onOpenConflicts())
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(16)
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 10, bottom: 32 })
      .alignItems(HorizontalAlign.Start)
    }
    .align(Alignment.TopStart)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
