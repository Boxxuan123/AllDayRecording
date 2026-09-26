import { common } from '@kit.AbilityKit';
import {
  DeviceV3AnnotationRequest,
  DeviceV3AnnotationResponse,
  DeviceV3ReviewActionRequest,
  DeviceV3ReviewActionResponse,
  DeviceV3ReviewAudioRequest,
  DeviceV3ReviewAudioResponse,
  DeviceV3ReviewSnapshot,
  DeviceV3StatusResponse,
  DeviceV3SyncRequest,
  DeviceV3SyncResponse
} from '../../computer/ComputerTransferProtocol';
import { connectComputerReceiver, verifyConfiguration } from '../../computer/ComputerReceiverConnection';
import { ComputerTransferConfigStore, ComputerTransferConfig } from '../../computer/ComputerTransferConfigStore';
import { ComputerTransferHttpClient } from '../../computer/ComputerTransferHttpClient';
import { PhoneV3RemotePort, PhoneV3RemoteSession } from '../application/PhoneV3Ports';

class PhoneV3HttpRemoteSession implements PhoneV3RemoteSession {
  private client: ComputerTransferHttpClient;
  private store: ComputerTransferConfigStore;
  private config: ComputerTransferConfig;

  constructor(client: ComputerTransferHttpClient, store: ComputerTransferConfigStore, config: ComputerTransferConfig) {
    this.client = client;
    this.store = store; this.config = config;
  }

  async status(): Promise<DeviceV3StatusResponse> {
    await verifyConfiguration(this.store, this.config);
    const response = await this.client.v3Status();
    await verifyConfiguration(this.store, this.config);
    return response;
  }

  async sync(request: DeviceV3SyncRequest): Promise<DeviceV3SyncResponse> {
    await verifyConfiguration(this.store, this.config);
    const response = await this.client.sync(request);
    await verifyConfiguration(this.store, this.config);
    return response;
  }

  async annotations(request: DeviceV3AnnotationRequest): Promise<DeviceV3AnnotationResponse> {
    await verifyConfiguration(this.store, this.config);
    const response = await this.client.annotations(request);
    await verifyConfiguration(this.store, this.config);
    return response;
  }

  async reviews(): Promise<DeviceV3ReviewSnapshot> {
    await verifyConfiguration(this.store, this.config);
    const response = await this.client.v3Reviews();
    await verifyConfiguration(this.store, this.config);
    return response;
  }

  async resolveReview(request: DeviceV3ReviewActionRequest): Promise<DeviceV3ReviewActionResponse> {
    await verifyConfiguration(this.store, this.config);
    const response = await this.client.v3ReviewAction(request);
    await verifyConfiguration(this.store, this.config);
    return response;
  }

  async reviewAudio(request: DeviceV3ReviewAudioRequest): Promise<DeviceV3ReviewAudioResponse> {
    await verifyConfiguration(this.store, this.config);
    const response = await this.client.v3ReviewAudio(request);
    response.local_audio_path = undefined;
    response.local_worker_tid = undefined;
    await verifyConfiguration(this.store, this.config);
    return response;
  }
}

export class PhoneV3DeviceRemote implements PhoneV3RemotePort {
  private context: common.UIAbilityContext;
  private configStore: ComputerTransferConfigStore;

  constructor(context: common.UIAbilityContext, store?: ComputerTransferConfigStore) {
    this.context = context;
    this.configStore = store ?? new ComputerTransferConfigStore(context);
  }

  async isPaired(): Promise<boolean> {
    const config = await this.configStore.load();
    return config.isPaired();
  }

  async connect(): Promise<PhoneV3RemoteSession> {
    const updated = await connectComputerReceiver(this.context, this.configStore);
    return new PhoneV3HttpRemoteSession(new ComputerTransferHttpClient(
      this.context, updated.baseUrl, updated.caPath, updated.deviceId, '', updated.signingKeyAlias), this.configStore, updated);
  }

  async audioNamespace(): Promise<string> {
    const config = await this.configStore.load();
    if (!config.isPaired()) { return ''; }
    return JSON.stringify([config.receiverId, config.caFingerprint, config.deviceId, config.rpId, config.signingKeyAlias]);
  }
}
