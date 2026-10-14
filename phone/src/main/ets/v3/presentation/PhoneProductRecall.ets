import { RecallResponse, RecallClaim } from '../domain/PhoneHistoryRecall';
// Business result states. Engine notices/count limits remain available in technical details.
export function productRecallAnswer(result:RecallResponse):string{
  if(result.status==='stale'||result.model_status==='stale'){return '原文已发生变化，原先的归纳需要重新核对';}
  if(result.status==='needs_clarification'){return result.answer??'请明确人物或日期后重试';}
  if(result.model_status==='failed'||result.model_status==='unavailable'||result.model_status==='timeout'){return '无法生成归纳（模型不可用、超时或证据校验失败）；以下仅为符合本次约束的原文。';}
  if(result.model_status==='insufficient'){return result.answer??'现有证据不足，无法生成可靠归纳；请核对本次范围内的原文。';}
  if(result.model_status==='available'){
    const claims=result.claims??[];
    const text=claims.filter((claim:RecallClaim):boolean=>claim.text.trim().length>0&&claim.citations.length>0).map((claim:RecallClaim):string=>claim.kind==='inference'?`推测：${claim.text}`:claim.text).join('\n');
    return text.length>0?text:'归纳没有形成有依据的结论，请核对原文。';
  }
  if(result.status==='not_found'){return result.answer??'当前人物、日期与会话范围未找到记录，不能据此判断没有发生。';}
  if(result.status==='partial'&&(result.evidence?.length??0)===0){return result.answer??'本轮原文未完整取回，请查看来源状态后重试。';}
  return (result.evidence?.length??0)>0?'未请求归纳；以下为本次范围内的原文':'当前范围没有找到相关原文';
}
export function productRecallCoverage(result:RecallResponse):string{
  if((result.coverage??[]).some((line:string):boolean=>line.includes('离线')||line.includes('SOURCE_OFFLINE'))){return '部分来源暂时离线，已保存内容不代表最新状态';}
  if(result.status==='unavailable'||result.source_status==='unavailable'||(result.coverage??[]).some((line:string):boolean=>line.includes('来源未完整取回'))){return '部分来源未成功取回，已有内容不代表最新状态';}
  return result.latest_status_confirmed===false||(result.coverage?.length??0)>0?'结果只覆盖本次可用记录，尚不能确认完整经过或最终进展':'';
}
