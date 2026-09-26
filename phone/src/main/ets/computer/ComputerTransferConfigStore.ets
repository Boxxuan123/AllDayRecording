import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { cert } from '@kit.DeviceCertificateKit';
import { writeBufferAtomically } from 'common';
import {
  computerTransferError,
  normalizeCertificateFingerprint,
  normalizeComputerBaseUrl,
  normalizeDeviceId,
  normalizeReceiverId
} from './ComputerTransferProtocol';

const PREFERENCES_NAME: string = 'computer_transfer_v1';
const BASE_URL_KEY: string = 'base_url';
const CA_FINGERPRINT_KEY: string = 'ca_fingerprint';
const RP_ID_KEY: string = 'rp_id';
const RECEIVER_ID_KEY: string = 'receiver_id';
const DEVICE_ID_KEY: string = 'device_id';
const CONFIG_DIRECTORY: string = 'computer_transfer';
const CA_FILE_NAME: string = 'receiver-ca.pem';
const MAX_CA_BYTES: number = 8000;

export class ComputerTransferConfig {
  signingKeyAlias: string = 'alldayrecording.computer-transfer.device-signing.v1';
  baseUrl: string;
  caFingerprint: string;
  rpId: string;
  caPath: string;
  receiverId: string;
  deviceId: string;

  constructor(baseUrl: string = '', caFingerprint: string = '', rpId: string = '', caPath: string = '',
    receiverId: string = '', deviceId: string = '') {
    this.baseUrl = baseUrl;
    this.caFingerprint = caFingerprint;
    this.rpId = rpId;
    this.caPath = caPath;
    this.receiverId = receiverId;
    this.deviceId = deviceId;
  }

  isPaired(): boolean {
    return this.caFingerprint.length > 0 && this.rpId.length > 0 && this.receiverId.length > 0 &&
      this.deviceId.length > 0 && this.caPath.length > 0 && fileIo.accessSync(this.caPath);
  }
}

export class ImportedComputerCa {
  path: string;
  fingerprint: string;
  pem: string;

  constructor(path: string, fingerprint: string, pem: string) {
    this.path = path;
    this.fingerprint = fingerprint;
    this.pem = pem;
  }
}

export class ComputerTransferConfigStore {
  private context: common.UIAbilityContext;
  private directory: string;
  private caPath: string;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.directory = `${context.filesDir}/${CONFIG_DIRECTORY}`;
    this.caPath = `${this.directory}/${CA_FILE_NAME}`;
  }

  async load(): Promise<ComputerTransferConfig> {
    try {
      const store = await preferences.getPreferences(this.context, PREFERENCES_NAME);
      const baseUrl = await store.get(BASE_URL_KEY, '');
      const fingerprint = await store.get(CA_FINGERPRINT_KEY, '');
      const rpId = await store.get(RP_ID_KEY, '');
      const receiverId = await store.get(RECEIVER_ID_KEY, '');
      const deviceId = await store.get(DEVICE_ID_KEY, '');
      let trustedCaPath = '';
      if (typeof fingerprint === 'string' && fingerprint.length > 0 && fileIo.accessSync(this.caPath)) {
        try {
          const actual = await certificateFingerprint(readSmallFile(this.caPath));
          if (actual === normalizeCertificateFingerprint(fingerprint)) {
            trustedCaPath = this.caPath;
          }
        } catch (error) {
          trustedCaPath = '';
        }
      }
      return new ComputerTransferConfig(
        typeof baseUrl === 'string' ? baseUrl : '',
        typeof fingerprint === 'string' ? fingerprint : '',
        typeof rpId === 'string' ? rpId : '',
        trustedCaPath,
        typeof receiverId === 'string' ? receiverId : '',
        typeof deviceId === 'string' ? deviceId : ''
      );
    } catch (error) {
      throw computerTransferError(error as Object);
    }
  }

  async importCa(uri: string, expectedFingerprint: string): Promise<ImportedComputerCa> {
    let fd: number = -1;
    try {
      if (!canIUse('SystemCapability.Security.Cert') ||
        !canIUse('SystemCapability.Security.CryptoFramework')) {
        throw new Error('本机系统不支持配对 CA 与 SHA-256 校验');
      }
      const expected = normalizeCertificateFingerprint(expectedFingerprint);
      const source = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      fd = source.fd;
      const stat = fileIo.statSync(fd);
      if (!stat.isFile() || stat.size <= 0 || stat.size > MAX_CA_BYTES) {
        throw new Error('配对 CA 文件为空或超过 8000 bytes');
      }
      const buffer = new ArrayBuffer(stat.size);
      const read = fileIo.readSync(fd, buffer);
      if (read !== stat.size) {
        throw new Error('配对 CA 文件没有完整读取');
      }
      const bytes = new Uint8Array(buffer);
      const pem = util.TextDecoder.create('utf-8').decodeToString(bytes);
      if (!pem.includes('-----BEGIN CERTIFICATE-----') || !pem.includes('-----END CERTIFICATE-----')) {
        throw new Error('选择的文件不是 PEM 证书');
      }
      const actual = await certificateFingerprint(bytes);
      if (actual !== expected) {
        throw new Error(`配对 CA 指纹不一致：实际为 ${actual}`);
      }
      if (!fileIo.accessSync(this.directory)) {
        fileIo.mkdirSync(this.directory);
      }
      writeBufferAtomically(this.caPath, buffer);
      const store = await preferences.getPreferences(this.context, PREFERENCES_NAME);
      const savedFingerprint = await store.get(CA_FINGERPRINT_KEY, '');
      let savedMatches = false;
      if (typeof savedFingerprint === 'string' && savedFingerprint.length > 0) {
        try {
          savedMatches = normalizeCertificateFingerprint(savedFingerprint) === actual;
        } catch (error) {
          savedMatches = false;
        }
      }
      if (typeof savedFingerprint === 'string' && savedFingerprint.length > 0 && !savedMatches) {
        await store.put(BASE_URL_KEY, '');
        await store.put(CA_FINGERPRINT_KEY, '');
        await store.put(RP_ID_KEY, '');
        await store.put(RECEIVER_ID_KEY, '');
        await store.put(DEVICE_ID_KEY, '');
        await store.flush();
      }
      return new ImportedComputerCa(this.caPath, actual, pem);
    } catch (error) {
      throw computerTransferError(error as Object);
    } finally {
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (error) {
        }
      }
    }
  }

  async importCaPem(pem: string, expectedFingerprint: string): Promise<ImportedComputerCa> {
    try {
      if (pem.length <= 0 || pem.length > MAX_CA_BYTES ||
        !pem.includes('-----BEGIN CERTIFICATE-----') || !pem.includes('-----END CERTIFICATE-----')) {
        throw new Error('配对二维码中的 CA 证书无效');
      }
      const bytes = util.TextEncoder.create('utf-8').encodeInto(pem);
      const expected = normalizeCertificateFingerprint(expectedFingerprint);
      const actual = await certificateFingerprint(bytes);
      if (actual !== expected) {
        throw new Error(`配对 CA 指纹不一致：实际为 ${actual}`);
      }
      if (!fileIo.accessSync(this.directory)) {
        fileIo.mkdirSync(this.directory);
      }
      const buffer = new ArrayBuffer(bytes.length);
      new Uint8Array(buffer).set(bytes);
      writeBufferAtomically(this.caPath, buffer);
      const store = await preferences.getPreferences(this.context, PREFERENCES_NAME);
      const savedFingerprint = await store.get(CA_FINGERPRINT_KEY, '');
      let savedMatches = false;
      if (typeof savedFingerprint === 'string' && savedFingerprint.length > 0) {
        try {
          savedMatches = normalizeCertificateFingerprint(savedFingerprint) === actual;
        } catch (error) {
          savedMatches = false;
        }
      }
      if (typeof savedFingerprint === 'string' && savedFingerprint.length > 0 && !savedMatches) {
        await store.put(BASE_URL_KEY, '');
        await store.put(CA_FINGERPRINT_KEY, '');
        await store.put(RP_ID_KEY, '');
        await store.put(RECEIVER_ID_KEY, '');
        await store.put(DEVICE_ID_KEY, '');
        await store.flush();
      }
      return new ImportedComputerCa(this.caPath, actual, pem);
    } catch (error) {
      throw computerTransferError(error as Object);
    }
  }

  async savePairing(baseUrl: string, caFingerprint: string, rpId: string,
    receiverId: string, deviceId: string): Promise<ComputerTransferConfig> {
    try {
      const normalizedUrl = normalizeComputerBaseUrl(baseUrl);
      const normalizedFingerprint = normalizeCertificateFingerprint(caFingerprint);
      const normalizedReceiverId = normalizeReceiverId(receiverId);
      const normalizedDeviceId = normalizeDeviceId(deviceId);
      if (!fileIo.accessSync(this.caPath) || rpId.trim().length === 0) {
        throw new Error('保存配对前必须导入 CA 并完成 Passkey 登记');
      }
      const actualFingerprint = await certificateFingerprint(readSmallFile(this.caPath));
      if (actualFingerprint !== normalizedFingerprint) {
        throw new Error('已导入 CA 与准备保存的证书指纹不一致');
      }
      const store = await preferences.getPreferences(this.context, PREFERENCES_NAME);
      await store.put(BASE_URL_KEY, normalizedUrl);
      await store.put(CA_FINGERPRINT_KEY, normalizedFingerprint);
      await store.put(RP_ID_KEY, rpId.trim());
      await store.put(RECEIVER_ID_KEY, normalizedReceiverId);
      await store.put(DEVICE_ID_KEY, normalizedDeviceId);
      await store.flush();
      return new ComputerTransferConfig(normalizedUrl, normalizedFingerprint, rpId.trim(), this.caPath,
        normalizedReceiverId, normalizedDeviceId);
    } catch (error) {
      throw computerTransferError(error as Object);
    }
  }

  async saveLastAddress(baseUrl: string): Promise<ComputerTransferConfig> {
    const current = await this.load();
    if (!current.isPaired()) {
      throw new Error('尚未完成电脑配对');
    }
    const normalizedUrl = normalizeComputerBaseUrl(baseUrl);
    const store = await preferences.getPreferences(this.context, PREFERENCES_NAME);
    await store.put(BASE_URL_KEY, normalizedUrl);
    await store.flush();
    current.baseUrl = normalizedUrl;
    return current;
  }

  readImportedCa(): ImportedComputerCa {
    if (!fileIo.accessSync(this.caPath)) {
      throw new Error('尚未导入电脑的配对 CA 证书');
    }
    const pem = fileIo.readTextSync(this.caPath);
    return new ImportedComputerCa(this.caPath, '', pem);
  }
}

function readSmallFile(path: string): Uint8Array {
  let fd: number = -1;
  try {
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    fd = file.fd;
    const stat = fileIo.statSync(fd);
    if (!stat.isFile() || stat.size <= 0 || stat.size > MAX_CA_BYTES) {
      throw new Error('配对 CA 文件为空或超过 8000 bytes');
    }
    const buffer = new ArrayBuffer(stat.size);
    const read = fileIo.readSync(fd, buffer);
    if (read !== stat.size) {
      throw new Error('配对 CA 文件没有完整读取');
    }
    return new Uint8Array(buffer);
  } finally {
    if (fd >= 0) {
      try {
        fileIo.closeSync(fd);
      } catch (error) {
      }
    }
  }
}

async function certificateFingerprint(pemBytes: Uint8Array): Promise<string> {
  const certificate = await cert.createX509Cert({
    data: pemBytes,
    encodingFormat: cert.EncodingFormat.FORMAT_PEM
  });
  const encoded = await certificate.getEncoded();
  const digest = cryptoFramework.createMd('SHA256');
  await digest.update({ data: encoded.data });
  const result = await digest.digest();
  const parts: Array<string> = [];
  for (let index = 0; index < result.data.length; index += 1) {
    parts.push(result.data[index].toString(16).padStart(2, '0').toUpperCase());
  }
  return parts.join(':');
}
