const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), Module = require('node:module');
const ts = require(process.env.PHONE_TEST_TYPESCRIPT || 'typescript');
let clock = 1000000;
const realNow = Date.now; Date.now = () => clock;
let copied;
const kit = {
  '@kit.BasicServicesKit': { pasteboard: { MIMETYPE_TEXT_PLAIN: 'text/plain',
    createData: (type, text) => text, getSystemPasteboard: () => ({ setData: async value => { copied = value; } }) } },
  '@kit.ArkTS': { util: { TextEncoder: { create: () => ({ encodeInto: x => Buffer.from(x) }) },
    TextDecoder: { create: () => ({ decodeToString: x => Buffer.from(x).toString() }) } } }
};
require.extensions['.ets'] = (module, file) => module._compile(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }
}).outputText, file);
const oldLoad = Module._load;
Module._load = function(name, ...args) {
  return kit[name] || (name.startsWith('@kit.') ? {} : oldLoad.call(this, name, ...args));
};
const root = path.resolve('common/src/main/ets');
const diagnostics = require(path.join(root, 'diagnostics/RuntimeDiagnostics.ets'));
const protocol = require(path.join(root, 'sync/protocol/WatchFileSyncProtocol.ets'));
(async () => {
  assert.equal(diagnostics.peerBuildReport('watch').state, 'unknown');
  const foreign = {component:'watch',release_version:'0.9.8',git_commit:'f'.repeat(40),built_at:'2026-09-01',dirty:false};
  const message = protocol.decodeWatchSyncMessage(protocol.encodeWatchSyncMessage({
    version: 1, type:'control_ready', requestId:'synthetic',runtime_build:foreign
  }));
  diagnostics.recordPeerBuild('watch', message.runtime_build);
  assert.equal(diagnostics.peerBuildReport('watch').build.release_version,'0.9.8');
  assert.notEqual(diagnostics.localBuildInfo('phone').release_version,'0.9.8');
  // Old peers without diagnostic metadata still decode and do not become local builds.
  const old = protocol.decodeWatchSyncMessage(protocol.encodeWatchSyncMessage({
    version:1,type:'control_ready',requestId:'old'
  }));
  diagnostics.recordPeerBuild('old-watch', old.runtime_build);
  assert.equal(diagnostics.peerBuildReport('old-watch').state,'unknown');
  clock += 120001;
  assert.equal(diagnostics.peerBuildReport('watch').state,'offline_or_stale');
  await diagnostics.copyDiagnostics('phone');
  assert.equal(JSON.parse(copied).peers.watch.build.git_commit, foreign.git_commit);
  assert.equal(JSON.parse(copied).peers.watch.state,'offline_or_stale');
  Date.now = realNow;
  console.log('PASS actual protocol v1 old/new peers, unequal releases, unknown/stale state, copy payload');
})().catch(error => { Date.now = realNow; console.error(error); process.exitCode=1; });
