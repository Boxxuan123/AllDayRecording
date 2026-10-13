import { MemoryIndex,MemoryContact,MemoryDiscussion,MemoryEvidence,MemoryThing,MemoryTopic,MemoryCandidate } from '../domain/PhoneCrossDayMemory';
import { PhoneV3SessionCard } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { PhoneV3ChatFollowupsSection } from './PhoneV3ChatFollowupsSection';
import { PhoneV3RemindersPage } from './PhoneV3RemindersPage';

@Component
export struct PhoneCrossDayMemorySection {
  @ObjectLink viewModel:PhoneV3ViewModel;
  @State private page:number=0;
  @State private evidencePage:number=0;
  @State private person:string='';
  @State private thing:string='';
  @State private topic:string='';
  @State private expanded:string='';
  @State private source:string='';
  @State private task:string='';
  @State private showTask:boolean=false;
  onOpenSession:(session:PhoneV3SessionCard)=>void=():void=>{};
  private time(value:string|undefined):string {
    if(typeof value!=='string'||value.length===0){return '证据已失效';}
    const d=new Date(new Date(value).getTime()+8*60*60*1000);
    return `${d.getUTCFullYear()}-${String(d.getUTCMonth()+1).padStart(2,'0')}-${String(d.getUTCDate()).padStart(2,'0')} ${String(d.getUTCHours()).padStart(2,'0')}:${String(d.getUTCMinutes()).padStart(2,'0')}:${String(d.getUTCSeconds()).padStart(2,'0')}`;
  }
  private index():MemoryIndex|undefined {return this.viewModel.snapshot.memoryPages.find((item:MemoryIndex):boolean=>item.page?.kind==='discussions'&&item.page.number===this.page)??this.viewModel.snapshot.memoryIndex;}
  private evidence(r:MemoryDiscussion):Array<MemoryEvidence> {
    if(this.evidencePage===0){return r.evidence;}
    return this.viewModel.snapshot.memoryPages.find((item:MemoryIndex):boolean=>item.page?.kind==='evidence'&&item.page.discussion_id===r.id&&item.discussions[0]?.evidence_page===this.evidencePage)?.discussions[0]?.evidence??[];
  }
  private rows():Array<MemoryDiscussion> {
    const index=this.index();
    return index?.discussions.filter((r:MemoryDiscussion):boolean=>(this.person.length===0||r.contacts.some((p:MemoryContact):boolean=>p.id===this.person))&&(this.thing.length===0||r.thing_id===this.thing)&&(this.topic.length===0||index.topics.some((t:MemoryTopic):boolean=>t.label===this.topic&&t.discussion_ids.includes(r.id)))).sort((a:MemoryDiscussion,b:MemoryDiscussion):number=>a.occurred_at.localeCompare(b.occurred_at))??[];
  }
  private canOperate():boolean {return !this.viewModel.busy&&!this.viewModel.snapshot.memoryPending;}
  private decide(source:string,target:string,action:string):void {const index=this.index();if(index!==undefined){this.viewModel.memoryCommand(source,target,action,index.revision);}this.source='';}
  private sibling(r:MemoryDiscussion):string {return this.index()?.discussions.find((v:MemoryDiscussion):boolean=>v.id!==r.id&&v.thing_id===r.thing_id)?.id??'';}
  private open(e:MemoryEvidence):void {const s=this.viewModel.snapshot.sessions.find((v:PhoneV3SessionCard):boolean=>v.sessionId===e.session_id);if(s!==undefined){this.onOpenSession(s);}}
  private play(e:MemoryEvidence):void {
    if(e.session_id===undefined||e.utterance_id===undefined||e.start_ms===undefined||e.end_ms===undefined){return;}
    this.viewModel.playDailyEvidence({session_id:e.session_id,utterance_id:e.utterance_id,revision:e.revision,start_ms:e.start_ms,end_ms:e.end_ms,start_at:e.occurred_at,end_at:e.occurred_at,text:e.quote,participant:{key:'unknown',kind:'unknown',label:'说话人身份以原转写为准',status:'unresolved'}});
  }
  @Builder private taskSheet() {
    Column({space:12}) {
      Button('关闭事项详情').onClick(():void=>{this.showTask=false;})
      PhoneV3ChatFollowupsSection({viewModel:this.viewModel,eventId:this.task})
      PhoneV3RemindersPage({viewModel:this.viewModel,eventId:this.task,onOpenSession:this.onOpenSession})
    }.width('100%').padding(12)
  }
  @Builder private discussion(r:MemoryDiscussion) {
    Column({space:8}) {
      if(typeof r.window_label==='string'){Text(`历史窗口：${r.window_label}`).fontSize(12)}
      Text(r.title).fontSize(16).fontWeight(FontWeight.Medium).onClick(():void=>{this.expanded=this.expanded===r.id?'':r.id;this.evidencePage=0;})
      Text(`${this.time(r.occurred_at)} · ${r.link_basis==='existing_event'?'已有事件依据':r.link_basis==='human_confirmed'?'人工关联':'独立讨论'}`).fontSize(12)
      if(typeof r.summary==='string'){Text(r.summary).fontSize(15)}
      if(r.evidence_status!=='valid'){Text('证据已变化／缺失；以下为原修订，不能继续当作已确认事实。').fontColor($r('app.color.brand_warning'))}
      Button(this.expanded===r.id?'收起原文':'查看原文依据').onClick(():void=>{this.expanded=this.expanded===r.id?'':r.id;this.evidencePage=0;})
      if(this.expanded===r.id) {
        if((r.evidence_total??r.evidence.length)>8){
          Row({space:8}) {
            Button('前一页原文').fontSize(12).layoutWeight(1).enabled(this.evidencePage>0).onClick(():void=>{this.evidencePage--;})
            Text(`原文第 ${this.evidencePage+1} 页 · 共 ${r.evidence_total??r.evidence.length} 条`).fontSize(12).maxLines(2).layoutWeight(1)
            Button('后一页原文').fontSize(12).layoutWeight(1).enabled((this.evidencePage+1)*8<(r.evidence_total??r.evidence.length)).onClick(():void=>{this.evidencePage++;})
          }
        }
        ForEach(this.evidence(r),(e:MemoryEvidence)=>{
          Column({space:6}) {
            Text(`${e.speaker} · ${this.time(e.occurred_at)} · 原文修订 ${e.revision}`).fontSize(12)
            Text(e.quote).fontSize(15)
            Text(`${e.role==='context'?'邻近上下文，不作为核心事实':'核心证据'} · is_from_self=${e.is_from_self===undefined?'未知':String(e.is_from_self)} · ${e.identity_basis??'来源身份依据'} · ${e.assertion}`).fontSize(12)
            if(typeof e.learned_at==='string'){Text(`系统获知于 ${this.time(e.learned_at)}`).fontSize(12)}
            if(e.source_type==='recording') {
              Button('播放引用片段').enabled(e.status==='valid').onClick(():void=>this.play(e))
              Button('打开转写与人物纠正').enabled(this.viewModel.snapshot.sessions.some((s:PhoneV3SessionCard):boolean=>s.sessionId===e.session_id)).onClick(():void=>this.open(e))
            } else {Text(e.status==='valid'?'已缓存必要聊天原话；完整上下文可在电脑人物页打开。':'聊天原文修订已变化，请连接电脑核对。').fontSize(12)}
          }.width('100%').alignItems(HorizontalAlign.Start)
        },(e:MemoryEvidence):string=>e.record_id??e.utterance_id??e.occurred_at)
        if(typeof r.event_id==='string'){Button('打开关联跟进').onClick(():void=>{this.task=r.event_id??'';this.showTask=true;})}
        if(r.pending_change){Text('发现待确认进展；使用已有跟进审核，不自动改变事项状态。').fontSize(13)}
        Button('关联到另一件事').enabled(this.canOperate()&&r.evidence_status==='valid').onClick(():void=>{this.source=r.id;})
        if(this.source===r.id) {
          ForEach(this.index()?.discussions.filter((v:MemoryDiscussion):boolean=>v.id!==r.id&&v.thing_id!==r.thing_id)??[],(v:MemoryDiscussion)=>{
            Text(`${v.title} · ${v.evidence[0]?.quote.slice(0,40)??''}`).fontSize(13)
            Button('确认关联到此记录').enabled(this.canOperate()).onClick(():void=>this.decide(r.id,v.id,'link'))
          },(v:MemoryDiscussion):string=>v.id)
          Button('取消选择').onClick(():void=>{this.source='';})
        }
        if(this.sibling(r).length>0){Button('撤销此记录的事情关联，恢复独立').enabled(this.canOperate()).onClick(():void=>this.decide(r.id,this.sibling(r),'detach'))}
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12).backgroundColor($r('app.color.surface_secondary')).borderRadius(12)
  }
  build() {
    Column({space:12}) {
      Text('跨天互动与事情').fontSize(20).fontWeight(FontWeight.Bold)
      if(this.index()===undefined){Text('尚无跨天记忆缓存。电脑人物页选取日期和联系人后，同步到手机。').fontSize(14)}
      else {
        Text(`${this.index()?.scope.first??''} 至 ${this.index()?.scope.last??''} · Asia/Singapore`).fontSize(13)
        if((this.index()?.scope.coverage.missing_sources.length??0)>0){Text(`资料缺失：${this.index()?.scope.coverage.missing_sources.join('、')??''}`).fontSize(13)}
        if((this.index()?.scope.coverage.incremental?.deferred_discussions??0)>0){Text(`有限批次待处理 ${this.index()?.scope.coverage.incremental?.deferred_discussions??0} 段；请在电脑继续下一批。已处理 ${this.index()?.scope.coverage.incremental?.processed_discussions??0} 段，历史不会被容量限制删除。`).fontSize(13)}
        if(this.viewModel.snapshot.memoryPending){Text('人工关联操作已保存，等待电脑同步回执；原记录保留。').fontSize(13)}
        if(this.index()?.status==='no_data'){Text('已选范围尚无可用讨论。').fontSize(14)}
        Row({space:8}) {
          Button('前一页讨论').fontSize(12).layoutWeight(1).enabled(this.page>0).onClick(():void=>{this.page--;this.person='';this.thing='';this.topic='';this.expanded='';})
          Text(`第 ${this.page+1}/${this.index()?.page?.total??1} 页 · 历史保留`).fontSize(12).maxLines(2).layoutWeight(1)
          Button('后一页／历史讨论').fontSize(12).layoutWeight(1).enabled(this.page+1<(this.index()?.page?.total??1)).onClick(():void=>{this.page++;this.person='';this.thing='';this.topic='';this.expanded='';})
        }
        Button('全部讨论').onClick(():void=>{this.person='';this.thing='';this.topic='';})
        ForEach(this.index()?.people??[],(p:MemoryContact)=>{
          Text(`${p.label} · ${p.platform}`).fontSize(17).fontWeight(FontWeight.Medium)
          Text(`${p.identity_basis} · 最后证据 ${this.time(p.last_evidence_at)}`).fontSize(12)
          Button('最近互动与涉及的事情').onClick(():void=>{this.person=p.id;this.thing='';this.topic='';})
        },(p:MemoryContact):string=>p.id+':'+String(this.index()?.revision??0))
        ForEach(this.index()?.things.filter((t:MemoryThing):boolean=>this.person.length===0||this.index()?.discussions.some((r:MemoryDiscussion):boolean=>t.discussion_ids.includes(r.id)&&r.contacts.some((p:MemoryContact):boolean=>p.id===this.person))===true)??[],(t:MemoryThing)=>{
          Text(`${t.title} · ${t.discussion_ids.length} 次记录`).fontSize(15).onClick(():void=>{this.thing=t.id;this.topic='';this.person='';})
          if(this.thing===t.id){Text(`${t.progress} · 最后证据 ${this.time(t.last_evidence_at)}`).fontSize(12)}
        },(t:MemoryThing):string=>t.id+':'+String(this.index()?.revision??0))
        Text('同一话题下的独立讨论').fontSize(16)
        ForEach(this.index()?.topics??[],(t:MemoryTopic)=>{Button(`${t.label} · ${t.discussion_ids.length} 次讨论`).onClick(():void=>{this.topic=t.label;this.thing='';this.person='';})},(t:MemoryTopic):string=>t.label+':'+String(this.index()?.revision??0))
        Text('话题按讨论内容分组，不代表同一事情、用户观点或长期偏好。').fontSize(12)
        ForEach(this.rows(),(r:MemoryDiscussion)=>{this.discussion(r)},(r:MemoryDiscussion):string=>r.id+':'+String(this.index()?.revision??0))
        ForEach(this.index()?.candidates??[],(c:MemoryCandidate)=>{
          Text(c.reason).fontSize(13)
          Text(`${this.index()?.discussions.find((r:MemoryDiscussion):boolean=>r.id===c.source)?.title??''} ↔ ${this.index()?.discussions.find((r:MemoryDiscussion):boolean=>r.id===c.target)?.title??''}`).fontSize(13)
          Button('关联到这件事').enabled(this.canOperate()).onClick(():void=>this.decide(c.source,c.target,'link'))
          Button('不是同一件事').enabled(this.canOperate()).onClick(():void=>this.decide(c.source,c.target,'reject'))
        },(c:MemoryCandidate):string=>c.source+c.target+':'+String(this.index()?.revision??0))
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12).bindSheet(this.showTask,this.taskSheet())
  }
}
