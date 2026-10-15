import { RecallResponse, RecallClaim } from '../domain/PhoneHistoryRecall';
// Business result states. Engine notices/count limits remain available in technical details.
export function productRecallAnswer(result:RecallResponse):string{
  if(result.status==='stale'||result.model_status==='stale'){return '原文已发生变化，原先的归纳需要重新核对';}
  if(result.status==='needs_clarification'){return result.answer??'请明确人物或日期后重试';}
  if(result.model_status==='timeout'){return '无法生成归纳：归纳超时。已找到的原文保留在下方，可重试归纳。';}
  if(result.model_status==='failed'){return '无法生成归纳：回答的依据校验未通过。请查看下方原文或重试归纳。';}
  if(result.model_status==='unavailable'){return '无法生成归纳：归纳模型暂不可用。已找到的原文保留在下方。';}
  if(result.model_status==='insufficient'){return result.answer??'现有证据不足，无法生成可靠归纳；请核对本次范围内的原文。';}
  if(result.model_status==='available'){
    const claims=result.claims??[];
    const text=claims.filter((claim:RecallClaim):boolean=>claim.text.trim().length>0&&claim.citations.length>0).map((claim:RecallClaim):string=>claim.kind==='inference'?`推测：${claim.text}`:claim.kind==='statement'?`来源陈述：${claim.text}`:claim.kind==='source_fact'?`来源事实：${claim.text}`:claim.text).join('\n');
    return text.length>0?text:'归纳没有形成有依据的结论，请核对原文。';
  }
  if(result.status==='coverage_insufficient'){return result.answer??'当前来源覆盖不足，不能判断没有聊天。';}
  if(result.status==='not_found'){return result.answer??'当前人物、日期与会话范围未找到记录，不能据此判断没有发生。';}
  if(result.status==='partial'&&(result.evidence?.length??0)===0){return result.answer??'本轮原文未完整取回，请查看来源状态后重试。';}
  return (result.evidence?.length??0)>0?'未请求归纳；以下为本次范围内的原文':'当前范围没有找到相关原文';
}
export function productRecallCoverage(result:RecallResponse):string{
  if((result.coverage??[]).some((line:string):boolean=>line.includes('离线')||line.includes('SOURCE_OFFLINE'))){return '部分来源暂时离线，已保存内容不代表最新状态';}
  if(result.status==='unavailable'||result.source_status==='unavailable'||(result.coverage??[]).some((line:string):boolean=>line.includes('来源未完整取回'))){return '部分来源未成功取回，已有内容不代表最新状态';}
  return result.latest_status_confirmed===false||(result.coverage?.length??0)>0?'结果只覆盖本次可用记录，尚不能确认完整经过或最终进展':'';
}

export function productRecallScope(result:RecallResponse):string{
  const scope=result.scope;if(scope===undefined){return '';}
  const first=scope.sent_from_local??new Date(scope.sent_from*1000).toISOString();
  const last=scope.sent_to_local??new Date(scope.sent_to*1000).toISOString();
  return `实际范围：${first} 至 ${last} · ${scope.timezone??'Asia/Singapore'} · ${scope.person_id.length>0?'已确认人物':'人物未限定'} · ${scope.source}`;
}

export function productRecallRange(result:RecallResponse):string{
  const scope=result.scope;if(scope===undefined){return '';}
  const format=(stamp:number):string=>{const d=new Date(stamp*1000);return `${d.getFullYear()}年${d.getMonth()+1}月${d.getDate()}日 ${d.getHours().toString().padStart(2,'0')}:${d.getMinutes().toString().padStart(2,'0')}`;};
  const source=scope.source==='wechat'?'微信':scope.source==='qq'?'QQ':scope.source==='recording'?'录音':'授权历史';
  return `${scope.target_label!==undefined?scope.target_label+" · ":""}${source} · ${format(scope.sent_from)} 至 ${format(scope.sent_to)}`;
}

export function productRecallClaimLabel(claim:RecallClaim):string{
  return claim.kind==='source_fact'?'来源事实':claim.kind==='statement'?'来源陈述':claim.kind==='quote'?'原话引用':claim.kind==='inference'?'有依据的推测':'模型归纳';
}
export function productRecallClaimTime(claim:RecallClaim):string{
  const value=claim.event_time;if(value===undefined||value.basis==='unknown'){return '';}
  const basis=value.basis==='explicit'?'来源明确日期':value.basis==='relative'?'按消息日期解释的相对日期':'时间尚属推测';
  return `事件时间：${value.first}${value.last!==value.first?' 至 '+value.last:''} · ${basis}`;
}
