import { formatRecordingDuration, formatRecordingSize } from 'common';
import { PhoneV3SessionCard, PhoneV3Utterance } from '../domain/PhoneV3Models';
import {
  phoneV3ComputerStage,
  phoneV3ProcessingStage,
  phoneV3WatchStage
} from './PhoneV3UiFormat';

class PhoneV3SessionSpeakerSummary {
  key: string;
  label: string;
  identity: string;
  count: number;

  constructor(key: string, label: string, identity: string, count: number = 0) {
    this.key = key;
    this.label = label;
    this.identity = identity;
    this.count = count;
  }
}

@Component
export struct PhoneV3SessionOverviewTab {
  session: PhoneV3SessionCard = new PhoneV3SessionCard('', '', '', '', '', 0, '', '', '', 0,
    0, 0, [], 0, 0, '', '', '', 0, []);

  @Builder
  private stage(label: string, value: string) {
    Row({ space: 12 }) {
      Text(label)
        .width(106)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text(value)
        .layoutWeight(1)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
  }

  @Builder
  private metric(label: string, value: string) {
    Column({ space: 4 }) {
      Text(value)
        .fontSize(19)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text(label)
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
    }
    .layoutWeight(1)
    .padding({ top: 12, bottom: 12 })
    .backgroundColor($r('app.color.surface_progress'))
    .borderRadius(12)
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        this.metric('时长', formatRecordingDuration(this.session.durationMs))
        this.metric('转写', this.session.utterances.length.toString())
        this.metric('版本', `r${this.session.revision}`)
      }
      .width('100%')
      Column({ space: 12 }) {
        this.stage('手表录音', phoneV3WatchStage(this.session))
        this.stage('电脑备份', phoneV3ComputerStage(this.session))
        this.stage('转写处理', phoneV3ProcessingStage(this.session))
      }
      .width('100%')
      .padding(16)
      .backgroundColor($r('app.color.surface_primary'))
      .borderRadius(16)
      Text('修改会创建新的 revision，原始录音和原始转写不会被覆盖。')
        .width('100%')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

@Component
export struct PhoneV3SessionSpeakersTab {
  session: PhoneV3SessionCard = new PhoneV3SessionCard('', '', '', '', '', 0, '', '', '', 0,
    0, 0, [], 0, 0, '', '', '', 0, []);

  private summaries(): Array<PhoneV3SessionSpeakerSummary> {
    const values: Map<string, PhoneV3SessionSpeakerSummary> =
      new Map<string, PhoneV3SessionSpeakerSummary>();
    for (let index = 0; index < this.session.utterances.length; index += 1) {
      const utterance = this.session.utterances[index];
      const key = utterance.identity === 'self' ? 'self' :
        utterance.speakerTrackId ?? utterance.speakerLabel ?? 'unassigned';
      const label = utterance.identity === 'self' ? '本人' :
        utterance.speakerLabel ?? '未指定说话人';
      const current = values.get(key) ??
        new PhoneV3SessionSpeakerSummary(key, label, utterance.identity);
      current.count += 1;
      values.set(key, current);
    }
    return Array.from(values.values());
  }

  private identityLabel(value: string): string {
    if (value === 'self') {
      return '本人';
    }
    if (value === 'not_self') {
      return '非本人';
    }
    return '身份未知';
  }

  @Builder
  private speakerRow(summary: PhoneV3SessionSpeakerSummary) {
    Row({ space: 12 }) {
      Stack() {
        Text(summary.label.slice(0, 1))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.brand_primary'))
      }
      .width(42)
      .height(42)
      .borderRadius(13)
      .backgroundColor($r('app.color.surface_accent'))
      Column({ space: 4 }) {
        Text(summary.label)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text(`${this.identityLabel(summary.identity)} · ${summary.count} 条发言`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.surface_primary'))
    .borderRadius(14)
  }

  build() {
    Column({ space: 10 }) {
      if (this.summaries().length === 0) {
        Text('当前会话还没有可显示的说话人轨道。')
          .width('100%')
          .padding(16)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.surface_primary'))
          .borderRadius(14)
      } else {
        ForEach(this.summaries(), (summary: PhoneV3SessionSpeakerSummary) => {
          this.speakerRow(summary)
        }, (summary: PhoneV3SessionSpeakerSummary): string => summary.key)
      }
      Text('需要调整身份时，在时间线中打开对应发言并选择“编辑转写”。')
        .width('100%')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

@Component
export struct PhoneV3SessionEvidenceTab {
  session: PhoneV3SessionCard = new PhoneV3SessionCard('', '', '', '', '', 0, '', '', '', 0,
    0, 0, [], 0, 0, '', '', '', 0, []);

  private correctedCount(): number {
    return this.session.utterances.filter((utterance: PhoneV3Utterance): boolean =>
      utterance.text !== utterance.originalText || utterance.status === 'corrected').length;
  }

  @Builder
  private evidenceRow(label: string, value: string) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1)
      Text(value)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
    }
    .width('100%')
    .padding({ top: 9, bottom: 9 })
  }

  build() {
    Column({ space: 12 }) {
      Column({ space: 2 }) {
        this.evidenceRow('手机原始录音', `${this.session.localPaths.length} 个文件`)
        this.evidenceRow('原始录音大小', formatRecordingSize(this.session.sizeBytes))
        this.evidenceRow('电脑记录', this.session.sessionId.length > 0 ? '已建立' : '尚未创建')
        this.evidenceRow('当前版本', this.session.revision.toString())
        this.evidenceRow('转写修订', `${this.correctedCount()} 条`)
        this.evidenceRow('处理状态', phoneV3ProcessingStage(this.session))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      .backgroundColor($r('app.color.surface_primary'))
      .borderRadius(16)
      Text('完整的录音摘要、备份恢复记录和处理历史以电脑端数据为准。')
        .width('100%')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
