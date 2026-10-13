export interface RecallPerson { person_id:string; display_name:string; kind:string; }
export interface RecallDecision { person_id:string; action:string; basis:string; }
export interface RecallIdentity { key:string; platform:string; source:string; account:string; label:string; person_id:string; basis:string; editable:boolean; decisions:Array<RecallDecision>; }
export interface RecallCommand { operation_id:string; key:string; person_id:string; action:string; basis:string; version:string; }
export interface RecallRequest { action:string; query_id?:string; question?:string; keyword?:string; person_id?:string; source?:string; sent_from?:number; sent_to?:number; expand?:boolean; summarize?:boolean; page?:number; offset?:number; evidence_id?:string; decision?:RecallCommand; }
export interface RecallEvidence { id:string; revision:number; source:string; speaker:string; person_id:string; identity_basis:string; identity_key:string; quote:string; quote_truncated:boolean; sent_at:number; origin:string; role:string; assertion:string; source_account_id?:string; conversation_id?:string; sender_account_id?:string; session_id?:string; utterance_id?:string; start_ms?:number; end_ms?:number; start_at?:string; end_at?:string; }
export interface RecallClaim { kind:string; text:string; citations:Array<string>; }
export interface RecallMetrics { hits:number; retrieved:number; model_calls:number; source_requests:number; elapsed_ms:number; }
export interface RecallScope { person_id:string; source:string; sent_from:number; sent_to:number; }
export interface RecallResponse { status?:string; query_id?:string; version?:string; people?:Array<RecallPerson>; items?:Array<RecallIdentity>; next_offset?:number; recording_notice?:string; answer?:string; evidence?:Array<RecallEvidence>; claims?:Array<RecallClaim>; unknown?:Array<string>; scope?:RecallScope; terms?:Array<string>; coverage?:Array<string>; model_status?:string; metrics?:RecallMetrics; page?:number; has_more?:boolean; notice?:string; }

// Stable operation/query IDs, including retries after an ambiguous HTTP outcome.
export function recallRequestId():string { return `recall-${Date.now()}-${Math.floor(Math.random()*1000000000)}`; }
export function recallDate(value:string,end:boolean):number|undefined {
  if(value.trim().length===0){return undefined;}
  if(!/^\d{4}-\d{2}-\d{2}$/.test(value)){throw new Error('日期请使用 YYYY-MM-DD');}
  const stamp=Date.parse(`${value}T${end?'23:59:59':'00:00:00'}+08:00`);
  if(!Number.isFinite(stamp)){throw new Error('日期无效');}
  return Math.floor(stamp/1000);
}
