// Display decisions over real Phone SQLite, followed by existing command/outbox semantics.
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {Repository,UseCases,apply,stores,root}=require('./phone-sqlite-harness.cjs');
const {productTasks,productTaskMatches,productAttention,productCalendarLabel}=require(path.join(root,'presentation/PhoneProductTasks.ets'));
const {productDay}=require(path.join(root,'presentation/PhoneProductHome.ets'));
const {recallProductEvidence,chatProductEvidence,productEvidenceQuery,productQuoteContext}=require(path.join(root,'presentation/PhoneProductEvidence.ets'));
const {productRecallAnswer,productRecallCoverage}=require(path.join(root,'presentation/PhoneProductRecall.ets'));
const fixture=JSON.parse(fs.readFileSync(path.resolve('tests/fixtures/phone-product-v2.json'),'utf8'));
(async()=>{
 assert(!productRecallAnswer({...fixture.query,answer:'找到200条，上限100'}).includes('100'));assert(!productRecallCoverage({...fixture.query,coverage:['预算100前2后4 Mac']}).includes('Mac'));
 const repo=await Repository.open({databasePath:path.join(fs.mkdtempSync(path.join(os.tmpdir(),'phone-product-v2-')),'isolated.sqlite')});
 const use=new UseCases(repo,{list:async()=>[]},{isPaired:async()=>true});await apply(repo,fixture.packet);
 const snap=await use.loadCached([]),before=JSON.stringify(snap.chatFollowups);
 let tasks=productTasks(snap);
 assert.equal(tasks.filter(t=>productTaskMatches(t,'self')).length,2,'one arranged self task plus one explicitly confirmed followup');
 assert.equal(tasks.find(t=>t.chat?.historical).category,'clues','historical promises must never masquerade as daily tasks');
 assert.equal(tasks.filter(t=>t.category==='waiting').length,1);
 assert.equal(tasks.filter(t=>t.category==='scheduled').length,1);
 assert.equal(JSON.stringify(snap.chatFollowups),before,'display mapping cannot mutate canonical state');
 assert(!productAttention(snap,Date.parse('2026-10-14T12:00:00+08:00')).some(t=>t.chat?.historical));
 const cache=await use.loadDailyCache();const day=productDay(cache,'2026-10-14');
 assert.equal(day.highlights.length,2);assert(day.highlights.every(h=>h.evidence.length));assert.equal(day.timeline.length,1);
 assert.equal(productDay(cache,'2026-10-15').date,'2026-10-14','missing current summary falls back to real historical content');
 const partial=structuredClone(cache);partial.summaries[0].objective.unified_review.coverage.missing_sources=['QQ'];assert.match(productDay(partial,'2026-10-14').coverage,/部分/);
 const failed=structuredClone(cache);failed.summaries[0].objective.unified_review.status='failed';assert.equal(productDay(failed,'2026-10-14').highlights.length,2);assert.match(productDay(failed,'2026-10-14').notice,/未更新/);
 const ungrounded=structuredClone(cache);ungrounded.summaries[0].objective.unified_review.evidence=[];assert.equal(productDay(ungrounded,'2026-10-14').highlights.length,0,'no fabricated unsupported summary');
 assert.equal(productDay({summaries:[],events:[]},'2026-10-14').highlights.length,0);
 assert.match(recallProductEvidence(fixture.context.evidence[1]).identity,/未确认/);assert.match(recallProductEvidence({...fixture.query.evidence[1],validity:'stale'}).meaning,/不代表/);
 assert.equal(recallProductEvidence({...fixture.query.evidence[1],validity:'stale'}).unavailable,true);
 console.log('PASS grounded current/history fallback, partial/model failure/empty states, identity boundary and historical task separation');
 const chat=snap.chatFollowups.find(c=>c.user_confirmed);const cited=chatProductEvidence(chat.evidence[0]);const bounded=productEvidenceQuery(cited,'owned-citation-query');assert.equal(bounded.sent_to-bounded.sent_from,2);assert.equal(bounded.source,'wechat');assert.equal(bounded.summarize,false);assert.equal(bounded.expand,false);assert.equal(productEvidenceQuery({...cited,stamp:0},'owned-citation-query'),undefined);
 const task=tasks.find(t=>t.category==='scheduled');
 let sequence=fixture.packet.changes.length;
 for(const action of ['reschedule','complete','cancel']){
   const writeRepo=await Repository.open({databasePath:path.join(fs.mkdtempSync(path.join(os.tmpdir(),'phone-product-command-')),'isolated.sqlite')});await apply(writeRepo,fixture.packet);const writeUse=new UseCases(writeRepo,{list:async()=>[]},{isPaired:async()=>true});
   const current=(await writeUse.loadCached([])).reminders[0];
   const due=new Date(Date.now()+7200000).toISOString();
   await writeUse.queueReminder('reminder.task',{event_id:task.id,action,...(action==='reschedule'?{title:'修改后的材料事项',scheduled_at:due}:{})},current.eventRevision);
   const op=(await writeRepo.pendingOperations())[0];assert.equal(op.payload.event_id,task.id);assert.equal(op.payload.action,action);
   const overlay=(await writeUse.loadCached([])).reminders[0];assert.equal(overlay.pendingAction,action);
   if(action==='reschedule'){assert.equal(overlay.scheduledAt,due);}else{assert.equal(overlay.status,action==='complete'?'completed':'cancelled');}
   const resource={...fixture.packet.changes[0].resource,event_revision:current.eventRevision+1,status:action==='complete'?'completed':action==='cancel'?'cancelled':'scheduled',scheduled_at:due};
   await apply(writeRepo,{projection_version:7,server_time:new Date().toISOString(),changes:[{sequence:++sequence,resource_type:'reminder',resource_id:task.id,revision:resource.event_revision,operation:'upsert',resource}],receipts:[{operation_id:op.operation_id,status:'applied',resource_revision:resource.event_revision,error:null,resource_results:[{resource_id:task.id,revision:resource.event_revision}]}],next_cursor:'cursor-'+sequence,has_more:false});
   if(action!=='reschedule'){const ended=productTasks(await writeUse.loadCached([])).find(t=>t.id===task.id);assert.match(ended.explanation,/已结束/);assert(!ended.explanation.includes('需要我执行'));assert.match(ended.time,/原定/);}
   assert.equal((await writeRepo.pendingOperations()).length,0);assert.equal((await writeUse.loadCached([])).reminders[0].pendingAction,'');
 }
 assert.deepEqual(productQuoteContext(null),[]);assert.deepEqual(productQuoteContext(undefined),[]);assert.match(productCalendarLabel('error',true),/移除/);
 console.log('PASS mapped task ID → real queue: modify/complete/cancel, pending overlay and authoritative receipts in isolated SQLite');
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(()=>{for(const s of stores)s.db.close();});
