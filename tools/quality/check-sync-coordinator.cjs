// Actual coordinator; deterministic native timer boundary, no source-string assertions.
const assert = require('node:assert/strict'), fs=require('node:fs'), vm=require('node:vm');
const ts=require(process.env.PHONE_TEST_TYPESCRIPT);
let now=0, seq=0; const timers=new Map(), exportsObject={}, errors={};
const compile=file=>ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
vm.runInNewContext(compile('phone/src/main/ets/computer/ComputerConnectionError.ets'),{exports:errors,Error});
vm.runInNewContext(compile('phone/src/main/ets/v3/application/PhoneSyncCoordinator.ets'),{
 exports:exportsObject,require:()=>errors,Error,Math,Date:{now:()=>now},
 setTimeout:(cb,ms)=>{const id=++seq;timers.set(id,{cb,at:now+ms});return id;},clearTimeout:id=>timers.delete(id)});
const {PhoneSyncCoordinator:Coordinator,PhoneSyncWorkResult:Result}=exportsObject;
const flush=async()=>{for(let i=0;i<12;i++)await Promise.resolve();};
async function advance(ms){now+=ms;const ready=[...timers].filter(([,v])=>v.at<=now);for(const [id,v]of ready){timers.delete(id);v.cb();}await flush();}
(async()=>{
 let calls=0,active=0,max=0,release,backRelease,backCalls=0;
 const c=new Coordinator({light:async()=>{calls++;active++;max=Math.max(max,active);await new Promise(r=>release=r);active--;return new Result();},
 backup:async()=>{backCalls++;await new Promise(r=>backRelease=r);return new Result();},cancelLight(){},changed(){}});
 c.setForeground(true);for(let i=0;i<50;i++)c.trigger(true);
 await advance(250);assert.equal(calls,1);assert.equal(backCalls,1);
 for(let i=0;i<50;i++)c.trigger();release();await flush();await advance(250);
 assert.equal(calls,2);assert.equal(max,1);assert(c.backup.running);
 c.pause();release();await flush();c.trigger(true,true);await advance(100000);assert.equal(calls,2);
 c.setForeground(false);c.setForeground(true);await advance(1000);assert.equal(calls,2);
 backRelease();await flush();c.resume();await advance(250);assert.equal(calls,3);
 c.stop();release();backRelease();await flush();assert.equal(timers.size,0);
 console.log('PASS 100 merged triggers, one consumer, backup overlap, in-memory pause, late completion, stop cleanup');
 let attempts=0;
 const temporary=new errors.ComputerConnectionError('unreachable','connect','offline');
 const retry=new Coordinator({light:async()=>{attempts++;if(attempts===1)throw temporary;return new Result();},
 backup:async()=>new Result(),cancelLight(){},changed(){}});
 retry.setForeground(true);await advance(250);assert.equal(attempts,1);
 for(let i=0;i<100;i++)retry.trigger();await advance(250);assert.equal(attempts,1);
 await advance(6000);assert.equal(attempts,2);retry.stop();
 const denied=new errors.ComputerConnectionError('authorization','response','denied');denied.statusCode=401;
 let blocked=0;const terminal=new Coordinator({light:async()=>{blocked++;throw denied;},backup:async()=>new Result(),cancelLight(){},changed(){}});
 terminal.setForeground(true);await advance(250);terminal.trigger();await advance(500000);assert.equal(blocked,1);
 terminal.trigger(false,true);await advance(250);assert.equal(blocked,2);terminal.stop();
 console.log('PASS capped retry schedule survives network/save bursts; authorization needs explicit retry');
 let lightOK=0;
 const separated=new Coordinator({light:async()=>{lightOK++;return new Result();},backup:async()=>{throw denied;},cancelLight(){},changed(){}});
 separated.setForeground(true);separated.trigger(true);await advance(250);await advance(250);
 assert(lightOK>=1);assert.equal(separated.light.error,'');assert.equal(separated.backup.error,'denied');separated.stop();
 console.log('PASS backup failure does not poison metadata lane');
 let polls=0;
 const idle=new Coordinator({light:async()=>{polls++;return new Result(false,120000,false);},backup:async()=>new Result(),cancelLight(){},changed(){}});
 idle.setForeground(true);await advance(250);assert.equal(polls,1);assert.equal(idle.light.successAt,0);
 idle.trigger();await advance(250);assert.equal(polls,2,'a new save must replace an already scheduled idle poll');idle.stop();
 console.log('PASS idle poll is preempted by a local save; waiting does not claim success');
 const envExports={},writes=[];let persisted=false,finish,available,wakes=0,registered=0,unregistered=0;
 const net={on:(_,cb)=>available=cb,register:cb=>{registered++;cb();},unregister:cb=>{unregistered++;cb();}};
 const preferences={getPreferences:async()=>({get:async()=>persisted,put:async(_,value)=>{
   writes.push(value);if(value)await new Promise(r=>finish=r);persisted=value;},flush:async()=>{}})};
 vm.runInNewContext(compile('phone/src/main/ets/v3/runtime/PhoneSyncEnvironment.ets'),{
   exports:envExports,require:()=>({preferences,connection:{createNetConnection:()=>net,getDefaultNet:async()=>({}),
    getNetCapabilities:async()=>({bearerTypes:[2]}),NetBearType:{BEARER_WIFI:1}}}),console});
 const Env=envExports.PhoneSyncEnvironment,environment=new Env({});
 const pause=environment.setPaused(true),resume=environment.setPaused(false);await flush();assert.deepEqual(writes,[true]);
 finish();await pause;await resume;assert.deepEqual(writes,[true,false]);assert.equal(await new Env({}).paused(),false);
 environment.start(()=>wakes++);environment.start(()=>wakes++);assert.equal(registered,1);available();assert.equal(wakes,1);
 assert.equal(await environment.wifi(),false);environment.stop();available();assert.equal(wakes,1);assert.equal(unregistered,1);
 console.log('PASS ordered pause persistence, fresh owner reload, single native registration, stopped callback ignored, non-Wi-Fi gated');
})().catch(e=>{console.error(e);process.exitCode=1;});
