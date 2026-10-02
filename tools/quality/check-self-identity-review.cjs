// Synthetic identity reviews through real phone SQLite, queue and audio validators.
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { Repository, UseCases, root, stores } = require('./phone-sqlite-harness.cjs');
const { phoneV3ReviewSnapshotItems } = require(path.join(root, 'data/PhoneV3ReviewProjection.ets'));
const { phoneV3PendingReviews, phoneV3VoiceCandidates } = require(path.join(root, 'domain/PhoneV3ReviewModels.ets'));
const { selfReviewDetail } = require(path.join(root, 'domain/PhoneV3SelfReview.ets'));
const { validateReviewSample } = require(path.join(root, 'domain/PhoneV3ReviewAudioValidation.ets'));
const dto = n => ({ review_id: `self:${n}`, kind: 'self_identity_review', priority: 'normal',
  source_id: String(n), source_revision: 1, session_id: 'synthetic', person_id: null,
  title: '可能是本人', summary: '本人匹配较高，但有效语音不足自动确认要求', reason: 'self_identity_review',
  evidence_count: 1, created_at: '2026-10-02T00:00:00Z', updated_at: '2026-10-02T00:00:00Z',
  context: { voice_mode: 'self_identity_review', review_lane: 'primary', source_text: 'Synthetic audio only',
    start_at: '2026-10-02T00:00:00Z', duration_ms: 2500, profile_learning: false,
    voice_candidates: [{prototype_id: String(n), session_id: 'synthetic', audio_available: true,
      audition_key: 'audition', audio_content_key: 'content', representative_clips: [{media_id:'m',start_ms:0,end_ms:2500}]}] }});
(async () => {
  const items = phoneV3ReviewSnapshotItems([dto(1), dto(2), dto(3)]);
  assert.equal(items.length, 3); assert.equal(phoneV3PendingReviews(items, 1).length, 3);
  assert.equal(selfReviewDetail(items[0]).duration, '2.5 秒');
  const candidate = phoneV3VoiceCandidates(items[0])[0];
  const audio = {complete_sample:true, review_id:'self:1', prototype_id:'1', audition_key:'audition',
    audio_content_key:'content',start_ms:0,end_ms:2500,windows:[{media_id:'m',start_ms:0,end_ms:2500,playback_start_ms:0}]};
  validateReviewSample(audio,'self:1',candidate);
  assert.throws(() => validateReviewSample({...audio,end_ms:2000},'self:1',candidate));
  assert.throws(() => validateReviewSample({...audio,audio_content_key:'stale'},'self:1',candidate));
  const databasePath = path.join(fs.mkdtempSync(path.join(os.tmpdir(),'self-review-')), 'test.sqlite');
  let repo = await Repository.open({databasePath});
  const remote = {isPaired:async()=>false,connect:async()=>{throw Error('offline');}};
  let use = new UseCases(repo,{list:async()=>[]},remote);
  await repo.replaceReviewItems([dto(1),dto(2),dto(3)]);
  for (const [n,action] of [[1,'confirm'],[2,'reject'],[3,'uncertain']]) {
    await use.queueVoiceReview({review_id:`self:${n}`,prototype_id:String(n),action});
  }
  await assert.rejects(use.flushVoiceReviews(), /offline/);
  const queued = await repo.pendingVoiceReviews(); assert.equal(queued.length,3);
  stores.at(-1).db.close(); repo = await Repository.open({databasePath});
  use = new UseCases(repo,{list:async()=>[]},remote);
  assert.deepEqual((await repo.pendingVoiceReviews()).map(r=>r.operation_id),queued.map(r=>r.operation_id));
  const ledger = new Map(); let mutations = 0;
  remote.connect = async()=>({resolveReview:async request=>{
    if (!ledger.has(request.operation_id)) { ledger.set(request.operation_id,request.action); mutations++; }
    return {result:{profile_learning:false},reviews:{items:[dto(1),dto(2),dto(3)].map(i=>({...i,context:{...i.context,review_lane:'history'}}))}};
  }});
  const replace = repo.replaceReviewItems.bind(repo); repo.replaceReviewItems=async()=>{throw Error('disk full');};
  await assert.rejects(use.flushVoiceReviews(), /disk full/);
  repo.replaceReviewItems=replace; await use.flushVoiceReviews();
  assert.equal(mutations,3); assert.equal((await repo.pendingVoiceReviews()).length,0);
  assert.equal(phoneV3PendingReviews(phoneV3ReviewSnapshotItems([dto(1),dto(2),dto(3)].map(i=>({...i,context:{...i.context,review_lane:'history'}})))).length,0);
  await use.flushVoiceReviews(); assert.equal(mutations,3);
  for (const store of stores) { try {store.db.close();} catch (_) {} }
  console.log('PASS self-review sync/filter/display, complete audio/stale audio, three actions, offline restart, committed-cache replay, terminal suppression');
})().catch(error=>{console.error(error);process.exitCode=1;});
