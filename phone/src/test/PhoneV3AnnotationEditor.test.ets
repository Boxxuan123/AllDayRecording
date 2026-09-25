import { describe, expect, it } from '@ohos/hypium';
import { PhoneV3AnnotationEditor } from '../main/ets/v3/domain/PhoneV3AnnotationEditor';
import { PhoneV3SessionCard, PhoneV3Utterance } from '../main/ets/v3/domain/PhoneV3Models';

function row(id: string, evidence: string = '{}', revision: number = 1): PhoneV3Utterance {
  return new PhoneV3Utterance(id, 's', null, null, null, null, '', '', '{}', 0, 1000, '', '', id, id, revision, 'active', evidence);
}
function group(rows: Array<PhoneV3Utterance>): Array<PhoneV3SessionCard> {
  return [new PhoneV3SessionCard('s', 's', '', '', '', 0, '', '', '', 0, 1, 0, [], 0, 0, '', '', '', 0, rows)];
}
export default function annotationEditorTest() {
  describe('PhoneV3AnnotationEditor', () => {
    it('skip_a_save_b_continue_c_then_offer_skipped_without_marking_done', 0, () => {
      const editor = new PhoneV3AnnotationEditor();
      const rows = [row('a'), row('b'), row('c')];
      editor.open(rows, group(rows));
      editor.move(1);
      expect(editor.current?.utteranceId).assertEqual('b');
      editor.update(group([row('a'), row('b', '{"annotation_fact_ids":{"sound":["f"]}}'), row('c')]));
      editor.saved(['b']);
      expect(editor.current?.utteranceId).assertEqual('c');
      editor.move(1);
      expect(editor.current === undefined).assertTrue();
      expect(editor.pending).assertEqual(2);
      editor.restartPending();
      expect(editor.current?.utteranceId).assertEqual('a');
    });
    it('all_done_scope_opens_results_and_preview_keeps_batch_selection', 0, () => {
      const editor = new PhoneV3AnnotationEditor();
      const rows = [row('a', '{"annotation_fact_ids":{"sound":["f"]}}'), row('b', '{"person_annotation":{"person_id":"p"}}')];
      editor.open(rows, group(rows));
      expect(editor.doneMode).assertTrue();
      editor.open([row('a'), row('b')], group([row('a'), row('b')]));
      editor.setBatch(true); editor.choose(editor.rows[0], true);
      const preview = new PhoneV3AnnotationEditor();
      preview.open([editor.rows[1]], group(editor.rows));
      expect(editor.selectedCount).assertEqual(1);
      expect(editor.batch).assertTrue();
    });
    it('opens_explicit_completed_sentence_and_does_not_select_a_person_for_next', 0, () => {
      const done = row('done', '{"person_annotation":{"person_id":"p"}}');
      const editor = new PhoneV3AnnotationEditor();
      editor.open([done], group([row('other'), done]));
      expect(editor.doneMode).assertTrue();
      expect(editor.current?.utteranceId).assertEqual('done');
      expect(editor.done).assertEqual(1);
    });
    it('thousand_rows_cross_page_search_selection_and_stable_scope', 0, () => {
      const rows: Array<PhoneV3Utterance> = [];
      for (let i = 0; i < 2000; i++) { rows.push(row(`u${i}`)); }
      const editor = new PhoneV3AnnotationEditor();
      editor.open(rows, group(rows));
      editor.setBatch(true);
      editor.selectFiltered();
      editor.page = 99; editor.filter();
      expect(editor.pageRows.length).assertEqual(20);
      expect(editor.selectedCount).assertEqual(2000);
      editor.query = 'u1999'; editor.filter();
      expect(editor.hidden).assertEqual(1999);
      expect(editor.targets().length).assertEqual(2000);
      editor.saved(['u1999']);
      expect(editor.selectedCount).assertEqual(1999);
      expect(editor.page).assertEqual(0);
      editor.switchMode(true);
      expect(editor.batch).assertFalse();
      expect(editor.selectedCount).assertEqual(0);
    });
    it('skip_is_ephemeral_and_refresh_does_not_replace_reviewed_version', 0, () => {
      const original = [row('a'), row('b')];
      const editor = new PhoneV3AnnotationEditor();
      editor.open(original, group(original));
      editor.move(1);
      expect(editor.current?.utteranceId).assertEqual('b');
      expect(editor.pending).assertEqual(2);
      editor.update(group([row('a'), row('b', '{}', 2)]));
      expect(editor.current?.revision).assertEqual(1);
      expect(editor.changed).assertTrue();
      editor.move(1);
      expect(editor.current === undefined).assertTrue();
    });
    it('missing_source_stays_in_scope_as_review_without_replacing_edit_version', 0, () => {
      const editor = new PhoneV3AnnotationEditor();
      const original = row('a', '{"person_annotation":{"person_id":"p"}}');
      editor.open([original], group([original]));
      editor.update(group([]));
      expect(editor.current?.status).assertEqual('active');
      expect(editor.changed).assertTrue();
      expect(editor.done).assertEqual(0);
      expect(editor.pending).assertEqual(1);
      editor.switchMode(false);
      expect(editor.current?.status).assertEqual('stale');
    });
    it('saved_rows_move_between_views_without_changing_target_scope', 0, () => {
      const editor = new PhoneV3AnnotationEditor();
      const original = [row('a'), row('b')];
      editor.open(original, group(original));
      editor.update(group([row('a', '{"person_annotation":{"person_id":"renamed"}}'), row('b')]));
      editor.saved(['a']);
      expect(editor.current?.utteranceId).assertEqual('b');
      expect(editor.done).assertEqual(1);
      editor.update(group([row('a', '{"person_annotation":{"person_id":"renamed"}}'), row('b', '{"annotation_fact_ids":{"sound":["f"]}}')]));
      editor.saved(['b']);
      expect(editor.current === undefined).assertTrue();
      expect(editor.pending).assertEqual(0);
      editor.switchMode(true);
      expect(editor.filtered.length).assertEqual(2);
    });
  });
}
