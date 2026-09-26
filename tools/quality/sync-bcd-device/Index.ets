// Temporary isolated assembly. Never imported by the production entry.
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { huks } from '@kit.UniversalKeystoreKit';
import { util, process } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { HdsNavigation } from '@kit.UIDesignKit';
import { ReceivedRecordingFile, AudioPlaybackService, PCM_SAMPLE_RATE_HZ } from 'common';
import { PhoneDeviceKeyClient } from '../computer/PhoneDeviceKeyClient';
import { ComputerTransferConfig, ComputerTransferConfigStore } from '../computer/ComputerTransferConfigStore';
import { ComputerRecordingBackupService, ComputerRecordingBackupRuntime } from '../computer/ComputerRecordingBackupService';
import { ComputerUploadProgress } from '../computer/ComputerRecordingUploadService';
import { PhoneV3DeviceRemote } from '../v3/data/PhoneV3DeviceRemote';
import { PhoneProjectionRepository } from '../v3/data/PhoneProjectionRepository';
import { PhoneV3UseCases } from '../v3/application/PhoneV3UseCases';
import { PhoneV3AudioBackupPort, PhoneV3AudioBackupResult, PhoneV3LocalAudioRepositoryPort } from '../v3/application/PhoneV3Ports';
import { PhoneV3LocalAudioFact, PhoneV3Utterance } from '../v3/domain/PhoneV3Models';
import { PhonePendingOperation } from '../v3/data/PhoneSyncProjection';
import { PhoneV3ViewModel } from '../v3/presentation/PhoneV3ViewModel';
import { PhoneV3AnnotationEditor } from '../v3/domain/PhoneV3AnnotationEditor';
import { PhoneV3AnnotationPage } from '../v3/presentation/PhoneV3AnnotationPage';
import { nativeRefresh } from './NativeRefresh';
import { PhoneV3ReviewAudioCache } from '../v3/data/PhoneV3ReviewAudioCache';
import { PhoneV3ReviewAudioPlayer } from '../v3/data/PhoneV3ReviewAudioPlayer';
import { DeviceV3ReviewAudioResponse } from '../computer/ComputerTransferProtocol';
import { phoneV3VoiceTasks } from '../v3/domain/PhoneV3VoiceReviewTask';
import { PhoneV3VoiceReviewPage } from '../v3/presentation/PhoneV3VoiceReviewPage';

const KEY: string = 'alldayrecording.bcd.synthetic.20260926';
const DB: string = 'sync-bcd-isolated-20260926.db';
interface Config { baseUrl: string; receiverId: string; deviceId: string; fingerprint: string; utteranceId: string; }
class IsolatedConfig extends ComputerTransferConfigStore {
  private config: ComputerTransferConfig;
  constructor(context: common.UIAbilityContext, value: Config) {
    super(context);
    this.config = new ComputerTransferConfig(value.baseUrl, value.fingerprint, 'localhost',
      context.cacheDir + '/sync-bcd-ca.pem', value.receiverId, value.deviceId);
    this.config.signingKeyAlias = KEY;
  }
  async load(): Promise<ComputerTransferConfig> { return this.config; }
  async saveLastAddress(address: string): Promise<ComputerTransferConfig> { this.config.baseUrl = address; return this.config; }
}
class Local implements PhoneV3LocalAudioRepositoryPort { async list(): Promise<Array<PhoneV3LocalAudioFact>> { return []; } }
class ProductionBackup implements PhoneV3AudioBackupPort {
  enabled: boolean = false;
  private service: ComputerRecordingBackupService;
  private recording: ReceivedRecordingFile;
  private report: (progress: ComputerUploadProgress) => void;
  constructor(context: common.UIAbilityContext, store: IsolatedConfig, repository: PhoneProjectionRepository,
    recording: ReceivedRecordingFile, report: (progress: ComputerUploadProgress) => void) {
    this.service = new ComputerRecordingBackupService(new ComputerRecordingBackupRuntime(context, store), repository);
    this.recording = recording; this.report = report;
  }
  async backup(): Promise<PhoneV3AudioBackupResult> {
    if (!this.enabled) { return new PhoneV3AudioBackupResult(); }
    const result = await this.service.backup([this.recording], this.report);
    return new PhoneV3AudioBackupResult(result.upload.sessions, result.upload.recordings, result.upload.skippedFiles);
  }
}
class Route { editor: PhoneV3AnnotationEditor; constructor(editor: PhoneV3AnnotationEditor) { this.editor=editor; } }
interface SaveTime { started: number; committed: number; operationIds: Array<string>; }
class TimedUseCases extends PhoneV3UseCases {
  times: Array<SaveTime> = [];
  async queueAnnotation(rows: Array<PhoneV3Utterance>, personId: string, name: string,
    changed: boolean, kind: string): Promise<Array<PhonePendingOperation>> {
    const started = Date.now();
    const operations = await super.queueAnnotation(rows,personId,name,changed,kind);
    this.times.push({started:started,committed:Date.now(),operationIds:operations.map((op)=>op.operation_id)});
    return operations;
  }
}
interface PlayTime { clicked: number; started: number; worker: number; main: number; key: string; }
class TimedPlayer extends PhoneV3ReviewAudioPlayer {
  clicked: number = 0;
  times: Array<PlayTime> = [];
  async play(response: DeviceV3ReviewAudioResponse, onStarted: () => void, onCompleted: () => void,
    onFailure: (message: string) => void, onProgress: (position: number) => void): Promise<void> {
    await super.play(response, (): void => {
      this.times.push({ clicked:this.clicked, started:Date.now(), worker:response.local_worker_tid ?? 0,
        main:process.tid,key:response.audio_content_key ?? '' });
      onStarted();
    }, onCompleted, onFailure, onProgress);
  }
}
async function write(path: string, bytes: Uint8Array): Promise<void> {
  const file = await fileIo.open(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try { await fileIo.write(file.fd, bytes.buffer); } finally { await fileIo.close(file); }
}
@Entry
@Component
struct Index {
  @State private model: PhoneV3ViewModel = new PhoneV3ViewModel();
  @State private revision: number = 0;
  @State private note: string = '';
  @State private migration: string = '';
  @State private progress: string = '';
  @State private playback: string = '';
  @State private pending: number = -1;
  @State private durable: string = '';
  private cache: PhoneV3ReviewAudioCache | undefined = undefined;
  private reviewPlayer: TimedPlayer | undefined = undefined;
  private backup: ProductionBackup | undefined = undefined;
  @State private reviewCount: number = 0;
  private nav: NavPathStack = new NavPathStack();
  private uid: string = '';
  private player: AudioPlaybackService | undefined = undefined;
  private recordingPath: string = '';
  private playbackPath: string = '';
  private use: TimedUseCases | undefined = undefined;
  private repository: PhoneProjectionRepository | undefined = undefined;
  aboutToAppear(): void { this.bootstrap(); }
  aboutToDisappear(): void { this.model.stop(); this.player?.release(); }
  private async bootstrap(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const publicKey = await new PhoneDeviceKeyClient(KEY).ensurePublicKey();
      await write(context.cacheDir + '/sync-bcd-public.txt', util.TextEncoder.create('utf-8').encodeInto(publicKey));
      this.note = '隔离 HUKS 公钥已准备';
      if (await fileIo.access(context.cacheDir+'/sync-bcd-resume')) { await this.prepare(true); }
    } catch (error) { this.note = String(error); }
  }
  private async prepare(resume: boolean = false): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const value = JSON.parse(util.TextDecoder.create('utf-8').decodeToString(
        await context.resourceManager.getRawFileContent('sync-bcd-config.json'))) as Config;
      await write(context.cacheDir + '/sync-bcd-ca.pem', await context.resourceManager.getRawFileContent('sync-bcd-ca.pem'));
      this.uid = value.utteranceId;
      if (!resume) {
      const previous = await relationalStore.getRdbStore(context, {name:DB, securityLevel:relationalStore.SecurityLevel.S2});
      await previous.close();
      await relationalStore.deleteRdbStore(context, DB);
      await PhoneProjectionRepository.open(context, DB);
      const store = await relationalStore.getRdbStore(context, {name:DB, securityLevel:relationalStore.SecurityLevel.S2});
      // Only this explicitly named synthetic DB is reconstructed as v10.
      await store.executeSql('DROP TRIGGER IF EXISTS outbox_selection_insert');
      await store.executeSql('DROP TRIGGER IF EXISTS outbox_selection_delete');
      await store.executeSql('DROP TABLE IF EXISTS outbox_selections');
      await store.executeSql("INSERT OR IGNORE INTO outbox(operation_id,kind,payload_json,created_at) VALUES('00000000000000000000999999','segment.classify','{\"selections\":[{\"utterance_id\":\"migration-target\",\"revision\":1}]}',0)");
      store.version = 10;
      await PhoneProjectionRepository.open(context, DB);
      const indexed = await store.querySql("SELECT COUNT(*) FROM outbox_selections WHERE resource_id='migration-target'");
      indexed.goToFirstRow(); const count = indexed.getLong(0); indexed.close();
      if (store.version !== 11 || count !== 1) { throw new Error('原生迁移校验失败'); }
      await store.executeSql("DELETE FROM outbox WHERE operation_id='00000000000000000000999999'");
      this.migration = '原生 RDB 10→11 通过';
      }
      const repository = await PhoneProjectionRepository.open(context, DB);
      this.repository = repository;
      this.recordingPath = context.cacheDir + '/sync-bcd-recording.wav';
      const bytes = new Uint8Array(8*1024*1024+44);
      const header = new DataView(bytes.buffer);
      bytes.set(util.TextEncoder.create('utf-8').encodeInto('RIFF'),0);
      header.setUint32(4,bytes.length-8,true);bytes.set(util.TextEncoder.create('utf-8').encodeInto('WAVEfmt '),8);
      header.setUint32(16,16,true);header.setUint16(20,1,true);header.setUint16(22,1,true);
      header.setUint32(24,PCM_SAMPLE_RATE_HZ,true);header.setUint32(28,PCM_SAMPLE_RATE_HZ*2,true);
      header.setUint16(32,2,true);header.setUint16(34,16,true);
      bytes.set(util.TextEncoder.create('utf-8').encodeInto('data'),36);header.setUint32(40,bytes.length-44,true);
      await write(this.recordingPath, bytes);
      this.playbackPath = context.cacheDir + '/sync-bcd-tone.wav';
      const tone = bytes.slice(0,PCM_SAMPLE_RATE_HZ*4+44);
      const toneHeader = new DataView(tone.buffer);
      toneHeader.setUint32(4,tone.length-8,true); toneHeader.setUint32(40,tone.length-44,true);
      await write(this.playbackPath,tone);
      const name = 'segment_000001_first_000000000000.wav';
      const recording: ReceivedRecordingFile = {fileName:name,path:this.recordingPath,size:bytes.length,
        durationMs:8388608/2/PCM_SAMPLE_RATE_HZ*1000,requestId:'synthetic',receivedAt:1,
        sourcePath:'pcm_gap_test_1790390000000/'+name};
      const config = new IsolatedConfig(context,value);
      const backup = new ProductionBackup(context,config,repository,recording,(p: ComputerUploadProgress):void=>{
        this.progress = p.sessionCompleted ? '生产备份已完成' : '生产备份进行中 ' + p.transferredBytes;
      });
      this.backup = backup;
      const cache = new PhoneV3ReviewAudioCache(context, 'sync-bcd-review-audio');
      this.cache = cache;
      this.reviewPlayer = new TimedPlayer(context, cache);
      const use = new TimedUseCases(repository,new Local(),new PhoneV3DeviceRemote(context,config),undefined,backup,cache);
      this.use = use;
      if (!resume) { await use.synchronize(); }
      this.model = new PhoneV3ViewModel(use, this.reviewPlayer);
      this.model.snapshot = await use.loadCached([]);
      this.model.setStateChangeListener(():void=>{
        this.revision+=1;
        this.reviewCount=phoneV3VoiceTasks(this.model.snapshot.reviewItems).length;
        this.pending=this.model.snapshot.sync.pendingOperations;
        repository.v3Status().then((status):void=>{
          this.durable='原生持久化待同步 '+status.pendingOperations;
          write(context.cacheDir+'/sync-bcd-state.json',util.TextEncoder.create('utf-8').encodeInto(JSON.stringify({
            pending:this.model.snapshot.sync.pendingOperations,durable:status.pendingOperations,
            message:this.model.computerSyncMessage,error:this.model.computerSyncError,revision:this.revision,at:Date.now(),times:use.times,
            cache:{hits:cache.hits,downloads:cache.downloads,joins:cache.joins},plays:this.reviewPlayer?.times,
            tasks:phoneV3VoiceTasks(this.model.snapshot.reviewItems).map((t)=>({key:t.key,fingerprint:t.fingerprint,
              content:t.candidate.audioContentKey,played:this.model.reviewSampleWasPlayed(t.item.reviewId,t.candidate.prototypeId)})),
            audioLoading:this.model.annotationPlaybackState(),audioError:this.model.error
          })));
        });
      });
      this.player = new AudioPlaybackService((_playing:boolean,message:string):void=>{this.playback=message;});
      await this.model.startForegroundSync(context,'sync_bcd_isolated_settings');
      this.model.setReviewAudioWindow([], true);
      await write(context.cacheDir+'/sync-bcd-resume',new Uint8Array([1]));
      this.note = '隔离生产链路已准备';
      this.reviewCount=phoneV3VoiceTasks(this.model.snapshot.reviewItems).length;
    } catch (error) { this.note=String(error); }
  }
  private playReview(index: number): void {
    const task=phoneV3VoiceTasks(this.model.snapshot.reviewItems)[index];
    if (!task || !this.reviewPlayer) { this.note='缺少合成审核样本'; return; }
    this.reviewPlayer.clicked=Date.now();
    this.model.playReviewSample(task.item.reviewId,task.candidate.prototypeId);
  }
  private prefetch(): void { this.model.setReviewAudioWindow(phoneV3VoiceTasks(this.model.snapshot.reviewItems)); }
  private async clearCache(): Promise<void> {
    this.model.setReviewAudioWindow([],false); this.model.stopPlayback();
    await this.reviewPlayer?.release(); await this.cache?.clear(); this.note='合成试听缓存已清理';
  }
  private async saveOfflineBatch(): Promise<void> {
    try {
      for (let kind of ['media_speech','non_speech','unintelligible']) {
        const row = this.model.snapshot.sessions.flatMap((s)=>s.utterances).find((r)=>r.utteranceId===this.uid);
        if (row === undefined) { throw new Error('missing synthetic row'); }
        await new Promise<void>((resolve,reject):void=>{
          this.model.saveAnnotation([row],'','',false,kind,():void=>resolve());
          setTimeout(():void=>reject(new Error('local save deadline')),5000);
        });
        while (this.model.annotationSaving) { await new Promise<void>((resolve)=>setTimeout(resolve,10)); }
      }
      const operations = await this.repository!.annotationOperations();
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await write(context.cacheDir+'/sync-bcd-queue.json',util.TextEncoder.create('utf-8').encodeInto(JSON.stringify(operations)));
      this.note='离线三次本地提交完成';
    } catch(error) { this.note=String(error); }
  }
  private open(): void {
    const row = this.model.snapshot.sessions.flatMap((s)=>s.utterances).find((r)=>r.utteranceId===this.uid);
    if (!row) { this.note='找不到合成片段'; return; }
    const editor = new PhoneV3AnnotationEditor();editor.open([row],this.model.snapshot.sessions);
    this.nav.pushPath({name:'annotation',param:new Route(editor)});
  }
  @Builder private destination(name:string,param:Object) {
    if(name==='voice') { PhoneV3VoiceReviewPage({viewModel:this.model,navStack:this.nav,stateRevision:this.revision}) }
    else if(name==='annotation') { PhoneV3AnnotationPage({viewModel:this.model,navStack:this.nav,
      editor:(param as Route).editor,stateRevision:this.revision,scopeTitle:'生产链路合成片段'}) }
  }
  build() {
    HdsNavigation(this.nav) {
      Scroll() {
        Column({space:12}) {
          Text(this.note).id('phase2-ready')
          Text('审核样本 '+this.reviewCount).id('bcd-count')
          Text(this.model.error).id('bcd-error')
          Text(this.model.reviewPlaybackPrototype ? '正在播放审核样本' : this.model.annotationPlaybackState() === '正在加载' ? '审核音频准备中' : '审核播放器空闲').id('bcd-play-state')
          Row({space:8}) {
            Button('试听一').id('bcd-play-0').onClick(():void=>this.playReview(0))
            Button('试听二').id('bcd-play-1').onClick(():void=>this.playReview(1))
            Button('停止').id('bcd-stop').onClick(():void=>this.model.stopPlayback())
          }
          Row({space:8}) {
            Button('打开审核页').id('bcd-open-voice').onClick(():void=>{this.nav.pushPath({name:'voice'});})
            Button('预取').id('bcd-prefetch').onClick(():void=>this.prefetch())
            Button('清理试听缓存').id('bcd-clear').onClick(():void=>{this.clearCache();})
          }
          Row({space:8}) {
            Button('开始备份').id('bcd-backup').onClick(():void=>{if(this.backup){this.backup.enabled=true;}this.model.synchronize();})
            Button('暂停同步').id('bcd-pause').onClick(():void=>this.model.cancelSynchronize())
            Button('继续同步').id('bcd-resume').onClick(():void=>this.model.resumeSynchronize())
          }
          Text(this.migration).id('phase2-migration')
          Text(this.progress).id('phase2-progress')
          Text(this.model.backupError || this.model.backupMessage).id('phase2-backup')
          Text(this.model.computerSyncError || this.model.computerSyncMessage).id('phase2-light')
          Text('待同步 '+this.pending).id('phase2-pending')
          Text(this.durable).id('phase2-durable')
          Button('准备生产链路').id('phase2-prepare').onClick(():void=>{this.prepare();})
          Button('打开合成标注').id('phase2-open').onClick(():void=>this.open())
          Button('播放本地合成音频').id('phase2-play').onClick(():void=>{this.player?.play(this.playbackPath,2000,0);})
          Button('连续保存三条合成标注').id('phase2-batch').onClick(():void=>{this.saveOfflineBatch();})
          Button('验证原生刷新交错').id('phase2-refresh').onClick(():void=>{
            nativeRefresh(this.getUIContext().getHostContext() as common.UIAbilityContext,this.repository!)
              .then((result:string):void=>{this.note=result;}).catch((error:Object):void=>{this.note=String(error);});
          })
          Button('清理隔离测试密钥').id('phase2-clean-key').onClick(():void=>{
            this.model.stop();
            huks.deleteKeyItem(KEY,{properties:[]}).then(():void=>{this.note='隔离测试密钥已清理';});
          })
          Text(this.playback).id('phase2-playback')
          ForEach([1,2,3,4,5,6,7,8,9,10],(n:number)=>{Text('合成滚动行 '+n).height(70)})
          Text('已滚动到底部').id('phase2-scroll-end')
        }.padding(20).width('100%')
      }.id('phase2-scroll')
    }.navDestination(this.destination)
  }
}
