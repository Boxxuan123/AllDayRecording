import { describe, expect, it } from '@ohos/hypium';
import { PhoneDailyEvent, phoneDailyMajorEvents } from '../main/ets/v3/domain/PhoneV3DailyModels';

function event(id: string): PhoneDailyEvent {
  return { event_id: id, revision: 1, local_date: '2026-01-01', timezone: 'UTC',
    title: '匿名事件', start_at: '2026-01-01T00:00:00Z', end_at: '2026-01-01T00:00:01Z',
    category: 'conversation', derivation_status: 'active', participants: [],
    evidence_snapshots: [], linked_task_ids: [] };
}

export default function phoneV3DailyModelsTest() {
  describe('PhoneV3DailyModels', () => {
    it('uses server major order instead of chronological cache order', 0, () => {
      const sources: Array<PhoneDailyEvent> = [event('early'), event('later'), event('secondary')];
      const ordered = phoneDailyMajorEvents(sources, [{ event_ids: ['later'] }, { event_ids: ['early'] }]);
      expect(ordered.length).assertEqual(2);
      expect(ordered[0].event_id).assertEqual('later');
      expect(ordered[1].event_id).assertEqual('early');
      expect(sources[0].event_id).assertEqual('early');
      expect(sources.length).assertEqual(3);
    });
    it('skips unavailable or duplicate references without promoting secondary events', 0, () => {
      const ordered = phoneDailyMajorEvents([event('visible'), event('secondary')],
        [{ event_ids: ['missing', 'visible'] }, { event_ids: ['visible'] }]);
      expect(ordered.length).assertEqual(1);
      expect(ordered[0].event_id).assertEqual('visible');
      expect(phoneDailyMajorEvents([event('secondary')], []).length).assertEqual(0);
    });
  });
}
