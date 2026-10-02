import { PhoneV3ReviewItem } from './PhoneV3Models';

interface SelfReviewContext {
  source_text?: string;
  start_at?: string;
  duration_ms?: number;
  review_action?: string;
}

export class PhoneV3SelfReviewDetail {
  text: string = '';
  time: string = '';
  duration: string = '';
  action: string = '';
}

export function selfReviewDetail(item: PhoneV3ReviewItem): PhoneV3SelfReviewDetail {
  const result = new PhoneV3SelfReviewDetail();
  try {
    const context = JSON.parse(item.contextJson) as SelfReviewContext;
    result.text = context.source_text ?? '';
    result.time = context.start_at ? new Date(context.start_at).toLocaleString() : '录音时间暂不可用';
    result.duration = `${((context.duration_ms ?? 0) / 1000).toFixed(1)} 秒`;
    result.action = context.review_action ?? '';
  } catch (_) {}
  return result;
}
