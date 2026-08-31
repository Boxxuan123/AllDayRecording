export class PhoneV3ProjectionRow {
  resourceId: string;
  revision: number;
  payloadJson: string;
  updatedAt: number;

  constructor(resourceId: string, revision: number, payloadJson: string, updatedAt: number) {
    this.resourceId = resourceId;
    this.revision = revision;
    this.payloadJson = payloadJson;
    this.updatedAt = updatedAt;
  }
}

export class PhoneV3LocalAudioFact {
  sessionKey: string;
  localGroupKey: string;
  paths: Array<string>;
  startedAt: number;
  receivedAt: number;
  sizeBytes: number;
  durationMs: number;

  constructor(sessionKey: string, localGroupKey: string, paths: Array<string>, startedAt: number, receivedAt: number,
    sizeBytes: number, durationMs: number) {
    this.sessionKey = sessionKey;
    this.localGroupKey = localGroupKey;
    this.paths = paths;
    this.startedAt = startedAt;
    this.receivedAt = receivedAt;
    this.sizeBytes = sizeBytes;
    this.durationMs = durationMs;
  }
}

export class PhoneV3LocalAudioLink {
  sessionKey: string;
  sessionId: string;
  localPath: string;
  uploadStatus: string;
  updatedAt: number;

  constructor(sessionKey: string, sessionId: string, localPath: string, uploadStatus: string,
    updatedAt: number) {
    this.sessionKey = sessionKey;
    this.sessionId = sessionId;
    this.localPath = localPath;
    this.uploadStatus = uploadStatus;
    this.updatedAt = updatedAt;
  }
}

export class PhoneV3Conflict {
  operationId: string;
  kind: string;
  errorJson: string;
  createdAt: number;

  constructor(operationId: string, kind: string, errorJson: string, createdAt: number) {
    this.operationId = operationId;
    this.kind = kind;
    this.errorJson = errorJson;
    this.createdAt = createdAt;
  }
}

export class PhoneV3SyncStatus {
  cursor: string;
  lastServerTime: string;
  lastError: string;
  pendingOperations: number;
  retryCount: number;

  constructor(cursor: string = 'cursor-0', lastServerTime: string = '', lastError: string = '',
    pendingOperations: number = 0, retryCount: number = 0) {
    this.cursor = cursor;
    this.lastServerTime = lastServerTime;
    this.lastError = lastError;
    this.pendingOperations = pendingOperations;
    this.retryCount = retryCount;
  }
}

export class PhoneV3Utterance {
  utteranceId: string;
  sessionId: string;
  startMs: number;
  endMs: number;
  text: string;
  revision: number;
  evidenceJson: string;

  constructor(utteranceId: string, sessionId: string, startMs: number, endMs: number, text: string,
    revision: number, evidenceJson: string) {
    this.utteranceId = utteranceId;
    this.sessionId = sessionId;
    this.startMs = startMs;
    this.endMs = endMs;
    this.text = text;
    this.revision = revision;
    this.evidenceJson = evidenceJson;
  }
}

export class PhoneV3SessionCard {
  id: string;
  sessionId: string;
  sessionKey: string;
  localGroupKey: string;
  capturedStart: string;
  startedAt: number;
  deviceName: string;
  state: string;
  statusCode: string;
  progress: number;
  revision: number;
  updatedAt: number;
  localPaths: Array<string>;
  sizeBytes: number;
  durationMs: number;
  uploadStatus: string;
  processingStatus: string;
  processingStage: string;
  processingProgress: number;
  utterances: Array<PhoneV3Utterance>;

  constructor(id: string, sessionId: string, sessionKey: string, localGroupKey: string, capturedStart: string,
    startedAt: number, deviceName: string, state: string, statusCode: string, progress: number,
    revision: number, updatedAt: number, localPaths: Array<string>, sizeBytes: number,
    durationMs: number, uploadStatus: string, processingStatus: string,
    processingStage: string, processingProgress: number, utterances: Array<PhoneV3Utterance>) {
    this.id = id;
    this.sessionId = sessionId;
    this.sessionKey = sessionKey;
    this.localGroupKey = localGroupKey;
    this.capturedStart = capturedStart;
    this.startedAt = startedAt;
    this.deviceName = deviceName;
    this.state = state;
    this.statusCode = statusCode;
    this.progress = progress;
    this.revision = revision;
    this.updatedAt = updatedAt;
    this.localPaths = localPaths;
    this.sizeBytes = sizeBytes;
    this.durationMs = durationMs;
    this.uploadStatus = uploadStatus;
    this.processingStatus = processingStatus;
    this.processingStage = processingStage;
    this.processingProgress = processingProgress;
    this.utterances = utterances;
  }
}

export class PhoneV3DeviceState {
  watchStatus: string;
  watchSyncing: boolean;
  watchReceived: number;
  watchTotal: number;
  isPlaying: boolean;
  playbackBusy: boolean;
  playbackPositionMs: number;
  playbackDurationMs: number;

  constructor(watchStatus: string = '正在连接手表', watchSyncing: boolean = false,
    watchReceived: number = 0, watchTotal: number = 0, isPlaying: boolean = false,
    playbackBusy: boolean = false, playbackPositionMs: number = 0, playbackDurationMs: number = 0) {
    this.watchStatus = watchStatus;
    this.watchSyncing = watchSyncing;
    this.watchReceived = watchReceived;
    this.watchTotal = watchTotal;
    this.isPlaying = isPlaying;
    this.playbackBusy = playbackBusy;
    this.playbackPositionMs = playbackPositionMs;
    this.playbackDurationMs = playbackDurationMs;
  }
}

export class PhoneV3Snapshot {
  sessions: Array<PhoneV3SessionCard>;
  conflicts: Array<PhoneV3Conflict>;
  sync: PhoneV3SyncStatus;
  paired: boolean;

  constructor(sessions: Array<PhoneV3SessionCard> = [], conflicts: Array<PhoneV3Conflict> = [],
    sync: PhoneV3SyncStatus = new PhoneV3SyncStatus(), paired: boolean = false) {
    this.sessions = sessions;
    this.conflicts = conflicts;
    this.sync = sync;
    this.paired = paired;
  }
}
