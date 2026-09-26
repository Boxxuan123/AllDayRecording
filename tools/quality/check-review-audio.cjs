// Execute the production wrapper AND common player. Only native AVPlayer/file API
// are substituted. This verifies callback coverage, not real-device sound output.
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),Module=require('node:module');
const ts=require(process.env.PHONE_TEST_TYPESCRIPT||'typescript');
require.extensions['.ets']=(m,f)=>m._compile(ts.transpileModule(fs.readFileSync(f,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS,experimentalDecorators:true}}).outputText,f);
const root=path.resolve(__dirname,'../..'),players=[],files=new Set();
global.canIUse=()=>true;
class NativePlayer {
 constructor(){this.callbacks={};this.duration=9000;this.currentTime=0;this.state='idle';players.push(this)}
 on(event,cb){this.callbacks[event]=cb}
 set fdSrc(value){this.fd=value.fd;this.state='initialized';this.callbacks.stateChange('initialized')}
 async prepare(){this.state='prepared'} setVolume(){} seek(){}
 async play(){this.state='playing';this.callbacks.stateChange('playing')}
 async release(){this.state='released'}
 emit(state){this.state=state;this.callbacks.stateChange(state)}
 error(){this.callbacks.error({message:'synthetic decoder failure'})}
}
const native={
 '@kit.CoreFileKit':{fileIo:{OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4,READ_ONLY:0},
  mkdirSync:fs.mkdirSync,statSync:fs.statSync,openSync:(p,mode)=>{if(mode) files.add(p);return {fd:fs.openSync(p,mode?'w':'r')}},
  writeSync:(fd,data)=>fs.writeSync(fd,Buffer.from(data)),closeSync:fs.closeSync,
  unlinkSync:p=>{fs.unlinkSync(p);files.delete(p)}}},
 '@kit.MediaKit':{media:{createAVPlayer:async()=>new NativePlayer(),SeekMode:{SEEK_CLOSEST:0}}},
 '@kit.ArkTS':{util:{}},
};
global.Observed=c=>c; const appValues=new Map();global.AppStorage={get:k=>appValues.get(k),setOrCreate:(k,v)=>appValues.set(k,v),set:(k,v)=>appValues.set(k,v)};
const oldLoad=Module._load;
Module._load=function(name,...args){return native[name]||((name.startsWith('@kit.')||name.startsWith('@hms.'))?{}:null)||oldLoad.call(this,name,...args)};
native.common=require(path.join(root,'common/src/main/ets/services/AudioPlaybackService.ets'));
const {PhoneV3ReviewAudioPlayer}=require(path.join(root,'phone/src/main/ets/v3/data/PhoneV3ReviewAudioPlayer.ets'));
const tick=()=>new Promise(r=>setImmediate(r));
(async()=>{
 const cacheDir=fs.mkdtempSync(path.join(os.tmpdir(),'review-player-synthetic-'));
 const wrapper=new PhoneV3ReviewAudioPlayer({cacheDir});let start=0,complete=0,errors=0;
 const response={review_id:'r',prototype_id:'p',format:'wav',start_ms:0,end_ms:9000,data_base64url:Buffer.from('synthetic native fixture').toString('base64url')};
 const play=()=>wrapper.play(response,()=>start++,()=>complete++,()=>errors++);
 await play();const first=players.at(-1);assert.equal(start,1);assert.equal(complete,0);
 first.callbacks.timeUpdate(3000);assert.equal(complete,0);assert.equal(files.size,1);
 first.emit('completed');await tick();assert.equal(complete,1);assert.equal(files.size,0);
 console.log('PASS actual common player start/first-window progress do not complete; native completion does; cache cleaned');
 await play();const stopped=players.at(-1);await wrapper.release();stopped.emit('completed');await tick();assert.equal(complete,1);assert.equal(files.size,0);
 await play();const replaced=players.at(-1);await play();replaced.emit('completed');await tick();assert.equal(complete,1);
 players.at(-1).error();await tick();assert.equal(errors,1);assert.equal(complete,1);assert.equal(files.size,0);
 console.log('PASS stop, switch and stale completion do not complete; decode failure clears playback and cache');
 await play();players.at(-1).emit('paused');await tick();assert.equal(errors,2);assert.equal(complete,1);assert.equal(files.size,0);
 const before=players.length;await assert.rejects(()=>wrapper.play({...response,end_ms:0},()=>{}));assert.equal(players.length,before);
 console.log('PASS pause and invalid response never produce completion');
 native['@kit.CryptoArchitectureKit']={cryptoFramework:{createMd:()=>({update:async()=>{},digest:async()=>({data:new Uint8Array(32)})})}};
 const {PhoneV3ViewModel}=require(path.join(root,'phone/src/main/ets/v3/presentation/PhoneV3ViewModel.ets'));
 const {PhoneV3Snapshot}=require(path.join(root,'phone/src/main/ets/v3/domain/PhoneV3Models.ets'));
 const vm=new PhoneV3ViewModel();const snapshot=new PhoneV3Snapshot();
 snapshot.reviewItems=[{reviewId:'r',title:'Synthetic',contextJson:JSON.stringify({voice_candidates:[{prototype_id:'p',audio_available:true,audition_key:'key',representative_clips:[{media_id:'m',start_ms:0,end_ms:3000},{media_id:'m',start_ms:3500,end_ms:6500},{media_id:'m',start_ms:7000,end_ms:10000}]}]})}];
 const full={...response,complete_sample:true,audition_key:'key',windows:[{media_id:'m',start_ms:0,end_ms:3000,playback_start_ms:0},{media_id:'m',start_ms:3500,end_ms:6500,playback_start_ms:3000},{media_id:'m',start_ms:7000,end_ms:10000,playback_start_ms:6000}]};
 let submissions=[]; vm.snapshot=snapshot;vm.reviewAudioPlayer=wrapper;
 vm.useCases={loadReviewAudio:async()=>full,loadLocal:async()=>[],loadCached:async()=>snapshot,resolveReview:async r=>{submissions.push(r);return snapshot.reviewItems}};
 vm.playReviewSample('r','p');await tick();assert.equal(vm.reviewSampleWasPlayed('r','p'),false);
 vm.resolveReview('r','confirm','p');assert.equal(submissions.length,0);
 players.at(-1).emit('completed');await tick();assert.equal(vm.reviewSampleWasPlayed('r','p'),true);
 vm.resolveReview('r','confirm','p');await tick();assert.equal(submissions.length,1);
 vm.stopPlayback();assert.equal(vm.reviewSampleWasPlayed('r','p'),false);
 vm.resolveReview('r','retract','p');await tick();assert.equal(submissions.length,2);
 console.log('PASS real ViewModel blocks first-start confirmation, allows completion, clears on stop; withdrawal needs no audition');
 vm.snapshot=snapshot;vm.playReviewSample('r','p');await tick();const old=players.at(-1);
 await vm.refreshSnapshot();assert.notEqual(old.state, 'released');
 old.emit('completed');await tick();assert.equal(vm.reviewSampleWasPlayed('r','p'),true);
 snapshot.reviewItems[0].contextJson = JSON.stringify({voice_candidates:[], grant_status:'revoked'});
 await vm.refreshSnapshot();assert.equal(vm.reviewSampleWasPlayed('r','p'),false);
 vm.useCases.loadReviewAudio=async()=>({...full,complete_sample:undefined});
 vm.playReviewSample('r','p');await tick();assert.equal(vm.reviewSampleWasPlayed('r','p'),false);
 assert(vm.error.includes('完整试听'));await wrapper.release();assert.equal(files.size,0);
 console.log('PASS unrelated refresh preserves full audition; changed review/grant invalidates credential; partial responses fail closed');

 // Real ViewModel remote outcome guard: never advance on failed/ambiguous submission.
 const {PhoneV3ReviewSubmissionError}=require(path.join(root,'phone/src/main/ets/v3/application/PhoneV3UseCases.ets'));
 const remoteVm=new PhoneV3ViewModel();let remoteWrites=0, advanced=0, reads=0;
 const pendingReview={reviewId:'remote',kind:'voice_identity',contextJson:JSON.stringify({voice_mode:'known_person',voice_candidates:[{prototype_id:'sample',review_status:'pending'}]})};
 remoteVm.snapshot=new PhoneV3Snapshot();remoteVm.snapshot.reviewItems=[pendingReview];
 remoteVm.useCases={resolveReview:async()=>{remoteWrites++;throw new PhoneV3ReviewSubmissionError(true)},refreshReviews:async()=>{reads++;return []}};
 remoteVm.resolveReview('remote','uncertain','sample','',()=>advanced++);await tick();
 assert.equal(advanced,0);assert.equal(remoteVm.reviewSubmissionState('remote','sample'),'committed');
 remoteVm.resolveReview('remote','uncertain','sample');await tick();assert.equal(remoteWrites,1);
 remoteVm.refreshVoiceReviews();await tick();assert.equal(reads,1);assert.equal(remoteWrites,1);assert.equal(remoteVm.reviewSubmissionState('remote','sample'),'');
 remoteVm.snapshot.reviewItems=[pendingReview];
 remoteVm.useCases.resolveReview=async()=>{remoteWrites++;throw new PhoneV3ReviewSubmissionError(false)};
 remoteVm.useCases.refreshReviews=async()=>{reads++;return [pendingReview]};
 remoteVm.resolveReview('remote','uncertain','sample','',()=>advanced++);await tick();
 remoteVm.refreshVoiceReviews();await tick();assert.equal(remoteVm.reviewSubmissionState('remote','sample'),'unknown');
 remoteVm.resolveReview('remote','uncertain','sample');await tick();assert.equal(remoteWrites,2);assert.equal(advanced,0);
 remoteVm.useCases.refreshReviews=async()=>[];remoteVm.refreshVoiceReviews();await tick();
 assert.equal(remoteVm.reviewSubmissionState('remote','sample'),'');assert.equal(advanced,0);assert.equal(remoteWrites,2);
 // Multiple unresolved objects survive independent submissions and alternate entry IDs.
 remoteVm.snapshot.reviewItems=[pendingReview];
 remoteVm.useCases.resolveReview=async()=>{remoteWrites++;throw new PhoneV3ReviewSubmissionError(false)};
 remoteVm.resolveReview('remote','uncertain','sample');await tick();const writesA=remoteWrites;
 remoteVm.resolveReview('another-entry','uncertain','sample');await tick();assert.equal(remoteWrites,writesA);assert.match(remoteVm.error,/核对结果/);
 remoteVm.resolveReview('second','uncertain','b');await tick();assert.equal(remoteWrites,writesA+1);
 assert.equal(remoteVm.reviewSubmissionState('remote','sample'),'unknown');assert.equal(remoteVm.reviewSubmissionState('second','b'),'unknown');
 remoteVm.useCases.resolveReview=async()=>{remoteWrites++;return remoteVm.snapshot.reviewItems};
 remoteVm.resolveReview('third','uncertain','c');await tick();remoteVm.resolveReview('reminder','confirm');await tick();remoteVm.resolveReview('memory','confirm');await tick();
 assert.equal(remoteWrites,writesA+4);assert.equal(remoteVm.reviewSubmissionState('remote','sample'),'unknown');assert.equal(remoteVm.reviewSubmissionState('second','b'),'unknown');
 remoteVm.useCases.resolveReview=async()=>{remoteWrites++;throw Error('not sent')};
 remoteVm.resolveReview('not-sent','uncertain','d');await tick();remoteVm.resolveReview('not-sent','uncertain','d');await tick();assert.equal(remoteWrites,writesA+6);assert.equal(remoteVm.reviewSubmissionState('not-sent','d'),'');
 // Reconcile one outcome while retaining another unresolved candidate.
 remoteVm.useCases.refreshReviews=async()=>[{...pendingReview,contextJson:JSON.stringify({voice_candidates:[{prototype_id:'b',review_status:'pending'}]})}];
 remoteVm.refreshVoiceReviews();await tick();assert.equal(remoteVm.reviewSubmissionState('remote','sample'),'');assert.equal(remoteVm.reviewSubmissionState('second','b'),'unknown');
 const writesBeforeEvidence=remoteWrites;
 console.log('PASS unresolved A cannot be bypassed by another entry; B/reminders/memory proceed; multiple pending outcomes survive; not-sent retries');
 const mappedCandidate={prototype_id:'sample',session_id:'s',representative_clips:[{media_id:'m',start_ms:0,end_ms:500}],evidence_utterances:[{utterance_id:'u',session_id:'s',revision:1,utterance_start_ms:0,utterance_end_ms:900,window_index:0,media_id:'m',clip_start_ms:0,clip_end_ms:500,session_start_ms:0,session_end_ms:500}]};
 remoteVm.snapshot.reviewItems=[{...pendingReview,contextJson:JSON.stringify({voice_mode:'known_person',voice_candidates:[mappedCandidate]})}];
 const changedSource={utteranceId:'u',sessionId:'s',revision:1,status:'active',startMs:0,endMs:900,annotationFacts:{person:'pending',sound:''}};
 remoteVm.snapshot.sessions=[{sessionId:'s',utterances:[changedSource]}];
 remoteVm.resolveReview('remote','uncertain','sample');await tick();assert.equal(remoteWrites,writesBeforeEvidence);assert.match(remoteVm.error,/依据已修改/);
 changedSource.annotationFacts.person='';changedSource.revision=2;
 remoteVm.resolveReview('remote','uncertain','sample');await tick();assert.equal(remoteWrites,writesBeforeEvidence);
 console.log('PASS remote committed/read failure only re-reads; ambiguous timeout stays locked while pending; disappearance never fakes success');

 // Exercise actual HTTP client authentication/dispatch boundary (native crypto only mocked).
 native['@kit.ArkTS'].util.TextEncoder={create:()=>({encodeInto:s=>Buffer.from(s)})};
 native['@kit.CryptoArchitectureKit']={cryptoFramework:{createMd:()=>({update:async()=>{},digest:async()=>({data:new Uint8Array(32)})})}};
 const {ComputerTransferHttpClient}=require(path.join(root,'phone/src/main/ets/computer/ComputerTransferHttpClient.ets'));
 const client=Object.create(ComputerTransferHttpClient.prototype);client.deviceId='device';let actionRequests=0;
 client.deviceKeys={sign:async()=> 'signature'};
 client.requestJson=async(method,url)=>{if(url.endsWith('/reviews/action')){actionRequests++;throw Error('submit timeout')}throw Error('auth timeout')};
 await assert.rejects(client.v3ReviewAction({review_id:'r',action:'confirm'}),e=>e.reviewRequestNotSent===true);assert.equal(actionRequests,0);
 client.requestJson=async(method,url)=>{if(url.endsWith('/reviews/action')){actionRequests++;throw Error('submit timeout')}return {version:1,challenge_id:'challenge',nonce:'nonce',expires_in_ms:1000}};
 await assert.rejects(client.v3ReviewAction({review_id:'r',action:'confirm'}),e=>!e.reviewRequestNotSent&&e.message==='submit timeout');assert.equal(actionRequests,1);
 console.log('PASS production HTTP authentication failure is not-sent; action transport timeout remains possibly sent');

 // Real ViewModel save boundary: UI success is independent of the following read.
 const saveVm = new PhoneV3ViewModel();
 let queueCalls = 0, saved = [], releaseSave;
 const target = { utteranceId: 'u', revision: 7 };
 saveVm.useCases = { queueAnnotation: async (rows, personId, name, personChanged, sound) => {
   queueCalls++; assert.equal(rows[0].revision, 7); assert.equal(name, 'Alice');
   await new Promise(resolve => { releaseSave = resolve; });
   return [];
 }, loadLocal: async () => [], loadCached: async () => new PhoneV3Snapshot() };
 const submit = () => saveVm.saveAnnotation([target], '', 'Alice', true, '', fresh => saved.push(fresh));
 submit(); submit(); assert.equal(queueCalls, 1); assert.equal(saveVm.annotationSaving, true);
 releaseSave(); await tick(); await tick();
 assert.deepEqual(saved, [true]); assert.equal(saveVm.annotationSaving, false);
 saveVm.useCases.queueAnnotation = async () => { queueCalls++; throw Error('disk full'); };
 submit(); await tick(); assert.deepEqual(saved, [true]); assert.match(saveVm.error, /数据库保存失败/);
 saveVm.useCases.queueAnnotation = async () => { queueCalls++; return []; };
 // A post-commit display failure must not be reported as a failed transaction.
 const clearSavedError = saveVm.clearError.bind(saveVm);
 saveVm.clearError = () => { throw Error('display failed'); };
 saveVm.useCases.loadCached = async () => { throw Error('save must not read'); };
 submit(); await tick(); await tick(); assert.deepEqual(saved, [true, false]);
 assert.match(saveVm.error, /已在手机保存/);
 saveVm.clearError = clearSavedError;
 const submitted = queueCalls;
 saveVm.useCases.loadCached = async () => new PhoneV3Snapshot();
 let reloaded = 0; saveVm.reloadAnnotationResult(() => reloaded++); await tick();
 assert.equal(reloaded, 1); assert.equal(queueCalls, submitted);
 console.log('PASS ViewModel double-click guard, DB failure does not advance, committed-read failure and read-only retry');

 const utterance = { utteranceId:'u', revision:1, status:'active', sessionId: 's', startMs: 0, endMs: 9000 };
 vm.snapshot = new PhoneV3Snapshot();
 vm.snapshot.sessions = [{ sessionId: 's', localPaths: [], localGroupKey: '', durationMs: 9000, utterances:[utterance] }];
 let audioResolve;
 vm.useCases.annotations = () => new Promise(resolve => { audioResolve = resolve; });
 const playerCount = players.length;
 vm.playUtterance(utterance); assert.equal(vm.annotationPlaybackState(), '正在加载');
 vm.stopPlayback(); audioResolve({ audio: response }); await tick();
 assert.equal(players.length, playerCount); assert.equal(vm.annotationPlaybackState(), '');
 vm.useCases.annotations = async () => ({ audio: response });
 vm.playUtterance(utterance); await tick();
 assert.equal(vm.annotationPlaybackState(), '正在播放');
 const oldAnnotation = players.at(-1);
 vm.useCases.loadCached = async () => vm.snapshot;
 await vm.refreshSnapshot();assert.equal(vm.annotationPlaybackState(),'正在播放');assert.notEqual(oldAnnotation.state,'released');
 vm.snapshot.sessions.push({sessionId:'unrelated',localPaths:['new-file'],utterances:[]});
 await vm.refreshSnapshot();assert.equal(vm.annotationPlaybackState(),'正在播放');
 vm.snapshot.sessions[0].utterances=[{...utterance,revision:2}];
 await vm.refreshSnapshot();assert.equal(vm.annotationPlaybackState(),'');assert.equal(oldAnnotation.state,'released');
 console.log('PASS unrelated new audio refresh preserves current playback; source revision invalidates it');
 vm.stopPlayback(); oldAnnotation.emit('completed'); await tick();
 assert.equal(vm.annotationPlaybackState(), '');
 console.log('PASS annotation playback has real loading/playing state and ignores stopped request/completion');


})().catch(e=>{console.error(e);process.exitCode=1});
