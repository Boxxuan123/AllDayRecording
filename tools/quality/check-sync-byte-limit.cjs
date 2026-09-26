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
  // Reconstruct a synthetic v8 store and exercise the actual upgrade to v11.
  stores.at(-1).db.exec('DROP TRIGGER outbox_selection_insert; DROP TRIGGER outbox_selection_delete; DROP TABLE outbox_selections');
  stores.at(-1).db.exec('ALTER TABLE outbox DROP COLUMN applied_revision; PRAGMA user_version=8');
  // Reconstruct after a real database close/reopen, before synchronization.
  stores.at(-1).db.close(); repo = await Repository.open({ databasePath });
  assert.equal(stores.at(-1).version,11);
  const session = { status: async () => ({ contract_version: contract.V3_CONTRACT_VERSION,
    projection_version: contract.V3_PROJECTION_VERSION }), sync, reviews: async () => ({ items: [] }),
    annotations: async () => ({ people: [] }) };
  return { repo, use: new UseCases(repo, { list: async () => [] }, { connect: async () => session }), databasePath };
}
(async () => {
  const { syncRequestBatch } = require('../../phone/src/main/ets/v3/data/PhoneSyncBatch.ets');
  const tiny=Array.from({length:501},(_,i)=>({operation_id:id(i),kind:'x',base_revision:null,payload:{}}));
  assert.equal(syncRequestBatch('cursor-0',tiny).client_operations.length,32);
  const seed={operation_id:id(999),kind:'x',base_revision:null,payload:{text:''}};
  const overhead=Buffer.byteLength(JSON.stringify(syncRequestBatch('cursor-123',[seed])));
  seed.payload.text='a'.repeat(65536-overhead);
  assert.equal(Buffer.byteLength(JSON.stringify(syncRequestBatch('cursor-123',[seed]))),65536);
  seed.payload.text+='a';
  assert.throws(()=>syncRequestBatch('cursor-123',[seed]),/单条同步操作/);
  assert.equal(seed.payload.text.length,65537-overhead);
  const sent = [];
  const c = await setup(60, async req => {
    const bytes = Buffer.byteLength(JSON.stringify(req), 'utf8');
    assert(bytes <= 65536, `HTTP body ${bytes} exceeds real server limit 65536`);
    sent.push(...req.client_operations);
    return response(req);
  });
  const original=[];
  for (let n=61; n<=180; n++) {
    const op={operation_id:id(n),kind:'segment.classify',base_revision:null,
      payload:{selections:[],sound_kind:'speech',note:'中文😀'.repeat(150)}};
    original.push(op); await c.repo.enqueue(op);
  }
  const result=await c.use.synchronize();
  assert.equal(result.completion,'complete'); assert.equal(sent.length,180);
  assert.equal(new Set(sent.map(o=>o.operation_id)).size,180);
  assert.deepEqual(sent.slice(60),original);
  assert.equal((await c.repo.v3Status()).pendingOperations,0);
  console.log('PASS byte-bounded UTF-8 batches drain real SQLite outbox with immutable IDs/payloads');
  for (const store of stores) { try {store.db.close();} catch {} }
})().catch(e=>{console.error(e);process.exitCode=1;});
