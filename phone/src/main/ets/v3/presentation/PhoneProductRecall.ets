import { RecallResponse } from '../domain/PhoneHistoryRecall';
// Business result states. Engine notices/count limits remain available in technical details.
export function productRecallAnswer(result:RecallResponse):string{
  if(result.status==='stale'||result.model_status==='stale'){return '原文已发生变化，原先的归纳需要重新核对';}
  if(result.model_status==='failed'||result.model_status==='unavailable'){return '归纳暂未完成，可以先查看已找到的原文';}
  if((result.metrics?.model_calls??0)>0&&(result.answer?.length??0)>0){return result.answer??'';}
  return (result.evidence?.length??0)>0?'已找到原文，可核对原话和事情进展':'当前范围没有找到相关原文';
}
export function productRecallCoverage(result:RecallResponse):string{
  if(result.status==='unavailable'||(result.coverage??[]).some((line:string):boolean=>line.includes('离线'))){return '部分来源暂时离线，已保存内容不代表最新状态';}
  return result.latest_status_confirmed===false||(result.coverage?.length??0)>0?'结果只覆盖本次可用记录，尚不能确认完整经过或最终进展':'';
}
