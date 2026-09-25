import { common } from '@kit.AbilityKit';
import { ComputerReceiverDiscovery } from './ComputerReceiverDiscovery';
import { ComputerTransferConfig, ComputerTransferConfigStore } from './ComputerTransferConfigStore';
import { ComputerTransferHttpClient } from './ComputerTransferHttpClient';

// mDNS locates changed addresses; a verified saved address is already sufficient.
export async function connectComputerReceiver(context: common.UIAbilityContext,
  store: ComputerTransferConfigStore): Promise<ComputerTransferConfig> {
  const config = await store.load();
  if (!config.isPaired()) { throw new Error('请先完成电脑 Passkey 配对'); }
  if (config.baseUrl.length > 0) {
    try {
      await verifyReceiver(context, config, config.baseUrl);
      return config;
    } catch (error) {
      // A changed address is recovered through the stable receiver identity.
    }
  }
  const address = await new ComputerReceiverDiscovery(context).discover(config.receiverId);
  await verifyReceiver(context, config, address);
  return store.saveLastAddress(address);
}

async function verifyReceiver(context: common.UIAbilityContext, config: ComputerTransferConfig,
  address: string): Promise<void> {
  const status = await new ComputerTransferHttpClient(context, address, config.caPath, config.deviceId).status();
  if (status.receiver_id !== config.receiverId) {
    throw new Error('电脑接收端身份与已配对身份不一致');
  }
}
