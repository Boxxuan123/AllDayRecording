export interface RecallContact { key:string; display_name:string; platform:string; names:Array<string>; conversation_type:string; }
export interface RecallPerson { person_id:string; display_name:string; kind:string; aliases?:Array<string>; }
export interface RecallDecision { person_id:string; action:string; basis:string; }
export interface RecallIdentity { key:string; platform:string; source:string; account:string; label:string; person_id:string; basis:string; editable:boolean; decisions:Array<RecallDecision>; }
export interface RecallCommand { operation_id:string; key:string; person_id:string; action:string; basis:string; version:string; }
export interface RecallRequest { action:string; query_id?:string; contact_key?:string; search?:string; previous_query_id?:string; question?:string; keyword?:string; person_id?:string; source?:string; timezone?:string; sent_from?:number; sent_to?:number; expand?:boolean; summarize?:boolean; page?:number; offset?:number; evidence_id?:string; decision?:RecallCommand; }
export interface RecallEvidence { id:string; revision:number; source:string; speaker:string; person_id:string; identity_basis:string; identity_key:string; quote:string; quote_truncated:boolean; source_is_from_self?:boolean|null; effective_is_self?:boolean|null; validity?:string; sent_at:number; origin:string; role:string; assertion:string; source_account_id?:string; conversation_id?:string; conversation_type?:string; reply_record_id?:string; sender_account_id?:string; session_id?:string; utterance_id?:string; start_ms?:number; end_ms?:number; start_at?:string; end_at?:string; }
export interface RecallEventTime { basis:string; first:string; last:string; evidence_id:string; quote:string; }
export interface RecallClaim { kind:string; text:string; citations:Array<string>; event_time?:RecallEventTime; }
export interface RecallMetrics { hits:number; retrieved:number; model_calls:number; source_requests:number; elapsed_ms:number; model_elapsed_ms?:number; model_input_ids?:Array<string>; source_records_read?:number; }
export interface RecallScope { person_id:string; source:string; sent_from:number; sent_to:number; timezone?:string; relationship?:string; sent_from_local?:string; sent_to_local?:string; target_label?:string; }
export interface RecallResponse { status?:string; query_id?:string; version?:string; people?:Array<RecallPerson>; person_candidates?:Array<RecallPerson>; contact_candidates?:Array<RecallContact>; contact_lookup_allowed?:boolean; summary_retry_available?:boolean; items?:Array<RecallIdentity>; next_offset?:number; recording_notice?:string; answer?:string; evidence?:Array<RecallEvidence>; claims?:Array<RecallClaim>; unknown?:Array<string>; scope?:RecallScope; terms?:Array<string>; coverage?:Array<string>; model_status?:string; source_status?:string; metrics?:RecallMetrics; page?:number; has_more?:boolean; notice?:string; intent?:string; invalidated_evidence_ids?:Array<string>; latest_status_confirmed?:boolean; }

// Stable operation/query IDs, including retries after an ambiguous HTTP outcome.
export function recallRequestId():string { return `recall-${Date.now()}-${Math.floor(Math.random()*1000000000)}`; }
export function recallDate(value:string,end:boolean):number|undefined {
  if(value.trim().length===0){return undefined;}
  if(!/^\d{4}-\d{2}-\d{2}$/.test(value)){throw new Error('日期请使用 YYYY-MM-DD');}
  const parts:Array<string>=value.split('-');
  const year=Number(parts[0]);const month=Number(parts[1]);const day=Number(parts[2]);
  const first=new Date(year,month-1,day);
  if(first.getFullYear()!==year||first.getMonth()!==month-1||first.getDate()!==day){throw new Error('日期无效');}
  const stamp=end?new Date(year,month-1,day+1).getTime()-1000:first.getTime();
  return Math.floor(stamp/1000);
}

// Pure state transition shared by the actual UI and offline acceptance.
// A stale response from a prior query must not invalidate the current query.
export function applyRecallContext(current:RecallResponse,context:RecallResponse):RecallResponse {
  if(context.query_id!==undefined&&context.query_id!==current.query_id){return current;}
  if(context.status!=='stale'&&context.status!=='unavailable'){return current;}
  // Copy only the collections changed below; preserve optional fields and source values.
  const next:RecallResponse={
    status:current.status,
    query_id:current.query_id,
    version:current.version,
    people:current.people,
    person_candidates:current.person_candidates,
    contact_candidates:current.contact_candidates,
    contact_lookup_allowed:current.contact_lookup_allowed,
    summary_retry_available:current.summary_retry_available,
    items:current.items,
    next_offset:current.next_offset,
    recording_notice:current.recording_notice,
    answer:current.answer,
    evidence:current.evidence,
    claims:current.claims,
    unknown:current.unknown,
    scope:current.scope,
    terms:current.terms,
    coverage:current.coverage,
    model_status:current.model_status,
    source_status:current.source_status,
    metrics:current.metrics,
    page:current.page,
    has_more:current.has_more,
    notice:current.notice,
    intent:current.intent,
    invalidated_evidence_ids:current.invalidated_evidence_ids,
    latest_status_confirmed:current.latest_status_confirmed
  };
  next.coverage=current.coverage?.slice()??[];
  next.evidence=current.evidence?.map(copyRecallEvidence);
  if(context.status==='stale'){
    const ids:Array<string>=current.invalidated_evidence_ids?.slice()??[];
    (context.invalidated_evidence_ids??[]).forEach((id:string)=>{if(!ids.includes(id)){ids.push(id);}});
    next.status='stale';
    next.model_status='stale';
    next.summary_retry_available=false;
    next.claims=[];
    next.answer='来源已确认修订／撤回，旧归纳已失效，请重新查询。';
    next.invalidated_evidence_ids=ids;
    next.evidence?.forEach((e:RecallEvidence)=>{if(ids.includes(e.id)){e.validity='stale';}});
    next.coverage.push(context.notice??'旧证据仅供审计');
  }else{
    next.coverage.push(context.notice??'来源离线；缓存不代表当前状态');
  }
  return next;
}

// Latch invalidation across delayed page responses for the same query.
export function applyRecallPage(current:RecallResponse,incoming:RecallResponse):RecallResponse {
  if(current.query_id===incoming.query_id&&current.status==='stale'){
    return applyRecallContext(incoming,{status:'stale',query_id:incoming.query_id,invalidated_evidence_ids:current.invalidated_evidence_ids,notice:'来源变化后旧分页不能恢复结论'});
  }
  return incoming;
}

// ArkTS uses explicit typed copies rather than object spread or JSON cloning.
function copyRecallEvidence(value:RecallEvidence):RecallEvidence {
  return {
    id:value.id,
    revision:value.revision,
    source:value.source,
    speaker:value.speaker,
    person_id:value.person_id,
    identity_basis:value.identity_basis,
    identity_key:value.identity_key,
    quote:value.quote,
    quote_truncated:value.quote_truncated,
    source_is_from_self:value.source_is_from_self,
    effective_is_self:value.effective_is_self,
    validity:value.validity,
    sent_at:value.sent_at,
    origin:value.origin,
    role:value.role,
    assertion:value.assertion,
    source_account_id:value.source_account_id,
    conversation_id:value.conversation_id,
    conversation_type:value.conversation_type,
    reply_record_id:value.reply_record_id,
    sender_account_id:value.sender_account_id,
    session_id:value.session_id,
    utterance_id:value.utterance_id,
    start_ms:value.start_ms,
    end_ms:value.end_ms,
    start_at:value.start_at,
    end_at:value.end_at
  };
}
