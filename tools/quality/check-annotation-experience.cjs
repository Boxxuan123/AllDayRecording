// Production repository, use cases, projection and selectors on a real disk DB.
// Only HarmonyOS native RdbStore is adapted to node:sqlite by the shared harness.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Repository, UseCases, stores, apply, contract, root } = require('./phone-sqlite-harness.cjs');
const { phoneV3AnnotationState: state } = require(path.join(root, 'domain/PhoneV3AnnotationState.ets'));
const { PhoneV3AnnotationEditor: Editor } = require(path.join(root, 'domain/PhoneV3AnnotationEditor.ets'));
const id = n => String(n).padStart(26, '0');
const time = '2026-09-25T00:00:00Z';
const dto = (n, revision = 1, evidence = {}) => ({
  utterance_id: id(n), session_id: id(9000), speaker_track_id: null, speaker_label: '系统预测',
  original_speaker_track_id: null, original_speaker_label: null, identity: 'unknown', original_identity: 'unknown',
  identity_evidence: {}, start_ms: n * 1000, end_ms: n * 1000 + 900, start_at: time, end_at: '2026-09-25T00:00:01Z',
  text: `测试片段 ${n}`, original_text: `测试片段 ${n}`, revision, status: 'active', evidence
});
let sequence = 0;
const change = row => ({ sequence: ++sequence, resource_type: 'utterance', resource_id: row.utterance_id,
  revision: row.revision, operation: 'upsert', resource: row });
const response = (changes = [], receipts = []) => ({ projection_version: contract.V3_PROJECTION_VERSION,
  changes, receipts, next_cursor: `cursor-${sequence}`, has_more: false, server_time: time });

(async () => {
  const databasePath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'annotation-experience-')), 'synthetic.sqlite');
  let repo = await Repository.open({ databasePath });
  let connects = 0;
  const remote = { isPaired: async () => false, connect: async () => { connects++; throw Error('offline'); } };
  let use = new UseCases(repo, { list: async () => [] }, remote);
  const read = async () => (await use.loadCached([])).sessions[0].utterances;
  await apply(repo, response([{ sequence: ++sequence, resource_type: 'recording_session', resource_id: id(9000),
    revision: 1, operation: 'upsert', resource: { session_id: id(9000), session_key: 'synthetic', captured_start: time } },
    change(dto(1)), change(dto(2))]));
  let rows = await read();
  assert.equal(state(rows[0]).done, false);
  await use.queueAnnotation([rows[0]], '', '合成人物甲', true, 'unintelligible');
  assert.equal(connects, 0);
  let ops = await repo.annotationOperations();
  assert.equal(ops.length, 2);
  assert.deepEqual(ops.map(o => o.kind), ['speaker.assign', 'segment.classify']);
  rows = await read();
  assert.equal(state(rows[0]).done, true);
  assert.equal(rows[0].soundKind, 'unintelligible');
  assert.equal(rows[0].speakerLabel, '合成人物甲');
  stores.at(-1).db.close();
  repo = await Repository.open({ databasePath });
  use = new UseCases(repo, { list: async () => [] }, remote);
  rows = await read();
  assert.equal(state(rows[0]).sync, '已在手机保存·待同步到电脑');
  await repo.markSyncFailure('offline');
  assert.match(state((await read())[0]).sync, /同步失败/);
  await apply(repo, response([], ops.map((op, i) => ({ operation_id: op.operation_id, status: 'applied',
    resource_revision: i + 2, resource_results: [{ resource_id: id(1), revision: i + 2 }], error: null }))));
  assert.equal(state((await read())[0]).sync, '电脑已接收，结果更新中');
  const person = (await repo.cachedPeople())[0];
  const evidence = { person_annotation: { person_id: person.person_id, state: 'active' },
    annotation_fact_ids: { person: [id(4000)], sound: [id(4001)] }, sound_kind: 'unintelligible' };
  await apply(repo, response([change({ ...dto(1, 3, evidence), speaker_label: '合成人物甲' })]));
  assert.equal((await repo.annotationOperations()).length, 0);
  assert.equal(state((await read())[0]).sync, '已同步');
  stores.at(-1).db.close();
  repo = await Repository.open({ databasePath });
  use = new UseCases(repo, { list: async () => [] }, remote);
  assert.equal(state((await read())[0]).done, true);
  await apply(repo, response([change({ ...dto(1, 4, evidence), text: '无关文本更新', speaker_label: '改名后的合成人物甲' })]));
  assert.equal(state((await read())[0]).done, true);
  console.log('PASS disk restart, two dimensions, offline failure, receipt-before-projection, cleanup, rename and text update');

  rows = await read();
  const before = await repo.cachedPeople();
  const enqueue = repo.enqueue.bind(repo);
  repo.enqueue = async op => { if (op.kind === 'segment.classify') throw Error('synthetic disk full'); return enqueue(op); };
  await assert.rejects(use.queueAnnotation([rows[1]], '', '必须回滚的人物', true, 'media_speech'), /disk full/);
  assert.equal((await repo.annotationOperations()).length, 0);
  assert.deepEqual(await repo.cachedPeople(), before);
  assert.equal(state((await read())[1]).done, false);
  repo.enqueue = enqueue;
  await use.queueSoundClassification([rows[1]], 'non_speech');
  const rejected = (await repo.annotationOperations())[0];
  await apply(repo, response([], [{ operation_id: rejected.operation_id, status: 'rejected',
    resource_revision: null, error: { code: 'annotation_invalid', message: 'source changed' } }]));
  const rejectedRow = (await read())[1];
  assert.equal(state(rejectedRow).review, true);
  assert.equal(rejectedRow.soundKind, 'non_speech');
  await apply(repo, response([change(dto(1, 5, { ...evidence, annotation_outdated: ['person'] }))]));
  assert.equal(state((await read())[0]).review, true);
  assert.match(state((await read())[0]).result, /听不清/);
  await assert.rejects(use.queueSoundClassification([rows[0]], 'speech'), /已变化/);
  console.log('PASS actual transaction rollback, rejected receipt retains choice, dimension-specific stale fact, stale save rejected');

  const changes = [];
  for (let n = 3; n <= 1202; n++) changes.push(change(dto(n)));
  for (let i = 0; i < changes.length; i += 400) await apply(repo, response(changes.slice(i, i + 400)));
  const scopeSource = (await read()).find(row => row.utteranceId === id(3));
  await use.queueSoundClassification([scopeSource], 'media_speech');
  await apply(repo, response([change({ ...dto(3, 2), start_ms: 3100 })]));
  assert.equal(state((await read()).find(row => row.utteranceId === id(3))).review, true);
  console.log('PASS source range change invalidates pending decision without losing its selection');
  const snapshot = await use.loadCached([]);
  const editor = new Editor();
  const started = performance.now();
  editor.open(snapshot.sessions[0].utterances, snapshot.sessions);
  editor.setBatch(true);
  editor.selectFiltered();
  assert.equal(editor.selectedCount, 1202);
  editor.page = 60; editor.filter();
  assert.equal(editor.pageRows.length, 2);
  editor.query = '1202'; editor.filter();
  assert.equal(editor.hidden, 1201);
  const indexed = editor.rows;
  for (let i = 0; i < 1000; i++) assert.equal(editor.update(snapshot.sessions), false);
  assert.equal(editor.rows, indexed);
  console.log(`PASS 1202 projected rows, cross-page/hidden selection and 1000 no-rescan ticks (${(performance.now() - started).toFixed(1)} ms)`);
  stores.at(-1).db.close();
})().catch(error => { console.error(error); process.exitCode = 1; });
