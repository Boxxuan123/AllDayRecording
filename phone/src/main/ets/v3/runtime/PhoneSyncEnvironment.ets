import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { connection } from '@kit.NetworkKit';

// Owns exactly one native registration. A stopped registration cannot wake its successor.
export class PhoneSyncEnvironment {
  private net: connection.NetConnection | undefined = undefined;
  private closed: boolean = false;
  private context: common.UIAbilityContext;
  private preferencesName: string;
  private persistence: Promise<void> = Promise.resolve();
  constructor(context: common.UIAbilityContext, preferencesName: string = 'phone_foreground_sync') {
    this.context = context; this.preferencesName = preferencesName;
  }
  async paused(): Promise<boolean> {
    const store = await preferences.getPreferences(this.context, this.preferencesName);
    return await store.get('paused', false) === true;
  }
  async setPaused(value: boolean): Promise<void> {
    const write = this.persistence.catch((): void => {}).then(async (): Promise<void> => {
      const store = await preferences.getPreferences(this.context, this.preferencesName);
      await store.put('paused', value); await store.flush();
    });
    this.persistence = write;
    await write;
  }
  start(onAvailable: () => void): void {
    if (this.net !== undefined || this.closed) { return; }
    try {
      const net = connection.createNetConnection(); this.net = net;
      net.on('netAvailable', (): void => { if (!this.closed) { onAvailable(); } });
      net.register((error): void => { if (error) { console.warn('[sync] network listener unavailable'); } });
    } catch (_) { console.warn('[sync] network listener unavailable'); }
  }
  stop(): void {
    this.closed = true;
    const net = this.net; this.net = undefined;
    if (net !== undefined) { try { net.unregister((): void => {}); } catch (_) {} }
  }
  async wifi(): Promise<boolean> {
    try {
      const net = await connection.getDefaultNet();
      const caps = await connection.getNetCapabilities(net);
      return caps.bearerTypes.indexOf(connection.NetBearType.BEARER_WIFI) >= 0;
    } catch (_) { return false; }
  }
}
