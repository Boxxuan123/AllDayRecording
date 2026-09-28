export function isRecordingCompletionSourcePath(path: string): boolean {
  return /^pcm_(session|gap_test)_[0-9]{13,}\/session_summary\.json$/.test(path);
}
