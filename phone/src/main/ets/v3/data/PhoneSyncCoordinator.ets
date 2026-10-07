export interface PhoneSyncResult {
  batches: number;
  submitted_operations: number;
  final_cursor: string;
}

export function retryDelayMs(attemptCount: number): number {
  const normalized = Math.max(0, Math.min(10, Math.floor(attemptCount)));
  return Math.min(300000, 1000 * Math.pow(2, normalized));
}
