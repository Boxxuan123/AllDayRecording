import { common } from '@kit.AbilityKit';
import { taskpool } from '@kit.ArkTS';
import { DeviceV3ReviewAudioResponse } from '../../computer/ComputerTransferProtocol';
import { PhoneV3ReviewAudioCachePort } from '../application/PhoneV3Ports';
import { reviewAudioFileTask } from './PhoneV3ReviewAudioWorker';

class AudioJob {
  id: string;
  namespace: string;
  key: string;
  prefetch: boolean;
  download: () => Promise<DeviceV3ReviewAudioResponse>;
  promise: Promise<DeviceV3ReviewAudioResponse>;
  resolve: (value: DeviceV3ReviewAudioResponse) => void = (): void => {};
  reject: (error: Error) => void = (): void => {};
  constructor(namespace: string, key: string, download: () => Promise<DeviceV3ReviewAudioResponse>, prefetch: boolean) {
    this.namespace = namespace; this.key = key; this.id = `${namespace}:${key}`;
    this.download = download; this.prefetch = prefetch;
    this.promise = new Promise<DeviceV3ReviewAudioResponse>((resolve, reject): void => { this.resolve = resolve; this.reject = reject; });
  }
}

export class PhoneV3ReviewAudioCache implements PhoneV3ReviewAudioCachePort {
  private root: string;
  private pins: Map<string, number> = new Map<string, number>();
  private jobs: Map<string, AudioJob> = new Map<string, AudioJob>();
  private queue: Array<AudioJob> = [];
  private running: boolean = false;
  private io: Promise<string> = Promise.resolve('');
  private initialized: boolean = false;
  private epoch: number = 0;
  private prefetchFailedUntil: number = 0;
  hits: number = 0;
  downloads: number = 0;
  joins: number = 0;
  constructor(context: common.UIAbilityContext, directory: string = 'review-audio-v1') {
    if (!/^[a-z0-9-]+$/.test(directory)) { throw new Error('invalid private cache directory'); }
    this.root = `${context.cacheDir}/${directory}`;
  }

  private file(action: string, namespace: string = '', key: string = '', response: string = '', encoded: string = ''): Promise<string> {
    const next = this.io.catch((): string => '').then(async (): Promise<string> => {
      if (!this.initialized) {
        await taskpool.execute(reviewAudioFileTask, this.root, 'initialize', '', '', '', '[]');
        this.initialized = true;
      }
      return await taskpool.execute(reviewAudioFileTask, this.root, action, namespace, key, response,
        JSON.stringify(Array.from(this.pins.keys())), encoded) as string;
    });
    this.io = next;
    return next;
  }

  async prepare(namespace: string, key: string, download: () => Promise<DeviceV3ReviewAudioResponse>, prefetch: boolean): Promise<DeviceV3ReviewAudioResponse> {
    if (!namespace || !/^[a-f0-9]{64}$/.test(key)) { throw new Error('尚无可信试听缓存描述'); }
    if (prefetch && this.prefetchFailedUntil > Date.now()) { throw new Error('预取暂缓'); }
    const epoch = this.epoch;
    const cached = await this.file('read', namespace, key);
    let response: DeviceV3ReviewAudioResponse;
    if (cached) { this.hits += 1; response = JSON.parse(cached) as DeviceV3ReviewAudioResponse; }
    else {
      const id = `${namespace}:${key}`;
      let job = this.jobs.get(id);
      if (job !== undefined) { job.prefetch = job.prefetch && prefetch; this.joins += 1; }
      else {
        if (this.jobs.size >= 4) { throw new Error('试听准备繁忙，请稍后重试'); }
        job = new AudioJob(namespace, key, download, prefetch);
        this.jobs.set(id, job); this.queue.push(job); this.drain();
      }
      response = await job.promise;
    }
    if (epoch !== this.epoch) { throw new Error('试听准备已取消'); }
    const copy = copyMetadata(response);
    if (!prefetch && copy.local_audio_path) {
      this.pins.set(copy.local_audio_path, (this.pins.get(copy.local_audio_path) ?? 0) + 1);
    }
    return copy;
  }

  private drain(): void {
    if (this.running || this.queue.length === 0) { return; }
    this.queue.sort((a: AudioJob, b: AudioJob): number => Number(a.prefetch) - Number(b.prefetch));
    const job = this.queue.shift() as AudioJob;
    const epoch = this.epoch;
    this.running = true;
    job.download().then(async (response: DeviceV3ReviewAudioResponse): Promise<void> => {
      if (epoch !== this.epoch) { throw new Error('试听准备已取消'); }
      this.downloads += 1;
      const metadata = copyMetadata(response);
      const result = await this.file('write', job.namespace, job.key, JSON.stringify(metadata), response.data_base64url);
      job.resolve(JSON.parse(result) as DeviceV3ReviewAudioResponse);
    }).catch((error: Error): void => {
      if (job.prefetch) { this.prefetchFailedUntil = Date.now() + 60000; }
      job.reject(error);
    }).finally((): void => { this.jobs.delete(job.id); this.running = false; this.drain(); });
  }

  release(path: string): void {
    const count = this.pins.get(path) ?? 0;
    if (count <= 1) { this.pins.delete(path); } else { this.pins.set(path, count - 1); }
  }
  hasLease(path: string): boolean { return (this.pins.get(path) ?? 0) > 0; }
  cancelPrefetch(): void {
    const pending = this.queue.filter((job: AudioJob): boolean => job.prefetch);
    this.queue = this.queue.filter((job: AudioJob): boolean => !job.prefetch);
    for (const job of pending) { this.jobs.delete(job.id); job.reject(new Error('预取已取消')); }
  }
  async clear(): Promise<void> {
    this.epoch += 1; this.cancelPrefetch();
    const pending = this.queue; this.queue = [];
    for (const job of pending) { this.jobs.delete(job.id); job.reject(new Error('试听缓存已清理')); }
    await this.file('clear');
  }
}

function copyMetadata(value: DeviceV3ReviewAudioResponse): DeviceV3ReviewAudioResponse {
  return { review_id: value.review_id, prototype_id: value.prototype_id, format: value.format,
    data_base64url: '', start_ms: value.start_ms, end_ms: value.end_ms,
    complete_sample: value.complete_sample, audition_key: value.audition_key, windows: value.windows,
    audio_content_key: value.audio_content_key, sha256: value.sha256, byte_length: value.byte_length,
    cache_hit: value.cache_hit, local_audio_path: value.local_audio_path, local_worker_tid: value.local_worker_tid };
}
