import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { PhoneV3SessionCard } from '../domain/PhoneV3Models';
import { PhoneDailyCache, PhoneDailyEvent } from '../domain/PhoneV3DailyModels';
import { PhoneProductDay, PhoneProductHighlight, productDay } from './PhoneProductHome';
import { PhoneProductTask, productAttention } from './PhoneProductTasks';
import { PhoneProductEvidence, dailyProductEvidence, productTime } from './PhoneProductEvidence';
import { PhoneEvidenceDetails } from './PhoneEvidenceDetails';
import { PhoneTaskDetails } from './PhoneTaskDetails';
import { phoneV3SessionTitle } from './PhoneV3UiFormat';
import { PHONE_V3_FLOATING_TAB_BAR_CONTENT_END_OFFSET } from './PhoneV3NativeUi';

@Component
export struct PhoneV3HomePage {
  @ObjectLink viewModel:PhoneV3ViewModel;
  @Prop @Watch('loadDaily') stateRevision:number=0;
  @State private cache:PhoneDailyCache=new PhoneDailyCache();
  @State private loading:boolean=true;
  @State private error:boolean=false;
  @State private timeline:boolean=false;
  @State private showEvidence:boolean=false;
  @State private selected:Array<PhoneProductEvidence>=[];
  @State private sheetKind:string='evidence';
  @State private taskId:string='';
  @State private controls:boolean=false;
  private generation:number=0;
  private dayClock:Date=new Date();
  @State private today:string='';
  onOpenSession:(session:PhoneV3SessionCard)=>void=():void=>{};
  onOpenReviews:()=>void=():void=>{};
  onOpenRecall:()=>void=():void=>{};
  onOpenTasks:()=>void=():void=>{};
  onOpenDaily:()=>void=():void=>{};
  onOpenSync:()=>void=():void=>{};
  aboutToAppear():void{this.loadDaily();}
  aboutToDisappear():void{this.generation++;}
  private loadDaily():void{
    this.dayClock.setTime(Date.now()+8*3600000);this.today=this.dayClock.toISOString().slice(0,10);
    const generation=++this.generation;
    this.viewModel.loadDailyCache().then((cache:PhoneDailyCache):void=>{if(generation===this.generation){this.cache=cache;this.loading=false;this.error=false;}})
      .catch(():void=>{if(generation===this.generation){this.error=true;this.loading=false;}});
  }
  private day():PhoneProductDay{return productDay(this.cache,this.today);}
  private tasks():Array<PhoneProductTask>{return productAttention(this.viewModel.snapshot,Date.now());}
  private recordings():Array<PhoneV3SessionCard>{return this.viewModel.snapshot.sessions.slice().sort((a:PhoneV3SessionCard,b:PhoneV3SessionCard):number=>b.startedAt-a.startedAt).slice(0,3);}
  private recordingText(session:PhoneV3SessionCard):string{
    const text=session.utterancePage(1)[0]?.text;
    return text!==undefined&&text.length>0?text:session.localPaths.length>0?'可直接试听 · 转写尚未同步':'可打开已同步记录';
  }
  @Builder private evidenceSheet(){PhoneEvidenceDetails({viewModel:this.viewModel,evidence:this.selected,onClose:():void=>{this.showEvidence=false;},onOpenSession:(session:PhoneV3SessionCard):void=>{this.showEvidence=false;this.onOpenSession(session);}})}
  @Builder private taskSheet(){PhoneTaskDetails({viewModel:this.viewModel,taskId:this.taskId,stateRevision:this.stateRevision,onClose:():void=>{this.showEvidence=false;},onOpenSession:(session:PhoneV3SessionCard):void=>{this.showEvidence=false;this.onOpenSession(session);}})}
  @Builder private sheet(){if(this.sheetKind==='task'){this.taskSheet()}else{this.evidenceSheet()}}
  @Builder private highlight(value:PhoneProductHighlight){
    Column({space:7}){
      Text(value.label).fontSize(11).fontColor($r('app.color.text_secondary'))
      Text(value.text).fontSize(17).lineHeight(25).maxLines(4).textOverflow({overflow:TextOverflow.Ellipsis})
      Button('查看原文依据').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.selected=value.evidence;this.sheetKind='evidence';this.showEvidence=true;})
    }.width('100%').padding(14).alignItems(HorizontalAlign.Start).backgroundColor($r('app.color.surface_primary')).borderRadius(14)
  }
  @Builder private event(event:PhoneDailyEvent){
    Column({space:5}){
      Text(productTime(event.start_at)).fontSize(12).fontColor($r('app.color.text_secondary'))
      Text(event.title).fontSize(15).maxLines(2).textOverflow({overflow:TextOverflow.Ellipsis})
      Button('查看这段原文').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.selected=event.evidence_snapshots.map(dailyProductEvidence);this.sheetKind='evidence';this.showEvidence=true;})
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  build(){
    Scroll(){Column({space:12}){
      Text(this.today).fontSize(12).fontColor($r('app.color.text_secondary'))
      if(!this.loading){Text(this.day().coverage).fontSize(12).fontColor($r('app.color.text_secondary'))}
      if(this.loading){Text('正在读取手机已保存内容…').fontSize(13)}
      if(this.error){Row(){Text('回顾暂未读取，已有记录仍可打开').fontSize(13).layoutWeight(1);Button('重试').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.loadDaily();})}.width('100%')}
      if(this.tasks().length>0){
        Text('需要关注').fontSize(18).fontWeight(FontWeight.Medium)
        ForEach(this.tasks(),(task:PhoneProductTask)=>{
          Button({type:ButtonType.ROUNDED_RECTANGLE}){Column({space:5}){Text(task.title).fontSize(16).maxLines(2);Text(task.time.length>0?task.time:task.status).fontSize(12).fontColor($r('app.color.text_secondary'))}.width('100%').alignItems(HorizontalAlign.Start)}.width('100%').padding(14).backgroundColor($r('app.color.surface_primary')).fontColor($r('app.color.text_primary')).onClick(():void=>{this.taskId=task.id;this.sheetKind='task';this.showEvidence=true;})
        },(task:PhoneProductTask):string=>task.id)
      }
      if(this.day().highlights.length>0){
        Row(){Text(this.day().title).fontSize(18).fontWeight(FontWeight.Medium);Blank();Button('历史回顾').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(this.onOpenDaily)}.width('100%')
        if(this.day().notice.length>0){Text(this.day().notice).fontSize(12).fontColor($r('app.color.text_secondary'))}
        ForEach(this.day().highlights,(value:PhoneProductHighlight)=>{this.highlight(value)},(value:PhoneProductHighlight):string=>value.text)
      }else if(!this.loading){Text(this.day().notice).fontSize(13).fontColor($r('app.color.text_secondary'))}
      if(this.day().timeline.length>0){
        Button(this.timeline?'收起时间线':`展开时间线 · ${this.day().timeline.length} 段`).height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.timeline=!this.timeline;})
        if(this.timeline){ForEach(this.day().timeline.slice(0,15),(event:PhoneDailyEvent)=>{this.event(event)},(event:PhoneDailyEvent):string=>event.event_id);if(this.day().timeline.length>15){Button('查看完整回顾').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(this.onOpenDaily)}}
      }
      if(this.recordings().length>0){Text('最近可回看的记录').fontSize(18).fontWeight(FontWeight.Medium)}
      ForEach(this.recordings(),(session:PhoneV3SessionCard)=>{
        Button({type:ButtonType.ROUNDED_RECTANGLE}){Column({space:6}){Text(`${phoneV3SessionTitle(session)} · 录音`).fontSize(13).fontColor($r('app.color.text_secondary'));Text(this.recordingText(session)).fontSize(15).maxLines(2).textOverflow({overflow:TextOverflow.Ellipsis});Text('打开录音 ›').fontSize(12).fontColor($r('app.color.brand_primary'))}.width('100%').alignItems(HorizontalAlign.Start)}.width('100%').padding(14).backgroundColor($r('app.color.surface_primary')).fontColor($r('app.color.text_primary')).onClick(():void=>this.onOpenSession(session))
      },(session:PhoneV3SessionCard):string=>session.id)
      if(!this.loading&&this.recordings().length===0&&this.day().highlights.length===0&&this.day().timeline.length===0){
        Text('手机还没有可回看的内容').fontSize(17)
        Button('接收或同步记录').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(this.onOpenSync)
      }
      Column({space:5}){
        Text(this.viewModel.snapshot.sync.lastServerTime.length>0?`最近同步 ${productTime(this.viewModel.snapshot.sync.lastServerTime)}`:'尚无同步更新时间').fontSize(12)
        if(this.day().updated.length>0){Text(`回顾更新 ${productTime(this.day().updated)}`).fontSize(12)}
        if(this.viewModel.computerSyncError.length>0){Text('电脑暂不可用，当前展示已保存内容').fontSize(12).fontColor($r('app.color.brand_warning'))}
        Row(){Text(this.viewModel.device.remoteRecordingState==='recording'?'正在录音':this.viewModel.device.watchSyncing?'正在接收录音':`${this.viewModel.snapshot.sync.pendingOperations} 项修改待同步`).fontSize(12).layoutWeight(1);Button('同步状态').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(this.onOpenSync)}.width('100%')
        Button(this.controls?'收起录音控制':'录音控制').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.controls=!this.controls;})
        if(this.controls){Text(this.viewModel.device.watchStatus).fontSize(12);Button(this.viewModel.device.remoteRecordingState==='recording'?'停止录音并保存':'开始录音').height(44).enabled(!this.viewModel.device.watchControlBusy&&!this.viewModel.device.receiverReconnecting).onClick(():void=>{this.viewModel.requestWatchRecordingState(this.viewModel.device.remoteRecordingState==='recording'?'stopped':'recording');})}
      }.width('100%').alignItems(HorizontalAlign.Start)
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start)}.width('100%').height('100%').align(Alignment.TopStart).contentEndOffset(PHONE_V3_FLOATING_TAB_BAR_CONTENT_END_OFFSET).backgroundColor($r('app.color.page_background'))
      .bindSheet($$this.showEvidence,this.sheet(),{height:SheetSize.LARGE,showClose:false})
  }
}
