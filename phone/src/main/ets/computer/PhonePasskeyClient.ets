import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import fido2 from '@hms.security.fido2';
import {
  ComputerAuthenticationPublicKeyOptions,
  ComputerAuthenticatorSelection,
  ComputerCredentialDescriptor,
  ComputerRegistrationPublicKeyOptions,
  decodeBase64Url,
  normalizeBase64Url
} from './ComputerTransferProtocol';

interface ServerAttestationResponse {
  clientDataJSON: string;
  authenticatorData?: string;
  transports: Array<string>;
  publicKey?: string;
  publicKeyAlgorithm?: number;
  attestationObject: string;
}

interface ServerRegistrationCredential {
  id: string;
  rawId: string;
  response: ServerAttestationResponse;
  authenticatorAttachment?: string;
  clientExtensionResults: Object;
  type: string;
}

interface ServerAssertionResponse {
  clientDataJSON: string;
  authenticatorData: string;
  signature: string;
  userHandle?: string;
}

interface ServerAuthenticationCredential {
  id: string;
  rawId: string;
  response: ServerAssertionResponse;
  authenticatorAttachment?: string;
  clientExtensionResults: Object;
  type: string;
}

export class PhonePasskeyClient {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async capabilityDescription(): Promise<string> {
    if (!canIUse('SystemCapability.Security.FIDO2')) {
      return '本机系统不支持 Passkey';
    }
    // Some production HarmonyOS builds expose register/authenticate but omit the
    // optional getClientCapabilities function declared by the SDK. Registration
    // itself is the authoritative capability check and provides a useful system
    // error when the device has no usable platform authenticator.
    return 'Passkey 系统能力可用，首次配对时由系统确认';
  }

  async register(options: ComputerRegistrationPublicKeyOptions): Promise<Object> {
    this.requireCapability();
    try {
      const credential = await fido2.register(this.context, {
        mediation: fido2.CredentialMediationRequirement.REQUIRED,
        publicKey: registrationOptions(options)
      });
      const response = credential.registrationResponseJson;
      const serverResponse: ServerAttestationResponse = {
        clientDataJSON: normalizeBase64Url(response.response.clientDataJson),
        transports: response.response.transports,
        publicKeyAlgorithm: response.response.publicKeyAlgorithm,
        attestationObject: normalizeBase64Url(response.response.attestationObject)
      };
      // HarmonyOS represents optional WebAuthn convenience fields as an empty
      // string on some devices. They are not part of the required attestation
      // response, so omit them instead of treating empty as malformed base64.
      if (response.response.authenticatorData.length > 0) {
        serverResponse.authenticatorData = normalizeBase64Url(response.response.authenticatorData);
      }
      if (response.response.publicKey !== undefined && response.response.publicKey.length > 0) {
        serverResponse.publicKey = normalizeBase64Url(response.response.publicKey);
      }
      const serverCredential: ServerRegistrationCredential = {
        id: normalizeBase64Url(response.id),
        rawId: normalizeBase64Url(response.rawId),
        type: response.type,
        authenticatorAttachment: response.authenticatorAttachment,
        clientExtensionResults: response.clientExtensionResults,
        response: serverResponse
      };
      return serverCredential;
    } catch (error) {
      throw new Error(passkeyErrorMessage(error as Object));
    }
  }

  async authenticate(options: ComputerAuthenticationPublicKeyOptions): Promise<Object> {
    this.requireCapability();
    try {
      const credential = await fido2.authenticate(this.context, {
        mediation: fido2.CredentialMediationRequirement.REQUIRED,
        publicKey: authenticationOptions(options)
      });
      const response = credential.authenticationResponseJson;
      const serverCredential: ServerAuthenticationCredential = {
        id: normalizeBase64Url(response.id),
        rawId: normalizeBase64Url(response.rawId),
        type: response.type,
        authenticatorAttachment: response.authenticatorAttachment,
        clientExtensionResults: response.clientExtensionResults,
        response: {
          clientDataJSON: normalizeBase64Url(response.response.clientDataJson),
          authenticatorData: normalizeBase64Url(response.response.authenticatorData),
          signature: normalizeBase64Url(response.response.signature),
          userHandle: response.response.userHandle === undefined ? undefined :
            normalizeBase64Url(response.response.userHandle)
        }
      };
      return serverCredential;
    } catch (error) {
      throw new Error(passkeyErrorMessage(error as Object));
    }
  }

  private requireCapability(): void {
    if (!canIUse('SystemCapability.Security.FIDO2')) {
      throw new Error('本机系统不支持 Passkey');
    }
  }
}

function registrationOptions(value: ComputerRegistrationPublicKeyOptions): fido2.PublicKeyCredentialCreationOptions {
  const parameters: Array<fido2.PublicKeyCredentialParameters> = [];
  for (let index = 0; index < value.pubKeyCredParams.length; index += 1) {
    const supported = algorithm(value.pubKeyCredParams[index].alg);
    if (supported !== undefined) {
      parameters.push({
        type: fido2.PublicKeyCredentialType.PUBLIC_KEY,
        alg: supported
      });
    }
  }
  if (parameters.length === 0) {
    throw new Error('电脑没有提供本机支持的 Passkey 算法');
  }
  return {
    rp: { id: value.rp.id, name: value.rp.name },
    user: {
      id: decodeBase64Url(value.user.id),
      name: value.user.name,
      displayName: value.user.displayName
    },
    challenge: decodeBase64Url(value.challenge),
    pubKeyCredParams: parameters,
    timeout: value.timeout,
    excludeCredentials: descriptors(value.excludeCredentials),
    authenticatorSelection: authenticatorSelection(value.authenticatorSelection),
    hints: hints(value.hints),
    attestation: fido2.AttestationConveyancePreference.NONE
  };
}

function authenticationOptions(value: ComputerAuthenticationPublicKeyOptions): fido2.PublicKeyCredentialRequestOptions {
  return {
    challenge: decodeBase64Url(value.challenge),
    timeout: value.timeout,
    rpId: value.rpId,
    allowCredentials: descriptors(value.allowCredentials),
    userVerification: fido2.UserVerificationRequirement.REQUIRED,
    hints: hints(value.hints)
  };
}

function algorithm(value: number): fido2.Algorithm | undefined {
  switch (value) {
    case -7: return fido2.Algorithm.ES256;
    case -35: return fido2.Algorithm.ES384;
    case -36: return fido2.Algorithm.ES512;
    case -37: return fido2.Algorithm.PS256;
    case -38: return fido2.Algorithm.PS384;
    case -39: return fido2.Algorithm.PS512;
    case -257: return fido2.Algorithm.RS256;
    case -258: return fido2.Algorithm.RS384;
    case -259: return fido2.Algorithm.RS512;
    default: return undefined;
  }
}

function descriptors(values: Array<ComputerCredentialDescriptor> | undefined):
  Array<fido2.PublicKeyCredentialDescriptor> | undefined {
  if (values === undefined) {
    return undefined;
  }
  const result: Array<fido2.PublicKeyCredentialDescriptor> = [];
  for (let index = 0; index < values.length; index += 1) {
    result.push({
      type: fido2.PublicKeyCredentialType.PUBLIC_KEY,
      id: decodeBase64Url(values[index].id),
      transports: transports(values[index].transports)
    });
  }
  return result;
}

function transports(values: Array<string> | undefined): Array<fido2.AuthenticatorTransport> | undefined {
  if (values === undefined) {
    return undefined;
  }
  const result: Array<fido2.AuthenticatorTransport> = [];
  for (let index = 0; index < values.length; index += 1) {
    switch (values[index]) {
      case 'usb': result.push(fido2.AuthenticatorTransport.USB); break;
      case 'nfc': result.push(fido2.AuthenticatorTransport.NFC); break;
      case 'ble': result.push(fido2.AuthenticatorTransport.BLE); break;
      case 'smart-card': result.push(fido2.AuthenticatorTransport.SMART_CARD); break;
      case 'hybrid': result.push(fido2.AuthenticatorTransport.HYBRID); break;
      case 'internal': result.push(fido2.AuthenticatorTransport.INTERNAL); break;
    }
  }
  return result;
}

function hints(values: Array<string> | undefined): Array<fido2.PublicKeyCredentialHint> | undefined {
  if (values === undefined) {
    return undefined;
  }
  const result: Array<fido2.PublicKeyCredentialHint> = [];
  for (let index = 0; index < values.length; index += 1) {
    switch (values[index]) {
      case 'security-key': result.push(fido2.PublicKeyCredentialHint.SECURITY_KEY); break;
      case 'client-device': result.push(fido2.PublicKeyCredentialHint.CLIENT_DEVICE); break;
      case 'hybrid': result.push(fido2.PublicKeyCredentialHint.HYBRID); break;
    }
  }
  return result;
}

function authenticatorSelection(value: ComputerAuthenticatorSelection | undefined):
  fido2.AuthenticatorSelectionCriteria | undefined {
  if (value === undefined) {
    return undefined;
  }
  return {
    authenticatorAttachment: fido2.AuthenticatorAttachment.PLATFORM,
    residentKey: value.residentKey,
    requireResidentKey: value.requireResidentKey,
    userVerification: fido2.UserVerificationRequirement.REQUIRED
  };
}

export function passkeyErrorMessage(error: Object): string {
  const business = error as BusinessError;
  if (business.code === 1021300004 || business.code === 1021300010) {
    return '用户取消了 Passkey 验证';
  }
  if (business.code === 1021300005) {
    return 'Passkey 验证超时';
  }
  if (business.code === 1021300008 || business.code === 1021300003) {
    return 'Passkey RP 域名尚未与本应用完成 App Linking/AGC 关联';
  }
  if (business.code === 1021310006) {
    return '本机没有该电脑对应的 Passkey，请重新完成首次配对';
  }
  if (error instanceof Error) {
    return error.message;
  }
  return `Passkey 错误 ${business.code}: ${business.message}`;
}
