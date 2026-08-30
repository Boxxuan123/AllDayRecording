import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

const WIFI_SECURITY_PROTOCOL: string = 'ALL_DAY_RECORDING_WIFI_SECURITY_V2';
const WIFI_BATCH_TOKEN_BYTES: number = 16;
const WIFI_TEMPORARY_KEY_BYTES: number = 32;
const WIFI_AUTH_NONCE_BYTES: number = 16;
const WIFI_GCM_NONCE_BYTES: number = 12;
const WIFI_GCM_TAG_BYTES: number = 16;
const WIFI_MAX_SESSION_TTL_MS: number = 5 * 60 * 1000;
const WIFI_AES_TRANSFORMATION: string = 'AES256|GCM|NoPadding';

export const WIFI_TRANSFER_SESSION_TTL_MS: number = 3 * 60 * 1000;
export const WIFI_SECURE_PAYLOAD_OVERHEAD_BYTES: number = WIFI_GCM_TAG_BYTES;
export const WIFI_WATCH_TO_PHONE: string = 'watch_to_phone';
export const WIFI_PHONE_TO_WATCH: string = 'phone_to_watch';

export interface WifiTransferSessionCredentials {
  batchToken: string;
  temporaryKey: string;
  expiresAt: number;
}

export interface WifiAuthInit {
  protocol: string;
  version: number;
  batchToken: string;
  clientNonce: string;
}

export interface WifiAuthChallenge extends WifiAuthInit {
  serverNonce: string;
  proof: string;
}

export interface WifiAuthResponse extends WifiAuthInit {
  serverNonce: string;
  proof: string;
}

export interface WifiAuthAccept extends WifiAuthInit {
  serverNonce: string;
  proof: string;
}

export function isWifiTransferCryptoAvailable(): boolean {
  const legacy = canIUse('SystemCapability.Security.CryptoFramework');
  return legacy || (canIUse('SystemCapability.Security.CryptoFramework.Cipher') &&
    canIUse('SystemCapability.Security.CryptoFramework.Mac') &&
    canIUse('SystemCapability.Security.CryptoFramework.Rand') &&
    canIUse('SystemCapability.Security.CryptoFramework.Key.SymKey'));
}

function assertCryptoAvailable(): void {
  if (!isWifiTransferCryptoAvailable()) {
    throw new Error('当前设备不支持 Wi-Fi 安全传输所需的 AES-GCM/HMAC 能力');
  }
}

function textBytes(value: string): Uint8Array {
  return util.TextEncoder.create('utf-8').encodeInto(value);
}

function copyBytes(value: Uint8Array): Uint8Array {
  const result = new Uint8Array(value.byteLength);
  result.set(value);
  return result;
}

function bytesToArrayBuffer(value: Uint8Array): ArrayBuffer {
  return copyBytes(value).buffer;
}

function securityError(error: Object): Error {
  return error instanceof Error ? error : new Error('Wi-Fi 密码操作失败');
}

function isHex(value: string, byteLength: number): boolean {
  if (value.length !== byteLength * 2) {
    return false;
  }
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    const digit = code >= 48 && code <= 57;
    const lower = code >= 97 && code <= 102;
    const upper = code >= 65 && code <= 70;
    if (!digit && !lower && !upper) {
      return false;
    }
  }
  return true;
}

export function wifiBytesToHex(value: Uint8Array): string {
  let result = '';
  for (let index = 0; index < value.length; index += 1) {
    result += value[index].toString(16).padStart(2, '0');
  }
  return result;
}

export function wifiHexToBytes(value: string): Uint8Array {
  if (value.length === 0 || value.length % 2 !== 0 || !isHex(value, value.length / 2)) {
    throw new Error('Wi-Fi 安全参数不是有效十六进制数据');
  }
  const result = new Uint8Array(value.length / 2);
  for (let index = 0; index < result.length; index += 1) {
    result[index] = Number.parseInt(value.substring(index * 2, index * 2 + 2), 16);
  }
  return result;
}

export function isValidWifiTransferCredentials(credentials: WifiTransferSessionCredentials,
  now: number = Date.now()): boolean {
  return isHex(credentials.batchToken, WIFI_BATCH_TOKEN_BYTES) &&
    isHex(credentials.temporaryKey, WIFI_TEMPORARY_KEY_BYTES) && Number.isFinite(credentials.expiresAt) &&
    credentials.expiresAt > now && credentials.expiresAt - now <= WIFI_MAX_SESSION_TTL_MS;
}

export function isValidWifiAuthNonce(value: string): boolean {
  return isHex(value, WIFI_AUTH_NONCE_BYTES);
}

export function wifiConstantTimeHexEqual(left: string, right: string): boolean {
  if (left.length !== right.length || left.length === 0) {
    return false;
  }
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

export function buildWifiFrameNonce(batchToken: string, direction: string, frameType: number,
  transferToken: number, sequence: number): Uint8Array {
  if (!isHex(batchToken, WIFI_BATCH_TOKEN_BYTES) ||
    (direction !== WIFI_WATCH_TO_PHONE && direction !== WIFI_PHONE_TO_WATCH) ||
    frameType < 0 || frameType > 255 || transferToken < 0 || transferToken > 4294967295 ||
    sequence < 0 || sequence > 65535) {
    throw new Error('Wi-Fi 加密帧随机数参数无效');
  }
  const tokenBytes = wifiHexToBytes(batchToken);
  const nonce = new Uint8Array(WIFI_GCM_NONCE_BYTES);
  nonce.set(tokenBytes.slice(0, 4), 0);
  nonce[4] = direction === WIFI_WATCH_TO_PHONE ? 1 : 2;
  nonce[5] = frameType;
  const view = new DataView(nonce.buffer);
  view.setUint32(6, transferToken, false);
  view.setUint16(10, sequence, false);
  tokenBytes.fill(0);
  return nonce;
}

export function buildWifiFrameAad(batchToken: string, direction: string, frameType: number,
  transferToken: number, sequence: number): Uint8Array {
  return textBytes(`${WIFI_SECURITY_PROTOCOL}\n${batchToken}\n${direction}\n${frameType}\n${transferToken}\n${sequence}`);
}

function clientProofText(batchToken: string, clientNonce: string, serverNonce: string): string {
  return `${WIFI_SECURITY_PROTOCOL}\nclient\n${batchToken}\n${clientNonce}\n${serverNonce}`;
}

function serverProofText(batchToken: string, clientNonce: string, serverNonce: string): string {
  return `${WIFI_SECURITY_PROTOCOL}\nserver\n${batchToken}\n${clientNonce}\n${serverNonce}`;
}

function acceptProofText(batchToken: string, clientNonce: string, serverNonce: string): string {
  return `${WIFI_SECURITY_PROTOCOL}\naccept\n${batchToken}\n${clientNonce}\n${serverNonce}`;
}

async function hmacBytes(key: cryptoFramework.SymKey, content: Uint8Array): Promise<Uint8Array> {
  try {
    const mac = cryptoFramework.createMac('SHA256');
    await mac.init(key);
    await mac.update({ data: content });
    const result = await mac.doFinal();
    const copied = copyBytes(result.data);
    result.data.fill(0);
    return copied;
  } catch (error) {
    throw securityError(error as Object);
  } finally {
    content.fill(0);
  }
}

async function convertHmacKey(keyBytes: Uint8Array): Promise<cryptoFramework.SymKey> {
  try {
    const generator = cryptoFramework.createSymKeyGenerator('HMAC');
    return await generator.convertKey({ data: keyBytes });
  } catch (error) {
    throw securityError(error as Object);
  }
}

async function convertAesKey(keyBytes: Uint8Array): Promise<cryptoFramework.SymKey> {
  try {
    const generator = cryptoFramework.createSymKeyGenerator('AES256');
    return await generator.convertKey({ data: keyBytes });
  } catch (error) {
    throw securityError(error as Object);
  }
}

export async function createWifiTransferCredentials(): Promise<WifiTransferSessionCredentials> {
  assertCryptoAvailable();
  let batchToken: cryptoFramework.DataBlob | undefined = undefined;
  let temporaryKey: cryptoFramework.DataBlob | undefined = undefined;
  try {
    const random = cryptoFramework.createRandom();
    batchToken = await random.generateRandom(WIFI_BATCH_TOKEN_BYTES);
    temporaryKey = await random.generateRandom(WIFI_TEMPORARY_KEY_BYTES);
    return {
      batchToken: wifiBytesToHex(batchToken.data),
      temporaryKey: wifiBytesToHex(temporaryKey.data),
      expiresAt: Date.now() + WIFI_TRANSFER_SESSION_TTL_MS
    };
  } catch (error) {
    throw securityError(error as Object);
  } finally {
    if (batchToken !== undefined) {
      batchToken.data.fill(0);
    }
    if (temporaryKey !== undefined) {
      temporaryKey.data.fill(0);
    }
  }
}

export async function createWifiAuthNonce(): Promise<string> {
  assertCryptoAvailable();
  let generated: cryptoFramework.DataBlob | undefined = undefined;
  try {
    generated = await cryptoFramework.createRandom().generateRandom(WIFI_AUTH_NONCE_BYTES);
    return wifiBytesToHex(generated.data);
  } catch (error) {
    throw securityError(error as Object);
  } finally {
    if (generated !== undefined) {
      generated.data.fill(0);
    }
  }
}

export class WifiTransferSecurityContext {
  private batchToken: string;
  private authKey: cryptoFramework.SymKey;
  private watchToPhoneKey: cryptoFramework.SymKey;
  private phoneToWatchKey: cryptoFramework.SymKey;
  private destroyed: boolean = false;

  constructor(batchToken: string, authKey: cryptoFramework.SymKey,
    watchToPhoneKey: cryptoFramework.SymKey, phoneToWatchKey: cryptoFramework.SymKey) {
    this.batchToken = batchToken;
    this.authKey = authKey;
    this.watchToPhoneKey = watchToPhoneKey;
    this.phoneToWatchKey = phoneToWatchKey;
  }

  token(): string {
    return this.batchToken;
  }

  async createServerProof(clientNonce: string, serverNonce: string): Promise<string> {
    this.assertUsable();
    return wifiBytesToHex(await hmacBytes(this.authKey,
      textBytes(serverProofText(this.batchToken, clientNonce, serverNonce))));
  }

  async createClientProof(clientNonce: string, serverNonce: string): Promise<string> {
    this.assertUsable();
    return wifiBytesToHex(await hmacBytes(this.authKey,
      textBytes(clientProofText(this.batchToken, clientNonce, serverNonce))));
  }

  async createAcceptProof(clientNonce: string, serverNonce: string): Promise<string> {
    this.assertUsable();
    return wifiBytesToHex(await hmacBytes(this.authKey,
      textBytes(acceptProofText(this.batchToken, clientNonce, serverNonce))));
  }

  async verifyServerProof(clientNonce: string, serverNonce: string, proof: string): Promise<boolean> {
    return wifiConstantTimeHexEqual(await this.createServerProof(clientNonce, serverNonce), proof);
  }

  async verifyClientProof(clientNonce: string, serverNonce: string, proof: string): Promise<boolean> {
    return wifiConstantTimeHexEqual(await this.createClientProof(clientNonce, serverNonce), proof);
  }

  async verifyAcceptProof(clientNonce: string, serverNonce: string, proof: string): Promise<boolean> {
    return wifiConstantTimeHexEqual(await this.createAcceptProof(clientNonce, serverNonce), proof);
  }

  async encrypt(direction: string, frameType: number, transferToken: number,
    sequence: number, payload: ArrayBuffer): Promise<ArrayBuffer> {
    this.assertUsable();
    const key = this.keyForDirection(direction);
    const iv = buildWifiFrameNonce(this.batchToken, direction, frameType, transferToken, sequence);
    const aad = buildWifiFrameAad(this.batchToken, direction, frameType, transferToken, sequence);
    const params: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: aad },
      authTag: { data: new Uint8Array(WIFI_GCM_TAG_BYTES) }
    };
    try {
      const cipher = cryptoFramework.createCipher(WIFI_AES_TRANSFORMATION);
      await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params);
      const encrypted = await cipher.doFinal({ data: new Uint8Array(payload) });
      const result = bytesToArrayBuffer(encrypted.data);
      encrypted.data.fill(0);
      return result;
    } catch (error) {
      throw securityError(error as Object);
    } finally {
      iv.fill(0);
      aad.fill(0);
    }
  }

  async decrypt(direction: string, frameType: number, transferToken: number,
    sequence: number, payload: ArrayBuffer): Promise<ArrayBuffer> {
    this.assertUsable();
    if (payload.byteLength <= WIFI_GCM_TAG_BYTES) {
      throw new Error('Wi-Fi 加密帧缺少认证标签');
    }
    const encrypted = new Uint8Array(payload);
    const cipherText = copyBytes(encrypted.slice(0, encrypted.length - WIFI_GCM_TAG_BYTES));
    const authTag = copyBytes(encrypted.slice(encrypted.length - WIFI_GCM_TAG_BYTES));
    const iv = buildWifiFrameNonce(this.batchToken, direction, frameType, transferToken, sequence);
    const aad = buildWifiFrameAad(this.batchToken, direction, frameType, transferToken, sequence);
    const params: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: aad },
      authTag: { data: authTag }
    };
    try {
      const cipher = cryptoFramework.createCipher(WIFI_AES_TRANSFORMATION);
      await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, this.keyForDirection(direction), params);
      const decrypted = await cipher.doFinal({ data: cipherText });
      const result = bytesToArrayBuffer(decrypted.data);
      decrypted.data.fill(0);
      return result;
    } catch (error) {
      throw securityError(error as Object);
    } finally {
      cipherText.fill(0);
      authTag.fill(0);
      iv.fill(0);
      aad.fill(0);
    }
  }

  destroy(): void {
    if (this.destroyed) {
      return;
    }
    this.destroyed = true;
    this.batchToken = '';
    try {
      this.authKey.clearMem();
    } catch (error) {
    }
    try {
      this.watchToPhoneKey.clearMem();
    } catch (error) {
    }
    try {
      this.phoneToWatchKey.clearMem();
    } catch (error) {
    }
  }

  private keyForDirection(direction: string): cryptoFramework.SymKey {
    if (direction === WIFI_WATCH_TO_PHONE) {
      return this.watchToPhoneKey;
    }
    if (direction === WIFI_PHONE_TO_WATCH) {
      return this.phoneToWatchKey;
    }
    throw new Error('Wi-Fi 加密方向无效');
  }

  private assertUsable(): void {
    if (this.destroyed) {
      throw new Error('Wi-Fi 临时安全会话已销毁');
    }
  }
}

export async function createWifiTransferSecurityContext(
  credentials: WifiTransferSessionCredentials): Promise<WifiTransferSecurityContext> {
  assertCryptoAvailable();
  if (!isValidWifiTransferCredentials(credentials)) {
    throw new Error('Wi-Fi 临时安全凭据无效或已过期');
  }
  const masterBytes = wifiHexToBytes(credentials.temporaryKey);
  let masterKey: cryptoFramework.SymKey | undefined = undefined;
  try {
    masterKey = await convertHmacKey(masterBytes);
  } finally {
    masterBytes.fill(0);
  }
  if (masterKey === undefined) {
    throw new Error('无法载入 Wi-Fi 临时主密钥');
  }
  try {
    const authBytes = await hmacBytes(masterKey,
      textBytes(`${WIFI_SECURITY_PROTOCOL}\nauth\n${credentials.batchToken}`));
    const watchToPhoneBytes = await hmacBytes(masterKey,
      textBytes(`${WIFI_SECURITY_PROTOCOL}\nwatch_to_phone\n${credentials.batchToken}`));
    const phoneToWatchBytes = await hmacBytes(masterKey,
      textBytes(`${WIFI_SECURITY_PROTOCOL}\nphone_to_watch\n${credentials.batchToken}`));
    let authKey: cryptoFramework.SymKey | undefined = undefined;
    let watchToPhoneKey: cryptoFramework.SymKey | undefined = undefined;
    let phoneToWatchKey: cryptoFramework.SymKey | undefined = undefined;
    try {
      authKey = await convertHmacKey(authBytes);
      watchToPhoneKey = await convertAesKey(watchToPhoneBytes);
      phoneToWatchKey = await convertAesKey(phoneToWatchBytes);
      return new WifiTransferSecurityContext(credentials.batchToken, authKey, watchToPhoneKey, phoneToWatchKey);
    } catch (error) {
      if (authKey !== undefined) {
        authKey.clearMem();
      }
      if (watchToPhoneKey !== undefined) {
        watchToPhoneKey.clearMem();
      }
      if (phoneToWatchKey !== undefined) {
        phoneToWatchKey.clearMem();
      }
      throw securityError(error as Object);
    } finally {
      authBytes.fill(0);
      watchToPhoneBytes.fill(0);
      phoneToWatchBytes.fill(0);
    }
  } finally {
    masterKey.clearMem();
  }
}

export function wifiSecurityProtocolName(): string {
  return WIFI_SECURITY_PROTOCOL;
}
