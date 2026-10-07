// Exercise production repositories/use cases with actual SQLite, counting work.
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { Repository, UseCases, stores, apply, contract } = require('./phone-sqlite-harness.cjs');
const id = n => String(n).padStart(26, '0');
const time = '2026-09-27T00:00:00Z';
const row = n => ({ utterance_id:id(n),session_id:id(9000+n%21),speaker_track_id:null,
  speaker_label:null,original_speaker_track_id:null,original_speaker_label:null,
  identity:'unknown',original_identity:'unknown',identity_evidence:{},start_ms:n*1000,
  end_ms:n*1000+500,start_at:time,end_at:'2026-09-27T00:00:01Z',text:'synthetic',original_text:'synthetic',
  revision:1,status:'active',evidence:{} });
const change = r => ({ sequence:1,resource_type:'utterance',resource_id:r.utterance_id,
  revision:r.revision,operation:'upsert',resource:r });
(async () => {
  const repo = await Repository.open({ databasePath:path.join(fs.mkdtempSync(path.join(os.tmpdir(),'sync-query-cost-')),'test.db') });
  const store = stores.at(-1);
  for (let n=0;n<21;n++) await repo.applyChange({sequence:1,resource_type:'recording_session',
    resource_id:id(9000+n),revision:1,operation:'upsert',resource:{session_id:id(9000+n)}});
  for (let n=1;n<=2100;n++) await repo.applyChange(change(row(n)));
  const use = new UseCases(repo,{list:async()=>[]},{isPaired:async()=>true});
  const parse = JSON.parse; let parses=0;
  JSON.parse = (...args) => { if (typeof args[0]==='string' && args[0].includes('"original_identity"')) parses++; return parse(...args); };
  let snapshot;
  try { snapshot=await use.loadCached([]); } finally { JSON.parse=parse; }
  assert.equal(parses,0,'home must not parse transcript history');
  assert.equal(snapshot.sessions.reduce((n,s)=>n+s.utteranceCount,0),2100);
  assert.equal(snapshot.sessions.reduce((n,s)=>n+s.utterances.length,0),0);
  JSON.parse=(...args)=>{if(typeof args[0]==='string'&&args[0].includes('"original_identity"'))parses++;return parse(...args);};
  try { await use.loadSessionUtterancePage(snapshot.sessions[0],50); } finally { JSON.parse=parse; }
  assert.equal(parses,50,'session opening reads one SQL page');
  assert.equal(snapshot.sessions[0].utterances.length,50);
  const one = await use.loadUtteranceById(snapshot.sessions[0].utterances[0].utteranceId);
  assert.equal(one.utteranceId,snapshot.sessions[0].utterances[0].utteranceId);
  assert.equal((await use.loadUtteranceById(id(9999999))),undefined);
  const changedId=snapshot.sessions[0].utterances[0].utteranceId;
  const revised={...row(Number(changedId)),revision:2,text:'synthetic edited'};
  await repo.applyChange(change(revised));
  const refreshedSnapshot=await use.refreshUtterances(snapshot,[changedId]);
  assert.equal(refreshedSnapshot.sessions[0].utteranceCount,100);
  assert.equal(refreshedSnapshot.sessions[0].utterances.length,0,'changed page must clear its cursor');
  await use.loadSessionUtterancePage(refreshedSnapshot.sessions[0],50);
  assert.equal(refreshedSnapshot.sessions[0].utterances.length,50);
  assert.equal(refreshedSnapshot.sessions[0].utterances[0].text,'synthetic edited');
  console.log('PASS 2100 utterances / 21 sessions: zero home payloads, 50 session rows');

  for (let n=1;n<=1200;n++) await repo.enqueue({operation_id:id(10000+n),kind:'segment.classify',
    base_revision:null,payload:{selections:[{utterance_id:id(n),revision:1}],sound_kind:'non_speech',
      depends_on:n<=700?[id(99999)]:[]}});
  await store.executeSql('INSERT INTO conflicts VALUES(?,?,?,?,?,?)',[id(99999),'segment.classify','{}','{}',1,'conflict']);
  let payloads=0; JSON.parse=(...args)=>{if(args[0].includes('"selections"'))payloads++;return parse(...args);};
  let pending;
  try { pending=await repo.pendingOperations(32,[id(10701)]); } finally { JSON.parse=parse; }
  assert.equal(pending.length,32);assert.equal(pending[0].operation_id,id(10702));assert.equal(payloads,32);
  assert(store.db.prepare('EXPLAIN QUERY PLAN SELECT * FROM outbox ORDER BY created_at,rowid LIMIT 32').all()
    .some(r=>r.detail.includes('outbox_created_at')));
  console.log('PASS 1200 queued / 700 blocked: only 32 ready payloads parsed, exclusion and indexed order preserved');

  const receipts=pending.map(op=>({operation_id:op.operation_id,status:'applied',resource_revision:2,error:null}));
  const response={projection_version:contract.V3_PROJECTION_VERSION,receipts,changes:[],next_cursor:'cursor-32',has_more:false,server_time:time};
  let cleanups=0;const cleanup=repo.clearProjectedOperations.bind(repo);
  repo.clearProjectedOperations=async()=>{cleanups++;return cleanup();};
  await apply(repo,response);assert.equal(cleanups,1);
  assert.equal((await repo.status()).confirmed_operations,32);
  // Fail after cleanup but before cursor update: all projection/receipt retirement rolls back.
  const execute=store.executeSql.bind(store);let fail=true;
  store.executeSql=async(sql,args)=>{if(fail&&sql.includes('UPDATE sync_state SET cursor'))throw Error('injected');return execute(sql,args);};
  const changes=pending.map((op,i)=>({...change({...row(Number(op.payload.selections[0].utterance_id)),revision:2}),sequence:33+i}));
  await assert.rejects(apply(repo,{...response,receipts:[],changes,next_cursor:'cursor-64'}),/injected/);
  assert.equal(await repo.currentCursor(),'cursor-32');assert.equal((await repo.status()).confirmed_operations,32);
  assert((await repo.projectionRows('utterance',pending.map(op=>op.payload.selections[0].utterance_id))).every(r=>r.revision===1));
  fail=false;await apply(repo,{...response,receipts:[],changes,next_cursor:'cursor-64'});
  assert.equal((await repo.status()).confirmed_operations,0);
  console.log('PASS one cleanup / 32 receipts; late projections and cursor failure preserve atomic rollback');

  let review={items:[{review_id:'synthetic-review',updated_at:time}],version:'r1'};
  let people={people:[{person_id:id(8000),display_name:'Synthetic'}],version:'p1'};
  const remote={isPaired:async()=>true,connect:async()=>({reviews:async()=>review,annotations:async()=>people})};
  const refreshed=new UseCases(repo,{list:async()=>[]},remote);let notifications=0;
  refreshed.onCommitted=()=>notifications++;
  await refreshed.refreshSupplementary();assert.equal(notifications,1);
  const writes=store.db.prepare('SELECT total_changes() n').get().n;
  await refreshed.refreshSupplementary();
  assert.equal(store.db.prepare('SELECT total_changes() n').get().n,writes);assert.equal(notifications,1);
  const reopened=new UseCases(repo,{list:async()=>[]},remote);reopened.onCommitted=()=>notifications++;
  await reopened.refreshSupplementary();
  assert.equal(store.db.prepare('SELECT total_changes() n').get().n,writes);assert.equal(notifications,1);
  review={items:[],version:'r2'};people={people:[{person_id:id(8000),display_name:'Renamed'}],version:'p2'};
  await refreshed.refreshSupplementary();assert.equal(notifications,2);
  assert.equal((await repo.cachedPeople())[0].display_name,'Renamed');
  assert.equal((await repo.projectionRows('review_item')).length,0);
  console.log('PASS unchanged versions and restarted client: zero row writes / UI notifications; changed versions converge');
  for(const s of stores)s.db.close();
})().catch(e=>{console.error(e);process.exit(1);});
