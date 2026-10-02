// Real SQLite migrations/projections; synthetic sources never leave this temporary DB.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Repository, stores, apply, contract, UseCases } = require('./phone-sqlite-harness.cjs');
const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'daily-events-'));
const context = { databasePath: path.join(folder, 'phone.db') };
const id = n => String(n).padStart(26, '0');
const participant = { key: 'self', kind: 'self', label: '本人', status: 'source_confirmed' };
const evidence = { session_id: id(3), utterance_id: id(4), revision: 1, start_ms: 100, end_ms: 900,
  start_at: '2026-09-01T08:00:00Z', end_at: '2026-09-01T08:00:01Z', text: '讨论项目材料', participant };
const event = { event_id: id(1), revision: 1, local_date: '2026-09-01', timezone: 'Asia/Singapore',
  title: '讨论片段：讨论项目材料', participants: [participant], linked_task_ids: [],
  evidence_snapshots: [evidence], start_at: evidence.start_at, end_at: evidence.end_at };
const summary = { summary_id: id(2), revision: 1, summary_date: event.local_date, timezone: event.timezone,
  objective: { date: event.local_date, headline: '1 个有证据的事件片段', source_event_ids: [id(1)],
    source_event_revisions: { [id(1)]: 1 }, key_events: [{ text: event.title, event_ids: [id(1)] }],
    tasks_created: [], tasks_completed: [], tasks_pending: [], people_interacted: [], unresolved_items: [] } };
const response = changes => ({ projection_version: contract.V3_PROJECTION_VERSION, receipts: [], changes,
  next_cursor: 'cursor-2', server_time: evidence.start_at, has_more: false });
const change = (type, resource, sequence) => ({ resource_type: type, resource_id: type === 'daily_event' ? resource.event_id : resource.summary_id,
  revision: resource.revision, operation: 'upsert', sequence, resource });
(async () => {
  let repo = await Repository.open(context);
  const baseline = stores.at(-1);
  await repo.setCursor('cursor-42', evidence.start_at);
  baseline.db.exec('DROP TABLE projection_daily_events; DROP TABLE projection_daily_summaries; PRAGMA user_version=18');
  baseline.db.close();
  repo = await Repository.open(context);
  assert.equal((await repo.v3Status()).cursor, 'cursor-42', 'schema migration preserves cursor');
  const packet = response([change('daily_event', event, 1), change('daily_summary', summary, 2)]);
  await apply(repo, packet); await apply(repo, packet);
  assert.equal((await repo.projectionRows('daily_event')).length, 1, 'duplicate sync dedupes');
  assert.equal((await repo.projectionRows('daily_summary')).length, 1);
  stores.at(-1).db.close();
  repo = await Repository.open(context);
  const use = new UseCases(repo, { isPaired: async () => true, sync: async () => { throw Error('offline'); } }, { list: async () => [] });
  const cache = await use.loadDailyCache();
  assert.equal(cache.events[0].evidence_snapshots[0].session_id, id(3));
  assert.equal(cache.summaries[0].objective.key_events[0].event_ids[0], id(1));
  assert.equal(cache.events.length, 1, 'restart/offline cache survives');
  const broken = structuredClone(event); broken.evidence_snapshots = [];
  await assert.rejects(apply(repo, response([change('daily_event', broken, 3)])), /来源证据/);
  const invented = structuredClone(summary); invented.objective.key_events[0].event_ids = [id(999)];
  await assert.rejects(apply(repo, response([change('daily_summary', invented, 4)])), /事件来源/);
  const newer = structuredClone(event); newer.revision = 2; newer.title = '修正后的原文';
  await apply(repo, response([change('daily_event', newer, 5)]));
  await apply(repo, packet);
  assert.equal((await repo.projectionRows('daily_event'))[0].revision, 2, 'old replay cannot overwrite revision');
  const sql = stores.at(-1).db;
  assert.equal(sql.prepare('SELECT count(*) AS n FROM calendar_reminder_mappings').get().n, 0);
  assert.equal(sql.prepare('SELECT count(*) AS n FROM outbox').get().n, 0);
  sql.close(); fs.rmSync(folder, { recursive: true, force: true });
  console.log('PASS daily migration, duplicate sync, restart, offline cache, evidence links, source validation, revision guard; no task/calendar writes');
})().catch(error => { console.error(error); process.exitCode = 1; });
