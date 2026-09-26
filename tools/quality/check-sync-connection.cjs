// Production HTTP boundary; only platform network I/O is replaced.
const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path'), Module = require('node:module');
const ts = require(process.env.PHONE_TEST_TYPESCRIPT || 'typescript');
require.extensions['.ets'] = (m, f) => m._compile(ts.transpileModule(fs.readFileSync(f, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }
}).outputText, f);
let response, destroyed = 0;
const native = { '@kit.NetworkKit': { http: { HttpDataType: { STRING: 0 }, RequestMethod: {GET:'GET',POST:'POST',PUT:'PUT'},
  createHttp: () => ({ request: async () => { if (response instanceof Error || response.code) throw response; return response; }, destroy: () => destroyed++ })
} } };
const oldLoad = Module._load;
Module._load = function(name, ...args) { return native[name] || (name.startsWith('@kit.') || name.startsWith('@hms.') ? {} : oldLoad.call(this, name, ...args)); };
const root = path.resolve('phone/src/main/ets/computer');
const { mayRediscover } = require(path.join(root, 'ComputerConnectionError.ets'));
const { ComputerTransferHttpClient: Client } = require(path.join(root, 'ComputerTransferHttpClient.ets'));
const client = Object.create(Client.prototype); client.baseUrl = 'https://synthetic'; client.caPath = 'synthetic';
(async () => {
  for (const status of [400,401,403,500]) {
    response = { responseCode: status, result: JSON.stringify({code:'SYNTHETIC',message:'Safe failure',request_id:'diag'}) };
    await assert.rejects(client.requestJson('GET','/device/v3/status',undefined,{}), e => {
      assert.equal(e.statusCode,status); assert.equal(e.serverCode,'SYNTHETIC'); assert.equal(e.path,'/device/v3/status');
      assert.equal(e.category, [401,403].includes(status)?'authorization':'http'); assert.equal(mayRediscover(e),false); return true;
    });
  }
  for (const [code,category] of [[2300007,'unreachable'],[2300006,'unreachable'],[2300060,'tls'],[2300077,'tls'],[2300028,'response_timeout']]) {
    response = {code, message:'PRIVATE CONTENT MUST NOT BE DISPLAYED'};
    await assert.rejects(client.requestJson('POST','/device/v3/reviews/action','{}',{}), e => {
      assert.equal(e.category,category); assert.equal(e.nativeCode,code); assert.equal(e.original,response);
      assert.equal(mayRediscover(e),category==='unreachable'); assert.equal(e.mayHaveSent,category==='response_timeout');
      assert(!e.message.includes('PRIVATE')); return true;
    });
  }
  assert.equal(destroyed,9);
  console.log('PASS HTTP 400/401/403/500; 5 native failures; original codes/causes; dispatch uncertainty; all request resources destroyed');
})().catch(e => { console.error(e); process.exitCode = 1; });
