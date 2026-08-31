import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http } from '@kit.NetworkKit';
import { PhoneDeviceKeyClient } from './PhoneDeviceKeyClient';
import { PhonePasskeyClient } from './PhonePasskeyClient';
import {
  COMPUTER_TRANSFER_STATUS_PATH,
  COMPUTER_TRANSFER_UPLOADS_PATH,
  ComputerDeviceChallengeResponse,
  ComputerRegistrationOptionsResponse,
  ComputerRegistrationVerifyResponse,
  ComputerRequestBinding,
  ComputerStatusResponse,
  ComputerUploadMetadata,
  ComputerUploadResponse,
  DEVICE_AUTH_CHALLENGE_PATH,
  DEVICE_V3_STATUS_PATH,
  DEVICE_V3_SYNC_PATH,
  DeviceV3StatusResponse,
  DeviceV3SyncRequest,
  DeviceV3SyncResponse,
  DEVICE_KEY_ALGORITHM,
  PASSKEY_REGISTER_OPTIONS_PATH,
  PASSKEY_REGISTER_VERIFY_PATH,
  computerTransferError,
  buildDeviceSignaturePayload,
  normalizeDeviceId,
  normalizeComputerBaseUrl,
  normalizeReceiverId,
  uploadItemPath
} from './ComputerTransferProtocol';

const CONNECT_TIMEOUT_MS: number = 20000;
const READ_TIMEOUT_MS: number = 120000;

interface ComputerErrorResponse {
  error?: string;
  message?: string;
}

interface PairingHeaders {
  Authorization: string;
  'Content-Type': string;
}

interface JsonHeaders {
  'Content-Type': string;
}

interface DeviceRegistrationRequest {
  algorithm: string;
  public_key: string;
}

interface RegistrationVerifyRequest {
  ceremony_id: string;
  credential: Object;
  device: DeviceRegistrationRequest;
}

interface AuthenticatedHeaders {
  'X-AllDay-Device-ID': string;
  'X-AllDay-Device-Challenge': string;
  'X-AllDay-Device-Signature': string;
  'Content-Type'?: string;
  'Upload-Offset'?: string;
}

export class ComputerPairingResult {
  rpId: string;
  receiverId: string;
  deviceId: string;
  status: ComputerStatusResponse;

  constructor(rpId: string, receiverId: string, deviceId: string, status: ComputerStatusResponse) {
    this.rpId = rpId;
    this.receiverId = receiverId;
    this.deviceId = deviceId;
    this.status = status;
  }
}

export class ComputerTransferHttpClient {
  private baseUrl: string;
  private caPath: string;
  private passkeys: PhonePasskeyClient;
  private deviceKeys: PhoneDeviceKeyClient;
  private deviceId: string;

  constructor(context: common.UIAbilityContext, baseUrl: string, caPath: string, deviceId: string = '') {
    if (!canIUse('SystemCapability.Communication.NetStack') ||
      !canIUse('SystemCapability.Security.CryptoFramework')) {
      throw new Error('本机系统不支持 HTTPS 或 SHA-256 电脑传输');
    }
    this.baseUrl = normalizeComputerBaseUrl(baseUrl);
    if (caPath.trim().length === 0) {
      throw new Error('尚未导入电脑的配对 CA 证书');
    }
    this.caPath = caPath;
    this.passkeys = new PhonePasskeyClient(context);
    this.deviceKeys = new PhoneDeviceKeyClient();
    this.deviceId = deviceId.length > 0 ? normalizeDeviceId(deviceId) : '';
  }

  async pair(pairingCode: string, deviceName: string): Promise<ComputerPairingResult> {
    const code = pairingCode.trim();
    if (code.length < 16) {
      throw new Error('首次配对码无效');
    }
    const headers: PairingHeaders = {
      'Authorization': `Bearer ${code}`,
      'Content-Type': 'application/json; charset=utf-8'
    };
    const devicePublicKey = await this.deviceKeys.ensurePublicKey();
    const startBody = JSON.stringify({ device_name: deviceName });
    const start = await this.requestJson<ComputerRegistrationOptionsResponse>(
      'POST', PASSKEY_REGISTER_OPTIONS_PATH, startBody, headers);
    if (start.ceremony_id.length === 0 || start.public_key.rp.id === undefined ||
      start.public_key.rp.id.length === 0) {
      throw new Error('电脑返回了无效的 Passkey 登记选项');
    }
    const credential = await this.passkeys.register(start.public_key);
    const finishRequest: RegistrationVerifyRequest = {
      ceremony_id: start.ceremony_id,
      credential: credential,
      device: {
        algorithm: this.deviceKeys.algorithm(),
        public_key: devicePublicKey
      }
    };
    const finishBody = JSON.stringify(finishRequest);
    const verified = await this.requestJson<ComputerRegistrationVerifyResponse>(
      'POST', PASSKEY_REGISTER_VERIFY_PATH, finishBody, headers);
    if (verified.device === null || verified.device.algorithm !== DEVICE_KEY_ALGORITHM) {
      throw new Error('电脑没有登记手机设备密钥');
    }
    this.deviceId = normalizeDeviceId(verified.device.device_id);
    const receiverId = normalizeReceiverId(verified.receiver_id);
    const status = await this.status();
    if (status.authentication !== 'device-signature' || status.enrollment !== 'passkey' ||
      status.passkey_rp_id !== start.public_key.rp.id || normalizeReceiverId(status.receiver_id) !== receiverId) {
      throw new Error('电脑返回的 Passkey 身份与登记时不一致');
    }
    return new ComputerPairingResult(start.public_key.rp.id, receiverId, this.deviceId, status);
  }

  async status(): Promise<ComputerStatusResponse> {
    return this.authenticatedJson<ComputerStatusResponse>('GET', COMPUTER_TRANSFER_STATUS_PATH,
      new Uint8Array(0), undefined, undefined);
  }

  async createUpload(metadata: ComputerUploadMetadata): Promise<ComputerUploadResponse> {
    const body = util.TextEncoder.create('utf-8').encodeInto(JSON.stringify(metadata));
    return this.authenticatedJson<ComputerUploadResponse>('POST', COMPUTER_TRANSFER_UPLOADS_PATH,
      body, 'application/json; charset=utf-8', undefined);
  }

  async queryUpload(uploadId: string): Promise<ComputerUploadResponse> {
    return this.authenticatedJson<ComputerUploadResponse>('GET', uploadItemPath(uploadId),
      new Uint8Array(0), undefined, undefined);
  }

  async appendUpload(uploadId: string, offset: number, chunk: Uint8Array): Promise<ComputerUploadResponse> {
    if (!Number.isSafeInteger(offset) || offset < 0 || chunk.length <= 0) {
      throw new Error('上传分片偏移或大小无效');
    }
    return this.authenticatedJson<ComputerUploadResponse>('PUT', uploadItemPath(uploadId), chunk,
      'application/octet-stream', offset);
  }

  async v3Status(): Promise<DeviceV3StatusResponse> {
    return this.authenticatedJson<DeviceV3StatusResponse>('GET', DEVICE_V3_STATUS_PATH,
      new Uint8Array(0), undefined, undefined);
  }

  async sync(request: DeviceV3SyncRequest): Promise<DeviceV3SyncResponse> {
    const body = util.TextEncoder.create('utf-8').encodeInto(JSON.stringify(request));
    return this.authenticatedJson<DeviceV3SyncResponse>('POST', DEVICE_V3_SYNC_PATH,
      body, 'application/json; charset=utf-8', undefined);
  }

  private async authenticatedJson<T>(method: string, path: string, body: Uint8Array,
    contentType: string | undefined, uploadOffset: number | undefined): Promise<T> {
    const binding: ComputerRequestBinding = {
      method: method,
      path: path,
      body_sha256: await sha256Hex(body)
    };
    if (uploadOffset !== undefined) {
      binding.upload_offset = uploadOffset;
    }
    const optionsBody = JSON.stringify({ device_id: this.requireDeviceId(), request: binding });
    const optionsHeaders: JsonHeaders = { 'Content-Type': 'application/json; charset=utf-8' };
    const challenge = await this.requestJson<ComputerDeviceChallengeResponse>(
      'POST', DEVICE_AUTH_CHALLENGE_PATH, optionsBody, optionsHeaders);
    if (challenge.version !== 1 || challenge.challenge_id.length === 0 || challenge.nonce.length === 0 ||
      !Number.isSafeInteger(challenge.expires_in_ms) || challenge.expires_in_ms <= 0) {
      throw new Error('电脑返回了无效的设备认证 challenge');
    }
    const signature = await this.deviceKeys.sign(
      buildDeviceSignaturePayload(challenge.challenge_id, challenge.nonce, binding));
    const headers: Object = authenticatedHeaders(this.deviceId, challenge.challenge_id,
      signature, contentType, uploadOffset);
    return this.requestJson<T>(method, path, body.length === 0 ? undefined : body.buffer, headers);
  }

  private requireDeviceId(): string {
    if (this.deviceId.length === 0) {
      throw new Error('手机设备密钥尚未在电脑登记');
    }
    return this.deviceId;
  }

  private async requestJson<T>(method: string, path: string, body: string | ArrayBuffer | undefined,
    headers: Object): Promise<T> {
    const request = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: requestMethod(method),
        header: headers,
        usingCache: false,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING,
        caPath: this.caPath
      };
      if (body !== undefined) {
        options.extraData = body;
      }
      const response = await request.request(`${this.baseUrl}${path}`, options);
      const text = responseText(response.result);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(serverErrorMessage(response.responseCode, text));
      }
      try {
        return JSON.parse(text) as T;
      } catch (error) {
        throw new Error(`电脑返回了无效的 JSON（HTTP ${response.responseCode}）`);
      }
    } catch (error) {
      throw computerTransferError(error as Object);
    } finally {
      request.destroy();
    }
  }
}

function authenticatedHeaders(deviceId: string, challengeId: string, signature: string,
  contentType: string | undefined, uploadOffset: number | undefined): AuthenticatedHeaders {
  if (uploadOffset !== undefined) {
    return {
      'X-AllDay-Device-ID': deviceId,
      'X-AllDay-Device-Challenge': challengeId,
      'X-AllDay-Device-Signature': signature,
      'Content-Type': contentType ?? 'application/octet-stream',
      'Upload-Offset': uploadOffset.toString()
    };
  }
  if (contentType !== undefined) {
    return {
      'X-AllDay-Device-ID': deviceId,
      'X-AllDay-Device-Challenge': challengeId,
      'X-AllDay-Device-Signature': signature,
      'Content-Type': contentType
    };
  }
  return {
    'X-AllDay-Device-ID': deviceId,
    'X-AllDay-Device-Challenge': challengeId,
    'X-AllDay-Device-Signature': signature
  };
}

export async function sha256Hex(value: Uint8Array): Promise<string> {
  const digest = cryptoFramework.createMd('SHA256');
  if (value.length > 0) {
    await digest.update({ data: value });
  }
  const result = await digest.digest();
  const parts: Array<string> = [];
  for (let index = 0; index < result.data.length; index += 1) {
    parts.push(result.data[index].toString(16).padStart(2, '0'));
  }
  return parts.join('');
}

function requestMethod(value: string): http.RequestMethod {
  switch (value) {
    case 'GET': return http.RequestMethod.GET;
    case 'POST': return http.RequestMethod.POST;
    case 'PUT': return http.RequestMethod.PUT;
    default: throw new Error(`不支持的电脑传输请求方法：${value}`);
  }
}

function responseText(value: string | Object | ArrayBuffer): string {
  if (typeof value === 'string') {
    return value;
  }
  if (value instanceof ArrayBuffer) {
    return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(value));
  }
  return JSON.stringify(value);
}

function serverErrorMessage(code: number, body: string): string {
  try {
    const payload = JSON.parse(body) as ComputerErrorResponse;
    if (payload.error !== undefined && payload.error.length > 0) {
      return `电脑拒绝请求（HTTP ${code}）：${payload.error}`;
    }
    if (payload.message !== undefined && payload.message.length > 0) {
      return `电脑拒绝请求（HTTP ${code}）：${payload.message}`;
    }
  } catch (error) {
  }
  return `电脑请求失败（HTTP ${code}）`;
}
