// Real production selectors, evidence index and SQLite/use-case boundaries.
const assert = require('node:assert/strict'), fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { Repository, UseCases, stores, apply, contract, root } = require('./phone-sqlite-harness.cjs');
const { PhoneV3ReviewSubmissionError } = require(path.join(root, 'application/PhoneV3UseCases.ets'));
const { phoneV3PendingReviews, phoneV3ReviewIsHistory } = require(path.join(root, 'domain/PhoneV3ReviewModels.ets'));
const { phoneV3VoiceTasks, PhoneV3VoiceQueue, PhoneV3VoiceEvidenceIndex, phoneV3EvidencePending } = require(path.join(root, 'domain/PhoneV3VoiceReviewTask.ets'));
const { phoneV3ReviewSnapshotItems } = require(path.join(root, 'data/PhoneV3ReviewProjection.ets'));
const id = n => String(n).padStart(26, '0'), time = '2026-09-25T00:00:00Z';
const clip = n => ({ media_id: 'm', start_ms: n * 1000, end_ms: n * 1000 + 500 });
const mapping = n => ({ utterance_id: id(n), session_id: id(9000), revision: 1,
  utterance_start_ms: n * 1000, utterance_end_ms: n * 1000 + 900,
  window_index: n - 1, media_id: 'm', clip_start_ms: n * 1000, clip_end_ms: n * 1000 + 500,
  session_start_ms: n * 1000, session_end_ms: n * 1000 + 500 });
const candidate = (prototype_id, nums = [1,2,3,4,5]) => ({ prototype_id, session_id: id(9000), speaker_track_id: 'track',
  person_name: '合成人物甲', review_status: 'pending', review_key: prototype_id, audition_key: prototype_id,
  representative_clips: nums.map(clip), evidence_utterances: nums.map((n,i) => ({...mapping(n),window_index:i})) });
const dtoReview = (review_id, mode, candidates = [candidate(review_id)]) => ({ review_id, kind: 'voice_identity', priority:'normal',
  source_id:id(7000), source_revision:null, session_id:id(9000), person_id:null, title:'合成声音', summary:'', reason:'test', evidence_count:5,
  created_at:time,updated_at:time,context:{voice_mode:mode,voice_candidates:candidates, review_lane:mode==='accepted_grant'?'history':'primary'} });
const parse = rows => phoneV3ReviewSnapshotItems(rows);
const histories = parse([1,2,3].map(n=>dtoReview(`h${n}`,'accepted_grant')));
assert.equal(histories.length,3); assert.equal(phoneV3PendingReviews(histories).length,0);assert.equal(histories.filter(phoneV3ReviewIsHistory).length,3);
assert.equal(phoneV3PendingReviews(parse([{...dtoReview('x','known_person'),context:{review_lane:'history'}}])).length,0);
const taskRows=parse([dtoReview('r','known_person',[candidate('a'),candidate('b'),candidate('c')])]);
const tasks=phoneV3VoiceTasks(taskRows); const queue=new PhoneV3VoiceQueue();queue.open(tasks,'r');queue.next(true);assert.equal(queue.current().candidate.prototypeId,'b');queue.next();assert.equal(queue.current().candidate.prototypeId,'c');queue.next();assert.equal(queue.current(),undefined);assert.deepEqual(queue.skipped,['r:a']);queue.revisit(taskRows,false);assert.equal(queue.current().candidate.prototypeId,'a');
console.log('PASS history-only queue/counts, exact candidate tasks, A skip/B success/C next without wrap');
(async()=>{
 const databasePath=path.join(fs.mkdtempSync(path.join(os.tmpdir(),'voice-flow-')),'synthetic.sqlite');
 let repo=await Repository.open({databasePath});let writes=0;
 const session={reviews:async()=>({items:taskRows.map(()=>dtoReview('r','known_person'))}),resolveReview:async()=>{writes++;return {result:{},reviews:{items:[]}}}};
 const remote={isPaired:async()=>false,connect:async()=>session}; let use=new UseCases(repo,{list:async()=>[]},remote);
 const changes=[{sequence:1,resource_type:'recording_session',resource_id:id(9000),revision:1,operation:'upsert',resource:{session_id:id(9000),session_key:'synthetic',captured_start:time}}];
 for(let n=1;n<=81;n++) changes.push({sequence:n+1,resource_type:'utterance',resource_id:id(n),revision:1,operation:'upsert',resource:{
  utterance_id:id(n),session_id:id(9000),speaker_track_id:null,speaker_label:'未知声音',original_speaker_track_id:null,original_speaker_label:null,
  identity:'unknown',original_identity:'unknown',identity_evidence:{},start_ms:n*1000,end_ms:n*1000+900,start_at:time,end_at:'2026-09-25T00:00:01Z',
  text:`合成原句 ${n}`,original_text:`合成原句 ${n}`,revision:1,status:'active',evidence:{}}});
 await apply(repo,{projection_version:contract.V3_PROJECTION_VERSION,changes,receipts:[],next_cursor:'cursor-82',has_more:false,server_time:time});
 let snapshot=await use.loadCached([]);const index=new PhoneV3VoiceEvidenceIndex();index.update(snapshot.sessions);
 const first=tasks[0].candidate;assert.equal(index.resolve(first).length,5);assert.equal(snapshot.sessions[0].utterances.length,81);
 const other=phoneV3VoiceTasks(parse([dtoReview('other','known_person',[candidate('other',[7])])]))[0].candidate;
 assert.deepEqual(index.resolve(other).map(r=>r.utteranceId),[id(7)]);
 const oldRevision=first.evidence[0].revision;first.evidence[0].revision=999;assert.equal(index.resolve(first).length,4);first.evidence[0].revision=oldRevision;
 const missing=phoneV3VoiceTasks(parse([dtoReview('missing','known_person',[{...candidate('missing'),evidence_utterances:[]}])]))[0].candidate;
 assert.equal(index.resolve(missing).length,0);
 const unknown=phoneV3VoiceTasks(parse([dtoReview('unknown','speaker_discovery',[candidate('c',[6,7,8])])]))[0].candidate;
 const selected=index.resolve(unknown).slice(0,2);await use.queueAnnotation(selected,'','合成人物乙',true,'');
 snapshot=await use.loadCached([]);index.update(snapshot.sessions);
 assert.equal(snapshot.sessions[0].utterances.filter(r=>r.annotationFacts.person==='pending').length,2);
 assert.equal((await repo.annotationOperations()).length,2);assert.equal(writes,0);assert(phoneV3EvidencePending(index.resolve(unknown)));
 stores.at(-1).db.close();repo=await Repository.open({databasePath});use=new UseCases(repo,{list:async()=>[]},remote);
 assert.equal((await use.loadCached([])).sessions[0].utterances.filter(r=>r.annotationFacts.person==='pending').length,2);
 console.log('PASS 5 windows vs 81 sentences; disjoint candidates; missing/version mismatch fail closed; only 2 of 3 mapped sentences persist offline');
 const replace=repo.replaceReviewItems.bind(repo);repo.replaceReviewItems=async()=>{throw Error('disk full')};
 await assert.rejects(use.resolveReview({review_id:'r',prototype_id:'a',action:'confirm'}),e=>e instanceof PhoneV3ReviewSubmissionError&&e.committed);
 assert.equal(writes,1);repo.replaceReviewItems=replace;await use.refreshReviews();assert.equal(writes,1);
 session.resolveReview=async()=>{writes++;throw Error('timeout')};
 await assert.rejects(use.resolveReview({review_id:'r',action:'reject'}),e=>e instanceof PhoneV3ReviewSubmissionError&&!e.committed);
 session.resolveReview=async()=>{const e=Error('stale');e.statusCode=409;throw e};
 await assert.rejects(use.resolveReview({review_id:'r',action:'reject'}),/stale/);
 remote.connect=async()=>{throw Error('computer offline')};
 await assert.rejects(use.resolveReview({review_id:'r',action:'confirm'}),/computer offline/);
 console.log('PASS offline vs conflict vs unknown timeout vs committed/cache failure; state retry never repeats mutation');
 for(const store of stores)try{store.db.close()}catch{}
})().catch(e=>{console.error(e);process.exitCode=1});
