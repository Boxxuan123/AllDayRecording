import { util } from '@kit.ArkTS';

export const COMPUTER_TRANSFER_STATUS_PATH: string = '/api/v1/status';
export const COMPUTER_TRANSFER_UPLOADS_PATH: string = '/api/v1/uploads';
export const PASSKEY_REGISTER_OPTIONS_PATH: string = '/api/v1/passkeys/register/options';
export const PASSKEY_REGISTER_VERIFY_PATH: string = '/api/v1/passkeys/register/verify';
export const PASSKEY_AUTHENTICATE_OPTIONS_PATH: string = '/api/v1/passkeys/authenticate/options';
export const DEVICE_AUTH_CHALLENGE_PATH: string = '/api/v1/devices/authenticate/challenge';
export const DEVICE_KEY_ALGORITHM: string = 'ECDSA_P256_SHA256';
export const COMPUTER_RECEIVER_SERVICE_TYPE: string = '_allday-pc._tcp';
export const COMPUTER_RECEIVER_PROTOCOL: string = 'ALL_DAY_RECORDING_TRANSFER';
export const COMPUTER_RECEIVER_VERSION: number = 2;
export const DEVICE_ID_HEADER: string = 'X-AllDay-Device-ID';
export const DEVICE_CHALLENGE_HEADER: string = 'X-AllDay-Device-Challenge';
export const DEVICE_SIGNATURE_HEADER: string = 'X-AllDay-Device-Signature';
export const PASSKEY_CEREMONY_HEADER: string = 'X-AllDay-Passkey-Ceremony';
export const PASSKEY_ASSERTION_HEADER: string = 'X-AllDay-Passkey-Assertion';
export const COMPUTER_UPLOAD_CHUNK_BYTES: number = 4 * 1024 * 1024;

const BASE64_URL_ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
const DEVICE_SIGNATURE_PREFIX: string = 'ALL_DAY_RECORDING_DEVICE_AUTH_V1';
const PAIRING_URI_PREFIX: string = 'alldayrecording://pair/';
const PAIRING_PROTOCOL: string = 'ALL_DAY_RECORDING_PAIRING';

export interface ComputerRequestBinding {
  method: string;
  path: string;
  body_sha256: string;
  upload_offset?: number;
}

export interface ComputerRegistrationOptionsResponse {
  ceremony_id: string;
  public_key: ComputerRegistrationPublicKeyOptions;
}

export interface ComputerRegistrationPublicKeyOptions {
  rp: ComputerRpEntity;
  user: ComputerUserEntity;
  challenge: string;
  pubKeyCredParams: Array<ComputerCredentialParameter>;
  timeout?: number;
  excludeCredentials?: Array<ComputerCredentialDescriptor>;
  authenticatorSelection?: ComputerAuthenticatorSelection;
  hints?: Array<string>;
  attestation?: string;
}

export interface ComputerAuthenticationOptionsResponse {
  ceremony_id: string;
  public_key: ComputerAuthenticationPublicKeyOptions;
}

export interface ComputerDeviceChallengeResponse {
  version: number;
  challenge_id: string;
  nonce: string;
  expires_in_ms: number;
}

export interface ComputerRegisteredDevice {
  device_id: string;
  device_name: string;
  algorithm: string;
}

export interface ComputerRegistrationVerifyResponse {
  credential: Object;
  device: ComputerRegisteredDevice;
  receiver_id: string;
}

export interface ComputerPairingBootstrap {
  protocol: string;
  version: number;
  receiver_id: string;
  addresses: Array<string>;
  ca_fingerprint: string;
  ca_pem: string;
  pairing_code: string;
}

export interface ComputerAuthenticationPublicKeyOptions {
  challenge: string;
  timeout?: number;
  rpId?: string;
  allowCredentials?: Array<ComputerCredentialDescriptor>;
  userVerification?: string;
  hints?: Array<string>;
}

export interface ComputerRpEntity {
  id?: string;
  name: string;
}

export interface ComputerUserEntity {
  id: string;
  name: string;
  displayName: string;
}

export interface ComputerCredentialParameter {
  type: string;
  alg: number;
}

export interface ComputerCredentialDescriptor {
  type: string;
  id: string;
  transports?: Array<string>;
}

export interface ComputerAuthenticatorSelection {
  authenticatorAttachment?: string;
  residentKey?: string;
  requireResidentKey?: boolean;
  userVerification?: string;
}

export interface ComputerUploadMetadata {
  relative_path: string;
  size: number;
  sha256: string;
  kind: string;
}

export interface ComputerUploadRecord {
  upload_id: string;
  relative_path: string;
  size: number;
  sha256: string;
  kind: string;
  offset: number;
  status: string;
}

export interface ComputerUploadResponse {
  upload: ComputerUploadRecord;
}

export interface ComputerStatusResponse {
  protocol: string;
  version: number;
  status: string;
  transport: string;
  max_file_bytes: number;
  max_chunk_bytes: number;
  authentication: string;
  enrollment: string;
  passkey_rp_id: string;
  receiver_id: string;
}

export function normalizeReceiverId(value: string): string {
  const normalized = value.trim().toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(normalized)) {
    throw new Error('电脑接收端标识无效');
  }
  return normalized;
}

export function normalizeDeviceId(value: string): string {
  const normalized = value.trim();
  if (!/^[A-Za-z0-9_-]{43}$/.test(normalized)) {
    throw new Error('手机设备密钥标识无效');
  }
  return normalized;
}

export function parseComputerPairingBootstrap(value: string): ComputerPairingBootstrap {
  if (!value.startsWith(PAIRING_URI_PREFIX)) {
    throw new Error('二维码不是 AllDayRecording 电脑配对码');
  }
  const decoded = util.TextDecoder.create('utf-8').decodeToString(
    decodeBase64Url(value.substring(PAIRING_URI_PREFIX.length)));
  let payload: ComputerPairingBootstrap;
  try {
    payload = JSON.parse(decoded) as ComputerPairingBootstrap;
  } catch (error) {
    throw new Error('电脑配对二维码内容损坏');
  }
  if (payload.protocol !== PAIRING_PROTOCOL || payload.version !== 1 ||
    !Array.isArray(payload.addresses) || payload.addresses.length === 0 ||
    payload.addresses.some((address: string): boolean => typeof address !== 'string') ||
    typeof payload.ca_fingerprint !== 'string' || typeof payload.ca_pem !== 'string' ||
    typeof payload.pairing_code !== 'string' || typeof payload.receiver_id !== 'string') {
    throw new Error('电脑配对二维码版本或字段无效');
  }
  const receiverId = normalizeReceiverId(payload.receiver_id);
  const fingerprint = normalizeCertificateFingerprint(payload.ca_fingerprint);
  if (receiverId !== fingerprint.replace(/:/g, '').toLowerCase()) {
    throw new Error('电脑接收端标识与配对 CA 不一致');
  }
  if (!payload.ca_pem.includes('-----BEGIN CERTIFICATE-----') ||
    !payload.ca_pem.includes('-----END CERTIFICATE-----') || payload.ca_pem.length > 8000 ||
    payload.pairing_code.trim().length < 16) {
    throw new Error('电脑配对二维码中的证书或配对码无效');
  }
  const addresses: Array<string> = [];
  for (let index = 0; index < payload.addresses.length; index += 1) {
    addresses.push(normalizeComputerBaseUrl(payload.addresses[index]));
  }
  return {
    protocol: PAIRING_PROTOCOL,
    version: 1,
    receiver_id: receiverId,
    addresses: addresses,
    ca_fingerprint: fingerprint,
    ca_pem: payload.ca_pem,
    pairing_code: payload.pairing_code.trim()
  };
}

export function buildDeviceSignaturePayload(challengeId: string, nonce: string,
  binding: ComputerRequestBinding): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/.test(challengeId) || !/^[A-Za-z0-9_-]+$/.test(nonce)) {
    throw new Error('电脑返回了无效的设备认证 challenge');
  }
  const offset = binding.upload_offset === undefined ? '' : binding.upload_offset.toString();
  const value = [DEVICE_SIGNATURE_PREFIX, challengeId, nonce, binding.method, binding.path,
    binding.body_sha256, offset].join('\n');
  return util.TextEncoder.create('utf-8').encodeInto(value);
}

export function normalizeComputerBaseUrl(value: string): string {
  const trimmed = value.trim();
  const match = /^https:\/\/(\[[0-9a-fA-F:]+\]|[A-Za-z0-9.-]+)(?::([0-9]{1,5}))?\/?$/.exec(trimmed);
  if (match === null) {
    throw new Error('电脑地址必须是无路径的 HTTPS 地址，例如 https://192.168.1.20:8766');
  }
  if (match[2] !== undefined) {
    const port = Number(match[2]);
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      throw new Error('电脑地址端口必须在 1 到 65535 之间');
    }
  }
  return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
}

export function normalizeCertificateFingerprint(value: string): string {
  const compact = value.trim().replace(/:/g, '').toUpperCase();
  if (!/^[0-9A-F]{64}$/.test(compact)) {
    throw new Error('证书指纹必须是 64 位 SHA-256 十六进制值');
  }
  const parts: Array<string> = [];
  for (let index = 0; index < compact.length; index += 2) {
    parts.push(compact.substring(index, index + 2));
  }
  return parts.join(':');
}

export function decodeBase64Url(value: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/.test(value) || value.length % 4 === 1) {
    throw new Error('服务端返回了无效的 base64url 数据');
  }
  const bytes: Array<number> = [];
  let buffer = 0;
  let bits = 0;
  for (let index = 0; index < value.length; index += 1) {
    const code = BASE64_URL_ALPHABET.indexOf(value.charAt(index));
    if (code < 0) {
      throw new Error('服务端返回了无效的 base64url 数据');
    }
    buffer = (buffer << 6) | code;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      bytes.push((buffer >>> bits) & 0xff);
    }
  }
  return new Uint8Array(bytes);
}

export function normalizeBase64Url(value: string): string {
  const normalized = value.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
  if (!/^[A-Za-z0-9_-]+$/.test(normalized)) {
    throw new Error('Passkey 返回了无效的 base64 数据');
  }
  return normalized;
}

export function encodeBase64Url(value: Uint8Array): string {
  let result = '';
  for (let index = 0; index < value.length; index += 3) {
    const first = value[index];
    const secondPresent = index + 1 < value.length;
    const thirdPresent = index + 2 < value.length;
    const second = secondPresent ? value[index + 1] : 0;
    const third = thirdPresent ? value[index + 2] : 0;
    result += BASE64_URL_ALPHABET.charAt(first >>> 2);
    result += BASE64_URL_ALPHABET.charAt(((first & 0x03) << 4) | (second >>> 4));
    if (secondPresent) {
      result += BASE64_URL_ALPHABET.charAt(((second & 0x0f) << 2) | (third >>> 6));
    }
    if (thirdPresent) {
      result += BASE64_URL_ALPHABET.charAt(third & 0x3f);
    }
  }
  return result;
}

export function encodePasskeyAssertionHeader(assertion: Object): string {
  return encodeBase64Url(util.TextEncoder.create('utf-8').encodeInto(JSON.stringify(assertion)));
}

export function uploadItemPath(uploadId: string): string {
  if (!/^[0-9a-f]{32}$/.test(uploadId)) {
    throw new Error('电脑返回了无效的上传任务 ID');
  }
  return `${COMPUTER_TRANSFER_UPLOADS_PATH}/${uploadId}`;
}

export function computerTransferError(error: Object): Error {
  if (error instanceof Error) {
    return error;
  }
  const value = error as Error;
  if (value.message !== undefined && value.message.length > 0) {
    return new Error(`${value.message}`);
  }
  return new Error(JSON.stringify(error));
}
