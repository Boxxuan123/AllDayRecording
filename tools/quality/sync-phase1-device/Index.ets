// Temporary isolated entry; never part of a production build. No real bridge/remote.
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { HdsNavigation } from '@kit.UIDesignKit';
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { AudioPlaybackService } from 'common';
import { PhoneProjectionRepository } from '../v3/data/PhoneProjectionRepository';
import { PhoneV3UseCases } from '../v3/application/PhoneV3UseCases';
import { PhoneV3RemotePort, PhoneV3RemoteSession, PhoneV3LocalAudioRepositoryPort, PhoneV3DeviceBridgePort, PhoneV3AudioBackupPort, PhoneV3AudioBackupResult } from '../v3/application/PhoneV3Ports';
import { PhoneV3LocalAudioFact, PhoneV3DeviceState } from '../v3/domain/PhoneV3Models';
import { PhoneV3AnnotationEditor } from '../v3/domain/PhoneV3AnnotationEditor';
import { PhoneV3ViewModel } from '../v3/presentation/PhoneV3ViewModel';
import { PhoneV3AnnotationPage } from '../v3/presentation/PhoneV3AnnotationPage';
import { DeviceV3Change, DeviceV3PersonChoice, decodeBase64Url } from '../computer/ComputerTransferProtocol';

const DB: string = 'sync-phase1-isolated-20260926.db';
interface Fixture { changes: Array<DeviceV3Change>; people: Array<DeviceV3PersonChoice>; audio: string; }
class SlowBackup implements PhoneV3AudioBackupPort {
  private ca: string;
  constructor(ca: string) { this.ca=ca; }
  async backup(): Promise<PhoneV3AudioBackupResult> {
    const request=http.createHttp();
    try {
      const response=await request.request('https://127.0.0.1:19099/synthetic', {
        method:http.RequestMethod.PUT,extraData:new Uint8Array(8*1024*1024).buffer,
        caPath:this.ca,usingCache:false,connectTimeout:5000,readTimeout:120000 });
      if (response.responseCode!==200) { throw new Error('隔离传输失败'); }
      return new PhoneV3AudioBackupResult(1,1,0);
    } finally { request.destroy(); }
  }
}
class LocalBridge implements PhoneV3DeviceBridgePort {
  private value: PhoneV3DeviceState = new PhoneV3DeviceState();
  private player: AudioPlaybackService;
  private path: string;
  constructor(path: string, onState: (value: string)=>void) {
    this.path=path;
    this.player=new AudioPlaybackService((playing:boolean,message:string):void=>{
      this.value.isPlaying=playing;onState(message);
    });
  }
  state(): PhoneV3DeviceState { return this.value; }
  selectSession(_key: string): void {}
  playRange(_key: string,start: number,end: number): void { this.player.play(this.path,end-start,start); }
  togglePlayback(): void { this.playRange('',0,2000); }
  seekPlayback(_position: number): void {}
  stopPlayback(): void { this.player.release(); }
  requestWatchSync(): void {}
  requestWatchRecordingState(_state: string): void {}
  toggleWifiReceiver(): void {}
  retryWifiReceiver(): void {}
  reconnectReceiver(): void {}
  async deleteLocalSession(_key: string): Promise<void> { throw new Error('隔离验收不提供删除'); }
  addLocalAudioChangeListener(_listener: ()=>void): void {}
  removeLocalAudioChangeListener(_listener: ()=>void): void {}
}
async function writeSynthetic(path: string, bytes: Uint8Array): Promise<void> {
  const file=await fileIo.open(path,fileIo.OpenMode.CREATE|fileIo.OpenMode.WRITE_ONLY|fileIo.OpenMode.TRUNC);
  try { await fileIo.write(file.fd,bytes.buffer); } finally { await fileIo.close(file); }
}
class Local implements PhoneV3LocalAudioRepositoryPort { async list(): Promise<Array<PhoneV3LocalAudioFact>> { return []; } }
class Offline implements PhoneV3RemotePort {
  async isPaired(): Promise<boolean> { return false; }
  async connect(): Promise<PhoneV3RemoteSession> { throw new Error('隔离接收端离线'); }
}
class Route { editor: PhoneV3AnnotationEditor; constructor(editor: PhoneV3AnnotationEditor) { this.editor=editor; } }
@Entry
@Component
struct Index {
  @State private model: PhoneV3ViewModel = new PhoneV3ViewModel();
  @State private revision: number = 0;
  @State private ready: boolean = false;
  @State private note: string = '正在准备隔离验收';
  @State private persisted: string = '';
  @State private playback: string = '';
  private nav: NavPathStack = new NavPathStack();
  private repository: PhoneProjectionRepository | undefined = undefined;
  private store: relationalStore.RdbStore | undefined = undefined;
  aboutToAppear(): void { this.initialize(); }
  private async initialize(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const fixture = JSON.parse(util.TextDecoder.create('utf-8').decodeToString(
        await context.resourceManager.getRawFileContent('voice-review-fixture.json'))) as Fixture;
      const repository = await PhoneProjectionRepository.open(context, DB);
      this.repository=repository;
      this.store=await relationalStore.getRdbStore(context,{name:DB,securityLevel:relationalStore.SecurityLevel.S2});
      await this.store.executeSql('DROP TRIGGER IF EXISTS synthetic_write_failure');
      if ((await repository.projectionRows('recording_session')).length === 0) {
        await repository.beginTransaction();
        try {
          for (let change of fixture.changes) { await repository.applyChange(change); }
          await repository.cachePeople(fixture.people); await repository.commit();
        } catch (error) { await repository.rollback(); throw error as Error; }
      }
      const ca=`${context.cacheDir}/sync-phase1-test-ca.pem`;
      const audio=`${context.cacheDir}/sync-phase1-tone.wav`;
      await writeSynthetic(ca,await context.resourceManager.getRawFileContent('sync-phase1-test-ca.pem'));
      await writeSynthetic(audio,decodeBase64Url(fixture.audio));
      const useCases=new PhoneV3UseCases(repository,new Local(),new Offline(),undefined,new SlowBackup(ca));
      this.model=new PhoneV3ViewModel(useCases,undefined,new LocalBridge(audio,(message:string):void=>{this.playback=message;}));
      this.model.snapshot=await useCases.loadCached([]);
      this.model.snapshot.sessions[0].localPaths=[audio];
      this.model.snapshot.sessions[0].localGroupKey='synthetic';
      this.model.setStateChangeListener(():void=>{this.revision+=1;});
      await this.readBack();this.ready=true;this.note='隔离验收 · 接收端离线';
    } catch (error) { this.note=String(error); }
  }
  private async readBack(): Promise<void> {
    if (!this.repository) { return; }
    const ops=await this.repository.annotationOperations();
    this.persisted=`持久化操作 ${ops.length}`;
  }
  private open(n: number): void {
    const editor=new PhoneV3AnnotationEditor();
    const row=this.model.snapshot.sessions[0].utterances.find((value):boolean=>value.utteranceId === n.toString().padStart(26,'0'));
    if (!row) { return; }
    editor.open([row],this.model.snapshot.sessions);
    this.nav.pushPath({name:'annotation',param:new Route(editor)});
  }
  private async failWrites(): Promise<void> {
    await this.store?.executeSql(`CREATE TRIGGER IF NOT EXISTS synthetic_write_failure BEFORE INSERT ON outbox
      BEGIN SELECT RAISE(ABORT,'synthetic write failure'); END`);
    this.note='隔离写入故障已启用';
  }
  private async resetSynthetic(): Promise<void> {
    await this.store?.executeSql('DROP TRIGGER IF EXISTS synthetic_write_failure');
    await this.store?.executeSql('DELETE FROM outbox');
    await this.initialize();
  }
  @Builder private destination(name: string, param: Object) {
    if (name === 'annotation') {
      PhoneV3AnnotationPage({viewModel:this.model,navStack:this.nav,editor:(param as Route).editor,
        stateRevision:this.revision,scopeTitle:'合成片段'})
    }
  }
  build() {
    HdsNavigation(this.nav) {
      Column({space:16}) {
        Text(this.note).id('phase1-ready')
        Text(this.persisted).id('phase1-persisted')
        Text(this.model.computerSyncActive ? '合成传输进行中' : '合成传输未运行').id('phase1-transfer')
        Text(this.playback).id('phase1-playback')
        Button('启动合成慢传输').id('phase1-transfer-start').enabled(this.ready).onClick(():void=>this.model.synchronize())
        Button('播放本地合成音频').id('phase1-play').enabled(this.ready).onClick(():void=>this.model.playUtterance(this.model.snapshot.sessions[0].utterances[0]))
        Button('打开合成片段一').id('phase1-open-one').enabled(this.ready).onClick(():void=>this.open(1))
        Button('打开合成片段二').id('phase1-open-two').enabled(this.ready).onClick(():void=>this.open(2))
        Button('读回隔离数据库').id('phase1-read').onClick(():void=>{this.readBack();})
        Button('启用隔离写入故障').id('phase1-fail').onClick(():void=>{this.failWrites();})
        Button('重置本轮合成标注').id('phase1-reset').onClick(():void=>{this.resetSynthetic();})
      }.padding(24).width('100%').height('100%')
    }.navDestination(this.destination)
  }
}
