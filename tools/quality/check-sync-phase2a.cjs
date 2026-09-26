const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {Repository,UseCases,stores,contract}=require('./phone-sqlite-harness.cjs');
const id=n=>String(n).padStart(26,'0');
const dto=(n,session=900)=>({utterance_id:id(n),session_id:id(session),speaker_track_id:null,speaker_label:null,
original_speaker_track_id:null,original_speaker_label:null,identity:'unknown',original_identity:'unknown',
identity_evidence:{},start_ms:0,end_ms:1000,start_at:'2026-09-26T00:00:00Z',end_at:'2026-09-26T00:00:01Z',
text:'SYNTHETIC',original_text:'SYNTHETIC',revision:1,status:'active',evidence:{}});
const change=r=>({sequence:1,resource_type:'utterance',resource_id:r.utterance_id,revision:r.revision,operation:'upsert',resource:r});
(async()=>{
const file=path.join(fs.mkdtempSync(path.join(os.tmpdir(),'phase2a-')),'synthetic.db');
const repo=await Repository.open({databasePath:file});
for(const n of [900,901])await repo.applyChange({sequence:1,resource_type:'recording_session',resource_id:id(n),revision:1,operation:'upsert',resource:{session_id:id(n)}});
await repo.applyChange(change(dto(1)));await repo.applyChange(change(dto(3,901)));
const op=(n,target,deps=[])=>({operation_id:id(n),kind:'segment.classify',base_revision:null,payload:{selections:[{utterance_id:id(target),revision:1}],sound_kind:'non_speech',depends_on:deps}});
await repo.enqueue(op(101,2));await repo.enqueue(op(102,1));await repo.enqueue(op(103,1,[id(101)]));
assert.deepEqual((await repo.pendingOperations()).map(o=>o.operation_id),[id(102)]);
assert.equal((await repo.conflictRows()).length,0);
await repo.applyChange(change(dto(2)));
assert.deepEqual((await repo.pendingOperations()).map(o=>o.operation_id),[id(101),id(102)]);
console.log('PASS absent resource waits durably; ready branch proceeds; resource arrival unblocks only eligible dependencies');
let release,backupDone=false,sent=[];
const session={status:async()=>({contract_version:contract.V3_CONTRACT_VERSION,projection_version:contract.V3_PROJECTION_VERSION}),
sync:async req=>{sent.push(...req.client_operations.map(o=>o.operation_id));return {projection_version:contract.V3_PROJECTION_VERSION,
next_cursor:'cursor-0',has_more:false,server_time:'2026-09-26T00:00:00Z',changes:[],receipts:req.client_operations.map(o=>({operation_id:o.operation_id,status:'applied',resource_revision:1,error:null}))};},
reviews:async()=>({items:[]}),annotations:async()=>({people:[]})};
const use=new UseCases(repo,{list:async()=>{throw Error('unexpected recording scan');}},{connect:async()=>session,isPaired:async()=>true},undefined,
{backup:async()=>{await new Promise(r=>release=r);backupDone=true;return {sessions:1,uploadedFiles:2,skippedFiles:0};}});
const backup=use.backupRecordings();const result=await use.synchronize(()=>{},false,1);
assert.equal(backupDone,false);assert(sent.includes(id(102)));assert.equal(result.completion,'budget_exhausted');
await use.synchronize();assert(sent.includes(id(103)));release();await backup;
console.log('PASS metadata receipts before backup completion; one-batch budget resumes dependent operation without new IDs');
const snapshot=await use.loadCached([]);
const unchanged=snapshot.sessions.find(s=>s.sessionId===id(901));
await repo.applyChange(change({...dto(1),revision:2,text:'SYNTHETIC UPDATED'}));
const queries=[],original=repo.projectionRows.bind(repo);
repo.projectionRows=async(type,ids)=>{queries.push({type,ids});return original(type,ids);};
const updated=await use.refreshUtterances(snapshot,[id(1)]);
assert.equal(updated.sessions.find(s=>s.sessionId===id(901)),unchanged);
assert.equal(updated.sessions.find(s=>s.sessionId===id(900)).utterances.find(r=>r.utteranceId===id(1)).text,'SYNTHETIC UPDATED');
assert.deepEqual(queries,[{type:'utterance',ids:[id(1)]}]);
console.log('PASS incremental utterance refresh queries only changed IDs, retains unrelated session, zero recording scans');
await repo.enqueue(op(104,3));
await repo.acknowledgeReceipt({operation_id:id(104),status:'applied',resource_revision:2,error:null});
await repo.applyChange(change({...dto(3,901),revision:2}));
assert((await repo.annotationOperations()).some(o=>o.operation_id===id(104)));
const retired=await use.synchronize();
assert.equal(retired.changed,true);assert.equal(retired.requiresReload,true);
assert(!(await repo.annotationOperations()).some(o=>o.operation_id===id(104)));
console.log('PASS empty remote page retires an applied local overlay and invalidates cached UI');
for(const store of stores)store.db.close();
})().catch(e=>{console.error(e);process.exitCode=1;});
