import { describe, expect, it } from '@ohos/hypium';
import { PhoneV3AnnotationIndex } from '../main/ets/v3/domain/PhoneV3AnnotationIndex';
import { PhoneV3SessionCard, PhoneV3Utterance } from '../main/ets/v3/domain/PhoneV3Models';

function utterance(id: string, revision: number = 1): PhoneV3Utterance {
  return new PhoneV3Utterance(id, 's', null, null, null, null, '', '', '{}',
    0, 1000, '', '', id, id, revision, 'active', '{}');
}
function session(rows: Array<PhoneV3Utterance>): PhoneV3SessionCard {
  return new PhoneV3SessionCard('s', 's', '', '', '', 0, '', '', '', 0, 1, 0,
    [], 0, 0, '', '', '', 0, rows);
}
export default function annotationIndexTest() {
  describe('PhoneV3AnnotationIndex', () => {
    it('reuses_rows_for_unchanged_snapshot_with_large_group', 0, () => {
      const all: Array<PhoneV3Utterance> = [];
      for (let i = 0; i < 10000; i++) { all.push(utterance(`u${i}`)); }
      const targets = all.slice(100, 360);
      const sessions = [session(all)];
      const index = new PhoneV3AnnotationIndex();
      index.setTargets(targets);
      expect(index.update(sessions)).assertTrue();
      expect(index.rows.length).assertEqual(260);
      const rows = index.rows;
      index.setTargets(targets.slice());
      for (let i = 0; i < 100; i++) { expect(index.update(sessions)).assertFalse(); }
      expect(index.rows === rows).assertTrue();
    });
    it('refreshes_revisions_and_removes_missing_targets', 0, () => {
      const index = new PhoneV3AnnotationIndex();
      index.setTargets([utterance('a'), utterance('b')]);
      index.update([session([utterance('a'), utterance('b')])]);
      index.update([session([utterance('a', 2), utterance('other')])]);
      expect(index.rows.length).assertEqual(1);
      expect(index.rows[0].revision).assertEqual(2);
      index.setTargets([utterance('other')]);
      expect(index.update([session([utterance('other')])])).assertTrue();
      expect(index.rows[0].utteranceId).assertEqual('other');
    });
  });
}
