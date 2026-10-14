import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { PhoneV3SessionCard, PhoneV3Conflict } from '../domain/PhoneV3Models';
import { localReminderTime, reminderConflictMessage } from '../domain/PhoneV3ReminderCommands';
import { PhoneProductTask, productTasks, productCalendarLabel, productCalendarRecovery } from './PhoneProductTasks';
import { PhoneProductEvidence, chatProductEvidence, dailyProductEvidence } from './PhoneProductEvidence';
import { PhoneDailyEvent } from '../domain/PhoneV3DailyModels';
import { PhoneEvidenceDetails } from './PhoneEvidenceDetails';

@Component
export struct PhoneTaskDetails {
  @ObjectLink viewModel:PhoneV3ViewModel;
  @Prop taskId:string='';
  @Prop stateRevision:number=0;
  @State private evidence:Array<PhoneProductEvidence>=[];
  @State private showEvidence:boolean=false;
  @State private editing:boolean=false;
  @State private title:string='';
  @State private due:string='';
  @State private mode:string='';
  @State private inputError:string='';
  @State private more:boolean=false;
  @State private technical:boolean=false;
  private generation:number=0;
  onClose:()=>void=():void=>{};
  onOpenSession:(session:PhoneV3SessionCard)=>void=():void=>{};
  aboutToAppear():void{this.loadEvidence();}
  aboutToDisappear():void{this.generation++;}
  private task():PhoneProductTask|undefined{return productTasks(this.viewModel.snapshot).find((t:PhoneProductTask):boolean=>t.id===this.taskId);}
  private pending():boolean{return !!this.task()?.chat?.pendingAction||(this.task()?.reminder?.pendingAction.length??0)>0;}
  private active():boolean{return this.task()?.category!=='ended';}
  private async loadEvidence():Promise<void>{
    const task=this.task();const generation=++this.generation;
    if(task?.chat!==undefined){this.evidence=task.chat.evidence.map(chatProductEvidence);return;}
    try{const cache=await this.viewModel.loadDailyCache();if(generation===this.generation){this.evidence=cache.events.filter((e:PhoneDailyEvent):boolean=>e.derivation_status==='active'&&e.linked_task_ids.includes(this.taskId)).flatMap((e:PhoneDailyEvent):Array<PhoneProductEvidence>=>e.evidence_snapshots.map(dailyProductEvidence));}}
    catch(_){if(generation===this.generation){this.inputError='依据暂未读取，可重试或查看来源录音';}}
  }
  private command(action:string):void{
    const task=this.task();if(task===undefined||this.pending()||this.viewModel.busy){return;}
    if(task.reminder!==undefined){this.viewModel.reminderCommand('reminder.task',task.id,action,task.reminder.eventRevision);}
    else if(task.chat!==undefined){this.viewModel.chatFollowupCommand(task.chat,action);}
  }
  private edit(mode:string):void{
    this.mode=mode;this.title=this.task()?.title??'';
    this.due=localReminderTime(this.task()?.reminder?.scheduledAt??this.task()?.chat?.time?.at??'');
    this.inputError='';this.editing=true;
  }
  private chooseTime():void{
    const selected=new Date(this.due.length>0?this.due.replace(' ','T'):Date.now()+3600000);
    DatePickerDialog.show({selected:selected,start:new Date(),showTime:true,useMilitaryTime:true,onDateAccept:(value:Date):void=>{this.due=localReminderTime(value.toISOString());this.inputError='';}});
  }
  private save():void{
    const task=this.task();if(task===undefined||this.pending()||this.viewModel.busy){return;}
    if(this.title.trim().length===0){this.inputError='请填写事项内容';return;}
    if((this.mode!=='edit'||this.due.length>0)&&(this.due.length===0||!Number.isFinite(Date.parse(this.due.replace(' ','T')))||Date.parse(this.due.replace(' ','T'))<=Date.now())){this.inputError='请选择明确的未来时间';return;}
    if(task.reminder!==undefined){this.viewModel.reminderCommand('reminder.task',task.id,'reschedule',task.reminder.eventRevision,this.title,this.due);}
    else if(task.chat!==undefined){this.viewModel.chatFollowupCommand(task.chat,this.mode,this.title,this.due.length===0?'':new Date(this.due.replace(' ','T')).toISOString());}
    this.editing=false;
  }
  private cancelTask():void{
    AlertDialog.show({title:'取消这项跟进？',message:'事项保留在历史记录中；已安排的日历提醒会按原流程移除。',primaryButton:{value:'保留',action:():void=>{}},secondaryButton:{value:'取消事项',action:():void=>{this.command(this.task()?.reminder!==undefined?'cancel':'ignore');}}});
  }
  private source():void{
    const session=this.viewModel.snapshot.sessions.find((s:PhoneV3SessionCard):boolean=>s.sessionId===this.task()?.reminder?.sessionId);
    if(session!==undefined){this.onOpenSession(session);}else{this.inputError='来源录音尚未同步到手机';}
  }
  @Builder private originalSheet(){PhoneEvidenceDetails({viewModel:this.viewModel,evidence:this.evidence,onClose:():void=>{this.showEvidence=false;},onOpenSession:(session:PhoneV3SessionCard):void=>{this.showEvidence=false;this.onOpenSession(session);}})}
  @Builder private actions(){
    if(this.active()&&!this.pending()){
      if(this.task()?.category==='clues'){
        if(this.task()?.chat?.actor_is_from_self===true){Button('确认现在仍需我处理').height(48).enabled(!this.viewModel.busy).onClick(():void=>{this.command('confirm');})}
        Text('确认处理只建立当前跟进；不会自动安排提醒').fontSize(12).fontColor($r('app.color.text_secondary'))
      }else{
        Button(this.task()?.category==='waiting'?'标记对方已完成':'标记完成').height(48).enabled(!this.viewModel.busy).onClick(():void=>{this.command('complete');})
        Button(this.task()?.reminder!==undefined?'修改时间':this.task()?.chat?.actor_is_from_self===true?'安排提醒':'修改跟进').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.viewModel.busy)
          .onClick(():void=>{this.edit(this.task()?.reminder!==undefined?'reschedule':this.task()?.chat?.actor_is_from_self===true?'enable_reminder':'edit');})
      }
    }
    if(this.editing){
      TextInput({text:this.title,placeholder:'事项内容'}).onChange((v:string):void=>{this.title=v;})
      Button(this.due.length>0?this.due:'选择日期与时间').height(48).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.chooseTime();})
      Text('按手机本地时间安排；确认后沿用原同步和日历流程').fontSize(12)
      Button(this.mode==='enable_reminder'?'确认时间并安排提醒':'保存修改').height(48).enabled(!this.viewModel.busy).onClick(():void=>{this.save();})
      Button('放弃修改').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.editing=false;})
    }
  }
  build(){
    Scroll(){Column({space:14}){
      Row(){Text('事项详情').fontSize(22).fontWeight(FontWeight.Bold);Blank();Button('返回列表').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(this.onClose)}.width('100%')
      if(this.task()===undefined){Text('这项事项已不在当前同步范围，请返回列表刷新。')}else{
        Text(this.task()?.title??'').fontSize(22).fontWeight(FontWeight.Medium).lineHeight(30)
        Text(this.task()?.status??'').fontSize(13).fontColor($r('app.color.text_secondary'))
        if((this.task()?.time.length??0)>0){Text(this.task()?.time??'').fontSize(16)}
        Text(this.task()?.explanation??'').fontSize(14)
        if(this.task()?.reminder!==undefined){Text(productCalendarLabel(this.viewModel.calendarReminderState(this.taskId),this.task()?.category==='ended')).fontSize(13).fontColor($r('app.color.text_secondary'))}
        if(this.pending()){Text('操作已保存在手机，等待电脑确认；暂不可重复修改').fontSize(13).fontColor($r('app.color.brand_warning'))}
        this.actions()
        if(this.evidence.length>0){
          Text('依据 · 原话').fontSize(16).fontWeight(FontWeight.Medium)
          Text(this.evidence[0].quote).fontSize(15).maxLines(3).textOverflow({overflow:TextOverflow.Ellipsis})
          Button('查看原文依据').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.showEvidence=true;})
        }else{Text('原话尚未同步到手机').fontSize(13);if((this.task()?.reminder?.sessionId.length??0)>0){Button('查看来源录音').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.source();})}}
        if(this.task()?.chat?.pending_change!==null&&this.task()?.chat?.pending_change!==undefined){
          Text('新进展需要你判断，原决定已保留').fontSize(14).fontColor($r('app.color.brand_warning'))
          Button('查看新进展原话').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.evidence=this.task()?.chat?.pending_change?.evidence.map(chatProductEvidence)??[];this.showEvidence=true;})
          Button('采用新进展').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.viewModel.busy&&!this.pending()&&this.task()?.chat?.pending_change?.kind!=='evidence_replaced').onClick(():void=>{this.command('accept_change');})
          Button('保留原决定').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.viewModel.busy&&!this.pending()).onClick(():void=>{this.command('dismiss_change');})
        }
        Button(this.more?'收起其他操作':'其他操作').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.more=!this.more;})
        if(this.more){
          if(this.task()?.chat!==undefined&&!this.active()){Button('重新开启跟进').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.viewModel.busy&&!this.pending()).onClick(():void=>{this.command('reopen');})}
          if(this.task()?.category==='clues'){Button('修改线索').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.viewModel.busy&&!this.pending()).onClick(():void=>{this.edit('edit');})}
          if(this.active()){Button('取消事项').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.viewModel.busy&&!this.pending()).onClick(():void=>{this.cancelTask();})}
          if(this.task()?.reminder!==undefined&&productCalendarRecovery(this.viewModel.calendarReminderState(this.taskId),!this.active()).length>0){Button(productCalendarRecovery(this.viewModel.calendarReminderState(this.taskId),!this.active())).height(44).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.viewModel.busy&&!this.pending()).onClick(():void=>{this.viewModel.retryCalendarReminder(this.taskId);})}
          ForEach(this.task()?.chat?.uncertainty??[],(line:string)=>{Text(line).fontSize(13)},(line:string):string=>line)
          Button(this.technical?'收起技术详情':'技术详情').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.technical=!this.technical;})
          if(this.technical){Text(JSON.stringify(this.task()?.chat??this.task()?.reminder)).fontSize(11);Text(this.viewModel.error).fontSize(11)}
        }
      }
      if(this.inputError.length>0){Text(this.inputError).fontSize(13).fontColor($r('app.color.brand_warning'))}
      if(this.viewModel.error.length>0){Text('操作尚未完成，现有记录仍保留；请检查同步后重试').fontSize(13).fontColor($r('app.color.brand_warning'))}
      ForEach(this.viewModel.snapshot.conflicts.filter((c:PhoneV3Conflict):boolean=>c.payloadJson.includes(this.taskId)),(c:PhoneV3Conflict)=>{Text(`操作冲突：${reminderConflictMessage(c.errorJson)}；请同步后核对，再重新选择。`).fontSize(13).fontColor($r('app.color.brand_warning'))},(c:PhoneV3Conflict):string=>c.operationId)
    }.width('100%').padding(18).alignItems(HorizontalAlign.Start)}.width('100%').height('100%').align(Alignment.TopStart).backgroundColor($r('app.color.page_background'))
      .bindSheet($$this.showEvidence,this.originalSheet(),{height:SheetSize.LARGE,showClose:false})
  }
}
