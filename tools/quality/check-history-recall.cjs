// Fictional cross-repository bridge through the production Phone use case. No devices/models.
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawn}=require('node:child_process');const readline=require('node:readline');
const {Repository,UseCases,stores,root}=require('./phone-sqlite-harness.cjs');
const {recallDate}=require(path.join(root,'domain/PhoneHistoryRecall.ets'));
const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'history-recall-phone-'));
const asr=process.env.CHAT_PHONE_ASR_ROOT;
const child=spawn(process.env.CHAT_PHONE_PYTHON,[path.join(asr,'tools/recall_phone_fixture.py'),path.join(tmp,'asr')],{cwd:asr,env:{...process.env,PYTHONIOENCODING:'utf-8',PYTHONPATH:asr+path.delimiter+path.join(asr,'src')},stdio:['pipe','pipe','pipe']});
const pending=[];let stderr='';child.stderr.on('data',v=>stderr+=v);
readline.createInterface({input:child.stdout}).on('line',line=>{const next=pending.shift();if(!next)return;const v=JSON.parse(line);v.error?next.reject(new Error(v.error)):next.resolve(v.value);});
child.on('exit',code=>{for(const p of pending.splice(0))p.reject(new Error('fixture exited '+code+' '+stderr));});
function peer(v){return new Promise((resolve,reject)=>{pending.push({resolve,reject});child.stdin.write(JSON.stringify(v)+'\n');});}
(async()=>{
 const repository=await Repository.open({databasePath:path.join(tmp,'phone.db')});
 const use=new UseCases(repository,{list:async()=>[]},{isPaired:async()=>true,connect:async()=>({recall:peer})});
 assert.equal(recallDate('2026-10-09',false),1791475200);assert.throws(()=>recallDate('bad-date',false));
 let catalog=await use.historyRecall({action:'catalog'});
 assert.equal(catalog.people.length,3);
 const account=catalog.items.find(i=>i.platform==='qq'&&i.source==='source-qq'&&i.account==='alice');
 const command={operation_id:'phone-stable-operation',key:account.key,person_id:'alice-person',action:'link',basis:'synthetic explicit confirmation',version:catalog.version};
 assert.equal((await use.historyRecall({action:'identity',decision:command})).status,'applied');
 assert.equal((await use.historyRecall({action:'identity',decision:command})).status,'applied');
 const before=await peer({action:'fingerprint'});
 let result=await use.historyRecall({action:'query',query_id:'phone-query-1',question:'杭电',keyword:'杭电',person_id:'alice-person',sent_from:1791503990,sent_to:1791504200,summarize:false,expand:false});
 assert.equal(result.metrics.hits,3);assert(result.evidence.some(e=>e.source==='recording'));
 assert(result.evidence.some(e=>e.role==='context'&&e.person_id===''));
 assert.deepEqual(await peer({action:'fingerprint'}),before,'query cannot enqueue memory/tasks/Calendar/voice work');
 assert.equal((await repository.pendingOperations()).length,0,'query has no Phone business outbox entries');
 catalog=await use.historyRecall({action:'catalog'});
 await use.historyRecall({action:'identity',decision:{...command,operation_id:'phone-unlink',action:'unlink',version:catalog.version}});
 await assert.rejects(()=>use.historyRecall({action:'page',query_id:'phone-query-1',page:0}),/过期|失效/);
 result=await use.historyRecall({action:'query',query_id:'phone-query-2',question:'杭电',keyword:'杭电',person_id:'alice-person',sent_from:1791503990,sent_to:1791504200,summarize:false,expand:false});
 assert.equal(result.metrics.hits,1);assert.equal(result.evidence[0].source,'recording');
 await use.historyRecall({action:'cancel',query_id:'phone-query-2'});
 await assert.rejects(()=>use.historyRecall({action:'page',query_id:'phone-query-2',page:0}));
 console.log('PASS Phone real use case → ASR identity command/query/context ownership/unlink/cancel; SQLite/outbox unchanged by query');
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(()=>{child.stdin.end();for(const store of stores)store.db.close();});
