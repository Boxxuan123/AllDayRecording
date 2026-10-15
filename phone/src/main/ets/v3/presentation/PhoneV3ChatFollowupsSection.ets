import { ChatFollowup, ChatFollowupEvidence } from '../domain/PhoneChatFollowup';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
@Component
export struct PhoneV3ChatFollowupsSection {
  @ObjectLink viewModel: PhoneV3ViewModel;
  @State private editing: string = '';
  @State private mode: string = '';
  @State private title: string = '';
  @State private at: string = '';
  @Builder
  private evidence(rows: Array<ChatFollowupEvidence>) {
    ForEach(rows,(e:ChatFollowupEvidence)=>{
      Text(`${e.platform==='wechat'?'微信':'QQ'} · ${e.is_from_self===true?'我本人':e.speaker} · ${e.sent_at===null?'发送时间未知':new Date(e.sent_at*1000).toISOString()}`).fontSize(12).fontColor($r('app.color.text_secondary'))
      Text(e.quote).fontSize(14)
      if(JSON.stringify(e.context)!=='{}') { Text(`引用／转发上下文：${JSON.stringify(e.context)}`).fontSize(12).fontColor($r('app.color.text_secondary')) }
    },(e:ChatFollowupEvidence):string=>`${e.record_id}:${e.record_revision}`)
  }
  @Builder
  private card(item:ChatFollowup) {
    Column({space:8}) {
      Text(item.title).fontSize(17).fontWeight(FontWeight.Medium)
      Text(`${item.actor_is_from_self===true?'我本人':item.actor_is_from_self===false?'对方':'承担者未知'} · ${item.status==='active'&&!item.ignored?'跟进中':'已结束'}${item.historical||item.progress_unknown?' · 历史事项，进展未知':''}`).fontSize(13)
      Text(`约定时间：${item.time.at??item.time.date??'未知'} · ${item.time.expression??''} ${item.time.uncertainty??''}`).fontSize(13)
      ForEach(item.uncertainty,(u:string)=>{Text(u).fontSize(13)},(u:string):string=>u)
      this.evidence(item.evidence)
      if(item.pendingAction) { Text('操作已保存在手机，待电脑确认').fontColor($r('app.color.brand_warning')) }
      if(item.pending_change!==null) {
        Text(`新进展待确认：${item.pending_change.action==='complete'?'完成':item.pending_change.action==='cancel'?'取消':'改期或其他变化'}；你的原决定已保留`).fontColor($r('app.color.brand_warning'))
        Text(`新时间：${item.pending_change.time.at??item.pending_change.time.date??'未知'}`).fontSize(13)
        this.evidence(item.pending_change.evidence)
        Row({space:8}) {
          Button('采用新变化').enabled(!this.viewModel.busy&&!item.pendingAction&&item.pending_change.kind!=='evidence_replaced').onClick(():void=>this.viewModel.chatFollowupCommand(item,'accept_change'))
          Button('拒绝新变化').enabled(!this.viewModel.busy&&!item.pendingAction).onClick(():void=>this.viewModel.chatFollowupCommand(item,'dismiss_change'))
        }
      }
      if(item.status==='active'&&!item.ignored) {
        Row({space:8}) {
          Button('确认当前需我处理').enabled(!this.viewModel.busy&&!item.pendingAction).onClick(():void=>this.viewModel.chatFollowupCommand(item,'confirm'))
          Button('完成').enabled(!this.viewModel.busy&&!item.pendingAction).onClick(():void=>this.viewModel.chatFollowupCommand(item,'complete'))
          Button('忽略').enabled(!this.viewModel.busy&&!item.pendingAction).onClick(():void=>this.viewModel.chatFollowupCommand(item,'ignore'))
        }
        Button('启用提醒').enabled(!this.viewModel.busy&&!item.pendingAction&&item.actor_is_from_self===true).onClick(():void=>{this.editing=item.event_id;this.mode='enable_reminder';this.title=item.title;this.at=item.time.at??'';})
      } else {
        Button('重新开启').enabled(!this.viewModel.busy&&!item.pendingAction).onClick(():void=>this.viewModel.chatFollowupCommand(item,'reopen'))
      }
      Button('编辑事项').enabled(!this.viewModel.busy&&!item.pendingAction).onClick(():void=>{this.editing=item.event_id;this.mode='edit';this.title=item.title;this.at=item.time.at??'';})
      if(this.editing===item.event_id) {
        if(this.mode==='edit'){TextInput({text:this.title,placeholder:'事项标题'}).onChange((v:string):void=>{this.title=v;})}
        TextInput({text:this.at,placeholder:'明确时间含时区，如 2026-10-12T09:00+08:00'}).onChange((v:string):void=>{this.at=v;})
        if(this.mode==='enable_reminder'){Text('点击确认表示当前仍需执行，并确认上述准确时间；只有日期或未知时间不能安排提醒。').fontSize(13)}
        Button(this.mode==='enable_reminder'?'确认当前仍需执行并启用提醒':'保存修改').enabled(!this.viewModel.busy&&!item.pendingAction).onClick(():void=>{this.viewModel.chatFollowupCommand(item,this.mode,this.title,this.at);this.editing='';})
        Button('收起').onClick(():void=>{this.editing='';})
      }
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start).backgroundColor($r('app.color.surface_primary')).borderRadius(16)
  }
  build() {
    Column({space:12}) {
      Text(`聊天跟进（${this.viewModel.snapshot.chatFollowups.length}）`).width('100%').fontSize(16).fontWeight(FontWeight.Medium)
      if(this.viewModel.snapshot.chatFollowups.length===0){Text('Windows 接纳后，同步电脑即可查看聊天事项。').fontSize(13)}
      ForEach(this.viewModel.snapshot.chatFollowups,(item:ChatFollowup)=>{this.card(item)},(item:ChatFollowup):string=>item.event_id)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
