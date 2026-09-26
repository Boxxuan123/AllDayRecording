const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),Module=require('node:module');
const ts=require(process.env.PHONE_TEST_TYPESCRIPT||'typescript');
require.extensions['.ets']=(m,f)=>m._compile(ts.transpileModule(fs.readFileSync(f,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText,f);
const timers=new Map();let serial=0,off=0,stop=0,found,resolveService,startError=false;
const realSet=global.setTimeout,realClear=global.clearTimeout;
global.setTimeout=f=>{timers.set(++serial,f);return serial;};global.clearTimeout=id=>timers.delete(id);global.canIUse=()=>true;
const native={'@kit.NetworkKit':{mdns:{
 createDiscoveryService:()=>({on:(_e,f)=>found=f,off:()=>off++,stopSearchingMDNS:()=>stop++,startSearchingMDNS:()=>{if(startError)throw Error('synthetic startup');}}),
 resolveLocalService:()=>new Promise(r=>resolveService=r)
}},'@kit.ArkTS':{util:{TextDecoder:{create:()=>({decodeToString:bytes=>Buffer.from(bytes).toString()})}}}};
const old=Module._load;Module._load=function(name,...args){return native[name]||(name.startsWith('@kit.')?{}:old.call(this,name,...args));};
const {ComputerReceiverDiscovery:Discovery}=require(path.resolve('phone/src/main/ets/computer/ComputerReceiverDiscovery.ets'));
(async()=>{
 const discovery=new Discovery({}),receiver='a'.repeat(64);
 let pending=discovery.discover(receiver);const timed=assert.rejects(pending,e=>e.category==='discovery_timeout');
 found({});const oldResolve=resolveService;
 [...timers.values()][0]();await timed;assert.equal(timers.size,0);assert.equal(stop,1);assert.equal(off,1);
 // A stale resolve finishes after timeout and cannot resolve a later discovery.
 pending=discovery.discover(receiver);const cancelled=assert.rejects(pending,e=>e.category==='cancelled');
 oldResolve({});await Promise.resolve();assert.equal(stop,1);
 discovery.cancel();await cancelled;assert.equal(timers.size,0);assert.equal(stop,2);assert.equal(off,2);
 pending=discovery.discover(receiver);const replaced=assert.rejects(pending,e=>e.category==='cancelled');
 const latest=discovery.discover(receiver);const last=assert.rejects(latest,e=>e.category==='cancelled');
 await replaced;discovery.cancel();await last;assert.equal(timers.size,0);assert.equal(stop,4);
 startError=true;await assert.rejects(discovery.discover(receiver),/启动/);assert.equal(timers.size,0);assert.equal(stop,5);assert.equal(off,5);
 console.log('PASS discovery timeout/cancel/replacement/start failure release timers/listeners; stale resolver is ignored');
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(()=>{global.setTimeout=realSet;global.clearTimeout=realClear;});
