// Production cache scheduler + worker IO/crypto against disposable synthetic files.
// taskpool dispatch is substituted here; actual off-thread execution is a device check.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os'),crypto=require('node:crypto'),Module=require('node:module');
const ts=require(process.env.PHONE_TEST_TYPESCRIPT||'typescript');
require.extensions['.ets']=(m,f)=>m._compile(ts.transpileModule(fs.readFileSync(f,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS,experimentalDecorators:true}}).outputText,f);
const hash=data=>crypto.createHash('sha256').update(data).digest('hex');
const io={OpenMode:{READ_ONLY:0,CREATE:1,WRITE_ONLY:2,TRUNC:4},mkdirSync:fs.mkdirSync,statSync:fs.statSync,listFileSync:fs.readdirSync,readTextSync:p=>fs.readFileSync(p,'utf8'),openSync:(p,m)=>({fd:fs.openSync(p,m?'w':'r')}),readSync:(fd,b)=>fs.readSync(fd,Buffer.from(b)),writeSync:(fd,b)=>fs.writeSync(fd,typeof b==='string'?b:Buffer.from(b)),fsyncSync:fs.fsyncSync,closeSync:fs.closeSync,renameSync:fs.renameSync,unlinkSync:p=>{try{fs.unlinkSync(p)}catch(e){if(e.code==='ENOENT')e.code=13900002;throw e}}};
const native={'@kit.CoreFileKit':{fileIo:io},'@kit.ArkTS':{process:{tid:99},taskpool:{execute:async(fn,...args)=>fn(...args)},util:{TextEncoder:class{encodeInto(s){return new Uint8Array(Buffer.from(s))}},Base64Helper:class{decodeSync(s){return new Uint8Array(Buffer.from(s,'base64'))}}}},'@kit.CryptoArchitectureKit':{cryptoFramework:{createMd:()=>{const h=crypto.createHash('sha256');return{update:async({data})=>{if(!data.length)throw new Error('native empty digest');h.update(data)},digest:async()=>({data:new Uint8Array(h.digest())})}}}}};
const load=Module._load;Module._load=function(name,...args){return native[name]||(name.startsWith('@kit.')?{}:null)||load.call(this,name,...args)};
const {PhoneV3ReviewAudioCache}=require('../../phone/src/main/ets/v3/data/PhoneV3ReviewAudioCache.ets');
const tick=()=>new Promise(r=>setImmediate(r));
const root=fs.mkdtempSync(path.join(os.tmpdir(),'review-cache-synthetic-'));
const bytes=Buffer.from('RIFF synthetic complete WAV bytes');
const key=hash('immutable-source-ordered-windows-renderer');
const value={review_id:'r',prototype_id:'p',audio_content_key:key,sha256:hash(bytes),byte_length:bytes.length,data_base64url:bytes.toString('base64url')};
const cached=()=>new PhoneV3ReviewAudioCache({cacheDir:root});
(async()=>{
 let cache=cached(),calls=0,unblock;
 const gate=new Promise(r=>unblock=r);
 const download=async()=>{calls++;await gate;return value};
 const pre=cache.prepare('trusted-source',key,download,true);
 await tick();await tick();
 const foreground=cache.prepare('trusted-source',key,download,false);
 await tick();await tick();unblock();
 const [a,b]=await Promise.all([pre,foreground]);assert.equal(calls,1);assert.equal(a.local_audio_path,b.local_audio_path);assert(cache.hasLease(b.local_audio_path));
 cache.release(b.local_audio_path);assert(fs.existsSync(b.local_audio_path));
 cache=cached();
 const noNetwork=()=>assert.fail('cache hit must not discover/authenticate/download');
 const hit=await cache.prepare('trusted-source',key,noNetwork,false);assert.equal(hit.data_base64url,'');assert(cache.hasLease(hit.local_audio_path));
 // A clear cannot delete an active player lease.
 await cache.clear();assert(fs.existsSync(hit.local_audio_path));cache.release(hit.local_audio_path);await cache.clear();assert(!fs.existsSync(hit.local_audio_path));
 let rebuilt=await cache.prepare('trusted-source',key,async()=>value,false);cache.release(rebuilt.local_audio_path);
 fs.writeFileSync(rebuilt.local_audio_path,'broken');
 rebuilt=await cache.prepare('trusted-source',key,async()=>{calls++;return value},false);assert.equal(calls,2);cache.release(rebuilt.local_audio_path);
 fs.unlinkSync(rebuilt.local_audio_path);
 rebuilt=await cache.prepare('trusted-source',key,async()=>value,false);cache.release(rebuilt.local_audio_path);
 await assert.rejects(()=>cache.prepare('other-source',key,async()=>({...value,sha256:'0'.repeat(64)}),false));
 const other=await cache.prepare('other-source',key,async()=>value,false);assert.notEqual(other.local_audio_path,rebuilt.local_audio_path);assert(!fs.existsSync(rebuilt.local_audio_path));cache.release(other.local_audio_path);
 const leased=await cache.prepare('other-source',key,noNetwork,false);
 fs.writeFileSync(leased.local_audio_path,'corrupt while leased');
 await assert.rejects(()=>cache.prepare('other-source',key,async()=>value,false));
 assert(fs.existsSync(leased.local_audio_path),'corruption cleanup deleted an active lease');
 cache.release(leased.local_audio_path);
 const repaired=await cache.prepare('other-source',key,async()=>value,false);cache.release(repaired.local_audio_path);
 const {PhoneV3UseCases}=require('../../phone/src/main/ets/v3/application/PhoneV3UseCases.ets');
 const clip={media_id:'m',start_ms:0,end_ms:1000};
 const item={review_id:'new-review',kind:'voice_identity',priority:'normal',source_id:'cluster',source_revision:1,session_id:'session',person_id:'person',title:'Synthetic',summary:'Synthetic',reason:'review',evidence_count:1,created_at:'2026-09-26T00:00:00Z',updated_at:'2026-09-26T00:00:00Z',context:{voice_candidates:[{prototype_id:'new-prototype',session_id:'session',audio_available:true,audition_key:'new-audition',audio_content_key:key,representative_clips:[clip]}]}};
 const oldResponse={...value,review_id:'old-review',prototype_id:'old-prototype',audition_key:'old-audition',complete_sample:true,start_ms:0,end_ms:1000,windows:[{...clip,playback_start_ms:0}]};
 const use=new PhoneV3UseCases({projectionRows:async()=>[{payloadJson:JSON.stringify(item)}]}, {}, {audioNamespace:async()=>'trusted',connect:noNetwork}, undefined, undefined, {prepare:async()=>({...oldResponse}),release(){}});
 const rebound=await use.loadReviewAudio('new-review','new-prototype');
 assert.equal(rebound.audition_key,'new-audition');assert.equal(rebound.prototype_id,'new-prototype');
 // Bounded pending work; cancelling queued prefetch preserves a foreground join.
 cache=cached();let finish;const held=new Promise(r=>finish=r);
 const running=cache.prepare('other-source',hash('running'),async()=>{await held;return {...value,audio_content_key:hash('running')}},true);
 await tick();await tick();
 const queued=cache.prepare('other-source',hash('queued'),async()=>({...value,audio_content_key:hash('queued')}),true);
 const joined=cache.prepare('other-source',hash('queued'),async()=>assert.fail('duplicate'),false);
 await tick();await tick();cache.cancelPrefetch();finish();
 const results=await Promise.all([running,queued,joined]);assert.equal(results[1].local_audio_path,results[2].local_audio_path);cache.release(results[2].local_audio_path);
 assert(fs.readdirSync(path.join(root,'review-audio-v1')).every(n=>!n.endsWith('.part')));
 // Full production 48-entry budget; expire holds using a controlled clock.
 const realNow=Date.now;let now=realNow();Date.now=()=>now;
 try {
  const fullRoot=path.join(root,'full');fs.mkdirSync(fullRoot);
  const make=()=>new PhoneV3ReviewAudioCache({cacheDir:fullRoot});let full=make();
  const put=async(n)=>{const k=hash('full-'+n);const r=await full.prepare('source',k,async()=>({...value,audio_content_key:k}),false);full.release(r.local_audio_path);now++;return r};
  const initial=[];for(let n=0;n<48;n++)initial.push(await put(n));now+=60000;
  fs.unlinkSync(initial[0].local_audio_path);
  await put(48);await put(49);
  const index=path.join(fullRoot,'review-audio-v1/index.json');
  assert.equal(JSON.parse(fs.readFileSync(index)).length,48);
  assert(!JSON.parse(fs.readFileSync(index)).some(e=>e.key===hash('full-0')));
  full=make();await full.prepare('source',hash('full-48'),noNetwork,true);
  // A completed stale-index repair survives a later write failure.
  now+=60000;const oldest=JSON.parse(fs.readFileSync(index)).sort((a,b)=>a.touched-b.touched)[0];
  fs.unlinkSync(path.join(fullRoot,'review-audio-v1',oldest.name));
  const open=io.openSync;io.openSync=(p,m)=>{if(p.endsWith('.wav.part'))throw Object.assign(new Error('disk full'),{code:13900028});return open(p,m)};
  await assert.rejects(()=>put(50));io.openSync=open;
  assert.equal(JSON.parse(fs.readFileSync(index)).length,47);
  full=make();await put(50);assert.equal(JSON.parse(fs.readFileSync(index)).length,48);
  now+=60000;const unlink=io.unlinkSync;io.unlinkSync=p=>{if(p.endsWith('.wav'))throw Object.assign(new Error('permission'),{code:13900001});return unlink(p)};
  const before=fs.readFileSync(index,'utf8');await assert.rejects(()=>put(51));
  assert.equal(fs.readFileSync(index,'utf8'),before,'permission failure falsely freed an index slot');
  io.unlinkSync=unlink;await put(51);
  console.log('PASS 48-entry stale eviction; consecutive new keys; durable repair after write failure; permission is not ENOENT');
 } finally {Date.now=realNow;}
 console.log('PASS persistent offline hits; shared prefetch/click; lease-safe clear; corruption/missing repair; namespace isolation; SHA rejection; promotion and waiter isolation');
 fs.rmSync(root,{recursive:true,force:true});
})().catch(e=>{console.error(e);process.exitCode=1});
