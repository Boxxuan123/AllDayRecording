// Native RDB + production ViewModel/queue/projection. Only network completion and
// read/commit scheduling are controlled; no production database is opened here.
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { PhoneProjectionRepository } from '../v3/data/PhoneProjectionRepository';
import { PhonePendingOperation } from '../v3/data/PhoneSyncProjection';
import { PhoneV3UseCases, PhoneV3SyncResult } from '../v3/application/PhoneV3UseCases';
import { PhoneV3LocalAudioRepositoryPort, PhoneV3RemotePort, PhoneV3RemoteSession } from '../v3/application/PhoneV3Ports';
import { PhoneV3LocalAudioFact, PhoneV3Snapshot, PhoneV3Utterance } from '../v3/domain/PhoneV3Models';
import { PhoneV3ViewModel } from '../v3/presentation/PhoneV3ViewModel';
import { ComputerConnectionError } from '../computer/ComputerConnectionError';

const DB: string = 'sync-bcd-refresh-isolated.db';
class Local implements PhoneV3LocalAudioRepositoryPort { async list(): Promise<Array<PhoneV3LocalAudioFact>> { return []; } }
class Remote implements PhoneV3RemotePort {
  async isPaired(): Promise<boolean> { return true; }
  async connect(): Promise<PhoneV3RemoteSession> { throw new Error('controlled offline'); }
}
class ControlledUse extends PhoneV3UseCases {
  holdSave: boolean = false;
  holdRead: boolean = false;
  releaseSave: (()=>void) | undefined = undefined;
  releaseRead: (()=>void) | undefined = undefined;
  changed: boolean = false;
  calls: number = 0;
  async synchronize(_status: (message:string)=>void = ():void=>{}, _rebuild: boolean = false,
    _budget: number = 100): Promise<PhoneV3SyncResult> {
    this.calls++;
    if (!this.changed) { throw new ComputerConnectionError('unreachable','connect','synthetic offline'); }
    this.changed=false;
    const result=new PhoneV3SyncResult(1,0,'synthetic');result.changed=true;result.requiresReload=true;return result;
  }
  async loadCached(facts: Array<PhoneV3LocalAudioFact>): Promise<PhoneV3Snapshot> {
    const result=await super.loadCached(facts);
    if(this.holdRead) { this.holdRead=false;await new Promise<void>((resolve)=>{this.releaseRead=resolve;}); }
    return result;
  }
  async queueAnnotation(rows:Array<PhoneV3Utterance>, personId:string, name:string,
    changed:boolean, kind:string): Promise<Array<PhonePendingOperation>> {
    if(this.holdSave) { this.holdSave=false;await new Promise<void>((resolve)=>{this.releaseSave=resolve;}); }
    return super.queueAnnotation(rows,personId,name,changed,kind);
  }
}
interface Resource { text:string; revision:number; utterance_id:string; }
async function waitFor(check:()=>boolean):Promise<void> {
  const until=Date.now()+10000;
  while(!check()) { if(Date.now()>until) { throw new Error('native refresh deadline'); }
    await new Promise<void>((resolve)=>setTimeout(resolve,10)); }
}
function check(value:boolean,message:string):void { if(!value) { throw new Error(message); } }

export async function nativeRefresh(context:common.UIAbilityContext, source:PhoneProjectionRepository):Promise<string> {
  const previous=await relationalStore.getRdbStore(context,{name:DB,securityLevel:relationalStore.SecurityLevel.S2});
  await previous.close();await relationalStore.deleteRdbStore(context,DB);
  const repo=await PhoneProjectionRepository.open(context,DB);
  for(let type of ['recording_session','utterance']) {
    for(let row of await source.projectionRows(type)) {
      await repo.applyChange({sequence:1,resource_type:type,resource_id:row.resourceId,revision:row.revision,
        operation:'upsert',resource:JSON.parse(row.payloadJson)});
    }
  }
  // The concurrent save targets another row. Changing the very row being reviewed
  // correctly rejects a stale annotation, and is not the refresh-loss scenario.
  const deltaRow=(await repo.projectionRows('utterance'))[0];
  const saveId='00000000000000000000000991';
  const copy=JSON.parse(deltaRow.payloadJson) as Resource;copy.utterance_id=saveId;
  await repo.applyChange({sequence:1,resource_type:'utterance',resource_id:saveId,
    revision:copy.revision,operation:'upsert',resource:copy});
  const use=new ControlledUse(repo,new Local(),new Remote());
  const model=new PhoneV3ViewModel(use);model.snapshot=await use.loadCached([]);
  const target=model.snapshot.sessions.flatMap((s)=>s.utterances).find((r)=>r.utteranceId===saveId)!;
  try {
    await model.startForegroundSync(context,'sync_phase2a_refresh_settings');
    use.holdSave=true;
    model.saveAnnotation([target],'','',false,'media_speech',():void=>{});
    await waitFor(()=>use.releaseSave!==undefined);
    // Two durable deltas while the save is suspended before entering its transaction.
    for(let text of ['NATIVE DELTA ONE','NATIVE DELTA FINAL']) {
      const row=(await repo.projectionRows('utterance',[deltaRow.resourceId]))[0];
      const resource=JSON.parse(row.payloadJson) as Resource;resource.text=text;resource.revision=row.revision+1;
      await repo.applyChange({sequence:2,resource_type:'utterance',resource_id:row.resourceId,
        revision:resource.revision,operation:'upsert',resource:resource});
      const calls=use.calls;use.changed=true;model.synchronize();
      await waitFor(()=>use.calls>calls&&!model.computerSyncActive);
    }
    const lastCalls=use.calls;use.releaseSave!();
    await waitFor(()=>!model.annotationSaving&&model.snapshot.sessions.flatMap((s)=>s.utterances).find((r)=>r.utteranceId===deltaRow.resourceId)!.text==='NATIVE DELTA FINAL');
    check(use.calls===lastCalls,'visibility waited for network');
    check(model.snapshot.sessions.flatMap((s)=>s.utterances).find((r)=>r.utteranceId===target.utteranceId)!.soundKind==='media_speech','new save lost');
    // A snapshot read before the next save must not replace that save when it returns late.
    use.holdRead=true;model.reloadAnnotationResult(():void=>{});
    await waitFor(()=>use.releaseRead!==undefined);
    model.saveAnnotation([model.snapshot.sessions.flatMap((s)=>s.utterances).find((r)=>r.utteranceId===target.utteranceId)!],'','',false,'non_speech',():void=>{});
    await waitFor(()=>!model.annotationSaving);use.releaseRead!();
    await new Promise<void>((resolve)=>setTimeout(resolve,30));
    check(model.snapshot.sessions.flatMap((s)=>s.utterances).find((r)=>r.utteranceId===target.utteranceId)!.soundKind==='non_speech','stale read replaced save');
    use.releaseRead=undefined;use.holdRead=true;model.reloadAnnotationResult(():void=>{});
    await waitFor(()=>use.releaseRead!==undefined);
    const snapshot=model.snapshot;model.stop();use.releaseRead!();
    await new Promise<void>((resolve)=>setTimeout(resolve,30));
    check(model.snapshot===snapshot,'stopped request published');
    const reopened=await PhoneProjectionRepository.open(context,DB);
    const next=new PhoneV3UseCases(reopened,new Local(),new Remote());
    check((await next.loadCached([])).sessions.flatMap((s)=>s.utterances).find((r)=>r.utteranceId===target.utteranceId)!.soundKind==='non_speech','reentry lost save');
    return '原生刷新交错通过';
  } finally { model.stop(); }
}
