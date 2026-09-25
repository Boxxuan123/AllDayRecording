import { DeviceV3AnnotationStatus } from '../../computer/ComputerTransferProtocol';

export function phoneV3SampleStatus(value: DeviceV3AnnotationStatus): string {
  let state = value.processing_status;
  switch (state) {
    case 'queued': state = '样本待处理'; break;
    case 'running': state = '样本处理中'; break;
    case 'retryable': state = '样本处理失败，可重试'; break;
    case 'missing_audio': state = '缺少原音，恢复后重试'; break;
    case 'not_applicable': state = '当前不适用'; break;
    case 'insufficient': state = '证据不足或未采纳'; break;
    case 'candidate': state = '候选待审核'; break;
    case 'accepted_unusable': state = '历史已采纳，当前不可用'; break;
    case 'matching': state = '当前版本可参与匹配'; break;
    case 'processed': state = '处理完毕，尚未满足候选条件'; break;
  }
  let reason = value.processing_reason;
  switch (reason) {
    case 'self_uses_separate_calibrated_library': reason = '本人使用独立校准库，普通标注未接入本人识别'; break;
    case 'source_invalidated': reason = '来源已被纠正、撤权或排除'; break;
    case 'incompatible_model': reason = '历史样本与当前模型不兼容'; break;
    case 'below_person_quality_policy': reason = '未达到人物样本质量门槛'; break;
    case 'awaiting_sample_review': reason = '请到审核页试听并采纳'; break;
    case 'available_to_matching': reason = '通过来源、审核、质量及模型兼容检查'; break;
    case 'no_eligible_person_evidence': reason = '尚无合格的已确认人物声音'; break;
    case 'source_excluded': reason = '声音用途规则排除'; break;
    case 'identity_conflict': case 'sound_conflict': reason = '人工事实冲突待审'; break;
  }
  return `${value.fact_status === 'conflict' ? '人工事实待审' : value.fact_status === 'saved' ? '人物事实已保存' : '尚未确认人物'} · ${state}${reason.length > 0 ? '：' + reason : ''}`;
}
