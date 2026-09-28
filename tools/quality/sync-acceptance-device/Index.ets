// Isolated native acceptance assembly, never imported by the production entry.
import { HdsNavigation } from '@kit.UIDesignKit';
import { PhoneV3AnnotationPage } from '../v3/presentation/PhoneV3AnnotationPage';
import { PhoneV3AnnotationEditor } from '../v3/domain/PhoneV3AnnotationEditor';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { systemDateTime } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { ReceivedRecordingFile, PCM_SAMPLE_RATE_HZ } from 'common';
import { PhoneDeviceKeyClient } from '../computer/PhoneDeviceKeyClient';
import { ComputerTransferConfig, ComputerTransferConfigStore } from '../computer/ComputerTransferConfigStore';
import { ComputerRecordingBackupService, ComputerRecordingBackupRuntime } from '../computer/ComputerRecordingBackupService';
import { PhoneV3DeviceRemote } from '../v3/data/PhoneV3DeviceRemote';
import { PhoneProjectionRepository } from '../v3/data/PhoneProjectionRepository';
import { PhoneV3UseCases } from '../v3/application/PhoneV3UseCases';
import { PhoneV3LocalAudioRepositoryPort } from '../v3/application/PhoneV3Ports';
import { PhoneV3LocalAudioFact, PhoneV3Utterance } from '../v3/domain/PhoneV3Models';
import { PhoneV3ViewModel } from '../v3/presentation/PhoneV3ViewModel';
const KEY: string = 'alldayrecording.acceptance.20260927';
interface Config { database?:string;baselineOnly?:boolean;baseUrl:string;receiverId:string;deviceId:string;fingerprint:string; }
class Route { editor:PhoneV3AnnotationEditor;constructor(editor:PhoneV3AnnotationEditor){this.editor=editor;} }
interface Sample { scenario:string;count:number;start:number;visible:number;elapsed:number;uploadBytes:number; }
class Local implements PhoneV3LocalAudioRepositoryPort { async list():Promise<Array<PhoneV3LocalAudioFact>> { return []; } }
class ConfigStore extends ComputerTransferConfigStore {
 private value:ComputerTransferConfig;
 constructor(context:common.UIAbilityContext,c:Config){super(context);this.value=new ComputerTransferConfig(c.baseUrl,c.fingerprint,'localhost',context.cacheDir+'/sync-acceptance-ca.pem',c.receiverId,c.deviceId);this.value.signingKeyAlias=KEY;}
 async load():Promise<ComputerTransferConfig>{return this.value;}
 async saveLastAddress(address:string):Promise<ComputerTransferConfig>{this.value.baseUrl=address;return this.value;}
}
function now():number{return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP,false);}
async function write(path:string,bytes:Uint8Array):Promise<void>{const f=await fileIo.open(path,fileIo.OpenMode.CREATE|fileIo.OpenMode.WRITE_ONLY|fileIo.OpenMode.TRUNC);try{await fileIo.write(f.fd,bytes.buffer);}finally{await fileIo.close(f);}}
async function pause(ms:number):Promise<void>{return new Promise<void>((resolve)=>{setTimeout(resolve,ms);});}
@Entry
@Component
struct Index {
 @State private model:PhoneV3ViewModel=new PhoneV3ViewModel();
 @State private note:string='初始化验收';
 @State private revision:number=0;
 @State private uploaded:number=0;
 @State private sampleLabel:string='';
 private nav:NavPathStack=new NavPathStack();
 private samples:Array<Sample>=[];
 private context:common.UIAbilityContext|undefined=undefined;
 private use:PhoneV3UseCases|undefined=undefined;
 private saved:boolean=false;
 private waiting:boolean=false;
 private visible:number=0;
 private selected:Array<string>=[];
 private kind:string='';
 private layout=():void=>{
  if(!this.waiting||!this.saved||this.model.annotationSaving||this.model.snapshot.sync.pendingOperations!==0){return;}
  const rows=this.model.snapshot.sessions.flatMap((s)=>s.utterances).filter((u)=>this.selected.includes(u.utteranceId));
  if(rows.length===this.selected.length&&rows.every((u)=>!u.annotationPending&&u.soundKind===this.kind)){
   this.visible=now();this.waiting=false;
  }
 };
 aboutToAppear():void{this.getUIContext().getUIObserver().on('didLayout',this.layout);this.run().catch((e:Object):void=>{this.note=String(e);console.error('[acceptance] '+this.note);});}
 aboutToDisappear():void{this.getUIContext().getUIObserver().off('didLayout',this.layout);this.model.stop();}
 private async run():Promise<void>{
  const context=this.getUIContext().getHostContext() as common.UIAbilityContext;this.context=context;
  const key=await new PhoneDeviceKeyClient(KEY).ensurePublicKey();
  await write(context.cacheDir+'/sync-acceptance-public.txt',util.TextEncoder.create('utf-8').encodeInto(key));
  this.note='验收公钥已准备';
  const cfg=JSON.parse(util.TextDecoder.create('utf-8').decodeToString(await context.resourceManager.getRawFileContent('sync-acceptance-config.json'))) as Config;
  await write(context.cacheDir+'/sync-acceptance-ca.pem',await context.resourceManager.getRawFileContent('sync-acceptance-ca.pem'));
  if(cfg.database!==undefined&&!/^sync-acceptance-[0-9]+\.db$/.test(cfg.database)){throw new Error('仅允许独立验收库');}
  const repo=await PhoneProjectionRepository.open(context,cfg.database ?? 'sync-acceptance-'+Date.now()+'.db');const store=new ConfigStore(context,cfg);
  const use=new PhoneV3UseCases(repo,new Local(),new PhoneV3DeviceRemote(context,store));this.use=use;
  this.note='首次快照同步';
  for(let page=0;page<100;page++){const initial=await use.synchronize();if(initial.completion==='complete'){break;}if(page===99){throw new Error('首次快照未完成');}}
  await use.refreshSupplementary();
  this.model=new PhoneV3ViewModel(use);this.model.snapshot=await use.loadCached([]);
  this.model.setStateChangeListener(():void=>{this.revision+=1;});
  await this.model.startForegroundSync(context,'sync_acceptance_settings');
  await pause(1500);
  for(let i=0;i<20;i++){await this.measure('idle',1,i);}
  for(let i=0;i<5;i++){await this.measure('idle',32,i);}
  if(cfg.baselineOnly){this.nav.clear();this.note='基线验收完成';await this.persist();return;}
  this.note='启动并发录音上传';
  const bytes=new Uint8Array(16*1024*1024+44);const header=new DataView(bytes.buffer);
  bytes.set(util.TextEncoder.create('utf-8').encodeInto('RIFF'),0);header.setUint32(4,bytes.length-8,true);
  bytes.set(util.TextEncoder.create('utf-8').encodeInto('WAVEfmt '),8);header.setUint32(16,16,true);header.setUint16(20,1,true);header.setUint16(22,1,true);header.setUint32(24,PCM_SAMPLE_RATE_HZ,true);header.setUint32(28,PCM_SAMPLE_RATE_HZ*2,true);header.setUint16(32,2,true);header.setUint16(34,16,true);bytes.set(util.TextEncoder.create('utf-8').encodeInto('data'),36);header.setUint32(40,bytes.length-44,true);
  const path=context.cacheDir+'/sync-acceptance-recording.wav';await write(path,bytes);
  const name='segment_000001_first_000000000000.wav';
  const recording:ReceivedRecordingFile={fileName:name,path:path,size:bytes.length,durationMs:16777216/2/PCM_SAMPLE_RATE_HZ*1000,requestId:'synthetic',receivedAt:1,sourcePath:'pcm_gap_test_'+Date.now()+'/'+name};
  const backup=new ComputerRecordingBackupService(new ComputerRecordingBackupRuntime(context,store),repo);
  const task=backup.backup([recording],(p):void=>{this.uploaded=p.transferredBytes;});
  const deadline=now()+15000;while(this.uploaded===0&&now()<deadline){await pause(50);}
  if(this.uploaded===0){throw new Error('并发上传未启动');}
  for(let i=0;i<20;i++){await this.measure('worker_upload',1,i);}
  for(let i=0;i<5;i++){await this.measure('worker_upload',32,i);}
  await task;this.nav.clear();this.note='验收采样完成';await this.persist();
 }
 private async measure(scenario:string,count:number,iteration:number):Promise<void>{
  while(this.model.annotationSaving||this.model.computerSyncActive){await pause(20);}
  const rows=this.model.snapshot.sessions.flatMap((s)=>s.utterances).slice(0,count);
  if(rows.length!==count){throw new Error('合成记录不足');}
  const editor=new PhoneV3AnnotationEditor();editor.open(rows,this.model.snapshot.sessions);
  this.nav.clear();this.nav.pushPath({name:'annotation',param:new Route(editor)});await pause(120);
  this.selected=rows.map((u)=>u.utteranceId);this.kind=iteration%2===0?'non_speech':'live_speech';
  this.saved=false;this.waiting=true;this.visible=0;this.note=scenario+' '+count+' 条 第 '+(iteration+1)+' 次';
  const start=now();this.sampleLabel=this.note;
  this.model.saveAnnotation(rows,'','',false,this.kind,():void=>{this.saved=true;});
  const deadline=start+30000;while(this.waiting&&now()<deadline){await pause(20);}
  if(this.waiting){throw new Error('确认超时 '+this.model.error+' '+this.model.computerSyncError);}
  const sample:Sample={scenario:scenario,count:count,start:start,visible:this.visible,elapsed:this.visible-start,uploadBytes:this.uploaded};
  this.samples.push(sample);console.info('[acceptance] '+JSON.stringify(sample));await this.persist();await pause(100);
 }
 private async persist():Promise<void>{if(this.context){await write(this.context.cacheDir+'/sync-acceptance-results.json',util.TextEncoder.create('utf-8').encodeInto(JSON.stringify(this.samples)));}}
 @Builder private destination(name:string,param:Object){
  PhoneV3AnnotationPage({viewModel:this.model,navStack:this.nav,editor:(param as Route).editor,stateRevision:this.revision,scopeTitle:'同步性能验收'})
 }
 build(){HdsNavigation(this.nav){Column({space:8}){
  Text(this.note).fontSize(22)
  Text('真实生产同步链路 / 合成验收记录')
  Text('上传字节 '+this.uploaded)
  Text('待确认 '+this.model.snapshot.sync.pendingOperations+' / 刷新 '+this.revision)
  Text(this.model.error+' '+this.model.computerSyncError)
  Text(this.sampleLabel)
  ForEach(this.model.snapshot.sessions.flatMap((s)=>s.utterances).slice(0,32),(u:PhoneV3Utterance)=>{
   Text(u.utteranceId.slice(-5)+' '+u.soundKind+' '+(u.annotationPending?'待确认':'已确认')).fontSize(12)
  },(u:PhoneV3Utterance)=>u.utteranceId)
 }.width('100%').height('100%').padding(12)}.navDestination(this.destination)}
}
