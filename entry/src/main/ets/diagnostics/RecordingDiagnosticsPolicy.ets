// Diagnostic sources are retained for explicit experiments only. They are not imported by the production graph.
export const RECORDING_DIAGNOSTICS_ENABLED: boolean = false;

export function areRecordingDiagnosticsEnabled(): boolean {
  return RECORDING_DIAGNOSTICS_ENABLED;
}

export function requireRecordingDiagnosticsEnabled(): void {
  if (!RECORDING_DIAGNOSTICS_ENABLED) {
    throw new Error('录音诊断功能未启用');
  }
}
