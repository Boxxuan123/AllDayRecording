// Original audit assertions; repository fixture includes new status port reads.
// Executes the unmodified ArkTS application/domain classes via TypeScript transpilation.
// Native storage/network are test doubles. Not a device/ArkUI test.
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const ts=require('typescript');
require.extensions['.ets']=(module,filename)=>{
 const source=fs.readFileSync(filename,'utf8');
 const out=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
 module._compile(out,filename);
};
const root=path.join(process.env.AUDIT_HARMONY_ROOT || path.join(__dirname,'annotation-review/source/Harmony'),'phone/src/main/ets/v3');
const {PhoneV3UseCases}=require(path.join(root,'application/PhoneV3UseCases.ets'));
const contract=require(path.join(root,'contracts/V3ContractModels.ets'));
(async()=>{
 let queue=Array.from({length:1001},(_,i)=>({operation_id:String(i+1).padStart(26,'0'),kind:'segment.classify',base_revision:null,payload:{},attempt_count:0}));
 const submitted=[];
 const repository={v3Status:async()=>({pendingOperations:queue.length}), conflictRows:async()=>[], pendingOperations:async limit=>queue.slice(0,limit),currentCursor:async()=> 'cursor-0',
   beginTransaction:async()=>{},commit:async()=>{},rollback:async()=>{},
   acknowledgeReceipt:async receipt=>{queue=queue.filter(op=>op.operation_id!==receipt.operation_id)},
   applyChange:async()=>{},setCursor:async()=>{},replaceReviewItems:async()=>{},cachePeople:async()=>{}};
 const remote={connect:async()=>({status:async()=>({contract_version:contract.V3_CONTRACT_VERSION,projection_version:contract.V3_PROJECTION_VERSION}),
   sync:async request=>{submitted.push(request.client_operations.length); return {
     projection_version:contract.V3_PROJECTION_VERSION, receipts:request.client_operations.map(op=>({operation_id:op.operation_id,status:'applied',resource_revision:1,error:null})),
     changes:[],next_cursor:'cursor-0',has_more:false,server_time:'2026-09-24T00:00:00Z'}},
   reviews:async()=>({items:[]}),annotations:async()=>({people:[]})})};
 const uc=new PhoneV3UseCases(repository,{list:async()=>[]},remote);
 const result=await uc.synchronize();
 console.log(JSON.stringify({initial:1001,submittedPerRequest:submitted,remaining:queue.length,result},null,2));
 assert.equal(queue.length,0,'Successful full synchronize leaves local annotations unsent');
})().catch(error=>{console.error(error);process.exitCode=1});
