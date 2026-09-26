// Real UseCases + coordinator + ViewModel + on-disk repository; network adapter is controlled.
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),Module=require('node:module');
const {Repository,UseCases,stores,root,contract}=require('./phone-sqlite-harness.cjs');
global.Observed=c=>c;global.AppStorage={setOrCreate(){}};
const originalLoad=Module._load;
Module._load=function(name,...args){return name.startsWith('@kit.')||name.startsWith('@hms.')||name==='common'?{}:originalLoad.call(this,name,...args);};
const {PhoneV3ViewModel:VM}=require(path.join(root,'presentation/PhoneV3ViewModel.ets'));
const {ComputerConnectionError:Failure}=require(path.join(root,'../computer/ComputerConnectionError.ets'));
const id=n=>String(n).padStart(26,'0'),time='2026-09-26T00:00:00Z';
const row=n=>({utterance_id:id(n),session_id:id(900),speaker_track_id:null,speaker_label:null,original_speaker_track_id:null,
 original_speaker_label:null,identity:'unknown',original_identity:'unknown',identity_evidence:{},start_ms:n*1000,end_ms:n*1000+500,
 start_at:time,end_at:'2026-09-26T00:00:01Z',text:'SYNTHETIC',original_text:'SYNTHETIC',revision:1,status:'active',evidence:{}});
const change=(r,sequence)=>({sequence,resource_type:'utterance',resource_id:r.utterance_id,revision:r.revision,operation:'upsert',resource:r});
const wait=async check=>{const end=Date.now()+5000;while(!check()){assert(Date.now()<end,'condition deadline');await new Promise(r=>setTimeout(r,10));}};
(async()=>{
 const file=path.join(fs.mkdtempSync(path.join(os.tmpdir(),'phase2a-restart-')),'synthetic.db');
 let repo=await Repository.open({databasePath:file});
 await repo.applyChange({sequence:1,resource_type:'recording_session',resource_id:id(900),revision:1,operation:'upsert',resource:{session_id:id(900)}});
 for(let n=1;n<=3;n++)await repo.applyChange(change(row(n),n+1));
 let online=false,connects=0,active=0,max=0,syncCalls=0;const seen=new Map(),extraChanges=[];
 const session={status:async()=>({contract_version:contract.V3_CONTRACT_VERSION,projection_version:contract.V3_PROJECTION_VERSION}),
  sync:async req=>{syncCalls++;active++;max=Math.max(max,active);await new Promise(r=>setTimeout(r,5));
   const receipts=req.client_operations.map(op=>{assert(!seen.has(op.operation_id),'unexpected replay after acknowledgement');seen.set(op.operation_id,op);
    return {operation_id:op.operation_id,status:'applied',resource_revision:2,error:null};});
   const changes=req.client_operations.map((op,i)=>change({...row(Number(op.payload.selections[0].utterance_id)),revision:2},i+5)).concat(extraChanges.splice(0));active--;
   return {projection_version:contract.V3_PROJECTION_VERSION,receipts,changes,next_cursor:'cursor-8',has_more:false,server_time:time};},
  reviews:async()=>({items:[]}),annotations:async()=>({people:[]})};
 const remote={isPaired:async()=>true,connect:async()=>{connects++;if(!online)throw new Failure('unreachable','connect','synthetic offline');return session;}};
 const make=async r=>{const u=new UseCases(r,{list:async()=>[]},remote);const m=new VM(u);m.snapshot=await u.loadCached([]);m.startCoordinator();return m;};
 let model=await make(repo);
 for(const target of model.snapshot.sessions[0].utterances.slice()){
  let saved=false;model.saveAnnotation([target],'','',false,'non_speech',()=>saved=true);await wait(()=>saved&&!model.annotationSaving);
 }
 await wait(()=>connects>0);
 const durable=(await repo.pendingOperations()).map(o=>o.operation_id);assert.equal(durable.length,3);
 assert.equal(model.snapshot.sync.pendingOperations,3);model.stop();await model.retirement;
 stores.at(-1).db.close();repo=await Repository.open({databasePath:file});
 assert.deepEqual((await repo.pendingOperations()).map(o=>o.operation_id),durable);
 online=true;model=await make(repo);await wait(()=>seen.size===3&&model.snapshot.sync.pendingOperations===0);
 assert.equal((await repo.pendingOperations()).length,0);assert.equal(max,1);assert.deepEqual([...seen.keys()].sort(),durable.sort());
 assert(connects<=3);
 console.log('PASS 3 offline local saves, database reopen, automatic foreground convergence, durable IDs, one consumer, UI pending=0');
 model.annotationSaving=true;
 extraChanges.push(change({...row(1),revision:3,text:'UPDATE ONE'},9));
 const before=syncCalls;model.coordinator.trigger();await wait(()=>syncCalls>before&&!model.coordinator.light.running);
 assert.equal(model.syncProjectionDirty,true);
 model.annotationSaving=false;
 extraChanges.push(change({...row(2),revision:3,text:'UPDATE TWO'},10));model.coordinator.trigger();
 await wait(()=>model.snapshot.sessions[0].utterances.find(r=>r.utteranceId===id(2)).text==='UPDATE TWO');
 assert.equal(model.snapshot.sessions[0].utterances.find(r=>r.utteranceId===id(1)).text,'UPDATE ONE');
 console.log('PASS a deferred refresh retains previous changed rows when the next batch changes other rows');
 // A real local save is held before its commit; the last remote delta is already durable.
 // No successful network event follows it. Local visibility must not depend on another poll.
 let releaseSave;const queue=model.useCases.queueAnnotation.bind(model.useCases);
 const staleTarget=model.snapshot.sessions[0].utterances.find(r=>r.utteranceId===id(1));
 model.useCases.queueAnnotation=async(...args)=>{await new Promise(r=>releaseSave=r);return queue(...args);};
 model.saveAnnotation([model.snapshot.sessions[0].utterances[2]],'','',false,'media_speech',()=>{});
 await wait(()=>releaseSave);
 extraChanges.push(change({...row(1),revision:4,text:'LAST DURABLE DELTA'},11));
 const last=syncCalls;model.coordinator.trigger();await wait(()=>syncCalls>last&&!model.coordinator.light.running);
 online=false;const callsAtDisconnect=syncCalls;releaseSave();
 await wait(()=>!model.annotationSaving);
 await wait(()=>model.snapshot.sessions[0].utterances.find(r=>r.utteranceId===id(1)).text==='LAST DURABLE DELTA');
 assert.equal(syncCalls,callsAtDisconnect,'visibility must not need another successful network response');
 assert.equal(model.snapshot.sessions[0].utterances[2].soundKind,'media_speech');
 await assert.rejects(queue([staleTarget],'','',false,'non_speech'),/片段已变化/);
 model.stop();await model.retirement;
 console.log('PASS last deferred delta becomes visible after local commit with no later network event');
 console.log('PASS a stale selection of the changed row is rejected instead of bypassing revision safety');
 for(const s of stores){try{s.db.close();}catch{}}
})().catch(e=>{console.error(e);process.exit(1);});
