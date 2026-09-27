export class PhoneV3ReviewAudioRetry extends Error {
  retryAt: number;
  constructor(retryAt: number) { super('试听预取暂缓'); this.retryAt = retryAt; }
}
