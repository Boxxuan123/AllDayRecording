// Real backend metadata SQLite + fake Calendar port. Task/domain never imports Calendar Kit.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { root, Repository, stores, UseCases, apply, contract } = require('./phone-sqlite-harness.cjs');
const { CalendarReminderScheduler } = require(path.join(root, 'application/CalendarReminderScheduler.ets'));
const { PhoneV3Reminder } = require(path.join(root, 'domain/PhoneV3Models.ets'));
const clone = value => JSON.parse(JSON.stringify(value));
class Calendar {
  granted = true; requests = 0; accounts = []; inventory = []; adds = 0; updates = 0; deletes = 0; failure = '';
  async permission(request) { if (request) this.requests++; return this.granted; }
  async account(id) { if (this.failure === 'account') throw Error('temporary'); if (!this.accounts.length) this.accounts.push(6); return this.accounts[0]; }
  async events() { if (this.failure === 'query') throw Error('temporary'); return clone(this.inventory); }
  async create(account, event) {
    if (this.failure === 'create') throw Error('temporary');
    const id = ++this.adds; this.inventory.push({ ...clone(event), id });
    if (this.failure === 'create_response_lost') throw Error('create response lost');
    return id;
  }
  async update(account, event) { if (this.failure === 'update') throw Error('temporary'); this.updates++; this.inventory[this.inventory.findIndex(v => v.id === event.id)] = clone(event); }
  async remove(account, id) { if (this.failure === 'delete') throw Error('temporary'); this.deletes++; this.inventory = this.inventory.filter(v => v.id !== id); }
}
const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'calendar-reminders-'));
const context = { databasePath: path.join(folder, 'phone.db') };
const due = new Date(Date.now() + 3600000).toISOString();
const task = id => new PhoneV3Reminder(id, 'session', 1, 'candidate', '给老师发材料', 'self', 'self', [], due, null, 'scheduled', due);
(async () => {
  let repo = await Repository.open(context), api = new Calendar();
  let scheduler = new CalendarReminderScheduler(api, repo), a = task('a');
  await scheduler.reconcile([]); assert.equal(api.requests, 0, 'empty startup never prompts');
  api.granted = false; await scheduler.reconcile([a]);
  assert.equal(scheduler.state('a'), 'permission_required'); assert.equal(api.adds, 0); assert.equal(a.status, 'scheduled');
  const requests = api.requests; await scheduler.reconcile([a]); assert.equal(api.requests, requests, 'denial does not repeatedly prompt');
  api.granted = true; await scheduler.retry('a', [a]);
  assert.equal(scheduler.state('a'), 'scheduled'); assert.equal(api.accounts.length, 1);
  await scheduler.reconcile([a]); await scheduler.reconcile([a]);
  assert.equal(api.adds, 1); assert.equal(api.inventory.length, 1); assert.equal(api.updates, 0);
  assert.deepEqual(api.inventory[0].reminderTime, [0]); assert.equal(api.inventory[0].description, '由 AllDayRecording 创建');
  const originalId = api.inventory[0].id;
  a.scheduledAt = new Date(Date.parse(due) + 600000).toISOString(); await scheduler.reconcile([a]);
  assert.equal(api.inventory[0].id, originalId); assert.equal(api.updates, 1); assert.equal(api.adds, 1);
  repo = await Repository.open(context); scheduler = new CalendarReminderScheduler(api, repo);
  await scheduler.reconcile([a]); assert.equal(api.accounts.length, 1); assert.equal(api.inventory.length, 1);
  assert.equal((await repo.calendarMappings())[0].calendarEventId, originalId);
  await repo.rebuildFromComputer(); assert.equal((await repo.calendarMappings())[0].calendarEventId, originalId);
  await scheduler.reconcile([]); assert.equal(api.inventory.length, 1, 'partial/cleared projection must not remove calendar events');
  api.inventory[0].startTime += 60000; await scheduler.reconcile([a]);
  assert.equal(scheduler.state('a'), 'externally_modified'); assert.equal(api.updates, 1);
  await scheduler.reconcile([a]); assert.equal(api.updates, 1);
  await scheduler.retry('a', [a]); assert.equal(scheduler.state('a'), 'scheduled'); assert.equal(api.inventory[0].id, originalId);
  api.inventory = []; await scheduler.reconcile([a]); assert.equal(scheduler.state('a'), 'externally_removed');
  await scheduler.reconcile([a]); assert.equal(api.adds, 1);
  await scheduler.retry('a', [a]); assert.equal(api.adds, 2); assert.equal(scheduler.state('a'), 'scheduled');
  a.status = 'cancelled'; api.failure = 'delete'; await scheduler.reconcile([a]);
  assert.equal(scheduler.state('a'), 'error'); assert.equal(api.inventory.length, 1);
  api.failure = ''; await scheduler.reconcile([a]); assert.equal(api.inventory.length, 0); assert.equal(scheduler.state('a'), 'removed');
  const b = task('b'); await scheduler.reconcile([b]); b.status = 'completed'; await scheduler.reconcile([b]);
  assert.equal(api.inventory.length, 0); assert.equal(b.status, 'completed');
  const c = task('c'); api.failure = 'create'; await scheduler.reconcile([c]); assert.equal(scheduler.state('c'), 'error');
  api.failure = ''; await scheduler.reconcile([c]); assert.equal(scheduler.state('c'), 'scheduled');
  c.scheduledAt = new Date(Date.parse(due) + 1200000).toISOString(); api.failure = 'update';
  await scheduler.reconcile([c]); assert.equal(scheduler.state('c'), 'error');
  api.failure = ''; await scheduler.reconcile([c]); assert.equal(scheduler.state('c'), 'scheduled');
  // Recover an event whose create committed before saving its ID locally.
  const d = task('d'); const mapping = clone((await repo.calendarMappings()).find(v => v.taskId === 'c'));
  mapping.taskId = 'd'; mapping.calendarEventId = -1; mapping.scheduledDueAt = ''; mapping.calendarSyncState = 'creating';
  await repo.saveCalendarMapping(mapping);
  api.inventory.push({ ...clone(api.inventory[0]), id: 999, identifier: 'allday-calendar-task:d', startTime: Date.parse(due), endTime: Date.parse(due) + 900000 });
  const adds = api.adds; await scheduler.reconcile([d]); assert.equal(api.adds, adds);
  assert.equal((await repo.calendarMappings()).find(v => v.taskId === 'd').calendarEventId, 999);
  // The create side effect is durable even when its response is lost. Cancellation
  // and completion must look up the stable identifier after a restart as well.
  for (const [name, finalStatus, restart] of [
    ['lost_cancel', 'cancelled', false], ['lost_complete', 'completed', false],
    ['lost_restart_cancel', 'cancelled', true], ['lost_restart_complete', 'completed', true]
  ]) {
    const pending = task(name);
    api.failure = 'create_response_lost';
    await scheduler.reconcile([pending]);
    assert.equal(api.inventory.filter(v => v.identifier === `allday-calendar-task:${name}`).length, 1);
    assert.equal((await repo.calendarMappings()).find(v => v.taskId === name).calendarEventId, -1);
    api.failure = '';
    if (restart) {
      repo = await Repository.open(context);
      scheduler = new CalendarReminderScheduler(api, repo);
    }
    pending.status = finalStatus;
    await scheduler.reconcile([pending]);
    await scheduler.reconcile([pending]);
    assert.equal(api.inventory.filter(v => v.identifier === `allday-calendar-task:${name}`).length, 0);
    assert.equal((await repo.calendarMappings()).find(v => v.taskId === name).calendarSyncState, 'removed');
  }
  const absent = task('never_created');
  const absentMapping = new (require(path.join(root, 'application/CalendarReminderPorts.ets')).CalendarReminderMapping)();
  absentMapping.taskId = absent.eventId; absentMapping.calendarAccountId = 6;
  absentMapping.calendarSyncState = 'creating';
  await repo.saveCalendarMapping(absentMapping);
  absent.status = 'cancelled';
  await scheduler.reconcile([absent]);
  assert.equal((await repo.calendarMappings()).find(v => v.taskId === absent.eventId).calendarSyncState, 'removed');
  // Existing review/outbox/receipt/projection flow injects the same Calendar port.
  const liveRepo = await Repository.open({ databasePath: path.join(folder, 'flow.db') });
  const liveApi = new Calendar(), liveScheduler = new CalendarReminderScheduler(liveApi, liveRepo);
  const remote = { isPaired: async () => true, connect: async () => { throw Error('offline'); } };
  const use = new UseCases(liveRepo, {}, remote, liveScheduler);
  const id = n => String(n).padStart(26, '0');
  await liveRepo.replaceReviewItems([{ review_id: 'reminder:' + id(3), kind: 'reminder', priority: 'high',
    source_id: id(3), source_revision: null, session_id: id(2), person_id: 'self', title: '测试', summary: '测试',
    reason: 'reminder_requires_confirmation', evidence_count: 1, created_at: due, updated_at: due,
    context: { actor_person_id: 'self', scheduled_at: due } }]);
  await use.queueReminder('reminder.review', { candidate_id: id(3), action: 'confirm' });
  await use.loadCached([]); assert.equal(liveApi.adds, 0, 'no Calendar event before confirmed projection');
  const operation = (await liveRepo.reminderOperations())[0];
  const dto = { event_id: id(1), session_id: id(2), event_revision: 1, source_candidate_id: id(3),
    title: '给老师发材料', actor_person_id: 'self', commitment_direction: 'not_applicable', related_person_ids: [],
    scheduled_at: due, location: null, status: 'scheduled', updated_at: due };
  await apply(liveRepo, { projection_version: contract.V3_PROJECTION_VERSION,
    changes: [{ sequence: 1, resource_type: 'reminder', resource_id: id(1), revision: 1, operation: 'upsert', resource: dto }],
    receipts: [{ operation_id: operation.operation_id, status: 'applied', resource_revision: 1, error: null,
      resource_results: [{ resource_id: id(1), revision: 1 }] }], next_cursor: 'cursor-1', has_more: false, server_time: due });
  await use.loadCached([]); assert.equal(liveApi.adds, 0, 'cached query is side-effect free');
  await use.reconcileCalendar(); await use.loadCached([]); assert.equal(liveApi.adds, 1);
  const nativeId = liveApi.inventory[0].id;
  const newDue = new Date(Date.parse(due) + 1800000).toISOString();
  await use.queueReminder('reminder.task', { event_id: id(1), action: 'reschedule', scheduled_at: newDue }, 1);
  await use.loadCached([]); await use.reconcileCalendar(); assert.equal(liveApi.inventory[0].id, nativeId);
  assert.equal(liveApi.inventory[0].startTime, Date.parse(newDue));
  // Pending task actions survive offline restart and immediately revoke the calendar event.
  const restarted = new UseCases(await Repository.open({ databasePath: path.join(folder, 'flow.db') }), {}, remote,
    new CalendarReminderScheduler(liveApi, liveRepo));
  await restarted.loadCached([]); await restarted.reconcileCalendar(); assert.equal(liveApi.adds, 1);
  console.log('Calendar review integration PASS: durable confirm, receipt, projection, duplicate reload, offline reschedule and restart');
  console.log('Calendar reminders PASS: permission, account, confirm, duplicate, reschedule, cancel, complete, restart, rebuild, external edits/deletion, retry and create recovery');
})().finally(() => { stores.forEach(store => store.db.close()); fs.rmSync(folder, { recursive: true, force: true }); });
