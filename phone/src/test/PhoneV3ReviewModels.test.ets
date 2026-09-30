import { describe, expect, it } from '@ohos/hypium';
import { PhoneV3ReviewItem } from '../main/ets/v3/domain/PhoneV3Models';
import {
  phoneV3ReviewReason,
  phoneV3VoiceCandidates,
  phoneV3VoiceMode,
  phoneV3PendingReviews,
  phoneV3ReviewIsHistory
} from '../main/ets/v3/domain/PhoneV3ReviewModels';

export default function phoneV3ReviewModelsTest() {
  describe('PhoneV3ReviewModels', () => {
    it('blindTruthAppearsInVoiceInboxAndHistoryLeavesPending', 0, () => {
      const clip = '"voice_candidates":[{"prototype_id":"synthetic","audio_available":true,' +
        '"representative_clips":[{"media_id":"synthetic","start_ms":0,"end_ms":8000},' +
        '{"media_id":"synthetic","start_ms":12000,"end_ms":20000}]}]';
      const pending = new PhoneV3ReviewItem('blind:synthetic', 'blind_identity_review', 'normal',
        'synthetic', null, null, null, 'Blind', '', 'blind_identity_review', 2, '', '',
        '{"voice_mode":"blind_identity_review","review_lane":"primary",' + clip + '}');
      const history = new PhoneV3ReviewItem('blind:history', 'blind_identity_review', 'normal',
        'history', 1, null, null, 'Blind', '', 'blind_identity_review', 2, '', '',
        '{"voice_mode":"blind_identity_review","review_lane":"history",' + clip + '}');
      expect(phoneV3PendingReviews([pending, history], 1).length).assertEqual(1);
      expect(phoneV3ReviewIsHistory(history)).assertTrue();
      expect(phoneV3VoiceCandidates(pending)[0].totalMs).assertEqual(16000);
      expect(phoneV3VoiceCandidates(pending)[0].bestScore).assertEqual(null);
    });
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
    it('purityTasksUseExactSourceAudioAndHistoryLeavesPendingInbox', 0, () => {
      const clip = '"voice_candidates":[{"prototype_id":"task-1","session_id":"session",' +
        '"speaker_track_id":"track","person_name":"待听原音","audio_available":true,' +
        '"representative_clips":[{"media_id":"media","start_ms":1250,"end_ms":5750}]}]';
      const pending = new PhoneV3ReviewItem('purity:task-1', 'speaker_profile_purity', 'high',
        'task-1', null, 'session', null, '声纹纯度审核', '', 'speaker_profile_purity', 1,
        '2026-09-28T00:00:00Z', '2026-09-28T00:00:00Z',
        '{"voice_mode":"speaker_profile_purity","review_lane":"primary",' + clip + '}');
      const reviewed = new PhoneV3ReviewItem('purity:task-2', 'speaker_profile_purity', 'high',
        'task-2', 1, 'session', null, '声纹纯度审核', '', 'speaker_profile_purity', 1,
        '2026-09-28T00:00:00Z', '2026-09-28T00:00:01Z',
        '{"voice_mode":"speaker_profile_purity","review_lane":"history",' + clip + '}');
      expect(phoneV3PendingReviews([pending, reviewed], 1).length).assertEqual(1);
      expect(phoneV3ReviewIsHistory(reviewed)).assertTrue();
      expect(phoneV3VoiceCandidates(pending)[0].totalMs).assertEqual(4500);
      expect(phoneV3VoiceCandidates(pending)[0].startMs).assertEqual(1250);
    });
  });
}
