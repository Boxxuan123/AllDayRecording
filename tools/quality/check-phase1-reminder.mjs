// Runs the actual ArkTS projection, DTO decoder, use case and scheduler under
// TypeScript transpilation. Only storage, clock and OS notification APIs are fakes.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';
const require = createRequire(import.meta.url);
const ts = require(path.resolve(process.argv[2]));
const root = path.resolve(process.argv[3]);
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const current = []; const cancelled = []; const published = []; const updated = [];
const native = {
  '@kit.NotificationKit': { notificationManager: { isNotificationEnabled: async () => true } },
  '@kit.BackgroundTasksKit': { reminderAgentManager: {
    ReminderType: { REMINDER_TYPE_CALENDAR: 1 }, TimeZoneType: { FIXED_TIME_ZONE: 1 },
    getAllValidReminders: async () => current.slice(),
    cancelReminder: async id => { cancelled.push(id); current.splice(current.findIndex(r => r.reminderId === id), 1); },
    publishReminder: async req => { published.push(req); current.push({ reminderId: 1, reminderReq: req }); },
    updateReminder: async (id, req) => { updated.push(req); current[0].reminderReq = req; }
  } }
};
const cache = new Map();
function load(file) {
  file = path.resolve(file);
  if (cache.has(file)) return cache.get(file).exports;
  const mod = { exports: {} }; cache.set(file, mod);
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  const localRequire = spec => {
    if (native[spec]) return native[spec];
    assert(spec.startsWith('.'), `unexpected native dependency: ${spec}`);
    return load(path.resolve(path.dirname(file), spec + '.ets'));
  };
  vm.runInThisContext(`(function(require,module,exports){${js}\n})`, { filename: file })(localRequire, mod, mod.exports);
  return mod.exports;
}
const { applySyncResponse } = load(path.join(root, 'data/PhoneSyncProjection.ets'));
const { PhoneV3UseCases } = load(path.join(root, 'application/PhoneV3UseCases.ets'));
const { PhoneV3ReminderScheduler } = load(path.join(root, 'data/PhoneV3ReminderScheduler.ets'));
const rows = new Map();
const storage = {
  beginTransaction: async () => {}, commit: async () => {}, rollback: async () => {},
  acknowledgeReceipt: async () => {}, setCursor: async () => {},
  applyChange: async c => {
    if (c.operation === 'tombstone') rows.delete(`${c.resource_type}:${c.resource_id}`);
    else rows.set(`${c.resource_type}:${c.resource_id}`, {
      resourceId: c.resource_id, revision: c.revision, payloadJson: JSON.stringify(c.resource), updatedAt: 0
    });
  },
  projectionRows: async type => [...rows.entries()].filter(([key]) => key.startsWith(type+':')).map(([,row]) => row),
  localAudioLinks: async () => [], conflictRows: async () => [], v3Status: async () => ({}), annotationOperations: async () => []
};
Date.now = () => input.now;
const useCases = new PhoneV3UseCases(storage, {}, { isPaired: async () => true }, new PhoneV3ReminderScheduler({}));
for (const response of input.responses) {
  await applySyncResponse(storage, response);
  const snapshot = await useCases.loadCached([]);
  assert(snapshot);
  assert.equal(current.length, 1);
  assert.equal(current[0].reminderReq.groupId, 'allday-v33:' + input.event_id);
}
assert.equal(cancelled.length, 0);
assert.equal(published.length, 1);
assert.equal(updated.length, input.responses.length - 1);
// Preserve the real fail-closed treatment of stale schedules.
const key = 'reminder:' + input.event_id;
const row = rows.get(key); const payload = JSON.parse(row.payloadJson);
payload.status = 'stale'; row.payloadJson = JSON.stringify(payload);
await useCases.loadCached([]);
assert.deepEqual(cancelled, [1]);
console.log('PASS: server sync -> actual projection/decoder -> actual scheduler; unchanged reminder retained; stale cancelled. OS notifications mocked.');
