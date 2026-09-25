import { phoneV3SoundKind } from './PhoneV3SoundKind';
import { annotationFacts, PhoneV3AnnotationFacts, AnnotationRow } from './PhoneV3AnnotationState';
import { phoneV3PersonFact, phoneV3PersonUncertain } from './PhoneV3PersonFact';
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
  status: string;
  errorJson: string;
  createdAt: number;
  payloadJson: string;

  constructor(operationId: string, kind: string, status: string, errorJson: string, createdAt: number, payloadJson: string = '{}') {
    this.payloadJson = payloadJson;
    this.operationId = operationId;
    this.kind = kind;
    this.status = status;
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

export class PhoneV3Utterance implements AnnotationRow {
  annotationFacts: PhoneV3AnnotationFacts = new PhoneV3AnnotationFacts();
  soundKind: string = 'speech';
  annotationPending: boolean = false;
  annotationPersonId: string = '';
  utteranceId: string;
  sessionId: string;
  speakerTrackId: string | null;
  speakerLabel: string | null;
  originalSpeakerTrackId: string | null;
  originalSpeakerLabel: string | null;
  identity: string;
  originalIdentity: string;
  identityEvidenceJson: string;
  startMs: number;
  endMs: number;
  startAt: string;
  endAt: string;
  text: string;
  originalText: string;
  revision: number;
  status: string;
  evidenceJson: string;

  constructor(utteranceId: string, sessionId: string, speakerTrackId: string | null,
    speakerLabel: string | null, originalSpeakerTrackId: string | null,
    originalSpeakerLabel: string | null, identity: string, originalIdentity: string,
    identityEvidenceJson: string, startMs: number, endMs: number,
    startAt: string, endAt: string, text: string, originalText: string,
    revision: number, status: string, evidenceJson: string) {
    this.utteranceId = utteranceId;
    this.sessionId = sessionId;
    this.speakerTrackId = speakerTrackId;
    this.speakerLabel = speakerLabel;
    this.originalSpeakerTrackId = originalSpeakerTrackId;
    this.originalSpeakerLabel = originalSpeakerLabel;
    this.identity = identity;
    this.originalIdentity = originalIdentity;
    this.identityEvidenceJson = identityEvidenceJson;
    this.startMs = startMs;
    this.endMs = endMs;
    this.startAt = startAt;
    this.endAt = endAt;
    this.text = text;
    this.originalText = originalText;
    this.revision = revision;
    this.status = status;
    this.evidenceJson = evidenceJson;
    this.annotationFacts = annotationFacts(evidenceJson);
    this.soundKind = phoneV3SoundKind(evidenceJson);
    this.annotationPersonId = phoneV3PersonFact(evidenceJson);
    if (phoneV3PersonUncertain(evidenceJson)) {
      this.identity = 'unknown';
      this.speakerLabel = '人物待确认';
    }
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

export class PhoneV3FileTransferState {
  active: boolean;
  stage: string;
  percent: number;
  fileName: string;
  transferredBytes: number;
  totalBytes: number;
  index: number;
  total: number;
  message: string;
  error: string;

  constructor(active: boolean = false, stage: string = '', percent: number = 0, fileName: string = '',
    transferredBytes: number = 0, totalBytes: number = 0, index: number = 0, total: number = 0,
    message: string = '', error: string = '') {
    this.active = active;
    this.stage = stage;
    this.percent = percent;
    this.fileName = fileName;
    this.transferredBytes = transferredBytes;
    this.totalBytes = totalBytes;
    this.index = index;
    this.total = total;
    this.message = message;
    this.error = error;
  }
}

export class PhoneV3WifiState {
  ready: boolean;
  busy: boolean;
  stopping: boolean;
  percent: number;
  status: string;
  capability: string;
  error: string;

  constructor(ready: boolean = false, busy: boolean = false, stopping: boolean = false,
    percent: number = 0, status: string = '', capability: string = '', error: string = '') {
    this.ready = ready;
    this.busy = busy;
    this.stopping = stopping;
    this.percent = percent;
    this.status = status;
    this.capability = capability;
    this.error = error;
  }
}

export class PhoneV3DeviceState {
  watchStatus: string;
  remoteRecordingState: string;
  watchControlBusy: boolean;
  receiverReconnecting: boolean;
  watchSyncing: boolean;
  watchReceived: number;
  watchTotal: number;
  watchTransfer: PhoneV3FileTransferState;
  wifi: PhoneV3WifiState;
  isPlaying: boolean;
  playbackBusy: boolean;
  playbackPositionMs: number;
  playbackDurationMs: number;
  operationMessage: string;
  operationError: string;

  constructor(watchStatus: string = '正在连接手表', watchSyncing: boolean = false,
    watchReceived: number = 0, watchTotal: number = 0, isPlaying: boolean = false,
    playbackBusy: boolean = false, playbackPositionMs: number = 0, playbackDurationMs: number = 0,
    remoteRecordingState: string = 'unknown', watchControlBusy: boolean = false,
    receiverReconnecting: boolean = false, watchTransfer: PhoneV3FileTransferState = new PhoneV3FileTransferState(),
    wifi: PhoneV3WifiState = new PhoneV3WifiState(), operationMessage: string = '', operationError: string = '') {
    this.watchStatus = watchStatus;
    this.remoteRecordingState = remoteRecordingState;
    this.watchControlBusy = watchControlBusy;
    this.receiverReconnecting = receiverReconnecting;
    this.watchSyncing = watchSyncing;
    this.watchReceived = watchReceived;
    this.watchTotal = watchTotal;
    this.watchTransfer = watchTransfer;
    this.wifi = wifi;
    this.isPlaying = isPlaying;
    this.playbackBusy = playbackBusy;
    this.playbackPositionMs = playbackPositionMs;
    this.playbackDurationMs = playbackDurationMs;
    this.operationMessage = operationMessage;
    this.operationError = operationError;
  }
}

export class PhoneV3Reminder {
  eventId: string;
  sessionId: string;
  eventRevision: number;
  sourceCandidateId: string;
  title: string;
  actorPersonId: string;
  commitmentDirection: string;
  relatedPersonIds: Array<string>;
  scheduledAt: string;
  location: string | null;
  status: string;
  updatedAt: string;

  constructor(eventId: string, sessionId: string, eventRevision: number,
    sourceCandidateId: string, title: string, actorPersonId: string,
    commitmentDirection: string, relatedPersonIds: Array<string>, scheduledAt: string,
    location: string | null, status: string, updatedAt: string) {
    this.eventId = eventId;
    this.sessionId = sessionId;
    this.eventRevision = eventRevision;
    this.sourceCandidateId = sourceCandidateId;
    this.title = title;
    this.actorPersonId = actorPersonId;
    this.commitmentDirection = commitmentDirection;
    this.relatedPersonIds = relatedPersonIds;
    this.scheduledAt = scheduledAt;
    this.location = location;
    this.status = status;
    this.updatedAt = updatedAt;
  }
}

export class PhoneV3ReviewItem {
  reviewId: string;
  kind: string;
  priority: string;
  sourceId: string;
  sourceRevision: number | null;
  sessionId: string | null;
  personId: string | null;
  title: string;
  summary: string;
  reason: string;
  evidenceCount: number;
  createdAt: string;
  updatedAt: string;
  contextJson: string;

  constructor(reviewId: string, kind: string, priority: string, sourceId: string,
    sourceRevision: number | null, sessionId: string | null, personId: string | null,
    title: string, summary: string, reason: string, evidenceCount: number,
    createdAt: string, updatedAt: string, contextJson: string) {
    this.reviewId = reviewId;
    this.kind = kind;
    this.priority = priority;
    this.sourceId = sourceId;
    this.sourceRevision = sourceRevision;
    this.sessionId = sessionId;
    this.personId = personId;
    this.title = title;
    this.summary = summary;
    this.reason = reason;
    this.evidenceCount = evidenceCount;
    this.createdAt = createdAt;
    this.updatedAt = updatedAt;
    this.contextJson = contextJson;
  }
}

export class PhoneV3Snapshot {
  sessions: Array<PhoneV3SessionCard>;
  conflicts: Array<PhoneV3Conflict>;
  sync: PhoneV3SyncStatus;
  paired: boolean;
  reminders: Array<PhoneV3Reminder>;
  reviewItems: Array<PhoneV3ReviewItem>;

  constructor(sessions: Array<PhoneV3SessionCard> = [], conflicts: Array<PhoneV3Conflict> = [],
    sync: PhoneV3SyncStatus = new PhoneV3SyncStatus(), paired: boolean = false,
    reminders: Array<PhoneV3Reminder> = [], reviewItems: Array<PhoneV3ReviewItem> = []) {
    this.sessions = sessions;
    this.conflicts = conflicts;
    this.sync = sync;
    this.paired = paired;
    this.reminders = reminders;
    this.reviewItems = reviewItems;
  }
}
