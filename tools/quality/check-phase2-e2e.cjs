// node >=22.13; actual Python services + phone SQLite projection + scheduler.
const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path');
const { spawn } = require('node:child_process');
const readline = require('node:readline');
const { Repository, UseCases, contract, stores, root, notifications } = require('./phone-sqlite-harness.cjs');
const python = spawn(process.env.PHONE_TEST_PYTHON, ['-u','-X','utf8','-m','tests.phase2_server_bridge'], {
  cwd: process.env.AUDIT_ASR_ROOT, stdio: ['pipe','pipe','inherit'] });
const pending = [];
python.on('exit', code => { if (code !== 0 || pending.length) {
  process.exitCode = 1; for (const waiter of pending.splice(0)) waiter.reject(Error(`server exited ${code}`));
} });
readline.createInterface({ input: python.stdout }).on('line', line => {
  const waiter = pending.shift();
  if (!waiter) throw Error('Unexpected server output: '+line);
  const response = JSON.parse(line); response.error ? waiter.reject(Error(response.error)) : waiter.resolve(response.result);
});
const rpc = (action, request) => new Promise((resolve,reject) => {
  pending.push({resolve,reject}); python.stdin.write(JSON.stringify({action,request})+'\n');
});
const { PhoneV3ReminderScheduler } = require(path.join(root,'data/PhoneV3ReminderScheduler.ets'));
const page = fs.readFileSync(path.join(root,'presentation/PhoneV3PeoplePage.ets'),'utf8');
const body = page.slice(page.indexOf('  private speakerKey('),page.indexOf('  private utterancesFor('));
const speakerKey = new Function('utterance', body.slice(body.indexOf('{')+1,body.lastIndexOf('}')));
const projectedRows = snapshot => snapshot.sessions.flatMap(s => s.utterances);
(async () => {
  const init = await rpc('init'); Date.now = () => init.now;
  const dir = fs.mkdtempSync(path.join(require('node:os').tmpdir(),'phone-e2e-'));
  const databasePath = path.join(dir,'synthetic.sqlite');
  let repo = await Repository.open({databasePath});
  const batchSizes = [];
  let expectStable = false;
  const session = { status: async () => ({contract_version:contract.V3_CONTRACT_VERSION,projection_version:contract.V3_PROJECTION_VERSION}),
    sync: async request => {
      if (expectStable) assert.equal(new Set(projectedRows(await use.loadCached([])).map(speakerKey)).size,1,
        'no transient grouping loss between receipt and authoritative pull pages');
      batchSizes.push(request.client_operations.length); return rpc('sync',request);
    },
    annotations: request => rpc('annotations',request), reviews: () => rpc('reviews'), resolveReview: request => rpc('resolve',request) };
  const remote = { connect: async () => session, isPaired: async () => true };
  let use = new UseCases(repo,{list:async()=>[]},remote,new PhoneV3ReminderScheduler({}));
  await use.synchronize();
  const initial = projectedRows(await use.loadCached([])); assert.equal(initial.length,3);
  await use.queueSpeakerAnnotation(initial,init.person_id,'Same display name');
  assert.equal((await repo.annotationOperations()).length,3);
  assert.equal(new Set(projectedRows(await use.loadCached([])).map(speakerKey)).size,1);
  stores.at(-1).db.close(); repo = await Repository.open({databasePath});
  // Reduce only the transport batch capacity for this three-row scenario. All
  // outbox dependency/eligibility decisions remain in the real repository SQL.
  const pendingOperations = repo.pendingOperations.bind(repo);
  repo.pendingOperations = (limit,excluded) => pendingOperations(Math.min(limit,2),excluded);
  use = new UseCases(repo,{list:async()=>[]},remote,new PhoneV3ReminderScheduler({}));
  const store = stores.at(-1), executeSql = store.executeSql.bind(store);
  let failProjection = true;
  store.executeSql = async (sql,params) => {
    if (failProjection && sql.includes('INSERT INTO projection_utterances')) {
      failProjection = false; throw Error('synthetic local write failure after server commit');
    }
    return executeSql(sql,params);
  };
  batchSizes.length = 0;
  expectStable = true;
  await assert.rejects(use.synchronize(), /synthetic local write failure/);
  assert.equal((await repo.annotationOperations()).length,3,'receipt removal rolled back with projection failure');
  assert.equal(new Set(projectedRows(await use.loadCached([])).map(speakerKey)).size,1);
  await use.synchronize();
  expectStable = false;
  assert.deepEqual(batchSizes.filter(n=>n>0),[2,2,1]);
  stores.at(-1).db.close(); repo = await Repository.open({databasePath});
  use = new UseCases(repo,{list:async()=>[]},remote,new PhoneV3ReminderScheduler({}));
  let saved = projectedRows(await use.loadCached([]));
  assert(saved.every(r=>r.annotationPersonId===init.person_id));
  assert.equal(new Set(saved.map(speakerKey)).size,1);
  assert.equal((await repo.annotationOperations()).length,0);
  const factCount = (await rpc('inspect')).fact_count;
  assert.equal(factCount,3,'server replay did not duplicate independent confirmations');
  await rpc('worker'); await rpc('worker');
  assert.equal((await rpc('inspect')).fact_count,factCount);
  const reviews = await session.reviews();
  const review = reviews.items.find(r=>r.person_id===init.person_id && r.kind==='voice_identity');
  assert(review,'aggregate candidate reaches existing review inbox');
  await use.resolveReview({review_id:review.review_id,action:'confirm',prototype_id:review.context.prototype_ids[0]});
  assert.deepEqual((await rpc('inspect')).matching_people,[init.person_id]);
  const reminder = await rpc('confirm_reminder'); await use.synchronize(); await use.loadCached([]);
  assert.equal(notifications.current.length,1);
  saved = projectedRows(await use.loadCached([]));
  await use.queueSpeakerAnnotation([saved[0]],init.second_person_id,'Same display name');
  await use.synchronize();
  const state = await rpc('inspect');
  assert.deepEqual(state.matching_people,[]);
  for (const key of ['title','scheduled_at','status']) assert.equal(state.reminder[key],reminder[key]);
  assert.equal(state.reminder.source_review_required,true);
  saved = projectedRows(await use.loadCached([]));
  assert.equal(new Set(saved.map(speakerKey)).size,2,'same display name with different stable ids stays separate');
  assert.equal(notifications.cancelled.length,0); assert.equal(notifications.current.length,1);
  await rpc('conflict'); await use.synchronize();
  saved = projectedRows(await use.loadCached([]));
  const conflicted = saved.find(row=>row.utteranceId===init.ids[0]);
  assert.equal(conflicted.annotationPersonId,''); assert.equal(conflicted.identity,'unknown');
  const status = await use.annotations({action:'status',utterance_ids:init.ids});
  assert.equal(status.items.find(row=>row.utterance_id===init.ids[0]).fact_status,'conflict');
  console.log('PASS actual concurrent fact conflict -> sync -> SQLite -> reconstructed phone model remains unassigned.');
  console.log('PASS E2E: offline 3 short sentences -> SQLite restart -> 2/1 push + multipage pull -> stable groups -> actual aggregate worker -> existing review -> actual person_vectors -> one correction withdraws whole vector; confirmed reminder stays scheduled through actual phone scheduler.');
})().catch(error => { console.error(error); process.exitCode=1; }).finally(()=>{
  python.stdin.end(); for (const s of stores) { try{s.db.close();}catch{} }
});
