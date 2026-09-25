// Native RdbStore adapter only. All SQL, migrations, receipts and projections
// are executed by the real phone repository against an on-disk SQLite database.
const { DatabaseSync } = require('node:sqlite');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require(process.env.PHONE_TEST_TYPESCRIPT || 'typescript');
require.extensions['.ets'] = (module, filename) => module._compile(ts.transpileModule(
  fs.readFileSync(filename, 'utf8'), { compilerOptions: {
    target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS
  } }).outputText, filename);
class Store {
  constructor(file) { this.db = new DatabaseSync(file); }
  get version() { return this.db.prepare('PRAGMA user_version').get().user_version; }
  set version(v) { this.db.exec(`PRAGMA user_version=${Number(v)}`); }
  beginTransaction() { this.db.exec('BEGIN IMMEDIATE'); }
  commit() { this.db.exec('COMMIT'); }
  rollBack() { this.db.exec('ROLLBACK'); }
  async executeSql(sql, params = []) { this.db.prepare(sql).run(...params); }
  async querySql(sql, params = []) {
    const stmt = this.db.prepare(sql), columns = stmt.columns().map(c => c.name);
    const rows = stmt.all(...params); let i = -1;
    return { goToNextRow: () => ++i < rows.length, getColumnIndex: n => columns.indexOf(n),
      getString: n => rows[i][columns[n]], getLong: n => Number(rows[i][columns[n]]),
      isColumnNull: n => rows[i][columns[n]] === null, close() {} };
  }
}
const stores = [];
const notifications = { current: [], cancelled: [], published: [] };
const native = {
  '@kit.NotificationKit': { notificationManager: { isNotificationEnabled: async () => true } },
  '@kit.BackgroundTasksKit': { reminderAgentManager: {
    ReminderType: { REMINDER_TYPE_CALENDAR: 1 }, TimeZoneType: { FIXED_TIME_ZONE: 1 },
    getAllValidReminders: async () => notifications.current.slice(),
    cancelReminder: async id => { notifications.cancelled.push(id); notifications.current = notifications.current.filter(r => r.reminderId !== id); },
    publishReminder: async req => { notifications.published.push(req); notifications.current.push({ reminderId: 1, reminderReq: req }); },
    updateReminder: async (id, req) => { notifications.current.find(r => r.reminderId === id).reminderReq = req; }
  } },
  '@kit.ArkData': { relationalStore: { SecurityLevel: { S2: 2 },
  getRdbStore: async context => { const s = new Store(context.databasePath); stores.push(s); return s; }
} } };
const oldLoad = Module._load;
Module._load = function(name, ...args) { return native[name] || oldLoad.call(this, name, ...args); };
const root = path.resolve(__dirname, '../../phone/src/main/ets/v3');
module.exports = { root, stores, Store, notifications,
  Repository: require(path.join(root, 'data/PhoneProjectionRepository.ets')).PhoneProjectionRepository,
  UseCases: require(path.join(root, 'application/PhoneV3UseCases.ets')).PhoneV3UseCases,
  contract: require(path.join(root, 'contracts/V3ContractModels.ets')),
  apply: require(path.join(root, 'data/PhoneSyncProjection.ets')).applySyncResponse };
