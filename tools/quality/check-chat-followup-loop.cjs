// Cross-repository production ASR sync + actual Phone SQLite/outbox + Calendar scheduler.
// Synthetic messages only. HarmonyOS Calendar port mocked, no model/network/device calls.
const assert=require('node:assert/strict'), fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawnSync}=require('node:child_process');
const {Repository,UseCases,stores,apply,root}=require('./phone-sqlite-harness.cjs');
const {CalendarReminderScheduler}=require(path.join(root,'application/CalendarReminderScheduler.ets'));
const {explicitChatTime}=require(path.join(root,'domain/PhoneChatFollowup.ets'));
const asr=process.env.CHAT_PHONE_ASR_ROOT,python=process.env.CHAT_PHONE_PYTHON;
if(!asr||!python)throw Error('Set CHAT_PHONE_ASR_ROOT and CHAT_PHONE_PYTHON to the ASR checkout and dev Python');
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'chat-phone-loop-'));
const peerRoot=path.join(temp,'chat-phone-loop-asr');fs.mkdirSync(peerRoot);
let cursor=null,repo;
function peer(operations=[],limit=100,extra={}) {
  const env={...process.env,PYTHONIOENCODING:'utf-8',PYTHONPATH:path.join(asr,'src')};delete env.CHAT_DATA_TOKEN;delete env.CHAT_DATA_BASE_URL;
  const r=spawnSync(python,[path.join(asr,'tools/chat_phone_fixture.py'),peerRoot],{input:JSON.stringify({cursor,client_operations:operations.map(({operation_id,kind,base_revision,payload})=>({operation_id,kind,base_revision,payload})),pull_limit:limit,...extra}),encoding:'utf8',env,cwd:asr,timeout:30000});
  assert.equal(r.status,0,r.stderr);const value=JSON.parse(r.stdout);cursor=value.next_cursor;return value;
}
const remote={isPaired:async()=>true};
function useCases(){return new UseCases(repo,{list:async()=>[]},remote);}
async function snapshot(){return useCases().loadCached([]);}
class Calendar {
  inventory=[];creates=0;updates=0;removes=0;granted=true;
  async permission(){return this.granted;} async account(){return 6;} async events(){return JSON.parse(JSON.stringify(this.inventory));}
  async create(_id,event){const id=++this.creates;this.inventory.push({...event,id});return id;}
  async update(_id,event){this.updates++;this.inventory[this.inventory.findIndex(e=>e.id===event.id)]={...event};}
  async remove(_id,id){this.removes++;this.inventory=this.inventory.filter(e=>e.id!==id);}
}
const due=new Date(Date.now()+3600000).toISOString(),due2=new Date(Date.now()+7200000).toISOString();
(async()=>{
  // A populated legacy v19 database preserves queue, cursor and Calendar mapping.
  const legacyPath=path.join(temp,'legacy19.db');await Repository.open({databasePath:legacyPath});
  const oldStore=stores.at(-1),legacy=oldStore.db;
  legacy.exec("DROP TABLE projection_chat_followups; UPDATE sync_state SET projection_version=5,cursor='cursor-123'; INSERT INTO outbox(operation_id,kind,base_revision,payload_json,created_at) VALUES('legacy-op','reminder.task',2,'{\"event_id\":\"legacy-event\",\"action\":\"complete\"}',1); INSERT INTO calendar_reminder_account VALUES(1,6); INSERT INTO calendar_reminder_mappings VALUES('legacy-event',6,77,'2030-10-12T06:00:00Z','Legacy synthetic','scheduled','')");
  const capture=()=>['outbox','calendar_reminder_mappings','calendar_reminder_account'].map(t=>legacy.prepare('SELECT * FROM '+t).all());
  const retained=capture();oldStore.version=19;await Repository.open({databasePath:legacyPath});assert.equal(stores.at(-1).version,21);assert.deepEqual(capture(),retained);assert.equal(legacy.prepare('SELECT cursor FROM sync_state').get().cursor,'cursor-123');assert.equal(legacy.prepare('SELECT projection_version FROM sync_state').get().projection_version,7);
  await Repository.open({databasePath:legacyPath});assert.deepEqual(capture(),retained);
  console.log('PASS populated Phone schema 19 → 21: queue/cursor/Calendar binding preserved; repeat upgrade idempotent');

  const context={databasePath:path.join(temp,'phone.sqlite3')};repo=await Repository.open(context);
  await apply(repo,peer());let snap=await snapshot();assert.equal(snap.chatFollowups.length,1);assert.equal(snap.reminders.length,0);
  const task=snap.chatFollowups[0],eventId=task.event_id;assert.equal(task.actor_is_from_self,true);assert.equal(task.evidence[0].source_type,'chat_record');
  assert.throws(()=>explicitChatTime('2030-10-12'),/明确/);
  await useCases().queueReminder('chat.followup',{event_id:eventId,action:'enable_reminder',changes:{at:due,confirm_current:true}},task.revision);
  await assert.rejects(()=>useCases().queueReminder('chat.followup',{event_id:eventId,action:'complete'},task.revision),/待同步/);
  repo=await Repository.open(context);snap=await snapshot();assert.equal(snap.chatFollowups[0].pendingAction,'enable_reminder');
  let operations=await repo.pendingOperations();const beforeCursor=cursor;const first=peer(operations,1);await apply(repo,{...first,changes:[],next_cursor:beforeCursor});
  assert.equal(first.receipts[0].status,'applied',JSON.stringify(first.receipts[0]));assert.equal((await repo.reminderOperations()).length,1,'receipt before corresponding projection keeps local intent');await apply(repo,first);
  // Re-send the same operation after a simulated lost response: identical receipt/no second Event.
  const repeated=peer(operations);assert.equal(repeated.receipts[0].status,'applied');await apply(repo,repeated);
  while(repeated.has_more){await apply(repo,peer());break;}
  snap=await snapshot();assert.equal(snap.chatFollowups.length,1);assert.equal(snap.reminders.length,1);assert.equal(snap.reminders[0].eventId,eventId);assert.equal(snap.reminders[0].sessionId,'');assert.equal((await repo.reminderOperations()).length,0);
  const api=new Calendar();let scheduler=new CalendarReminderScheduler(api,repo);api.granted=false;await scheduler.reconcile(snap.reminders);assert.equal(scheduler.state(eventId),'permission_required');assert.equal(api.creates,0);
  api.granted=true;await scheduler.retry(eventId,snap.reminders);await scheduler.reconcile(snap.reminders);assert.equal(api.creates,1);const calendarId=api.inventory[0].id;
  const latest=snap.chatFollowups[0];await useCases().queueReminder('chat.followup',{event_id:eventId,action:'edit',changes:{title:'CHAT_PHONE_LOOP_TEST 人工修改',at:due2}},latest.revision);
  repo=await Repository.open(context);snap=await snapshot();assert.equal(snap.chatFollowups[0].title,'CHAT_PHONE_LOOP_TEST 人工修改');
  await apply(repo,peer(await repo.pendingOperations()));snap=await snapshot();scheduler=new CalendarReminderScheduler(api,repo);await scheduler.reconcile(snap.reminders);assert.equal(api.creates,1);assert.equal(api.inventory[0].id,calendarId);assert.equal(api.inventory[0].startTime,Date.parse(due2));
  await apply(repo,peer([],100,{progress:'complete'}));snap=await snapshot();
  assert.equal(snap.chatFollowups[0].pending_change.action,'complete');assert.equal(snap.chatFollowups[0].status,'active');assert.equal(snap.chatFollowups[0].title,'CHAT_PHONE_LOOP_TEST 人工修改');
  let item=snap.chatFollowups[0];await useCases().queueReminder('chat.followup',{event_id:eventId,action:'dismiss_change'},item.revision);await apply(repo,peer(await repo.pendingOperations()));snap=await snapshot();assert.equal(snap.chatFollowups[0].pending_change,null);assert.equal(snap.chatFollowups[0].status,'active');
  await apply(repo,peer([],100,{progress:'update'}));snap=await snapshot();assert.equal(snap.chatFollowups[0].pending_change.time.date,'2030-10-12');
  item=snap.chatFollowups[0];await useCases().queueReminder('chat.followup',{event_id:eventId,action:'accept_change'},item.revision);await apply(repo,peer(await repo.pendingOperations()));snap=await snapshot();await scheduler.reconcile(snap.reminders);assert.equal(api.inventory[0].id,calendarId);assert.equal(api.creates,1);assert.equal(snap.chatFollowups[0].title,'CHAT_PHONE_LOOP_TEST 人工修改');
  const scheduledBefore=snap.reminders[0].scheduledAt, removesBefore=api.removes;
  await apply(repo,peer([],100,{progress:'ordinary'}));snap=await snapshot();
  item=snap.chatFollowups[0];await useCases().queueReminder('chat.followup',{event_id:eventId,action:'accept_change'},item.revision);await apply(repo,peer(await repo.pendingOperations()));snap=await snapshot();await scheduler.reconcile(snap.reminders);
  assert.equal(snap.reminders[0].status,'scheduled');assert.equal(snap.reminders[0].scheduledAt,scheduledBefore);assert.equal(api.inventory[0].id,calendarId);assert.equal(api.removes,removesBefore,'ordinary progress must preserve existing Calendar reminder');
  await apply(repo,peer([],100,{progress:'date_only'}));snap=await snapshot();assert.equal(snap.chatFollowups[0].pending_change.time.at,null);
  item=snap.chatFollowups[0];await useCases().queueReminder('chat.followup',{event_id:eventId,action:'accept_change'},item.revision);await apply(repo,peer(await repo.pendingOperations()));snap=await snapshot();await scheduler.reconcile(snap.reminders);assert.equal(snap.reminders[0].status,'stale');assert.equal(api.inventory.length,0,'date-only change must revoke the old time');
  // The same Event/ReminderSchedule resumes only after explicit execution time.
  item=snap.chatFollowups[0];await useCases().queueReminder('chat.followup',{event_id:eventId,action:'enable_reminder',changes:{at:due2,confirm_current:true}},item.revision);await apply(repo,peer(await repo.pendingOperations()));snap=await snapshot();await scheduler.reconcile(snap.reminders);assert.equal(api.inventory.length,1);assert.equal(snap.reminders.length,1);assert.equal(snap.chatFollowups[0].event_id,eventId);assert.equal(api.inventory[0].identifier,'allday-calendar-task:'+eventId);
  await scheduler.reconcile(snap.reminders);assert.equal(api.creates,2,'resume has one Calendar object and remains idempotent');
  await apply(repo,peer([],100,{progress:'complete'}));snap=await snapshot();
  item=snap.chatFollowups[0];await useCases().queueReminder('chat.followup',{event_id:eventId,action:'accept_change'},item.revision);await apply(repo,peer(await repo.pendingOperations()));snap=await snapshot();await scheduler.reconcile(snap.reminders);assert.equal(snap.chatFollowups[0].status,'completed');assert.equal(snap.reminders[0].status,'completed');assert.equal(api.inventory.length,0);
  await apply(repo,peer([],100,{replay_original:true}));snap=await snapshot();assert.equal(snap.chatFollowups[0].status,'completed');assert.equal(snap.chatFollowups.length,1);
  // Explicit reopen retains the same business ID and stable Calendar identifier.
  item=snap.chatFollowups[0];await useCases().queueReminder('chat.followup',{event_id:eventId,action:'reopen'},item.revision);await apply(repo,peer(await repo.pendingOperations()));snap=await snapshot();await scheduler.reconcile(snap.reminders);assert.equal(snap.chatFollowups[0].event_id,eventId);assert.equal(api.inventory.length,1);
  item=snap.chatFollowups[0];await useCases().queueReminder('chat.followup',{event_id:eventId,action:'cancel'},item.revision);await apply(repo,peer(await repo.pendingOperations()));snap=await snapshot();await scheduler.reconcile(snap.reminders);assert.equal(snap.chatFollowups[0].status,'cancelled');assert.equal(api.inventory.length,0);
  console.log('PASS chat Event → Phone SQLite/offline outbox → explicit first Calendar reminder → reschedule → complete → reopen → cancel; duplicate/receipt/restart/permissions, zero models');
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(()=>{for(const s of stores)s.db.close();fs.rmSync(temp,{recursive:true,force:true});});
