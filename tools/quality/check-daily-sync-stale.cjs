// Actual Phone repository SQL, projection decoder and persistent cursor.
// The input comes from the real ASR composition/correction/coordinator/sync.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { Repository, stores, apply, root } = require('./phone-sqlite-harness.cjs');
const { PhoneV3ProjectionQueries } = require(path.join(root, 'application/PhoneV3ProjectionQueries.ets'));
const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

(async () => {
  const file = process.argv[3];
  let repo = await Repository.open({ databasePath: file });
  const summary = async () => (await new PhoneV3ProjectionQueries(repo).loadDailyCache()).summaries
    .find(value => value.summary_id === input.summary_id);
  await apply(repo, input.responses[0]);
  assert.equal((await summary()).derivation_status, 'active');
  await apply(repo, input.responses[1]);
  const stale = await summary();
  assert.equal(stale.derivation_status, 'stale');
  assert.equal(stale.revision, input.revision);
  assert.deepEqual(stale.objective, input.objective);
  const cursor = await repo.currentCursor();
  await apply(repo, input.responses[1]);
  await apply(repo, input.responses[0]);
  assert.equal((await summary()).derivation_status, 'stale');
  assert.equal(await repo.currentCursor(), cursor);
  stores.at(-1).db.close();
  repo = await Repository.open({ databasePath: file });
  await apply(repo, input.responses[0]);
  assert.equal((await summary()).derivation_status, 'stale');
  assert.equal(await repo.currentCursor(), cursor);
  // Rebuild resets cursor and projection atomically; post-invalidation snapshot
  // directly loads stale, without changing content revision or local evidence.
  await repo.rebuildFromComputer();
  assert.equal(await repo.currentCursor(), 'cursor-0');
  await apply(repo, input.bootstrap);
  assert.equal((await summary()).derivation_status, 'stale');
  // A failed state update cannot advance the persistent cursor or mutate rows.
  const store = stores.at(-1), original = store.executeSql.bind(store);
  store.executeSql = async (sql, args) => {
    if (sql.startsWith('UPDATE sync_state SET cursor =')) throw Error('synthetic cursor fault');
    return original(sql, args);
  };
  const nextSequence = Number(cursor.slice(7)) + 1;
  const summaryChange = input.responses[1].changes.find(change => change.resource_type === 'daily_summary');
  const failing = { ...input.responses[1], changes: [{ ...summaryChange, sequence: nextSequence,
    resource: { ...summaryChange.resource, derivation_status: 'active' } }], next_cursor: `cursor-${nextSequence}` };
  await assert.rejects(apply(repo, failing), /synthetic cursor fault/);
  store.executeSql = original;
  assert.equal((await summary()).derivation_status, 'stale');
  assert.equal(await repo.currentCursor(), input.bootstrap.next_cursor);
  assert.equal(store.version, 19);
  store.db.close();
  console.log('PASS real ASR sync -> actual Phone SQL/query: same revision stale, duplicate/old replay, restart, rebuild, rollback; schemas unchanged. HOST_NOT_DEVICE');
})().catch(error => { console.error(error); process.exitCode = 1; });
