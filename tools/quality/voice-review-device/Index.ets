// Test-only overlay for pages/Index.ets. Never registered in the production HAP.
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { HdsNavigation } from '@kit.UIDesignKit';
import { PhoneProjectionRepository } from '../v3/data/PhoneProjectionRepository';
import { PhoneV3ReviewAudioPlayer } from '../v3/data/PhoneV3ReviewAudioPlayer';
import { PhoneV3UseCases } from '../v3/application/PhoneV3UseCases';
import { PhoneV3RemotePort, PhoneV3RemoteSession, PhoneV3LocalAudioRepositoryPort } from '../v3/application/PhoneV3Ports';
import { PhoneV3LocalAudioFact } from '../v3/domain/PhoneV3Models';
import { PhoneV3ViewModel } from '../v3/presentation/PhoneV3ViewModel';
import { PhoneV3VoiceReviewPage } from '../v3/presentation/PhoneV3VoiceReviewPage';
import { PhoneV3ReviewInboxPage } from '../v3/presentation/PhoneV3ReviewInboxPage';
import { DeviceV3Change, DeviceV3PersonChoice, DeviceV3ReviewSnapshot, DeviceV3ReviewActionRequest, DeviceV3ReviewActionResponse, DeviceV3ReviewAudioRequest, DeviceV3ReviewAudioResponse, DeviceV3ReviewAudioWindow, DeviceV3StatusResponse, DeviceV3SyncRequest, DeviceV3SyncResponse, DeviceV3AnnotationRequest, DeviceV3AnnotationResponse } from '../computer/ComputerTransferProtocol';
interface Clip { media_id: string; start_ms: number; end_ms: number; }
interface Candidate { prototype_id: string; representative_clips: Array<Clip>; }
interface Context { voice_candidates: Array<Candidate>; }
interface Review { review_id: string; context: Context; }
interface Fixture { changes: Array<DeviceV3Change>; reviews: Array<Review>; people: Array<DeviceV3PersonChoice>; audio: string; }
class Local implements PhoneV3LocalAudioRepositoryPort { async list(): Promise<Array<PhoneV3LocalAudioFact>> { return []; } }
class Remote implements PhoneV3RemotePort, PhoneV3RemoteSession {
  fixture: Fixture;
  offline: boolean = false;
  constructor(fixture: Fixture) { this.fixture = fixture; }
  async isPaired(): Promise<boolean> { return true; }
  async connect(): Promise<PhoneV3RemoteSession> { if (this.offline) { throw new Error('隔离验收：电脑连接中断'); } return this; }
  async status(): Promise<DeviceV3StatusResponse> { throw new Error('unused'); }
  async sync(request: DeviceV3SyncRequest): Promise<DeviceV3SyncResponse> { throw new Error('unused'); }
  async annotations(request: DeviceV3AnnotationRequest): Promise<DeviceV3AnnotationResponse> { return { people: this.fixture.people }; }
  async reviews(): Promise<DeviceV3ReviewSnapshot> { return { items: this.fixture.reviews }; }
  async resolveReview(request: DeviceV3ReviewActionRequest): Promise<DeviceV3ReviewActionResponse> {
    for (let r of this.fixture.reviews) { if (r.review_id === request.review_id) { r.context.voice_candidates = r.context.voice_candidates.filter((c: Candidate): boolean => c.prototype_id !== request.prototype_id); } }
    this.fixture.reviews = this.fixture.reviews.filter((r: Review): boolean => r.context.voice_candidates.length > 0);
    return { result: new Object(), reviews: await this.reviews() };
  }
  async reviewAudio(request: DeviceV3ReviewAudioRequest): Promise<DeviceV3ReviewAudioResponse> {
    const candidate = this.fixture.reviews.find((r: Review): boolean => r.review_id === request.review_id)?.context.voice_candidates.find((c: Candidate): boolean => c.prototype_id === request.prototype_id);
    if (!candidate) { throw new Error('sample missing'); }
    const windows: Array<DeviceV3ReviewAudioWindow> = candidate.representative_clips.map((c: Clip, i: number): DeviceV3ReviewAudioWindow => ({media_id:c.media_id,start_ms:c.start_ms,end_ms:c.end_ms,playback_start_ms:i*500}));
    return { complete_sample:true, audition_key:request.prototype_id, windows:windows,review_id:request.review_id,prototype_id:request.prototype_id,format:'wav',data_base64url:this.fixture.audio,start_ms:0,end_ms:windows.length*500 };
  }
}
class Route { id: string; history: boolean; constructor(id: string, history: boolean) { this.id=id; this.history=history; } }
@Entry
@Component
struct Index {
  @State private model: PhoneV3ViewModel = new PhoneV3ViewModel();
  @State private revision: number = 0;
  @State private ready: boolean = false;
  @State private note: string = '正在创建隔离数据库';
  private nav: NavPathStack = new NavPathStack();
  private remote: Remote | undefined = undefined;
  aboutToAppear(): void { this.initialize(); }
  private async initialize(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const bytes = await context.resourceManager.getRawFileContent('voice-review-fixture.json');
      const fixture = JSON.parse(util.TextDecoder.create('utf-8').decodeToString(bytes)) as Fixture;
      const repository = await PhoneProjectionRepository.open(context, 'voice-review-isolated.db');
      await repository.rebuildFromComputer();
      await repository.beginTransaction();
      for (let change of fixture.changes) { await repository.applyChange(change); }
      await repository.commit();
      await repository.replaceReviewItems(fixture.reviews); await repository.cachePeople(fixture.people);
      this.remote = new Remote(fixture);
      this.model = new PhoneV3ViewModel(new PhoneV3UseCases(repository, new Local(), this.remote), new PhoneV3ReviewAudioPlayer(context));
      this.model.setStateChangeListener((): void => { this.revision += 1; });
      this.model.refresh(); this.ready=true; this.note='隔离验收 · 合成数据 / 真实页面';
    } catch (error) { this.note=String(error); }
  }
  @Builder private destination(name: string, param: Object) {
    if (name === 'voice') {
      PhoneV3VoiceReviewPage({viewModel:this.model,navStack:this.nav,reviewId:(param as Route).id,history:(param as Route).history,stateRevision:this.revision,
        onConnect:():void=>{ if (this.remote) { this.remote.offline=!this.remote.offline; } }})
    }
  }
  build() {
    HdsNavigation(this.nav) {
      Column({space:12}) {
        Text(this.note).fontSize(16)
        if (this.ready) {
          Row() {
            Button('重读本地结果').onClick(():void=>this.model.refresh())
            Button('清理隔离数据').onClick(():void=>{
              this.model.stopPlayback();
              relationalStore.deleteRdbStore(this.getUIContext().getHostContext() as common.UIAbilityContext, 'voice-review-isolated.db').then(():void=>{this.note='隔离数据库已删除';this.ready=false;}).catch((error:Error):void=>{this.note=error.message;});
            })
          }
          PhoneV3ReviewInboxPage({viewModel:this.model,stateRevision:this.revision,onOpenVoice:(id:string,history:boolean):void=>{this.nav.pushPath({name:'voice',param:new Route(id,history)});}})
        }
      }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
    }.hideTitleBar(true).navDestination(this.destination).mode(NavigationMode.Stack)
  }
}
