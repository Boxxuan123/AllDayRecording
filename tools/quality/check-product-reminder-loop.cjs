// PRODUCT_REMINDER_E2E_TEST: real ArkTS use cases/repository and on-disk SQLite.
// HarmonyOS APIs are mocked: this never claims a real device notification.
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { Repository, UseCases, stores, apply, contract, root, notifications } = require('./phone-sqlite-harness.cjs');
const { PhoneV3ReminderScheduler: Scheduler } = require(path.join(root, 'data/PhoneV3ReminderScheduler.ets'));
const id = n => String(n).padStart(26, '0');
const now = Date.now(), due = new Date(now + 600000).toISOString();
let sequence = 0;
const dto = (revision = 1, status = 'scheduled', scheduled_at = due) => ({ event_id: id(1), session_id: id(2),
  event_revision: revision, source_candidate_id: id(3), title: 'PRODUCT_REMINDER_E2E_TEST 检查结果',
  actor_person_id: 'self', commitment_direction: 'not_applicable', related_person_ids: [],
  scheduled_at, location: null, status, updated_at: new Date(now).toISOString() });
const change = value => ({ sequence: ++sequence, resource_type: 'reminder', resource_id: value.event_id,
  revision: value.event_revision, operation: 'upsert', resource: value });
const response = (changes = [], receipts = []) => ({ projection_version: contract.V3_PROJECTION_VERSION,
  changes, receipts, next_cursor: `cursor-${sequence}`, has_more: false, server_time: new Date(now).toISOString() });

(async () => {
  const databasePath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'product-reminder-')), 'synthetic.sqlite');
  let repository = await Repository.open({ databasePath });
  const remote = { isPaired: async () => true, connect: async () => { throw Error('offline'); } };
  let use = new UseCases(repository, {}, remote, new Scheduler({}));
  const review = { review_id: 'reminder:' + id(3), kind: 'reminder', priority: 'high', source_id: id(3),
    source_revision: null, session_id: id(2), person_id: 'self', title: '测试', summary: '测试',
    reason: 'reminder_requires_confirmation', evidence_count: 1, created_at: due, updated_at: due,
    context: { actor_person_id: 'self', source_text: '我明天下午三点检查结果', scheduled_at: due } };
  await repository.replaceReviewItems([review]);
  await use.queueReminder('reminder.review', { candidate_id: id(3), action: 'confirm' });
  const operationId = (await repository.reminderOperations())[0].operation_id;
  await assert.rejects(use.queueReminder('reminder.review', { candidate_id: id(3), action: 'confirm' }), /已有待同步/);
  await assert.rejects(use.synchronize(), /offline/);
  await use.loadCached([]);
  assert.equal(notifications.current.length, 0, 'unconfirmed candidate must not schedule');
  stores.at(-1).db.close();
  repository = await Repository.open({ databasePath });
  use = new UseCases(repository, {}, remote, new Scheduler({}));
  assert.equal((await repository.reminderOperations())[0].operation_id, operationId);
  const receipt = { operation_id: operationId, status: 'applied', resource_revision: 1, error: null,
    resource_results: [{ resource_id: id(1), revision: 1 }] };
  await apply(repository, response([], [receipt]));
  await repository.replaceReviewItems([review]);
  assert.equal((await repository.projectionRows('review_item')).length, 0, 'stale snapshot cannot resurrect confirmed candidate');
  assert.equal((await repository.reminderOperations()).length, 1, 'retain until projection even on a later page');
  await apply(repository, response([change(dto())]));
  assert.equal((await repository.reminderOperations()).length, 0);
  await use.loadCached([]);
  assert.equal(notifications.current.length, 1);
  const published = notifications.published.length;
  await use.loadCached([]); await use.loadCached([]);
  assert.equal(notifications.published.length, published, 'duplicate sync/reload must not publish twice');
  stores.at(-1).db.close();
  repository = await Repository.open({ databasePath });
  use = new UseCases(repository, {}, remote, new Scheduler({}));
  assert.equal((await use.loadCached([])).reminders.length, 1);
  assert.equal(notifications.published.length, published, 'restart must reuse OS reminder');
  const newDue = new Date(now + 1200000).toISOString();
  await use.queueReminder('reminder.task', { event_id: id(1), action: 'reschedule', scheduled_at: newDue }, 1);
  await use.loadCached([]);
  assert.equal(notifications.current[0].reminderReq.dateTime.minute, new Date(newDue).getUTCMinutes());
  const reschedule = (await repository.reminderOperations())[0];
  await apply(repository, response([], [{ operation_id: reschedule.operation_id, status: 'applied',
    resource_revision: 2, error: null, resource_results: [{ resource_id: id(1), revision: 2 }] }]));
  await use.loadCached([]);
  assert.equal((await repository.reminderOperations()).length, 1);
  await apply(repository, response([change(dto(2, 'scheduled', newDue))]));
  await use.queueReminder('reminder.task', { event_id: id(1), action: 'cancel' }, 2);
  assert.equal((await use.loadCached([])).reminders[0].status, 'cancelled');
  assert.equal(notifications.current.length, 0, 'offline cancel must revoke OS request');
  stores.at(-1).db.close();
  repository = await Repository.open({ databasePath });
  use = new UseCases(repository, {}, remote, new Scheduler({}));
  await use.loadCached([]);
  assert.equal(notifications.current.length, 0, 'restart cannot resurrect pending cancellation');
  const cancellation = (await repository.reminderOperations())[0];
  await apply(repository, response([change(dto(3, 'cancelled'))], [{ operation_id: cancellation.operation_id,
    status: 'applied', resource_revision: 3, error: null, resource_results: [{ resource_id: id(1), revision: 3 }] }]));
  assert.equal((await repository.reminderOperations()).length, 0);
  await apply(repository, response([change(dto(4))]));
  await use.loadCached([]);
  await use.queueReminder('reminder.task', { event_id: id(1), action: 'complete' }, 4);
  await use.loadCached([]);
  assert.equal(notifications.current.length, 0, 'completion cancels system reminder');
  const completion = (await repository.reminderOperations())[0];
  await apply(repository, response([change(dto(5, 'completed'))], [{ operation_id: completion.operation_id,
    status: 'applied', resource_revision: 5, error: null, resource_results: [{ resource_id: id(1), revision: 5 }] }]));
  await use.loadCached([]);
  assert.equal(notifications.current.length, 0);
  const scheduler = new Scheduler({});
  await apply(repository, response([change(dto(6))]));
  await use.loadCached([]);
  notifications.current.push({ reminderId: 99, reminderReq: { ...notifications.current[0].reminderReq } });
  await scheduler.reconcile((await use.loadCached([])).reminders);
  assert.equal(notifications.current.length, 1, 'cleanup preexisting duplicate system groups');
  notifications.enabled = false;
  const next = (await use.loadCached([])).reminders;
  next[0].scheduledAt = new Date(now + 1800000).toISOString();
  await assert.rejects(scheduler.reconcile(next), /通知权限/);
  assert.equal(notifications.current.length, 0, 'denied permission cannot leave the old due time scheduled');
  const permissionRequests = notifications.permissionRequests;
  await scheduler.reconcile([]);
  assert.equal(notifications.current.length, 0, 'revocation still works with denied notification permission');
  assert.equal(notifications.permissionRequests, permissionRequests, 'empty lists must not prompt for permission');
  await assert.rejects(scheduler.reconcile((await use.loadCached([])).reminders), /通知权限/);
  notifications.enabled = true;
  const invalid = new UseCases(repository, {}, remote, { reconcile: async () => { throw Error('permission denied'); } });
  await invalid.loadCached([]);
  assert.match(invalid.reminderSchedulingError, /permission denied/);
  const editReview = { ...review, review_id: 'reminder:' + id(30), source_id: id(30) };
  const ignoreReview = { ...review, review_id: 'reminder:' + id(31), source_id: id(31) };
  await repository.replaceReviewItems([editReview, ignoreReview]);
  await use.queueReminder('reminder.review', { candidate_id: id(30), action: 'edit', title: '修改后的待办', scheduled_at: newDue });
  await use.queueReminder('reminder.review', { candidate_id: id(31), action: 'ignore' });
  stores.at(-1).db.close();
  repository = await Repository.open({ databasePath });
  use = new UseCases(repository, {}, remote, new Scheduler({}));
  const decisions = await repository.reminderOperations();
  assert.equal(decisions.length, 2, 'edit/ignore choices survive restart');
  assert.equal(decisions[0].payload.title, '修改后的待办');
  assert.equal(decisions[0].payload.scheduled_at, newDue);
  assert.equal((await use.loadCached([])).reviewItems.length, 0, 'queued decisions cannot be decided twice');
  await apply(repository, response([], decisions.map(operation => ({ operation_id: operation.operation_id,
    status: 'applied', resource_revision: 1, error: null,
    resource_results: operation.payload.action === 'edit' ? [{ resource_id: id(40), revision: 1 }] : [] }))));
  assert.equal((await repository.reminderOperations()).length, 1, 'edit waits for task projection; ignore is final');
  await repository.replaceReviewItems([editReview, ignoreReview]);
  assert.equal((await repository.projectionRows('review_item')).length, 0);
  await apply(repository, response([change({ ...dto(), event_id: id(40), source_candidate_id: id(30),
    title: '修改后的待办', scheduled_at: newDue })]));
  assert.equal((await repository.reminderOperations()).length, 0);
  assert.equal((await use.loadCached([])).reminders.find(value => value.eventId === id(40)).title, '修改后的待办');
  stores.at(-1).db.close();
  console.log('PASS: reminder loop (durable confirmation/edit/ignore, no preconfirmation notification, duplicate choice, offline retry, paged receipt, stale snapshot, reload, restart, reschedule, cancellation, completion, duplicate OS group, denied permission, visible OS error). OS notifications mocked.');
})().catch(error => { console.error(error); process.exitCode = 1; });
