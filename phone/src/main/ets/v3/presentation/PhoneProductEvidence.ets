import { RecallEvidence, RecallRequest, RecallResponse } from '../domain/PhoneHistoryRecall';
import { PhoneDailyEvidence } from '../domain/PhoneV3DailyModels';
import { PhoneUnifiedEvidence, unifiedRecordingEvidence } from '../domain/PhoneUnifiedReview';
import { ChatFollowupEvidence } from '../domain/PhoneChatFollowup';
import { PhoneV3Utterance } from '../domain/PhoneV3Models';

// Ephemeral display values, never a second source of identity/task truth.
export class PhoneProductEvidence {
  id: string = '';
  source: string = '';
  speaker: string = '';
  time: string = '';
  quote: string = '';
  identity: string = '身份未确认';
  meaning: string = '原话；是否已执行需结合上下文';
  unavailable: boolean = false;
  truncated: boolean = false;
  recording: PhoneDailyEvidence | undefined = undefined;
  technical: string = '';
  context: Array<string> = [];
  recordId:string='';
  recordRevision:number=0;
  platform:string='';
  stamp:number=0;
  kindLabel:string='已保存引用';
}
export function productTime(value: string | number): string {
  if(typeof value!=='number'&&typeof value!=='string'||value===0||value===''){return '时间未知';}
  const date = new Date(typeof value === 'number' ? value * 1000 : value);
  return Number.isFinite(date.getTime()) ? date.toLocaleString('zh-CN') : '时间未知';
}
export function productSource(value: string): string {
  return value === 'qq' ? 'QQ' : value === 'wechat' ? '微信' : value === 'recording' ? '录音' : '聊天';
}
interface QuoteContext { text?: string; content?: string; quote?: string; reply?: Object; forward?: Object; source_quote?: Object; }
function contextText(value: Object): string {
  if (typeof value === 'string') { return value; }
  if(value===undefined||value===null){return '';}
  const q = value as QuoteContext;
  return typeof q.text === 'string' ? q.text : typeof q.content === 'string' ? q.content : typeof q.quote === 'string' ? q.quote : '';
}
export function productQuoteContext(value: Object): Array<string> {
  if(value===undefined||value===null){return [];}
  const q = value as QuoteContext;
  const result: Array<string> = [];
  for (const field of [q.reply, q.forward, q.source_quote]) {
    if (field !== undefined && field !== null) {
      const text = contextText(field);
      if (text.length > 0) { result.push(text); }
    }
  }
  return result;
}
export function recallProductEvidence(e: RecallEvidence): PhoneProductEvidence {
  const value = new PhoneProductEvidence();
  value.id = e.id; value.source = productSource(e.source); value.speaker = e.speaker;
  value.time = productTime(e.sent_at); value.quote = e.quote; value.truncated = e.quote_truncated;
  value.identity = e.person_id.length > 0 ? '已确认人物身份' : e.source_is_from_self===true&&e.effective_is_self===true?'来源已确认本人':'来源显示名，人物身份未确认';
  value.meaning = e.source==='recording'?'录音中的陈述；听到不代表本人执行':'聊天原话；讨论和计划不代表已经执行';
  value.unavailable = e.validity === 'stale';
  value.technical = JSON.stringify(e);value.kindLabel=e.role==='context'?'前后文':'原消息';
  if(e.source==='qq'||e.source==='wechat'){value.recordId=e.id.startsWith('chat:')?e.id.slice(5):'';value.recordRevision=e.revision;value.platform=e.source;value.stamp=e.sent_at;}
  if (e.source === 'recording' && e.session_id !== undefined && e.utterance_id !== undefined && e.start_ms !== undefined && e.end_ms !== undefined) {
    value.recording = { session_id:e.session_id, utterance_id:e.utterance_id, revision:e.revision, start_ms:e.start_ms, end_ms:e.end_ms, start_at:e.start_at??'', end_at:e.end_at??'', text:e.quote, participant:{key:e.person_id||'unknown',kind:e.person_id.length>0?'known':'unknown',label:e.speaker,status:e.person_id.length>0?'confirmed':'unresolved'} };
  }
  return value;
}
export function dailyProductEvidence(e: PhoneDailyEvidence): PhoneProductEvidence {
  const value = new PhoneProductEvidence();
  value.id = e.utterance_id; value.source = '录音'; value.speaker = e.participant.label;
  value.time = productTime(e.start_at); value.quote = e.text; value.recording = e;
  value.identity = e.participant.status === 'confirmed' || e.participant.status === 'source_confirmed' ? '已确认人物身份' : '说话人身份未确认';
  value.technical = JSON.stringify(e); return value;
}
export function unifiedProductEvidence(e: PhoneUnifiedEvidence): PhoneProductEvidence {
  const recording = unifiedRecordingEvidence(e);
  if (recording !== undefined) { return dailyProductEvidence(recording); }
  const value = new PhoneProductEvidence();
  value.id = e.record_id===undefined?e.evidence_id:'chat:'+e.record_id; value.recordId=e.record_id??'';value.recordRevision=e.revision;value.platform=e.platform??'';value.stamp=e.sent_at??0; value.source = productSource(e.platform??'chat'); value.speaker = e.speaker??'发言人未知';
  value.time = e.sent_at === undefined ? '时间未知' : productTime(e.sent_at); value.quote = e.text;
  value.identity = '来源显示名，人物身份未确认'; value.technical = JSON.stringify(e);
  value.context = e.context===undefined?[]:productQuoteContext(e.context); return value;
}
export function chatProductEvidence(e: ChatFollowupEvidence): PhoneProductEvidence {
  const value = new PhoneProductEvidence();
  value.id = 'chat:'+e.record_id;value.recordId=e.record_id;value.recordRevision=e.record_revision;value.platform=e.platform;value.stamp=e.sent_at??0; value.source = productSource(e.platform); value.speaker = e.is_from_self === true ? '我本人' : e.speaker;
  value.time = e.sent_at === null ? '时间未知' : productTime(e.sent_at); value.quote = e.quote;
  value.identity = e.is_from_self === true ? '来源已确认本人' : '来源显示名，人物身份未确认';
  value.context = productQuoteContext(e.context); value.technical = JSON.stringify(e); return value;
}
export function utteranceProductEvidence(e: PhoneV3Utterance): PhoneProductEvidence {
  return dailyProductEvidence({session_id:e.sessionId,utterance_id:e.utteranceId,revision:e.revision,start_ms:e.startMs,end_ms:e.endMs,start_at:e.startAt,end_at:e.endAt,text:e.text,participant:{key:e.annotationPersonId||'unknown',kind:e.annotationPersonId.length>0?'known':'unknown',label:e.speakerLabel??'说话人未知',status:e.annotationPersonId.length>0?'confirmed':'unresolved'}});
}

// Only the cited record's two-second window, then an exact canonical record-ID match.
// No model, identity command, follow-up scan, or default 30-day search is involved.
export function productEvidenceQuery(e:PhoneProductEvidence,queryId:string):RecallRequest|undefined{
  if(e.recordId.length===0||!Number.isSafeInteger(e.recordRevision)||e.recordRevision<1||!Number.isSafeInteger(e.stamp)||e.stamp<=0||e.quote.trim().length===0||!['qq','wechat'].includes(e.platform)){return undefined;}
  return {action:'query',query_id:queryId,question:'查看这条原文',keyword:e.quote.slice(0,80),source:e.platform,sent_from:Math.max(0,e.stamp-1),sent_to:e.stamp+1,summarize:false,expand:false};
}

// Render identity includes the current display value. A placeholder and its filled
// native citation share an evidence ID, but must not reuse a frozen ArkUI row.
export function productEvidenceRenderKey(value:PhoneProductEvidence):string {
  return JSON.stringify(value);
}
export function productContextNotice(context:RecallResponse):string {
  if(context.status==='stale'){return '来源已失效或修订；保存的归纳需重新核对';}
  if(context.status==='unavailable'){return context.notice??'上下文暂未取回，以下为已保存原文；当前状态未重新核对';}
  return '原消息与前后文';
}
