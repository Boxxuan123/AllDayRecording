import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { mdns } from '@kit.NetworkKit';
import {
  COMPUTER_RECEIVER_PROTOCOL,
  COMPUTER_RECEIVER_SERVICE_TYPE,
  COMPUTER_RECEIVER_VERSION,
  normalizeComputerBaseUrl,
  normalizeReceiverId
} from './ComputerTransferProtocol';

const DISCOVERY_TIMEOUT_MS: number = 12000;

export class ComputerReceiverDiscovery {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  discover(receiverId: string): Promise<string> {
    const expectedReceiverId = normalizeReceiverId(receiverId);
    return new Promise<string>((resolve: (value: string) => void, reject: (error: Error) => void) => {
      if (!canIUse('SystemCapability.Communication.NetManager.MDNS')) {
        reject(new Error('本机系统不支持局域网自动发现'));
        return;
      }
      const discovery = mdns.createDiscoveryService(this.context, COMPUTER_RECEIVER_SERVICE_TYPE);
      let settled = false;
      let timeoutId = -1;

      const cleanup = (): void => {
        if (timeoutId >= 0) {
          clearTimeout(timeoutId);
        }
        try {
          discovery.off('serviceFound', foundCallback);
          discovery.stopSearchingMDNS();
        } catch (error) {
        }
      };

      const foundCallback = (serviceInfo: mdns.LocalServiceInfo): void => {
        if (settled) {
          return;
        }
        mdns.resolveLocalService(this.context, serviceInfo).then((resolved: mdns.LocalServiceInfo): void => {
          if (settled || !matchesReceiver(resolved, expectedReceiverId) ||
            resolved.host === undefined || resolved.port === undefined || resolved.port <= 0) {
            return;
          }
          settled = true;
          cleanup();
          resolve(receiverBaseUrl(resolved.host.address, resolved.port));
        }).catch((): void => {
        });
      };

      discovery.on('serviceFound', foundCallback);
      timeoutId = setTimeout((): void => {
        if (settled) {
          return;
        }
        settled = true;
        cleanup();
        reject(new Error('12 秒内未发现已配对电脑；请确认电脑接收服务已启动且两端连接同一 Wi-Fi'));
      }, DISCOVERY_TIMEOUT_MS);
      try {
        discovery.startSearchingMDNS();
      } catch (error) {
        settled = true;
        cleanup();
        const value = error as Error;
        reject(new Error(`启动电脑自动发现失败：${value.message}`));
      }
    });
  }
}

export function receiverBaseUrl(address: string, port: number): string {
  const host = address.includes(':') ? `[${address}]` : address;
  return normalizeComputerBaseUrl(`https://${host}:${port}`);
}

function matchesReceiver(service: mdns.LocalServiceInfo, receiverId: string): boolean {
  return serviceAttribute(service, 'protocol') === COMPUTER_RECEIVER_PROTOCOL &&
    serviceAttribute(service, 'version') === COMPUTER_RECEIVER_VERSION.toString() &&
    serviceAttribute(service, 'receiver_id') === receiverId &&
    serviceAttribute(service, 'transport') === 'tls';
}

function serviceAttribute(service: mdns.LocalServiceInfo, key: string): string {
  const attributes = service.serviceAttribute ?? [];
  for (let index = 0; index < attributes.length; index += 1) {
    if (attributes[index].key === key) {
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(attributes[index].value));
    }
  }
  return '';
}
