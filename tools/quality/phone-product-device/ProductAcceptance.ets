// Isolated native test assembly. No production pairing, Calendar, receiver or data files.
import { common } from '@kit.AbilityKit';
import { AudioPlaybackService } from 'common';
import { PhoneV3DeviceBridgePort, PhoneV3RemotePort, PhoneV3RemoteSession, PhoneV3LocalAudioRepositoryPort } from '../v3/application/PhoneV3Ports';
import { DeviceV3StatusResponse, DeviceV3SyncRequest, DeviceV3SyncResponse, DeviceV3Change, DeviceV3OperationReceipt, DeviceV3AnnotationRequest, DeviceV3AnnotationResponse, DeviceV3ReviewSnapshot, DeviceV3ReviewActionRequest, DeviceV3ReviewActionResponse, DeviceV3ReviewAudioRequest, DeviceV3ReviewAudioResponse } from '../computer/ComputerTransferProtocol';
import { V3ReminderDto } from '../v3/contracts/V3ContractModels';
import { PhoneV3ReminderCommand } from '../v3/domain/PhoneV3ReminderCommands';
import { RecallRequest, RecallResponse } from '../v3/domain/PhoneHistoryRecall';
import { PhoneV3DeviceState, PhoneV3LocalAudioFact } from '../v3/domain/PhoneV3Models';
export interface ProductObservation {phase:string;playing?:boolean;message?:string;position?:number;start?:number;end?:number;action?:string;id?:string;revision?:number;status?:string;time?:string;query_id?:string;evidence_id?:string;question?:string;summarize?:boolean;mode?:number;database?:string;}
export interface ProductFixture { packet:DeviceV3SyncResponse;query:RecallResponse;context:RecallResponse;recording_context:RecallResponse; }
export class ProductLocal implements PhoneV3LocalAudioRepositoryPort {
  private path:string;private empty:boolean;
  constructor(path:string,empty:boolean){this.path=path;this.empty=empty;}
  async list():Promise<Array<PhoneV3LocalAudioFact>>{return this.empty?[]:[new PhoneV3LocalAudioFact('phone-product-v2-tone','phone-product-v2-tone',[this.path],1791939600000,1791939600000,384044,12000)];}
}
export class ProductBridge implements PhoneV3DeviceBridgePort {
  private value:PhoneV3DeviceState=new PhoneV3DeviceState('隔离验收音频');
  private player:AudioPlaybackService;
  private end:number=0;
  private path:string;private observe:(event:ProductObservation)=>void;
  constructor(path:string,observe:(event:ProductObservation)=>void){this.path=path;this.observe=observe;
    this.player=new AudioPlaybackService((playing:boolean,message:string):void=>{this.value.isPlaying=playing;this.observe({phase:'audio_state',playing:playing,message:message});},(position:number,duration:number):void=>{this.value.playbackPositionMs=position;this.value.playbackDurationMs=duration;this.observe({phase:'audio_progress',position:position});if(this.end>0&&position>=this.end){this.stopPlayback();}});
  }
  state():PhoneV3DeviceState{const value=new PhoneV3DeviceState();value.isPlaying=this.value.isPlaying;value.playbackPositionMs=this.value.playbackPositionMs;value.playbackDurationMs=this.value.playbackDurationMs;value.watchStatus=this.value.watchStatus;return value;}
  selectSession(_key:string):void{}
  playRange(_key:string,start:number,end:number):void{this.end=end;this.observe({phase:'audio_range',start:start,end:end});this.player.play(this.path,12000,start).catch((error:Object):void=>{this.observe({phase:'audio_error',message:String(error)});});}
  togglePlayback():void{if(this.value.isPlaying){this.player.pause();}else{this.player.resume();}}
  seekPlayback(position:number):void{this.player.seekTo(position);}
  stopPlayback():void{this.end=0;this.player.release();this.value.isPlaying=false;}
  requestWatchSync():void{}
  requestWatchRecordingState(_state:string):void{}
  toggleWifiReceiver():void{}
  retryWifiReceiver():void{}
  reconnectReceiver():void{}
  async deleteLocalSession(_key:string):Promise<void>{throw new Error('禁止删除验收之外的文件');}
  addLocalAudioChangeListener(_listener:()=>void):void{}
  removeLocalAudioChangeListener(_listener:()=>void):void{}
}
export class ProductRemote implements PhoneV3RemotePort,PhoneV3RemoteSession {
  private sequence:number;
  private fixture:ProductFixture;private mode:number;private observe:(event:ProductObservation)=>void;
  constructor(fixture:ProductFixture,mode:number,observe:(event:ProductObservation)=>void){this.fixture=fixture;this.mode=mode;this.observe=observe;this.sequence=fixture.packet.changes.length;}
  async isPaired():Promise<boolean>{return true;}
  async connect():Promise<PhoneV3RemoteSession>{return this;}
  async status():Promise<DeviceV3StatusResponse>{return {contract_version:'3.12.0',projection_version:7,server_time:new Date().toISOString()};}
  async sync(request:DeviceV3SyncRequest):Promise<DeviceV3SyncResponse>{
    const changes:Array<DeviceV3Change>=[];const receipts:Array<DeviceV3OperationReceipt>=[];
    for(const op of request.client_operations){
      const command=op.payload as PhoneV3ReminderCommand;
      if(op.kind!=='reminder.task'){throw new Error('隔离验收仅允许已确认任务命令');}
      const row=this.fixture.packet.changes.find((c:DeviceV3Change):boolean=>c.resource_type==='reminder'&&c.resource_id===command.event_id);
      if(row===undefined){throw new Error('隔离任务不存在');}
      const task=row.resource as V3ReminderDto;
      if(op.base_revision!==task.event_revision){throw new Error('隔离任务版本冲突');}
      task.event_revision++;task.status=command.action==='complete'?'completed':command.action==='cancel'?'cancelled':'scheduled';
      if(command.scheduled_at!==undefined){task.scheduled_at=command.scheduled_at;}
      if(command.title!==undefined){task.title=command.title;}
      changes.push({sequence:++this.sequence,resource_type:'reminder',resource_id:task.event_id,revision:task.event_revision,operation:'upsert',resource:task});
      receipts.push({operation_id:op.operation_id,status:'applied',resource_revision:task.event_revision,error:null,resource_results:[{resource_id:task.event_id,revision:task.event_revision}]});
      this.observe({phase:'task_receipt',action:command.action,id:task.event_id,revision:task.event_revision,status:task.status,time:task.scheduled_at});
    }
    return {projection_version:7,changes:changes,receipts:receipts,next_cursor:'cursor-'+this.sequence,has_more:false,server_time:new Date().toISOString()};
  }
  async recall(request:RecallRequest):Promise<RecallResponse>{
    this.observe({phase:'recall',action:request.action,query_id:request.query_id,evidence_id:request.evidence_id,question:request.question,summarize:request.summarize});
    if(request.action==='catalog'){return {people:[]};}
    if(request.action==='cancel'){return {status:'cancelled'};}
    const response=JSON.parse(JSON.stringify(request.action==='context'?(request.evidence_id?.startsWith('recording:')?this.fixture.recording_context:this.fixture.context):this.fixture.query)) as RecallResponse;
    response.query_id=request.query_id;
    if(request.action==='query'&&request.sent_from!==undefined&&request.source==='wechat'){response.evidence=this.fixture.context.evidence;}
    if(this.mode===1){response.evidence=[];response.claims=[];response.answer='当前范围没有找到相关内容';response.unknown=[];}
    if(this.mode===2){response.coverage=['QQ 尚未覆盖，只能核对已保存微信和录音'];response.latest_status_confirmed=false;}
    if(this.mode===3){response.coverage=['来源离线，返回已保存原文'];if(request.action==='context'){response.status='unavailable';response.evidence=this.fixture.query.evidence?.filter((e):boolean=>e.id===request.evidence_id);}}
    if(this.mode===4){response.model_status='failed';response.answer='归纳未完成，已命中的原文如下';response.claims=[];}
    if(this.mode===5&&request.action==='context'){response.status='stale';response.invalidated_evidence_ids=[request.evidence_id??''];}
    return response;
  }
  async annotations(_request:DeviceV3AnnotationRequest):Promise<DeviceV3AnnotationResponse>{throw new Error('隔离验收不提交标注');}
  async reviews():Promise<DeviceV3ReviewSnapshot>{throw new Error('隔离验收不读取生产审核');}
  async resolveReview(_request:DeviceV3ReviewActionRequest):Promise<DeviceV3ReviewActionResponse>{throw new Error('隔离验收不提交审核');}
  async reviewAudio(_request:DeviceV3ReviewAudioRequest):Promise<DeviceV3ReviewAudioResponse>{throw new Error('隔离验收不调用远端音频');}
}
