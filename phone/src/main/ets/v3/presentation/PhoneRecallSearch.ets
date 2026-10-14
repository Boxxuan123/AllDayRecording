import { i18n } from '@kit.LocalizationKit';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { PhoneV3SessionCard } from '../domain/PhoneV3Models';
import { RecallRequest, RecallResponse, RecallClaim, RecallEvidence, RecallPerson, recallDate, recallRequestId, applyRecallContext, applyRecallPage } from '../domain/PhoneHistoryRecall';
import { PhoneProductEvidence, recallProductEvidence } from './PhoneProductEvidence';
import { productRecallAnswer, productRecallCoverage, productRecallScope } from './PhoneProductRecall';
import { PhoneEvidenceDetails } from './PhoneEvidenceDetails';

@Component
export struct PhoneRecallSearch {
  @ObjectLink viewModel: PhoneV3ViewModel;
  onOpenSession:(session:PhoneV3SessionCard)=>void=():void=>{};
  onOpenPeople:()=>void=():void=>{};
  @State private question:string='';
  @State private submitted:string='';
  @State private editing:boolean=true;
  @State private source:string='all';
  @State private first:string='';
  @State private last:string='';
  @State private keyword:string='';
  @State private person:string='';
  @State private filters:boolean=false;
  @State private summarize:boolean=true;
  @State private expand:boolean=true;
  @State private people:Array<RecallPerson>=[];
  @State private catalogError:string='';
  @State private result:RecallResponse={};
  @State private busy:boolean=false;
  @State private error:string='';
  @State private technical:boolean=false;
  @State private showEvidence:boolean=false;
  @State private selected:Array<PhoneProductEvidence>=[];
  private queryId:string='';
  private generation:number=0;
  private catalogGeneration:number=0;
  private scroller:Scroller=new Scroller();
  aboutToDisappear():void { this.catalogGeneration++; if(this.busy){this.cancel();} }
  private cancel():void {
    this.generation++; this.busy=false;
    if(this.queryId.length>0){this.viewModel.historyRecall({action:'cancel',query_id:this.queryId}).catch(():void=>{});}
  }
  private async loadPeople():Promise<void> {
    const generation=++this.catalogGeneration; this.catalogError='';
    try{const response=await this.viewModel.historyRecall({action:'catalog'});if(generation===this.catalogGeneration){this.people=response.people??[];}}
    catch(_){if(generation===this.catalogGeneration){this.catalogError='人物筛选暂不可用；涉及具体人物的查询仍需确认身份';}}
  }
  private async search():Promise<void> {
    if(this.question.trim().length===0||this.busy){return;}
    this.cancel();const generation=this.generation;this.queryId=recallRequestId();
    this.submitted=this.question.trim();this.busy=true;this.error='';this.result={};this.showEvidence=false;this.editing=false;
    try {
      const request:RecallRequest={action:'query',query_id:this.queryId,question:this.submitted,keyword:this.keyword,person_id:this.person,source:this.source,timezone:i18n.getTimeZone().getID(),sent_from:recallDate(this.first,false),sent_to:recallDate(this.last,true),summarize:this.summarize,expand:this.expand};
      const response=await this.viewModel.historyRecall(request);
      if(generation===this.generation){this.result=response;this.scroller.scrollTo({xOffset:0,yOffset:0});}
    }catch(error){if(generation===this.generation){const message=error instanceof Error?error.message:'';this.error=message.includes('YYYY-MM-DD')||/日期|时区|时刻|时间描述|时间段|人物|范围|来源.*冲突|起止/.test(message)?message:'搜索暂未完成，检查电脑连接后可重试。';}}
    finally{if(generation===this.generation){this.busy=false;}}
  }
  private async page(number:number):Promise<void> {
    const generation=this.generation;this.busy=true;this.error='';
    try{const response=await this.viewModel.historyRecall({action:'page',query_id:this.queryId,page:number});if(generation===this.generation){this.result=applyRecallPage(this.result,response);this.scroller.scrollTo({xOffset:0,yOffset:0});}}
    catch(_){if(generation===this.generation){this.error='更多原文暂未取回，当前结果已保留；可重试或重新搜索。';}}
    finally{if(generation===this.generation){this.busy=false;}}
  }
  private original(id:string):void {
    const row=this.result.evidence?.find((e:RecallEvidence):boolean=>e.id===id);
    if(row!==undefined){this.selected=[recallProductEvidence(row)];}
    else {const value=new PhoneProductEvidence();value.id=id;this.selected=[value];}
    this.showEvidence=true;
  }
  @Builder private evidenceSheet() {
    PhoneEvidenceDetails({viewModel:this.viewModel,evidence:this.selected,queryId:this.queryId,
      onContext:(context:RecallResponse):void=>{this.result=applyRecallContext(this.result,context);},
      onClose:():void=>{this.showEvidence=false;},onOpenSession:(session:PhoneV3SessionCard):void=>{this.showEvidence=false;this.onOpenSession(session);}})
  }
  private peopleOptions():Array<SelectOption>{const options:Array<SelectOption>=[{value:'全部人物'}];for(const p of this.people){options.push({value:p.display_name});}return options;}
  @Builder private searchEditor() {
    Column({space:10}) {
      Row({space:8}) {
        TextInput({text:this.question,placeholder:'搜索你想找回的事情或原话'}).layoutWeight(1).height(48).enterKeyType(EnterKeyType.Search)
          .onChange((value:string):void=>{this.question=value;this.error='';}).onSubmit(():void=>{this.search();})
        Button('搜索').height(48).enabled(this.question.trim().length>0&&!this.busy).onClick(():void=>{this.search();})
      }.width('100%')
      Row(){Button(this.filters?'收起筛选':'筛选').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.filters=!this.filters;if(this.filters&&this.people.length===0){this.loadPeople();}});Blank();Text('默认最近 30 天').fontSize(12).fontColor($r('app.color.text_secondary'))}.width('100%')
      if(this.filters){
        Select([{value:'全部来源'},{value:'QQ'},{value:'微信'},{value:'录音'}]).selected(['all','qq','wechat','recording'].indexOf(this.source)).value(['全部来源','QQ','微信','录音'][['all','qq','wechat','recording'].indexOf(this.source)]).onSelect((i:number):void=>{this.source=['all','qq','wechat','recording'][i];})
        Select(this.peopleOptions()).selected(this.people.findIndex((p:RecallPerson):boolean=>p.person_id===this.person)+1).value(this.people.find((p:RecallPerson):boolean=>p.person_id===this.person)?.display_name??'全部人物').onSelect((i:number):void=>{this.person=i===0?'':this.people[i-1].person_id;})
        if(this.catalogError.length>0){Text(this.catalogError).fontSize(12)}
        Row({space:8}){TextInput({text:this.first,placeholder:'起日 YYYY-MM-DD'}).layoutWeight(1).onChange((v:string):void=>{this.first=v;});TextInput({text:this.last,placeholder:'止日 YYYY-MM-DD'}).layoutWeight(1).onChange((v:string):void=>{this.last=v;})}
        TextInput({text:this.keyword,placeholder:'精确关键词（可选）'}).onChange((v:string):void=>{this.keyword=v;})
        Row(){Text('生成有依据的归纳').layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:this.summarize}).onChange((v:boolean):void=>{this.summarize=v;})}.height(44)
        Row(){Text('按需核对后续原文').layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:this.expand}).onChange((v:boolean):void=>{this.expand=v;})}.height(44)
        Text('日期按手机当前时区，单次最多一年。归纳由电脑按配置处理必要资料，可能联网；关闭后仍可检索原文。').fontSize(12).fontColor($r('app.color.text_secondary'))
        Button('人物与来源管理').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(this.onOpenPeople)
      }
      if(this.submitted.length===0){Text('搜索 QQ、微信与已同步录音。').fontSize(14).fontColor($r('app.color.text_secondary'))}
      if(this.submitted.length>0){Button('返回当前结果').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.editing=false;})}
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder private answer() {
    Column({space:10}) {
      if(productRecallScope(this.result).length>0){Text(productRecallScope(this.result)).fontSize(12).fontColor($r('app.color.text_secondary')).copyOption(CopyOptions.InApp)}
      Text(productRecallAnswer(this.result)).fontSize(18).lineHeight(27).copyOption(CopyOptions.InApp)

      if(this.result.status==='needs_clarification'&&(this.result.person_candidates?.length??0)>1){
        Select((this.result.person_candidates??[]).map((p:RecallPerson):SelectOption=>({value:`${p.display_name} (${p.person_id})`}))).value('选择具体人物').onSelect((i:number):void=>{this.person=this.result.person_candidates?.[i]?.person_id??'';this.search();})
      }
      if(productRecallCoverage(this.result).length>0){Text(productRecallCoverage(this.result)).fontSize(13).fontColor($r('app.color.brand_warning'))}
      ForEach(this.result.unknown??[],(text:string)=>{Text(`尚不确定：${text}`).fontSize(13)},(text:string):string=>text)
      ForEach(this.result.claims??[],(claim:RecallClaim)=>{
        Column({space:4}) {
          Text(claim.kind==='quote'?'原话引用':claim.kind==='inference'?'推测':'模型归纳').fontSize(12).fontColor($r('app.color.text_secondary'))
          Text(claim.text).fontSize(15)
          ForEach(claim.citations,(id:string,index:number)=>{Button(`查看依据 ${index+1}`).height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.original(id);})},(id:string):string=>id)
        }.width('100%').alignItems(HorizontalAlign.Start)
      },(claim:RecallClaim):string=>claim.kind+claim.text)
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start).backgroundColor($r('app.color.surface_primary')).borderRadius(14)
  }
  build(){
    Scroll(this.scroller){Column({space:14}){
      if(this.editing){this.searchEditor()}else{
        Row({space:8}){Text(this.submitted).fontSize(16).fontWeight(FontWeight.Medium).maxLines(2).layoutWeight(1);Button('修改问题').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.editing=true;})}.width('100%')
        if(this.busy){Row({space:8}){LoadingProgress().width(24).height(24);Text('正在查找原文…');Blank();Button('取消').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.cancel();this.error='本次查询已取消，可修改问题后重试。';})}.width('100%')}
        if(this.result.query_id!==undefined||this.result.answer!==undefined||this.result.evidence!==undefined){
          this.answer()

          if((this.result.evidence?.length??0)>0){Text('原文依据').fontSize(17).fontWeight(FontWeight.Medium)}
          ForEach(this.result.evidence??[],(e:RecallEvidence)=>{
            Button({type:ButtonType.ROUNDED_RECTANGLE}){Column({space:6}){Text(`${e.speaker} · ${e.source==='qq'?'QQ':e.source==='wechat'?'微信':'录音'}`).fontSize(12).fontColor($r('app.color.text_secondary'));Text(e.quote).fontSize(15).maxLines(3).textOverflow({overflow:TextOverflow.Ellipsis});Text('查看原文与上下文 ›').fontSize(12).fontColor($r('app.color.brand_primary'))}.width('100%').alignItems(HorizontalAlign.Start)}.width('100%').padding(14).backgroundColor($r('app.color.surface_primary')).fontColor($r('app.color.text_primary')).onClick(():void=>{this.original(e.id);})
          },(e:RecallEvidence):string=>e.id)
          if(this.result.has_more===true||(this.result.page??0)>0){Row(){Button('上一页').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.busy&&(this.result.page??0)>0).onClick(():void=>{this.page((this.result.page??0)-1);});Blank();Text(`第 ${(this.result.page??0)+1} 页`).fontSize(12);Blank();Button('下一页').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.busy&&this.result.has_more===true).onClick(():void=>{this.page((this.result.page??0)+1);})}.width('100%')}
          Button(this.technical?'收起技术详情':'技术详情').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.technical=!this.technical;})
          if(this.technical){Text(JSON.stringify(this.result.metrics)).fontSize(11);Text(this.result.answer??'').fontSize(11);ForEach(this.result.coverage??[],(line:string)=>{Text(line).fontSize(11)},(line:string):string=>line);Text(`${this.result.status??''} · ${this.result.model_status??''}`).fontSize(11)}
        }
      }
      if(this.error.length>0){Text(this.error).fontSize(14).fontColor($r('app.color.brand_warning'));Button('重试搜索').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.busy).onClick(():void=>{this.search();})}
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16)}.width('100%').height('100%').align(Alignment.TopStart).contentEndOffset(76).backgroundColor($r('app.color.page_background'))
      .bindSheet($$this.showEvidence,this.evidenceSheet(),{height:SheetSize.LARGE,showClose:false})
  }
}
