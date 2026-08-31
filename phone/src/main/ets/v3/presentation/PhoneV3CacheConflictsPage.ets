import { formatRecordingReceivedAt } from 'common';
import { PhoneV3Conflict } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';

@Component
export struct PhoneV3CacheConflictsPage {
  @ObjectLink viewModel: PhoneV3ViewModel;

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Text('缓存与冲突')
          .width('100%')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        Column({ space: 10 }) {
          Text('离线状态')
            .width('100%')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(`本地会话 ${this.viewModel.state.snapshot.sessions.length} · ` +
            `待提交 ${this.viewModel.state.snapshot.sync.pendingOperations} · ` +
            `冲突 ${this.viewModel.state.snapshot.conflicts.length}`)
            .width('100%')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
          Text('应用重启后会从 phone_v3_projection.db 恢复游标、outbox、冲突与错误；音频文件仍是本地事实源。')
            .width('100%')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(16)

        Text('冲突记录')
          .width('100%')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        if (this.viewModel.state.snapshot.conflicts.length === 0) {
          Text('当前没有待处理冲突')
            .width('100%')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .padding(16)
            .backgroundColor($r('app.color.surface_primary'))
            .borderRadius(12)
        } else {
          ForEach(this.viewModel.state.snapshot.conflicts, (conflict: PhoneV3Conflict) => {
            Column({ space: 6 }) {
              Text(conflict.kind)
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
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 22, bottom: 100 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
