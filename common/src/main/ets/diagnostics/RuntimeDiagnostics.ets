import { pasteboard } from '@kit.BasicServicesKit';
import {
  BUILD_RELEASE_VERSION, BUILD_VERSION_CODE, BUILD_BUILD_VERSION,
  BUILD_GIT_COMMIT, BUILD_BUILT_AT, BUILD_DIRTY
} from './GeneratedBuildIdentity';

export interface RuntimeBuildInfo {
  component: string;
  release_version: string;
  git_commit: string;
  built_at: string | null;
  dirty: boolean | null;
  version_code?: number;
  build_version?: string;
  identity_source?: string;
}

export interface PeerBuildReport {
  build: RuntimeBuildInfo | undefined;
  last_seen: number;
  state: string;
}


export interface RuntimePeerReports {
  watch: PeerBuildReport;
  phone: PeerBuildReport;
  backend: PeerBuildReport;
}
export interface RuntimeProtocols {
  watch: number;
  transfer: number;
  contract: string;
}
export interface RuntimeDiagnosticPayload {
  local: RuntimeBuildInfo;
  peers: RuntimePeerReports;
  protocols: RuntimeProtocols;
}
export interface PhoneRuntimeReport {
  phone: RuntimeBuildInfo;
  watch: PeerBuildReport;
}

const peers: Map<string, PeerBuildReport> = new Map<string, PeerBuildReport>();

export function localBuildInfo(component: string): RuntimeBuildInfo {
  return { component: component, release_version: BUILD_RELEASE_VERSION,
    version_code: BUILD_VERSION_CODE, build_version: BUILD_BUILD_VERSION,
    git_commit: BUILD_GIT_COMMIT, built_at: BUILD_BUILT_AT, dirty: BUILD_DIRTY,
    identity_source: 'build' };
}

export function recordPeerBuild(peer: string, info: RuntimeBuildInfo | undefined): void {
  // Old peers are supported and must never acquire our version as a substitute.
  if (info === undefined || typeof info.release_version !== 'string' ||
    typeof info.git_commit !== 'string' || info.release_version.length > 64 ||
    info.git_commit.length > 64) {
    return;
  }
  peers.set(peer, { build: info, last_seen: Date.now(), state: 'reported' });
}

export function peerBuildReport(peer: string): PeerBuildReport {
  const value = peers.get(peer);
  if (value === undefined) {
    return { build: undefined, last_seen: 0, state: 'unknown' };
  }
  return { build: value.build, last_seen: value.last_seen,
    state: Date.now() - value.last_seen <= 120000 ? 'reported' : 'offline_or_stale' };
}

export function diagnosticText(component: string): string {
  const local = localBuildInfo(component);
  const payload: RuntimeDiagnosticPayload = { local: local, peers: {
    watch: peerBuildReport('watch'), phone: peerBuildReport('phone'),
    backend: peerBuildReport('pc-backend')
  }, protocols: { watch: 1, transfer: 2, contract: '3.8.0' } };
  return JSON.stringify(payload, undefined, 2);
}

export async function copyDiagnostics(component: string): Promise<void> {
  const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, diagnosticText(component));
  await pasteboard.getSystemPasteboard().setData(data);
}
