import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { wearEngine } from '@kit.WearEngine';
import {
  P2P_COMMUNICATION_FAILURE,
  P2P_REMOTE_APP_NOT_INSTALLED,
  P2P_REMOTE_APP_NOT_RUNNING,
  P2P_REMOTE_APP_RUNNING,
  PhoneReceiverLifecycleCoordinator,
  PhoneRecordingControlCoordinator,
  PhoneRecordingControlState,
  PhoneSyncCoordinator,
  ReceivedRecordingFile,
  WatchRecordingControlStatus,
  WatchSyncFileDescriptor,
  WatchSyncProgress,
  WATCH_AUTO_FILE,
  WATCH_CONTROL_PROBE,
  WATCH_CONTROL_READY,
  WATCH_PHONE_READY,
  WATCH_RECORDING_ACK,
  WATCH_RECORDING_COMMAND,
  WATCH_SYNC_BEGIN,
  WATCH_SYNC_COMPLETE,
  WATCH_SYNC_ERROR,
  WATCH_SYNC_FILE,
  WATCH_SYNC_FILE_FAILED,
  WATCH_SYNC_FILE_PROGRESS,
  WATCH_SYNC_FILE_RECEIVED,
  WATCH_SYNC_INVENTORY_PAGE,
  WATCH_SYNC_PROTOCOL_VERSION,
  WATCH_SYNC_QUEUED,
  WATCH_SYNC_READY,
  WATCH_SYNC_REQUEST,
  WatchSyncProtocolMessage,
  WearEngineConnection,
  WearEngineTransport,
  copyFileAtomically,
  decodeWatchSyncMessage,
  destroyWearEngineChannel,
  exactWatchFileKey,
  legacyWatchFileKey,
  p2pResultMessage,
  shouldRetryReceiverConnection,
  wearEngineErrorMessage
} from 'common';
import { ReceivedRecordingStore, SYNC_RECEIVE_DIRECTORY } from './ReceivedRecordingStore';

export { wearEngineErrorMessage } from 'common';

const MAX_RECORDING_BYTES: number = 10 * 1024 * 1024;
const INVENTORY_KEYS_PER_PAGE: number = 24;
const RECEIVER_CONNECT_ATTEMPTS: number = 5;
const RECEIVER_RETRY_BASE_DELAY_MS: number = 800;
const SYNC_HANDSHAKE_TIMEOUT_MS: number = 20 * 1000;
const CONTROL_COMMAND_TIMEOUT_MS: number = 20 * 1000;
const PENDING_USER_ACTION_TIMEOUT_MS: number = 5 * 60 * 1000;

export type RecordingReceivedHandler = (recording: ReceivedRecordingFile) => void;
export type TransferStatusHandler = (status: string) => void;
export type WatchSyncProgressHandler = (progress: WatchSyncProgress) => void;
export type WatchRecordingControlStatusHandler = (status: WatchRecordingControlStatus) => void;

type P2pTransport = WearEngineConnection;

function waitForReceiverRetry(delayMs: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(resolve, delayMs);
  });
}

function ensureDirectory(path: string): void {
  if (!pathExistsChecked(path)) {
    createDirectoryChecked(path);
  }
}

function pathExistsChecked(path: string): boolean {
  try {
    return fileIo.accessSync(path);
  } catch (error) {
    throw transferFileError(error);
  }
}

function createDirectoryChecked(path: string): void {
  try {
    fileIo.mkdirSync(path);
  } catch (error) {
    throw transferFileError(error);
  }
}

function closeFileChecked(fd: number): void {
  try {
    fileIo.closeSync(fd);
  } catch (error) {
    throw transferFileError(error);
  }
}

function transferFileError(error: Object): Error {
  return error instanceof Error ? error : new Error(JSON.stringify(error));
}

function safeFileName(fileName: string): string {
  return fileName.replace(/[^A-Za-z0-9._-]/g, '_');
}

export class WearEngineRecordingReceiver {
  private context: common.UIAbilityContext;
  private transportEngine: WearEngineTransport;
  private receivedHandler: RecordingReceivedHandler;
  private statusHandler: TransferStatusHandler;
  private syncProgressHandler: WatchSyncProgressHandler;
  private controlStatusHandler: WatchRecordingControlStatusHandler;
  private p2pClient: wearEngine.P2pClient | undefined = undefined;
  private peer: wearEngine.Device | undefined = undefined;
  private appParam: wearEngine.P2pAppParam | undefined = undefined;
  private phoneSync: PhoneSyncCoordinator = new PhoneSyncCoordinator(SYNC_HANDSHAKE_TIMEOUT_MS);
  private activeTotal: number = 0;
  private activeReceived: number = 0;
  private activeSkipped: number = 0;
  private activeAlreadyReceived: number = 0;
  private activeRemaining: number = 0;
  private activeScannedTotal: number = 0;
  private expectedReceived: number = -1;
  private remoteComplete: boolean = false;
  private fileTransferActive: boolean = false;
  private transferStage: string = 'idle';
  private transferPercent: number = 0;
  private transferFileName: string = '';
  private transferredBytes: number = 0;
  private transferSize: number = 0;
  private transferIndex: number = 0;
  private transferTotal: number = 0;
  private transferAutomatic: boolean = false;
  private lastTransferProgressAt: number = 0;
  private activeTransferDescriptor: WatchSyncFileDescriptor | undefined = undefined;
  private phoneControl: PhoneRecordingControlCoordinator = new PhoneRecordingControlCoordinator(
    CONTROL_COMMAND_TIMEOUT_MS, PENDING_USER_ACTION_TIMEOUT_MS);
  private startTask: Promise<void> | undefined = undefined;
  private receiverLifecycle: PhoneReceiverLifecycleCoordinator = new PhoneReceiverLifecycleCoordinator();
  private recordingStore: ReceivedRecordingStore;
  private fileReceiver = (incoming: wearEngine.P2pFile): void => {
    this.receiveFile(incoming);
  };
  private messageReceiver = (incoming: wearEngine.P2pMessage): void => {
    this.receiveMessage(incoming);
  };

  constructor(context: common.UIAbilityContext, receivedHandler: RecordingReceivedHandler,
    statusHandler: TransferStatusHandler, syncProgressHandler: WatchSyncProgressHandler,
    controlStatusHandler: WatchRecordingControlStatusHandler) {
    this.context = context;
    this.transportEngine = new WearEngineTransport(context);
    this.receivedHandler = receivedHandler;
    this.statusHandler = statusHandler;
    this.syncProgressHandler = syncProgressHandler;
    this.controlStatusHandler = controlStatusHandler;
    this.recordingStore = new ReceivedRecordingStore(context.filesDir);
  }

  getStoredRecordings(): Array<ReceivedRecordingFile> {
    return this.recordingStore.list();
  }

  async start(): Promise<void> {
    if (this.p2pClient !== undefined) {
      return;
    }
    if (this.startTask !== undefined) {
      await this.startTask;
      return;
    }
    const startToken = this.receiverLifecycle.beginStart();
    const task = this.connectWithRetry(startToken);
    this.startTask = task;
    try {
      await task;
    } finally {
      if (this.startTask === task) {
        this.startTask = undefined;
      }
      this.receiverLifecycle.finish(startToken);
    }
  }

  private async connectWithRetry(startToken: number): Promise<void> {
    for (let attempt = 1; attempt <= RECEIVER_CONNECT_ATTEMPTS; attempt += 1) {
      if (!this.receiverLifecycle.isActive(startToken)) {
        throw new Error('Wear Engine 接收器启动已取消');
      }
      this.statusHandler(`正在核对 Wear Engine 用户授权（${attempt}/${RECEIVER_CONNECT_ATTEMPTS}）…`);
      try {
        const authorization = await wearEngine.getAuthClient(this.context).getAuthorization();
        this.statusHandler(`用户授权正常（${authorization.permissions.length} 项），正在查找手表` +
          `（${attempt}/${RECEIVER_CONNECT_ATTEMPTS}）…`);
        await this.connectOnce(startToken);
        return;
      } catch (error) {
        if (!this.receiverLifecycle.isActive(startToken)) {
          throw new Error('Wear Engine 接收器启动已取消');
        }
        if (attempt >= RECEIVER_CONNECT_ATTEMPTS || !shouldRetryReceiverConnection(error)) {
          throw new Error(wearEngineErrorMessage(error));
        }
        const delayMs = RECEIVER_RETRY_BASE_DELAY_MS * attempt;
        this.statusHandler(`Wear Engine 暂未发现手表，${Math.ceil(delayMs / 1000)} 秒后自动重试…`);
        await waitForReceiverRetry(delayMs);
      }
    }
  }

  private async connectOnce(startToken: number): Promise<void> {
    const transport = await this.transportEngine.connect(false);
    const peer = transport.peer;
    if (!this.receiverLifecycle.isActive(startToken)) {
      throw new Error('Wear Engine 接收器启动已取消');
    }
    this.statusHandler('已找到手表，正在注册文件与消息接收…');
    const appParam = transport.appParam;
    const client = transport.client;
    let messageRegistered = false;
    let fileRegistered = false;
    try {
      await this.transportEngine.registerMessageReceiver(transport, this.messageReceiver);
      messageRegistered = true;
      if (!this.receiverLifecycle.isActive(startToken)) {
        throw new Error('Wear Engine 接收器启动已取消');
      }
      await this.transportEngine.registerFileReceiver(transport, this.fileReceiver);
      fileRegistered = true;
      if (!this.receiverLifecycle.isActive(startToken)) {
        throw new Error('Wear Engine 接收器启动已取消');
      }
    } catch (error) {
      if (fileRegistered) {
        try {
          await this.transportEngine.unregisterFileReceiver(transport, this.fileReceiver);
        } catch (unregisterError) {
          // The Wear Engine service may have restarted while cleaning up this attempt.
        }
      }
      if (messageRegistered) {
        try {
          await this.transportEngine.unregisterMessageReceiver(transport, this.messageReceiver);
        } catch (unregisterError) {
          // The Wear Engine service may have restarted while cleaning up this attempt.
        }
      }
      throw new Error(wearEngineErrorMessage(error));
    }
    this.peer = peer;
    this.appParam = appParam;
    this.p2pClient = client;
    this.statusHandler(`已通过 Wear Engine 连接${peer.name ? `：${peer.name}` : '手表'}，可以同步`);
    const readyMessage: WatchSyncProtocolMessage = {
      version: WATCH_SYNC_PROTOCOL_VERSION,
      type: WATCH_PHONE_READY,
      requestId: ''
    };
    try {
      await this.transportEngine.sendProtocolMessage(transport, readyMessage);
    } catch (error) {
      // The watch may not be open yet; receiving remains available in the foreground.
    }
  }

  async stop(): Promise<void> {
    this.receiverLifecycle.cancel();
    const startTask = this.startTask;
    if (startTask !== undefined) {
      try {
        await startTask;
      } catch (error) {
        // A cancelled or failed startup has already cleaned up its partial registrations.
      }
    }
    const client = this.p2pClient;
    const peer = this.peer;
    const appParam = this.appParam;
    this.p2pClient = undefined;
    this.peer = undefined;
    this.appParam = undefined;
    this.phoneControl.finish();
    this.clearSyncHandshakeTimeout();
    this.phoneSync.stop();
    this.activeTotal = 0;
    this.activeReceived = 0;
    this.activeSkipped = 0;
    this.activeAlreadyReceived = 0;
    this.activeRemaining = 0;
    this.activeScannedTotal = 0;
    this.expectedReceived = -1;
    this.remoteComplete = false;
    this.resetFileTransferState();
    this.emitProgress(false, '同步状态已重置');
    if (client !== undefined && peer !== undefined && appParam !== undefined) {
      const transport: P2pTransport = {
        client: client,
        peer: peer,
        appParam: appParam
      };
      try {
        await this.transportEngine.unregisterFileReceiver(transport, this.fileReceiver);
      } catch (error) {
        // The peer may have disconnected while the page was closing.
      }
      try {
        await this.transportEngine.unregisterMessageReceiver(transport, this.messageReceiver);
      } catch (error) {
        // The peer may have disconnected while the page was closing.
      }
    }
  }

  static async destroyChannel(): Promise<void> {
    await destroyWearEngineChannel();
  }

  async reconnect(): Promise<void> {
    await this.stop();
    this.updateReceiverStatus('正在释放异常的 Wear Engine 通道…');
    await WearEngineRecordingReceiver.destroyChannel();
    this.updateReceiverStatus('Wear Engine 通道已重建，正在重新注册接收器…');
    await this.start();
  }

  async requestRecordingState(desiredState: string): Promise<void> {
    const client = this.p2pClient;
    const peer = this.peer;
    const appParam = this.appParam;
    if (client === undefined || peer === undefined || appParam === undefined) {
      throw new Error('手机控制通道尚未连接');
    }
    const transport: P2pTransport = {
      client: client,
      peer: peer,
      appParam: appParam
    };
    if (desiredState !== 'recording' && desiredState !== 'stopped') {
      throw new Error('不支持的录音目标状态');
    }
    const requestId = `control_${Date.now()}`;
    const actionText = desiredState === 'recording' ? '启动' : '停止';
    this.phoneControl.begin(requestId, desiredState, (expired: PhoneRecordingControlState): void => {
      this.emitControlState(expired, false, '', `手表${actionText}录音超时，请确认新包已在手表前台`);
    });
    this.emitControl(true, '', `正在拉起手表并请求${actionText}录音…`);

    try {
      const startStatus = await this.startRemoteWatchUi(transport);
      this.emitControl(true, '', `${startStatus}，正在等待手表录音控制器…`);
      await this.sendControlProbe();
    } catch (error) {
      this.emitControl(false, '', `手机控制请求失败：${wearEngineErrorMessage(error)}`);
      this.phoneControl.finish();
      throw new Error(wearEngineErrorMessage(error));
    }
  }

  private async startRemoteWatchUi(transport: P2pTransport): Promise<string> {
    const result = await this.transportEngine.startRemoteApp(transport);

    if (result.code === P2P_REMOTE_APP_NOT_INSTALLED || result.code === P2P_COMMUNICATION_FAILURE) {
      throw new Error(p2pResultMessage(result.code));
    }
    const mode = '已请求启动手表应用';
    if (result.code === P2P_REMOTE_APP_NOT_RUNNING) {
      return `${mode}（原进程未运行，返回 201）`;
    }
    if (result.code === P2P_REMOTE_APP_RUNNING) {
      return `${mode}（原进程已运行，返回 202）`;
    }
    return `${mode}（返回 ${result.code === undefined ? '空结果' : result.code}）`;
  }

  async requestWatchSync(): Promise<void> {
    const client = this.p2pClient;
    const peer = this.peer;
    const appParam = this.appParam;
    if (client === undefined || peer === undefined || appParam === undefined) {
      throw new Error('手机接收通道尚未连接');
    }
    const transport: P2pTransport = {
      client: client,
      peer: peer,
      appParam: appParam
    };
    if (this.phoneSync.inProgress()) {
      throw new Error('上一项手表文件同步仍在进行');
    }

    const requestId = Date.now().toString();
    this.activeTotal = 0;
    this.activeReceived = 0;
    this.activeSkipped = 0;
    this.activeAlreadyReceived = 0;
    this.activeRemaining = 0;
    this.activeScannedTotal = 0;
    this.expectedReceived = -1;
    this.remoteComplete = false;
    this.resetFileTransferState();
    this.startSyncHandshakeTimeout(requestId);
    this.emitProgress(true, '正在拉起手表并请求一个文件…');
    try {
      try {
        // On API 23, startRemoteApp can return UNKNOWN_ERROR when the watch app
        // is already in the foreground. The following message is the
        // authoritative check that the sync responder is ready.
        await this.transportEngine.startRemoteApp(transport);
      } catch (error) {
        // Continue and let sendMessage report the actual P2P availability.
      }
      const knownFileKeys = this.recordingStore.knownFileKeys();
      const inventoryPages = knownFileKeys.length === 0 ? 0 :
        Math.ceil(knownFileKeys.length / INVENTORY_KEYS_PER_PAGE);
      for (let page = 0; page < inventoryPages; page += 1) {
        const pageStart = page * INVENTORY_KEYS_PER_PAGE;
        const inventoryMessage: WatchSyncProtocolMessage = {
          version: WATCH_SYNC_PROTOCOL_VERSION,
          type: WATCH_SYNC_INVENTORY_PAGE,
          requestId: requestId,
          inventoryPage: page,
          inventoryPages: inventoryPages,
          knownFileKeys: knownFileKeys.slice(pageStart, pageStart + INVENTORY_KEYS_PER_PAGE)
        };
        await this.transportEngine.sendProtocolMessage(transport, inventoryMessage);
      }
      const request: WatchSyncProtocolMessage = {
        version: WATCH_SYNC_PROTOCOL_VERSION,
        type: WATCH_SYNC_REQUEST,
        requestId: requestId,
        inventoryPages: inventoryPages
      };
      await this.transportEngine.sendProtocolMessage(transport, request);
      if (this.phoneSync.requestId() === requestId) {
        this.emitProgress(true, '同步请求已发送，等待手表响应…');
      }
    } catch (error) {
      this.clearSyncHandshakeTimeout();
      this.emitProgress(false, `同步请求失败：${wearEngineErrorMessage(error)}`);
      this.phoneSync.finishRequest();
      throw new Error(wearEngineErrorMessage(error));
    }
  }

  private receiveMessage(incoming: wearEngine.P2pMessage): void {
    try {
      const message = decodeWatchSyncMessage(incoming.content);
      if (message.type === WATCH_SYNC_READY) {
        if (this.phoneControl.isActive() && !this.phoneControl.commandSent()) {
          this.sendControlProbe();
        }
        return;
      }
      if (message.type === WATCH_CONTROL_READY && this.phoneControl.matches(message.requestId)) {
        this.sendRecordingCommand();
        return;
      }
      if (message.type === WATCH_RECORDING_ACK && this.phoneControl.matches(message.requestId)) {
        this.handleRecordingAck(message);
        return;
      }
      if (message.type === WATCH_SYNC_FILE_PROGRESS && message.file !== undefined) {
        this.applyFileTransferProgress(message);
        return;
      }
      if (message.type === WATCH_AUTO_FILE && message.file !== undefined) {
        if (this.phoneSync.inProgress()) {
          this.clearSyncHandshakeTimeout();
        }
        this.addPendingFile(message.file);
        this.setTransferDescriptor(message.file, 'preparing', 0, true);
        this.emitProgress(this.phoneSync.inProgress(),
          `自动队列准备发送第 ${message.file.index} 段：${message.file.fileName}`);
        return;
      }
      if (message.type === WATCH_SYNC_FILE_FAILED && message.file !== undefined) {
        this.removePendingFile(message.file);
        const existing = this.recordingStore.findExisting(message.file);
        if (existing !== undefined) {
          this.receivedHandler(existing);
          if (message.file.automatic !== true && this.markDescriptorReceived(message.file)) {
            this.activeReceived += 1;
          }
          this.setTransferDescriptor(message.file, 'waiting_ack', 100, false);
          this.emitProgress(this.phoneSync.inProgress(),
            `文件已保存在手机，但确认回执未送达：${message.file.fileName}；手表会安全重试`);
        } else {
          this.setTransferDescriptor(message.file, 'failed', 0, false);
          this.emitProgress(this.phoneSync.inProgress(),
            `本片尚未传完，手表源文件已保留，等待补传：${message.file.fileName}`);
        }
        return;
      }
      if (message.requestId !== this.phoneSync.requestId()) {
        return;
      }
      if (message.type === WATCH_SYNC_QUEUED) {
        this.clearSyncHandshakeTimeout();
        this.transferStage = 'queued';
        this.fileTransferActive = false;
        const detail = message.message !== undefined ? message.message : '手表已将本次同步加入队列';
        this.emitProgress(true, detail);
        return;
      }
      if (message.type === WATCH_SYNC_BEGIN) {
        this.clearSyncHandshakeTimeout();
        this.activeTotal = message.total !== undefined ? message.total : 0;
        this.activeSkipped = message.skipped !== undefined ? message.skipped : 0;
        this.activeAlreadyReceived = message.alreadyReceived !== undefined ? message.alreadyReceived : 0;
        this.activeRemaining = message.remaining !== undefined ? message.remaining : 0;
        this.activeScannedTotal = message.scannedTotal !== undefined ? message.scannedTotal :
          this.activeTotal + this.activeAlreadyReceived + this.activeRemaining;
        this.emitProgress(true, `手表扫描到 ${this.activeScannedTotal} 个文件，本轮发送 ${this.activeTotal} 个` +
          `${this.activeAlreadyReceived > 0 ? `，已识别手机保存 ${this.activeAlreadyReceived} 个` : ''}`);
        return;
      }
      if (message.type === WATCH_SYNC_FILE && message.file !== undefined) {
        this.clearSyncHandshakeTimeout();
        this.addPendingFile(message.file);
        this.setTransferDescriptor(message.file, 'preparing', 0, true);
        this.emitProgress(true,
          `准备接收 ${message.file.index}/${message.file.total}：${message.file.fileName}`);
        return;
      }
      if (message.type === WATCH_SYNC_COMPLETE) {
        this.clearSyncHandshakeTimeout();
        this.expectedReceived = message.sent !== undefined ? message.sent : this.activeReceived;
        this.activeSkipped = message.skipped !== undefined ? message.skipped : this.activeSkipped;
        this.activeAlreadyReceived = message.alreadyReceived !== undefined ?
          message.alreadyReceived : this.activeAlreadyReceived;
        this.activeRemaining = message.remaining !== undefined ? message.remaining : this.activeRemaining;
        this.activeScannedTotal = message.scannedTotal !== undefined ?
          message.scannedTotal : this.activeScannedTotal;
        this.remoteComplete = true;
        this.finishIfComplete();
        return;
      }
      if (message.type === WATCH_SYNC_ERROR) {
        this.clearSyncHandshakeTimeout();
        const detail = message.message !== undefined ? message.message : '手表未能完成同步';
        const saved = this.activeTransferDescriptor !== undefined ?
          this.recordingStore.findExisting(this.activeTransferDescriptor) : undefined;
        if (saved !== undefined) {
          this.fileTransferActive = false;
          this.transferStage = 'waiting_ack';
          this.transferPercent = 100;
          this.emitProgress(false, `文件已保存在手机，但手表未收到确认回执；源文件仍保留，可重新同步补确认`);
        } else {
          this.fileTransferActive = false;
          this.transferStage = 'failed';
          this.emitProgress(false, `同步失败：${detail}；手表源文件已保留`);
        }
        this.phoneSync.finishRequest();
      }
    } catch (error) {
      this.statusHandler(`同步消息解析失败：${wearEngineErrorMessage(error)}`);
    }
  }

  private applyFileTransferProgress(message: WatchSyncProtocolMessage): void {
    const descriptor = message.file;
    if (descriptor === undefined) {
      return;
    }
    if (!this.phoneSync.accepts(message.requestId, descriptor.automatic === true)) {
      return;
    }
    if (descriptor.automatic !== true || this.phoneSync.inProgress()) {
      this.clearSyncHandshakeTimeout();
    }
    const stage = message.transferStage !== undefined ? message.transferStage : 'transferring';
    const percent = Math.max(0, Math.min(100, Math.floor(message.progress !== undefined ? message.progress : 0)));
    const active = stage !== 'completed' && stage !== 'failed';
    this.setTransferDescriptor(descriptor, stage, percent, active);
    if (message.transferredBytes !== undefined) {
      this.transferredBytes = Math.max(0, Math.min(descriptor.size, message.transferredBytes));
    }
    let detail = descriptor.automatic === true ?
      `自动队列正在发送第 ${descriptor.index} 段：${percent}%` :
      `正在传输 ${descriptor.fileName}：${percent}%`;
    if (stage === 'waiting_ack') {
      detail = descriptor.automatic === true ?
        `自动队列第 ${descriptor.index} 段已传输，手机正在保存并确认` :
        `文件已传输 100%，手机正在保存并确认：${descriptor.fileName}`;
    } else if (stage === 'completed') {
      detail = descriptor.automatic === true ? `自动队列第 ${descriptor.index} 段已确认：${descriptor.fileName}` :
        `手机已保存并完成确认：${descriptor.fileName}`;
    }
    this.emitProgress(this.phoneSync.inProgress(), detail);
  }

  private setTransferDescriptor(descriptor: WatchSyncFileDescriptor, stage: string,
    percent: number, active: boolean): void {
    this.activeTransferDescriptor = descriptor;
    this.fileTransferActive = active;
    this.transferStage = stage;
    this.transferPercent = percent;
    this.transferFileName = descriptor.fileName;
    this.transferSize = descriptor.size;
    this.transferIndex = descriptor.index;
    this.transferTotal = descriptor.total;
    this.transferredBytes = Math.min(descriptor.size, Math.floor(descriptor.size * percent / 100));
    this.transferAutomatic = descriptor.automatic === true;
    this.lastTransferProgressAt = Date.now();
  }

  private resetFileTransferState(): void {
    this.fileTransferActive = false;
    this.transferStage = 'idle';
    this.transferPercent = 0;
    this.transferFileName = '';
    this.transferredBytes = 0;
    this.transferSize = 0;
    this.transferIndex = 0;
    this.transferTotal = 0;
    this.transferAutomatic = false;
    this.lastTransferProgressAt = 0;
    this.activeTransferDescriptor = undefined;
  }

  private startSyncHandshakeTimeout(requestId: string): void {
    this.phoneSync.beginRequest(requestId, (_expiredRequestId: string): void => {
      this.fileTransferActive = false;
      this.transferStage = 'failed';
      this.emitProgress(false, '手表未在 20 秒内响应，本次同步已结束；手表文件未删除');
    });
  }

  private clearSyncHandshakeTimeout(): void {
    this.phoneSync.clearHandshake();
  }

  private async sendControlProbe(): Promise<void> {
    const client = this.p2pClient;
    const peer = this.peer;
    const appParam = this.appParam;
    if (client === undefined || peer === undefined || appParam === undefined ||
      !this.phoneControl.isActive()) {
      return;
    }
    const transport: P2pTransport = {
      client: client,
      peer: peer,
      appParam: appParam
    };
    const probe: WatchSyncProtocolMessage = {
      version: WATCH_SYNC_PROTOCOL_VERSION,
      type: WATCH_CONTROL_PROBE,
      requestId: this.phoneControl.requestId()
    };
    try {
      await this.transportEngine.sendProtocolMessage(transport, probe);
      this.emitControl(true, '', '手表已拉起，等待录音控制器就绪…');
    } catch (error) {
      this.emitControl(true, '', '手表正在启动，等待 READY 握手…');
    }
  }

  private async sendRecordingCommand(): Promise<void> {
    const client = this.p2pClient;
    const peer = this.peer;
    const appParam = this.appParam;
    if (client === undefined || peer === undefined || appParam === undefined ||
      !this.phoneControl.isActive() || this.phoneControl.commandSent()) {
      return;
    }
    const transport: P2pTransport = {
      client: client,
      peer: peer,
      appParam: appParam
    };
    this.phoneControl.markCommandSent();
    const command: WatchSyncProtocolMessage = {
      version: WATCH_SYNC_PROTOCOL_VERSION,
      type: WATCH_RECORDING_COMMAND,
      requestId: this.phoneControl.requestId(),
      desiredState: this.phoneControl.desiredState(),
      sentAt: Date.now()
    };
    try {
      await this.transportEngine.sendProtocolMessage(transport, command);
      this.emitControl(true, '', '录音命令已送达，等待手表实际状态回执…');
    } catch (error) {
      this.phoneControl.markCommandSendFailed();
      this.emitControl(true, '', `命令暂未送达，等待重连：${wearEngineErrorMessage(error)}`);
    }
  }

  private handleRecordingAck(message: WatchSyncProtocolMessage): void {
    this.phoneControl.clearTimeout();
    const succeeded = message.success === true;
    const actualState = message.actualState || '';
    const detail = message.message || (succeeded ? '手表已完成录音控制' : '手表录音控制失败');
    if (succeeded && actualState === 'pending_user_action') {
      this.emitControl(true, actualState, detail);
      this.phoneControl.beginPendingUserAction((expired: PhoneRecordingControlState): void => {
        this.emitControlState(expired, false, 'pending_user_action', '等待手表点击通知已超时，请重新发起');
      });
      return;
    }
    this.emitControl(false, actualState, detail);
    this.phoneControl.finish();
  }

  private emitControl(inProgress: boolean, actualState: string, message: string): void {
    this.emitControlState(this.phoneControl.state(), inProgress, actualState, message);
  }

  private emitControlState(controlState: PhoneRecordingControlState,
    inProgress: boolean, actualState: string, message: string): void {
    const status: WatchRecordingControlStatus = {
      requestId: controlState.requestId,
      desiredState: controlState.desiredState,
      actualState: actualState,
      inProgress: inProgress,
      message: message
    };
    this.statusHandler(message);
    this.controlStatusHandler(status);
  }

  private receiveFile(incoming: wearEngine.P2pFile): void {
    try {
      const sourceStat = fileIo.statSync(incoming.file.fd);
      if (sourceStat.size <= 0 || sourceStat.size > MAX_RECORDING_BYTES) {
        throw new Error('收到的录音为空或超过 10 MB 限制');
      }

      const descriptor = this.phoneSync.takePendingFile();
      if (descriptor !== undefined) {
        if (descriptor.size !== sourceStat.size) {
          throw new Error(`文件大小不符：期望 ${descriptor.size}，实际 ${sourceStat.size}`);
        }
        this.setTransferDescriptor(descriptor, 'saving', 100, true);
        this.emitProgress(this.phoneSync.inProgress(), `传输完成，正在安全保存：${descriptor.fileName}`);
        const existing = this.recordingStore.findExisting(descriptor);
        if (existing !== undefined) {
          this.receivedHandler(existing);
          const firstReceipt = this.markDescriptorReceived(descriptor);
          this.sendFileReceivedAck(descriptor);
          this.setTransferDescriptor(descriptor, 'waiting_ack', 100, true);
          if (descriptor.automatic === true) {
            this.emitProgress(this.phoneSync.inProgress(),
              `手机已有该文件，正在补发确认：${descriptor.fileName}`);
            return;
          }
          if (firstReceipt) {
            this.activeReceived += 1;
          }
          this.emitProgress(true,
            `已核对 ${this.activeReceived}/${this.activeTotal}：${descriptor.fileName}`);
          this.finishIfComplete();
          return;
        }
        const syncRoot = `${this.context.filesDir}/${SYNC_RECEIVE_DIRECTORY}`;
        const requestDirectory = `${syncRoot}/${descriptor.requestId}`;
        ensureDirectory(syncRoot);
        ensureDirectory(requestDirectory);
        const indexText = descriptor.index.toString().padStart(3, '0');
        const localName = `${indexText}_${safeFileName(descriptor.fileName)}`;
        const path = `${requestDirectory}/${localName}`;
        this.copyIncomingFileDurably(incoming.file.fd, path);
        const recording: ReceivedRecordingFile = {
          fileName: descriptor.fileName,
          path: path,
          size: sourceStat.size,
          durationMs: 0,
          requestId: descriptor.requestId,
          sourcePath: descriptor.relativePath,
          receivedAt: Date.now(),
          syncKey: exactWatchFileKey(descriptor.relativePath, descriptor.size),
          legacySyncKey: legacyWatchFileKey(descriptor.fileName, descriptor.size)
        };
        const stored = this.recordingStore.record(recording);
        this.receivedHandler(stored);
        const firstReceipt = this.markDescriptorReceived(descriptor);
        this.sendFileReceivedAck(descriptor);
        this.setTransferDescriptor(descriptor, 'waiting_ack', 100, true);
        if (descriptor.automatic === true) {
          this.emitProgress(this.phoneSync.inProgress(),
            `自动同步已保存，正在确认：${descriptor.fileName}`);
          return;
        }
        if (firstReceipt) {
          this.activeReceived += 1;
        }
        this.emitProgress(true,
          `已接收 ${this.activeReceived}/${this.activeTotal}：${descriptor.fileName}`);
        this.finishIfComplete();
        return;
      }

      const fileName = `received_${Date.now()}.wav`;
      const path = `${this.context.filesDir}/${fileName}`;
      this.copyIncomingFileDurably(incoming.file.fd, path);
      const recording: ReceivedRecordingFile = {
        fileName: fileName,
        path: path,
        size: sourceStat.size,
        durationMs: 0,
        requestId: 'manual',
        sourcePath: '手表手动发送',
        receivedAt: Date.now(),
        legacySyncKey: legacyWatchFileKey(fileName, sourceStat.size)
      };
      const stored = this.recordingStore.record(recording);
      this.receivedHandler(stored);
      this.statusHandler('录音接收完成，可以试听');
    } catch (error) {
      this.statusHandler(`接收失败：${error instanceof Error ? error.message : '无法保存录音'}`);
    } finally {
      closeFileChecked(incoming.file.fd);
    }
  }

  private updateReceiverStatus(status: string): void {
    this.statusHandler(status);
  }

  private finishIfComplete(): void {
    if (!this.remoteComplete || this.expectedReceived < 0 || this.activeReceived < this.expectedReceived) {
      return;
    }
    this.clearSyncHandshakeTimeout();
    this.fileTransferActive = false;
    if (this.transferFileName.length > 0) {
      this.transferStage = 'completed';
      this.transferPercent = 100;
    }
    this.emitProgress(false, `同步完成：本轮收到 ${this.activeReceived} 个；手表扫描到 ` +
      `${this.activeScannedTotal} 个文件，原文件已保留`);
    this.phoneSync.finishRequest();
  }

  private markDescriptorReceived(descriptor: WatchSyncFileDescriptor): boolean {
    return this.phoneSync.markReceived(descriptor);
  }

  private sendFileReceivedAck(descriptor: WatchSyncFileDescriptor): void {
    const client = this.p2pClient;
    const peer = this.peer;
    const appParam = this.appParam;
    if (client === undefined || peer === undefined || appParam === undefined) {
      this.setTransferDescriptor(descriptor, 'waiting_ack', 100, false);
      this.emitProgress(this.phoneSync.inProgress(), '文件已保存，等待 Wear Engine 重连后补发确认回执');
      return;
    }
    const transport: P2pTransport = {
      client: client,
      peer: peer,
      appParam: appParam
    };
    const ack: WatchSyncProtocolMessage = {
      version: WATCH_SYNC_PROTOCOL_VERSION,
      type: WATCH_SYNC_FILE_RECEIVED,
      requestId: descriptor.requestId,
      file: descriptor
    };
    this.transportEngine.sendProtocolMessage(transport, ack).catch(() => {
      this.setTransferDescriptor(descriptor, 'waiting_ack', 100, false);
      this.emitProgress(this.phoneSync.inProgress(), '文件已保存，确认回执暂未送达，手表将安全重试');
    });
  }

  private copyIncomingFileDurably(sourceFd: number, finalPath: string): void {
    copyFileAtomically(sourceFd, finalPath);
  }

  private removePendingFile(descriptor: WatchSyncFileDescriptor): void {
    this.phoneSync.removePendingFile(descriptor);
  }

  private addPendingFile(descriptor: WatchSyncFileDescriptor): void {
    this.phoneSync.addPendingFile(descriptor);
  }

  private emitProgress(inProgress: boolean, message: string): void {
    const progress: WatchSyncProgress = {
      requestId: this.phoneSync.requestId(),
      total: this.activeTotal,
      received: this.activeReceived,
      skipped: this.activeSkipped,
      alreadyReceived: this.activeAlreadyReceived,
      remaining: this.activeRemaining,
      scannedTotal: this.activeScannedTotal,
      inProgress: inProgress,
      message: message,
      fileTransferActive: this.fileTransferActive,
      transferStage: this.transferStage,
      transferPercent: this.transferPercent,
      transferFileName: this.transferFileName,
      transferredBytes: this.transferredBytes,
      transferSize: this.transferSize,
      transferIndex: this.transferIndex,
      transferTotal: this.transferTotal,
      automatic: this.transferAutomatic,
      lastProgressAt: this.lastTransferProgressAt
    };
    this.statusHandler(message);
    this.syncProgressHandler(progress);
  }
}
