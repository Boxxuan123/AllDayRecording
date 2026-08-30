import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { wearEngine } from '@kit.WearEngine';
import {
  ReceivedRecordingFile,
  RecordingFile,
  WatchRecordingControlStatus,
  WatchSyncFileDescriptor,
  WatchSyncProgress
} from '../models/RecordingModels';
import { copyFileAtomically } from '../shared/io/AtomicFileWriter';
import {
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
  decodeWatchSyncMessage,
  exactWatchFileKey,
  legacyWatchFileKey
} from '../sync/protocol/WatchFileSyncProtocol';
import {
  PhoneReceiverLifecycleCoordinator,
  PhoneSyncCoordinator
} from '../sync/phone/PhoneSyncCoordinator';
import {
  WATCH_CONTROL_BUSY,
  WATCH_CONTROL_REPLAY,
  PhoneRecordingControlCoordinator,
  PhoneRecordingControlState,
  WatchRecordingControlCoordinator
} from '../sync/control/WatchRecordingControlCoordinator';
import {
  AUTOMATIC_QUEUE_DAMAGED,
  AUTOMATIC_QUEUE_ENQUEUED,
  AUTOMATIC_QUEUE_ENQUEUED_NOT_SAVED,
  AUTOMATIC_QUEUE_INVALID,
  AUTOMATIC_QUEUE_REJECTED,
  AutomaticSyncQueue,
  AutomaticSyncQueueEntry
} from '../sync/watch/AutomaticSyncQueue';
import {
  WATCH_MANUAL_DUPLICATE,
  WATCH_MANUAL_QUEUED,
  WatchFileAckCoordinator,
  WatchManualSyncDecision,
  WatchManualSyncRequest,
  WatchSyncCoordinator,
  watchFileTransferKey
} from '../sync/watch/WatchSyncCoordinator';
import {
  P2P_COMMUNICATION_FAILURE,
  P2P_COMMUNICATION_SUCCESS,
  P2P_REMOTE_APP_NOT_INSTALLED,
  P2P_REMOTE_APP_NOT_RUNNING,
  P2P_REMOTE_APP_RUNNING,
  WearEngineConnection,
  WearEngineTransport,
  destroyWearEngineChannel,
  isP2pCommunicationError,
  p2pResultMessage,
  shouldRetryReceiverConnection,
  wearEngineErrorMessage
} from '../sync/transport/WearEngineTransport';
import { ReceivedRecordingStore, SYNC_RECEIVE_DIRECTORY } from './ReceivedRecordingStore';

export { wearEngineErrorMessage } from '../sync/transport/WearEngineTransport';

const MAX_RECORDING_BYTES = 10 * 1024 * 1024;
// Reliability-first fallback: keep only one Wear Engine file task in each manual
// sync request. Once a single file is durably acknowledged, the phone can issue
// another request. The source file on the watch is never deleted.
const MAX_SYNC_FILE_COUNT = 1;
const INVENTORY_KEYS_PER_PAGE = 24;
const RECEIVER_CONNECT_ATTEMPTS = 5;
const RECEIVER_RETRY_BASE_DELAY_MS = 800;
const TRANSFER_RETRY_ATTEMPTS = 3;
const TRANSFER_RETRY_BASE_DELAY_MS = 800;
// File movement and the durable phone ACK are separate phases. Transfer activity
// refreshes its own watchdog; the ACK timer starts only after Wear Engine reaches 100%.
const TRANSFER_PROGRESS_STALL_TIMEOUT_MS = 60 * 1000;
const TRANSFER_FILE_ACK_TIMEOUT_MS = 60 * 1000;
const SYNC_HANDSHAKE_TIMEOUT_MS = 20 * 1000;
const TRANSFER_PROGRESS_STEP = 5;
const TRANSFER_PROGRESS_MESSAGE_INTERVAL_MS = 1000;
const CONTROL_COMMAND_TIMEOUT_MS = 20 * 1000;
const PENDING_USER_ACTION_TIMEOUT_MS = 5 * 60 * 1000;

export type RecordingReceivedHandler = (recording: ReceivedRecordingFile) => void;
export type TransferStatusHandler = (status: string) => void;
export type WatchSyncProgressHandler = (progress: WatchSyncProgress) => void;
export type WatchRecordingControlStatusHandler = (status: WatchRecordingControlStatus) => void;

export interface WatchRecordingControlResult {
  actualState: string;
  sessionId: string;
  message: string;
}

export type WatchRecordingControlHandler =
  (desiredState: string, requestId: string) => Promise<WatchRecordingControlResult>;

interface SyncSourceFile extends RecordingFile {
  relativePath: string;
}

interface SyncScanResult {
  files: Array<SyncSourceFile>;
  skippedCount: number;
  alreadyReceivedCount: number;
  remainingCount: number;
  scannedCount: number;
}

type P2pTransport = WearEngineConnection;

function waitForReceiverRetry(delayMs: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(resolve, delayMs);
  });
}

function scanSyncableFiles(filesDirectory: string, knownFileKeys: Array<string>): SyncScanResult {
  const result: SyncScanResult = {
    files: [],
    skippedCount: 0,
    alreadyReceivedCount: 0,
    remainingCount: 0,
    scannedCount: 0
  };
  collectSyncableFiles(filesDirectory, '', result);
  result.files.sort((left: SyncSourceFile, right: SyncSourceFile) =>
    left.relativePath.localeCompare(right.relativePath));
  result.scannedCount = result.files.length;

  const missing: Array<SyncSourceFile> = [];
  for (let index = 0; index < result.files.length; index += 1) {
    const source = result.files[index];
    const exactKey = exactWatchFileKey(source.relativePath, source.size);
    const exactKnown = knownFileKeys.indexOf(exactKey) >= 0;
    if (exactKnown) {
      result.alreadyReceivedCount += 1;
    } else {
      missing.push(source);
    }
  }
  result.files = missing;
  if (result.files.length > MAX_SYNC_FILE_COUNT) {
    result.remainingCount = result.files.length - MAX_SYNC_FILE_COUNT;
    result.files = result.files.slice(0, MAX_SYNC_FILE_COUNT);
  }
  return result;
}

function collectSyncableFiles(filesDirectory: string, relativeDirectory: string, result: SyncScanResult): void {
  const directory = relativeDirectory.length > 0 ? `${filesDirectory}/${relativeDirectory}` : filesDirectory;
  const entries = listFilesChecked(directory);
  for (let index = 0; index < entries.length; index += 1) {
    const fileName = entries[index];
    if (relativeDirectory.length === 0 && fileName === SYNC_RECEIVE_DIRECTORY) {
      continue;
    }
    const relativePath = relativeDirectory.length > 0 ? `${relativeDirectory}/${fileName}` : fileName;
    const path = `${filesDirectory}/${relativePath}`;
    const stat = statFileChecked(path);
    if (isDirectoryChecked(stat)) {
      collectSyncableFiles(filesDirectory, relativePath, result);
      continue;
    }
    const lowerName = fileName.toLowerCase();
    if (!lowerName.endsWith('.wav') && !lowerName.endsWith('.m4a')) {
      continue;
    }
    if (lowerName.endsWith('.part') || stat.size <= 0 || stat.size > MAX_RECORDING_BYTES) {
      result.skippedCount += 1;
      continue;
    }
    result.files.push({
      fileName: fileName,
      path: path,
      relativePath: relativePath,
      size: stat.size,
      durationMs: 0
    });
  }
}

function ensureDirectory(path: string): void {
  if (!pathExistsChecked(path)) {
    createDirectoryChecked(path);
  }
}

function listFilesChecked(path: string): Array<string> {
  try {
    return fileIo.listFileSync(path);
  } catch (error) {
    throw transferFileError(error);
  }
}

function statFileChecked(path: string): fileIo.Stat {
  try {
    return fileIo.statSync(path);
  } catch (error) {
    throw transferFileError(error);
  }
}

function isDirectoryChecked(stat: fileIo.Stat): boolean {
  try {
    return stat.isDirectory();
  } catch (error) {
    throw transferFileError(error);
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

function openReadOnlyChecked(path: string): fileIo.File {
  try {
    return fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
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

export class WearEngineRecordingSender {
  private context: common.UIAbilityContext;
  private transportEngine: WearEngineTransport;
  private statusHandler: TransferStatusHandler | undefined;
  private p2pClient: wearEngine.P2pClient | undefined = undefined;
  private peer: wearEngine.Device | undefined = undefined;
  private appParam: wearEngine.P2pAppParam | undefined = undefined;
  private syncCoordinator: WatchSyncCoordinator = new WatchSyncCoordinator();
  private inventoryRequestId: string = '';
  private inventoryPageCount: number = 0;
  private inventoryPagesReceived: Array<number> = [];
  private inventoryKnownKeys: Array<string> = [];
  private automaticQueue: AutomaticSyncQueue;
  private controlHandler: WatchRecordingControlHandler | undefined;
  private controlCoordinator: WatchRecordingControlCoordinator = new WatchRecordingControlCoordinator();
  private fileAckCoordinator: WatchFileAckCoordinator = new WatchFileAckCoordinator(
    TRANSFER_PROGRESS_STALL_TIMEOUT_MS, TRANSFER_FILE_ACK_TIMEOUT_MS);
  private activeFileLastProgressSent: number = -1;
  private activeFileLastProgressSentAt: number = 0;
  private messageReceiver = (incoming: wearEngine.P2pMessage): void => {
    this.receiveMessage(incoming);
  };

  constructor(context: common.UIAbilityContext, statusHandler?: TransferStatusHandler,
    controlHandler?: WatchRecordingControlHandler) {
    this.context = context;
    this.transportEngine = new WearEngineTransport(context);
    this.automaticQueue = new AutomaticSyncQueue(context.filesDir);
    this.statusHandler = statusHandler;
    this.controlHandler = controlHandler;
  }

  async start(): Promise<void> {
    const restoreStatus = this.automaticQueue.restore();
    if (restoreStatus === AUTOMATIC_QUEUE_DAMAGED) {
      this.updateStatus('自动同步队列清单无法读取，录音文件未受影响');
    } else if (restoreStatus === AUTOMATIC_QUEUE_INVALID) {
      this.updateStatus('自动同步队列清单版本无效，录音文件未受影响');
    }
    if (this.p2pClient !== undefined) {
      return;
    }
    const transport = await this.createTransport();
    await this.transportEngine.registerMessageReceiver(transport, this.messageReceiver);
    this.peer = transport.peer;
    this.appParam = transport.appParam;
    this.p2pClient = transport.client;
    const readyMessage: WatchSyncProtocolMessage = {
      version: WATCH_SYNC_PROTOCOL_VERSION,
      type: WATCH_SYNC_READY,
      requestId: ''
    };
    try {
      await this.transportEngine.sendProtocolMessage(transport, readyMessage);
    } catch (error) {
      // The phone page may not be open yet. The registered receiver remains ready for a later request.
    }
    if (this.automaticQueue.count() > 0) {
      this.updateStatus(`已恢复自动同步队列（${this.automaticQueue.count()}），准备续传`);
      this.drainAutomaticQueue();
    }
  }

  async stop(): Promise<void> {
    const client = this.p2pClient;
    const peer = this.peer;
    const appParam = this.appParam;
    this.p2pClient = undefined;
    this.peer = undefined;
    this.appParam = undefined;
    if (client !== undefined && peer !== undefined && appParam !== undefined) {
      try {
        await this.transportEngine.unregisterMessageReceiver({
          client: client,
          peer: peer,
          appParam: appParam
        }, this.messageReceiver);
      } catch (error) {
        // The peer may have disconnected while the page was closing.
      }
    }
  }

  async send(recording: RecordingFile): Promise<void> {
    if (this.syncCoordinator.isBusy()) {
      throw new Error('正在同步其他录音，请稍后再手动发送');
    }
    const transport = await this.getTransport();
    await this.transferRecordingWithRetry(transport, recording);
  }

  enqueueAutomatic(recording: RecordingFile): void {
    const result = this.automaticQueue.enqueue(recording);
    if (result === AUTOMATIC_QUEUE_REJECTED) {
      this.updateStatus('分片尚未完整封口，未加入自动同步');
      return;
    }
    if (result !== AUTOMATIC_QUEUE_ENQUEUED && result !== AUTOMATIC_QUEUE_ENQUEUED_NOT_SAVED) {
      return;
    }
    this.updateStatus(result === AUTOMATIC_QUEUE_ENQUEUED ?
      `已封口，等待自动同步（${this.automaticQueue.count()}）` :
      '录音已封口，但自动队列清单保存失败；录音文件已保留');
    this.drainAutomaticQueue();
  }

  async reportRecordingControlResult(requestId: string, desiredState: string, success: boolean,
    result: WatchRecordingControlResult): Promise<void> {
    if (requestId.length === 0) {
      return;
    }
    const transport = await this.getTransport();
    const ack = await this.sendRecordingAck(transport, requestId, desiredState, success,
      result.actualState, result.sessionId, result.message);
    this.controlCoordinator.complete(requestId, ack);
    this.updateStatus(result.message);
  }

  private receiveMessage(incoming: wearEngine.P2pMessage): void {
    try {
      const message = decodeWatchSyncMessage(incoming.content);
      if (message.type === WATCH_SYNC_FILE_RECEIVED && message.file !== undefined) {
        this.completeFileTransferAck(message.file);
        return;
      }
      if (message.type === WATCH_CONTROL_PROBE && message.requestId.length > 0) {
        this.sendControlReady(message.requestId);
        return;
      }
      if (message.type === WATCH_RECORDING_COMMAND && message.requestId.length > 0) {
        this.processRecordingControl(message);
        return;
      }
      if (message.type === WATCH_PHONE_READY) {
        this.drainAutomaticQueue();
        return;
      }
      if (message.type === WATCH_SYNC_INVENTORY_PAGE && message.requestId.length > 0) {
        this.receiveSyncInventoryPage(message);
        return;
      }
      if (message.type !== WATCH_SYNC_REQUEST || message.requestId.length === 0) {
        return;
      }
      const knownFileKeys = this.consumeSyncInventory(message.requestId, message.inventoryPages || 0);
      this.processSyncRequest(message.requestId, knownFileKeys);
    } catch (error) {
      this.updateStatus(`同步请求解析失败：${wearEngineErrorMessage(error)}`);
    }
  }

  private receiveSyncInventoryPage(message: WatchSyncProtocolMessage): void {
    const page = message.inventoryPage !== undefined ? message.inventoryPage : -1;
    const pages = message.inventoryPages !== undefined ? message.inventoryPages : 0;
    const keys = message.knownFileKeys !== undefined ? message.knownFileKeys : [];
    if (page < 0 || pages <= 0 || page >= pages || keys.length > INVENTORY_KEYS_PER_PAGE) {
      throw new Error('手机已收文件清单分页无效');
    }
    if (this.inventoryRequestId !== message.requestId) {
      this.inventoryRequestId = message.requestId;
      this.inventoryPageCount = pages;
      this.inventoryPagesReceived = [];
      this.inventoryKnownKeys = [];
    }
    if (this.inventoryPageCount !== pages || this.inventoryPagesReceived.indexOf(page) >= 0) {
      return;
    }
    for (let index = 0; index < keys.length; index += 1) {
      const key = keys[index];
      if (key.length > 0 && this.inventoryKnownKeys.indexOf(key) < 0) {
        this.inventoryKnownKeys.push(key);
      }
    }
    this.inventoryPagesReceived.push(page);
  }

  private consumeSyncInventory(requestId: string, expectedPages: number): Array<string> {
    if (expectedPages === 0) {
      return [];
    }
    if (this.inventoryRequestId !== requestId || this.inventoryPageCount !== expectedPages ||
      this.inventoryPagesReceived.length !== expectedPages) {
      throw new Error('手机已收文件清单未完整到达，请重新同步');
    }
    const keys = this.inventoryKnownKeys.slice();
    this.inventoryRequestId = '';
    this.inventoryPageCount = 0;
    this.inventoryPagesReceived = [];
    this.inventoryKnownKeys = [];
    return keys;
  }

  private async sendControlReady(requestId: string): Promise<void> {
    try {
      const transport = await this.getTransport();
      const ready: WatchSyncProtocolMessage = {
        version: WATCH_SYNC_PROTOCOL_VERSION,
        type: WATCH_CONTROL_READY,
        requestId: requestId
      };
      await this.transportEngine.sendProtocolMessage(transport, ready);
    } catch (error) {
      this.updateStatus(`手机控制握手失败：${wearEngineErrorMessage(error)}`);
    }
  }

  private async processRecordingControl(command: WatchSyncProtocolMessage): Promise<void> {
    let transport: P2pTransport;
    try {
      transport = await this.getTransport();
    } catch (error) {
      this.updateStatus(`手机控制连接失败：${wearEngineErrorMessage(error)}`);
      return;
    }
    const decision = this.controlCoordinator.inspect(command.requestId);
    if (decision === WATCH_CONTROL_REPLAY) {
      const lastAck = this.controlCoordinator.lastAck();
      if (lastAck !== undefined) {
        await this.transportEngine.sendProtocolMessage(transport, lastAck);
      }
      return;
    }
    if (decision === WATCH_CONTROL_BUSY) {
      await this.sendRecordingAck(transport, command.requestId, command.desiredState || '', false,
        '', '', '手表正在处理另一项录音控制');
      return;
    }
    const desiredState = command.desiredState || '';
    if (desiredState !== 'recording' && desiredState !== 'stopped') {
      await this.sendRecordingAck(transport, command.requestId, desiredState, false,
        '', '', '不支持的录音目标状态');
      return;
    }
    if (this.controlHandler === undefined) {
      await this.sendRecordingAck(transport, command.requestId, desiredState, false,
        '', '', '手表录音控制器尚未就绪');
      return;
    }
    this.controlCoordinator.begin();
    try {
      const result = await this.controlHandler(desiredState, command.requestId);
      const ack = await this.sendRecordingAck(transport, command.requestId, desiredState, true,
        result.actualState, result.sessionId, result.message);
      this.controlCoordinator.complete(command.requestId, ack);
      this.updateStatus(result.message);
    } catch (error) {
      const message = wearEngineErrorMessage(error);
      const ack = await this.sendRecordingAck(transport, command.requestId, desiredState, false,
        '', '', message);
      this.controlCoordinator.complete(command.requestId, ack);
      this.updateStatus(`手机控制失败：${message}`);
    } finally {
      this.controlCoordinator.finishWithoutAck();
    }
  }

  private async sendRecordingAck(transport: P2pTransport, requestId: string, desiredState: string,
    success: boolean, actualState: string, sessionId: string, message: string): Promise<WatchSyncProtocolMessage> {
    const ack: WatchSyncProtocolMessage = {
      version: WATCH_SYNC_PROTOCOL_VERSION,
      type: WATCH_RECORDING_ACK,
      requestId: requestId,
      desiredState: desiredState,
      actualState: actualState,
      success: success,
      sessionId: sessionId,
      message: message
    };
    await this.transportEngine.sendProtocolMessage(transport, ack);
    return ack;
  }

  private async processSyncRequest(requestId: string, knownFileKeys: Array<string>): Promise<void> {
    const decision: WatchManualSyncDecision = this.syncCoordinator.requestManual(requestId, knownFileKeys);
    if (decision.action === WATCH_MANUAL_DUPLICATE) {
      return;
    }
    if (decision.action === WATCH_MANUAL_QUEUED) {
      const detail = this.syncCoordinator.isAutomatic() ?
        '当前自动分片发送完成后，将优先执行本次手机同步' :
        '当前手机同步完成后，将继续执行本次请求';
      this.updateStatus(detail);
      try {
        const queuedTransport = await this.getTransport();
        await this.sendSyncQueued(queuedTransport, requestId, detail);
      } catch (error) {
        // The request stays queued even if the non-authoritative status hint cannot be delivered.
      }
      return;
    }
    await this.runManualSync(decision.request);
  }

  private async runManualSync(request: WatchManualSyncRequest): Promise<void> {
    const requestId = request.requestId;
    const knownFileKeys = request.knownFileKeys;
    let transport: P2pTransport;
    try {
      transport = await this.getTransport();
    } catch (error) {
      this.updateStatus(`无法响应手机同步：${wearEngineErrorMessage(error)}`);
      this.syncCoordinator.finishCurrent();
      if (!this.startPendingSyncIfIdle()) {
        this.drainAutomaticQueue();
      }
      return;
    }
    let sentCount: number = 0;
    let skippedCount: number = 0;
    try {
      const scan = scanSyncableFiles(this.context.filesDir, knownFileKeys);
      skippedCount = scan.skippedCount;
      const beginMessage: WatchSyncProtocolMessage = {
        version: WATCH_SYNC_PROTOCOL_VERSION,
        type: WATCH_SYNC_BEGIN,
        requestId: requestId,
        total: scan.files.length,
        skipped: skippedCount,
        alreadyReceived: scan.alreadyReceivedCount,
        remaining: scan.remainingCount,
        scannedTotal: scan.scannedCount
      };
      await this.transportEngine.sendProtocolMessage(transport, beginMessage);
      this.updateStatus(`手表扫描到 ${scan.scannedCount} 个文件，本轮发送 ${scan.files.length} 个` +
        `${scan.alreadyReceivedCount > 0 ? `，已识别手机保存 ${scan.alreadyReceivedCount} 个` : ''}`);

      for (let index = 0; index < scan.files.length; index += 1) {
        const source = scan.files[index];
        const descriptor: WatchSyncFileDescriptor = {
          requestId: requestId,
          index: index + 1,
          total: scan.files.length,
          relativePath: source.relativePath,
          fileName: source.fileName,
          size: source.size
        };
        const fileMessage: WatchSyncProtocolMessage = {
          version: WATCH_SYNC_PROTOCOL_VERSION,
          type: WATCH_SYNC_FILE,
          requestId: requestId,
          file: descriptor
        };
        try {
          transport = await this.transferDescribedRecordingWithRetry(
            transport, fileMessage, descriptor, source);
          sentCount += 1;
          this.removeAutomaticFile(source.path);
          this.updateStatus(`同步 ${sentCount}/${scan.files.length}，手表原文件保留`);
        } catch (error) {
          if (isP2pCommunicationError(error)) {
            throw new Error(wearEngineErrorMessage(error));
          }
          skippedCount += 1;
          await this.sendFileFailed(transport, descriptor);
        }
      }

      const completeMessage: WatchSyncProtocolMessage = {
        version: WATCH_SYNC_PROTOCOL_VERSION,
        type: WATCH_SYNC_COMPLETE,
        requestId: requestId,
        sent: sentCount,
        skipped: skippedCount,
        alreadyReceived: scan.alreadyReceivedCount,
        remaining: scan.remainingCount,
        scannedTotal: scan.scannedCount
      };
      await this.transportEngine.sendProtocolMessage(transport, completeMessage);
      this.updateStatus(`手机同步完成 ${sentCount} 个，手表文件全部保留`);
    } catch (error) {
      await this.sendSyncError(transport, requestId, wearEngineErrorMessage(error));
      this.updateStatus(`手机同步失败，手表文件已保留：${wearEngineErrorMessage(error)}`);
    } finally {
      this.syncCoordinator.finishCurrent();
      if (!this.startPendingSyncIfIdle()) {
        this.drainAutomaticQueue();
      }
    }
  }

  private async drainAutomaticQueue(): Promise<void> {
    if (this.automaticQueue.count() === 0 || !this.syncCoordinator.beginAutomatic()) {
      return;
    }
    try {
      let transport = await this.getTransport();
      while (this.syncCoordinator.isAutomatic() && !this.syncCoordinator.hasPendingManual() &&
        this.automaticQueue.count() > 0) {
        const source: AutomaticSyncQueueEntry | undefined = this.automaticQueue.first();
        if (source === undefined) {
          break;
        }
        const queuePosition = this.automaticQueue.completedCount() + 1;
        const queueTotal = this.automaticQueue.completedCount() + this.automaticQueue.count();
        const descriptor: WatchSyncFileDescriptor = {
          requestId: this.automaticQueue.requestId(),
          index: queuePosition,
          total: queueTotal,
          relativePath: source.relativePath,
          fileName: source.fileName,
          size: source.size,
          automatic: true
        };
        const fileMessage: WatchSyncProtocolMessage = {
          version: WATCH_SYNC_PROTOCOL_VERSION,
          type: WATCH_AUTO_FILE,
          requestId: descriptor.requestId,
          file: descriptor
        };
        try {
          this.updateStatus(`自动队列正在发送第 ${queuePosition} 段（共 ${queueTotal} 段）`);
          transport = await this.transferDescribedRecordingWithRetry(
            transport, fileMessage, descriptor, source);
          const queueSaved = this.automaticQueue.complete(source.path);
          this.updateStatus(queueSaved ? `自动同步完成第 ${queuePosition} 段：${source.fileName}，手表原文件保留` :
            `第 ${queuePosition} 段已确认，但队列清单更新失败；录音文件仍保留`);
        } catch (error) {
          await this.sendFileFailed(transport, descriptor);
          this.updateStatus(`自动同步待重试，手表原文件已保留：${wearEngineErrorMessage(error)}`);
          break;
        }
      }
    } catch (error) {
      this.updateStatus(`自动同步待重试，手表原文件已保留：${wearEngineErrorMessage(error)}`);
    } finally {
      this.syncCoordinator.finishCurrent();
      this.startPendingSyncIfIdle();
    }
  }

  private startPendingSyncIfIdle(): boolean {
    const pending = this.syncCoordinator.takePendingManual();
    if (pending === undefined) {
      return false;
    }
    this.runManualSync(pending);
    return true;
  }

  private removeAutomaticFile(path: string): void {
    this.automaticQueue.removeIfQueued(path);
  }

  private async sendFileFailed(transport: P2pTransport, descriptor: WatchSyncFileDescriptor): Promise<void> {
    const failedMessage: WatchSyncProtocolMessage = {
      version: WATCH_SYNC_PROTOCOL_VERSION,
      type: WATCH_SYNC_FILE_FAILED,
      requestId: descriptor.requestId,
      file: descriptor
    };
    try {
      await this.transportEngine.sendProtocolMessage(transport, failedMessage);
    } catch (error) {
      // A later phone reconnect retries the still-queued source; the watch file remains untouched.
    }
  }

  private async sendSyncError(transport: P2pTransport, requestId: string, message: string): Promise<void> {
    const errorMessage: WatchSyncProtocolMessage = {
      version: WATCH_SYNC_PROTOCOL_VERSION,
      type: WATCH_SYNC_ERROR,
      requestId: requestId,
      message: message
    };
    try {
      await this.transportEngine.sendProtocolMessage(transport, errorMessage);
    } catch (error) {
      // Preserve the local status even when the peer has disconnected.
    }
  }

  private async sendSyncQueued(transport: P2pTransport, requestId: string, message: string): Promise<void> {
    const queuedMessage: WatchSyncProtocolMessage = {
      version: WATCH_SYNC_PROTOCOL_VERSION,
      type: WATCH_SYNC_QUEUED,
      requestId: requestId,
      message: message
    };
    try {
      await this.transportEngine.sendProtocolMessage(transport, queuedMessage);
    } catch (error) {
      // The queued request remains authoritative and starts after the in-flight file even if this hint is lost.
    }
  }

  private async getTransport(): Promise<P2pTransport> {
    if (this.p2pClient !== undefined && this.peer !== undefined && this.appParam !== undefined) {
      return {
        peer: this.peer,
        client: this.p2pClient,
        appParam: this.appParam
      };
    }
    return this.createTransport();
  }

  private async createTransport(): Promise<P2pTransport> {
    return this.transportEngine.connect(true);
  }

  private async reacquireTransport(): Promise<P2pTransport> {
    const transport = await this.createTransport();
    this.peer = transport.peer;
    this.appParam = transport.appParam;
    this.p2pClient = transport.client;
    return transport;
  }

  private async sendProtocolMessageWithRetry(transport: P2pTransport,
    message: WatchSyncProtocolMessage): Promise<P2pTransport> {
    let currentTransport = transport;
    let lastError: Object = new Error('Wear Engine 消息发送失败');
    for (let attempt = 1; attempt <= TRANSFER_RETRY_ATTEMPTS; attempt += 1) {
      try {
        await this.transportEngine.sendProtocolMessage(currentTransport, message);
        return currentTransport;
      } catch (error) {
        lastError = error as Object;
        if (!isP2pCommunicationError(lastError) || attempt >= TRANSFER_RETRY_ATTEMPTS) {
          break;
        }
        this.updateStatus(`Wear Engine 通信中断，正在重连并重试消息（${attempt}/${TRANSFER_RETRY_ATTEMPTS}）`);
        await waitForReceiverRetry(TRANSFER_RETRY_BASE_DELAY_MS * attempt);
        try {
          currentTransport = await this.reacquireTransport();
        } catch (reconnectError) {
          lastError = reconnectError as Object;
        }
      }
    }
    throw new Error(wearEngineErrorMessage(lastError));
  }

  private async transferRecordingWithRetry(transport: P2pTransport,
    recording: RecordingFile): Promise<P2pTransport> {
    let currentTransport = transport;
    let lastError: Object = new Error('Wear Engine 文件传输失败');
    for (let attempt = 1; attempt <= TRANSFER_RETRY_ATTEMPTS; attempt += 1) {
      try {
        await this.transferRecording(currentTransport, recording);
        return currentTransport;
      } catch (error) {
        lastError = error as Object;
        if (!isP2pCommunicationError(lastError) || attempt >= TRANSFER_RETRY_ATTEMPTS) {
          break;
        }
        this.updateStatus(`Wear Engine 通信中断，正在重连并重试文件（${attempt}/${TRANSFER_RETRY_ATTEMPTS}）`);
        await waitForReceiverRetry(TRANSFER_RETRY_BASE_DELAY_MS * attempt);
        try {
          currentTransport = await this.reacquireTransport();
        } catch (reconnectError) {
          lastError = reconnectError as Object;
        }
      }
    }
    throw new Error(wearEngineErrorMessage(lastError));
  }

  private async transferDescribedRecordingWithRetry(transport: P2pTransport,
    fileMessage: WatchSyncProtocolMessage, descriptor: WatchSyncFileDescriptor,
    recording: RecordingFile): Promise<P2pTransport> {
    let currentTransport = transport;
    let lastError: Object = new Error('Wear Engine 文件传输失败');
    for (let attempt = 1; attempt <= TRANSFER_RETRY_ATTEMPTS; attempt += 1) {
      try {
        await this.transportEngine.sendProtocolMessage(currentTransport, fileMessage);
        await this.transferRecordingAwaitingAck(currentTransport, recording, descriptor);
        return currentTransport;
      } catch (error) {
        lastError = error as Object;
        if (!isP2pCommunicationError(lastError) || attempt >= TRANSFER_RETRY_ATTEMPTS) {
          break;
        }
        this.updateStatus(`文件回执未完成，正在重连并重试（${attempt}/${TRANSFER_RETRY_ATTEMPTS}）`);
        await waitForReceiverRetry(TRANSFER_RETRY_BASE_DELAY_MS * attempt);
        try {
          currentTransport = await this.reacquireTransport();
        } catch (reconnectError) {
          lastError = reconnectError as Object;
        }
      }
    }
    throw new Error(wearEngineErrorMessage(lastError));
  }

  private async transferRecordingAwaitingAck(transport: P2pTransport, recording: RecordingFile,
    descriptor: WatchSyncFileDescriptor): Promise<void> {
    if (recording.size <= 0 || recording.size > MAX_RECORDING_BYTES) {
      throw new Error('录音文件为空或超过 10 MB 限制');
    }
    if (this.fileAckCoordinator.activeKey().length > 0) {
      throw new Error('上一片文件仍在等待手机持久化回执');
    }

    const ackKey = watchFileTransferKey(descriptor);
    const inputFile = openReadOnlyChecked(recording.path);
    try {
      await new Promise<void>((resolve, reject) => {
        this.fileAckCoordinator.begin(descriptor, resolve, reject);
        this.activeFileLastProgressSent = -1;
        this.activeFileLastProgressSentAt = 0;
        this.reportFileTransferProgress(transport, descriptor, 0, 'transferring', true);

        this.transportEngine.transferFile(transport, inputFile,
          (error: BusinessError, result: wearEngine.P2pResult) => {
            if (error) {
              this.fileAckCoordinator.failForKey(ackKey, new Error(wearEngineErrorMessage(error)));
              return;
            }
            if (result.code !== undefined && result.code !== P2P_COMMUNICATION_SUCCESS) {
              this.fileAckCoordinator.failForKey(ackKey, new Error(p2pResultMessage(result.code)));
              return;
            }
            if (result.progress !== undefined) {
              this.handleFileTransferProgress(transport, descriptor, ackKey, result.progress);
              return;
            }
            // API 23 can report a successful final callback with an empty result. This only
            // ends the transfer phase; the file stays open until the phone's durable ACK.
            this.handleFileTransferProgress(transport, descriptor, ackKey, 100);
          });
      });
      this.reportFileTransferProgress(transport, descriptor, 100, 'completed', true);
    } finally {
      this.clearFileTransferAck();
      closeFileChecked(inputFile.fd);
    }
  }

  private handleFileTransferProgress(transport: P2pTransport, descriptor: WatchSyncFileDescriptor,
    ackKey: string, progress: number): void {
    const bounded = Math.max(0, Math.min(100, Math.floor(progress)));
    if (ackKey !== this.fileAckCoordinator.activeKey() ||
      !this.fileAckCoordinator.progress(descriptor, bounded)) {
      return;
    }
    if (bounded >= 100) {
      this.reportFileTransferProgress(transport, descriptor, 100, 'waiting_ack', true);
      return;
    }
    this.reportFileTransferProgress(transport, descriptor, bounded, 'transferring', false);
  }

  private reportFileTransferProgress(transport: P2pTransport, descriptor: WatchSyncFileDescriptor,
    progress: number, stage: string, force: boolean): void {
    const now = Date.now();
    if (!force && progress < this.activeFileLastProgressSent + TRANSFER_PROGRESS_STEP &&
      now - this.activeFileLastProgressSentAt < TRANSFER_PROGRESS_MESSAGE_INTERVAL_MS) {
      return;
    }
    this.activeFileLastProgressSent = progress;
    this.activeFileLastProgressSentAt = now;
    const progressMessage: WatchSyncProtocolMessage = {
      version: WATCH_SYNC_PROTOCOL_VERSION,
      type: WATCH_SYNC_FILE_PROGRESS,
      requestId: descriptor.requestId,
      file: descriptor,
      progress: progress,
      transferredBytes: Math.min(descriptor.size, Math.floor(descriptor.size * progress / 100)),
      transferStage: stage
    };
    this.transportEngine.sendProtocolMessage(transport, progressMessage).catch(() => {
      // Progress is advisory; the file transfer and durable ACK remain authoritative.
    });
  }

  private completeFileTransferAck(descriptor: WatchSyncFileDescriptor): void {
    this.fileAckCoordinator.acknowledge(descriptor);
  }

  private clearFileTransferAck(): void {
    this.fileAckCoordinator.clear();
    this.activeFileLastProgressSent = -1;
    this.activeFileLastProgressSentAt = 0;
  }

  private async transferRecording(transport: P2pTransport, recording: RecordingFile): Promise<void> {
    if (recording.size <= 0 || recording.size > MAX_RECORDING_BYTES) {
      throw new Error('录音文件为空或超过 10 MB 限制');
    }

    const inputFile = openReadOnlyChecked(recording.path);
    try {
      await new Promise<void>((resolve, reject) => {
        this.transportEngine.transferFile(transport, inputFile,
          (error: BusinessError, result: wearEngine.P2pResult) => {
            if (error) {
              reject(new Error(wearEngineErrorMessage(error)));
              return;
            }
            if (result.code !== undefined && result.code !== P2P_COMMUNICATION_SUCCESS) {
              reject(new Error(p2pResultMessage(result.code)));
              return;
            }
            if (result.progress !== undefined) {
              if (result.progress >= 100) {
                resolve();
              }
              return;
            }
            // API 23 can report a successful final callback with an empty P2pResult.
            resolve();
          });
      });
    } finally {
      closeFileChecked(inputFile.fd);
    }
  }

  private updateStatus(status: string): void {
    if (this.statusHandler !== undefined) {
      this.statusHandler(status);
    }
  }
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
