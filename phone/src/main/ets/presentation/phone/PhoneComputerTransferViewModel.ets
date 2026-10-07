import { common } from '@kit.AbilityKit';
import { ReceivedRecordingFile } from 'common';
import {
  createComputerRecordingBackupService,
  ComputerRecordingBackupRuntime
} from '../../computer/ComputerRecordingBackupService';
import {
  ComputerUploadProgress,
  computerDeviceName,
  computerTransferTimezone
} from '../../computer/ComputerRecordingUploadService';
import {
  ComputerTransferConfig,
  ComputerTransferConfigStore,
  ImportedComputerCa
} from '../../computer/ComputerTransferConfigStore';
import { ComputerTransferHttpClient } from '../../computer/ComputerTransferHttpClient';
import { ComputerReceiverDiscovery } from '../../computer/ComputerReceiverDiscovery';
import { PhoneDeviceKeyClient } from '../../computer/PhoneDeviceKeyClient';
import {
  computerTransferError,
  normalizeComputerBaseUrl,
  parseComputerPairingBootstrap
} from '../../computer/ComputerTransferProtocol';
import { prepareComputerSessions } from '../../computer/ComputerSessionManifest';
import { PreparedComputerSession } from '../../computer/ComputerSessionManifest';
import { recordingsNeedingComputerBackup, retryLegacyCompletionConflictsOnce } from '../../v3/data/PhoneV3ComputerBackup';
import { PhoneV3RecordingStore } from '../../v3/runtime/PhoneV3RecordingStore';
import { PhoneSessionCompletionRecord, PhoneSessionTransferFailure } from '../../v3/domain/PhoneV3Models';
import { PhonePasskeyClient } from '../../computer/PhonePasskeyClient';
import {
  PhoneProjectionRepository,
  PhoneProjectionStatus
} from '../../v3/data/PhoneProjectionRepository';
import { retryDelayMs } from '../../v3/data/PhoneSyncCoordinator';
import { PhoneSyncService, PhoneSyncServiceState } from '../../v3/application/PhoneSyncService';

interface PhoneProcessingProjection {
  status?: string;
  current_stage?: string;
  progress?: number;
}

export interface LegacyCompletionCandidate {
  sessionKey: string;
  completedSegments: number;
  totalSamples: number;
}

@Observed
export class PhoneComputerTransferViewModel {
  baseUrl: string = '';
  pairingCode: string = '';
  expectedFingerprint: string = '';
  importedFingerprint: string = '';
  rpId: string = '';
  passkeyCapability: string = '正在检查 Passkey 能力…';
  deviceKeyCapability: string = '正在检查 HUKS 设备密钥能力…';
  status: string = '请先导入并核对电脑终端显示的配对 CA';
  busy: boolean = false;
  paired: boolean = false;
  progressPercent: number = 0;
  uploadProgressActive: boolean = false;
  uploadRunning: boolean = false;
  completedFiles: number = 0;
  totalFiles: number = 0;
  availableSessions: number = 0;
  availableRecordings: number = 0;
  legacyCandidates: Array<LegacyCompletionCandidate> = [];
  transferFailures: Array<PhoneSessionTransferFailure> = [];
  pendingOperations: number = 0;
  syncCursor: string = 'cursor-0';
  cachedProcessingStatus: string = '暂无已同步处理状态';
  sharedSyncStatus: string = '同步空闲';

  private context: common.UIAbilityContext | undefined = undefined;
  private store: ComputerTransferConfigStore | undefined = undefined;
  private config: ComputerTransferConfig = new ComputerTransferConfig();
  private recordings: Array<ReceivedRecordingFile> = [];
  private knownCompletions: Array<PhoneSessionCompletionRecord> = [];
  private importedCaPath: string = '';
  private projectionPromise: Promise<PhoneProjectionRepository> | undefined = undefined;
  private syncServicePromise: Promise<PhoneSyncService> | undefined = undefined;
  private unsubscribeSync: (() => void) | undefined = undefined;
  private lifecycleGeneration: number = 0;
  private retryTimer: number = -1;
  private uploadGeneration: number = 0;
  private stopUploadRequested: boolean = false;

  async pairFromQr(value: string): Promise<void> {
    const context = this.requireContext();
    const store = this.requireStore();
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.progressPercent = 0;
    try {
      const bootstrap = parseComputerPairingBootstrap(value);
      this.status = '正在验证电脑配对 CA…';
      const imported = await store.importCaPem(bootstrap.ca_pem, bootstrap.ca_fingerprint);
      this.importedCaPath = imported.path;
      this.importedFingerprint = imported.fingerprint;
      this.expectedFingerprint = imported.fingerprint;
      this.baseUrl = bootstrap.addresses[0];
      this.status = '电脑身份已验证，请在系统界面确认一次 Passkey';
      const client = new ComputerTransferHttpClient(context, this.baseUrl, imported.path);
      const result = await client.pair(bootstrap.pairing_code, computerDeviceName());
      if (result.receiverId !== bootstrap.receiver_id) {
        throw new Error('电脑返回的稳定身份与二维码不一致');
      }
      const config = await store.savePairing(this.baseUrl, imported.fingerprint, result.rpId,
        result.receiverId, result.deviceId);
      this.applyConfig(config);
      this.status = '配对成功；以后换 Wi-Fi 会自动发现电脑并静默认证';
    } catch (error) {
      this.status = computerTransferError(error as Object).message;
    } finally {
      this.busy = false;
    }
  }

  start(context: common.UIAbilityContext): void {
    const generation = ++this.lifecycleGeneration;
    this.context = context;
    this.store = new ComputerTransferConfigStore(context);
    this.syncServicePromise = PhoneSyncService.shared(context);
    this.syncServicePromise.then((service: PhoneSyncService): void => {
      if (generation !== this.lifecycleGeneration) { return; }
      this.unsubscribeSync?.();
      this.unsubscribeSync = service.subscribe((state: PhoneSyncServiceState): void => {
        this.sharedSyncStatus = state.runningOwner === 'home' ? '首页同步中' :
          state.runningOwner === 'computer-page' ? '当前页面同步中' :
          state.queued > 0 ? `等待同步 · ${state.queued} 项` : '同步空闲';
      });
    }, (): void => {});
    this.projectionPromise = this.syncServicePromise.then(
      (service: PhoneSyncService): PhoneProjectionRepository => service.projection());
    this.refreshRecordings();
    this.requireProjection().then(async (repository: PhoneProjectionRepository): Promise<void> => {
      this.knownCompletions = await repository.localSessionCompletions();
      this.transferFailures = await repository.localSessionFailures();
      this.updateRecordings(this.recordings);
    }, (): void => {});
    this.loadState(context);
  }

  stop(): void {
    this.lifecycleGeneration += 1;
    this.cancelRetry();
    this.unsubscribeSync?.();
    this.unsubscribeSync = undefined;
    this.syncServicePromise?.then((service: PhoneSyncService): void => service.cancel('computer-page'),
      (): void => {});
  }

  refreshRecordings(): void {
    const context = this.requireContext();
    this.updateRecordings(PhoneV3RecordingStore.shared(context.filesDir).list());
  }

  private updateRecordings(recordings: Array<ReceivedRecordingFile>): void {
    this.recordings = recordings.slice();
    try {
      const sessions = prepareComputerSessions(this.recordings);
      this.availableSessions = sessions.length;
      let count = 0;
      for (let index = 0; index < sessions.length; index += 1) {
        count += sessions[index].recordings.length;
      }
      this.availableRecordings = count;
      this.legacyCandidates = sessions.filter((session: PreparedComputerSession): boolean =>
        !session.canCommit() && session.manifest.continuityValid &&
        !this.knownCompletions.some((record: PhoneSessionCompletionRecord): boolean =>
          record.sessionKey === session.manifest.sessionKey &&
          (record.manifestSha256.length > 0 ||
            (record.completedSegments === session.manifest.completedSegments &&
              record.totalSamples === session.manifest.totalSamples))) &&
        !this.recordings.some((file: ReceivedRecordingFile): boolean =>
          file.sourcePath === `${session.directory}/session_summary.json`))
        .map((session: PreparedComputerSession): LegacyCompletionCandidate => ({
          sessionKey: session.manifest.sessionKey,
          completedSegments: session.manifest.completedSegments,
          totalSamples: session.manifest.totalSamples
        }));
    } catch (error) {
      this.availableSessions = 0;
      this.availableRecordings = 0;
      this.legacyCandidates = [];
      this.status = computerTransferError(error as Object).message;
    }
  }

  async confirmLegacySession(sessionKey: string): Promise<void> {
    try {
      this.refreshRecordings();
      const candidate = this.legacyCandidates.find((item: LegacyCompletionCandidate): boolean =>
        item.sessionKey === sessionKey);
      if (candidate === undefined) { throw new Error('此会话已有结束记录或分片状态已变化，请刷新'); }
      const projection = await this.requireProjection();
      const existing = (await projection.localSessionCompletions()).find(
        (record: PhoneSessionCompletionRecord): boolean => record.sessionKey === sessionKey);
      if (existing !== undefined && existing.manifestSha256.length > 0) {
        throw new Error('旧录音已获电脑整场回执；迟到分片需要走修复流程');
      }
      if (existing !== undefined && existing.completedSegments === candidate.completedSegments &&
        existing.totalSamples === candidate.totalSamples) {
        throw new Error('此旧录音已经确认，不能重复覆盖回执');
      }
      const confirmation: PhoneSessionCompletionRecord = {
        sessionKey: candidate.sessionKey, source: 'legacy_user_confirmed',
        completedSegments: candidate.completedSegments, totalSamples: candidate.totalSamples,
        confirmedAt: Date.now(), manifestSha256: ''
      };
      await projection.recordSessionCompletion(confirmation);
      this.knownCompletions.push(confirmation);
      this.legacyCandidates = this.legacyCandidates.filter((item: LegacyCompletionCandidate): boolean =>
        item.sessionKey !== sessionKey);
      this.status = `已确认旧录音 ${candidate.completedSegments} 片，${candidate.totalSamples} 样本；请上传以取得电脑整场回执`;
    } catch (error) { this.status = computerTransferError(error as Object).message; }
  }

  async importCa(uri: string): Promise<void> {
    const store = this.requireStore();
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const imported = await store.importCa(uri, this.expectedFingerprint);
      this.importedCaPath = imported.path;
      this.importedFingerprint = imported.fingerprint;
      const saved = await store.load();
      if (saved.isPaired() && saved.caFingerprint === imported.fingerprint) {
        this.applyConfig(saved);
        this.status = 'CA 指纹验证通过，已有 Passkey 配对仍然有效';
      } else {
        this.config = new ComputerTransferConfig('', imported.fingerprint, '', imported.path);
        this.paired = false;
        this.rpId = '';
        this.status = 'CA 指纹验证通过，请输入首次配对码登记 Passkey';
      }
    } catch (error) {
      this.status = computerTransferError(error as Object).message;
    } finally {
      this.busy = false;
    }
  }

  async pair(): Promise<void> {
    const context = this.requireContext();
    const store = this.requireStore();
    if (this.busy) {
      return;
    }
    const code = this.pairingCode;
    this.pairingCode = '';
    this.busy = true;
    this.progressPercent = 0;
    try {
      const baseUrl = normalizeComputerBaseUrl(this.baseUrl);
      const caPath = this.importedCaPath.length > 0 ? this.importedCaPath : this.config.caPath;
      if (caPath.length === 0 || this.importedFingerprint.length === 0) {
        throw new Error('请先导入 CA，并核对电脑终端显示的 SHA-256 指纹');
      }
      this.status = '正在创建系统 Passkey…';
      const client = new ComputerTransferHttpClient(context, baseUrl, caPath);
      const result = await client.pair(code, computerDeviceName());
      const config = await store.savePairing(baseUrl, this.importedFingerprint, result.rpId,
        result.receiverId, result.deviceId);
      this.applyConfig(config);
      this.status = `配对成功：${result.rpId}。以后换 Wi-Fi 会自动发现电脑`;
    } catch (error) {
      this.paired = this.config.isPaired();
      this.status = computerTransferError(error as Object).message;
    } finally {
      this.busy = false;
    }
  }

  stopFurtherChecks(): void {
    this.stopUploadRequested = true;
    this.status = '当前录音确认完成后停止后续检查，已上传文件和回执会保留';
  }

  async upload(onlySessionKey: string = ''): Promise<void> {
    const context = this.requireContext();
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.uploadRunning = true;
    this.stopUploadRequested = false;
    this.uploadProgressActive = true;
    const uploadGeneration = ++this.uploadGeneration;
    this.progressPercent = 0;
    this.completedFiles = 0;
    this.totalFiles = 0;
    try {
      this.refreshRecordings();
      this.status = '正在自动发现已配对电脑…';
      const projection = await this.requireProjection();
      const completions = await projection.localSessionCompletions();
      const links = await projection.localAudioLinks();
      await retryLegacyCompletionConflictsOnce(context.filesDir, projection, completions);
      const failures = await projection.localSessionFailures();
      let pending = await recordingsNeedingComputerBackup(this.recordings, links, completions,
        undefined, onlySessionKey.length > 0 ? [] : failures);
      if (onlySessionKey.length > 0) {
        const selected = prepareComputerSessions(pending, computerTransferTimezone(), completions)
          .find((session: PreparedComputerSession): boolean => session.manifest.sessionKey === onlySessionKey);
        pending = selected === undefined ? [] : pending.filter((recording: ReceivedRecordingFile): boolean =>
          recording.sourcePath.startsWith(`${selected.directory}/`));
      }
      if (pending.length === 0) {
        if (onlySessionKey.length > 0) {
          this.status = '此录音的当前完整清单已确认，或录音文件尚未齐全';
          return;
        }
        this.status = failures.length > 0 ? `${failures.length} 条录音存在冲突或等待重试，请查看下方说明` :
          '音频分片已备份；清单入库状态见录音列表';
        const connected = await new ComputerRecordingBackupRuntime(context).connect();
        this.applyConfig(connected);
        await (await this.requireSyncService()).synchronize('computer-page',
          new ComputerTransferHttpClient(context, connected.baseUrl,
            connected.caPath, connected.deviceId));
        this.cancelRetry();
        await this.refreshProjectionStatus(projection);
        this.transferFailures = failures;
        return;
      }
      const sessions = prepareComputerSessions(pending, computerTransferTimezone(), completions).reverse();
      let connected: ComputerTransferConfig | undefined = undefined;
      let newFiles = 0;
      let skippedFiles = 0;
      let confirmedSessions = 0;
      const errors: Array<string> = [];
      for (let index = 0; index < sessions.length; index += 1) {
        if (this.stopUploadRequested) { break; }
        const session = sessions[index];
        const files = pending.filter((recording: ReceivedRecordingFile): boolean =>
          recording.sourcePath.startsWith(`${session.directory}/`));
        try {
          const outcome = await (await this.requireSyncService()).run('computer-page',
            async (owned: PhoneProjectionRepository) => createComputerRecordingBackupService(context, owned)
            .backup(files, (progress: ComputerUploadProgress): void => {
              if (uploadGeneration !== this.uploadGeneration) { return; }
              this.progressPercent = progress.stage === 'uploading' ? progress.percent() : 0;
              this.uploadProgressActive = progress.stage === 'uploading';
              this.completedFiles = progress.completedFiles;
              this.totalFiles = progress.totalFiles;
              this.status = this.stopUploadRequested ? '当前录音确认完成后停止后续检查' :
                `第 ${index + 1}/${sessions.length} 场 · ${progress.message}`;
            }, completions, await owned.localAudioLinks(), await owned.localSessionFailures()));
          connected = outcome.config;
          const uploaded = outcome.upload;
          newFiles += uploaded.recordings + uploaded.manifests - uploaded.skippedFiles;
          skippedFiles += uploaded.skippedFiles;
          confirmedSessions += uploaded.sessions;
        } catch (error) {
          errors.push(`${session.directory}：${computerTransferError(error as Object).message}`);
        }
      }
      this.knownCompletions = await projection.localSessionCompletions();
      this.updateRecordings(this.recordings);
      this.uploadProgressActive = false;
      this.status = `${this.stopUploadRequested ? '已停止后续检查' : '上传检查完成'}：新增 ${newFiles} 个文件，电脑已有并跳过 ${skippedFiles} 个；` +
        `${confirmedSessions} 个会话已获得整场备份确认` +
        (errors.length > 0 ? `；${errors.length} 条录音待处理：${errors.join('；')}` : '');
      if (connected === undefined) { return; }
      this.applyConfig(connected);
      try {
        const sync = await (await this.requireSyncService()).synchronize('computer-page',
          new ComputerTransferHttpClient(context, connected.baseUrl,
            connected.caPath, connected.deviceId));
        await this.refreshProjectionStatus(projection);
        this.cancelRetry();
        this.status += `；V3 已同步 ${sync.batches} 批，游标 ${sync.final_cursor}`;
      } catch (error) {
        const projectionStatus = await this.refreshProjectionStatus(projection);
        this.scheduleRetry(projectionStatus.retry_count);
        this.status += `；录音已安全上传，V3 状态同步待重试：${computerTransferError(error as Object).message}`;
      }
    } catch (error) {
      this.status = computerTransferError(error as Object).message;
    } finally {
      this.uploadRunning = false;
      if (uploadGeneration === this.uploadGeneration) {
        this.uploadProgressActive = false;
        this.progressPercent = 0;
        this.uploadGeneration += 1;
      }
      try { this.transferFailures = await (await this.requireProjection()).localSessionFailures(); }
      catch (_error) {}
      this.busy = false;
    }
  }

  async synchronize(): Promise<void> {
    const context = this.requireContext();
    const store = this.requireStore();
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      if (!this.config.isPaired()) {
        throw new Error('请先完成电脑 Passkey 配对');
      }
      this.status = '正在发现电脑并同步 V3 状态…';
      const discoveredUrl = await new ComputerReceiverDiscovery(context).discover(this.config.receiverId);
      const updated = await store.saveLastAddress(discoveredUrl);
      this.applyConfig(updated);
      const projection = await this.requireProjection();
      const result = await (await this.requireSyncService()).synchronize('computer-page',
        new ComputerTransferHttpClient(context, updated.baseUrl, updated.caPath, updated.deviceId));
      await this.refreshProjectionStatus(projection);
      this.cancelRetry();
      this.status = `V3 同步完成：${result.batches} 批，游标 ${result.final_cursor}，` +
        `待提交 ${this.pendingOperations} 项`;
    } catch (error) {
      this.status = computerTransferError(error as Object).message;
      try {
        const projection = await this.requireProjection();
        const projectionStatus = await this.refreshProjectionStatus(projection);
        this.scheduleRetry(projectionStatus.retry_count);
      } catch (projectionError) {
      }
    } finally {
      this.busy = false;
    }
  }

  async rebuildProjection(): Promise<void> {
    const context = this.requireContext();
    const store = this.requireStore();
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      if (!this.config.isPaired()) {
        throw new Error('请先完成电脑 Passkey 配对');
      }
      const projection = await this.requireProjection();
      await (await this.requireSyncService()).rebuild('computer-page');
      await this.refreshProjectionStatus(projection);
      this.cancelRetry();
      this.status = '本地可重建投影已清空；outbox 与手机录音保留，正在从电脑恢复…';
      const discoveredUrl = await new ComputerReceiverDiscovery(context).discover(this.config.receiverId);
      const updated = await store.saveLastAddress(discoveredUrl);
      this.applyConfig(updated);
      const result = await (await this.requireSyncService()).synchronize('computer-page',
        new ComputerTransferHttpClient(context, updated.baseUrl, updated.caPath, updated.deviceId));
      await this.refreshProjectionStatus(projection);
      this.cancelRetry();
      this.status = `本地投影已从电脑重建：${result.batches} 批，游标 ${result.final_cursor}`;
    } catch (error) {
      this.status = `投影重建待继续：${computerTransferError(error as Object).message}`;
      try {
        const projection = await this.requireProjection();
        const projectionStatus = await this.refreshProjectionStatus(projection);
        this.scheduleRetry(projectionStatus.retry_count);
      } catch (projectionError) {
      }
    } finally {
      this.busy = false;
    }
  }

  private loadState(context: common.UIAbilityContext): void {
    const store = this.requireStore();
    store.load().then((config: ComputerTransferConfig): void => {
      this.applyConfig(config);
      if (config.isPaired()) {
        this.status = '电脑已配对；上传时会自动发现，无需处理 Wi-Fi 或 IP 变化';
        this.loadProjectionRetryState();
      }
    }, (error: Object): void => {
      this.status = `读取电脑配对失败：${computerTransferError(error).message}`;
    });
    const passkeys = new PhonePasskeyClient(context);
    passkeys.capabilityDescription().then((value: string): void => {
      this.passkeyCapability = value;
    }, (error: Object): void => {
      this.passkeyCapability = computerTransferError(error).message;
    });
    const deviceKeys = new PhoneDeviceKeyClient();
    deviceKeys.capabilityDescription().then((value: string): void => {
      this.deviceKeyCapability = value;
    }, (error: Object): void => {
      this.deviceKeyCapability = computerTransferError(error).message;
    });
    this.loadProjectionRetryState();
  }

  private loadProjectionRetryState(): void {
    this.requireProjection().then((repository: PhoneProjectionRepository): void => {
      this.refreshProjectionStatus(repository).then((status: PhoneProjectionStatus): void => {
        if (status.last_error.length > 0) {
          this.scheduleRetry(status.retry_count);
        }
      }, (error: Object): void => {
        this.status = `读取 Phone V3 状态失败：${computerTransferError(error).message}`;
      });
    }, (error: Object): void => {
      this.status = `读取 Phone V3 投影失败：${computerTransferError(error).message}`;
    });
  }

  private applyConfig(config: ComputerTransferConfig): void {
    this.config = config;
    this.paired = config.isPaired();
    if (config.baseUrl.length > 0) {
      this.baseUrl = config.baseUrl;
    }
    if (config.caFingerprint.length > 0) {
      this.expectedFingerprint = config.caFingerprint;
      this.importedFingerprint = config.caFingerprint;
    }
    this.importedCaPath = config.caPath;
    this.rpId = config.rpId;
  }

  private requireContext(): common.UIAbilityContext {
    if (this.context === undefined) {
      throw new Error('电脑传输页面尚未初始化');
    }
    return this.context;
  }

  private requireStore(): ComputerTransferConfigStore {
    if (this.store === undefined) {
      throw new Error('电脑传输页面尚未初始化');
    }
    return this.store;
  }

  private async requireProjection(): Promise<PhoneProjectionRepository> {
    if (this.projectionPromise === undefined) {
      throw new Error('Phone V3 投影尚未初始化');
    }
    return this.projectionPromise;
  }

  private async requireSyncService(): Promise<PhoneSyncService> {
    if (this.syncServicePromise === undefined) {
      throw new Error('Phone 同步服务尚未初始化');
    }
    return this.syncServicePromise;
  }

  private async refreshProjectionStatus(repository: PhoneProjectionRepository): Promise<PhoneProjectionStatus> {
    const status: PhoneProjectionStatus = await repository.status();
    this.pendingOperations = status.pending_operations;
    this.syncCursor = status.cursor;
    const processingPayload = await repository.latestProcessingPayload();
    this.cachedProcessingStatus = processingPayload === null ? '暂无已同步处理状态' :
      formatProcessingStatus(processingPayload);
    return status;
  }

  private scheduleRetry(attemptCount: number): void {
    if (this.retryTimer >= 0 || !this.paired) {
      return;
    }
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      this.synchronize();
    }, retryDelayMs(attemptCount));
  }

  private cancelRetry(): void {
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }
}

function formatProcessingStatus(payloadJson: string): string {
  try {
    const payload = JSON.parse(payloadJson) as PhoneProcessingProjection;
    const status = payload.status === undefined || payload.status.length === 0 ? 'unknown' : payload.status;
    const stage = payload.current_stage === undefined || payload.current_stage.length === 0 ? '' :
      `，阶段 ${payload.current_stage}`;
    const progress = payload.progress === undefined || !Number.isFinite(payload.progress) ? '' :
      `，进度 ${Math.round(payload.progress * 100)}%`;
    return `${status}${stage}${progress}`;
  } catch (error) {
    return '缓存处理状态无法解析';
  }
}
