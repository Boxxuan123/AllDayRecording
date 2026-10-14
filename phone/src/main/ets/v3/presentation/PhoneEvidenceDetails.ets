import { PhoneProductEvidence, recallProductEvidence, productEvidenceQuery } from './PhoneProductEvidence';
import { RecallResponse, recallRequestId } from '../domain/PhoneHistoryRecall';
import { PhoneV3SessionCard, PhoneV3Utterance } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';

@Component
export struct PhoneEvidenceDetails {
  @ObjectLink viewModel: PhoneV3ViewModel;
  @Prop evidence: Array<PhoneProductEvidence> = [];
  @Prop queryId: string = '';
  @State private rows: Array<PhoneProductEvidence> = [];
  @State private loading: boolean = false;
  @State private notice: string = '';
  @State private error: string = '';
  @State private technical: boolean = false;
  @State private stale: boolean = false;
  @State private limit:number=15;
  @State private playId:string='';
  @State private playbackLoading:boolean=false;
  private generation: number = 0;
  private playGeneration: number = -1;
  private ownedQuery:string='';
  onContext: (context: RecallResponse) => void = (): void => {};
  onClose: () => void = (): void => {};
  onOpenSession: (session: PhoneV3SessionCard) => void = (): void => {};
  aboutToAppear(): void { this.rows=this.evidence; this.load(); }
  aboutToDisappear(): void { this.generation++;if(this.ownedQuery.length>0){this.viewModel.historyRecall({action:'cancel',query_id:this.ownedQuery}).catch(():void=>{});} if(this.playGeneration>=0){this.viewModel.stopPlayback(this.playGeneration);} }
  private async loadSaved(generation:number):Promise<void>{
    let unavailable=false;let offline=false;const evidence=this.evidence;
    for(const e of evidence){
      if(e.recording===undefined){continue;}
      try{const original=await this.viewModel.verifyEvidenceUtterance(e.recording);if(generation!==this.generation){return;}if(original!==undefined&&(original.revision!==e.recording.revision||original.status!=='active')){unavailable=true;}}
      catch(_){offline=true;}
    }
    if(generation===this.generation){this.stale=unavailable;this.notice=unavailable?'原文已更新或失效；旧引用仅供核对，不能继续播放':offline?'原文状态暂无法核对，以下为已保存的引用':'同步时保存的原文；完整来源当前可用性尚未核对';}
  }
  private async sourceContext(e:PhoneProductEvidence,generation:number):Promise<RecallResponse>{
    let queryId=this.queryId;
    let evidenceId=e.id;
    let changed=false;
    if(queryId.length===0){
      if(this.ownedQuery.length>0){this.viewModel.historyRecall({action:'cancel',query_id:this.ownedQuery}).catch(():void=>{});}
      queryId=recallRequestId();this.ownedQuery=queryId;
      const request=productEvidenceQuery(e,queryId);
      if(request===undefined){throw new Error('original_unavailable');}
      const found=await this.viewModel.historyRecall(request);
      if(generation!==this.generation){throw new Error('closed');}
      const exact=found.evidence?.find((row):boolean=>row.id==='chat:'+e.recordId);
      if(exact===undefined){throw new Error('original_not_found');}
      evidenceId=exact.id;changed=exact.revision!==e.recordRevision;
    }
    const context=await this.viewModel.historyRecall({action:'context',query_id:queryId,evidence_id:evidenceId});
    if(changed){context.status='stale';}
    return context;
  }
  private async load(target:PhoneProductEvidence|undefined=undefined):Promise<void>{
    const generation=++this.generation;
    const selected=target??this.evidence[0];
    if(selected===undefined){return;}
    if(this.queryId.length===0&&productEvidenceQuery(selected,'probe')===undefined){await this.loadSaved(generation);return;}
    this.loading=true;
    let notice='原消息与前后文';let error='';let stale=false;let rows=this.evidence;
    try{
      const context=await this.sourceContext(selected,generation);
      if(generation!==this.generation){return;}
      this.onContext(context);stale=context.status==='stale';
      notice=stale?'来源已失效或修订；保存的归纳需重新核对':context.status==='unavailable'?'来源离线，以下为已保存原文；无法确认最新上下文':'原消息与前后文';
      const incoming=context.evidence?.map(recallProductEvidence)??[];
      const original=incoming.find((e:PhoneProductEvidence):boolean=>e.id===selected.id);
      if(incoming.length>0){rows=original===undefined?incoming:[original].concat(incoming.filter((e:PhoneProductEvidence):boolean=>e.id!==original.id));}
    }catch(_){error='来源暂不可用，已保存原话仍可浏览。';notice='未能取得完整上下文';}
    if(generation===this.generation){this.rows=rows;this.error=error;this.notice=notice;this.stale=stale;this.loading=false;}
  }
  private playing(e:PhoneProductEvidence):boolean{return this.playId===e.id&&this.playGeneration===this.viewModel.playbackGeneration()&&this.viewModel.annotationPlaybackState()==='正在播放';}
  private async play(e:PhoneProductEvidence):Promise<void>{
    const recording=e.recording;if(recording===undefined||this.stale||e.unavailable||this.playbackLoading){return;}
    const generation=this.generation;this.playbackLoading=true;
    try{
      const original=await this.viewModel.verifyEvidenceUtterance(recording);
      if(generation!==this.generation){return;}
      if(original===undefined||original.status!=='active'||original.revision!==recording.revision||original.sessionId!==recording.session_id){this.error='来源转写尚未同步或已经变化，请同步后再播放';return;}
      this.viewModel.playUtterance(original);this.playGeneration=this.viewModel.playbackGeneration();this.playId=e.id;
    }catch(_){if(generation===this.generation){this.error='录音暂未准备好，已保存原文仍可浏览';}}
    finally{if(generation===this.generation){this.playbackLoading=false;}}
  }
  private open(e:PhoneProductEvidence):void {
    const session=this.viewModel.snapshot.sessions.find((s:PhoneV3SessionCard):boolean=>s.sessionId===e.recording?.session_id);
    if(session!==undefined){this.onOpenSession(session);}else{this.error='手机尚未缓存此会话，请先同步；已保存引用仍可浏览。';}
  }
  @Builder private row(e:PhoneProductEvidence) {
    Column({space:8}) {
      Text(`${e.kindLabel} · ${e.source} · ${e.time}`).fontSize(12).fontColor($r('app.color.text_secondary'))
      Text(e.speaker||'发言人未知').fontSize(15).fontWeight(FontWeight.Medium)
      Text(e.identity).fontSize(12).fontColor($r('app.color.text_secondary'))
      Text(e.quote).fontSize(17).lineHeight(26).copyOption(CopyOptions.InApp)
      Text(e.meaning).fontSize(12).fontColor($r('app.color.text_secondary'))
      if(e.unavailable){Text('这条来源已失效').fontSize(13).fontColor($r('app.color.brand_warning'))}
      if(e.truncated){Text('当前片段被截断，完整原文未取回').fontSize(12)}
      ForEach(e.context,(line:string)=>{Text(`回复或引用的原文：${line}`).fontSize(14)},(line:string):string=>line)
      if(e.kindLabel==='已保存引用'&&productEvidenceQuery(e,'probe')!==undefined){Button('核对这条原消息与前后文').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.loading).onClick(():void=>{this.load(e);})}
      if(e.recording!==undefined){
        Row({space:8}) {
          Button(this.playing(e)?'停止片段':this.playbackLoading?'正在准备':'播放片段').height(44)
            .enabled(!this.loading&&!this.playbackLoading&&!this.stale&&!e.unavailable)
            .onClick(():void=>{if(this.playing(e)){this.viewModel.stopPlayback(this.playGeneration);}else{this.play(e);}})
          Text(`${Math.floor(e.recording.start_ms/1000)}–${Math.ceil(e.recording.end_ms/1000)} 秒`).fontSize(12)
        }
        if(this.viewModel.annotationPlaybackState().length>0){Text(this.viewModel.annotationPlaybackState()).fontSize(12)}
        Button('打开完整录音与转写').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.stale&&!e.unavailable).onClick(():void=>this.open(e))
      }
      if(this.technical){Text(e.technical).fontSize(11).copyOption(CopyOptions.InApp)}
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor($r('app.color.surface_primary')).borderRadius(14)
  }
  build(){
    Scroll(){Column({space:14}){
      Row(){Text('原文依据').fontSize(22).fontWeight(FontWeight.Bold);Blank();Button('返回').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(this.onClose)}.width('100%')
      Text(this.notice).fontSize(13).fontColor($r('app.color.text_secondary'))
      if(this.loading){LoadingProgress().width(24).height(24)}
      if(this.error.length>0){Text(this.error).fontSize(13).fontColor($r('app.color.brand_warning'));Button('重新读取来源').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.load();})}
      ForEach(this.rows.slice(0,this.limit),(e:PhoneProductEvidence)=>{this.row(e)},(e:PhoneProductEvidence):string=>e.id)
      if(this.rows.length>this.limit){Button('展开更多上下文').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.limit+=15;})}
      if(this.rows.length===0&&!this.loading){Text('手机没有保存这条原文。请同步后再查看。').fontSize(14)}
      if(this.viewModel.error.length>0){Text('播放或读取尚未完成，现有原文仍保留；可检查同步后重试').fontSize(13).fontColor($r('app.color.brand_warning'))}
      if(this.technical&&this.viewModel.error.length>0){Text(this.viewModel.error).fontSize(11)}
      Button(this.technical?'收起技术详情':'技术详情').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(():void=>{this.technical=!this.technical;})
    }.width('100%').padding(18).alignItems(HorizontalAlign.Start)}.width('100%').height('100%').align(Alignment.TopStart).backgroundColor($r('app.color.page_background'))
  }
}
