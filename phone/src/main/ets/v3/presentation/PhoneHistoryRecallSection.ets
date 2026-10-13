import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { RecallRequest, RecallResponse, RecallPerson, RecallIdentity, RecallEvidence, RecallClaim, RecallCommand, RecallDecision, recallRequestId, recallDate, applyRecallContext, applyRecallPage } from '../domain/PhoneHistoryRecall';
import { PhoneV3SessionCard } from '../domain/PhoneV3Models';

@Component
export struct PhoneHistoryRecallSection {
  @ObjectLink viewModel:PhoneV3ViewModel;
  onOpenSession:(session:PhoneV3SessionCard)=>void=():void=>{};
  @State private question:string='';
  @State private keyword:string='';
  @State private first:string='';
  @State private last:string='';
  @State private source:string='all';
  @State private person:string='';
  @State private catalog:RecallResponse={};
  @State private result:RecallResponse={};
  @State private context:RecallResponse={};
  @State private busy:boolean=false;
  @State private catalogBusy:boolean=false;
  @State private error:string='';
  @State private showIdentities:boolean=false;
  @State private basis:string='';
  @State private summarize:boolean=true;
  @State private expand:boolean=true;
  @State private pending:RecallCommand|undefined=undefined;
  private queryId:string='';
  private revision:number=0;
  private contextRevision:number=0;
  aboutToAppear():void { this.result={};this.context={}; }
  aboutToDisappear():void { this.cancel(); }
  private message(error:Object):string {return error instanceof Error?error.message:String(error);}
  private time(stamp:number):string {return new Date(stamp*1000+8*3600000).toISOString().slice(0,19).replace('T',' ');}
  private cancel():void {
    this.revision++;this.contextRevision++;this.busy=false;this.result={};this.context={};
    const old=this.queryId;this.queryId='';
    if(old.length>0){this.viewModel.historyRecall({action:'cancel',query_id:old}).catch(():void=>{});}
  }
  private async loadCatalog(offset:number=0):Promise<void> {
    this.catalogBusy=true;this.error='';
    try {this.catalog=await this.viewModel.historyRecall({action:'catalog',offset:offset});}
    catch(error){this.error=this.message(error);}
    finally{this.catalogBusy=false;}
  }
  private async search():Promise<void> {
    this.cancel();const version=this.revision;const qid=recallRequestId();this.queryId=qid;
    this.busy=true;this.error='';this.result={};this.context={};
    try {
      const request:RecallRequest={action:'query',query_id:qid,question:this.question,keyword:this.keyword,person_id:this.person,source:this.source,sent_from:recallDate(this.first,false),sent_to:recallDate(this.last,true),summarize:this.summarize,expand:this.expand};
      const result=await this.viewModel.historyRecall(request);
      if(version===this.revision){this.result=result;}
    } catch(error){if(version===this.revision){this.error=this.message(error);}}
    finally{if(version===this.revision){this.busy=false;}}
  }
  private async page(number:number):Promise<void> {
    const version=this.revision;this.busy=true;this.error='';
    try{const result=await this.viewModel.historyRecall({action:'page',query_id:this.queryId,page:number});if(version===this.revision){this.result=applyRecallPage(this.result,result);}}
    catch(error){if(version===this.revision){this.result={};this.error=this.message(error);}}
    finally{if(version===this.revision){this.busy=false;}}
  }
  private async original(id:string):Promise<void> {
    const version=++this.contextRevision;this.error='';this.context={};
    try{const result=await this.viewModel.historyRecall({action:'context',query_id:this.queryId,evidence_id:id});if(version===this.contextRevision){this.context=result;this.result=applyRecallContext(this.result,result);}}
    catch(error){if(version===this.contextRevision){this.result={};this.error=this.message(error);}}
  }
  private async decide(identity:RecallIdentity,action:string):Promise<void> {
    if(this.person.length===0||this.basis.trim().length===0){this.error='请先选择人物并填写依据';return;}
    this.pending={operation_id:recallRequestId(),key:identity.key,person_id:this.person,action:action,basis:this.basis,version:this.catalog.version??''};
    await this.sendDecision();
  }
  private async sendDecision():Promise<void> {
    const decision=this.pending;if(decision===undefined){return;}
    this.catalogBusy=true;this.error='';
    try {
      await this.viewModel.historyRecall({action:'identity',decision:decision});
      this.pending=undefined;this.cancel();this.result={};this.context={};
      await this.loadCatalog();
    }catch(error){this.error=this.message(error);}
    finally{this.catalogBusy=false;}
  }
  private play(e:RecallEvidence):void {
    if(e.session_id===undefined||e.utterance_id===undefined||e.start_ms===undefined||e.end_ms===undefined){return;}
    this.viewModel.playDailyEvidence({session_id:e.session_id,utterance_id:e.utterance_id,revision:e.revision,start_ms:e.start_ms,end_ms:e.end_ms,start_at:e.start_at??'',end_at:e.end_at??'',text:e.quote,participant:{key:e.person_id||'unknown',kind:e.person_id.length>0?'known':'unknown',label:e.speaker,status:e.person_id.length>0?'confirmed':'unresolved'}});
  }
  private open(e:RecallEvidence):void {const session=this.viewModel.snapshot.sessions.find((s:PhoneV3SessionCard):boolean=>s.sessionId===e.session_id);if(session!==undefined){this.onOpenSession(session);}else{this.error='手机尚未缓存此录音会话；可先同步或直接播放引用片段';}}
  @Builder private evidence(e:RecallEvidence) {
    Column({space:6}) {
      Text(`${e.speaker} · ${e.source} · ${this.time(e.sent_at)} +08:00`).fontSize(13)
      if(e.validity==='stale'){Text('原文已失效，仅供核对历史').fontSize(13).fontColor($r('app.color.brand_warning'))}
      Text(e.quote).fontSize(15).copyOption(CopyOptions.InApp)
      Text(`${e.role==='context'?'邻近上下文':'查询命中'} · ${e.identity_basis} · ${e.assertion}`).fontSize(12)
      if(e.source_account_id!==undefined){Text(`采集账号 ${e.source_account_id} · 发送账号 ${e.sender_account_id??'未知'} · 会话 ${e.conversation_id??''}`).fontSize(11)}
      if(e.quote_truncated){Text('片段已截断，请打开来源核对。').fontSize(12)}
      Button('打开依据／核对来源').onClick(():void=>{this.original(e.id);})
      if(e.source==='recording'){
        Button('播放引用片段').enabled(e.validity!=='stale').onClick(():void=>this.play(e))
        Button('打开原转写／纠正说话人').enabled(e.validity!=='stale').onClick(():void=>this.open(e))
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(10).backgroundColor($r('app.color.surface_secondary')).borderRadius(10)
  }
  build() {
    Column({space:10}) {
      Text('历史检索与回忆').fontSize(20).fontWeight(FontWeight.Bold)
      TextInput({text:this.question,placeholder:'输入问题：查原话、问原因、回顾经过或最终状态'}).onChange((v:string):void=>{this.question=v;})
      TextInput({text:this.keyword,placeholder:'可选精确关键词／主题（每次一个）'}).onChange((v:string):void=>{this.keyword=v;})
      Row({space:6}) {
        TextInput({text:this.first,placeholder:'起日 YYYY-MM-DD'}).layoutWeight(1).onChange((v:string):void=>{this.first=v;})
        TextInput({text:this.last,placeholder:'止日 YYYY-MM-DD'}).layoutWeight(1).onChange((v:string):void=>{this.last=v;})
      }
      Text('默认最近 30 天；日期按 Asia/Singapore；单次最多 366 天。').fontSize(12)
      Select([{value:'全部来源'},{value:'QQ'},{value:'微信'},{value:'录音'}]).selected(['all','qq','wechat','recording'].indexOf(this.source)).onSelect((i:number):void=>{this.source=['all','qq','wechat','recording'][i];})
      Button(this.catalogBusy?'读取人物中…':'选择人物／查看来源身份').enabled(!this.catalogBusy).onClick(():void=>{this.showIdentities=!this.showIdentities;this.loadCatalog();})
      if((this.catalog.people?.length??0)>0){
        Button('全部人物').onClick(():void=>{this.person='';})
        Select(this.catalog.people?.map((p:RecallPerson):SelectOption=>({value:p.display_name}))??[]).value(this.catalog.people?.find((p:RecallPerson):boolean=>p.person_id===this.person)?.display_name??'选择已有人物').onSelect((i:number):void=>{this.person=this.catalog.people?.[i]?.person_id??'';})
      }
      if(this.showIdentities){
        Text(this.catalog.recording_notice??'').fontSize(12)
        TextInput({text:this.basis,placeholder:'关联／解除／拒绝依据（由你确认）'}).onChange((v:string):void=>{this.basis=v;})
        if(this.pending!==undefined){
          Button('重试上次关联操作').enabled(!this.catalogBusy).onClick(():void=>{this.sendDecision();})
          Button('停止重试并刷新当前关联').enabled(!this.catalogBusy).onClick(():void=>{this.pending=undefined;this.loadCatalog();})
        }
        ForEach(this.catalog.items??[],(identity:RecallIdentity)=>{
          Column({space:4}){
            Text(`${identity.label} · ${identity.platform} · ${identity.account}`).fontSize(14)
            Text(`账号命名空间 ${identity.source} · ${identity.basis}`).fontSize(12)
            Text(`关联人物：${this.catalog.people?.find((p:RecallPerson):boolean=>p.person_id===identity.person_id)?.display_name??'未关联'}`).fontSize(12)
            ForEach(identity.decisions,(d:RecallDecision)=>{Text(`${d.action} · ${d.basis}`).fontSize(12)},(d:RecallDecision):string=>d.person_id)
            if(identity.editable){
              Button('关联／纠正到所选人物').enabled(!this.catalogBusy&&this.person.length>0&&this.pending===undefined).onClick(():void=>{this.decide(identity,'link');})
              Button('不是所选人物').enabled(!this.catalogBusy&&this.person.length>0&&this.pending===undefined).onClick(():void=>{this.decide(identity,'reject');})
              if(identity.person_id===this.person&&this.person.length>0){Button('解除此关联').enabled(!this.catalogBusy&&this.pending===undefined).onClick(():void=>{this.decide(identity,'unlink');})}
            }
          }.width('100%').alignItems(HorizontalAlign.Start).padding(8)
        },(identity:RecallIdentity):string=>identity.key)
        if(this.catalog.next_offset!==undefined&&this.catalog.next_offset!==null){Button('下一页来源身份').enabled(!this.catalogBusy).onClick(():void=>{this.loadCatalog(this.catalog.next_offset??0);})}
      }
      Row(){Toggle({type:ToggleType.Switch,isOn:this.expand}).onChange((v:boolean):void=>{this.expand=v;});Text('按需核对来源与后续').fontSize(13)}
      Row(){Toggle({type:ToggleType.Switch,isOn:this.summarize}).onChange((v:boolean):void=>{this.summarize=v;});Text('生成有依据的简短归纳').fontSize(13)}
      Button(this.busy?'取消上一轮并开始新查询':'查询').enabled(this.question.trim().length>0).onClick(():void=>{this.search();})
      if(this.busy){Button('取消查询').onClick(():void=>{this.cancel();this.result={};this.context={};})}
      if(this.error.length>0){Text(this.error).fontSize(14).fontColor($r('app.color.brand_warning'))}
      if(this.result.answer!==undefined){
        Text(this.result.answer).fontSize(16)
        Text(`状态：${this.result.status??''} · 归纳：${this.result.model_status??''}`).fontSize(12)
        if(this.result.scope!==undefined){Text(`范围：${this.time(this.result.scope.sent_from)} 至 ${this.time(this.result.scope.sent_to)} · ${this.result.scope.source} · 关键词 ${(this.result.terms??[]).join('、')}`).fontSize(12)}
        ForEach(this.result.coverage??[],(v:string)=>{Text(v).fontSize(12)},(v:string):string=>v)
        if(this.result.latest_status_confirmed===false){Text('当前证据覆盖不完整，不能认定最终状态。').fontSize(12)}
        ForEach(this.result.claims??[],(c:RecallClaim)=>{
          Text(`${c.kind==='quote'?'原文引用':c.kind==='inference'?'推测':'模型归纳（待核对）'}：${c.text}`).fontSize(15)
          ForEach(c.citations,(id:string)=>{Button('核对这条依据').onClick(():void=>{this.original(id);})},(id:string):string=>id)
        },(c:RecallClaim):string=>c.kind+c.text)
        ForEach(this.result.unknown??[],(v:string)=>{Text(`尚不确定：${v}`).fontSize(13)},(v:string):string=>v)
        Text(`命中 ${this.result.metrics?.hits??0} · 取回 ${this.result.metrics?.retrieved??0} · 模型调用 ${this.result.metrics?.model_calls??0} · ${this.result.metrics?.elapsed_ms??0} ms`).fontSize(12)
        ForEach(this.result.evidence??[],(e:RecallEvidence)=>{this.evidence(e)},(e:RecallEvidence):string=>e.id)
        Row({space:8}){
          Button('前页').layoutWeight(1).enabled(!this.busy&&(this.result.page??0)>0).onClick(():void=>{this.page((this.result.page??0)-1);})
          Text(`第 ${(this.result.page??0)+1} 页`).fontSize(12)
          Button('后页').layoutWeight(1).enabled(!this.busy&&this.result.has_more===true).onClick(():void=>{this.page((this.result.page??0)+1);})
        }
      }
      if(this.context.notice!==undefined){
        Text(this.context.notice).fontSize(14)
        ForEach(this.context.evidence??[],(e:RecallEvidence)=>{Text(`${e.speaker} · ${e.source} · ${this.time(e.sent_at)}：${e.quote}`).fontSize(14)},(e:RecallEvidence):string=>e.id)
        Button('收起依据').onClick(():void=>{this.contextRevision++;this.context={};})
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
  }
}
