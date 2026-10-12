// Defensive projection for old cached/replayed indices. Raw attachments remain in the source cache.
export function safeMemoryText(value:string):string {
  if(/<(?:msg|appmsg|img|video|refermsg)\b|(?:aeskey|cdnthumbaeskey|access.?token|authkey|encryptkey|password|signature)\s*[=：:]/i.test(value)) {
    return /<img\b/i.test(value)?'收到图片，内容未解析':'附件访问材料已省略；请在来源中查看有效文字';
  }
  return value.replace(/https?:\/\/[^\s<>"']+/g,(url:string):string=>url.split(/[?#]/)[0].replace(/^(https?:\/\/)[^/@]+@/,'$1'));
}
export interface MemoryContact { id:string; label:string; identity_basis:string; platform:string; person_id?:string; last_evidence_at?:string; discussion_ids:Array<string>; }
export interface MemoryEvidence { source_type:string; quote:string; revision:number; occurred_at:string; learned_at?:string; assertion:string; status:string; speaker:string; record_id?:string; session_id?:string; utterance_id?:string; start_ms?:number; end_ms?:number; }
export interface MemoryDiscussion { id:string; title:string; summary?:string; contacts:Array<MemoryContact>; thing_id:string; link_basis:string; occurred_at:string; evidence_status:string; evidence:Array<MemoryEvidence>; event_id?:string; pending_change:boolean; }
export interface MemoryThing { id:string; title:string; discussion_ids:Array<string>; progress:string; last_evidence_at?:string; needs_confirmation:boolean; }
export interface MemoryTopic { label:string; discussion_ids:Array<string>; }
export interface MemoryCandidate { source:string; target:string; reason:string; }
export interface MemoryCoverage { missing_sources:Array<string>; }
export interface MemoryScope { first:string; last:string; timezone:string; coverage:MemoryCoverage; }
export interface MemoryIndex { id:string; revision:number; status:string; scope:MemoryScope; people:Array<MemoryContact>; discussions:Array<MemoryDiscussion>; things:Array<MemoryThing>; topics:Array<MemoryTopic>; candidates:Array<MemoryCandidate>; }
export interface MemoryCommand { source:string; target:string; action:string; }
export function validateMemoryIndex(value:Object):MemoryIndex {
  const v=value as MemoryIndex;
  if(!Number.isSafeInteger(v.revision)||v.revision<1||!Array.isArray(v.discussions)||v.discussions.length>7||!Array.isArray(v.people)||v.people.length>3||!Array.isArray(v.things)||!Array.isArray(v.topics)||v.topics.length>3||!Array.isArray(v.candidates)||v.scope.timezone!=='Asia/Singapore') { throw new Error('跨天记忆投影无效'); }
  const ids=new Set<string>();
  for(let r of v.discussions) {
    if(ids.has(r.id)||!Array.isArray(r.evidence)||r.evidence.length<1||r.evidence.length>8||!['valid','source_changed_or_missing'].includes(r.evidence_status)) {throw new Error('讨论依据无效');}
    r.title=safeMemoryText(r.title);
    if(typeof r.summary==='string'){r.summary=safeMemoryText(r.summary);}
    ids.add(r.id);
    for(let e of r.evidence) {if(typeof e.quote!=='string'||e.quote.length>600||!Number.isSafeInteger(e.revision)||e.revision<1||!['chat','recording'].includes(e.source_type)) {throw new Error('记忆原文无效');} e.quote=safeMemoryText(e.quote);e.speaker=safeMemoryText(e.speaker);e.assertion=safeMemoryText(e.assertion);}
  }
  for(let c of v.candidates) {if(!ids.has(c.source)||!ids.has(c.target)||c.source===c.target) {throw new Error('记忆关联候选无效');}}
  for(let p of v.people){p.label=safeMemoryText(p.label);p.identity_basis=safeMemoryText(p.identity_basis);}
  for(let t of v.things){t.title=safeMemoryText(t.title);t.progress=safeMemoryText(t.progress);}
  for(let c of v.candidates){c.reason=safeMemoryText(c.reason);}
  return v;
}
