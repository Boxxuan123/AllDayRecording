import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { wearEngine } from '@kit.WearEngine';
import {
  WatchSyncProtocolMessage,
  encodeWatchSyncMessage
} from '../protocol/WatchFileSyncProtocol';
import {
  P2P_COMMUNICATION_SUCCESS,
  p2pResultMessage
} from './WearEngineTransportPolicy';

export {
  P2P_REMOTE_APP_NOT_INSTALLED,
  P2P_REMOTE_APP_NOT_RUNNING,
  P2P_REMOTE_APP_RUNNING,
  P2P_COMMUNICATION_FAILURE,
  P2P_COMMUNICATION_SUCCESS,
  p2pResultMessage,
  isP2pCommunicationError,
  shouldRetryReceiverConnection,
  wearEngineErrorMessage
} from './WearEngineTransportPolicy';

export interface WearEngineConnection {
  peer: wearEngine.Device;
  client: wearEngine.P2pClient;
  appParam: wearEngine.P2pAppParam;
}

export type WearEngineMessageReceiver = (incoming: wearEngine.P2pMessage) => void;
export type WearEngineFileReceiver = (incoming: wearEngine.P2pFile) => void;

export function validateP2pResult(result: wearEngine.P2pResult): void {
  if (result.code !== undefined && result.code !== P2P_COMMUNICATION_SUCCESS) {
    throw new Error(p2pResultMessage(result.code));
  }
}

export async function destroyWearEngineChannel(): Promise<void> {
  try {
    await wearEngine.destroy();
  } catch (error) {
    throw transportError(error);
  }
}

export class WearEngineTransport {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async connect(requireRemoteApp: boolean = true): Promise<WearEngineConnection> {
    const peer = await this.getConnectedPeer();
    try {
      const client = wearEngine.getP2pClient(this.context);
      const appParam = await this.getLocalAppParam();
      if (requireRemoteApp) {
        const installed = await client.isRemoteAppInstalled(peer.randomId, appParam.remoteApp.bundleName);
        if (!installed) {
          throw new Error('对端尚未安装本应用');
        }
      }
      return {
        peer: peer,
        client: client,
        appParam: appParam
      };
    } catch (error) {
      throw transportError(error);
    }
  }

  async registerMessageReceiver(connection: WearEngineConnection,
    receiver: WearEngineMessageReceiver): Promise<void> {
    try {
      await connection.client.registerMessageReceiver(
        connection.peer.randomId, connection.appParam, receiver);
    } catch (error) {
      throw transportError(error);
    }
  }

  async unregisterMessageReceiver(connection: WearEngineConnection,
    receiver: WearEngineMessageReceiver): Promise<void> {
    try {
      await connection.client.unregisterMessageReceiver(
        connection.peer.randomId, connection.appParam, receiver);
    } catch (error) {
      throw transportError(error);
    }
  }

  async registerFileReceiver(connection: WearEngineConnection,
    receiver: WearEngineFileReceiver): Promise<void> {
    try {
      await connection.client.registerFileReceiver(
        connection.peer.randomId, connection.appParam, receiver);
    } catch (error) {
      throw transportError(error);
    }
  }

  async unregisterFileReceiver(connection: WearEngineConnection,
    receiver: WearEngineFileReceiver): Promise<void> {
    try {
      await connection.client.unregisterFileReceiver(
        connection.peer.randomId, connection.appParam, receiver);
    } catch (error) {
      throw transportError(error);
    }
  }

  async sendProtocolMessage(connection: WearEngineConnection,
    message: WatchSyncProtocolMessage): Promise<void> {
    const p2pMessage: wearEngine.P2pMessage = {
      content: encodeWatchSyncMessage(message)
    };
    try {
      const result = await connection.client.sendMessage(
        connection.peer.randomId, connection.appParam, p2pMessage);
      validateP2pResult(result);
    } catch (error) {
      throw transportError(error);
    }
  }

  transferFile(connection: WearEngineConnection, file: fileIo.File,
    callback: (error: BusinessError, result: wearEngine.P2pResult) => void): void {
    try {
      connection.client.transferFile(connection.peer.randomId, connection.appParam, { file: file }, callback);
    } catch (error) {
      throw transportError(error);
    }
  }

  async startRemoteApp(connection: WearEngineConnection): Promise<wearEngine.P2pResult> {
    try {
      return connection.client.startRemoteApp(
        connection.peer.randomId, connection.appParam.remoteApp.bundleName);
    } catch (error) {
      throw transportError(error);
    }
  }

  async destroy(): Promise<void> {
    await destroyWearEngineChannel();
  }

  private async getLocalAppParam(): Promise<wearEngine.P2pAppParam> {
    const info = await bundleManager.getBundleInfoForSelf(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_SIGNATURE_INFO);
    return {
      remoteApp: {
        bundleName: info.name,
        // Wear Engine's legacy field name is fingerprint; HarmonyOS uses appIdentifier as the app identity.
        fingerprint: info.signatureInfo.appIdentifier
      }
    };
  }

  private async getConnectedPeer(): Promise<wearEngine.Device> {
    if (!canIUse('SystemCapability.Health.WearEngine')) {
      throw new Error('当前设备不支持 Wear Engine');
    }
    try {
      const devices = await wearEngine.getDeviceClient(this.context).getConnectedDevices();
      if (devices.length === 0) {
        throw new Error('未找到已连接的对端设备，请先在华为运动健康中确认手机与手表在线');
      }
      return devices[0];
    } catch (error) {
      throw transportError(error);
    }
  }
}

function transportError(error: Object): Error {
  return error instanceof Error ? error : new Error(JSON.stringify(error));
}
