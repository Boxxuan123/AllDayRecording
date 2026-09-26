import { huks } from '@kit.UniversalKeystoreKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DEVICE_KEY_ALGORITHM, encodeBase64Url } from './ComputerTransferProtocol';

const DEVICE_KEY_ALIAS: string = 'alldayrecording.computer-transfer.device-signing.v1';

function keyProperties(purpose: huks.HuksKeyPurpose): Array<huks.HuksParam> {
  return [
    {
      tag: huks.HuksTag.HUKS_TAG_ALGORITHM,
      value: huks.HuksKeyAlg.HUKS_ALG_ECC
    },
    {
      tag: huks.HuksTag.HUKS_TAG_KEY_SIZE,
      value: huks.HuksKeySize.HUKS_ECC_KEY_SIZE_256
    },
    {
      tag: huks.HuksTag.HUKS_TAG_PURPOSE,
      value: purpose
    },
    {
      tag: huks.HuksTag.HUKS_TAG_DIGEST,
      value: huks.HuksKeyDigest.HUKS_DIGEST_SHA256
    }
  ];
}

export class PhoneDeviceKeyClient {
  private alias: string;
  constructor(alias: string = DEVICE_KEY_ALIAS) { this.alias = alias; }
  algorithm(): string {
    return DEVICE_KEY_ALGORITHM;
  }

  async capabilityDescription(): Promise<string> {
    if (!canIUse('SystemCapability.Security.Huks.Core')) {
      return '本机系统不支持 HUKS 设备密钥';
    }
    try {
      await this.ensurePublicKey();
      return 'HUKS 设备密钥可用，后续认证无需弹窗';
    } catch (error) {
      const value = error as Error;
      return `HUKS 设备密钥不可用：${value.message}`;
    }
  }

  async ensurePublicKey(): Promise<string> {
    this.requireCapability();
    const emptyOptions: huks.HuksOptions = { properties: [] };
    let keyExists = false;
    try {
      keyExists = await huks.isKeyItemExist(this.alias, emptyOptions);
    } catch (error) {
      // The promise API rejects with 12000011 when an alias does not exist;
      // it does not consistently resolve to false on physical devices.
      if (!isHuksError(error as Object, 12000011)) {
        throw new Error(huksErrorMessage(error as Object));
      }
    }
    if (!keyExists) {
      try {
        await huks.generateKeyItem(this.alias, {
          properties: keyProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN)
        });
      } catch (error) {
        // Capability probing and pairing can initialize concurrently. If the
        // other call created the alias first, continue and export that key.
        if (!isHuksError(error as Object, 12000017)) {
          throw new Error(huksErrorMessage(error as Object));
        }
      }
    }
    const exported = await huks.exportKeyItem(this.alias, emptyOptions);
    if (exported.outData === undefined || exported.outData.length === 0) {
      throw new Error('HUKS 没有返回设备公钥');
    }
    return encodeBase64Url(exported.outData);
  }

  async sign(payload: Uint8Array): Promise<string> {
    this.requireCapability();
    if (payload.length === 0 || payload.length > 4096) {
      throw new Error('设备签名载荷大小无效');
    }
    await this.ensurePublicKey();
    const properties = keyProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN);
    const session = await huks.initSession(this.alias, { properties: properties });
    try {
      await huks.updateSession(session.handle, {
        properties: properties,
        inData: payload
      });
      const result = await huks.finishSession(session.handle, { properties: properties });
      if (result.outData === undefined || result.outData.length === 0) {
        throw new Error('HUKS 没有返回设备签名');
      }
      return encodeBase64Url(result.outData);
    } catch (error) {
      try {
        await huks.abortSession(session.handle, { properties: properties });
      } catch (abortError) {
      }
      const value = error as Error;
      throw new Error(value.message);
    }
  }

  private requireCapability(): void {
    if (!canIUse('SystemCapability.Security.Huks.Core')) {
      throw new Error('本机系统不支持 HUKS 设备密钥');
    }
  }
}

function isHuksError(error: Object, code: number): boolean {
  return (error as BusinessError).code === code;
}

function huksErrorMessage(error: Object): string {
  if (error instanceof Error) {
    return error.message;
  }
  const business = error as BusinessError;
  if (business.message !== undefined && business.message.length > 0) {
    return `${business.message}`;
  }
  return `HUKS 错误 ${business.code}`;
}
