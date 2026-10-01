// V2 truth uses the real durable phone queue, SQL and offline projection.
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { Repository, UseCases, stores, root } = require('./phone-sqlite-harness.cjs');
const { phoneV3ReviewItems } = require(path.join(root,'data/PhoneV3ReviewProjection.ets'));
const { phoneV3ReviewIsHistory, phoneV3VoiceCandidates } = require(path.join(root,'domain/PhoneV3ReviewModels.ets'));
const time = '2026-01-01T00:00:00Z';
const source = { review_id:'blind:synthetic-v2',kind:'blind_identity_review',priority:'normal',
  source_id:'synthetic-v2',source_revision:null,session_id:null,person_id:null,title:'Blind',
  summary:'',reason:'blind_identity_review',evidence_count:2,created_at:time,updated_at:time,
  context:{review_schema_version:2,audio_composition:'multiple_clips',source_window_count:2,
    model_window_order:[0,1],review_window_order:[1,0],voice_mode:'blind_identity_review',
    review_lane:'primary',voice_candidates:[{prototype_id:'synthetic-v2',audio_available:true,
      representative_clips:[{media_id:'synthetic',start_ms:0,end_ms:8000},
        {media_id:'synthetic',start_ms:12000,end_ms:20000}]}]}};
(async () => {
  const databasePath = path.join(fs.mkdtempSync(path.join(os.tmpdir(),'blind-v2-')),'synthetic.sqlite');
  let repo = await Repository.open({databasePath});
  const remote = {isPaired:async()=>false,connect:async()=>{throw Error('offline');}};
  let use = new UseCases(repo,{list:async()=>[]},remote);
  for (const [composition,boundary] of [['clean_single','clean'],['simultaneous_overlap','clean'],
    ['sequential_multi_speaker','clean'],['backchannel','clean'],['clean_single','cut'],['uncertain','uncertain']]) {
    remote.connect=async()=>{throw Error('offline');};
    await repo.replaceReviewItems([source]);
    const request={review_id:source.review_id,action:'submit',review_schema_version:2,
      primary_speaker_person_id:null,primary_speaker_unknown:true,unknown_kind:'stranger',
      speaker_composition:composition,boundary_quality:boundary};
    let items=await use.queuePurityReview(request);
    await use.flushPurityReviews().catch(()=>{});
    assert(phoneV3ReviewIsHistory(items[0]));
    assert.equal(JSON.parse(items[0].contextJson).purity_review.speaker_composition,composition);
    assert.equal(JSON.parse(items[0].contextJson).purity_review.boundary_quality,boundary);
    assert.equal(phoneV3VoiceCandidates(items[0])[0].bestScore,null);
    stores.at(-1).db.close();
    repo=await Repository.open({databasePath});
    use=new UseCases(repo,{list:async()=>[]},remote);
    let saved=(await repo.pendingPurityReviews())[0];
    assert.equal(saved.operation_id,request.operation_id);
    assert.equal(saved.review_schema_version,2);
    assert.equal(saved.boundary_quality,boundary);
    assert.equal(saved.speaker_composition,composition);
    assert.equal(saved.purity,undefined);
    const delivered=[];
    remote.connect=async()=>({resolveReview:async submitted=>{
      delivered.push({...submitted});
      const context={...source.context,review_lane:submitted.action==='undo'?'primary':'history'};
      if (submitted.action==='submit') context.purity_review={...submitted};
      return {result:{},reviews:{items:[{...source,context}]}};
    }});
    await use.flushPurityReviews();
    assert.equal(delivered[0].operation_id,request.operation_id);
    assert.equal((await repo.pendingPurityReviews()).length,0);
    items=phoneV3ReviewItems(await repo.projectionRows('review_item'));
    assert.equal(JSON.parse(items[0].contextJson).purity_review.speaker_composition,composition);
    await use.queuePurityReview({...request,boundary_quality:'cut'});
    await use.flushPurityReviews();
    assert.equal(delivered.at(-1).boundary_quality,'cut');
    await use.queuePurityReview({review_id:source.review_id,action:'undo'});
    await use.flushPurityReviews();
    items=phoneV3ReviewItems(await repo.projectionRows('review_item'));
    assert.equal(phoneV3ReviewIsHistory(items[0]),false);
    assert.equal(JSON.parse(items[0].contextJson).purity_review,undefined);
  }
  for (const store of stores) {try {store.db.close();} catch (_) {}}
  console.log('PASS 6 V2 cases: submit/edit/undo, offline restart, sync, dimensions, no prediction hints');
})().catch(e=>{console.error(e);process.exitCode=1;});
