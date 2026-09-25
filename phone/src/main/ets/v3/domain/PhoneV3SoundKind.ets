export const PHONE_V3_SOUND_KINDS: Array<string> = ['speech', 'live_speech', 'non_speech', 'unintelligible', 'background_speech', 'overlapping_speech', 'remote_speech', 'media_speech'];
export function phoneV3SoundKindLabel(kind: string): string {
  switch (kind) {
    case 'live_speech': return '现场实际对话';
    case 'overlapping_speech': return '内容清楚但多人重叠';
    case 'remote_speech': return '远程实际互动';
    case 'media_speech': return '确定是媒体播放';
    case 'non_speech': return '非人声／噪声';
    case 'unintelligible': return '人声听不清';
    case 'background_speech': return '背景人声／电视声';
    default: return '正常发言';
  }
}
interface SoundEvidence { sound_kind?: string; }
export function phoneV3SoundKind(evidenceJson: string): string {
  const evidence = JSON.parse(evidenceJson) as SoundEvidence;
  return evidence.sound_kind ?? 'speech';
}
