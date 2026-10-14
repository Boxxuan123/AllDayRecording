import { HdsNavigation, HdsNavDestination, HdsNavigationTitleMode, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { PhoneV3RootPage } from '../v3/presentation/PhoneV3RootPage';
import { PhoneV3SessionDetailPage } from '../v3/presentation/PhoneV3SessionDetailPage';
import { PhoneV3ViewModel } from '../v3/presentation/PhoneV3ViewModel';
import { PhoneV3UseCases } from '../v3/application/PhoneV3UseCases';
import { PhoneProjectionRepository } from '../v3/data/PhoneProjectionRepository';
import { applySyncResponse } from '../v3/data/PhoneSyncProjection';
import { PhoneV3SessionCard } from '../v3/domain/PhoneV3Models';
import { PhoneDailySummary } from '../v3/domain/PhoneV3DailyModels';
import { ProductObservation, ProductFixture, ProductLocal, ProductRemote, ProductBridge } from './ProductAcceptance';
interface ProductLedger {database:string;events:Array<ProductObservation>;}
async function write(path:string,data:Uint8Array):Promise<void>{const f=await fileIo.open(path,fileIo.OpenMode.CREATE|fileIo.OpenMode.WRITE_ONLY|fileIo.OpenMode.TRUNC);try{await fileIo.write(f.fd,data.buffer);}finally{await fileIo.close(f);}}
@Entry
@Component
struct Index {
  @State private model:PhoneV3ViewModel=new PhoneV3ViewModel();
  @State private revision:number=0;
  @State private tab:number=0;
  @State private mode:number=0;
  @State private ready:boolean=false;
  @State private note:string='初始化隔离验收';
  private nav:NavPathStack=new NavPathStack();
  private use:PhoneV3UseCases|undefined=undefined;
  private context:common.UIAbilityContext|undefined=undefined;
  private bridge:ProductBridge|undefined=undefined;
  private events:Array<ProductObservation>=[];
  private timer:number=-1;
  private database:string='';
  aboutToAppear():void{this.setup(0);}
  aboutToDisappear():void{this.model.stop();this.bridge?.stopPlayback();if(this.timer>=0){clearInterval(this.timer);}}
  private record(event:ProductObservation):void{this.events.push(event);this.persist();}
  private ledger():ProductLedger{return {database:this.database,events:this.events};}
  private async persist():Promise<void>{if(this.context!==undefined){await write(this.context.cacheDir+'/phone-product-v2-evidence.json',util.TextEncoder.create('utf-8').encodeInto(JSON.stringify(this.ledger())));}}
  private async setup(mode:number):Promise<void>{
    this.ready=false;this.model.stop();this.bridge?.stopPlayback();this.mode=mode;this.tab=0;this.note='正在读取隔离数据';
    try{
      const context=this.getUIContext().getHostContext() as common.UIAbilityContext;this.context=context;
      const fixture=JSON.parse(util.TextDecoder.create('utf-8').decodeToString(await context.resourceManager.getRawFileContent('product-v2-fixture.json'))) as ProductFixture;
      const audio=context.cacheDir+'/phone-product-v2-silence.wav';await write(audio,await context.resourceManager.getRawFileContent('product-v2-fixture.wav'));
      this.database='phone-product-v2-'+Date.now()+'-'+mode+'.db';
      if(!/^phone-product-v2-[0-9]+-[0-9]+\.db$/.test(this.database)){throw new Error('拒绝生产库名');}
      const repo=await PhoneProjectionRepository.open(context,this.database);
      if(mode!==1){
        const day=fixture.packet.changes.find((c):boolean=>c.resource_type==='daily_summary')?.resource as PhoneDailySummary;
        if(mode===2&&day.objective.unified_review!==undefined){day.objective.unified_review.coverage.missing_sources=['QQ'];}
        if(mode===4&&day.objective.unified_review!==undefined){day.objective.unified_review.status='failed';}
        await applySyncResponse(repo,fixture.packet);
      }
      const local=new ProductLocal(audio,mode===1);
      const remote=new ProductRemote(fixture,mode,(event:ProductObservation):void=>{this.record(event);});
      const use=new PhoneV3UseCases(repo,local,remote);this.use=use;
      const bridge=new ProductBridge(audio,(event:ProductObservation):void=>{this.record(event);});this.bridge=bridge;
      const model=new PhoneV3ViewModel(use,undefined,bridge);model.snapshot=await use.loadCached(await local.list());model.localReady=true;model.cacheReady=true;
      model.setStateChangeListener(():void=>{this.revision++;});this.model=model;
      if(this.timer>=0){clearInterval(this.timer);}this.timer=setInterval(():void=>{if(this.bridge!==undefined){this.model.device=this.bridge.state();this.revision++;}},1000);
      this.record({phase:'scenario',mode:mode,database:this.database});this.note='隔离验收 · 合成数据';this.revision++;this.ready=true;
    }catch(error){this.note=String(error);}
  }
  private async acknowledge():Promise<void>{
    const use=this.use;if(use===undefined){return;}
    try{await use.synchronize();this.model.refresh();this.note='隔离回执已保存';this.record({phase:'acknowledged'});}
    catch(error){this.note=String(error);}
  }
  @Builder private destination(_name:string,param:Object){HdsNavDestination(){PhoneV3SessionDetailPage({viewModel:this.model,routeSession:param as PhoneV3SessionCard,stateRevision:this.revision})}.titleBar({enableComponentSafeArea:true,content:{title:{mainTitle:'来源录音'}}}).titleMode(HdsNavDestinationTitleMode.MINI).onBackPressed(():boolean=>{this.model.stopPlayback();return false;})}
  build(){
    HdsNavigation(this.nav){Column({space:4}){
      Row({space:4}){
        Select([{value:'有内容'},{value:'无内容'},{value:'部分覆盖'},{value:'来源离线'},{value:'模型失败'},{value:'来源失效'}]).selected(this.mode).value(['有内容','无内容','部分覆盖','来源离线','模型失败','来源失效'][this.mode]).onSelect((i:number):void=>{this.setup(i);})
        Text(this.note).fontSize(10).layoutWeight(1)
        Button('收取回执').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(this.ready).onClick(():void=>{this.acknowledge();})
      }.width('100%').padding({left:12,right:12})
      if(this.ready){PhoneV3RootPage({viewModel:this.model,stateRevision:this.revision,selectedTab:$tab,onOpenSession:(session:PhoneV3SessionCard):void=>{this.model.selectSession(session);this.nav.pushPath({name:'session',param:session});}}).layoutWeight(1)}
    }.width('100%').height('100%')}.titleBar({enableComponentSafeArea:true,content:{title:{mainTitle:['今天','回忆','事项','记录'][this.tab]}}}).titleMode(HdsNavigationTitleMode.MINI).mode(NavigationMode.Stack).width('100%').height('100%').navDestination(this.destination)
  }
}

