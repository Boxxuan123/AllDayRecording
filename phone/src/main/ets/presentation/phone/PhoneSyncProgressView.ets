import { formatRecordingSize } from 'common';
import { PhoneRecordingViewModel } from './PhoneRecordingViewModel';

@Component
export struct PhoneSyncProgressView {
  @ObjectLink viewModel: PhoneRecordingViewModel;

  build() {
    if (this.viewModel.syncState.inProgress || this.viewModel.syncState.fileTransferActive) {
      Column({ space: 7 }) {
        Row({ space: 8 }) {
          Text(this.viewModel.transferStageLabel())
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          Text(`${this.viewModel.syncState.transferPercent}%`)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.brand_primary'))
        }
        .width('100%')

        Progress({ value: this.viewModel.syncState.transferPercent, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(6)
          .color($r('app.color.brand_primary'))
          .backgroundColor($r('app.color.surface_secondary'))

        if (this.viewModel.syncState.transferFileName.length > 0) {
          Text(`${this.viewModel.syncState.transferFileName}${this.viewModel.syncState.transferSize > 0 ?
            ` · ${formatRecordingSize(this.viewModel.syncState.transferredBytes)} / ` +
              formatRecordingSize(this.viewModel.syncState.transferSize) : ''}`)
            .width('100%')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor($r('app.color.surface_progress'))
      .borderRadius(10)
    }
  }
}
