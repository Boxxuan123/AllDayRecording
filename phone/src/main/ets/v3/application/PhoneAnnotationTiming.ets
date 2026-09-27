import { systemDateTime } from '@kit.BasicServicesKit';

// Device-local monotonic milliseconds; never compare with a computer wall clock.
export function annotationTiming(phase: string, ids: Array<string>): void {
  if (ids.length === 0) { return; }
  try {
  const tick = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
  console.debug(`[annotation] phase=${phase} tick_ms=${tick} count=${ids.length} ops=${ids.slice(0, 32).join(',')}`);
  } catch (_) { /* Optional diagnostics cannot change a committed annotation. */ }
}
