import { describe, expect, it } from '@ohos/hypium';
import { PhoneDailyEvent, phoneDailyMajorEvents, phoneDailyDisplayText } from '../main/ets/v3/domain/PhoneV3DailyModels';

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
    it('hides only linked citation groups from headline and overview display', 0, () => {
      const first = '00000000000000000000000001';
      const second = '00000000000000000000000002';
      const references = [first, second];
      const headline = `匿名项目安排（${first}、${second}）`;
      const overview = `讨论备考计划。（${first}） 讨论赛事安排。（${second}）`;
      expect(phoneDailyDisplayText(headline, references)).assertEqual('匿名项目安排');
      expect(phoneDailyDisplayText(overview, references)).assertEqual('讨论备考计划。 讨论赛事安排。');
      expect(headline).assertEqual(`匿名项目安排（${first}、${second}）`);
      expect(references.length).assertEqual(2);
      expect(references[0]).assertEqual(first);
    });
    it('supports ASCII citation groups and UUID source references', 0, () => {
      const first = '00000000-0000-7000-8000-000000000001';
      const second = '00000000-0000-7000-8000-000000000002';
      expect(phoneDailyDisplayText(`安排 (${first}, ${second})`, [first, second])).assertEqual('安排');
      expect(phoneDailyDisplayText(`安排（${first}；${second}）`, [first, second])).assertEqual('安排');
    });
    it('preserves meaningful parentheses, numbers and unlinked identifiers', 0, () => {
      const linked = '00000000000000000000000001';
      const other = '00000000000000000000000002';
      const text = `考研（复试）在 2026 年，型号（AB123），另有编号（${other}）。`;
      expect(phoneDailyDisplayText(text, [linked])).assertEqual(text);
      expect(phoneDailyDisplayText(`计划（${linked}，待确认）`, [linked]))
        .assertEqual(`计划（${linked}，待确认）`);
      expect(phoneDailyDisplayText(`计划（${linked}、${other}）`, [linked]))
        .assertEqual(`计划（${linked}、${other}）`);
    });
    it('does not remove source substrings or citations when no source links are available', 0, () => {
      const linked = '00000000000000000000000001';
      expect(phoneDailyDisplayText(`编号（${linked}-suffix）`, [linked]))
        .assertEqual(`编号（${linked}-suffix）`);
      expect(phoneDailyDisplayText(`计划（${linked}）`, [])).assertEqual(`计划（${linked}）`);
      expect(phoneDailyDisplayText('', [linked])).assertEqual('');
    });
  });
}
