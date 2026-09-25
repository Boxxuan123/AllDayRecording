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
 await vm.refreshSnapshot();old.emit('completed');await tick();assert.equal(vm.reviewSampleWasPlayed('r','p'),false);
 vm.useCases.loadReviewAudio=async()=>({...full,complete_sample:undefined});
 vm.playReviewSample('r','p');await tick();assert.equal(vm.reviewSampleWasPlayed('r','p'),false);
 assert(vm.error.includes('完整试听'));await wrapper.release();assert.equal(files.size,0);
 console.log('PASS refresh cancels stale completion and legacy partial responses fail closed');

})().catch(e=>{console.error(e);process.exitCode=1});
