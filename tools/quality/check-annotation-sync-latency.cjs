// Production UseCases/ViewModel/coordinator and real on-disk SQLite; controlled remote only.
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),Module=require('node:module');
const {Repository,UseCases,stores,root,contract}=require('./phone-sqlite-harness.cjs');
const {loadFixtureTranscript}=require('./phone-paged-fixture.cjs');
global.Observed=c=>c;global.AppStorage={setOrCreate(){}};
const orig=Module._load;Module._load=function(name,...args){return name.startsWith('@kit.')||name.startsWith('@hms.')||name==='common'?{}:orig.call(this,name,...args)};
const {PhoneV3ViewModel:VM}=require(path.join(root,'presentation/PhoneV3ViewModel.ets'));
const {ComputerConnectionError:Failure}=require(path.join(root,'../computer/ComputerConnectionError.ets'));
const id=n=>String(n).padStart(26,'0'),time='2026-09-27T00:00:00Z';
const row=n=>({utterance_id:id(n),session_id:id(900),speaker_track_id:null,speaker_label:null,original_speaker_track_id:null,original_speaker_label:null,identity:'unknown',original_identity:'unknown',identity_evidence:{},start_ms:n*1000,end_ms:n*1000+500,start_at:time,end_at:'2026-09-27T00:00:01Z',text:'SYNTHETIC',original_text:'SYNTHETIC',revision:1,status:'active',evidence:{}});
const change=(r,sequence)=>({sequence,resource_type:'utterance',resource_id:r.utterance_id,revision:r.revision,operation:'upsert',resource:r});
const wait=async f=>{const end=Date.now()+5000;while(!await f()){assert(Date.now()<end,'deadline');await new Promise(r=>setTimeout(r,5));}};
(async()=>{
 const repo=await Repository.open({databasePath:path.join(fs.mkdtempSync(path.join(os.tmpdir(),'annotation-latency-')),'synthetic.db')});
 await repo.applyChange({sequence:1,resource_type:'recording_session',resource_id:id(900),revision:1,operation:'upsert',resource:{session_id:id(900)}});
 for(let n=1;n<=3;n++)await repo.applyChange(change(row(n),n+1));
 let release,rejectRead,seen=[],active=0,maxActive=0,readStarted=false;const deltas=[];
 const session={status:async()=>({contract_version:contract.V3_CONTRACT_VERSION,projection_version:contract.V3_PROJECTION_VERSION}),
 sync:async req=>{active++;maxActive=Math.max(maxActive,active);seen.push(...req.client_operations);active--;return {projection_version:contract.V3_PROJECTION_VERSION,receipts:req.client_operations.map(op=>({operation_id:op.operation_id,status:'applied',resource_revision:2,error:null})),changes:deltas.splice(0),next_cursor:'cursor-0',has_more:false,server_time:time}},
 reviews:async()=>{readStarted=true;return new Promise((res,rej)=>{release=()=>res({items:[]});rejectRead=()=>rej(new Failure('unreachable','response','synthetic reviews failure'));})},annotations:async()=>({people:[]})};
 const u=new UseCases(repo,{list:async()=>[]},{isPaired:async()=>true,connect:async()=>session});
 const model=new VM(u);model.syncService={run:(_owner,action)=>action(),cancel(){}};
 model.snapshot=await loadFixtureTranscript(u,await u.loadCached([]));model.startCoordinator();
 const save=async n=>{await loadFixtureTranscript(u,model.snapshot);let done=false;model.saveAnnotation([model.snapshot.sessions[0].utterances.find(x=>x.utteranceId===id(n))],'',n===1?'Synthetic Person':'',n===1,n===1?'':'non_speech',()=>done=true);await wait(()=>done&&!model.annotationSaving);};
 await save(1);await wait(()=>readStarted&&seen.length===1&&model.snapshot.sync.pendingOperations===0);
 await loadFixtureTranscript(u,model.snapshot);
 assert.equal(model.snapshot.sync.confirmedOperations,1,'accepted overlay stays durable awaiting projection');
 assert.equal(model.snapshot.sessions[0].utterances.find(x=>x.utteranceId===id(1)).annotationPending,false);
 await save(2);await wait(()=>seen.length===2&&model.snapshot.sync.pendingOperations===0);
 assert.equal(model.snapshot.sync.confirmedOperations,2);assert.equal(maxActive,1);
 assert.deepEqual(seen.map(op=>op.kind),['speaker.assign','segment.classify']);
 console.log('PASS blocked reviews does not hold single outbox lane; two commits visible before release; overlays retained');
 rejectRead();await wait(()=>model.supplementaryError.length>0);
 assert.equal(model.computerSyncError,'');assert.equal(model.snapshot.sync.pendingOperations,0);
 model.coordinator.trigger();await wait(()=>!model.coordinator.light.running&&model.snapshot.sync.pendingOperations===0);
 assert.equal(model.snapshot.sync.confirmedOperations,2);
 // Authority arrives later; empty receipts must retire overlays and notify.
 for(let n=1;n<=2;n++)deltas.push(change({...row(n),revision:2},n+10));
 model.coordinator.trigger();await wait(()=>model.snapshot.sync.confirmedOperations===0);
 assert.equal((await repo.annotationOperations()).length,0);
 console.log('PASS reviews failure stays local; empty incremental response converges; delayed authority retires overlays');
 model.stop();if(release)release();await model.retirement;for(const s of stores){try{s.db.close()}catch{}}
})().catch(e=>{console.error(e);process.exit(1)});
