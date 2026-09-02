import { common } from '@kit.AbilityKit';
import { ReceivedRecordingFile } from 'common';
import {
  createComputerRecordingBackupService
} from '../../computer/ComputerRecordingBackupService';
import {
  ComputerUploadProgress,
  computerDeviceName
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
import { ReceivedRecordingStore } from '../../services/ReceivedRecordingStore';
import { PhonePasskeyClient } from '../../computer/PhonePasskeyClient';
import {
  PhoneProjectionRepository,
  PhoneProjectionStatus
} from '../../v3/data/PhoneProjectionRepository';
import { PhoneSyncCoordinator, retryDelayMs } from '../../v3/data/PhoneSyncCoordinator';

interface PhoneProcessingProjection {
  status?: string;
  current_stage?: string;
  progress?: number;
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
  completedFiles: number = 0;
  totalFiles: number = 0;
  availableSessions: number = 0;
  availableRecordings: number = 0;
  pendingOperations: number = 0;
  syncCursor: string = 'cursor-0';
  cachedProcessingStatus: string = '暂无已同步处理状态';

  private context: common.UIAbilityContext | undefined = undefined;
  private store: ComputerTransferConfigStore | undefined = undefined;
  private config: ComputerTransferConfig = new ComputerTransferConfig();
  private recordings: Array<ReceivedRecordingFile> = [];
  private importedCaPath: string = '';
  private projectionPromise: Promise<PhoneProjectionRepository> | undefined = undefined;
  private retryTimer: number = -1;

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
    this.context = context;
    this.store = new ComputerTransferConfigStore(context);
    this.projectionPromise = PhoneProjectionRepository.open(context);
    this.refreshRecordings();
    this.loadState(context);
  }

  refreshRecordings(): void {
    const context = this.requireContext();
    this.updateRecordings(new ReceivedRecordingStore(context.filesDir).list());
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
    } catch (error) {
      this.availableSessions = 0;
      this.availableRecordings = 0;
      this.status = computerTransferError(error as Object).message;
    }
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

  async upload(): Promise<void> {
    const context = this.requireContext();
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.progressPercent = 0;
    this.completedFiles = 0;
    this.totalFiles = 0;
    try {
      this.refreshRecordings();
      this.status = '正在自动发现已配对电脑…';
      const projection = await this.requireProjection();
      const outcome = await createComputerRecordingBackupService(context, projection)
        .backup(this.recordings, (progress: ComputerUploadProgress): void => {
          this.progressPercent = progress.percent();
          this.completedFiles = progress.completedFiles;
          this.totalFiles = progress.totalFiles;
          this.status = progress.message;
        });
      this.applyConfig(outcome.config);
      const result = outcome.upload;
      this.progressPercent = 100;
      const newFiles = result.recordings + result.manifests - result.skippedFiles;
      this.status = `上传检查完成：新增 ${newFiles} 个文件，电脑已有并跳过 ${result.skippedFiles} 个；` +
        `共 ${result.sessions} 个会话，手机原文件已保留`;
      try {
        const sync = await new PhoneSyncCoordinator(
          new ComputerTransferHttpClient(context, outcome.config.baseUrl,
            outcome.config.caPath, outcome.config.deviceId),
          projection).synchronize();
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
      const result = await new PhoneSyncCoordinator(
        new ComputerTransferHttpClient(context, updated.baseUrl, updated.caPath, updated.deviceId),
        projection).synchronize();
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
      await projection.rebuildFromComputer();
      await this.refreshProjectionStatus(projection);
      this.cancelRetry();
      this.status = '本地可重建投影已清空；outbox 与手机录音保留，正在从电脑恢复…';
      const discoveredUrl = await new ComputerReceiverDiscovery(context).discover(this.config.receiverId);
      const updated = await store.saveLastAddress(discoveredUrl);
      this.applyConfig(updated);
      const result = await new PhoneSyncCoordinator(
        new ComputerTransferHttpClient(context, updated.baseUrl, updated.caPath, updated.deviceId),
        projection).synchronize();
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
