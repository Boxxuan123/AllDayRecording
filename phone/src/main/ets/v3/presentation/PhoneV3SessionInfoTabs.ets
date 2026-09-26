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

interface SessionTabOptions { session: PhoneV3SessionCard; }


  @Builder
function PhoneV3SessionOverviewTabStage(options: SessionTabOptions, label: string, value: string) {
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
function PhoneV3SessionOverviewTabMetric(options: SessionTabOptions, label: string, value: string) {
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

@Builder
export function PhoneV3SessionOverviewTab(options: SessionTabOptions) {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        PhoneV3SessionOverviewTabMetric(options, '时长', formatRecordingDuration(options.session.durationMs))
        PhoneV3SessionOverviewTabMetric(options, '转写', options.session.utterances.length.toString())
        PhoneV3SessionOverviewTabMetric(options, '版本', `r${options.session.revision}`)
      }
      .width('100%')
      Column({ space: 12 }) {
        PhoneV3SessionOverviewTabStage(options, '手表录音', phoneV3WatchStage(options.session))
        PhoneV3SessionOverviewTabStage(options, '电脑备份', phoneV3ComputerStage(options.session))
        PhoneV3SessionOverviewTabStage(options, '转写处理', phoneV3ProcessingStage(options.session))
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


function PhoneV3SessionSpeakersTabSummaries(options: SessionTabOptions): Array<PhoneV3SessionSpeakerSummary> {
    const values: Map<string, PhoneV3SessionSpeakerSummary> =
      new Map<string, PhoneV3SessionSpeakerSummary>();
    for (let index = 0; index < options.session.utterances.length; index += 1) {
      const utterance = options.session.utterances[index];
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

function PhoneV3SessionSpeakersTabIdentityLabel(options: SessionTabOptions, value: string): string {
    if (value === 'self') {
      return '本人';
    }
    if (value === 'not_self') {
      return '非本人';
    }
    return '身份未知';
  }

  @Builder
function PhoneV3SessionSpeakersTabSpeakerRow(options: SessionTabOptions, summary: PhoneV3SessionSpeakerSummary) {
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
        Text(`${PhoneV3SessionSpeakersTabIdentityLabel(options, summary.identity)} · ${summary.count} 条发言`)
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

@Builder
export function PhoneV3SessionSpeakersTab(options: SessionTabOptions) {
    Column({ space: 10 }) {
      if (PhoneV3SessionSpeakersTabSummaries(options).length === 0) {
        Text('当前会话还没有可显示的说话人轨道。')
          .width('100%')
          .padding(16)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.surface_primary'))
          .borderRadius(14)
      } else {
        ForEach(PhoneV3SessionSpeakersTabSummaries(options), (summary: PhoneV3SessionSpeakerSummary) => {
          PhoneV3SessionSpeakersTabSpeakerRow(options, summary)
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


function PhoneV3SessionEvidenceTabCorrectedCount(options: SessionTabOptions): number {
    return options.session.utterances.filter((utterance: PhoneV3Utterance): boolean =>
      utterance.text !== utterance.originalText || utterance.status === 'corrected').length;
  }

  @Builder
function PhoneV3SessionEvidenceTabEvidenceRow(options: SessionTabOptions, label: string, value: string) {
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

@Builder
export function PhoneV3SessionEvidenceTab(options: SessionTabOptions) {
    Column({ space: 12 }) {
      Column({ space: 2 }) {
        PhoneV3SessionEvidenceTabEvidenceRow(options, '手机原始录音', `${options.session.localPaths.length} 个文件`)
        PhoneV3SessionEvidenceTabEvidenceRow(options, '原始录音大小', formatRecordingSize(options.session.sizeBytes))
        PhoneV3SessionEvidenceTabEvidenceRow(options, '电脑记录', options.session.sessionId.length > 0 ? '已建立' : '尚未创建')
        PhoneV3SessionEvidenceTabEvidenceRow(options, '当前版本', options.session.revision.toString())
        PhoneV3SessionEvidenceTabEvidenceRow(options, '转写修订', `${PhoneV3SessionEvidenceTabCorrectedCount(options)} 条`)
        PhoneV3SessionEvidenceTabEvidenceRow(options, '处理状态', phoneV3ProcessingStage(options.session))
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
