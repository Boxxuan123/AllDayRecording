const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.env.PHONE_TEST_TYPESCRIPT || 'typescript');

let opens = 0;
const repository = { cursor: 0, pending: ['operation-1'] };
const exportsObject = {};
const source = ts.transpileModule(
  fs.readFileSync('phone/src/main/ets/v3/application/PhoneSyncService.ets', 'utf8'),
  { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } }
).outputText;
vm.runInNewContext(source, {
  exports: exportsObject, Map, Set, Promise, Error, console,
  require: name => {
    if (name.includes('PhoneProjectionRepository')) return {
      PhoneProjectionRepository: { open: async () => { opens++; return repository; } }
    };
    if (name.includes('PhoneV3UseCases')) return {
      PhoneV3UseCases: class {
        constructor(owner, local, remote) { this.owner = owner; this.remote = remote; }
        cancelSynchronize() { this.cancelled = true; }
        async synchronize() {
          const client = await this.remote.connect();
          const result = await client.sync({});
          this.owner.cursor = result.next_cursor;
          return { batches: 1, submittedOperations: 0, finalCursor: result.next_cursor };
        }
      }
    };
    return {};
  }
});

(async () => {
  const Service = exportsObject.PhoneSyncService;
  const first = await Service.shared({ filesDir: 'phone-files' });
  const second = await Service.shared({ filesDir: 'phone-files' });
  assert.equal(first, second);
  assert.equal(opens, 1);
  const states = [];
  const unsubscribe = first.subscribe(state => states.push([state.runningOwner, state.queued]));
  let release, active = 0, peak = 0;
  const homeCancellation = { cancelled: false, cancelSynchronize() { this.cancelled = true; } };
  const enter = () => { active++; peak = Math.max(peak, active); };
  const leave = () => { active--; };
  const home = first.run('home', async db => {
    enter();
    await new Promise(resolve => { release = resolve; });
    db.cursor = 1;
    db.pending = [];
    leave();
  }, homeCancellation);
  const page = first.run('computer-page', async db => {
    enter();
    assert.equal(db.cursor, 1);
    assert.deepEqual(db.pending, []);
    db.cursor = 2;
    leave();
  });
  const cancelled = first.run('home', async () => { throw Error('cancelled work ran'); });
  for (let turn = 0; turn < 10 && release === undefined; turn++) await Promise.resolve();
  assert.equal(typeof release, 'function');
  first.cancel('home');
  assert.equal(homeCancellation.cancelled, true);
  release();
  await home;
  await page;
  await assert.rejects(cancelled, /取消/);
  assert.equal(peak, 1);
  assert.equal(repository.cursor, 2);
  const client = { sync: async () => ({ next_cursor: 'cursor-3' }) };
  const result = await first.synchronize('computer-page', client);
  assert.equal(result.final_cursor, 'cursor-3');
  assert.equal(repository.cursor, 'cursor-3');
  let finishActive;
  const activeClient = { sync: async () => new Promise(resolve => { finishActive = resolve; }) };
  const activeHome = first.synchronize('home', activeClient);
  for (let turn = 0; turn < 10 && finishActive === undefined; turn++) await Promise.resolve();
  const pageAfterCancel = first.synchronize('computer-page',
    { sync: async () => ({ next_cursor: 'cursor-4' }) });
  first.cancel('home');
  finishActive({ next_cursor: 'cursor-3a' });
  await activeHome;
  assert.equal((await pageAfterCancel).final_cursor, 'cursor-4');
  assert.equal(repository.cursor, 'cursor-4');
  // A new application process reopens its own service over the same durable
  // projection. Pending operations are handed to the common sync engine once.
  const reopened = new Service({ cursor: 'cursor-4', pending: ['operation-2'] });
  let restartedSubmissions = 0;
  await reopened.synchronize('home', { sync: async () => {
    restartedSubmissions++;
    assert.deepEqual(reopened.projection().pending, ['operation-2']);
    reopened.projection().pending = [];
    return { next_cursor: 'cursor-5' };
  } });
  assert.equal(restartedSubmissions, 1);
  assert.deepEqual(reopened.projection().pending, []);
  assert(states.some(([owner, queued]) => owner === 'home' && queued >= 1));
  assert.deepEqual(states.at(-1), ['', 0]);
  unsubscribe();
  console.log('Phone sync service PASS: one DB owner, one shared sync implementation, one stream, isolated cancellation');
})().catch(error => { console.error(error); process.exitCode = 1; });
