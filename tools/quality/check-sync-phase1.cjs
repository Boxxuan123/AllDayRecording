// Real SQL/use cases/ViewModel; native adapters only. Synthetic disk data.
const assert = require('node:assert/strict'), fs = require('node:fs'), os = require('node:os'), path = require('node:path'), Module = require('node:module');
const {Repository,UseCases,stores,apply,root,contract} = require('./phone-sqlite-harness.cjs');
global.Observed = c=>c; global.AppStorage = {setOrCreate(){}};
const oldLoad = Module._load;
Module._load = function(name,...args) { return name.startsWith('@kit.') || name.startsWith('@hms.') || name==='common' ? {} : oldLoad.call(this,name,...args); };
const {PhoneV3ViewModel:VM} = require(path.join(root,'presentation/PhoneV3ViewModel.ets'));
const {PhoneV3Snapshot:Snapshot} = require(path.join(root,'domain/PhoneV3Models.ets'));
const time='2026-09-26T00:00:00Z', id=n=>String(n).padStart(26,'0');
const dto=n=>({utterance_id:id(n),session_id:id(900000),speaker_track_id:null,speaker_label:null,original_speaker_track_id:null,
  original_speaker_label:null,identity:'unknown',original_identity:'unknown',identity_evidence:{},start_ms:n*1000,end_ms:n*1000+900,
  start_at:time,end_at:'2026-09-26T00:00:01Z',text:'SYNTHETIC',original_text:'SYNTHETIC',revision:1,status:'active',evidence:{}});
const change=row=>({sequence:1,resource_type:'utterance',resource_id:row.utterance_id,revision:row.revision,operation:'upsert',resource:row});
const response=(changes=[],receipts=[])=>({projection_version:contract.V3_PROJECTION_VERSION,changes,receipts,next_cursor:'cursor-1',has_more:false,server_time:time});
const tick=()=>new Promise(r=>setImmediate(r));
const wait=async predicate=>{const end=Date.now()+3000;while(!predicate()){assert(Date.now()<end,'deadline');await tick();}};
(async()=>{
 const report=[];
 for(const history of [0,1000,10000]) {
  const file=path.join(fs.mkdtempSync(path.join(os.tmpdir(),'sync-phase1-')),'synthetic.db');
  const repo=await Repository.open({databasePath:file}), store=stores.at(-1);
  await repo.beginTransaction();
  await repo.applyChange({sequence:1,resource_type:'recording_session',resource_id:id(900000),revision:1,operation:'upsert',resource:{session_id:id(900000),captured_start:time}});
  for(let n=1;n<=history+2;n++) await repo.applyChange(change(dto(n)));
  // Unrelated pending operations are indexed, too; closed operations are absent.
  for(let n=3;n<=history+2;n++) await repo.enqueue({operation_id:id(100000+n),kind:'segment.classify',base_revision:null,
    payload:{selections:[{utterance_id:id(n),revision:1}],sound_kind:'non_speech',person_name:'synthetic'}});
  await repo.commit();
  let network=0,scans=0;
  const use=new UseCases(repo,{list:async()=>{scans++;return [];}},{isPaired:async()=>false,connect:async()=>{network++;throw Error('offline');}});
  const snapshot=await use.loadCached([]), vm=new VM(use);vm.snapshot=snapshot;
  const row=snapshot.sessions[0].utterances.find(r=>r.utteranceId===id(1));
  const query=store.querySql.bind(store);let queries=0,returned=0;
  store.querySql=async(sql,params)=>{queries++;const result=await query(sql,params);const next=result.goToNextRow;
    result.goToNextRow=()=>{const found=next();if(found)returned++;return found;};return result;};
  const durations=[];let completed=0;
  for(let n=0;n<8;n++) {
   const start=performance.now();vm.saveAnnotation([row],'','',false,n%2?'media_speech':'non_speech',()=>completed++);
   vm.saveAnnotation([row],'','',false,'non_speech',()=>{throw Error('duplicate callback');});
   await wait(()=>!vm.annotationSaving);assert.equal(completed,n+1);durations.push(performance.now()-start);
  }
  assert.equal(network,0);assert.equal(scans,0);assert.equal(queries,16); // 1 target + 1 indexed dependency query per save
  assert.equal(returned,36); // one target plus only that target's growing dependency chain
  const ops=await repo.annotationOperations([id(1)]);assert.equal(ops.length,8);
  await assert.rejects(use.synchronize(),/offline/);
  assert((await repo.annotationOperations([id(1)])).every(op=>!op.last_error),'pre-dispatch failure must not taint local operations');
  assert.equal(ops.at(-1).payload.depends_on.length,7);
  durations.sort((a,b)=>a-b);report.push({history,repeats:8,p50:durations[3],p95:durations[7],max:durations[7],queries:16,returned:36,scans,saveNetworkCalls:network-1});
  // Save and receipt application serialize without nesting; old resource cannot regress revision.
  await Promise.all([use.queueAnnotation([row],'','',false,'unintelligible'),apply(repo,response([change({...dto(2),revision:2})]))]);
  assert.equal((await repo.projectionRows('utterance',[id(2)]))[0].revision,2);
  await apply(repo,response([change(dto(2))]));assert.equal((await repo.projectionRows('utterance',[id(2)]))[0].revision,2);
  await apply(repo,response([{...change(dto(2)),operation:'tombstone',resource:null}]));
  assert.equal((await repo.projectionRows('utterance',[id(2)]))[0].revision,2);
  await apply(repo,response([{...change({...dto(2),revision:3}),operation:'tombstone',resource:null}]));
  await apply(repo,response([change({...dto(2),revision:2})]));
  assert.equal((await repo.projectionRows('utterance',[id(2)])).length,0,'old upsert cannot resurrect a tombstone');
  const committed=store.commit.bind(store);store.commit=()=>{throw Error('synthetic commit failure');};
  const before=(await repo.annotationOperations([id(1)])).length;
  await assert.rejects(use.queueAnnotation([row],'','Never saved',true,''),/commit failure/);store.commit=committed;
  assert.equal((await repo.annotationOperations([id(1)])).length,before);assert.equal((await repo.cachedPeople()).length,0);
  if(history===0) store.db.exec('DROP TRIGGER outbox_selection_insert; DROP TRIGGER outbox_selection_delete; DROP TABLE outbox_selections; PRAGMA user_version=10');
  store.db.close();const reopened=await Repository.open({databasePath:file});assert.equal((await reopened.annotationOperations([id(1)])).length,before);
  assert.equal(stores.at(-1).version,11);
  stores.at(-1).db.close();
 }
 console.log('PASS scale-independent target/dependency queries, zero scans/network, duplicate guard, rollback, restart, interleaved writes and older revisions');
 console.log(JSON.stringify({kind:'HOST_SQLITE_NOT_DEVICE',results:report}));
 // Keep sync in flight while a real ViewModel save and local playback complete.
 let finishSync,finishRead,saveCount=0,played=0;
 const vm=new VM({cancelSynchronize(){},synchronize:()=>new Promise(r=>finishSync=r),loadLocal:async()=>[],loadCached:()=>new Promise(r=>finishRead=r),
  queueAnnotation:async()=>{saveCount++;return [];}});
 vm.snapshot=new Snapshot();vm.snapshot.sessions=[{sessionId:'s',localPaths:['synthetic'],localGroupKey:'s',durationMs:1000,utterances:[]}];
 vm.bridge={stopPlayback(){},removeLocalAudioChangeListener(){},playRange:()=>played++,state:()=>vm.device};
 vm.synchronize();vm.synchronize();assert.equal(vm.busy,false);assert.equal(vm.computerSyncActive,true);
 let saved=0;vm.saveAnnotation([{utteranceId:'u'}],'','',false,'non_speech',()=>saved++);await wait(()=>!vm.annotationSaving);
 vm.playUtterance({sessionId:'s',startMs:0,endMs:800});assert.equal(played,1);assert.equal(saved,1);assert.equal(vm.computerSyncActive,true);
 const loading=vm.refreshSnapshot();await tick();const old=new Snapshot();
 vm.saveAnnotation([{utteranceId:'u'}],'','',false,'media_speech',()=>saved++);await wait(()=>!vm.annotationSaving);
 finishRead(old);await loading;assert.notEqual(vm.snapshot,old);
 vm.stop();finishSync({backup:{uploadedFiles:0,skippedFiles:0},batches:0,summary:()=>''});await tick();
 // Resolve stopped sync's local read; it must not publish the pre-stop snapshot.
 if(finishRead)finishRead(old);await tick();assert.equal(saveCount,2);
 console.log('PASS sync-in-flight local save/playback, duplicate sync guard, late snapshot cannot overwrite save');
})().catch(e=>{console.error(e);process.exitCode=1});
