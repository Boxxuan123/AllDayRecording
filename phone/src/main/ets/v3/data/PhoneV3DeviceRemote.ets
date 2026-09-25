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
import { connectComputerReceiver } from '../../computer/ComputerReceiverConnection';
import { ComputerTransferConfigStore } from '../../computer/ComputerTransferConfigStore';
import { ComputerTransferHttpClient } from '../../computer/ComputerTransferHttpClient';
import { PhoneV3RemotePort, PhoneV3RemoteSession } from '../application/PhoneV3Ports';

class PhoneV3HttpRemoteSession implements PhoneV3RemoteSession {
  private client: ComputerTransferHttpClient;

  constructor(client: ComputerTransferHttpClient) {
    this.client = client;
  }

  async status(): Promise<DeviceV3StatusResponse> {
    return this.client.v3Status();
  }

  async sync(request: DeviceV3SyncRequest): Promise<DeviceV3SyncResponse> {
    return this.client.sync(request);
  }

  async annotations(request: DeviceV3AnnotationRequest): Promise<DeviceV3AnnotationResponse> {
    return this.client.annotations(request);
  }

  async reviews(): Promise<DeviceV3ReviewSnapshot> {
    return this.client.v3Reviews();
  }

  async resolveReview(request: DeviceV3ReviewActionRequest): Promise<DeviceV3ReviewActionResponse> {
    return this.client.v3ReviewAction(request);
  }

  async reviewAudio(request: DeviceV3ReviewAudioRequest): Promise<DeviceV3ReviewAudioResponse> {
    return this.client.v3ReviewAudio(request);
  }
}

export class PhoneV3DeviceRemote implements PhoneV3RemotePort {
  private context: common.UIAbilityContext;
  private configStore: ComputerTransferConfigStore;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.configStore = new ComputerTransferConfigStore(context);
  }

  async isPaired(): Promise<boolean> {
    const config = await this.configStore.load();
    return config.isPaired();
  }

  async connect(): Promise<PhoneV3RemoteSession> {
    const updated = await connectComputerReceiver(this.context, this.configStore);
    return new PhoneV3HttpRemoteSession(new ComputerTransferHttpClient(
      this.context, updated.baseUrl, updated.caPath, updated.deviceId));
  }
}
