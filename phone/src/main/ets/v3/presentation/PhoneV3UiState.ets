import { PhoneV3DeviceState, PhoneV3SessionCard, PhoneV3Snapshot } from '../domain/PhoneV3Models';

export enum PhoneV3UiActionType {
  LOCAL_READY,
  SNAPSHOT_READY,
  BUSY,
  SUCCESS,
  FAILURE,
  DEVICE_CHANGED,
  SESSION_SELECTED
}

export class PhoneV3UiAction {
  type: PhoneV3UiActionType;
  snapshot: PhoneV3Snapshot | undefined;
  device: PhoneV3DeviceState | undefined;
  message: string;

  constructor(type: PhoneV3UiActionType, snapshot?: PhoneV3Snapshot,
    device?: PhoneV3DeviceState, message: string = '') {
    this.type = type;
    this.snapshot = snapshot;
    this.device = device;
    this.message = message;
  }
}

export class PhoneV3UiState {
  snapshot: PhoneV3Snapshot;
  device: PhoneV3DeviceState;
  selectedSessionId: string;
  localReady: boolean;
  cacheReady: boolean;
  busy: boolean;
  message: string;
  error: string;

  constructor(snapshot: PhoneV3Snapshot = new PhoneV3Snapshot(),
    device: PhoneV3DeviceState = new PhoneV3DeviceState(), selectedSessionId: string = '',
    localReady: boolean = false, cacheReady: boolean = false, busy: boolean = false,
    message: string = '正在读取手机录音…', error: string = '') {
    this.snapshot = snapshot;
    this.device = device;
    this.selectedSessionId = selectedSessionId;
    this.localReady = localReady;
    this.cacheReady = cacheReady;
    this.busy = busy;
    this.message = message;
    this.error = error;
  }
}

export function reducePhoneV3Ui(state: PhoneV3UiState, action: PhoneV3UiAction): PhoneV3UiState {
  const next = new PhoneV3UiState(state.snapshot, state.device, state.selectedSessionId,
    state.localReady, state.cacheReady, state.busy, state.message, state.error);
  switch (action.type) {
    case PhoneV3UiActionType.LOCAL_READY:
      if (action.snapshot !== undefined) {
        next.snapshot = action.snapshot;
      }
      next.localReady = true;
      next.message = action.message.length > 0 ? action.message : '手机本地录音已就绪';
      next.error = '';
      return next;
    case PhoneV3UiActionType.SNAPSHOT_READY:
      if (action.snapshot !== undefined) {
        next.snapshot = action.snapshot;
      }
      next.localReady = true;
      next.cacheReady = true;
      next.busy = false;
      next.message = action.message.length > 0 ? action.message : '已载入手机缓存';
      next.error = '';
      return ensureSelection(next);
    case PhoneV3UiActionType.BUSY:
      next.busy = true;
      next.message = action.message;
      next.error = '';
      return next;
    case PhoneV3UiActionType.SUCCESS:
      next.busy = false;
      next.message = action.message;
      next.error = '';
      return next;
    case PhoneV3UiActionType.FAILURE:
      next.busy = false;
      next.error = action.message;
      next.message = '仍可继续查看手机本地与缓存内容';
      return next;
    case PhoneV3UiActionType.DEVICE_CHANGED:
      if (action.device !== undefined) {
        next.device = action.device;
      }
      return next;
    case PhoneV3UiActionType.SESSION_SELECTED:
      next.selectedSessionId = action.message;
      return next;
    default:
      return next;
  }
}

export function selectedPhoneV3Session(state: PhoneV3UiState): PhoneV3SessionCard | undefined {
  for (let index = 0; index < state.snapshot.sessions.length; index += 1) {
    if (state.snapshot.sessions[index].id === state.selectedSessionId) {
      return state.snapshot.sessions[index];
    }
  }
  return undefined;
}

function ensureSelection(state: PhoneV3UiState): PhoneV3UiState {
  if (selectedPhoneV3Session(state) !== undefined || state.snapshot.sessions.length === 0) {
    return state;
  }
  state.selectedSessionId = state.snapshot.sessions[0].id;
  return state;
}
