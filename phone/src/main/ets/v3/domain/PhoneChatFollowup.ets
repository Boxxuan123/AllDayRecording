import { PhonePendingOperation } from '../data/PhoneSyncProjection';
export interface ChatFollowupTime { expression?: string; date?: string|null; at?: string|null; timezone?: string|null; uncertainty?: string|null; }
export interface ChatFollowupEvidence { source_type: string; record_id: string; record_revision: number; platform: string; sent_at: number|null; quote: string; is_from_self: boolean|null; speaker: string; context: Object; }
export interface ChatFollowupChange { action: string; kind: string; time: ChatFollowupTime; uncertainty: Array<string>; evidence: Array<ChatFollowupEvidence>; }
export interface ChatFollowup { event_id: string; revision: number; source_key: string; title: string; status: string; category: string; actor_is_from_self: boolean|null; time: ChatFollowupTime; historical: boolean; progress_unknown: boolean; user_confirmed: boolean; ignored: boolean; uncertainty: Array<string>; evidence: Array<ChatFollowupEvidence>; pending_change: ChatFollowupChange|null; updated_at: string; pendingAction?: string; }
export interface ChatFollowupChanges { title?: string; at?: string; date?: string; timezone?: string; category?: string; confirm_current?: boolean; }
export interface ChatFollowupCommand { event_id: string; action: string; changes?: ChatFollowupChanges; }
export function validateChatFollowup(value: Object): ChatFollowup {
  const item = value as ChatFollowup;
  if (typeof item.event_id !== 'string' || !Number.isSafeInteger(item.revision) || item.revision < 1 || typeof item.title !== 'string' || ['active','completed','cancelled'].indexOf(item.status) < 0 || !Array.isArray(item.evidence) || !Array.isArray(item.uncertainty) || (item.actor_is_from_self !== true && item.actor_is_from_self !== false && item.actor_is_from_self !== null)) { throw new Error('聊天事项投影无效'); }
  for (let e of item.evidence) { if(e.source_type !== 'chat_record' || !e.record_id || !Number.isSafeInteger(e.record_revision) || e.record_revision<1 || typeof e.quote !== 'string' || ['qq','wechat'].indexOf(e.platform)<0) { throw new Error('聊天证据无效'); } }
  return item;
}
export function explicitChatTime(value: string): string {
  const time = value.trim();
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?(Z|[+-]\d{2}:\d{2})$/.test(time) || !Number.isFinite(Date.parse(time)) || Date.parse(time)<=Date.now()) { throw new Error('请确认明确的未来时间，包含时区偏移，例如 2026-10-12T09:00+08:00'); }
  return new Date(time).toISOString();
}
export function overlayChatCommands(items: Array<ChatFollowup>, commands: Array<PhonePendingOperation>): Array<ChatFollowup> {
  for(let op of commands) {
    if(op.kind !== 'chat.followup') { continue; }
    const command=op.payload as ChatFollowupCommand;
    const item=items.find((v: ChatFollowup):boolean=>v.event_id===command.event_id);
    if(item===undefined){continue;}
    item.pendingAction=command.action;
    if(command.action==='complete'){item.status='completed';}
    if(command.action==='ignore'||command.action==='cancel'){item.status='cancelled';}
    if(command.changes?.title){item.title=command.changes.title;}
  }
  return items;
}
