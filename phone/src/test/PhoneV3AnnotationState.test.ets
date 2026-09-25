import { describe, expect, it } from '@ohos/hypium';
import { PhoneV3Utterance, PhoneV3SessionCard, PhoneV3Conflict } from '../main/ets/v3/domain/PhoneV3Models';
import { phoneV3AnnotationState } from '../main/ets/v3/domain/PhoneV3AnnotationState';
import { applyLocalAnnotations, applyAnnotationConflicts, PhoneV3LocalAnnotation } from '../main/ets/v3/domain/PhoneV3LocalAnnotation';
import { PhonePendingOperation } from '../main/ets/v3/data/PhoneSyncProjection';

function row(evidence: string = '{}'): PhoneV3Utterance {
  return new PhoneV3Utterance('u', 's', null, '模型姓名', null, null, '', '', '{}',
    0, 1000, '', '', '正文', '正文', 2, 'active', evidence);
}
function sessions(value: PhoneV3Utterance): Array<PhoneV3SessionCard> {
  return [new PhoneV3SessionCard('s', 's', '', '', '', 0, '', '', '', 0, 1, 0, [], 0, 0, '', '', '', 0, [value])];
}
function operation(): PhonePendingOperation {
  const payload: PhoneV3LocalAnnotation = { selections: [{ utterance_id: 'u', revision: 1, text: '旧正文', speaker_label: '' }], person_name: '合成人物甲', person_id: 'p' };
  return { operation_id: 'op', kind: 'speaker.assign', base_revision: null, attempt_count: 0,
    payload: payload };
}
export default function annotationStateTest() {
  describe('PhoneV3AnnotationState', () => {
    it('model_and_default_kind_are_not_decisions', 0, () => {
      expect(phoneV3AnnotationState(row()).done).assertFalse();
      expect(phoneV3AnnotationState(row('{"sound_kind":"speech"}')).done).assertFalse();
    });
    it('local_receipt_projection_and_cleanup_keep_completion', 0, () => {
      const value = row();
      const op = operation();
      applyLocalAnnotations(sessions(value), [op]);
      expect(phoneV3AnnotationState(value).done).assertTrue();
      expect(phoneV3AnnotationState(value).sync).assertEqual('已在手机保存·待同步到电脑');
      op.applied_revision = 3;
      const restarted = row();
      applyLocalAnnotations(sessions(restarted), [op]);
      expect(phoneV3AnnotationState(restarted).sync).assertEqual('电脑已接收，结果更新中');
      const projected = row('{"person_annotation":{"person_id":"p","state":"active"}}');
      applyLocalAnnotations(sessions(projected), []);
      expect(phoneV3AnnotationState(projected).done).assertTrue();
      expect(phoneV3AnnotationState(projected).sync).assertEqual('已同步');
    });
    it('sound_fact_is_independent_and_review_takes_priority', 0, () => {
      const value = row('{"sound_kind":"non_speech","annotation_fact_ids":{"sound":["f"]},"annotation_outdated":["person"]}');
      expect(phoneV3AnnotationState(value).review).assertTrue();
      expect(phoneV3AnnotationState(value).done).assertFalse();
      expect(phoneV3AnnotationState(value).result).assertContain('非人声');
      expect(phoneV3AnnotationState(row('{"sound_kind":"speech","annotation_fact_ids":{"sound":["f"]}}')).done).assertTrue();
    });
    it('conflicts_use_exact_selection_ids_and_preserve_local_choice', 0, () => {
      const value = row();
      const group = sessions(value);
      applyAnnotationConflicts(group, [new PhoneV3Conflict('op', 'speaker.assign', 'rejected', '{}', 1,
        '{"selections":[{"utterance_id":"other"}],"person_name":"u"}')]);
      expect(phoneV3AnnotationState(value).review).assertFalse();
      applyAnnotationConflicts(group, [new PhoneV3Conflict('op', 'speaker.assign', 'conflict', '{}', 1,
        JSON.stringify(operation().payload))]);
      expect(phoneV3AnnotationState(value).review).assertTrue();
      expect(value.annotationPersonId).assertEqual('p');
    });
    it('network_failure_keeps_saved_and_source_change_requires_review', 0, () => {
      const value = row();
      const op = operation();
      op.last_error = 'offline';
      applyLocalAnnotations(sessions(value), [op]);
      expect(phoneV3AnnotationState(value).done).assertTrue();
      expect(phoneV3AnnotationState(value).sync).assertContain('同步失败');
      value.status = 'superseded';
      expect(phoneV3AnnotationState(value).review).assertTrue();
    });
  });
}
