const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Repository, UseCases, contract, stores } = require('./phone-sqlite-harness.cjs');
const id = n => String(n).padStart(26, '0');
const response = (request, more = false, cursor = 'cursor-0') => ({
  projection_version: contract.V3_PROJECTION_VERSION, next_cursor: cursor, has_more: more,
  server_time: '2026-09-24T00:00:00Z', changes: [], receipts: request.client_operations.map(op => ({
    operation_id: op.operation_id, status: 'applied', resource_revision: 2, error: null })) });
async function setup(count, sync) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'annotation-phone-'));
  const databasePath = path.join(dir, 'synthetic.sqlite');
  let repo = await Repository.open({ databasePath });
  for (let n = 1; n <= count; n++) await repo.enqueue({ operation_id: id(n), kind: 'segment.classify',
    base_revision: null, payload: { selections: [], sound_kind: 'speech' } });
  // Reconstruct a synthetic v8 store and exercise the actual v8 -> v9 upgrade.
  stores.at(-1).db.exec('ALTER TABLE outbox DROP COLUMN applied_revision; PRAGMA user_version=8');
  // Reconstruct after a real database close/reopen, before synchronization.
  stores.at(-1).db.close(); repo = await Repository.open({ databasePath });
  assert.equal(stores.at(-1).version,10);
  const session = { status: async () => ({ contract_version: contract.V3_CONTRACT_VERSION,
    projection_version: contract.V3_PROJECTION_VERSION }), sync, reviews: async () => ({ items: [] }),
    annotations: async () => ({ people: [] }) };
  return { repo, use: new UseCases(repo, { list: async () => [] }, { connect: async () => session }), databasePath };
}
(async () => {
  const batches = [];
  let c = await setup(1001, async req => { assert(Buffer.byteLength(JSON.stringify(req),'utf8') <= 65536); batches.push(req.client_operations.length); return response(req); });
  let result = await c.use.synchronize();
  assert.deepEqual(batches, [...Array(31).fill(32), 9]); assert.equal(result.completion, 'complete');
  assert.equal((await c.repo.v3Status()).pendingOperations, 0);
  console.log('PASS 1001 persisted/restarted operations: at most 32 operations and 64 KB, no payload rewriting');

  const sent = []; let first = true;
  c = await setup(502, async req => {
    sent.push(req.client_operations.map(op => op.operation_id)); const res = response(req);
    if (first) { first = false; res.receipts[0] = { operation_id: id(1), status: 'conflict',
      resource_revision: null, error: { code: 'REVISION_CONFLICT', message: 'synthetic' } }; }
    return res;
  });
  await c.repo.enqueue({ operation_id: id(503), kind: 'speaker.assign', base_revision: null,
    payload: { selections: [], depends_on: [id(1)] } });
  await c.repo.enqueue({ operation_id: id(504), kind: 'speaker.assign', base_revision: null,
    payload: { selections: [], depends_on: [id(501)] } });
  result = await c.use.synchronize();
  assert(sent.flat().includes(id(504))); assert(!sent.flat().includes(id(503)));
  assert.equal(result.remainingOperations, 2); assert.equal(result.completion, 'waiting');
  console.log('PASS conflict branch isolated; cross-batch dependency ordered');

  let page = 0;
  c = await setup(0, async req => response(req, ++page < 3, `cursor-${page}`));
  assert.equal((await c.use.synchronize()).batches, 3);
  c = await setup(0, async req => response(req, true));
  assert.equal((await c.use.synchronize()).completion, 'no_progress');
  let fail = true, payloads = [];
  c = await setup(1, async req => { payloads.push(JSON.stringify(req.client_operations));
    if (fail) { fail = false; throw Error('server committed, receipt lost'); } return response(req); });
  await assert.rejects(c.use.synchronize()); await c.use.synchronize();
  assert.equal(payloads[0], payloads[1]);
  console.log('PASS pull-only multiple pages; no-progress bound; disconnected immutable retry');
  c = await setup(1001, async req => { c.use.cancelSynchronize(); return response(req); });
  result = await c.use.synchronize(); assert.equal(result.completion, 'cancelled'); assert.equal(result.remainingOperations, 969);
  let release;
  c = await setup(0, async req => { await new Promise(resolve => release = resolve); return response(req); });
  const running = c.use.synchronize();
  while (!release) await new Promise(resolve => setImmediate(resolve));
  await assert.rejects(c.use.synchronize(), /同步正在进行/); release(); await running;
  console.log('PASS cancellation and concurrent synchronization lock');
  for (const store of stores) { try { store.db.close(); } catch {} }
})().catch(error => { console.error(error); process.exitCode = 1; });
