import { common } from '@kit.AbilityKit';
import { ComputerReceiverDiscovery } from './ComputerReceiverDiscovery';
import { ComputerTransferConfig, ComputerTransferConfigStore } from './ComputerTransferConfigStore';
import { ComputerTransferHttpClient } from './ComputerTransferHttpClient';
import { ComputerConnectionError, mayRediscover, connectionDiagnosticId } from './ComputerConnectionError';

const connecting: Map<string, Promise<ComputerTransferConfig>> = new Map<string, Promise<ComputerTransferConfig>>();

// mDNS locates changed addresses; a verified saved address is already sufficient.
export async function connectComputerReceiver(context: common.UIAbilityContext,
  store: ComputerTransferConfigStore): Promise<ComputerTransferConfig> {
  const config = await store.load();
  const key = JSON.stringify([context.filesDir, config.receiverId, config.deviceId, config.caFingerprint,
    config.caPath, config.rpId, config.baseUrl, config.signingKeyAlias]);
  const pending=connecting.get(key);
  if (pending !== undefined) {
    const ready = await pending;
    await verifyConfiguration(store, ready);
    return ready;
  }
  const task=connectSavedReceiver(context,store,config);
  connecting.set(key,task);
  try { return await task; } finally { connecting.delete(key); }
}

async function connectSavedReceiver(context: common.UIAbilityContext,
  store: ComputerTransferConfigStore, config: ComputerTransferConfig): Promise<ComputerTransferConfig> {
  const id=connectionDiagnosticId();
  const started=Date.now();
  console.debug(`[sync] id=${id} phase=connect start`);
  try {
  if (!config.isPaired()) { throw new ComputerConnectionError('unpaired', 'connect', '请先完成电脑 Passkey 配对'); }
  if (config.baseUrl.length > 0) {
    try {
      await verifyReceiver(context, config, config.baseUrl, id);
      await verifyConfiguration(store, config);
      return config;
    } catch (error) {
      // Only this GET status probe is replay-safe. Business decisions never enter this catch.
      if (!mayRediscover(error as Object, true)) { throw error as Error; }
    }
  }
  console.debug(`[sync] id=${id} phase=discover start`);
  const address = await new ComputerReceiverDiscovery(context).discover(config.receiverId);
  await verifyReceiver(context, config, address, id);
  await verifyConfiguration(store, config);
  return store.saveLastAddress(address);
  } finally { console.debug(`[sync] id=${id} phase=connect end ms=${Date.now()-started}`); }
}

export async function verifyConfiguration(store: ComputerTransferConfigStore, config: ComputerTransferConfig): Promise<void> {
  const current = await store.load();
  if (!current.isPaired() || current.receiverId !== config.receiverId || current.deviceId !== config.deviceId ||
    current.caFingerprint !== config.caFingerprint || current.caPath !== config.caPath || current.rpId !== config.rpId ||
    current.signingKeyAlias !== config.signingKeyAlias) {
    throw new ComputerConnectionError('identity', 'verify', '配对配置已变化，请重新连接');
  }
}

async function verifyReceiver(context: common.UIAbilityContext, config: ComputerTransferConfig,
  address: string, diagnosticId: string): Promise<void> {
  const status = await new ComputerTransferHttpClient(context, address, config.caPath, config.deviceId, diagnosticId, config.signingKeyAlias).status();
  if (status.receiver_id !== config.receiverId) {
    throw new ComputerConnectionError('identity', 'verify', '电脑接收端身份与已配对身份不一致');
  }
}
