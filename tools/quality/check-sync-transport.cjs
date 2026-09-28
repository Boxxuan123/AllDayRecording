const assert=require('node:assert/strict');
const Module=require('node:module');
const z=require('node:zlib');
require('./phone-sqlite-harness.cjs');
const {PhoneSyncBatchPolicy,syncRequestBatch}=require('../../phone/src/main/ets/v3/data/PhoneSyncBatch.ets');
const load=Module._load;
Module._load=function(name,...args){
 if(name==='@kit.ArkTS') return {util:{TextDecoder:{create:()=>({decodeToString:b=>new TextDecoder().decode(b)})}}};
 if(name==='@kit.BasicServicesKit') return {zlib:{ReturnStatus:{OK:0,STREAM_END:1},CompressFlushMode:{FINISH:4},createZip:async()=>{
  let stream;
  return {inflateInit2:async(s,bits)=>{assert.equal(bits,31);stream=s;return 0;},inflate:async s=>{
   const out=z.gunzipSync(Buffer.from(s.nextIn));new Uint8Array(s.nextOut).set(out);stream.totalOut=out.length;stream.availableIn=0;return 1;
  },getZStream:async()=>stream,inflateEnd:async()=>{}};
 }}};
 return load.call(this,name,...args);
};
const {computerJsonText}=require('../../phone/src/main/ets/computer/ComputerJsonBody.ets');
const buffer=b=>b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength);
(async()=>{
 const p=new PhoneSyncBatchPolicy();
 p.observe(32,1000,20,500,250000,20);assert.equal(p.operations,40);assert.equal(p.pullBytes,327680);
 p.observe(40,1000,600,200,200000,400);assert.equal(p.operations,20);assert.equal(p.pullLimit,100);assert.equal(p.pullBytes,100000);
 for(let i=0;i<20;i++)p.observe(p.operations,1000,1000,16,16384,1000);
 assert.equal(p.operations,4);assert.equal(p.pullLimit,16);assert.equal(p.pullBytes,16384);
 for(let i=0;i<80;i++)p.observe(p.operations,1000,1,p.pullLimit,p.pullBytes,1);
 assert.equal(p.operations,128);assert.equal(p.pullLimit,500);assert.equal(p.pullBytes,1048576);
 const ops=Array.from({length:128},(_,i)=>({operation_id:String(i).padStart(26,'0'),kind:'x',base_revision:null,payload:{text:'中文😀'.repeat(200)}}));
 const req=syncRequestBatch('cursor-0',ops,128,500,262144,true);
 assert.equal(req.bootstrap,true);assert(Buffer.byteLength(JSON.stringify(req))<=65536);assert(req.client_operations.length<128);
 assert.equal(syncRequestBatch('snapshot-v1-500-20',[],32,500,262144,true).bootstrap,undefined);
 const text=JSON.stringify({text:'中文😀'.repeat(10000)}), zipped=z.gzipSync(text);
 assert.equal(await computerJsonText(buffer(zipped)),text);
 assert.equal(await computerJsonText(buffer(Buffer.from(text))),text);
 const corrupt=Buffer.from(zipped);corrupt[corrupt.length-8]^=1;await assert.rejects(()=>computerJsonText(buffer(corrupt)));
 await assert.rejects(()=>computerJsonText(buffer(zipped.subarray(0,10))));
 const bomb=Buffer.from(zipped);bomb.writeUInt32LE(32*1024*1024+1,bomb.length-4);await assert.rejects(()=>computerJsonText(buffer(bomb)));
 console.log('PASS adaptive bounds, UTF-8 envelope, bootstrap continuation, gzip decode/CRC/truncation/size limits');
})().catch(e=>{console.error(e);process.exitCode=1;});
