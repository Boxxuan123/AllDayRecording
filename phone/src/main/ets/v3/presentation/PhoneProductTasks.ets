import { PhoneV3Snapshot, PhoneV3Reminder } from '../domain/PhoneV3Models';
import { ChatFollowup } from '../domain/PhoneChatFollowup';
import { productTime } from './PhoneProductEvidence';
export class PhoneProductTask {
  id: string = '';
  title: string = '';
  category: string = '';
  status: string = '';
  time: string = '';
  explanation: string = '';
  reminder: PhoneV3Reminder | undefined = undefined;
  chat: ChatFollowup | undefined = undefined;
}
export function productChatCategory(item: ChatFollowup): string {
  if (item.status !== 'active' || item.ignored) { return 'ended'; }
  if (!item.user_confirmed && (item.historical || item.progress_unknown || item.category === 'pending')) { return 'clues'; }
  if (item.actor_is_from_self === true && item.user_confirmed) { return 'self'; }
  if (item.actor_is_from_self === false && item.category === 'waiting') { return 'waiting'; }
  return 'clues';
}
export function productTasks(snapshot: PhoneV3Snapshot): Array<PhoneProductTask> {
  const values: Array<PhoneProductTask> = [];
  for (const reminder of snapshot.reminders) {
    const task = new PhoneProductTask();
    task.id=reminder.eventId; task.title=reminder.title; task.reminder=reminder;
    task.chat=snapshot.chatFollowups.find((item:ChatFollowup):boolean=>item.event_id===task.id);
    task.category=reminder.status==='completed'||reminder.status==='cancelled'?'ended':'scheduled';
    task.status=reminder.pendingAction.length>0?'等待同步确认':reminder.status==='completed'?'已完成':reminder.status==='cancelled'?'已取消':'已确认任务';
    task.time=(task.category==='ended'?'原定 ':'')+productTime(reminder.scheduledAt);
    task.explanation=reminder.pendingAction.length>0?'操作已保存到手机':task.category==='ended'?'事项已结束，原记录和依据保留':reminder.actorPersonId==='self'?'需要我执行；日历安排见详情':'已确认的提醒安排';
    values.push(task);
  }
  for (const item of snapshot.chatFollowups) {
    if (values.some((task:PhoneProductTask):boolean=>task.id===item.event_id)) { continue; }
    const task = new PhoneProductTask(); task.id=item.event_id; task.title=item.title; task.chat=item;
    task.category=productChatCategory(item);
    task.status=item.pendingAction?'等待同步确认':task.category==='ended'?(item.status==='completed'?'已完成':'已结束'):task.category==='self'?'需要我处理':task.category==='waiting'?'等待对方':item.historical||item.progress_unknown?'历史线索':'需要判断';
    task.time=item.time?.at?productTime(item.time.at):item.time?.date??'';
    task.explanation=task.category==='clues'?'尚未确认当前仍需处理；没有安排提醒':task.category==='waiting'?'等待对方的下一步；没有安排提醒':task.category==='self'?'已确认当前需处理；尚未安排提醒':'历史记录已保留';
    if (item.pending_change!==null&&item.pending_change!==undefined) { task.explanation='发现新进展，需在详情中核对'; }
    values.push(task);
  }
  return values;
}
export function productTaskMatches(task: PhoneProductTask, category: string): boolean {
  return task.category===category || category==='self'&&task.category==='scheduled'&&task.reminder?.actorPersonId==='self';
}
export function productAttention(snapshot: PhoneV3Snapshot, now: number): Array<PhoneProductTask> {
  const end = new Date(now); end.setHours(23,59,59,999);
  return productTasks(snapshot).filter((task:PhoneProductTask):boolean=>
    task.category==='self' || task.category==='scheduled'&&task.reminder?.actorPersonId==='self'&&Date.parse(task.reminder.scheduledAt)<=end.getTime()).slice(0,3);
}
export function productCalendarLabel(state: string, ended:boolean=false): string {
  if(ended){return state==='removed'?'原日历提醒已移除':state==='error'?'事项已结束，日历移除尚未成功，可重试':'事项已结束，日历移除状态暂未确认';}
  if (state==='scheduled') { return '已写入系统日历；通知是否开启由系统设置决定'; }
  if (state==='permission_required') { return '任务已保存，需要日历权限才能安排提醒'; }
  if (state==='externally_removed') { return '系统日历事件已被删除，任务仍保留'; }
  if (state==='externally_modified') { return '系统日历事件已被修改，已保留系统中的修改'; }
  if (state==='error') { return '日历写入失败，任务已保留'; }
  if (state==='removed') { return '日历提醒已移除'; }
  return '日历安排尚未确认；不能据此认定会收到提醒';
}

export function productCalendarRecovery(state:string,ended:boolean):string{
  if(!['permission_required','error','externally_removed','externally_modified'].includes(state)){return '';}
  if(ended){return state==='permission_required'?'授权并重试移除日历提醒':'重试移除日历提醒';}
  return state==='permission_required'?'授权日历并重试':state==='externally_modified'?'按事项时间恢复日历提醒':state==='externally_removed'?'重新启用日历提醒':'重试日历同步';
}
