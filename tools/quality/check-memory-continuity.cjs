const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawnSync}=require('node:child_process');
const {Repository,UseCases,stores,apply}=require('./phone-sqlite-harness.cjs');
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'cross-day-phone-'));let cursor=null;
function peer(extra={}) {const asr=process.env.CHAT_PHONE_ASR_ROOT;const r=spawnSync(process.env.CHAT_PHONE_PYTHON,[path.join(asr,'tools/cross_day_memory_phone_fixture.py'),path.join(temp,'asr')],{cwd:asr,input:JSON.stringify({cursor,...extra}),encoding:'utf8',env:{...process.env,PYTHONIOENCODING:'utf-8',PYTHONPATH:asr+path.delimiter+path.join(asr,'src')},timeout:30000});assert.equal(r.status,0,r.stderr);const v=JSON.parse(r.stdout);cursor=v.next_cursor;return v;}
(async()=>{
 const ctx={databasePath:path.join(temp,'phone.db')};let repo=await Repository.open(ctx);
 const use=()=>new UseCases(repo,{list:async()=>[]},{isPaired:async()=>true});
 const old=peer();await apply(repo,old);let s=await use().loadCached([]);const c=s.memoryIndex.candidates[0];
 const switched=peer({window:true});await apply(repo,switched);s=await use().loadCached([]);
 assert.equal(s.memoryIndex.scope.first,'2026-10-08');assert.equal(s.memoryIndex.discussions.length,1);
 let history=s.memoryPages.find(p=>p.page?.number===1&&p.page.kind==='discussions');
 assert(history);assert(history.candidates.some(v=>v.source===c.source&&v.target===c.target));
 assert.equal(history.discussions.length,3,'old discussions remain on a distinct cached history page');
 repo=await Repository.open(ctx);await apply(repo,old);s=await use().loadCached([]);
 assert.equal(s.memoryIndex.scope.first,'2026-10-08');assert.equal(s.memoryPages.length,2);
 const independent=history.discussions.find(r=>!r.event_id).id, destination=history.discussions.find(r=>r.event_id).id;
 for(const action of ['reject','link','detach']) {
   s=await use().loadCached([]);await use().queueMemory({source:action==='reject'?c.source:independent,target:action==='reject'?c.target:destination,action},s.memoryIndex.revision);
   assert.equal((await use().loadCached([])).memoryPending,true);
   const operations=await repo.pendingOperations();const result=peer({operations});await apply(repo,result);
   assert.equal(result.receipts[0].status,'applied',JSON.stringify({action,base:s.memoryIndex.revision,receipt:result.receipts,index:result.changes.filter(x=>x.resource_type==='memory_index').map(x=>({id:x.resource_id,revision:x.revision}))}));assert.equal((await repo.pendingOperations()).length,0);
   const duplicate=peer({operations});assert.deepEqual(duplicate.receipts,result.receipts);await apply(repo,duplicate);
   repo=await Repository.open(ctx);await apply(repo,switched);
   s=await use().loadCached([]);assert.equal(s.memoryIndex.scope.first,'2026-10-08');
   assert(!s.memoryPages.some(p=>p.candidates.some(v=>v.source===c.source&&v.target===c.target)));
 }
 console.log('PASS actual Phone SQLite historical page → outbox reject/link/detach → receipts/restart/repeated sync/old revision replay; zero models');
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(()=>{for(const s of stores)s.db.close();fs.rmSync(temp,{recursive:true,force:true});});
