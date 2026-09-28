// Execute the production upload loop against real files and pread semantics.
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),vm=require('node:vm'),crypto=require('node:crypto');
const ts=require(process.env.PHONE_TEST_TYPESCRIPT),exportsObject={},handles=new Map();
const source=fs.readFileSync(process.env.PHONE_UPLOAD_SOURCE||'phone/src/main/ets/computer/ComputerRecordingUploadService.ets','utf8');
let closed=0,hashes=0;const positions=[];
let preparedSessions=[];
class ComputerHttpError extends Error { constructor(statusCode,message){super(message);this.statusCode=statusCode;} }
class ComputerUploadConcurrency { constructor(){this.limit=1;} congested(){} }
const fileIo={OpenMode:{READ_ONLY:'r'},statSync:fs.statSync,
 open:async p=>{const h=await fs.promises.open(p,'r');handles.set(h.fd,h);return {fd:h.fd};},
 read:async(fd,buffer,options)=>{positions.push(options.offset);
  return (await handles.get(fd).read(Buffer.from(buffer),0,options.length,options.offset??null)).bytesRead;},
 close:async fd=>{await handles.get(fd).close();handles.delete(fd);closed++;}};
const digest=b=>crypto.createHash('sha256').update(b).digest('hex');
vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText,{
 exports:exportsObject,require:name=>name==='@kit.CoreFileKit'?{fileIo,hash:{hash:async p=>{hashes++;return digest(await fs.promises.readFile(p));}}}:
 name.endsWith('ComputerReceiverConnection')?{verifyConfiguration:async()=>{}}:
 name.endsWith('ComputerUploadQueue')?{ComputerUploadConcurrency,runAdaptiveComputerUploadQueue:async(n,_,work)=>{for(let i=0;i<n;i++)await work(i);}}:
 name.endsWith('ComputerSessionManifest')?{prepareComputerSessions:()=>preparedSessions}:
 name.endsWith('ComputerTransferHttpClient')?{ComputerHttpError,sha256Hex:async bytes=>digest(bytes)}:
 name.endsWith('ComputerTransferProtocol')?{COMPUTER_UPLOAD_CHUNK_BYTES:128,confirmedComputerSessionId:()=> 'confirmed'}:
 name==='@kit.ArkTS'?{util:{TextEncoder:{create:()=>({encodeInto:text=>new TextEncoder().encode(text)})}}}:
 name==='@kit.LocalizationKit'?{i18n:{getCalendar:()=>({getTimeZone:()=> 'Asia/Singapore'})}}:
 name==='@kit.BasicServicesKit'?{deviceInfo:{marketName:'test'}}:{},ArrayBuffer,Uint8Array,TextEncoder,console});
(async()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'phone-upload-')),file=path.join(dir,'synthetic.wav');
 const data=Buffer.from(Array.from({length:1027},(_,i)=>(i*17+Math.floor(i/128))%256));fs.writeFileSync(file,data);
 try {
  for(const offset of [0,256]){
   positions.length=0;const uploader=Object.create(exportsObject.ComputerRecordingUploadService.prototype);
   let record,received=Buffer.from(data.subarray(0,offset));uploader.config={};uploader.store={};
   uploader.client={createUpload:async metadata=>{record={...metadata,upload_id:'synthetic',offset,status:'uploading'};return {upload:record};},
    appendUpload:async(_,at,bytes)=>{assert.equal(at,received.length);received=Buffer.concat([received,Buffer.from(bytes)]);
     const done=received.length===data.length;if(done)assert.equal(digest(received),record.sha256,'all chunks must match original SHA-256');
     record={...record,offset:received.length,status:done?'completed':'uploading'};return {upload:record};}};
   const result=await uploader.uploadRecording({path:file,size:data.length,sourcePath:'synthetic.wav',fileName:'synthetic.wav'},128,()=>{},()=>{});
   assert.equal(result.upload.status,'completed');assert.deepEqual(received,data);
   assert.deepEqual(positions,Array.from({length:Math.ceil((data.length-offset)/128)},(_,i)=>offset+i*128));
  }
  assert.equal(closed,2);assert.equal(handles.size,0);
  console.log('PASS fresh and resumed multi-chunk uploads preserve SHA-256, exact offsets and descriptor cleanup');
  const recording={path:file,size:data.length,sourcePath:'session/synthetic.wav',fileName:'synthetic.wav'};
  const session={directory:'session',recordings:[recording],manifest:{sessionKey:'watch-session:1',sessionStartedAt:1,
    continuityValid:true,completion:{source:'watch',completedSegments:1,totalSamples:1,confirmedAt:1}},
    canCommit:()=>true,manifestRelativePath:()=> 'session/session_summary.json'};
  preparedSessions=[session];
  assert.equal(await exportsObject.computerSessionManifestSha256(session),
    digest(Buffer.from(JSON.stringify(session.manifest,null,2))));
  const receipt={sessionKey:'watch-session:1',localPath:file,uploadStatus:'uploaded',sha256:digest(data)};
  const status={protocol:'ALL_DAY_RECORDING_TRANSFER',version:2,status:'ready',transport:'tls',
    authentication:'device-signature',enrollment:'passkey',max_chunk_bytes:128,max_file_bytes:100000};
  for(const missing of [false,true]){
    hashes=0;let requests=[],receipts=0,manifestAttempts=0;
    const uploader=Object.create(exportsObject.ComputerRecordingUploadService.prototype);
    uploader.config={};uploader.store={};
    uploader.client={status:async()=>status,createUpload:async metadata=>{
      requests.push(metadata.kind);
      if(metadata.kind==='manifest' && missing && manifestAttempts++===0)
        throw new ComputerHttpError(409,'会话清单引用的录音尚未完整上传');
      return {upload:{...metadata,upload_id:metadata.kind,offset:metadata.size,status:'completed'}};
    }};
    const result=await uploader.upload([recording],()=>{},async()=>{},async()=>{receipts++;},[],[receipt]);
    assert.equal(result.sessions,1);assert.equal(hashes,missing?1:0);
    assert.deepEqual(requests,missing?['manifest','recording','manifest']:['manifest']);
    assert.equal(receipts,missing?1:0);
  }
  console.log('PASS saved per-file receipt skips audio hash and HTTP; missing receiver audio triggers one recheck and retry');
 } finally {fs.unlinkSync(file);fs.rmdirSync(dir);}
})().catch(e=>{console.error(e);process.exitCode=1;});
