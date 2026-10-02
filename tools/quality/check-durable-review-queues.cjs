// Synthetic requests through the production use cases and real on-disk SQLite.
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { Repository, UseCases, stores } = require('./phone-sqlite-harness.cjs');

(async () => {
  const databasePath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'review-queues-')), 'synthetic.sqlite');
  let repo = await Repository.open({ databasePath });
  const remote = { isPaired: async () => false, connect: async () => { throw Error('offline'); } };
  let use = new UseCases(repo, { list: async () => [] }, remote);
  const first = { review_id: 'voice:a', prototype_id: 'sample-a', action: 'confirm', expected_review_key: 'a' };
  const second = { review_id: 'voice:b', prototype_id: 'sample-b', action: 'uncertain' };
  await use.queueVoiceReview(first);
  await use.queueVoiceReview(second);
  await assert.rejects(use.flushVoiceReviews(), /offline/);
  stores.at(-1).db.close();
  repo = await Repository.open({ databasePath });
  use = new UseCases(repo, { list: async () => [] }, remote);
  assert.equal((await repo.pendingVoiceReviews())[0].operation_id, first.operation_id);
  const delivered = [];
  remote.connect = async () => ({ resolveReview: async request => {
    delivered.push(request.operation_id);
    if (request.prototype_id === 'sample-a') { throw Error('stale sample'); }
    return { result: {}, reviews: { items: [] } };
  } });
  const active = use.flushVoiceReviews();
  assert.equal(use.flushVoiceReviews(), active);
  await assert.rejects(active, /stale sample/);
  assert.deepEqual(delivered, [first.operation_id, second.operation_id]);
  assert.deepEqual((await repo.pendingVoiceReviews()).map(r => r.operation_id), [first.operation_id]);

  // A committed remote response followed by a local write failure must retry
  // the original operation, never create a second authorization.
  const committed = new Set(); let mutations = 0;
  remote.connect = async () => ({ resolveReview: async request => {
    if (!committed.has(request.operation_id)) { committed.add(request.operation_id); mutations++; }
    return { result: {}, reviews: { items: [] } };
  } });
  const replace = repo.replaceReviewItems.bind(repo);
  repo.replaceReviewItems = async () => { throw Error('disk full'); };
  await assert.rejects(use.flushVoiceReviews(), /disk full/);
  assert.equal((await repo.pendingVoiceReviews())[0].operation_id, first.operation_id);
  repo.replaceReviewItems = replace;
  await use.flushVoiceReviews();
  assert.equal(mutations, 1);
  assert.equal((await repo.pendingVoiceReviews()).length, 0);

  const submit = { review_id: 'blind:a', action: 'submit', review_schema_version: 2,
    primary_speaker_unknown: true, unknown_kind: 'stranger', speaker_composition: 'clean_single', boundary_quality: 'clean' };
  const undo = { review_id: 'blind:a', action: 'undo' };
  const unrelated = { ...submit, review_id: 'blind:b' };
  remote.connect = async () => { throw Error('offline'); };
  await use.queuePurityReview(submit);
  await use.queuePurityReview(undo);
  await use.queuePurityReview(unrelated);
  await use.flushPurityReviews().catch(() => {});
  const actions = [];
  remote.connect = async () => ({ resolveReview: async request => {
    actions.push(`${request.review_id}:${request.action}`);
    if (request.review_id === 'blind:a') { throw Error('timeout'); }
    return { result: {}, reviews: { items: [] } };
  } });
  await assert.rejects(use.flushPurityReviews(), /timeout/);
  assert.deepEqual(actions, ['blind:a:submit', 'blind:b:submit']);
  assert.deepEqual((await repo.pendingPurityReviews()).map(r => r.operation_id), [submit.operation_id, undo.operation_id]);
  stores.at(-1).db.close();
  repo = await Repository.open({ databasePath });
  use = new UseCases(repo, { list: async () => [] }, remote);
  actions.length = 0;
  remote.connect = async () => ({ resolveReview: async request => {
    actions.push(`${request.review_id}:${request.action}`);
    return { result: {}, reviews: { items: [] } };
  } });
  await use.flushPurityReviews();
  assert.deepEqual(actions, ['blind:a:submit', 'blind:a:undo']);
  assert.equal((await repo.pendingPurityReviews()).length, 0);

  // Simulate an existing V16 database; migration preserves its queued truth.
  remote.connect = async () => { throw Error('offline'); };
  await use.queuePurityReview({ ...submit });
  await use.flushPurityReviews().catch(() => {});
  const before = (await repo.pendingPurityReviews())[0];
  const db = stores.at(-1).db;
  db.exec('DROP TABLE pending_voice_reviews; PRAGMA user_version=16');
  db.close();
  repo = await Repository.open({ databasePath });
  assert.equal(stores.at(-1).version, 18);
  assert.equal((await repo.pendingPurityReviews())[0].operation_id, before.operation_id);
  assert.equal((await repo.pendingVoiceReviews()).length, 0);
  for (const store of stores) { try { store.db.close(); } catch (_) {} }
  console.log('PASS durable voice retry/restart, isolated failures, response/cache failure replay, ordered truth/undo, V16 migration');
})().catch(error => { console.error(error); process.exitCode = 1; });
