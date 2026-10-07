const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require(process.env.PHONE_TEST_TYPESCRIPT || 'typescript');

require.extensions['.ets'] = (module, file) => module._compile(ts.transpileModule(
  fs.readFileSync(file, 'utf8'), { compilerOptions: {
    target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
    experimentalDecorators: true
  } }).outputText, file);
global.Observed = value => value;
const native = { '@kit.AbilityKit': { common: {} }, common: {} };
const oldLoad = Module._load;
Module._load = function (name, ...args) {
  return native[name] || (name.startsWith('@kit.') || name.startsWith('@hms.') ? {} : null) ||
    oldLoad.call(this, name, ...args);
};

const VM = require(path.resolve('phone/src/main/ets/v3/presentation/PhoneV3ViewModel.ets')).PhoneV3ViewModel;
const tick = () => new Promise(resolve => setImmediate(resolve));
(async () => {
  const model = new VM();
  model.snapshot = { sessions: [{ sessionId: 'session-a', utterances: [] }] };
  const played = [], errors = [];
  model.playUtterance = row => played.push(row.utteranceId);
  model.fail = error => errors.push(error.message);
  model.useCases = { loadUtteranceById: async id => ({ utteranceId: id,
    sessionId: 'session-a', revision: 2, status: 'active' }) };
  model.playDailyEvidence({ session_id: 'session-a', utterance_id: 'source-a', revision: 2 });
  await tick();
  assert.deepEqual(played, ['source-a']);
  model.playDailyEvidence({ session_id: 'session-a', utterance_id: 'source-a', revision: 1 });
  await tick();
  assert.equal(played.length, 1);
  assert.match(errors.at(-1), /已更新/);
  model.playDailyEvidence({ session_id: 'missing', utterance_id: 'source-a', revision: 2 });
  assert.match(errors.at(-1), /会话/);
  console.log('PASS Daily evidence plays through ID query after pagination and rejects stale revisions');
})().catch(error => { console.error(error); process.exitCode = 1; });
