// Fictional backend -> actual Phone UseCases -> production claim/time presentation.
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawn}=require('node:child_process'),readline=require('node:readline');
const {Repository,UseCases,root}=require('./phone-sqlite-harness.cjs');
const {productRecallAnswer,productRecallClaimLabel,productRecallClaimTime}=require(path.join(root,'presentation/PhoneProductRecall.ets'));
const {applyRecallContext}=require(path.join(root,'domain/PhoneHistoryRecall.ets'));
const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'agentic-recall-phone-'));
const asr=process.env.CHAT_PHONE_ASR_ROOT;
const child=spawn(process.env.CHAT_PHONE_PYTHON,[path.join(asr,'tools/agentic_recall_phone_fixture.py'),path.join(tmp,'asr')],{cwd:asr,env:{...process.env,PYTHONIOENCODING:'utf-8',PYTHONPATH:asr+path.delimiter+path.join(asr,'src')},stdio:['pipe','pipe','pipe']});
const pending=[];let stderr='';child.stderr.on('data',v=>stderr+=v);
readline.createInterface({input:child.stdout}).on('line',line=>{const p=pending.shift();if(!p)return;const v=JSON.parse(line);v.error?p.reject(new Error(v.error)):p.resolve(v.value);});
child.on('exit',code=>{for(const p of pending.splice(0))p.reject(new Error('fixture exited '+code+' '+stderr));});
function peer(v){return new Promise((resolve,reject)=>{pending.push({resolve,reject});child.stdin.write(JSON.stringify(v)+'\n');});}
(async()=>{
 const repository=await Repository.open({databasePath:path.join(tmp,'phone.sqlite')});
 const use=new UseCases(repository,{list:async()=>[]},{isPaired:async()=>true,connect:async()=>({recall:peer})});
 const result=await use.historyRecall({action:'query',query_id:'phone-agentic-acceptance',question:'前天霜叶观测社的活动有什么进展？',timezone:'Asia/Singapore',source:'qq',expand:true,summarize:true});
 assert.equal(result.model_status,'available');assert.equal(result.metrics.model_calls,2);
 assert.match(productRecallAnswer(result),/^来源陈述：.*冲突/);
 const claim=result.claims[0];assert.equal(productRecallClaimLabel(claim),'来源陈述');
 assert.match(productRecallClaimTime(claim),/事件时间：2026-10-13.*消息日期/);
 assert.equal(productRecallClaimLabel({...claim,kind:'source_fact'}),'来源事实');
 assert.match(productRecallAnswer({...result,claims:[{...claim,kind:'inference'}]}),/^推测：/);
 assert.match(productRecallClaimTime({...claim,event_time:{...claim.event_time,basis:'inferred'}}),/尚属推测/);
 const later=result.evidence.find(e=>e.record_id==='rec:fixture-5002');assert(later);
 const context=await use.historyRecall({action:'context',query_id:result.query_id,evidence_id:later.id});
 assert.equal(context.status,'available');assert(context.evidence.some(e=>e.id===later.id),'later discussion must remain openable despite earlier event date');
 const stale=applyRecallContext(result,{status:'stale',query_id:result.query_id,invalidated_evidence_ids:[later.id]});
 assert.equal(stale.claims.length,0);assert.match(productRecallAnswer(stale),/重新核对/);
 const source=fs.readFileSync(path.join(root,'presentation/PhoneRecallSearch.ets'),'utf8');
 assert(source.includes('productRecallClaimLabel(claim)'));assert(source.includes('productRecallClaimTime(claim)'));
 console.log('PASS fictional agentic backend -> Phone UseCases -> statement/time/citation/invalidation presentation');
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(()=>{child.stdin.end();child.kill();});
