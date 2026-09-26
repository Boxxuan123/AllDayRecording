import { common } from '@kit.AbilityKit';
import { ComputerReceiverDiscovery } from './ComputerReceiverDiscovery';
import { ComputerTransferConfig, ComputerTransferConfigStore } from './ComputerTransferConfigStore';
import { ComputerTransferHttpClient } from './ComputerTransferHttpClient';
import { ComputerConnectionError, mayRediscover, connectionDiagnosticId } from './ComputerConnectionError';

const connecting: WeakMap<ComputerTransferConfigStore, Promise<ComputerTransferConfig>> =
  new WeakMap<ComputerTransferConfigStore, Promise<ComputerTransferConfig>>();

// mDNS locates changed addresses; a verified saved address is already sufficient.
export async function connectComputerReceiver(context: common.UIAbilityContext,
  store: ComputerTransferConfigStore): Promise<ComputerTransferConfig> {
  const pending=connecting.get(store);
  if (pending !== undefined) { return pending; }
  const task=connectSavedReceiver(context,store);
  connecting.set(store,task);
  try { return await task; } finally { connecting.delete(store); }
}

async function connectSavedReceiver(context: common.UIAbilityContext,
  store: ComputerTransferConfigStore): Promise<ComputerTransferConfig> {
  const id=connectionDiagnosticId();
  const started=Date.now();
  console.info(`[sync] id=${id} phase=connect start`);
  try {
  const config = await store.load();
  if (!config.isPaired()) { throw new ComputerConnectionError('unpaired', 'connect', '请先完成电脑 Passkey 配对'); }
  if (config.baseUrl.length > 0) {
    try {
      await verifyReceiver(context, config, config.baseUrl, id);
      return config;
    } catch (error) {
      if (!mayRediscover(error as Object)) { throw error as Error; }
    }
  }
  console.info(`[sync] id=${id} phase=discover start`);
  const address = await new ComputerReceiverDiscovery(context).discover(config.receiverId);
  await verifyReceiver(context, config, address, id);
  const current=await store.load();
  if (!current.isPaired() || current.receiverId !== config.receiverId || current.deviceId !== config.deviceId || current.caPath !== config.caPath) {
    throw new ComputerConnectionError('identity','verify','连接期间配对配置已变化，请重新连接');
  }
  return store.saveLastAddress(address);
  } finally { console.info(`[sync] id=${id} phase=connect end ms=${Date.now()-started}`); }
}

async function verifyReceiver(context: common.UIAbilityContext, config: ComputerTransferConfig,
  address: string, diagnosticId: string): Promise<void> {
  const status = await new ComputerTransferHttpClient(context, address, config.caPath, config.deviceId, diagnosticId).status();
  if (status.receiver_id !== config.receiverId) {
    throw new ComputerConnectionError('identity', 'verify', '电脑接收端身份与已配对身份不一致');
  }
}
