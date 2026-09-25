const assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs'),os=require('node:os');
const {Repository,UseCases,stores,contract,apply}=require('./phone-sqlite-harness.cjs');
const data=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const base={...data.response,receipts:[],changes:[],has_more:false};
async function create(){
 const databasePath=path.join(fs.mkdtempSync(path.join(os.tmpdir(),'closeout-phone-')),'synthetic.sqlite');
 const repo=await Repository.open({databasePath});await repo.enqueue(data.operation);
 return {repo,databasePath};
}
async function model(repo){const use=new UseCases(repo,{list:async()=>[]},{isPaired:async()=>true,connect:async()=>{throw Error('no network');}});return (await use.loadCached([])).sessions.flatMap(s=>s.utterances);}
async function visible(repo,uid=data.corrected_uid){return (await model(repo)).find(r=>r.utteranceId===uid);}
(async()=>{
 // Receipt before pages; per-resource overlays stop independently. No group max.
 let {repo,databasePath}=await create();
 await apply(repo,{...base,receipts:data.response.receipts,next_cursor:'cursor-0'});
 const boundary=data.response.changes.findIndex(c=>c.resource_id===data.corrected_uid&&c.revision===2);
 const early=data.response.changes.slice(0,boundary+1),last=data.response.changes.slice(boundary+1);
 assert(last.some(c=>c.revision===6));
 await apply(repo,{...base,changes:early,next_cursor:`cursor-${early.at(-1).sequence}`});
 let overlays=await repo.annotationOperations();assert.deepEqual(overlays[0].projected_resource_ids,[data.corrected_uid]);
 const other=data.operation.payload.selections[1].utterance_id;
 assert.equal((await visible(repo,other)).soundKind,'non_speech');
 // A newer authoritative correction cannot be masked even while another selected
 // resource is still awaiting its projection. Real emitted DTO, not a forged model.
 await apply(repo,data.late_response);
 assert.equal((await visible(repo)).soundKind,'speech');assert.equal((await visible(repo)).annotationPending,false);
 const pending={...data.operation,operation_id:'00000000000000000000000777',payload:{selections:[{utterance_id:data.corrected_uid,revision:3}],sound_kind:'media_speech'}};
 await repo.enqueue(pending);assert.equal((await visible(repo)).soundKind,'media_speech');assert.equal((await visible(repo)).annotationPending,true);
 await apply(repo,{...base,changes:last});
 assert.equal((await repo.v3Status()).pendingOperations,1);
 assert.equal((await repo.pendingOperations())[0].operation_id,pending.operation_id);
 console.log('PASS per-resource overlay completion, later authoritative correction and newer unsent local overlay');

 // v9 already-stuck accepted row: immutable replay obtains current snapshot targets.
 ({repo,databasePath}=await create());await apply(repo,{...data.response,receipts:[]});await apply(repo,data.late_response);
 let db=stores.at(-1).db;db.prepare('UPDATE outbox SET applied_revision=6').run();db.exec('DROP TABLE outbox_resource_receipts; PRAGMA user_version=9');db.close();
 repo=await Repository.open({databasePath});assert.equal(stores.at(-1).version,10);
 assert.deepEqual((await repo.pendingOperations())[0].payload,data.operation.payload);
 let sent=[];const session={status:async()=>({contract_version:contract.V3_CONTRACT_VERSION,projection_version:contract.V3_PROJECTION_VERSION}),
 sync:async req=>{sent.push(req.client_operations);return data.recovery_response;},reviews:async()=>({items:[]}),annotations:async()=>({people:[]})};
 const use=new UseCases(repo,{list:async()=>[]},{connect:async()=>session});
 const result=await use.synchronize();assert.equal(result.remainingOperations,0);assert.equal(result.completion,'complete');
 assert.deepEqual(sent.flat().map(({attempt_count,...op})=>op),[data.operation]);
 assert.equal((await visible(repo)).soundKind,'speech');assert.equal((await visible(repo)).annotationPending,false);
 stores.at(-1).db.close();repo=await Repository.open({databasePath});assert.equal((await repo.v3Status()).pendingOperations,0);
 console.log('PASS persisted v9 stale batch -> v10 -> original-payload replay -> per-resource recovery -> restart convergence');

 // Entire receipt/projection transaction failure rolls back metadata as well.
 ({repo,databasePath}=await create());const store=stores.at(-1),execute=store.executeSql.bind(store);let fail=true;
 store.executeSql=async(sql,params)=>{if(fail&&sql.includes('UPDATE sync_state SET cursor')){fail=false;throw Error('local transaction fault');}return execute(sql,params);};
 await assert.rejects(apply(repo,data.response),/local transaction fault/);
 assert.equal(store.db.prepare('SELECT count(*) n FROM outbox_resource_receipts').get().n,0);
 assert.equal((await repo.pendingOperations()).length,1);
 await apply(repo,data.response);assert.equal((await repo.v3Status()).pendingOperations,0);
 await repo.enqueue(data.noop_operation);await apply(repo,data.noop_response);assert.equal((await repo.v3Status()).pendingOperations,0);
 console.log('PASS local transaction rollback/replay and applied no-op with unchanged revision');

 ({repo,databasePath}=await create());await apply(repo,{...base,receipts:data.response.receipts,changes:data.response.changes.filter(c=>c.resource_type!=='utterance')});
 const tombstones=data.response.receipts[0].resource_results.map((r,i)=>({sequence:100+i,resource_type:'utterance',resource_id:r.resource_id,revision:r.revision+1,operation:'tombstone',resource:null}));
 await apply(repo,{...base,changes:tombstones,next_cursor:'cursor-101'});assert.equal((await repo.v3Status()).pendingOperations,0);
 console.log('PASS authoritative tombstones retire overlays without clearing unrelated pending work');
 for(const s of stores){try{s.db.close()}catch{}}
})().catch(e=>{console.error(e);process.exitCode=1;});
