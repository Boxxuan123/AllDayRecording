import { describe, expect, it } from '@ohos/hypium';
import { PhoneV3ReviewItem } from '../main/ets/v3/domain/PhoneV3Models';
import {
  phoneV3ReviewReason,
  phoneV3VoiceCandidates,
  phoneV3VoiceMode
} from '../main/ets/v3/domain/PhoneV3ReviewModels';

export default function phoneV3ReviewModelsTest() {
  describe('PhoneV3ReviewModels', () => {
    it('missingSourceDisablesAudioWithoutRemovingHistory', 0, () => {
      const item = new PhoneV3ReviewItem('r', 'voice_identity', 'normal', 'c', null, null, 'p',
        'P', '', 'voice_grant_management', 1, '', '',
        '{"voice_mode":"accepted_grant","voice_candidates":[{"prototype_id":"old",' +
        '"audio_available":false,"audio_unavailable_reason":"原音不可用",' +
        '"representative_clips":[{"media_id":"m","start_ms":0,"end_ms":800},' +
        '{"media_id":"m","start_ms":4500,"end_ms":10000}]}]}');
      const candidate = phoneV3VoiceCandidates(item)[0];
      expect(candidate.hasAudio).assertFalse();
      expect(candidate.windowCount).assertEqual(2);
      expect(candidate.totalMs).assertEqual(6300);
      expect(candidate.unavailableReason).assertEqual('原音不可用');
      expect(phoneV3VoiceMode(item)).assertEqual('accepted_grant');
    });
    it('parsesAndSortsVoiceSamplesWeakestFirst', 0, () => {
      const item = new PhoneV3ReviewItem(
        'voice_identity:cluster:person:primary', 'voice_identity', 'normal',
        'cluster', null, null, 'person', '张同学', '2 条声音共同指向张同学',
        'voice_identity_requires_confirmation', 2,
        '2026-09-02T00:00:00Z', '2026-09-02T00:00:00Z',
        '{"voice_mode":"known_person","voice_candidates":[' +
        '{"prototype_id":"strong","session_id":"session-2","speaker_track_id":"track-2",' +
        '"person_name":"张同学","quality_score":0.92,"best_score":0.91,"score_margin":0.2,' +
        '"audio_available":true,"audition_key":"synthetic-key","review_status":"pending","representative_clips":[' +
        '{"media_id":"media-2","start_ms":2000,"end_ms":5000}]},' +
        '{"prototype_id":"weak","session_id":"session-1","speaker_track_id":"track-1",' +
        '"person_name":"张同学","quality_score":0.82,"best_score":0.72,"score_margin":0.08,' +
        '"audio_available":true,"audition_key":"synthetic-key","review_status":"pending","representative_clips":[' +
        '{"media_id":"media-1","start_ms":1000,"end_ms":3000}]}]}');

      const candidates = phoneV3VoiceCandidates(item);

      expect(phoneV3VoiceMode(item)).assertEqual('known_person');
      expect(candidates.length).assertEqual(2);
      expect(candidates[0].prototypeId).assertEqual('weak');
      expect(candidates[0].hasAudio).assertTrue();
      expect(candidates[0].startMs).assertEqual(1000);
      expect(candidates[0].windowCount).assertEqual(1);
      expect(candidates[0].totalMs).assertEqual(2000);
      expect(candidates[0].auditionKey).assertEqual('synthetic-key');
      expect(phoneV3ReviewReason(item.reason).includes('单独')).assertTrue();
    });
  });
}
