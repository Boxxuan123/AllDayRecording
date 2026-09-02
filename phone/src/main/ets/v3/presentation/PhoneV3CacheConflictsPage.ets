import { formatRecordingReceivedAt } from 'common';
import { ChipV2 } from '@kit.ArkUI';
import { PhoneV3Conflict } from '../domain/PhoneV3Models';
import { phoneV3StatusChip } from './PhoneV3NativeUi';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';

@Component
export struct PhoneV3CacheConflictsPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  onOpenLegacy: () => void = (): void => {};

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Column({ space: 4 }) {
          Text('更多')
            .width('100%')
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('离线数据、异常记录与兼容工具')
            .width('100%')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 10 }) {
          Row() {
            Text('本地数据安全')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            ChipV2({ chipV2Options: phoneV3StatusChip('离线可用') })
          }
            .width('100%')
          Text('电脑断开时，手机上的录音仍然可以查看和播放。')
            .width('100%')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
          Row({ space: 8 }) {
            Text(`会话 ${this.viewModel.state.snapshot.sessions.length}`)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
            Text(`待备份 ${this.viewModel.state.snapshot.sync.pendingOperations}`)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
            Text(`异常 ${this.viewModel.state.snapshot.conflicts.length}`)
              .fontSize(12)
              .fontColor(this.viewModel.state.snapshot.conflicts.length > 0 ?
                $r('app.color.brand_warning') : $r('app.color.text_secondary'))
          }
            .width('100%')
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(16)

        Text('同步异常')
          .width('100%')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        if (this.viewModel.state.snapshot.conflicts.length === 0) {
          Text('当前没有需要处理的同步异常')
            .width('100%')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .padding(16)
            .backgroundColor($r('app.color.surface_primary'))
            .borderRadius(12)
        } else {
          ForEach(this.viewModel.state.snapshot.conflicts, (conflict: PhoneV3Conflict) => {
            Column({ space: 6 }) {
              Text(`${conflict.status} · ${conflict.kind}`)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text(formatRecordingReceivedAt(conflict.createdAt))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
              Text(conflict.errorJson)
                .width('100%')
                .fontSize(12)
                .fontColor($r('app.color.brand_danger'))
                .maxLines(4)
            }
            .width('100%')
            .padding(14)
            .alignItems(HorizontalAlign.Start)
            .backgroundColor($r('app.color.surface_primary'))
            .borderRadius(12)
          }, (conflict: PhoneV3Conflict): string => conflict.operationId)
        }

        Column({ space: 8 }) {
          Text('旧版数据查看')
            .width('100%')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text('用于核对 V2 时期的本地录音。该入口只能查看和试听，不会修改数据。')
            .width('100%')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
          Button('查看 V2 旧版录音', { type: ButtonType.Capsule })
            .width('100%')
            .height(46)
            .buttonStyle(ButtonStyleMode.NORMAL)
            .onClick((): void => this.onOpenLegacy())
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(16)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 106 })
      .alignItems(HorizontalAlign.Start)
    }
    .align(Alignment.TopStart)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
