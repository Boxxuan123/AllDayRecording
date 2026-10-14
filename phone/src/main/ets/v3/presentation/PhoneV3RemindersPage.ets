import { PhoneV3SessionCard } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { PhoneProductTask, productTasks, productTaskMatches } from './PhoneProductTasks';
import { PhoneTaskDetails } from './PhoneTaskDetails';
import { PHONE_V3_FLOATING_TAB_BAR_CONTENT_END_OFFSET } from './PhoneV3NativeUi';
@Component
export struct PhoneV3RemindersPage {
  @ObjectLink viewModel:PhoneV3ViewModel;
  @Prop stateRevision:number=0;
  @Prop eventId:string='';
  @State private category:string='self';
  @State private limit:number=15;
  @State private selected:string='';
  @State private showDetail:boolean=false;
  onOpenReviews:()=>void=():void=>{};
  onOpenSession:(session:PhoneV3SessionCard)=>void=():void=>{};
  private scroller:Scroller=new Scroller();
  aboutToAppear():void{if(this.eventId.length>0){this.selected=this.eventId;this.showDetail=true;}}
  private tasks():Array<PhoneProductTask>{return productTasks(this.viewModel.snapshot).filter((task:PhoneProductTask):boolean=>productTaskMatches(task,this.category));}
  private labels():Array<string>{return ['需要我处理','等待对方','已确认提醒','线索与待判断','已完成'];}
  @Builder private detail(){PhoneTaskDetails({viewModel:this.viewModel,taskId:this.selected,stateRevision:this.stateRevision,onClose:():void=>{this.showDetail=false;},onOpenSession:(session:PhoneV3SessionCard):void=>{this.showDetail=false;this.onOpenSession(session);}})}
  @Builder private card(task:PhoneProductTask){
    Column({space:7}){
      Text(task.title).fontSize(17).fontWeight(FontWeight.Medium).maxLines(2).textOverflow({overflow:TextOverflow.Ellipsis})
      Row(){Text(task.status).fontSize(12).fontColor($r('app.color.text_secondary'));Blank();if(task.time.length>0){Text(task.time).fontSize(12).fontColor($r('app.color.text_secondary'))}}.width('100%')
      Text(task.explanation).fontSize(13).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis}).fontColor($r('app.color.text_secondary'))
      Button(task.category==='clues'?'核对这条线索':'查看详情').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.selected=task.id;this.showDetail=true;})
    }.width('100%').padding(14).alignItems(HorizontalAlign.Start).backgroundColor($r('app.color.surface_primary')).borderRadius(14)
  }
  build(){
    Scroll(this.scroller){Column({space:12}){
      Select(this.labels().map((label:string):SelectOption=>({value:label}))).selected(['self','waiting','scheduled','clues','ended'].indexOf(this.category)).value(this.labels()[['self','waiting','scheduled','clues','ended'].indexOf(this.category)])
        .onSelect((i:number):void=>{this.category=['self','waiting','scheduled','clues','ended'][i];this.limit=15;this.scroller.scrollTo({xOffset:0,yOffset:0});})
      Row(){Text(`${this.tasks().length} 项`).fontSize(12).fontColor($r('app.color.text_secondary'));Blank();Button('审核箱').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(this.onOpenReviews)}.width('100%')
      if(this.category==='clues'){Text('历史原话和少量建议；确认当前仍需处理后才进入待办').fontSize(13).fontColor($r('app.color.text_secondary'))}
      ForEach(this.tasks().slice(0,this.limit),(task:PhoneProductTask)=>{this.card(task)},(task:PhoneProductTask):string=>task.id)
      if(this.tasks().length===0){
        Text(this.category==='self'?'当前没有已确认需你处理的事项':this.category==='waiting'?'当前没有等待对方的跟进':this.category==='scheduled'?'当前没有已确认并安排的提醒':this.category==='ended'?'当前同步范围没有已结束事项':'当前没有保存的线索').fontSize(15).padding({top:18,bottom:6})
        if(this.category==='self'){Button('查看线索与待判断').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.category='clues';this.limit=15;})}
      }
      if(this.tasks().length>this.limit){Button('加载更多事项').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.limit+=15;})}
      if(this.viewModel.snapshot.sync.pendingOperations>0){Text(`${this.viewModel.snapshot.sync.pendingOperations} 项修改已保存在手机，等待同步`).fontSize(12).fontColor($r('app.color.brand_warning'))}
      if(this.viewModel.error.length>0){Text('部分操作未完成，请打开详情核对或从同步管理重试').fontSize(13).fontColor($r('app.color.brand_warning'))}
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start)}.width('100%').height('100%').align(Alignment.TopStart).contentEndOffset(PHONE_V3_FLOATING_TAB_BAR_CONTENT_END_OFFSET).backgroundColor($r('app.color.page_background'))
      .bindSheet($$this.showDetail,this.detail(),{height:SheetSize.LARGE,showClose:false})
  }
}
