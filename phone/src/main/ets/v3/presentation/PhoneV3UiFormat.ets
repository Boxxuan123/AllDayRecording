import { formatRecordingDuration, formatRecordingReceivedAt, formatRecordingSize } from 'common';
import { PhoneV3SessionCard } from '../domain/PhoneV3Models';

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

export function phoneV3UpdatedLabel(updatedAt: number): string {
  return updatedAt > 0 ? `更新 ${formatRecordingReceivedAt(updatedAt)}` : '尚无电脑更新时间';
}

export function phoneV3TimelineTime(milliseconds: number): string {
  return formatRecordingDuration(milliseconds);
}
