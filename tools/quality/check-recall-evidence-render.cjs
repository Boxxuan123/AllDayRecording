// Rendering identity must change when an async citation fills the same evidence ID.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {root}=require('./phone-sqlite-harness.cjs');
const {PhoneProductEvidence,recallProductEvidence,productEvidenceRenderKey,productContextNotice}=require(path.join(root,'presentation/PhoneProductEvidence.ets'));
const placeholder=new PhoneProductEvidence();placeholder.id='chat:synthetic-later-page';
const native={id:placeholder.id,revision:1,source:'qq',speaker:'虚构乙',person_id:'',sent_at:1791997200,quote:'北门，等最后通知',role:'context',quote_truncated:false,validity:'active'};
const loaded=recallProductEvidence(native);
assert.equal(loaded.id,placeholder.id);assert.notEqual(productEvidenceRenderKey(placeholder),productEvidenceRenderKey(loaded));
assert.notEqual(productEvidenceRenderKey(loaded),productEvidenceRenderKey({...loaded,quote:'取消，改为线上'}));
assert.notEqual(productEvidenceRenderKey(loaded),productEvidenceRenderKey({...loaded,unavailable:true}));
assert.equal(productEvidenceRenderKey(loaded),productEvidenceRenderKey({...loaded}));
const budget='来源未成功打开（SOURCE_REQUEST_BUDGET_REACHED）；保留本轮原文';
assert.equal(productContextNotice({status:'unavailable',notice:budget}),budget);
assert(!productContextNotice({status:'unavailable'}).includes('离线'));
assert.match(productContextNotice({status:'stale'}),/失效|修订/);
const page=fs.readFileSync(path.join(root,'presentation/PhoneEvidenceDetails.ets'),'utf8');
assert.match(page,/productEvidenceRenderKey\(e\)/);assert.match(page,/productContextNotice\(context\)/);
console.log('PASS same-ID empty citation -> async native text render; changed/retracted rows; honest context failure reason');
