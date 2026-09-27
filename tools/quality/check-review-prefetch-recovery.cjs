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
  unlink:async p=>{fs.unlinkSync(p);files.delete(p)},unlinkSync:p=>{fs.unlinkSync(p);files.delete(p)}}},
 '@kit.MediaKit':{media:{createAVPlayer:async()=>new NativePlayer(),SeekMode:{SEEK_CLOSEST:0}}},
 '@kit.ArkTS':{util:{},taskpool:{execute:async(fn,...args)=>fn(...args)}},
};
global.Observed=c=>c; const appValues=new Map();global.AppStorage={get:k=>appValues.get(k),setOrCreate:(k,v)=>appValues.set(k,v),set:(k,v)=>appValues.set(k,v)};
const oldLoad=Module._load;
Module._load=function(name,...args){return native[name]||((name.startsWith('@kit.')||name.startsWith('@hms.'))?{}:null)||oldLoad.call(this,name,...args)};
native.common=require(path.join(root,'common/src/main/ets/services/AudioPlaybackService.ets'));
const {PhoneV3ReviewAudioPlayer}=require(path.join(root,'phone/src/main/ets/v3/data/PhoneV3ReviewAudioPlayer.ets'));
const tick=()=>new Promise(r=>setImmediate(r));
const {PhoneV3ViewModel}=require(path.join(root,'phone/src/main/ets/v3/presentation/PhoneV3ViewModel.ets'));
const {ComputerConnectionError}=require(path.join(root,'phone/src/main/ets/computer/ComputerConnectionError.ets'));
const task={key:'k',fingerprint:'evidence',item:{reviewId:'r'},candidate:{prototypeId:'p',hasAudio:true,audioContentKey:'content'}};
(async()=>{
 const oldNow=Date.now,oldSet=setTimeout,oldClear=clearTimeout;let now=1000,id=0;const timers=new Map();
 Date.now=()=>now;global.setTimeout=(fn,delay)=>{timers.set(++id,{fn,due:now+delay});return id};global.clearTimeout=id=>timers.delete(id);
 const flush=async()=>{for(let n=0;n<8;n++)await tick()};
 const advance=async(ms)=>{now+=ms;for(let n=0;n<20;n++){const due=[...timers].filter(([,v])=>v.due<=now);if(!due.length)break;for(const [i,v] of due){timers.delete(i);v.fn()}await flush()}};
 const setup=()=>{let online=false,calls=0;const vm=new PhoneV3ViewModel();vm.useCases={cancelSynchronize(){},cancelReviewPrefetch(){},loadReviewAudio:async()=>{calls++;if(!online)throw new ComputerConnectionError('unreachable','connect','synthetic offline');return {}}};return {vm,online:()=>online=true,calls:()=>calls}};
 try {
  const a=setup();a.vm.setReviewAudioWindow([task]);await flush();assert.equal(a.calls(),1);
  a.online();a.vm.setReviewAudioWindow([task]);await flush();assert.equal(a.calls(),1);assert.equal(timers.size,1);
  await advance(60001);assert.equal(a.calls(),2);assert.match(a.vm.reviewAudioState('k'),/已缓存/);assert.equal(timers.size,0);
  a.vm.setReviewAudioWindow([task]);await advance(120000);assert.equal(a.calls(),2,'ready window repeated download');a.vm.stop();
  const b=setup();b.vm.setReviewAudioWindow([task]);await flush();await advance(60001);assert.equal(b.calls(),2);
  b.online();await advance(120001);assert.equal(b.calls(),3);b.vm.stop();
  const c=setup();c.vm.setReviewAudioWindow([task]);await flush();c.vm.setReviewAudioWindow([],false);c.online();await advance(600000);assert.equal(c.calls(),1);assert.equal(timers.size,0);c.vm.stop();
  const d=setup();let release;d.vm.useCases.loadReviewAudio=()=>new Promise(r=>release=r);d.vm.setReviewAudioWindow([task]);await flush();d.vm.setReviewAudioWindow([task]);assert.equal(d.vm.prefetchDemands.size,1);d.vm.stop();release({});await flush();assert.equal(timers.size,0);assert.equal(d.vm.reviewAudioState('k'),'点击准备试听');
  const e=setup();let auth=0;e.vm.useCases.loadReviewAudio=async()=>{auth++;throw new ComputerConnectionError('authorization','auth','synthetic denied')};e.vm.setReviewAudioWindow([task]);await flush();await advance(900000);assert.equal(auth,1);assert.equal(timers.size,0);e.vm.stop();
  const f=setup();f.vm.setReviewAudioWindow([task]);await flush();f.vm.setForeground(false);f.online();await advance(900000);assert.equal(f.calls(),1);assert.equal(timers.size,0);f.vm.stop();
  console.log('PASS early recovery then no events; late recovery; ready/inflight coalescing; exit/background/stop cleanup; authorization blocks retries');
 } finally {Date.now=oldNow;global.setTimeout=oldSet;global.clearTimeout=oldClear;}
})().catch(e=>{console.error(e);process.exitCode=1});
