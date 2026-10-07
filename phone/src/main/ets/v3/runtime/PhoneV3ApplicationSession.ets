import { common } from '@kit.AbilityKit';
import { ComputerUploadProgress } from '../../computer/ComputerRecordingUploadService';
import { CalendarReminderScheduler } from '../application/CalendarReminderScheduler';
import { PhoneSyncService } from '../application/PhoneSyncService';
import { PhoneV3UseCases } from '../application/PhoneV3UseCases';
import { CalendarReminderBackend } from '../data/CalendarReminderBackend';
import { PhoneV3ComputerBackup } from '../data/PhoneV3ComputerBackup';
import { PhoneV3DeviceRemote } from '../data/PhoneV3DeviceRemote';
import { PhoneV3LocalAudioRepository } from '../data/PhoneV3LocalAudioRepository';
import { PhoneV3ReviewAudioCache } from '../data/PhoneV3ReviewAudioCache';
import { PhoneV3ReviewAudioPlayer } from '../data/PhoneV3ReviewAudioPlayer';
import { PhoneV3LocalAudioFact } from '../domain/PhoneV3Models';

export interface PhoneV3ApplicationBindings {
  syncService: PhoneSyncService;
  calendarScheduler: CalendarReminderScheduler;
  useCases: PhoneV3UseCases;
}

/** Composition root for the home session's storage, remote and playback adapters. */
export class PhoneV3ApplicationSession {
  private context: common.UIAbilityContext;
  private local: PhoneV3LocalAudioRepository;
  private audioCache: PhoneV3ReviewAudioCache;
  private purityAudioCache: PhoneV3ReviewAudioCache;
  reviewAudioPlayer: PhoneV3ReviewAudioPlayer;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.local = new PhoneV3LocalAudioRepository(context.filesDir);
    this.audioCache = new PhoneV3ReviewAudioCache(context);
    this.purityAudioCache = new PhoneV3ReviewAudioCache(context, 'purity-audio-v1');
    this.reviewAudioPlayer = new PhoneV3ReviewAudioPlayer(context, this.audioCache, this.purityAudioCache);
  }

  listLocal(): Promise<Array<PhoneV3LocalAudioFact>> { return this.local.list(); }

  async connect(progress: (value: ComputerUploadProgress) => void): Promise<PhoneV3ApplicationBindings> {
    const syncService = await PhoneSyncService.shared(this.context);
    const repository = syncService.projection();
    const calendarScheduler = new CalendarReminderScheduler(new CalendarReminderBackend(this.context), repository);
    const useCases = new PhoneV3UseCases(repository, this.local, new PhoneV3DeviceRemote(this.context),
      calendarScheduler, new PhoneV3ComputerBackup(this.context, repository, progress),
      this.audioCache, this.purityAudioCache);
    return { syncService: syncService, calendarScheduler: calendarScheduler, useCases: useCases };
  }
}
