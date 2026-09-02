import { formatRecordingDuration, formatRecordingReceivedAt, formatRecordingSize } from 'common';
import { PhoneV3Reminder, PhoneV3SessionCard } from '../domain/PhoneV3Models';

export function phoneV3SessionTitle(session: PhoneV3SessionCard): string {
  return formatRecordingReceivedAt(session.startedAt);
}

export function phoneV3SessionMeta(session: PhoneV3SessionCard): string {
  const duration = session.durationMs > 0 ? formatRecordingDuration(session.durationMs) : '时长待同步';
  const size = session.sizeBytes > 0 ? formatRecordingSize(session.sizeBytes) : '电脑投影';
  return `${duration} · ${size}`;
}

export function phoneV3WatchStage(session: PhoneV3SessionCard): string {
  return session.localPaths.length > 0 ? `已到手机 · ${session.localPaths.length} 段` : '手机暂无本地音频';
}

export function phoneV3ComputerStage(session: PhoneV3SessionCard): string {
  if (session.sessionId.length > 0) {
    return `电脑已入库 · r${session.revision}`;
  }
  if (session.uploadStatus === 'uploaded') {
    return '已上传，等待电脑投影';
  }
  return '仅保存在手机';
}

export function phoneV3ProcessingStage(session: PhoneV3SessionCard): string {
  if (session.processingStatus === 'not_started') {
    return '尚未开始处理';
  }
  const stage = session.processingStage.length > 0 ? session.processingStage : session.processingStatus;
  return `${stage} · ${Math.round(session.processingProgress * 100)}%`;
}

export function phoneV3TranscriptSummary(session: PhoneV3SessionCard): string {
  if (session.utterances.length > 0) {
    return `已生成 ${session.utterances.length} 条转写`;
  }
  if (session.processingStatus === 'running' || session.processingStatus === 'queued') {
    return phoneV3ProcessingStage(session);
  }
  if (session.sessionId.length === 0) {
    return session.uploadStatus === 'uploaded' ? '已上传，等待电脑生成转写' : '仅在手机，尚未同步生成转写';
  }
  return '电脑尚未生成转写';
}

export function phoneV3UpdatedLabel(updatedAt: number): string {
  return updatedAt > 0 ? `更新 ${formatRecordingReceivedAt(updatedAt)}` : '尚无电脑更新时间';
}

export function phoneV3TimelineTime(milliseconds: number): string {
  return formatRecordingDuration(milliseconds);
}

export function phoneV3AbsoluteTime(value: string): string {
  const date = new Date(value);
  const hours = date.getHours().toString().padStart(2, '0');
  const minutes = date.getMinutes().toString().padStart(2, '0');
  const seconds = date.getSeconds().toString().padStart(2, '0');
  return `${hours}:${minutes}:${seconds}`;
}

export function phoneV3ReminderTime(reminder: PhoneV3Reminder): string {
  const timestamp = Date.parse(reminder.scheduledAt);
  return Number.isFinite(timestamp) ? formatRecordingReceivedAt(timestamp) : reminder.scheduledAt;
}

export function phoneV3ReminderState(reminder: PhoneV3Reminder): string {
  if (reminder.status === 'scheduled' && Date.parse(reminder.scheduledAt) <= Date.now()) {
    return '已到提醒时间';
  }
  switch (reminder.status) {
    case 'scheduled': return '待提醒';
    case 'delivered': return '已通知';
    case 'completed': return '已完成';
    case 'cancelled': return '已取消';
    case 'stale': return '证据已变更';
    default: return reminder.status;
  }
}
