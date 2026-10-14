// Fictional Python backend → real Phone UseCases → production answer formatter.
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawn}=require('node:child_process'),readline=require('node:readline');
const {Repository,UseCases,stores,root}=require('./phone-sqlite-harness.cjs');
const {productRecallAnswer,productRecallCoverage,productRecallScope}=require(path.join(root,'presentation/PhoneProductRecall.ets'));
const {recallDate}=require(path.join(root,'domain/PhoneHistoryRecall.ets'));
const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'recall-query-loop-'));
const asr=process.env.CHAT_PHONE_ASR_ROOT;
const child=spawn(process.env.CHAT_PHONE_PYTHON,[path.join(asr,'tools/recall_query_phone_fixture.py'),path.join(tmp,'asr')],{cwd:asr,env:{...process.env,PYTHONIOENCODING:'utf-8',PYTHONPATH:asr+path.delimiter+path.join(asr,'src')},stdio:['pipe','pipe','pipe']});
const pending=[];let stderr='';child.stderr.on('data',v=>stderr+=v);
readline.createInterface({input:child.stdout}).on('line',line=>{const next=pending.shift();if(!next)return;const value=JSON.parse(line);value.error?next.reject(new Error(value.error)):next.resolve(value.value);});
child.on('exit',code=>{for(const p of pending.splice(0))p.reject(new Error('fixture exited '+code+' '+stderr));});
function peer(v){return new Promise((resolve,reject)=>{pending.push({resolve,reject});child.stdin.write(JSON.stringify(v)+'\n');});}
(async()=>{
 const repository=await Repository.open({databasePath:path.join(tmp,'phone.sqlite')});
 const use=new UseCases(repository,{list:async()=>[]},{isPaired:async()=>true,connect:async()=>({recall:peer})});
 let n=0;
 const ask=(extra={})=>use.historyRecall({action:'query',query_id:'phone-natural-'+(++n),question:'昨天我跟蓝老师聊了什么',timezone:'Asia/Singapore',summarize:true,expand:false,...extra});
 const success=await ask();
 const summary='你们讨论了样品检查，约定周五十点检查，由本人准备清单。';
 assert.equal(productRecallAnswer(success),summary);
 assert.match(productRecallScope(success),/实际范围：2026-10-13T00:00:00.*Asia\/Singapore/);
 assert.match(productRecallAnswer({...success,status:'coverage_insufficient',model_status:'not_requested',claims:[],evidence:[],answer:'来源覆盖不足，不能判断没有聊天。'}),/覆盖不足.*不能判断没有聊天/);
 for(const question of ['昨天我们和蓝老师聊了什么','昨天我和Aster说了啥']){const r=await ask({question});assert.equal(productRecallAnswer(r),summary);assert.equal(r.intent,'conversation');}
 assert.equal(success.answer,summary);assert.equal(success.intent,'conversation');assert.deepEqual(success.terms,[]);
 assert(success.claims[0].citations.length>=2);assert(success.unknown.length>0);assert(success.coverage.length>0);
 assert(success.evidence.some(r=>r.effective_is_self===true));assert(success.evidence.every(r=>['alice-person','myself'].includes(r.person_id)));
 assert.equal(productRecallAnswer({...success,claims:[{kind:'inference',text:'可能还需核对检查安排。',citations:['chat:rec:fixture-1001']}]}),'推测：可能还需核对检查安排。');
 assert.equal(productRecallAnswer({...success,answer:'已找到原文，可核对原话和事情进展'}),summary,'claims must reach primary display even on an older server answer');
 for(const fixture_model of ['timeout','invalid','insufficient']){
   const failed=await ask({fixture_model});
   assert.match(productRecallAnswer(failed),/无法生成/);assert(!productRecallAnswer(failed).includes('伪造'));
   assert.equal(failed.claims.length,0);assert(failed.evidence.length>0);assert(failed.unknown.length>0);
 }
 const unknown=await ask({question:'昨天我跟陌生老师聊了什么'});
 assert.equal(unknown.status,'needs_clarification');assert.equal(unknown.evidence.length,0);
 assert.match(productRecallAnswer(unknown),/没有可信/);
 const empty=await ask({question:'今天我跟蓝老师聊了什么'});
 assert.equal(empty.status,'not_found');assert.equal(empty.evidence.length,0);assert.match(productRecallAnswer(empty),/未找到/);
 const offline=await ask({fixture_offline:true,expand:true});
 assert.equal(productRecallAnswer(offline),summary);assert.match(productRecallCoverage(offline),/离线/);
 assert.equal((await repository.pendingOperations()).length,0);
 process.env.TZ='Asia/Singapore';assert.equal(recallDate('2026-10-13',true)-recallDate('2026-10-13',false)+1,86400);
 process.env.TZ='America/New_York';assert.equal(recallDate('2026-03-08',true)-recallDate('2026-03-08',false)+1,23*3600);
 assert.equal(recallDate('2026-11-01',true)-recallDate('2026-11-01',false)+1,25*3600);
 assert.throws(()=>recallDate('2026-02-30',false),/日期无效/);
 console.log('PASS natural question → bounded bilateral evidence → final Phone summary; failure/insufficient/unknown/empty/offline states; timezone and unchanged outbox');
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(()=>{child.stdin.end();for(const s of stores)s.db.close();});
