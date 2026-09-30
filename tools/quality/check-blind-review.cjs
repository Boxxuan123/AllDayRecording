// Real durable SQLite queue and projection; synthetic truth only.
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { Repository, UseCases, stores, root } = require('./phone-sqlite-harness.cjs');
const { phoneV3PendingReviews, phoneV3ReviewIsHistory, phoneV3VoiceCandidates } = require(path.join(root, 'domain/PhoneV3ReviewModels.ets'));
const { phoneV3ReviewItems } = require(path.join(root, 'data/PhoneV3ReviewProjection.ets'));
const time = '2026-01-01T00:00:00Z';
const task = { review_id: 'blind:synthetic', kind: 'blind_identity_review', priority: 'normal',
  source_id: 'synthetic', source_revision: null, session_id: null, person_id: null, title: 'Blind',
  summary: '', reason: 'blind_identity_review', evidence_count: 2, created_at: time, updated_at: time,
  context: { voice_mode: 'blind_identity_review', review_lane: 'primary', voice_candidates: [{
    prototype_id: 'synthetic', audio_available: true, representative_clips: [
      { media_id: 'synthetic', start_ms: 0, end_ms: 8000 }, { media_id: 'synthetic', start_ms: 12000, end_ms: 20000 }] }] } };
(async () => {
  const databasePath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'blind-review-')), 'synthetic.sqlite');
  let repo = await Repository.open({ databasePath });
  await repo.replaceReviewItems([task]);
  const remote = { isPaired: async () => false, connect: async () => { throw Error('offline'); } };
  let use = new UseCases(repo, { list: async () => [] }, remote);
  let items = phoneV3ReviewItems(await repo.projectionRows('review_item'));
  assert.equal(phoneV3PendingReviews(items, 1).length, 1);
  assert.equal(phoneV3VoiceCandidates(items[0])[0].totalMs, 16000);
  assert.equal(phoneV3VoiceCandidates(items[0])[0].bestScore, null);
  const request = { review_id: task.review_id, action: 'submit', primary_speaker_person_id: null,
    primary_speaker_unknown: true, unknown_kind: 'stranger', purity: 'mixed_overlap' };
  items = await use.queuePurityReview(request);
  assert.equal(phoneV3PendingReviews(items).length, 0);
  assert.equal(phoneV3ReviewIsHistory(items[0]), true);
  assert.equal(JSON.parse(items[0].contextJson).purity_review.unknown_kind, 'stranger');
  assert.equal((await repo.pendingPurityReviews()).length, 1);
  await use.flushPurityReviews().catch(() => {});
  stores.at(-1).db.close();
  repo = await Repository.open({ databasePath });
  use = new UseCases(repo, { list: async () => [] }, remote);
  const pending = await repo.pendingPurityReviews();
  assert.equal(pending[0].unknown_kind, 'stranger');
  assert.equal(pending[0].operation_id, request.operation_id);
  let writes = 0;
  remote.connect = async () => ({ resolveReview: async submitted => {
    writes++; assert.equal(submitted.operation_id, request.operation_id);
    return { result: {}, reviews: { items: [{ ...task, context: { ...task.context, review_lane: 'history' } }] } };
  } });
  await use.flushPurityReviews();
  assert.equal(writes, 1); assert.equal((await repo.pendingPurityReviews()).length, 0);
  remote.connect = async () => { throw Error('offline'); };
  items = await use.queuePurityReview({ review_id: task.review_id, action: 'undo' });
  assert.equal(phoneV3PendingReviews(items).length, 1);
  await use.flushPurityReviews().catch(() => {});
  for (const store of stores) { try { store.db.close(); } catch (_) {} }
  console.log('PASS Blind inbox, complete windows, no model hint, offline durable truth, restart/retry and undo');
})().catch(e => { console.error(e); process.exitCode = 1; });
