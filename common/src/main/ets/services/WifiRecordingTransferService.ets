import { common, wantAgent } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, hash } from '@kit.CoreFileKit';
import { mdns, socket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ReceivedRecordingFile, RecordingFile } from '../models/RecordingModels';
import { exactWatchFileKey, legacyWatchFileKey } from '../sync/protocol/WatchFileSyncProtocol';

const SERVICE_TYPE: string = '_alldayrecording._tcp';
const SERVICE_NAME: string = 'AllDayRecordingReceiver';
const SERVER_PORT: number = 38521;
const PROTOCOL_NAME: string = 'ALL_DAY_RECORDING_WIFI_V1';
const SYNC_RECEIVE_DIRECTORY: string = 'synced_from_watch';
const PACKET_LENGTH_BYTES: number = 4;
const FRAME_HEADER_BYTES: number = 9;
const PACKET_OVERHEAD_BYTES: number = PACKET_LENGTH_BYTES + FRAME_HEADER_BYTES;
const WIFI_CHUNK_BYTES: number = 128 * 1024;
const MAX_PACKET_BYTES: number = WIFI_CHUNK_BYTES + FRAME_HEADER_BYTES;
const MAX_FILE_BYTES: number = 512 * 1024 * 1024;
const DISCOVERY_TIMEOUT_MS: number = 12000;
const CONNECT_TIMEOUT_MS: number = 8000;
const READY_TIMEOUT_MS: number = 15000;
const ACK_TIMEOUT_MS: number = 120000;
const BACKGROUND_TASK_REQUEST_CODE: number = 1254;
const LOG_DOMAIN: number = 0x5746;
const LOG_TAG: string = 'WifiRecordingTransfer';

const FRAME_START: number = 1;
const FRAME_DATA: number = 2;
const FRAME_END: number = 3;
const FRAME_ACK: number = 4;
const FRAME_ERROR: number = 5;
const FRAME_READY: number = 6;
const FRAME_BATCH_END: number = 7;
const FRAME_BATCH_ACK: number = 8;

export type WifiTransferUpdateHandler = (status: string, progress: number) => void;
export type WifiRecordingReceivedHandler = (recording: ReceivedRecordingFile, sha256: string) => void;
export type WifiExistingRecordingHandler =
  (sourcePath: string, size: number) => ReceivedRecordingFile | undefined;

export interface WifiTransferBatchResult {
  total: number;
  transferred: number;
  alreadyPresent: number;
}

export type WifiTransferBatchCompletedHandler = (result: WifiTransferBatchResult) => void;

interface TransferMetadata {
  protocol: string;
  version: number;
  transferToken: number;
  fileName: string;
  sourcePath: string;
  size: number;
  durationMs: number;
  sha256: string;
  chunkSize: number;
  batchIndex: number;
  batchTotal: number;
}

interface TransferAck {
  transferToken: number;
  size: number;
  sha256: string;
}

interface TransferError {
  transferToken: number;
  message: string;
}

interface TransferBatchSummary extends WifiTransferBatchResult {
  protocol: string;
  version: number;
  batchToken: number;
}

interface ReceivingFile {
  transferToken: number;
  requestId: string;
  fileName: string;
  sourcePath: string;
  durationMs: number;
  fd: number;
  partPath: string;
  finalPath: string;
  expectedSize: number;
  expectedHash: string;
  expectedChunkSize: number;
  batchIndex: number;
  batchTotal: number;
  receivedSize: number;
  nextSequence: number;
  startedAt: number;
}

interface RecordingCandidate extends RecordingFile {
  modifiedAt: number;
  relativePath: string;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, milliseconds);
  });
}

function encodeJson(value: Object): ArrayBuffer {
  return util.TextEncoder.create('utf-8').encodeInto(JSON.stringify(value)).buffer;
}

function decodeJson<T>(value: ArrayBuffer): T {
  const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(value));
  return JSON.parse(text) as T;
}

function encodePacket(type: number, transferToken: number, sequence: number, payload: ArrayBuffer): ArrayBuffer {
  const frameLength = FRAME_HEADER_BYTES + payload.byteLength;
  const packet = new Uint8Array(PACKET_LENGTH_BYTES + frameLength);
  const view = new DataView(packet.buffer);
  view.setUint32(0, frameLength, false);
  packet[PACKET_LENGTH_BYTES] = type;
  view.setUint32(PACKET_LENGTH_BYTES + 1, transferToken, false);
  view.setUint32(PACKET_LENGTH_BYTES + 5, sequence, false);
  packet.set(new Uint8Array(payload), PACKET_OVERHEAD_BYTES);
  return packet.buffer;
}

function framePayload(frame: ArrayBuffer): ArrayBuffer {
  return frame.slice(FRAME_HEADER_BYTES);
}

export function sanitizeWifiRecordingFileName(fileName: string): string {
  return fileName.replace(/[^A-Za-z0-9._-]/g, '_');
}

export function isSafeWifiRecordingSourcePath(sourcePath: string): boolean {
  return sourcePath.length > 0 && !sourcePath.startsWith('/') && !sourcePath.includes('..') &&
    (sourcePath.toLowerCase().endsWith('.wav') || sourcePath.toLowerCase().endsWith('.m4a'));
}

export function isExactWifiRecordingMatch(incomingSourcePath: string, incomingSize: number,
  incomingSha256: string, existingSourcePath: string, existingSize: number,
  existingSha256: string): boolean {
  return incomingSourcePath === existingSourcePath && incomingSize === existingSize &&
    incomingSha256.toLowerCase() === existingSha256.toLowerCase();
}

function transferRateText(bytes: number, elapsedMs: number): string {
  const safeElapsedMs = Math.max(1, elapsedMs);
  const mibPerSecond = bytes * 1000 / safeElapsedMs / 1024 / 1024;
  return `${(safeElapsedMs / 1000).toFixed(1)} 秒，${mibPerSecond.toFixed(2)} MiB/s`;
}

function errorMessage(error: Object): string {
  const businessError = error as BusinessError;
  switch (businessError.code) {
    case 201:
      return '网络权限未授予（201）';
    case 801:
      return '当前设备不支持所需网络能力（801）';
    case 2204006:
      return '局域网服务解析超时（2204006）';
    case 2303198:
      return 'Wi-Fi 接收端口已被占用（2303198）';
    case 2300002:
      return '网络服务内部错误（2300002）';
    default:
      if (businessError.message !== undefined && businessError.message.length > 0) {
        return businessError.code === undefined ? businessError.message :
          `${businessError.message}（${businessError.code}）`;
      }
      return error instanceof Error ? error.message : '未知错误';
  }
}

function accessFileChecked(path: string): boolean {
  try {
    return fileIo.accessSync(path);
  } catch (error) {
    throw new Error(errorMessage(error as Object));
  }
}

function statFileChecked(path: string): fileIo.Stat {
  try {
    return fileIo.statSync(path);
  } catch (error) {
    throw new Error(errorMessage(error as Object));
  }
}

function isDirectoryChecked(stat: fileIo.Stat): boolean {
  try {
    return stat.isDirectory();
  } catch (error) {
    throw new Error(errorMessage(error as Object));
  }
}

function listFilesChecked(path: string): Array<string> {
  try {
    return fileIo.listFileSync(path);
  } catch (error) {
    throw new Error(errorMessage(error as Object));
  }
}

function openReadOnlyChecked(path: string): fileIo.File {
  try {
    return fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
  } catch (error) {
    throw new Error(errorMessage(error as Object));
  }
}

function readFileChecked(fd: number, buffer: ArrayBuffer): number {
  try {
    return fileIo.readSync(fd, buffer);
  } catch (error) {
    throw new Error(errorMessage(error as Object));
  }
}

function closeFileChecked(fd: number): void {
  try {
    fileIo.closeSync(fd);
  } catch (error) {
    throw new Error(errorMessage(error as Object));
  }
}

function ensureDirectoryChecked(path: string): void {
  try {
    if (!fileIo.accessSync(path)) {
      fileIo.mkdirSync(path);
    }
  } catch (error) {
    throw new Error(errorMessage(error as Object));
  }
}

function createOutputFileChecked(path: string): fileIo.File {
  try {
    return fileIo.openSync(path,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  } catch (error) {
    throw new Error(errorMessage(error as Object));
  }
}

function writeFileChecked(fd: number, payload: ArrayBuffer): number {
  try {
    return fileIo.writeSync(fd, payload);
  } catch (error) {
    throw new Error(errorMessage(error as Object));
  }
}

async function hashFileChecked(path: string): Promise<string> {
  try {
    return (await hash.hash(path, 'sha256')).toLowerCase();
  } catch (error) {
    throw new Error(errorMessage(error as Object));
  }
}

export function wifiRecordingTransferErrorMessage(error: Object): string {
  return errorMessage(error);
}

export class WifiRecordingTransferService {
  private context: common.UIAbilityContext;
  private updateHandler: WifiTransferUpdateHandler;
  private receivedHandler: WifiRecordingReceivedHandler;
  private serverSocket: socket.TCPSocketServer | undefined = undefined;
  private clientSocket: socket.TCPSocket | undefined = undefined;
  private serverConnection: socket.TCPSocketConnection | undefined = undefined;
  private registeredService: mdns.LocalServiceInfo | undefined = undefined;
  private serverConnectCallback: ((connection: socket.TCPSocketConnection) => void) | undefined = undefined;
  private serverErrorCallback: ((error: BusinessError) => void) | undefined = undefined;
  private messageCallback: ((info: socket.SocketMessageInfo) => void) | undefined = undefined;
  private closeCallback: (() => void) | undefined = undefined;
  private peerErrorCallback: ((error: BusinessError) => void) | undefined = undefined;
  private streamBuffer: Uint8Array = new Uint8Array(0);
  private incomingQueue: Promise<void> = Promise.resolve();
  private receivingFile: ReceivingFile | undefined = undefined;
  private readyToken: number = 0;
  private finalAck: TransferAck | undefined = undefined;
  private batchAckToken: number = 0;
  private remoteFailureMessage: string = '';
  private backgroundTaskActive: boolean = false;
  private sending: boolean = false;
  private closingPeer: boolean = false;
  private lastProgress: number = 0;
  private existingRecordingHandler: WifiExistingRecordingHandler | undefined;
  private batchCompletedHandler: WifiTransferBatchCompletedHandler | undefined;

  constructor(context: common.UIAbilityContext, updateHandler: WifiTransferUpdateHandler,
    receivedHandler: WifiRecordingReceivedHandler,
    existingRecordingHandler?: WifiExistingRecordingHandler,
    batchCompletedHandler?: WifiTransferBatchCompletedHandler) {
    this.context = context;
    this.updateHandler = updateHandler;
    this.receivedHandler = receivedHandler;
    this.existingRecordingHandler = existingRecordingHandler;
    this.batchCompletedHandler = batchCompletedHandler;
  }

  describeCapability(): string {
    if (!canIUse('SystemCapability.Communication.NetStack')) {
      return '系统未提供 TCP 网络能力';
    }
    if (!canIUse('SystemCapability.Communication.NetManager.MDNS')) {
      return '系统未提供局域网自动发现能力';
    }
    return 'Wi-Fi 快传可用（两端需连接同一 WLAN）';
  }

  findLatestRecording(): RecordingFile | undefined {
    const candidates: Array<RecordingCandidate> = [];
    this.collectRecordingCandidates(this.context.filesDir, '', candidates);
    let latest: RecordingCandidate | undefined = undefined;
    for (let index = 0; index < candidates.length; index += 1) {
      const candidate = candidates[index];
      if (latest === undefined || candidate.modifiedAt > latest.modifiedAt) {
        latest = candidate;
      }
    }
    if (latest === undefined) {
      return undefined;
    }
    return {
      fileName: latest.fileName,
      path: latest.path,
      size: latest.size,
      durationMs: latest.durationMs
    };
  }

  findAllRecordings(): Array<RecordingFile> {
    const candidates: Array<RecordingCandidate> = [];
    this.collectRecordingCandidates(this.context.filesDir, '', candidates);
    candidates.sort((left: RecordingCandidate, right: RecordingCandidate): number =>
      left.relativePath.localeCompare(right.relativePath));
    const result: Array<RecordingFile> = [];
    for (let index = 0; index < candidates.length; index += 1) {
      const candidate = candidates[index];
      result.push({
        fileName: candidate.fileName,
        path: candidate.path,
        size: candidate.size,
        durationMs: candidate.durationMs
      });
    }
    return result;
  }

  async prepareReceiver(): Promise<void> {
    this.assertReady();
    if (this.serverSocket !== undefined) {
      this.update('手机 Wi-Fi 接收已就绪，请到手表同步全部录音', 0);
      return;
    }
    await this.startBackgroundTransfer();
    try {
      const server = socket.constructTCPSocketServerInstance();
      this.serverSocket = server;
      this.serverConnectCallback = (connection: socket.TCPSocketConnection): void => {
        this.attachServerConnection(connection).catch((error: Object): void => {
          this.abortReceive(errorMessage(error));
        });
      };
      this.serverErrorCallback = (error: BusinessError): void => {
        this.abortReceive(errorMessage(error));
      };
      server.on('connect', this.serverConnectCallback);
      server.on('error', this.serverErrorCallback);
      await server.listen({ address: '0.0.0.0', family: 1, port: SERVER_PORT });
      const advertised: mdns.LocalServiceInfo = {
        serviceType: SERVICE_TYPE,
        serviceName: SERVICE_NAME,
        port: SERVER_PORT,
        serviceAttribute: [{
          key: 'protocol',
          value: Array.from(util.TextEncoder.create('utf-8').encodeInto(PROTOCOL_NAME))
        }]
      };
      this.registeredService = await mdns.addLocalService(this.context, advertised);
      this.update('手机 Wi-Fi 接收已就绪，请到手表同步全部录音', 0);
    } catch (error) {
      await this.shutdownTransport();
      await this.stopBackgroundTransfer();
      throw new Error(errorMessage(error as Object));
    }
  }

  async stopReceiver(): Promise<void> {
    this.closeReceivingFile('已停止 Wi-Fi 接收，未完成的临时文件已保留');
    await this.shutdownTransport();
    await this.stopBackgroundTransfer();
    this.update('已停止 Wi-Fi 接收', 0);
  }

  async send(recording: RecordingFile): Promise<void> {
    await this.sendAll([recording]);
  }

  async sendAll(recordings: Array<RecordingFile>): Promise<WifiTransferBatchResult> {
    if (this.sending) {
      throw new Error('录音正在通过 Wi-Fi 批量发送，请勿重复操作');
    }
    this.assertReady();
    if (recordings.length === 0) {
      throw new Error('没有找到可同步的完整录音');
    }

    this.sending = true;
    const result: WifiTransferBatchResult = {
      total: recordings.length,
      transferred: 0,
      alreadyPresent: 0
    };
    try {
      await this.startBackgroundTransfer();
      this.update('正在同一 Wi-Fi 中自动查找手机', 2);
      this.batchAckToken = 0;
      const receiver = await this.discoverReceiver();
      await this.connectReceiver(receiver);
      const batchToken = Math.max(1, Math.floor(Date.now() % 4294967295));
      for (let index = 0; index < recordings.length; index += 1) {
        const transferred = await this.sendBatchRecording(recordings[index], index + 1,
          recordings.length, batchToken);
        if (transferred) {
          result.transferred += 1;
        } else {
          result.alreadyPresent += 1;
        }
      }
      const summary: TransferBatchSummary = {
        protocol: PROTOCOL_NAME,
        version: 1,
        batchToken: batchToken,
        total: result.total,
        transferred: result.transferred,
        alreadyPresent: result.alreadyPresent
      };
      await this.writePacket(FRAME_BATCH_END, batchToken, recordings.length, encodeJson(summary));
      await this.waitForBatchAck(batchToken);
      this.update(`Wi-Fi 全量同步完成：新增 ${result.transferred} 个，已存在 ${result.alreadyPresent} 个`, 100);
      return result;
    } finally {
      this.sending = false;
      await this.closePeer();
      await this.stopBackgroundTransfer();
    }
  }

  private async sendBatchRecording(recording: RecordingFile, batchIndex: number,
    batchTotal: number, batchToken: number): Promise<boolean> {
    if (!accessFileChecked(recording.path)) {
      throw new Error(`手表中找不到待发送录音：${recording.fileName}`);
    }
    const fileStat = statFileChecked(recording.path);
    if (isDirectoryChecked(fileStat) || fileStat.size <= 0 || fileStat.size > MAX_FILE_BYTES) {
      throw new Error(`待发送录音为空或超过 512 MB 限制：${recording.fileName}`);
    }
    const sourcePath = this.relativeSourcePath(recording.path);
    if (!isSafeWifiRecordingSourcePath(sourcePath)) {
      throw new Error(`待发送录音路径无效：${recording.fileName}`);
    }
    this.updateBatchProgress(`正在计算 ${batchIndex}/${batchTotal} 的 SHA-256`, batchIndex, batchTotal, 1);
    const sourceHash = await hashFileChecked(recording.path);
    const transferToken = Math.max(1, Math.floor((batchToken + batchIndex) % 4294967295));
    const metadata: TransferMetadata = {
      protocol: PROTOCOL_NAME,
      version: 1,
      transferToken: transferToken,
      fileName: recording.fileName,
      sourcePath: sourcePath,
      size: fileStat.size,
      durationMs: recording.durationMs,
      sha256: sourceHash,
      chunkSize: WIFI_CHUNK_BYTES,
      batchIndex: batchIndex,
      batchTotal: batchTotal
    };
    this.readyToken = 0;
    this.finalAck = undefined;
    this.remoteFailureMessage = '';
    await this.writePacket(FRAME_START, transferToken, 0, encodeJson(metadata));
    if (!await this.waitForReady(metadata)) {
      this.updateBatchProgress(`手机已有 ${batchIndex}/${batchTotal}：${recording.fileName}`,
        batchIndex, batchTotal, 100);
      return false;
    }
    await this.sendFile(recording.path, metadata);
    return true;
  }

  stop(): void {
    this.closeReceivingFile('应用退出，Wi-Fi 临时文件已保留');
    this.shutdownTransport().then((): Promise<void> => {
      return this.stopBackgroundTransfer();
    }).catch((): void => {
    });
  }

  async shutdown(): Promise<void> {
    this.closeReceivingFile('应用退出，Wi-Fi 临时文件已保留');
    await this.shutdownTransport();
    await this.stopBackgroundTransfer();
  }

  private assertReady(): void {
    if (!canIUse('SystemCapability.Communication.NetStack')) {
      throw new Error('当前系统未提供 TCP 网络能力');
    }
    if (!canIUse('SystemCapability.Communication.NetManager.MDNS')) {
      throw new Error('当前系统未提供局域网自动发现能力');
    }
  }

  private collectRecordingCandidates(filesDirectory: string, relativeDirectory: string,
    result: Array<RecordingCandidate>): void {
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
        this.collectRecordingCandidates(filesDirectory, relativePath, result);
        continue;
      }
      const lowerName = fileName.toLowerCase();
      if ((!lowerName.endsWith('.wav') && !lowerName.endsWith('.m4a')) || lowerName.endsWith('.part') ||
        stat.size <= 0 || stat.size > MAX_FILE_BYTES) {
        continue;
      }
      const modifiedAt = Math.round(stat.mtime * 1000);
      result.push({
        fileName: fileName,
        path: path,
        size: stat.size,
        durationMs: 0,
        modifiedAt: modifiedAt,
        relativePath: relativePath
      });
    }
  }

  private relativeSourcePath(path: string): string {
    const prefix = `${this.context.filesDir}/`;
    if (!path.startsWith(prefix)) {
      throw new Error('只能发送应用录音目录中的文件');
    }
    return path.substring(prefix.length);
  }

  private discoverReceiver(): Promise<mdns.LocalServiceInfo> {
    return new Promise<mdns.LocalServiceInfo>((resolve: (value: mdns.LocalServiceInfo) => void,
      reject: (error: Error) => void) => {
      const discovery = mdns.createDiscoveryService(this.context, SERVICE_TYPE);
      let settled = false;
      let resolving = false;
      let timeoutId = -1;

      const cleanup = (): void => {
        if (timeoutId >= 0) {
          clearTimeout(timeoutId);
        }
        try {
          discovery.off('serviceFound', foundCallback);
          discovery.stopSearchingMDNS();
        } catch (error) {
        }
      };

      const foundCallback = (serviceInfo: mdns.LocalServiceInfo): void => {
        if (settled || resolving || serviceInfo.serviceName.indexOf(SERVICE_NAME) !== 0) {
          return;
        }
        resolving = true;
        mdns.resolveLocalService(this.context, serviceInfo).then((resolved: mdns.LocalServiceInfo): void => {
          resolving = false;
          if (settled) {
            return;
          }
          if (resolved.host === undefined || resolved.host.address.length === 0 ||
            resolved.port === undefined || resolved.port <= 0) {
            return;
          }
          settled = true;
          cleanup();
          resolve(resolved);
        }).catch((error: Object): void => {
          resolving = false;
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'mDNS resolve failed: %{public}s', errorMessage(error));
        });
      };

      discovery.on('serviceFound', foundCallback);
      timeoutId = setTimeout((): void => {
        if (settled) {
          return;
        }
        settled = true;
        cleanup();
        reject(new Error('12 秒内未发现手机；请确认两端连接同一 Wi-Fi，且手机已开启 Wi-Fi 接收'));
      }, DISCOVERY_TIMEOUT_MS);
      try {
        discovery.startSearchingMDNS();
      } catch (error) {
        settled = true;
        cleanup();
        reject(new Error(errorMessage(error as Object)));
      }
    });
  }

  private async connectReceiver(receiver: mdns.LocalServiceInfo): Promise<void> {
    const host = receiver.host;
    const port = receiver.port;
    if (host === undefined || port === undefined) {
      throw new Error('手机局域网地址无效');
    }
    const family = host.family === 2 || host.address.indexOf(':') >= 0 ? 2 : 1;
    const client = socket.constructTCPSocketInstance();
    this.clientSocket = client;
    this.attachPeerCallbacks(client);
    try {
      await client.bind({ address: family === 2 ? '::' : '0.0.0.0', family: family, port: 0 });
      await client.setExtraOptions({
        TCPNoDelay: true,
        keepAlive: true,
        sendBufferSize: 512 * 1024,
        receiveBufferSize: 512 * 1024
      });
      this.update(`已发现手机 ${host.address}，正在建立 Wi-Fi 连接`, 3);
      await client.connect({
        address: { address: host.address, family: family, port: port },
        timeout: CONNECT_TIMEOUT_MS
      });
    } catch (error) {
      throw new Error(errorMessage(error as Object));
    }
  }

  private async attachServerConnection(connection: socket.TCPSocketConnection): Promise<void> {
    await this.closePeer();
    this.serverConnection = connection;
    this.attachPeerCallbacks(connection);
    this.update('手表已通过 Wi-Fi 连接，等待文件元数据', 0);
  }

  private attachPeerCallbacks(peer: socket.TCPSocket | socket.TCPSocketConnection): void {
    this.streamBuffer = new Uint8Array(0);
    this.incomingQueue = Promise.resolve();
    this.messageCallback = (info: socket.SocketMessageInfo): void => {
      const copiedData = info.message.slice(0);
      this.incomingQueue = this.incomingQueue.then(async (): Promise<void> => {
        await this.consumeIncoming(copiedData);
      }).catch((error: Object): void => {
        this.abortReceive(errorMessage(error));
      });
    };
    this.closeCallback = (): void => {
      if (this.closingPeer) {
        return;
      }
      if (this.receivingFile !== undefined) {
        this.abortReceive('Wi-Fi 连接在文件完成前关闭');
      } else if (this.sending && this.batchAckToken === 0) {
        this.remoteFailureMessage = '手机提前关闭了 Wi-Fi 连接';
      }
    };
    this.peerErrorCallback = (error: BusinessError): void => {
      if (this.closingPeer) {
        return;
      }
      const message = errorMessage(error);
      if (this.receivingFile !== undefined) {
        this.abortReceive(message);
      } else {
        this.remoteFailureMessage = message;
      }
    };
    peer.on('message', this.messageCallback);
    peer.on('close', this.closeCallback);
    peer.on('error', this.peerErrorCallback);
  }

  private async sendFile(sourcePath: string, metadata: TransferMetadata): Promise<void> {
    const input = openReadOnlyChecked(sourcePath);
    let totalRead = 0;
    let sequence = 0;
    const startedAt = Date.now();
    this.updateBatchProgress(`开始发送 ${metadata.batchIndex}/${metadata.batchTotal}（${metadata.chunkSize /
      1024} KiB/片）`, metadata.batchIndex, metadata.batchTotal, 4);
    try {
      while (totalRead < metadata.size) {
        const buffer = new ArrayBuffer(Math.min(metadata.chunkSize, metadata.size - totalRead));
        const bytesRead = readFileChecked(input.fd, buffer);
        if (bytesRead <= 0) {
          throw new Error('读取手表录音时提前到达文件末尾');
        }
        sequence += 1;
        await this.writePacket(FRAME_DATA, metadata.transferToken, sequence, buffer.slice(0, bytesRead));
        totalRead += bytesRead;
        if (totalRead === metadata.size || sequence % 8 === 0) {
          const progress = Math.min(98, Math.floor(totalRead * 100 / metadata.size));
          this.updateBatchProgress(`正在发送 ${metadata.batchIndex}/${metadata.batchTotal}：${totalRead}/${
            metadata.size} 字节`, metadata.batchIndex, metadata.batchTotal, progress);
        }
      }
    } finally {
      closeFileChecked(input.fd);
    }
    await this.writePacket(FRAME_END, metadata.transferToken, sequence, encodeJson(metadata));
    this.updateBatchProgress(`第 ${metadata.batchIndex}/${metadata.batchTotal} 个已发完，等待手机校验`,
      metadata.batchIndex, metadata.batchTotal, 99);
    await this.waitForFinalAck(metadata.transferToken);
    const ack = this.finalAck;
    if (ack === undefined || ack.sha256.toLowerCase() !== metadata.sha256.toLowerCase() ||
      ack.size !== metadata.size) {
      throw new Error('手机最终确认与手表源文件不一致');
    }
    this.updateBatchProgress(`第 ${metadata.batchIndex}/${metadata.batchTotal} 个已校验（${transferRateText(
      ack.size, Date.now() - startedAt)}）`, metadata.batchIndex, metadata.batchTotal, 100);
  }

  private async writePacket(type: number, transferToken: number, sequence: number,
    payload: ArrayBuffer): Promise<void> {
    const packet = encodePacket(type, transferToken, sequence, payload);
    if (this.clientSocket !== undefined) {
      try {
        await this.clientSocket.send({ data: packet });
      } catch (error) {
        throw new Error(errorMessage(error as Object));
      }
      return;
    }
    if (this.serverConnection !== undefined) {
      try {
        await this.serverConnection.send({ data: packet });
      } catch (error) {
        throw new Error(errorMessage(error as Object));
      }
      return;
    }
    throw new Error('Wi-Fi TCP 尚未连接');
  }

  private async consumeIncoming(data: ArrayBuffer): Promise<void> {
    const incoming = new Uint8Array(data);
    const combined = new Uint8Array(this.streamBuffer.byteLength + incoming.byteLength);
    combined.set(this.streamBuffer, 0);
    combined.set(incoming, this.streamBuffer.byteLength);
    let offset = 0;
    while (combined.byteLength - offset >= PACKET_LENGTH_BYTES) {
      const frameLength = new DataView(combined.buffer, combined.byteOffset + offset,
        combined.byteLength - offset).getUint32(0, false);
      if (frameLength < FRAME_HEADER_BYTES || frameLength > MAX_PACKET_BYTES) {
        throw new Error(`Wi-Fi 数据帧长度无效：${frameLength}`);
      }
      const packetLength = PACKET_LENGTH_BYTES + frameLength;
      if (combined.byteLength - offset < packetLength) {
        break;
      }
      const frameBytes = combined.slice(offset + PACKET_LENGTH_BYTES, offset + packetLength);
      const frame = new ArrayBuffer(frameBytes.byteLength);
      new Uint8Array(frame).set(frameBytes);
      await this.handleFrame(frame);
      offset += packetLength;
    }
    this.streamBuffer = combined.slice(offset);
  }

  private async handleFrame(frame: ArrayBuffer): Promise<void> {
    const bytes = new Uint8Array(frame);
    const view = new DataView(frame);
    const type = bytes[0];
    const transferToken = view.getUint32(1, false);
    const sequence = view.getUint32(5, false);
    const payload = framePayload(frame);
    if (type === FRAME_START) {
      await this.beginReceive(transferToken, decodeJson<TransferMetadata>(payload));
      return;
    }
    if (type === FRAME_DATA) {
      this.writeReceiveChunk(transferToken, sequence, payload);
      return;
    }
    if (type === FRAME_END) {
      await this.finishReceive(transferToken, sequence, decodeJson<TransferMetadata>(payload));
      return;
    }
    if (type === FRAME_BATCH_END) {
      await this.finishBatch(transferToken, sequence, decodeJson<TransferBatchSummary>(payload));
      return;
    }
    if (type === FRAME_READY) {
      const ready = decodeJson<TransferAck>(payload);
      if (ready.transferToken === transferToken) {
        this.readyToken = transferToken;
      }
      return;
    }
    if (type === FRAME_ACK) {
      const ack = decodeJson<TransferAck>(payload);
      if (ack.transferToken === transferToken) {
        this.finalAck = ack;
      }
      return;
    }
    if (type === FRAME_BATCH_ACK) {
      const summary = decodeJson<TransferBatchSummary>(payload);
      if (summary.batchToken === transferToken) {
        this.batchAckToken = transferToken;
      }
      return;
    }
    if (type === FRAME_ERROR) {
      const transferError = decodeJson<TransferError>(payload);
      this.remoteFailureMessage = transferError.message;
      this.update(`对端 Wi-Fi 处理失败：${transferError.message}`, 0);
    }
  }

  private async beginReceive(transferToken: number, metadata: TransferMetadata): Promise<void> {
    if (metadata.protocol !== PROTOCOL_NAME || metadata.version !== 1 || metadata.transferToken !== transferToken ||
      metadata.size <= 0 || metadata.size > MAX_FILE_BYTES || metadata.sha256.length !== 64 ||
      metadata.chunkSize < 1024 || metadata.chunkSize > WIFI_CHUNK_BYTES ||
      !Number.isFinite(metadata.batchIndex) || !Number.isFinite(metadata.batchTotal) ||
      Math.floor(metadata.batchIndex) !== metadata.batchIndex || Math.floor(metadata.batchTotal) !== metadata.batchTotal ||
      metadata.batchIndex < 1 || metadata.batchTotal < 1 || metadata.batchIndex > metadata.batchTotal ||
      !isSafeWifiRecordingSourcePath(metadata.sourcePath)) {
      throw new Error('手表发送的 Wi-Fi 文件元数据无效');
    }
    if (this.receivingFile !== undefined && this.receivingFile.transferToken === transferToken) {
      await this.sendReady(metadata);
      return;
    }
    this.closeReceivingFile('新的 Wi-Fi 传输已开始，旧临时文件已保留');
    if (await this.findVerifiedExisting(metadata)) {
      const ack: TransferAck = {
        transferToken: transferToken,
        size: metadata.size,
        sha256: metadata.sha256.toLowerCase()
      };
      await this.writePacket(FRAME_ACK, transferToken, 0, encodeJson(ack));
      this.updateBatchProgress(`手机已存在 ${metadata.batchIndex}/${metadata.batchTotal}：${metadata.fileName}`,
        metadata.batchIndex, metadata.batchTotal, 100);
      return;
    }
    const syncRoot = `${this.context.filesDir}/${SYNC_RECEIVE_DIRECTORY}`;
    ensureDirectoryChecked(syncRoot);
    const requestId = `wifi_${Date.now()}_${transferToken}`;
    const requestDirectory = `${syncRoot}/${requestId}`;
    ensureDirectoryChecked(requestDirectory);
    const finalPath = `${requestDirectory}/001_${sanitizeWifiRecordingFileName(metadata.fileName)}`;
    const partPath = `${finalPath}.part`;
    const output = createOutputFileChecked(partPath);
    this.receivingFile = {
      transferToken: transferToken,
      requestId: requestId,
      fileName: metadata.fileName,
      sourcePath: metadata.sourcePath,
      durationMs: metadata.durationMs,
      fd: output.fd,
      partPath: partPath,
      finalPath: finalPath,
      expectedSize: metadata.size,
      expectedHash: metadata.sha256.toLowerCase(),
      expectedChunkSize: metadata.chunkSize,
      batchIndex: metadata.batchIndex,
      batchTotal: metadata.batchTotal,
      receivedSize: 0,
      nextSequence: 1,
      startedAt: Date.now()
    };
    this.updateBatchProgress(`开始接收 ${metadata.batchIndex}/${metadata.batchTotal}：${metadata.size} 字节`,
      metadata.batchIndex, metadata.batchTotal, 0);
    await this.sendReady(metadata);
  }

  private async findVerifiedExisting(metadata: TransferMetadata): Promise<boolean> {
    if (this.existingRecordingHandler === undefined) {
      return false;
    }
    const existing = this.existingRecordingHandler(metadata.sourcePath, metadata.size);
    if (existing === undefined || !accessFileChecked(existing.path)) {
      return false;
    }
    const stat = statFileChecked(existing.path);
    if (isDirectoryChecked(stat) || stat.size !== metadata.size) {
      return false;
    }
    const existingHash = await hashFileChecked(existing.path);
    return isExactWifiRecordingMatch(metadata.sourcePath, metadata.size, metadata.sha256,
      existing.sourcePath, existing.size, existingHash);
  }

  private async sendReady(metadata: TransferMetadata): Promise<void> {
    const ready: TransferAck = {
      transferToken: metadata.transferToken,
      size: metadata.size,
      sha256: metadata.sha256.toLowerCase()
    };
    await this.writePacket(FRAME_READY, metadata.transferToken, 0, encodeJson(ready));
  }

  private writeReceiveChunk(transferToken: number, sequence: number, payload: ArrayBuffer): void {
    const receiving = this.receivingFile;
    if (receiving === undefined || receiving.transferToken !== transferToken) {
      return;
    }
    if (sequence !== receiving.nextSequence) {
      throw new Error(`Wi-Fi 可靠流序号异常：期望 ${receiving.nextSequence}，收到 ${sequence}`);
    }
    if (payload.byteLength <= 0 || payload.byteLength > receiving.expectedChunkSize ||
      receiving.receivedSize + payload.byteLength > receiving.expectedSize) {
      throw new Error('Wi-Fi 接收分片长度无效');
    }
    let written = 0;
    while (written < payload.byteLength) {
      const writeCount = writeFileChecked(receiving.fd, payload.slice(written));
      if (writeCount <= 0) {
        throw new Error('手机写入 Wi-Fi 接收文件失败');
      }
      written += writeCount;
    }
    receiving.receivedSize += payload.byteLength;
    receiving.nextSequence += 1;
    if (receiving.receivedSize === receiving.expectedSize || sequence % 8 === 0) {
      const progress = Math.min(99, Math.floor(receiving.receivedSize * 100 / receiving.expectedSize));
      this.updateBatchProgress(`正在接收 ${receiving.batchIndex}/${receiving.batchTotal}：${
        receiving.receivedSize}/${receiving.expectedSize} 字节`, receiving.batchIndex, receiving.batchTotal, progress);
    }
  }

  private async finishReceive(transferToken: number, sequence: number, metadata: TransferMetadata): Promise<void> {
    const receiving = this.receivingFile;
    if (receiving === undefined || receiving.transferToken !== transferToken) {
      return;
    }
    this.receivingFile = undefined;
    try {
      if (metadata.protocol !== PROTOCOL_NAME || sequence !== receiving.nextSequence - 1 ||
        receiving.receivedSize !== receiving.expectedSize || metadata.size !== receiving.expectedSize ||
        metadata.sha256.toLowerCase() !== receiving.expectedHash || metadata.sourcePath !== receiving.sourcePath) {
        throw new Error('Wi-Fi 接收文件大小、序号或元数据不一致');
      }
      fileIo.fsyncSync(receiving.fd);
      fileIo.closeSync(receiving.fd);
      const receivedHash = (await hash.hash(receiving.partPath, 'sha256')).toLowerCase();
      if (receivedHash !== receiving.expectedHash) {
        throw new Error('Wi-Fi 接收文件 SHA-256 不一致，临时文件已保留');
      }
      fileIo.renameSync(receiving.partPath, receiving.finalPath);
      const recording: ReceivedRecordingFile = {
        fileName: receiving.fileName,
        path: receiving.finalPath,
        size: receiving.receivedSize,
        durationMs: receiving.durationMs,
        requestId: receiving.requestId,
        sourcePath: receiving.sourcePath,
        receivedAt: Date.now(),
        syncKey: exactWatchFileKey(receiving.sourcePath, receiving.receivedSize),
        legacySyncKey: legacyWatchFileKey(receiving.fileName, receiving.receivedSize)
      };
      this.receivedHandler(recording, receivedHash);
      const ack: TransferAck = {
        transferToken: transferToken,
        size: receiving.receivedSize,
        sha256: receivedHash
      };
      await this.writePacket(FRAME_ACK, transferToken, sequence, encodeJson(ack));
      this.updateBatchProgress(`第 ${receiving.batchIndex}/${receiving.batchTotal} 个接收并校验完成（${
        transferRateText(receiving.receivedSize, Date.now() - receiving.startedAt)}）`, receiving.batchIndex,
      receiving.batchTotal, 100);
    } catch (error) {
      try {
        fileIo.closeSync(receiving.fd);
      } catch (closeError) {
      }
      throw new Error(errorMessage(error as Object));
    }
  }

  private async finishBatch(batchToken: number, sequence: number, summary: TransferBatchSummary): Promise<void> {
    if (summary.protocol !== PROTOCOL_NAME || summary.version !== 1 || summary.batchToken !== batchToken ||
      !Number.isFinite(summary.total) || !Number.isFinite(summary.transferred) ||
      !Number.isFinite(summary.alreadyPresent) || Math.floor(summary.total) !== summary.total ||
      Math.floor(summary.transferred) !== summary.transferred ||
      Math.floor(summary.alreadyPresent) !== summary.alreadyPresent || sequence !== summary.total ||
      summary.total <= 0 || summary.transferred < 0 || summary.alreadyPresent < 0 ||
      summary.transferred + summary.alreadyPresent !== summary.total || this.receivingFile !== undefined) {
      throw new Error('手表发送的 Wi-Fi 批次汇总无效');
    }
    await this.writePacket(FRAME_BATCH_ACK, batchToken, summary.total, encodeJson(summary));
    this.update(`Wi-Fi 全量同步完成：新增 ${summary.transferred} 个，已存在 ${summary.alreadyPresent} 个`, 100);
    if (this.batchCompletedHandler !== undefined) {
      this.batchCompletedHandler({
        total: summary.total,
        transferred: summary.transferred,
        alreadyPresent: summary.alreadyPresent
      });
    }
    await delay(200);
    await this.shutdownTransport();
    await this.stopBackgroundTransfer();
  }

  private async waitForReady(metadata: TransferMetadata): Promise<boolean> {
    const startedAt = Date.now();
    while (Date.now() - startedAt < READY_TIMEOUT_MS) {
      if (this.remoteFailureMessage.length > 0) {
        throw new Error(this.remoteFailureMessage);
      }
      const ack = this.finalAck;
      if (ack !== undefined && ack.transferToken === metadata.transferToken) {
        if (ack.size !== metadata.size || ack.sha256.toLowerCase() !== metadata.sha256.toLowerCase()) {
          throw new Error('手机已有文件的确认与手表源文件不一致');
        }
        return false;
      }
      if (this.readyToken === metadata.transferToken) {
        return true;
      }
      await delay(20);
    }
    throw new Error('手机未在 15 秒内确认 Wi-Fi 文件元数据');
  }

  private async waitForFinalAck(transferToken: number): Promise<void> {
    const startedAt = Date.now();
    while (Date.now() - startedAt < ACK_TIMEOUT_MS) {
      if (this.finalAck !== undefined && this.finalAck.transferToken === transferToken) {
        return;
      }
      if (this.remoteFailureMessage.length > 0) {
        throw new Error(this.remoteFailureMessage);
      }
      await delay(20);
    }
    throw new Error('手机未返回 Wi-Fi 落盘确认；手表源文件仍保留');
  }

  private async waitForBatchAck(batchToken: number): Promise<void> {
    const startedAt = Date.now();
    while (Date.now() - startedAt < READY_TIMEOUT_MS) {
      if (this.batchAckToken === batchToken) {
        return;
      }
      if (this.remoteFailureMessage.length > 0) {
        throw new Error(this.remoteFailureMessage);
      }
      await delay(20);
    }
    throw new Error('手机未确认 Wi-Fi 批量同步完成；手表源文件仍保留');
  }

  private abortReceive(message: string): void {
    const receiving = this.receivingFile;
    if (receiving !== undefined) {
      this.receivingFile = undefined;
      try {
        fileIo.fsyncSync(receiving.fd);
      } catch (syncError) {
      }
      try {
        fileIo.closeSync(receiving.fd);
      } catch (closeError) {
      }
    }
    this.shutdownTransport().then((): Promise<void> => {
      return this.stopBackgroundTransfer();
    }).catch((): void => {
    });
    this.update(`Wi-Fi 接收失败，临时文件已保留：${message}`, 0);
  }

  private closeReceivingFile(message: string): void {
    const receiving = this.receivingFile;
    if (receiving === undefined) {
      return;
    }
    this.receivingFile = undefined;
    try {
      fileIo.fsyncSync(receiving.fd);
    } catch (syncError) {
    }
    try {
      fileIo.closeSync(receiving.fd);
    } catch (closeError) {
    }
    this.update(message, this.lastProgress);
  }

  private async closePeer(): Promise<void> {
    const client = this.clientSocket;
    const connection = this.serverConnection;
    this.clientSocket = undefined;
    this.serverConnection = undefined;
    this.closingPeer = true;
    try {
      if (client !== undefined) {
        try {
          client.off('message', this.messageCallback);
          client.off('close', this.closeCallback);
          client.off('error', this.peerErrorCallback);
        } catch (error) {
        }
        try {
          await client.close();
        } catch (error) {
        }
      }
      if (connection !== undefined) {
        try {
          connection.off('message', this.messageCallback);
          connection.off('close', this.closeCallback);
          connection.off('error', this.peerErrorCallback);
        } catch (error) {
        }
        try {
          await connection.close();
        } catch (error) {
        }
      }
    } finally {
      this.messageCallback = undefined;
      this.closeCallback = undefined;
      this.peerErrorCallback = undefined;
      this.streamBuffer = new Uint8Array(0);
      this.closingPeer = false;
    }
  }

  private async shutdownTransport(): Promise<void> {
    await this.closePeer();
    const registered = this.registeredService;
    this.registeredService = undefined;
    if (registered !== undefined) {
      try {
        await mdns.removeLocalService(this.context, registered);
      } catch (error) {
      }
    }
    const server = this.serverSocket;
    this.serverSocket = undefined;
    if (server !== undefined) {
      try {
        server.off('connect', this.serverConnectCallback);
        server.off('error', this.serverErrorCallback);
      } catch (error) {
      }
      try {
        await server.close();
      } catch (error) {
      }
    }
    this.serverConnectCallback = undefined;
    this.serverErrorCallback = undefined;
  }

  private update(status: string, progress: number): void {
    this.lastProgress = progress;
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s | progress=%{public}d', status, progress);
    this.updateHandler(status, progress);
  }

  private updateBatchProgress(status: string, batchIndex: number, batchTotal: number,
    fileProgress: number): void {
    const safeTotal = Math.max(1, batchTotal);
    const safeIndex = Math.max(1, Math.min(batchIndex, safeTotal));
    const safeFileProgress = Math.max(0, Math.min(fileProgress, 100));
    const progress = Math.min(99, Math.floor(((safeIndex - 1) * 100 + safeFileProgress) / safeTotal));
    this.update(status, progress);
  }

  private async startBackgroundTransfer(): Promise<void> {
    if (this.backgroundTaskActive) {
      return;
    }
    try {
      const notificationWantAgent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: this.context.applicationInfo.name,
          abilityName: 'EntryAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: BACKGROUND_TASK_REQUEST_CODE,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      await backgroundTaskManager.startBackgroundRunning(this.context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER, notificationWantAgent);
      this.backgroundTaskActive = true;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'Wi-Fi data-transfer continuous task started');
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'Wi-Fi continuous task unavailable: %{public}s',
        errorMessage(error as Object));
    }
  }

  private async stopBackgroundTransfer(): Promise<void> {
    if (!this.backgroundTaskActive) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
    } catch (error) {
    } finally {
      this.backgroundTaskActive = false;
    }
  }
}
