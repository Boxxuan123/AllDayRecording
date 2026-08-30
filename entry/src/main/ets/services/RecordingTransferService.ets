import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { wearEngine } from '@kit.WearEngine';
import {
  RecordingFile,
  WatchSyncFileDescriptor,
  WATCH_AUTO_FILE,
  WATCH_CONTROL_BUSY,
  WATCH_CONTROL_PROBE,
  WATCH_CONTROL_READY,
  WATCH_CONTROL_REPLAY,
  WATCH_MANUAL_DUPLICATE,
  WATCH_MANUAL_QUEUED,
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
  WATCH_WIFI_TRANSFER_ACK,
  WATCH_WIFI_TRANSFER_COMMAND,
  WATCH_WIFI_TRANSFER_PROBE,
  WATCH_WIFI_TRANSFER_READY,
  AUTOMATIC_QUEUE_DAMAGED,
  AUTOMATIC_QUEUE_ENQUEUED,
  AUTOMATIC_QUEUE_ENQUEUED_NOT_SAVED,
  AUTOMATIC_QUEUE_INVALID,
  AUTOMATIC_QUEUE_REJECTED,
  AutomaticSyncQueue,
  AutomaticSyncQueueEntry,
  P2P_COMMUNICATION_SUCCESS,
  WatchAutomaticRetryCoordinator,
  WatchFileAckCoordinator,
  WatchManualSyncDecision,
  WatchManualSyncRequest,
  WatchRecordingControlCoordinator,
  WatchSyncCoordinator,
  WatchSyncProtocolMessage,
  WearEngineConnection,
  WearEngineTransport,
  decodeWatchSyncMessage,
  exactWatchFileKey,
  isP2pCommunicationError,
  isP2pCommunicationFailureResult,
  p2pResultMessage,
  shouldRetryP2pFileTransfer,
  watchFileTransferKey,
  wearEngineErrorMessage
} from 'common';

export { wearEngineErrorMessage } from 'common';

const MAX_RECORDING_BYTES: number = 10 * 1024 * 1024;
const MAX_SYNC_FILE_COUNT: number = 1;
const INVENTORY_KEYS_PER_PAGE: number = 24;
const TRANSFER_RETRY_ATTEMPTS: number = 3;
const TRANSFER_RETRY_BASE_DELAY_MS: number = 800;
const TRANSFER_PROGRESS_STALL_TIMEOUT_MS: number = 60 * 1000;
const TRANSFER_FILE_ACK_TIMEOUT_MS: number = 60 * 1000;
const TRANSFER_PROGRESS_STEP: number = 5;
const TRANSFER_PROGRESS_MESSAGE_INTERVAL_MS: number = 1000;
const SYNC_RECEIVE_DIRECTORY: string = 'synced_from_watch';

export type TransferStatusHandler = (status: string) => void;

export interface WatchRecordingControlResult {
  actualState: string;
  sessionId: string;
  message: string;
}

export type WatchRecordingControlHandler =
  (desiredState: string, requestId: string) => Promise<WatchRecordingControlResult>;

export type WatchWifiTransferHandler = (requestId: string) => Promise<string>;

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
    if (knownFileKeys.indexOf(exactWatchFileKey(source.relativePath, source.size)) >= 0) {
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

export class WearEngineRecordingSender {
  private context: common.UIAbilityContext;
  private transportEngine: WearEngineTransport;
  private statusHandler: TransferStatusHandler | undefined;
  private p2pClient: wearEngine.P2pClient | undefined = undefined;
  private peer: wearEngine.Device | undefined = undefined;
  private appParam: wearEngine.P2pAppParam | undefined = undefined;
  private syncCoordinator: WatchSyncCoordinator = new WatchSyncCoordinator();
  private automaticRetryCoordinator: WatchAutomaticRetryCoordinator = new WatchAutomaticRetryCoordinator();
  private inventoryRequestId: string = '';
  private inventoryPageCount: number = 0;
  private inventoryPagesReceived: Array<number> = [];
  private inventoryKnownKeys: Array<string> = [];
  private automaticQueue: AutomaticSyncQueue;
  private controlHandler: WatchRecordingControlHandler | undefined;
  private controlCoordinator: WatchRecordingControlCoordinator = new WatchRecordingControlCoordinator();
  private wifiTransferHandler: WatchWifiTransferHandler | undefined;
  private wifiTransferCoordinator: WatchRecordingControlCoordinator = new WatchRecordingControlCoordinator();
  private fileAckCoordinator: WatchFileAckCoordinator = new WatchFileAckCoordinator(
    TRANSFER_PROGRESS_STALL_TIMEOUT_MS, TRANSFER_FILE_ACK_TIMEOUT_MS);
  private activeFileLastProgressSent: number = -1;
  private activeFileLastProgressSentAt: number = 0;
  private messageReceiver = (incoming: wearEngine.P2pMessage): void => {
    this.receiveMessage(incoming);
  };

  constructor(context: common.UIAbilityContext, statusHandler?: TransferStatusHandler,
    controlHandler?: WatchRecordingControlHandler, wifiTransferHandler?: WatchWifiTransferHandler) {
    this.context = context;
    this.transportEngine = new WearEngineTransport(context);
    this.automaticQueue = new AutomaticSyncQueue(context.filesDir);
    this.statusHandler = statusHandler;
    this.controlHandler = controlHandler;
    this.wifiTransferHandler = wifiTransferHandler;
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
      this.requestAutomaticDrain();
    }
  }

  async stop(): Promise<void> {
    this.automaticRetryCoordinator.cancelScheduled();
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
    this.requestAutomaticDrain();
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
      if (message.type === WATCH_WIFI_TRANSFER_PROBE && message.requestId.length > 0) {
        this.sendWifiTransferReady(message.requestId);
        return;
      }
      if (message.type === WATCH_RECORDING_COMMAND && message.requestId.length > 0) {
        this.processRecordingControl(message);
        return;
      }
      if (message.type === WATCH_WIFI_TRANSFER_COMMAND && message.requestId.length > 0) {
        this.processWifiTransferCommand(message);
        return;
      }
      if (message.type === WATCH_PHONE_READY) {
        this.requestAutomaticDrain();
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

  private async sendWifiTransferReady(requestId: string): Promise<void> {
    try {
      const transport = await this.getTransport();
      const ready: WatchSyncProtocolMessage = {
        version: WATCH_SYNC_PROTOCOL_VERSION,
        type: WATCH_WIFI_TRANSFER_READY,
        requestId: requestId
      };
      await this.transportEngine.sendProtocolMessage(transport, ready);
    } catch (error) {
      this.updateStatus(`Wi-Fi 快传握手失败：${wearEngineErrorMessage(error)}`);
    }
  }

  private async processWifiTransferCommand(command: WatchSyncProtocolMessage): Promise<void> {
    let transport: P2pTransport;
    try {
      transport = await this.getTransport();
    } catch (error) {
      this.updateStatus(`Wi-Fi 快传控制连接失败：${wearEngineErrorMessage(error)}`);
      return;
    }
    const decision = this.wifiTransferCoordinator.inspect(command.requestId);
    if (decision === WATCH_CONTROL_REPLAY) {
      const lastAck = this.wifiTransferCoordinator.lastAck();
      if (lastAck !== undefined) {
        await this.transportEngine.sendProtocolMessage(transport, lastAck);
      }
      return;
    }
    if (decision === WATCH_CONTROL_BUSY) {
      await this.sendWifiTransferAck(transport, command.requestId, false, '手表正在处理另一项 Wi-Fi 快传');
      return;
    }
    if (this.wifiTransferHandler === undefined) {
      await this.sendWifiTransferAck(transport, command.requestId, false, '手表 Wi-Fi 快传控制器尚未就绪');
      return;
    }
    this.wifiTransferCoordinator.begin();
    try {
      const result = await this.wifiTransferHandler(command.requestId);
      const ack = await this.sendWifiTransferAck(transport, command.requestId, true, result);
      this.wifiTransferCoordinator.complete(command.requestId, ack);
      this.updateStatus(result);
    } catch (error) {
      const message = wearEngineErrorMessage(error);
      const ack = await this.sendWifiTransferAck(transport, command.requestId, false, message);
      this.wifiTransferCoordinator.complete(command.requestId, ack);
      this.updateStatus(`Wi-Fi 快传失败：${message}`);
    } finally {
      this.wifiTransferCoordinator.finishWithoutAck();
    }
  }

  private async sendWifiTransferAck(transport: P2pTransport, requestId: string,
    success: boolean, message: string): Promise<WatchSyncProtocolMessage> {
    const ack: WatchSyncProtocolMessage = {
      version: WATCH_SYNC_PROTOCOL_VERSION,
      type: WATCH_WIFI_TRANSFER_ACK,
      requestId: requestId,
      actualState: success ? 'completed' : 'failed',
      success: success,
      message: message
    };
    await this.transportEngine.sendProtocolMessage(transport, ack);
    return ack;
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
      this.deferAutomaticQueueAfterCommunicationFailure(error as Object);
      this.syncCoordinator.finishCurrent();
      if (!this.startPendingSyncIfIdle()) {
        this.requestAutomaticDrain();
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
          this.automaticRetryCoordinator.markSuccess();
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
      this.deferAutomaticQueueAfterCommunicationFailure(error as Object);
      await this.sendSyncError(transport, requestId, wearEngineErrorMessage(error));
      this.updateStatus(`手机同步失败，手表文件已保留：${wearEngineErrorMessage(error)}`);
    } finally {
      this.syncCoordinator.finishCurrent();
      if (!this.startPendingSyncIfIdle()) {
        this.requestAutomaticDrain();
      }
    }
  }

  private requestAutomaticDrain(): void {
    if (this.automaticQueue.count() === 0) {
      return;
    }
    if (this.automaticRetryCoordinator.scheduleIfCoolingDown(() => {
      this.requestAutomaticDrain();
    })) {
      return;
    }
    this.drainAutomaticQueue();
  }

  private deferAutomaticQueueAfterCommunicationFailure(error: Object): boolean {
    if (this.automaticQueue.count() === 0 || !isP2pCommunicationFailureResult(error)) {
      return false;
    }
    const delayMs = this.automaticRetryCoordinator.defer();
    const delaySeconds = Math.ceil(delayMs / 1000);
    this.updateStatus(`Wear Engine 文件通道繁忙，${delaySeconds} 秒后自动续传；手表原文件已保留`);
    this.requestAutomaticDrain();
    return true;
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
          this.automaticRetryCoordinator.markSuccess();
          const queueSaved = this.automaticQueue.complete(source.path);
          this.updateStatus(queueSaved ? `自动同步完成第 ${queuePosition} 段：${source.fileName}，手表原文件保留` :
            `第 ${queuePosition} 段已确认，但队列清单更新失败；录音文件仍保留`);
        } catch (error) {
          await this.sendFileFailed(transport, descriptor);
          if (!this.deferAutomaticQueueAfterCommunicationFailure(error as Object)) {
            this.updateStatus(`自动同步待重试，手表原文件已保留：${wearEngineErrorMessage(error)}`);
          }
          break;
        }
      }
    } catch (error) {
      if (!this.deferAutomaticQueueAfterCommunicationFailure(error as Object)) {
        this.updateStatus(`自动同步待重试，手表原文件已保留：${wearEngineErrorMessage(error)}`);
      }
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
        if (!shouldRetryP2pFileTransfer(lastError, attempt, TRANSFER_RETRY_ATTEMPTS)) {
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
        if (!shouldRetryP2pFileTransfer(lastError, attempt, TRANSFER_RETRY_ATTEMPTS)) {
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
