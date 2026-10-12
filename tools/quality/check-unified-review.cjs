const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawnSync}=require('node:child_process');
const {Repository,UseCases,stores,apply,root}=require('./phone-sqlite-harness.cjs');
const {unifiedRecordingEvidence,unifiedEvidenceForClaim,visibleUnifiedSections,unifiedRecordingIdentity,UNIFIED_COVERAGE_EXPLANATION}=require(path.join(root,'domain/PhoneUnifiedReview.ets'));
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'unified-review-phone-'));let cursor=null;
function peer(extra={}) {const asr=process.env.CHAT_PHONE_ASR_ROOT;const r=spawnSync(process.env.CHAT_PHONE_PYTHON,[path.join(asr,'tools/unified_review_phone_fixture.py'),path.join(temp,'asr')],{cwd:asr,input:JSON.stringify({cursor,...extra}),encoding:'utf8',env:{...process.env,PYTHONIOENCODING:'utf-8',PYTHONPATH:path.join(asr,'src')},timeout:30000});assert.equal(r.status,0,r.stderr);const value=JSON.parse(r.stdout);cursor=value.next_cursor;return value;}
(async()=>{
  const ctx={databasePath:path.join(temp,'phone.db')};let repo=await Repository.open(ctx);
  const use=()=>new UseCases(repo,{list:async()=>[]},{isPaired:async()=>true});
  const first=peer();await apply(repo,first);
  let cache=await use().loadDailyCache(),summary=cache.summaries[0],review=summary.objective.unified_review;
  assert.equal(review.status,'ready');assert.equal(cache.summaries.length,1);assert.equal(review.claims.length,2);
  const sources=unifiedEvidenceForClaim(review,review.claims.find(c=>c.section==='followup'));assert.equal(sources[0].text,'我准备明天交第1版材料');assert.equal(sources[0].session_id,undefined);assert.equal(unifiedRecordingEvidence(sources[0]),undefined);
  assert.deepEqual(visibleUnifiedSections(review),['activity','followup']);
  assert.deepEqual(visibleUnifiedSections({...review,claims:[...review.claims,{...review.claims.find(c=>c.section==='followup'),section:'people'}]}),['people','activity','followup']);
  assert.equal(unifiedRecordingIdentity(review.evidence.find(e=>e.source_type==='recording')),'说话人身份未确认');
  assert.ok(UNIFIED_COVERAGE_EXPLANATION.includes('不是召回率'));
  const playback=unifiedRecordingEvidence(review.evidence.find(e=>e.source_type==='recording'));assert.equal(playback.start_ms,100);assert.equal(playback.end_ms,2000);
  const id=summary.summary_id,rev=summary.revision,time=review.generated_at;
  await apply(repo,peer());cache=await use().loadDailyCache();assert.equal(cache.summaries[0].revision,rev,'unchanged input has no duplicate generation');
  repo=await Repository.open(ctx);cache=await use().loadDailyCache();assert.equal(cache.summaries[0].objective.unified_review.claims.find(c=>c.section==='followup').text,'我准备明天交第1版材料');
  await apply(repo,peer({revision:2}));cache=await use().loadDailyCache();assert.equal(cache.summaries.length,1);assert.equal(cache.summaries[0].summary_id,id);assert.ok(cache.summaries[0].revision>rev);assert.equal(cache.summaries[0].objective.unified_review.claims.find(c=>c.section==='followup').text,'我准备明天交第2版材料');
  const last=cache.summaries[0].objective.unified_review;
  await apply(repo,peer({revision:3,fail:true}));cache=await use().loadDailyCache();assert.equal(cache.summaries[0].objective.unified_review.status,'failed');assert.deepEqual(cache.summaries[0].objective.unified_review.claims,last.claims);assert.equal(cache.summaries[0].objective.unified_review.generated_at,last.generated_at);
  assert.equal((await repo.pendingOperations()).length,0,'viewing reviews creates no tasks or Calendar intent');
  console.log('PASS ASR daily revision → Phone actual SQLite → restart/offline → evidence/playback mapping → repeat reuse → affected-day update → failure retains valid review; zero models');
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(()=>{for(const s of stores)s.db.close();fs.rmSync(temp,{recursive:true,force:true});});
