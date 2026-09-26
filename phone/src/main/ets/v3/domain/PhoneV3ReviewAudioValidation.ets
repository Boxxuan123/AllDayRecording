import { DeviceV3ReviewAudioResponse } from '../../computer/ComputerTransferProtocol';
import { PhoneV3VoiceCandidate } from './PhoneV3ReviewModels';

export function validateReviewSample(response: DeviceV3ReviewAudioResponse, reviewId: string, candidate: PhoneV3VoiceCandidate): void {
  if (response.complete_sample !== true || response.review_id !== reviewId || response.prototype_id !== candidate.prototypeId ||
    !candidate.auditionKey || response.audition_key !== candidate.auditionKey ||
    (candidate.audioContentKey.length > 0 && response.audio_content_key !== candidate.audioContentKey) ||
    response.start_ms !== 0 || response.end_ms !== candidate.totalMs || response.windows === undefined ||
    response.windows.length !== candidate.windowCount || response.windows.some((window, index: number): boolean => {
      const clip = candidate.clips[index];
      return clip === undefined || window.media_id !== clip.media_id || window.start_ms !== clip.start_ms || window.end_ms !== clip.end_ms ||
        window.playback_start_ms !== candidate.clips.slice(0, index).reduce((total: number, previous): number => total + (previous.end_ms ?? 0) - (previous.start_ms ?? 0), 0);
    })) { throw new Error('样本已变化或电脑未提供完整试听，请刷新后重试'); }
}
