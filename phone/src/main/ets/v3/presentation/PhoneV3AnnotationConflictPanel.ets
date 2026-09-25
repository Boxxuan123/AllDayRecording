import { phoneV3SoundKindLabel } from '../domain/PhoneV3SoundKind';
import { PhoneV3Conflict, PhoneV3Utterance } from '../domain/PhoneV3Models';
import { PhoneV3LocalAnnotation, PhoneV3AnnotationSentence } from '../domain/PhoneV3LocalAnnotation';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';

@Component
export struct PhoneV3AnnotationConflictPanel {
  viewModel: PhoneV3ViewModel = new PhoneV3ViewModel();
  conflict: PhoneV3Conflict = new PhoneV3Conflict('', '', '', '{}', 0);
  @Prop stateRevision: number = 0;
  @State private expanded: boolean = false;
  @State private rows: Array<PhoneV3Utterance> = [];
  @State private page: number = 0;
  @State private loaded: boolean = false;
  private payload: PhoneV3LocalAnnotation = { selections: [], person_name: '' };

  aboutToAppear(): void {
    this.payload = JSON.parse(this.conflict.payloadJson) as PhoneV3LocalAnnotation;
  }

  private open(): void {
    this.expanded = !this.expanded;
    if (this.expanded) {
      this.loaded = false;
      this.viewModel.loadAnnotationConflict(this.payload, (rows): void => { this.rows = rows; this.loaded = true; });
    }
  }

  private current(selection: PhoneV3AnnotationSentence): string {
    const row = this.rows.find((value: PhoneV3Utterance): boolean => value.utteranceId === selection.utterance_id);
    return row === undefined ? '此句已删除或重新转写，需重新选句' :
      `${phoneV3SoundKindLabel(row.soundKind)} · ${row.speakerLabel ?? '未知说话人'} · ${row.text}`;
  }

  build() {
    Column({ space: 8 }) {
      Text('片段标注同步冲突').fontSize(16).fontWeight(FontWeight.Bold)
      Text(`本地选择：${this.payload.person_name} · ${this.payload.selections.length} 句`).fontSize(14)
      Text('本地标注已保留，尚未覆盖电脑结果。请展开核对。').fontSize(12)
      Button(this.expanded ? '收起' : '核对并处理').onClick((): void => this.open())
      if (this.expanded && this.loaded) {
        ForEach(this.payload.selections.slice(this.page * 20, (this.page + 1) * 20),
          (selection: PhoneV3AnnotationSentence) => {
            Column({ space: 4 }) {
              Text(`标注时：${phoneV3SoundKindLabel(selection.sound_kind ?? 'speech')} · ${selection.speaker_label} · ${selection.text}`).fontSize(13)
              Text(`电脑最新：${this.current(selection)}`).fontSize(13)
            }.width('100%').alignItems(HorizontalAlign.Start).padding(8)
          }, (selection: PhoneV3AnnotationSentence): string => selection.utterance_id)
        Row({ space: 8 }) {
          Button('上一页').enabled(this.page > 0).onClick((): void => { this.page -= 1; })
          Text(`${this.page + 1} / ${Math.max(1, Math.ceil(this.payload.selections.length / 20))}`)
          Button('下一页').enabled((this.page + 1) * 20 < this.payload.selections.length)
            .onClick((): void => { this.page += 1; })
        }
        Button('保留本地标注，重新排队同步').width('100%')
          .enabled(this.stateRevision >= 0 && !this.viewModel.annotationSaving && this.rows.length === this.payload.selections.length)
          .onClick((): void => this.viewModel.resolveAnnotationConflict(this.conflict.operationId, true, this.rows))
        Button('采用电脑结果，结束本项审核').width('100%')
          .enabled(this.stateRevision >= 0 && !this.viewModel.annotationSaving)
          .onClick((): void => this.viewModel.resolveAnnotationConflict(this.conflict.operationId, false, this.rows))
      }
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.surface_primary')).borderRadius(16)
  }
}
