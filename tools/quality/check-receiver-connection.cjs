const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.env.PHONE_TEST_TYPESCRIPT || 'typescript');
const source = fs.readFileSync('phone/src/main/ets/computer/ComputerReceiverConnection.ets', 'utf8');
const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText;
let calls, responses, discovered;
const exportsObject = {};
const errors = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('phone/src/main/ets/computer/ComputerConnectionError.ets','utf8'),
  {compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText, {exports:errors, Error});
vm.runInNewContext(code, { exports: exportsObject, require: name => {
  if (name.endsWith('ComputerConnectionError')) return errors;
  if (name.endsWith('ComputerReceiverDiscovery')) return { ComputerReceiverDiscovery: class {
    async discover(id) { calls.push(['discover', id]); return discovered; }
  }};
  if (name.endsWith('ComputerTransferHttpClient')) return { ComputerTransferHttpClient: class {
    constructor(context, url, ca, device) { this.url = url; calls.push(['client', url, ca, device]); }
    async status() { const value = responses[this.url]; if (value instanceof Error) throw value; return value; }
  }};
  return {};
}});
const config = { baseUrl: 'saved', receiverId: 'receiver', caPath: 'pinned-ca', deviceId: 'device', isPaired: () => true };
const store = { load: async () => config, saveLastAddress: async url => { calls.push(['save', url]); return { ...config, baseUrl: url }; } };
(async () => {
  calls = []; responses = { saved: { receiver_id: 'receiver' } };
  assert.equal(await exportsObject.connectComputerReceiver({}, store), config);
  assert.deepEqual(calls, [['client', 'saved', 'pinned-ca', 'device']]);
  calls = []; discovered = 'new'; responses = { saved: new errors.ComputerConnectionError('unreachable','connect','offline'), new: { receiver_id: 'receiver' } };
  assert.equal((await exportsObject.connectComputerReceiver({}, store)).baseUrl, 'new');
  assert.deepEqual(calls.map(c => c[0]), ['client', 'discover', 'client', 'save']);
  calls = []; responses.new = { receiver_id: 'other' };
  await assert.rejects(exportsObject.connectComputerReceiver({}, store), /身份/);
  assert(!calls.some(c => c[0] === 'save'));
  for (const category of ['authorization','http','tls','response_timeout','identity','transport']) {
    calls = []; const failure = new errors.ComputerConnectionError(category,'response','synthetic'); responses.saved = failure;
    await assert.rejects(exportsObject.connectComputerReceiver({},store), e=>e===failure);
    assert.equal(calls.filter(c=>c[0]==='discover').length,0);
  }
  calls = []; responses.saved = new errors.ComputerConnectionError('unreachable','connect','offline'); responses.new = Error('certificate rejected');
  await assert.rejects(exportsObject.connectComputerReceiver({}, store), /certificate/);
  assert(!calls.some(c => c[0] === 'save'));
  console.log('PASS saved address, rediscovery, receiver identity and pinned TLS failure');
})().catch(error => { console.error(error); process.exitCode = 1; });
