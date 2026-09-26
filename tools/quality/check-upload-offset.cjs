// Execute the production upload loop against real files and pread semantics.
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),vm=require('node:vm'),crypto=require('node:crypto');
const ts=require(process.env.PHONE_TEST_TYPESCRIPT),exportsObject={},handles=new Map();
const source=fs.readFileSync(process.env.PHONE_UPLOAD_SOURCE||'phone/src/main/ets/computer/ComputerRecordingUploadService.ets','utf8');
let closed=0;const positions=[];
const fileIo={OpenMode:{READ_ONLY:'r'},statSync:fs.statSync,
 open:async p=>{const h=await fs.promises.open(p,'r');handles.set(h.fd,h);return {fd:h.fd};},
 read:async(fd,buffer,options)=>{positions.push(options.offset);
  return (await handles.get(fd).read(Buffer.from(buffer),0,options.length,options.offset??null)).bytesRead;},
 close:async fd=>{await handles.get(fd).close();handles.delete(fd);closed++;}};
const digest=b=>crypto.createHash('sha256').update(b).digest('hex');
vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText,{
 exports:exportsObject,require:name=>name==='@kit.CoreFileKit'?{fileIo,hash:{hash:async p=>digest(await fs.promises.readFile(p))}}:
 name.endsWith('ComputerReceiverConnection')?{verifyConfiguration:async()=>{}}:{},ArrayBuffer,Uint8Array,console});
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
 } finally {fs.unlinkSync(file);fs.rmdirSync(dir);}
})().catch(e=>{console.error(e);process.exitCode=1;});
