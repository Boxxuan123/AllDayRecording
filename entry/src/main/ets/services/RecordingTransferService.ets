import { common, bundleManager } from '@kit.AbilityKit';
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
  JSON_LOAD_DAMAGED,
  JSON_LOAD_MISSING,
  JSON_LOAD_SUCCESS,
  loadVersionedJson,
  writeVersionedJson
} from '../shared/io/AtomicJsonStore';
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
  encodeWatchSyncMessage,
  exactWatchFileKey,
  legacyWatchFileKey
} from './WatchFileSyncProtocol';
import { ReceivedRecordingStore, SYNC_RECEIVE_DIRECTORY } from './ReceivedRecordingStore';

const MAX_RECORDING_BYTES = 10 * 1024 * 1024;
// Reliability-first fallback: keep only one Wear Engine file task in each manual
// sync request. Once a single file is durably acknowledged, the phone can issue
// another request. The source file on the watch is never deleted.
const MAX_SYNC_FILE_COUNT = 1;
const INVENTORY_KEYS_PER_PAGE = 24;
const P2P_REMOTE_APP_NOT_INSTALLED = 200;
const P2P_REMOTE_APP_NOT_RUNNING = 201;
const P2P_REMOTE_APP_RUNNING = 202;
const P2P_COMMUNICATION_FAILURE = 206;
const P2P_COMMUNICATION_SUCCESS = 207;
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
const PENDING_USER_ACTION_TIMEOUT_MS = 5 * 60 * 1000;
const AUTOMATIC_QUEUE_MANIFEST_VERSION = 1;
const AUTOMATIC_QUEUE_MANIFEST_FILE = 'automatic_sync_queue_v1.json';

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

interface AutomaticQueueManifestEntry {
  relativePath: string;
  fileName: string;
  size: number;
  durationMs: number;
}

interface AutomaticQueueManifest {
  version: number;
  updatedAt: number;
  completedCount: number;
  files: Array<AutomaticQueueManifestEntry>;
}

function isAutomaticQueueManifest(manifest: AutomaticQueueManifest): boolean {
  return Array.isArray(manifest.files);
}

interface P2pTransport {
  peer: wearEngine.Device;
  client: wearEngine.P2pClient;
  appParam: wearEngine.P2pAppParam;
}

type FileTransferAckResolve = () => void;
type FileTransferAckReject = (error: Error) => void;

function fileTransferAckKey(descriptor: WatchSyncFileDescriptor): string {
  return `${descriptor.requestId}\n${descriptor.index}\n${descriptor.relativePath}`;
}

async function getLocalAppParam(): Promise<wearEngine.P2pAppParam> {
  const info = await bundleManager.getBundleInfoForSelf(
    bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_SIGNATURE_INFO);
  return {
    remoteApp: {
      bundleName: info.name,
      // Wear Engine's legacy field name is fingerprint; HarmonyOS uses appIdentifier as the app identity.
      fingerprint: info.signatureInfo.appIdentifier
    }
  };
}

async function getConnectedPeer(context: common.UIAbilityContext): Promise<wearEngine.Device> {
  if (!canIUse('SystemCapability.Health.WearEngine')) {
    throw new Error('当前设备不支持 Wear Engine');
  }
  const devices = await wearEngine.getDeviceClient(context).getConnectedDevices();
  if (devices.length === 0) {
    throw new Error('未找到已连接的对端设备，请先在华为运动健康中确认手机与手表在线');
  }
  return devices[0];
}

function waitForReceiverRetry(delayMs: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(resolve, delayMs);
  });
}

function shouldRetryReceiverConnection(error: Object): boolean {
  const businessError = error as BusinessError;
  if (businessError.code === 1008500004 || businessError.code === 1008500005 ||
    businessError.code === 1008500006 || businessError.code === 1008500008) {
    return false;
  }
  const message = error instanceof Error ? error.message : '';
  return message !== '当前设备不支持 Wear Engine' && message !== 'Wear Engine 接收器启动已取消';
}

function p2pResultMessage(code: number | undefined): string {
  switch (code) {
    case P2P_REMOTE_APP_NOT_INSTALLED:
      return '对端尚未安装本应用';
    case P2P_REMOTE_APP_NOT_RUNNING:
      return '请先打开对端应用';
    case P2P_COMMUNICATION_FAILURE:
      return 'Wear Engine 通信失败，请检查华为运动健康中的设备连接';
    default:
      return `Wear Engine 返回错误码 ${code}`;
  }
}

function isP2pCommunicationError(error: Object): boolean {
  const businessError = error as BusinessError;
  if (businessError.code === 1008500002 || businessError.code === 1008500003) {
    return true;
  }
  const message = error instanceof Error ? error.message : '';
  return message.includes('Wear Engine 通信失败') || message.includes('当前未连接') ||
    message.includes('未找到已连接的对端设备');
}

function validateP2pResult(result: wearEngine.P2pResult): void {
  if (result.code !== undefined && result.code !== P2P_COMMUNICATION_SUCCESS) {
    throw new Error(p2pResultMessage(result.code));
  }
}

async function sendProtocolMessage(client: wearEngine.P2pClient, peer: wearEngine.Device,
  appParam: wearEngine.P2pAppParam, message: WatchSyncProtocolMessage): Promise<void> {
  const p2pMessage: wearEngine.P2pMessage = {
    content: encodeWatchSyncMessage(message)
  };
  const result = await client.sendMessage(peer.randomId, appParam, p2pMessage);
  validateP2pResult(result);
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
  const entries = fileIo.listFileSync(directory);
  for (let index = 0; index < entries.length; index += 1) {
    const fileName = entries[index];
    if (relativeDirectory.length === 0 && fileName === SYNC_RECEIVE_DIRECTORY) {
      continue;
    }
    const relativePath = relativeDirectory.length > 0 ? `${relativeDirectory}/${fileName}` : fileName;
    const path = `${filesDirectory}/${relativePath}`;
    const stat = fileIo.statSync(path);
    if (stat.isDirectory()) {
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
  if (!fileIo.accessSync(path)) {
    fileIo.mkdirSync(path);
  }
}

function safeFileName(fileName: string): string {
  return fileName.replace(/[^A-Za-z0-9._-]/g, '_');
}

export function wearEngineErrorMessage(error: Object): string {
  const businessError = error as BusinessError;
  switch (businessError.code) {
    case 1008500002:
      return '没有已绑定的穿戴设备';
    case 1008500003:
      return '手机与手表当前未连接';
    case 1008500004:
      return '应用尚未在华为开发者联盟申请 Wear Engine 服务';
    case 1008500005:
      return '华为账号尚未授权本应用使用 Wear Engine';
    case 1008500006:
      return '请先同意 Wear Engine 隐私声明';
    case 1008500008:
      return '设备尚未登录华为账号';
    case 1008509999:
      return 'Wear Engine 权限校验失败，请确认设备基础信息与 P2P 通信能力已审批生效';
    default:
      if (businessError.code !== undefined) {
        return `${businessError.message || 'Wear Engine 调用失败'}（错误码 ${businessError.code}）`;
      }
      return error instanceof Error ? error.message : '未知错误';
  }
}

export class WearEngineRecordingSender {
  private context: common.UIAbilityContext;
  private statusHandler: TransferStatusHandler | undefined;
  private p2pClient: wearEngine.P2pClient | undefined = undefined;
  private peer: wearEngine.Device | undefined = undefined;
  private appParam: wearEngine.P2pAppParam | undefined = undefined;
  private syncInProgress: boolean = false;
  private activeSyncRequestId: string = '';
  private pendingSyncRequestId: string = '';
  private pendingSyncKnownKeys: Array<string> = [];
  private inventoryRequestId: string = '';
  private inventoryPageCount: number = 0;
  private inventoryPagesReceived: Array<number> = [];
  private inventoryKnownKeys: Array<string> = [];
  private automaticTransferInProgress: boolean = false;
  private automaticQueue: Array<SyncSourceFile> = [];
  private automaticQueueLoaded: boolean = false;
  private automaticRequestId: string = `auto_${Date.now()}`;
  private automaticCompletedCount: number = 0;
  private controlHandler: WatchRecordingControlHandler | undefined;
  private controlInProgress: boolean = false;
  private lastControlRequestId: string = '';
  private lastControlAck: WatchSyncProtocolMessage | undefined = undefined;
  private activeFileAckKey: string = '';
  private activeFileAckResolve: FileTransferAckResolve | undefined = undefined;
  private activeFileAckReject: FileTransferAckReject | undefined = undefined;
  private activeFileAckTimeoutId: number = -1;
  private activeFileProgressTimeoutId: number = -1;
  private activeFileAckPhaseStarted: boolean = false;
  private activeFileLastProgress: number = -1;
  private activeFileLastProgressSent: number = -1;
  private activeFileLastProgressSentAt: number = 0;
  private messageReceiver = (incoming: wearEngine.P2pMessage): void => {
    this.receiveMessage(incoming);
  };

  constructor(context: common.UIAbilityContext, statusHandler?: TransferStatusHandler,
    controlHandler?: WatchRecordingControlHandler) {
    this.context = context;
    this.statusHandler = statusHandler;
    this.controlHandler = controlHandler;
  }

  async start(): Promise<void> {
    this.restoreAutomaticQueue();
    if (this.p2pClient !== undefined) {
      return;
    }
    const transport = await this.createTransport();
    await transport.client.registerMessageReceiver(
      transport.peer.randomId, transport.appParam, this.messageReceiver);
    this.peer = transport.peer;
    this.appParam = transport.appParam;
    this.p2pClient = transport.client;
    const readyMessage: WatchSyncProtocolMessage = {
      version: WATCH_SYNC_PROTOCOL_VERSION,
      type: WATCH_SYNC_READY,
      requestId: ''
    };
    try {
      await sendProtocolMessage(transport.client, transport.peer, transport.appParam, readyMessage);
    } catch (error) {
      // The phone page may not be open yet. The registered receiver remains ready for a later request.
    }
    if (this.automaticQueue.length > 0) {
      this.updateStatus(`已恢复自动同步队列（${this.automaticQueue.length}），准备续传`);
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
        await client.unregisterMessageReceiver(peer.randomId, appParam, this.messageReceiver);
      } catch (error) {
        // The peer may have disconnected while the page was closing.
      }
    }
  }

  async send(recording: RecordingFile): Promise<void> {
    if (this.syncInProgress || this.automaticTransferInProgress) {
      throw new Error('正在同步其他录音，请稍后再手动发送');
    }
    const transport = await this.getTransport();
    await this.transferRecordingWithRetry(transport, recording);
  }

  enqueueAutomatic(recording: RecordingFile): void {
    if (recording.path.endsWith('.part') || recording.size <= 0 || recording.size > MAX_RECORDING_BYTES) {
      this.updateStatus('分片尚未完整封口，未加入自动同步');
      return;
    }
    for (let index = 0; index < this.automaticQueue.length; index += 1) {
      if (this.automaticQueue[index].path === recording.path) {
        return;
      }
    }
    const filesPrefix = `${this.context.filesDir}/`;
    const relativePath = recording.path.startsWith(filesPrefix) ?
      recording.path.substring(filesPrefix.length) : recording.fileName;
    this.automaticQueue.push({
      fileName: recording.fileName,
      path: recording.path,
      size: recording.size,
      durationMs: recording.durationMs,
      relativePath: relativePath
    });
    const queueSaved = this.persistAutomaticQueue();
    this.updateStatus(queueSaved ? `已封口，等待自动同步（${this.automaticQueue.length}）` :
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
    this.lastControlRequestId = requestId;
    this.lastControlAck = ack;
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
      await sendProtocolMessage(transport.client, transport.peer, transport.appParam, ready);
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
    if (command.requestId === this.lastControlRequestId && this.lastControlAck !== undefined) {
      await sendProtocolMessage(transport.client, transport.peer, transport.appParam, this.lastControlAck);
      return;
    }
    if (this.controlInProgress) {
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
    this.controlInProgress = true;
    try {
      const result = await this.controlHandler(desiredState, command.requestId);
      const ack = await this.sendRecordingAck(transport, command.requestId, desiredState, true,
        result.actualState, result.sessionId, result.message);
      this.lastControlRequestId = command.requestId;
      this.lastControlAck = ack;
      this.updateStatus(result.message);
    } catch (error) {
      const message = wearEngineErrorMessage(error);
      const ack = await this.sendRecordingAck(transport, command.requestId, desiredState, false,
        '', '', message);
      this.lastControlRequestId = command.requestId;
      this.lastControlAck = ack;
      this.updateStatus(`手机控制失败：${message}`);
    } finally {
      this.controlInProgress = false;
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
    await sendProtocolMessage(transport.client, transport.peer, transport.appParam, ack);
    return ack;
  }

  private async processSyncRequest(requestId: string, knownFileKeys: Array<string>): Promise<void> {
    if (this.syncInProgress || this.automaticTransferInProgress) {
      if (requestId === this.activeSyncRequestId || requestId === this.pendingSyncRequestId) {
        return;
      }
      this.pendingSyncRequestId = requestId;
      this.pendingSyncKnownKeys = knownFileKeys.slice();
      const detail = this.automaticTransferInProgress ?
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
    this.syncInProgress = true;
    this.activeSyncRequestId = requestId;
    let transport: P2pTransport;
    try {
      transport = await this.getTransport();
    } catch (error) {
      this.updateStatus(`无法响应手机同步：${wearEngineErrorMessage(error)}`);
      this.syncInProgress = false;
      this.activeSyncRequestId = '';
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
      await sendProtocolMessage(transport.client, transport.peer, transport.appParam, beginMessage);
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
      await sendProtocolMessage(transport.client, transport.peer, transport.appParam, completeMessage);
      this.updateStatus(`手机同步完成 ${sentCount} 个，手表文件全部保留`);
    } catch (error) {
      await this.sendSyncError(transport, requestId, wearEngineErrorMessage(error));
      this.updateStatus(`手机同步失败，手表文件已保留：${wearEngineErrorMessage(error)}`);
    } finally {
      this.syncInProgress = false;
      this.activeSyncRequestId = '';
      if (!this.startPendingSyncIfIdle()) {
        this.drainAutomaticQueue();
      }
    }
  }

  private async drainAutomaticQueue(): Promise<void> {
    if (this.automaticTransferInProgress || this.syncInProgress || this.pendingSyncRequestId.length > 0 ||
      this.automaticQueue.length === 0) {
      return;
    }
    this.automaticTransferInProgress = true;
    try {
      let transport = await this.getTransport();
      while (!this.syncInProgress && this.pendingSyncRequestId.length === 0 && this.automaticQueue.length > 0) {
        const source = this.automaticQueue[0];
        const queuePosition = this.automaticCompletedCount + 1;
        const queueTotal = this.automaticCompletedCount + this.automaticQueue.length;
        const descriptor: WatchSyncFileDescriptor = {
          requestId: this.automaticRequestId,
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
          this.automaticQueue.shift();
          this.automaticCompletedCount += 1;
          const queueSaved = this.persistAutomaticQueue();
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
      this.automaticTransferInProgress = false;
      this.startPendingSyncIfIdle();
    }
  }

  private startPendingSyncIfIdle(): boolean {
    if (this.syncInProgress || this.automaticTransferInProgress || this.pendingSyncRequestId.length === 0) {
      return false;
    }
    const requestId = this.pendingSyncRequestId;
    const knownFileKeys = this.pendingSyncKnownKeys.slice();
    this.pendingSyncRequestId = '';
    this.pendingSyncKnownKeys = [];
    this.processSyncRequest(requestId, knownFileKeys);
    return true;
  }

  private restoreAutomaticQueue(): void {
    if (this.automaticQueueLoaded) {
      return;
    }
    this.automaticQueueLoaded = true;
    const manifestPath = `${this.context.filesDir}/${AUTOMATIC_QUEUE_MANIFEST_FILE}`;
    try {
      const loaded = loadVersionedJson<AutomaticQueueManifest>(manifestPath,
        AUTOMATIC_QUEUE_MANIFEST_VERSION, isAutomaticQueueManifest);
      if (loaded.status === JSON_LOAD_MISSING) {
        return;
      }
      if (loaded.status !== JSON_LOAD_SUCCESS || loaded.value === undefined) {
        this.updateStatus(loaded.status === JSON_LOAD_DAMAGED ?
          '自动同步队列清单无法读取，录音文件未受影响' :
          '自动同步队列清单版本无效，录音文件未受影响');
        return;
      }
      const manifest = loaded.value;
      this.automaticCompletedCount = Math.max(0, Math.floor(manifest.completedCount || 0));
      for (let index = 0; index < manifest.files.length; index += 1) {
        const entry = manifest.files[index];
        if (entry.relativePath.length === 0 || entry.relativePath.startsWith('/') ||
          entry.relativePath.includes('..')) {
          continue;
        }
        const path = `${this.context.filesDir}/${entry.relativePath}`;
        if (!fileIo.accessSync(path)) {
          continue;
        }
        const stat = fileIo.statSync(path);
        const lowerName = entry.fileName.toLowerCase();
        if (!stat.isFile() || stat.size <= 0 || stat.size > MAX_RECORDING_BYTES ||
          stat.size !== entry.size || (!lowerName.endsWith('.wav') && !lowerName.endsWith('.m4a')) ||
          lowerName.endsWith('.part')) {
          continue;
        }
        this.automaticQueue.push({
          fileName: entry.fileName,
          path: path,
          relativePath: entry.relativePath,
          size: entry.size,
          durationMs: entry.durationMs || 0
        });
      }
      if (this.automaticQueue.length !== manifest.files.length) {
        this.persistAutomaticQueue();
      }
    } catch (error) {
      this.updateStatus('自动同步队列清单无法读取，录音文件未受影响');
    }
  }

  private persistAutomaticQueue(): boolean {
    const entries: Array<AutomaticQueueManifestEntry> = [];
    for (let index = 0; index < this.automaticQueue.length; index += 1) {
      const source = this.automaticQueue[index];
      entries.push({
        relativePath: source.relativePath,
        fileName: source.fileName,
        size: source.size,
        durationMs: source.durationMs
      });
    }
    const manifest: AutomaticQueueManifest = {
      version: AUTOMATIC_QUEUE_MANIFEST_VERSION,
      updatedAt: Date.now(),
      completedCount: this.automaticCompletedCount,
      files: entries
    };
    const manifestPath = `${this.context.filesDir}/${AUTOMATIC_QUEUE_MANIFEST_FILE}`;
    try {
      writeVersionedJson<AutomaticQueueManifest>(manifestPath, AUTOMATIC_QUEUE_MANIFEST_VERSION,
        manifest, isAutomaticQueueManifest);
      return true;
    } catch (error) {
      return false;
    }
  }

  private removeAutomaticFile(path: string): void {
    let removedCount = 0;
    for (let index = this.automaticQueue.length - 1; index >= 0; index -= 1) {
      if (this.automaticQueue[index].path === path) {
        this.automaticQueue.splice(index, 1);
        removedCount += 1;
      }
    }
    if (removedCount > 0) {
      this.automaticCompletedCount += removedCount;
      this.persistAutomaticQueue();
    }
  }

  private async sendFileFailed(transport: P2pTransport, descriptor: WatchSyncFileDescriptor): Promise<void> {
    const failedMessage: WatchSyncProtocolMessage = {
      version: WATCH_SYNC_PROTOCOL_VERSION,
      type: WATCH_SYNC_FILE_FAILED,
      requestId: descriptor.requestId,
      file: descriptor
    };
    try {
      await sendProtocolMessage(transport.client, transport.peer, transport.appParam, failedMessage);
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
      await sendProtocolMessage(transport.client, transport.peer, transport.appParam, errorMessage);
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
      await sendProtocolMessage(transport.client, transport.peer, transport.appParam, queuedMessage);
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
    const peer = await getConnectedPeer(this.context);
    const client = wearEngine.getP2pClient(this.context);
    const appParam = await getLocalAppParam();
    const installed = await client.isRemoteAppInstalled(peer.randomId, appParam.remoteApp.bundleName);
    if (!installed) {
      throw new Error('对端尚未安装本应用');
    }
    return {
      peer: peer,
      client: client,
      appParam: appParam
    };
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
        await sendProtocolMessage(currentTransport.client, currentTransport.peer, currentTransport.appParam, message);
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
        await sendProtocolMessage(currentTransport.client, currentTransport.peer,
          currentTransport.appParam, fileMessage);
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
    if (this.activeFileAckKey.length > 0) {
      throw new Error('上一片文件仍在等待手机持久化回执');
    }

    const ackKey = fileTransferAckKey(descriptor);
    const inputFile = fileIo.openSync(recording.path, fileIo.OpenMode.READ_ONLY);
    try {
      await new Promise<void>((resolve, reject) => {
        this.activeFileAckKey = ackKey;
        this.activeFileAckResolve = resolve;
        this.activeFileAckReject = reject;
        this.activeFileAckPhaseStarted = false;
        this.activeFileLastProgress = -1;
        this.activeFileLastProgressSent = -1;
        this.activeFileLastProgressSentAt = 0;
        this.refreshFileTransferProgressTimeout(ackKey);
        this.reportFileTransferProgress(transport, descriptor, 0, 'transferring', true);

        transport.client.transferFile(transport.peer.randomId, transport.appParam, { file: inputFile },
          (error: BusinessError, result: wearEngine.P2pResult) => {
            if (error) {
              this.failFileTransferAck(ackKey, new Error(wearEngineErrorMessage(error)));
              return;
            }
            if (result.code !== undefined && result.code !== P2P_COMMUNICATION_SUCCESS) {
              this.failFileTransferAck(ackKey, new Error(p2pResultMessage(result.code)));
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
      fileIo.closeSync(inputFile.fd);
    }
  }

  private handleFileTransferProgress(transport: P2pTransport, descriptor: WatchSyncFileDescriptor,
    ackKey: string, progress: number): void {
    if (ackKey !== this.activeFileAckKey) {
      return;
    }
    const bounded = Math.max(0, Math.min(100, Math.floor(progress)));
    if (bounded < this.activeFileLastProgress) {
      return;
    }
    const increased = bounded > this.activeFileLastProgress;
    this.activeFileLastProgress = bounded;
    if (bounded >= 100) {
      this.startFileAckTimeout(ackKey);
      this.reportFileTransferProgress(transport, descriptor, 100, 'waiting_ack', true);
      return;
    }
    if (increased) {
      this.refreshFileTransferProgressTimeout(ackKey);
    }
    this.reportFileTransferProgress(transport, descriptor, bounded, 'transferring', false);
  }

  private refreshFileTransferProgressTimeout(ackKey: string): void {
    if (this.activeFileProgressTimeoutId >= 0) {
      clearTimeout(this.activeFileProgressTimeoutId);
    }
    this.activeFileProgressTimeoutId = setTimeout(() => {
      if (this.activeFileAckKey !== ackKey || this.activeFileAckPhaseStarted) {
        return;
      }
      this.failFileTransferAck(ackKey, new Error('Wear Engine 通信失败：文件传输进度 60 秒未变化'));
    }, TRANSFER_PROGRESS_STALL_TIMEOUT_MS);
  }

  private startFileAckTimeout(ackKey: string): void {
    if (this.activeFileAckPhaseStarted) {
      return;
    }
    this.activeFileAckPhaseStarted = true;
    if (this.activeFileProgressTimeoutId >= 0) {
      clearTimeout(this.activeFileProgressTimeoutId);
      this.activeFileProgressTimeoutId = -1;
    }
    this.activeFileAckTimeoutId = setTimeout(() => {
      if (this.activeFileAckKey !== ackKey) {
        return;
      }
      this.failFileTransferAck(ackKey, new Error('Wear Engine 通信失败：文件已传完，但等待手机持久化回执超时'));
    }, TRANSFER_FILE_ACK_TIMEOUT_MS);
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
    sendProtocolMessage(transport.client, transport.peer, transport.appParam, progressMessage).catch(() => {
      // Progress is advisory; the file transfer and durable ACK remain authoritative.
    });
  }

  private completeFileTransferAck(descriptor: WatchSyncFileDescriptor): void {
    const ackKey = fileTransferAckKey(descriptor);
    if (ackKey !== this.activeFileAckKey || this.activeFileAckResolve === undefined) {
      return;
    }
    const resolve = this.activeFileAckResolve;
    this.clearFileTransferAck();
    resolve();
  }

  private failFileTransferAck(ackKey: string, error: Error): void {
    if (ackKey !== this.activeFileAckKey || this.activeFileAckReject === undefined) {
      return;
    }
    const reject = this.activeFileAckReject;
    this.clearFileTransferAck();
    reject(error);
  }

  private clearFileTransferAck(): void {
    if (this.activeFileAckTimeoutId >= 0) {
      clearTimeout(this.activeFileAckTimeoutId);
    }
    if (this.activeFileProgressTimeoutId >= 0) {
      clearTimeout(this.activeFileProgressTimeoutId);
    }
    this.activeFileAckKey = '';
    this.activeFileAckResolve = undefined;
    this.activeFileAckReject = undefined;
    this.activeFileAckTimeoutId = -1;
    this.activeFileProgressTimeoutId = -1;
    this.activeFileAckPhaseStarted = false;
    this.activeFileLastProgress = -1;
    this.activeFileLastProgressSent = -1;
    this.activeFileLastProgressSentAt = 0;
  }

  private async transferRecording(transport: P2pTransport, recording: RecordingFile): Promise<void> {
    if (recording.size <= 0 || recording.size > MAX_RECORDING_BYTES) {
      throw new Error('录音文件为空或超过 10 MB 限制');
    }

    const inputFile = fileIo.openSync(recording.path, fileIo.OpenMode.READ_ONLY);
    try {
      await new Promise<void>((resolve, reject) => {
        transport.client.transferFile(transport.peer.randomId, transport.appParam, { file: inputFile },
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
      fileIo.closeSync(inputFile.fd);
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
  private receivedHandler: RecordingReceivedHandler;
  private statusHandler: TransferStatusHandler;
  private syncProgressHandler: WatchSyncProgressHandler;
  private controlStatusHandler: WatchRecordingControlStatusHandler;
  private p2pClient: wearEngine.P2pClient | undefined = undefined;
  private peer: wearEngine.Device | undefined = undefined;
  private appParam: wearEngine.P2pAppParam | undefined = undefined;
  private pendingFiles: Array<WatchSyncFileDescriptor> = [];
  private activeRequestId: string = '';
  private activeTotal: number = 0;
  private activeReceived: number = 0;
  private activeSkipped: number = 0;
  private activeAlreadyReceived: number = 0;
  private activeRemaining: number = 0;
  private activeScannedTotal: number = 0;
  private expectedReceived: number = -1;
  private remoteComplete: boolean = false;
  private syncRequestInProgress: boolean = false;
  private syncHandshakeTimeoutId: number = -1;
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
  private activeControlRequestId: string = '';
  private desiredControlState: string = '';
  private controlCommandSent: boolean = false;
  private controlTimeoutId: number = -1;
  private startTask: Promise<void> | undefined = undefined;
  private startCancelled: boolean = false;
  private recordingStore: ReceivedRecordingStore;
  private completedDescriptorKeys: Set<string> = new Set<string>();
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
    this.startCancelled = false;
    const task = this.connectWithRetry();
    this.startTask = task;
    try {
      await task;
    } finally {
      if (this.startTask === task) {
        this.startTask = undefined;
      }
    }
  }

  private async connectWithRetry(): Promise<void> {
    for (let attempt = 1; attempt <= RECEIVER_CONNECT_ATTEMPTS; attempt += 1) {
      if (this.startCancelled) {
        throw new Error('Wear Engine 接收器启动已取消');
      }
      this.statusHandler(`正在核对 Wear Engine 用户授权（${attempt}/${RECEIVER_CONNECT_ATTEMPTS}）…`);
      try {
        const authorization = await wearEngine.getAuthClient(this.context).getAuthorization();
        this.statusHandler(`用户授权正常（${authorization.permissions.length} 项），正在查找手表` +
          `（${attempt}/${RECEIVER_CONNECT_ATTEMPTS}）…`);
        await this.connectOnce();
        return;
      } catch (error) {
        if (this.startCancelled) {
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

  private async connectOnce(): Promise<void> {
    const peer = await getConnectedPeer(this.context);
    if (this.startCancelled) {
      throw new Error('Wear Engine 接收器启动已取消');
    }
    this.statusHandler('已找到手表，正在注册文件与消息接收…');
    const appParam = await getLocalAppParam();
    const client = wearEngine.getP2pClient(this.context);
    let messageRegistered = false;
    let fileRegistered = false;
    try {
      await client.registerMessageReceiver(peer.randomId, appParam, this.messageReceiver);
      messageRegistered = true;
      if (this.startCancelled) {
        throw new Error('Wear Engine 接收器启动已取消');
      }
      await client.registerFileReceiver(peer.randomId, appParam, this.fileReceiver);
      fileRegistered = true;
      if (this.startCancelled) {
        throw new Error('Wear Engine 接收器启动已取消');
      }
    } catch (error) {
      if (fileRegistered) {
        try {
          await client.unregisterFileReceiver(peer.randomId, appParam, this.fileReceiver);
        } catch (unregisterError) {
          // The Wear Engine service may have restarted while cleaning up this attempt.
        }
      }
      if (messageRegistered) {
        try {
          await client.unregisterMessageReceiver(peer.randomId, appParam, this.messageReceiver);
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
      await sendProtocolMessage(client, peer, appParam, readyMessage);
    } catch (error) {
      // The watch may not be open yet; receiving remains available in the foreground.
    }
  }

  async stop(): Promise<void> {
    this.startCancelled = true;
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
    this.clearControlTimeout();
    this.clearSyncHandshakeTimeout();
    this.syncRequestInProgress = false;
    this.activeRequestId = '';
    this.activeTotal = 0;
    this.activeReceived = 0;
    this.activeSkipped = 0;
    this.activeAlreadyReceived = 0;
    this.activeRemaining = 0;
    this.activeScannedTotal = 0;
    this.expectedReceived = -1;
    this.remoteComplete = false;
    this.pendingFiles = [];
    this.resetFileTransferState();
    this.activeControlRequestId = '';
    this.desiredControlState = '';
    this.controlCommandSent = false;
    this.emitProgress(false, '同步状态已重置');
    if (client !== undefined && peer !== undefined && appParam !== undefined) {
      try {
        await client.unregisterFileReceiver(peer.randomId, appParam, this.fileReceiver);
      } catch (error) {
        // The peer may have disconnected while the page was closing.
      }
      try {
        await client.unregisterMessageReceiver(peer.randomId, appParam, this.messageReceiver);
      } catch (error) {
        // The peer may have disconnected while the page was closing.
      }
    }
  }

  static async destroyChannel(): Promise<void> {
    await wearEngine.destroy();
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
    if (desiredState !== 'recording' && desiredState !== 'stopped') {
      throw new Error('不支持的录音目标状态');
    }
    if (this.activeControlRequestId.length > 0) {
      throw new Error('上一项手表录音控制仍在进行');
    }

    this.activeControlRequestId = `control_${Date.now()}`;
    this.desiredControlState = desiredState;
    this.controlCommandSent = false;
    const actionText = desiredState === 'recording' ? '启动' : '停止';
    this.emitControl(true, '', `正在拉起手表并请求${actionText}录音…`);
    this.controlTimeoutId = setTimeout(() => {
      if (this.activeControlRequestId.length === 0) {
        return;
      }
      this.emitControl(false, '', `手表${actionText}录音超时，请确认新包已在手表前台`);
      this.activeControlRequestId = '';
      this.desiredControlState = '';
      this.controlCommandSent = false;
      this.controlTimeoutId = -1;
    }, 20000);

    try {
      const startStatus = await this.startRemoteWatchUi(client, peer, appParam);
      this.emitControl(true, '', `${startStatus}，正在等待手表录音控制器…`);
      await this.sendControlProbe();
    } catch (error) {
      this.clearControlTimeout();
      this.emitControl(false, '', `手机控制请求失败：${wearEngineErrorMessage(error)}`);
      this.activeControlRequestId = '';
      this.desiredControlState = '';
      this.controlCommandSent = false;
      throw new Error(wearEngineErrorMessage(error));
    }
  }

  private async startRemoteWatchUi(client: wearEngine.P2pClient, peer: wearEngine.Device,
    appParam: wearEngine.P2pAppParam): Promise<string> {
    const result = await client.startRemoteApp(peer.randomId, appParam.remoteApp.bundleName);

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
    if (this.syncRequestInProgress) {
      throw new Error('上一项手表文件同步仍在进行');
    }

    const requestId = Date.now().toString();
    this.syncRequestInProgress = true;
    this.activeRequestId = requestId;
    this.activeTotal = 0;
    this.activeReceived = 0;
    this.activeSkipped = 0;
    this.activeAlreadyReceived = 0;
    this.activeRemaining = 0;
    this.activeScannedTotal = 0;
    this.completedDescriptorKeys.clear();
    this.expectedReceived = -1;
    this.remoteComplete = false;
    this.resetFileTransferState();
    this.pendingFiles = this.pendingFiles.filter((descriptor: WatchSyncFileDescriptor) =>
      descriptor.automatic === true);
    this.emitProgress(true, '正在拉起手表并请求一个文件…');
    this.startSyncHandshakeTimeout(requestId);
    try {
      try {
        // On API 23, startRemoteApp can return UNKNOWN_ERROR when the watch app
        // is already in the foreground. The following message is the
        // authoritative check that the sync responder is ready.
        await client.startRemoteApp(peer.randomId, appParam.remoteApp.bundleName);
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
        await sendProtocolMessage(client, peer, appParam, inventoryMessage);
      }
      const request: WatchSyncProtocolMessage = {
        version: WATCH_SYNC_PROTOCOL_VERSION,
        type: WATCH_SYNC_REQUEST,
        requestId: requestId,
        inventoryPages: inventoryPages
      };
      await sendProtocolMessage(client, peer, appParam, request);
      if (this.activeRequestId === requestId) {
        this.emitProgress(true, '同步请求已发送，等待手表响应…');
      }
    } catch (error) {
      this.clearSyncHandshakeTimeout();
      this.emitProgress(false, `同步请求失败：${wearEngineErrorMessage(error)}`);
      this.syncRequestInProgress = false;
      this.activeRequestId = '';
      throw new Error(wearEngineErrorMessage(error));
    }
  }

  private receiveMessage(incoming: wearEngine.P2pMessage): void {
    try {
      const message = decodeWatchSyncMessage(incoming.content);
      if (message.type === WATCH_SYNC_READY) {
        if (this.activeControlRequestId.length > 0 && !this.controlCommandSent) {
          this.sendControlProbe();
        }
        return;
      }
      if (message.type === WATCH_CONTROL_READY && message.requestId === this.activeControlRequestId) {
        this.sendRecordingCommand();
        return;
      }
      if (message.type === WATCH_RECORDING_ACK && message.requestId === this.activeControlRequestId) {
        this.handleRecordingAck(message);
        return;
      }
      if (message.type === WATCH_SYNC_FILE_PROGRESS && message.file !== undefined) {
        this.applyFileTransferProgress(message);
        return;
      }
      if (message.type === WATCH_AUTO_FILE && message.file !== undefined) {
        if (this.syncRequestInProgress) {
          this.clearSyncHandshakeTimeout();
        }
        this.addPendingFile(message.file);
        this.setTransferDescriptor(message.file, 'preparing', 0, true);
        this.emitProgress(this.syncRequestInProgress,
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
          this.emitProgress(this.syncRequestInProgress,
            `文件已保存在手机，但确认回执未送达：${message.file.fileName}；手表会安全重试`);
        } else {
          this.setTransferDescriptor(message.file, 'failed', 0, false);
          this.emitProgress(this.syncRequestInProgress,
            `本片尚未传完，手表源文件已保留，等待补传：${message.file.fileName}`);
        }
        return;
      }
      if (message.requestId !== this.activeRequestId) {
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
        this.syncRequestInProgress = false;
        this.activeRequestId = '';
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
    if (descriptor.automatic !== true && message.requestId !== this.activeRequestId) {
      return;
    }
    if (descriptor.automatic !== true || this.syncRequestInProgress) {
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
    this.emitProgress(this.syncRequestInProgress, detail);
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
    this.clearSyncHandshakeTimeout();
    this.syncHandshakeTimeoutId = setTimeout(() => {
      if (this.activeRequestId !== requestId || !this.syncRequestInProgress) {
        return;
      }
      this.syncRequestInProgress = false;
      this.activeRequestId = '';
      this.fileTransferActive = false;
      this.transferStage = 'failed';
      this.syncHandshakeTimeoutId = -1;
      this.emitProgress(false, '手表未在 20 秒内响应，本次同步已结束；手表文件未删除');
    }, SYNC_HANDSHAKE_TIMEOUT_MS);
  }

  private clearSyncHandshakeTimeout(): void {
    if (this.syncHandshakeTimeoutId >= 0) {
      clearTimeout(this.syncHandshakeTimeoutId);
      this.syncHandshakeTimeoutId = -1;
    }
  }

  private async sendControlProbe(): Promise<void> {
    const client = this.p2pClient;
    const peer = this.peer;
    const appParam = this.appParam;
    if (client === undefined || peer === undefined || appParam === undefined ||
      this.activeControlRequestId.length === 0) {
      return;
    }
    const probe: WatchSyncProtocolMessage = {
      version: WATCH_SYNC_PROTOCOL_VERSION,
      type: WATCH_CONTROL_PROBE,
      requestId: this.activeControlRequestId
    };
    try {
      await sendProtocolMessage(client, peer, appParam, probe);
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
      this.activeControlRequestId.length === 0 || this.controlCommandSent) {
      return;
    }
    this.controlCommandSent = true;
    const command: WatchSyncProtocolMessage = {
      version: WATCH_SYNC_PROTOCOL_VERSION,
      type: WATCH_RECORDING_COMMAND,
      requestId: this.activeControlRequestId,
      desiredState: this.desiredControlState,
      sentAt: Date.now()
    };
    try {
      await sendProtocolMessage(client, peer, appParam, command);
      this.emitControl(true, '', '录音命令已送达，等待手表实际状态回执…');
    } catch (error) {
      this.controlCommandSent = false;
      this.emitControl(true, '', `命令暂未送达，等待重连：${wearEngineErrorMessage(error)}`);
    }
  }

  private handleRecordingAck(message: WatchSyncProtocolMessage): void {
    this.clearControlTimeout();
    const succeeded = message.success === true;
    const actualState = message.actualState || '';
    const detail = message.message || (succeeded ? '手表已完成录音控制' : '手表录音控制失败');
    if (succeeded && actualState === 'pending_user_action') {
      this.emitControl(true, actualState, detail);
      this.controlTimeoutId = setTimeout(() => {
        if (this.activeControlRequestId.length === 0) {
          return;
        }
        this.emitControl(false, 'pending_user_action', '等待手表点击通知已超时，请重新发起');
        this.activeControlRequestId = '';
        this.desiredControlState = '';
        this.controlCommandSent = false;
        this.controlTimeoutId = -1;
      }, PENDING_USER_ACTION_TIMEOUT_MS);
      return;
    }
    this.emitControl(false, actualState, detail);
    this.activeControlRequestId = '';
    this.desiredControlState = '';
    this.controlCommandSent = false;
  }

  private emitControl(inProgress: boolean, actualState: string, message: string): void {
    const status: WatchRecordingControlStatus = {
      requestId: this.activeControlRequestId,
      desiredState: this.desiredControlState,
      actualState: actualState,
      inProgress: inProgress,
      message: message
    };
    this.statusHandler(message);
    this.controlStatusHandler(status);
  }

  private clearControlTimeout(): void {
    if (this.controlTimeoutId >= 0) {
      clearTimeout(this.controlTimeoutId);
      this.controlTimeoutId = -1;
    }
  }

  private receiveFile(incoming: wearEngine.P2pFile): void {
    try {
      const sourceStat = fileIo.statSync(incoming.file.fd);
      if (sourceStat.size <= 0 || sourceStat.size > MAX_RECORDING_BYTES) {
        throw new Error('收到的录音为空或超过 10 MB 限制');
      }

      const descriptor = this.pendingFiles.length > 0 ? this.pendingFiles.shift() : undefined;
      if (descriptor !== undefined) {
        if (descriptor.size !== sourceStat.size) {
          throw new Error(`文件大小不符：期望 ${descriptor.size}，实际 ${sourceStat.size}`);
        }
        this.setTransferDescriptor(descriptor, 'saving', 100, true);
        this.emitProgress(this.syncRequestInProgress, `传输完成，正在安全保存：${descriptor.fileName}`);
        const existing = this.recordingStore.findExisting(descriptor);
        if (existing !== undefined) {
          this.receivedHandler(existing);
          const firstReceipt = this.markDescriptorReceived(descriptor);
          this.sendFileReceivedAck(descriptor);
          this.setTransferDescriptor(descriptor, 'waiting_ack', 100, true);
          if (descriptor.automatic === true) {
            this.emitProgress(this.syncRequestInProgress,
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
          this.emitProgress(this.syncRequestInProgress,
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
      fileIo.closeSync(incoming.file.fd);
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
    this.syncRequestInProgress = false;
    this.activeRequestId = '';
  }

  private markDescriptorReceived(descriptor: WatchSyncFileDescriptor): boolean {
    const key = fileTransferAckKey(descriptor);
    if (this.completedDescriptorKeys.has(key)) {
      return false;
    }
    this.completedDescriptorKeys.add(key);
    return true;
  }

  private sendFileReceivedAck(descriptor: WatchSyncFileDescriptor): void {
    const client = this.p2pClient;
    const peer = this.peer;
    const appParam = this.appParam;
    if (client === undefined || peer === undefined || appParam === undefined) {
      this.setTransferDescriptor(descriptor, 'waiting_ack', 100, false);
      this.emitProgress(this.syncRequestInProgress, '文件已保存，等待 Wear Engine 重连后补发确认回执');
      return;
    }
    const ack: WatchSyncProtocolMessage = {
      version: WATCH_SYNC_PROTOCOL_VERSION,
      type: WATCH_SYNC_FILE_RECEIVED,
      requestId: descriptor.requestId,
      file: descriptor
    };
    sendProtocolMessage(client, peer, appParam, ack).catch(() => {
      this.setTransferDescriptor(descriptor, 'waiting_ack', 100, false);
      this.emitProgress(this.syncRequestInProgress, '文件已保存，确认回执暂未送达，手表将安全重试');
    });
  }

  private copyIncomingFileDurably(sourceFd: number, finalPath: string): void {
    copyFileAtomically(sourceFd, finalPath);
  }

  private removePendingFile(descriptor: WatchSyncFileDescriptor): void {
    for (let index = 0; index < this.pendingFiles.length; index += 1) {
      const pending = this.pendingFiles[index];
      if (pending.requestId === descriptor.requestId && pending.index === descriptor.index &&
        pending.relativePath === descriptor.relativePath) {
        this.pendingFiles.splice(index, 1);
        return;
      }
    }
  }

  private addPendingFile(descriptor: WatchSyncFileDescriptor): void {
    for (let index = 0; index < this.pendingFiles.length; index += 1) {
      const pending = this.pendingFiles[index];
      if (pending.requestId === descriptor.requestId && pending.index === descriptor.index &&
        pending.relativePath === descriptor.relativePath) {
        return;
      }
    }
    this.pendingFiles.push(descriptor);
  }

  private emitProgress(inProgress: boolean, message: string): void {
    const progress: WatchSyncProgress = {
      requestId: this.activeRequestId,
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
