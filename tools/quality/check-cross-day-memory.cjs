const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawnSync}=require('node:child_process');
const {Repository,UseCases,stores,apply}=require('./phone-sqlite-harness.cjs');
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'cross-day-phone-'));let cursor=null;
function peer(extra={}) {const asr=process.env.CHAT_PHONE_ASR_ROOT;const r=spawnSync(process.env.CHAT_PHONE_PYTHON,[path.join(asr,'tools/cross_day_memory_phone_fixture.py'),path.join(temp,'asr')],{cwd:asr,input:JSON.stringify({cursor,...extra}),encoding:'utf8',env:{...process.env,PYTHONIOENCODING:'utf-8',PYTHONPATH:asr+path.delimiter+path.join(asr,'src')},timeout:30000});assert.equal(r.status,0,r.stderr);const v=JSON.parse(r.stdout);cursor=v.next_cursor;return v;}
(async()=>{
 const ctx={databasePath:path.join(temp,'phone.db')};let repo=await Repository.open(ctx);
 let use=()=>new UseCases(repo,{list:async()=>[]},{isPaired:async()=>true});
 const first=peer();await apply(repo,first);
 let snapshot=await use().loadCached([]),index=snapshot.memoryIndex;
 assert.equal(index.people.length,1);assert.equal(index.things.length,2);assert.equal(index.candidates.length,1);
 assert.equal(index.discussions[1].evidence[0].quote,'准备婉拒招聘机会');
 const c=index.candidates[0];await use().queueMemory({source:c.source,target:c.target,action:'reject'},index.revision);
 assert.equal((await use().loadCached([])).memoryPending,true);
 let operations=await repo.pendingOperations();const rejected=peer({operations});await apply(repo,rejected);
 assert.equal(rejected.receipts[0].status,'applied');assert.equal((await repo.pendingOperations()).length,0);
 index=(await use().loadCached([])).memoryIndex;assert.equal(index.candidates.length,0);
 const [a,b,d]=index.discussions.map(r=>r.id);
 await use().queueMemory({source:d,target:a,action:'link'},index.revision);operations=await repo.pendingOperations();const linked=peer({operations});await apply(repo,linked);
 index=(await use().loadCached([])).memoryIndex;assert.equal(index.things.length,1);
 repo=await Repository.open(ctx);index=(await use().loadCached([])).memoryIndex;assert.equal(index.things.length,1);
 await apply(repo,first);assert.equal((await use().loadCached([])).memoryIndex.things.length,1,'old revision replay cannot override human association');
 await use().queueMemory({source:d,target:a,action:'detach'},index.revision);operations=await repo.pendingOperations();const detached=peer({operations});await apply(repo,detached);
 index=(await use().loadCached([])).memoryIndex;assert.equal(index.things.length,2);assert.equal(index.candidates.length,0,'detach/reject tombstone suppresses reply candidate');
 await apply(repo,linked);assert.equal((await use().loadCached([])).memoryIndex.things.length,2);
 const arrival=peer({arrival:true});await apply(repo,arrival);index=(await use().loadCached([])).memoryIndex;
 assert.equal(index.discussions.length,4);assert.equal(index.things.length,3);assert.equal(index.candidates.length,0);
 assert.equal(index.scope.coverage.incremental.deferred_discussions,2);
 const arrivedRevision=index.revision;await apply(repo,peer({arrival:true}));assert.equal((await use().loadCached([])).memoryIndex.revision,arrivedRevision);
 repo=await Repository.open(ctx);await apply(repo,detached);index=(await use().loadCached([])).memoryIndex;
 assert.equal(index.revision,arrivedRevision);assert.equal(index.discussions.length,4);assert.equal(index.candidates.length,0);
 await apply(repo,peer({invalidate:true}));index=(await use().loadCached([])).memoryIndex;assert.equal(index.discussions[0].evidence_status,'source_changed_or_missing');
 repo=await Repository.open(ctx);snapshot=await use().loadCached([]);assert.equal(snapshot.memoryIndex.discussions[0].evidence_status,'source_changed_or_missing');assert.equal((await repo.pendingOperations()).length,0);
 await use().queueMemory({source:d,target:a,action:'link'},1);operations=await repo.pendingOperations();const stale=peer({operations,invalidate:true});await apply(repo,stale);assert.equal(stale.receipts[0].status,'conflict');assert.equal((await repo.pendingOperations()).length,0);assert.equal((await repo.conflictRows()).length,1);
 // The schema-20 upgrade adds only rebuildable memory rows, preserving cursor and unrelated projections.
 const before=await repo.currentCursor();stores[stores.length-1].db.exec('DROP TABLE projection_memory_indexes; PRAGMA user_version=20');repo=await Repository.open(ctx);assert.equal(await repo.currentCursor(),before);assert.deepEqual(await repo.projectionRows('memory_index'),[]);
 console.log('PASS cross-day ASR → actual Phone SQLite/outbox → reject/link/detach → restart/old replay → new arrivals/idempotent decisions → invalid evidence → stale receipt conflict → schema 20 upgrade; zero models');
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(()=>{for(const s of stores)s.db.close();fs.rmSync(temp,{recursive:true,force:true});});
