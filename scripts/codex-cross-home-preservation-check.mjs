// Owned-only feasibility probe. Never reads a user's CODEX_HOME or credentials.
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,readFile,copyFile,rm,stat,readdir} from 'node:fs/promises';
import {spawn,execFileSync} from 'node:child_process';
import {createServer} from 'node:http';
import {createInterface} from 'node:readline';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const cli=process.env.AUTOAPPROVE_CODEX_BIN;
assert.ok(cli&&path.isAbsolute(cli),'Set AUTOAPPROVE_CODEX_BIN to a native installed CLI');
const probeVersion=process.argv.includes('--probe-0.167')?'0.167.0':'0.166.0';
const version=execFileSync(cli,['--version'],{encoding:'utf8'}).trim();assert.equal(version,'codex-cli '+probeVersion,'The owned probe must match its explicit native version');
const restoreGoal=process.argv.includes('--restore-goal');
const requireGoal=process.argv.includes('--require-goal-preservation')||restoreGoal;
const returnOriginal=process.argv.includes('--return-original-home');
const checkClearedSlot=process.argv.includes('--check-cleared-slot');
const checkSettings=process.argv.includes('--check-settings');
const checkRetirement=process.argv.includes('--check-retirement');
const returnCleared=process.argv.includes('--return-cleared-goal');
const crashNativeAcks=process.argv.includes('--crash-native-acks');
assert.ok(probeVersion==='0.166.0'||!returnOriginal,'The native return coordinator is still pinned to 0.166.0; the 0.167 probe does not bypass its version contract');
assert.ok(!crashNativeAcks || returnOriginal&&checkRetirement);
assert.ok(!returnCleared || returnOriginal&&checkRetirement);
assert.ok(!checkClearedSlot || restoreGoal);
assert.ok(!checkSettings || restoreGoal);
assert.ok(!checkRetirement || restoreGoal);
assert.ok(!returnOriginal || restoreGoal&&process.argv.includes('--archive-source'));
assert.ok(!returnOriginal || checkRetirement,'Direct return requires typed retirement and independent backup');
const root=await mkdtemp('/private/tmp/aa-cross-home-'),children=[];
const env={...process.env};for(const k of Object.keys(env))if(/TOKEN|API_KEY|CODEX_HOME|NODE_OPTIONS/.test(k))delete env[k];
let requests=0;const requestBodies=[];
const provider=createServer(async(req,res)=>{
 let data='';for await(const chunk of req)data+=chunk;
 if(!req.url.endsWith('/responses')){res.writeHead(404);res.end();return;}
 requestBodies.push(JSON.parse(data));
 requests++;const id='resp_owned_'+requests,item={id:'msg_owned_'+requests,type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:'Owned preservation fixture response.',annotations:[]}]};
 res.writeHead(200,{'Content-Type':'text/event-stream','Connection':'close'});
 const emit=(type,body)=>res.write('data: '+JSON.stringify({type,...body})+'\n\n');
 emit('response.created',{response:{id,status:'in_progress',output:[]}});
 emit('response.output_item.added',{output_index:0,item:{...item,status:'in_progress',content:[]}});
 emit('response.output_text.delta',{item_id:item.id,output_index:0,content_index:0,delta:item.content[0].text});
 emit('response.output_item.done',{output_index:0,item});
 emit('response.completed',{response:{id,status:'completed',output:[item],usage:{input_tokens:23,output_tokens:11,total_tokens:34}}});res.end();
});
await new Promise(r=>provider.listen(0,'127.0.0.1',r));
async function server(home){
 await mkdir(home,{recursive:true});
 await writeFile(home+'/config.toml',`cli_auth_credentials_store = "file"\nmodel = "owned-fixture"\nmodel_provider = "owned"\n[features]\nhooks = false\n[model_providers.owned]\nname = "Owned loopback fixture"\nbase_url = "http://127.0.0.1:${provider.address().port}/v1"\nwire_api = "responses"\nrequires_openai_auth = false\n`);
 const child=spawn(cli,['app-server'],{cwd:home,env:{...env,CODEX_HOME:home},detached:true,stdio:['pipe','pipe','pipe']});children.push(child);
 let sequence=0,stderr='',notifications=[];const pending=new Map();
 child.stderr.on('data',b=>{stderr=(stderr+b).slice(-12000)});
 createInterface({input:child.stdout}).on('line',line=>{let m;try{m=JSON.parse(line)}catch{return}if('id'in m&&pending.has(m.id)){const p=pending.get(m.id);pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(Error(home+" "+p.method+": "+JSON.stringify(m.error))):p.resolve(m.result);}else notifications.push(m);});
 const request=(method,params={})=>new Promise((resolve,reject)=>{const id=++sequence,timer=setTimeout(()=>{pending.delete(id);reject(Error(method+' timed out: '+stderr.slice(-1000)))},20000);pending.set(id,{resolve,reject,timer,method});child.stdin.write(JSON.stringify({id,method,params})+'\n');});
 const wait=async(method,predicate=()=>true)=>{const end=Date.now()+25000;while(Date.now()<end){const m=notifications.find(m=>m.method===method&&predicate(m.params));if(m)return m.params;await new Promise(r=>setTimeout(r,20));}throw Error(method+' missing: '+stderr.slice(-1000));};
 const stop=async()=>{if(child.exitCode!==null||child.signalCode!==null)return;process.kill(-child.pid,'SIGTERM');await new Promise(r=>{child.once('close',r);setTimeout(r,1500)});};
 await request('initialize',{clientInfo:{name:'owned_preservation_fixture',version:'1'},capabilities:{experimentalApi:true}});child.stdin.write(JSON.stringify({method:'initialized'})+'\n');
 return {request,wait,stop,home,pid:child.pid,identity:'owned:'+child.pid+':'+process.hrtime.bigint(),alive:()=>child.exitCode===null&&child.signalCode===null};
}
const sql=(home,q)=>execFileSync('/usr/bin/sqlite3',[home+'/goals_1.sqlite',q],{encoding:'utf8'}).trim();
async function archivedRollout(home,id){const entries=await readdir(home+'/archived_sessions',{recursive:true});const found=entries.filter(name=>name.endsWith('.jsonl')&&name.includes(id));assert.equal(found.length,1);return path.join(home,'archived_sessions',found[0]);}
try{
 let transfer;
 if(restoreGoal){
  transfer=root+'/transfer';const build=path.resolve('.build/debug');
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/GoalTransfer'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/codex-goal-transfer-check.swift','Tests/fixtures/codex-native-return-bridge.swift','-o',transfer],{stdio:'inherit',timeout:120000});
 }
 let a=await server(root+'/a');
 const workspaceRoot=root+'/selected-workspace';
 if(checkSettings)await mkdir(workspaceRoot);
 const settings=checkSettings?{serviceTier:'flex',baseInstructions:'Owned base instruction sentinel 731.',developerInstructions:'Owned developer instruction sentinel 829.',config:{model_reasoning_effort:'high'},runtimeWorkspaceRoots:[workspaceRoot]}:{};
 const start=await a.request('thread/start',{cwd:root,model:'owned-fixture',modelProvider:'owned',approvalPolicy:'never',sandbox:'read-only',...settings}),id=start.thread.id;
 const disabledPlugins=['owned-disabled-plugin@example.invalid'];
 if(checkSettings)await a.request('thread/settings/update',{threadId:id,effort:'high',serviceTier:'flex',disabledPluginIds:disabledPlugins});
 await a.request('turn/start',{threadId:id,input:[{type:'text',text:'Owned synthetic history only. Reply with the fixture response.',text_elements:[]}]});
 const turn=await a.wait('turn/completed',p=>p.threadId===id);assert.equal(turn.turn.status,'completed',JSON.stringify(turn.turn.error));
 const checkRequest=body=>{
  assert.equal(body.reasoning?.effort,'high','Nondefault reasoning must reach inference');
  assert.equal(body.service_tier,'flex','Nondefault service tier must reach inference');
  const content=JSON.stringify((body.input||[]).filter(item=>['system','developer'].includes(item.role)));
  assert.ok(content.includes('Owned base instruction sentinel 731.'),'Base instructions must reach inference');
  assert.ok(content.includes('Owned developer instruction sentinel 829.'),'Developer instructions must reach inference');
 };
 if(checkSettings)checkRequest(requestBodies[0]);
 await a.request('thread/goal/set',{threadId:id,objective:'Owned preservation objective',status:'paused',tokenBudget:1234,origin:'user'});
 const source=(await a.request('thread/read',{threadId:id,includeTurns:true})).thread;assert.ok(source.turns.length>0);assert.ok(source.turns.some(t=>t.items.some(i=>i.type==='agentMessage')),'Nonempty assistant history required');
 console.error(JSON.stringify({sourcePath:source.path,pathExists:source.path?await stat(source.path).then(s=>s.size).catch(()=>false):false}));await a.stop();
 const columns=sql(a.home,'PRAGMA table_info(thread_goals);');assert.match(columns,/goal_id/);
 if(requireGoal)console.error(JSON.stringify({goalSchema:sql(a.home,'.schema'),migrations:sql(a.home,'SELECT version,description,success,hex(checksum) FROM _sqlx_migrations ORDER BY version;')}));
 sql(a.home,`UPDATE thread_goals SET tokens_used=37,time_used_seconds=19 WHERE thread_id='${id}';`);
 const before=JSON.parse(sql(a.home,`SELECT json_object('thread_id',thread_id,'goal_id',goal_id,'objective',objective,'status',status,'token_budget',token_budget,'tokens_used',tokens_used,'time_used_seconds',time_used_seconds,'created_at_ms',created_at_ms,'updated_at_ms',updated_at_ms) FROM thread_goals WHERE thread_id='${id}';`));
 assert.equal(before.tokens_used,37);assert.equal(before.time_used_seconds,19);
 a=await server(a.home);await a.request('thread/resume',{threadId:id});const sourceGoal=(await a.request('thread/goal/get',{threadId:id})).goal;assert.equal(sourceGoal.tokensUsed,37);assert.equal(sourceGoal.timeUsedSeconds,19);
 if(returnOriginal||checkRetirement)await a.request('thread/archive',{threadId:id});await a.stop();
 if(restoreGoal)sql(a.home,`INSERT OR IGNORE INTO thread_goal_continuation_deferrals(thread_id) VALUES ('${id}');`);
 const firstRollout=returnOriginal||checkRetirement ? await archivedRollout(a.home,id):source.path;
 const b=await server(root+'/b'),destination=path.join(b.home,path.relative(a.home,source.path));await mkdir(path.dirname(destination),{recursive:true});await copyFile(firstRollout,destination);assert.notEqual((await stat(firstRollout)).ino,(await stat(destination)).ino);
 let unselected,unselectedGoal;
 if(restoreGoal){
  unselected=(await b.request('thread/start',{cwd:root,approvalPolicy:'never',sandbox:'read-only'})).thread.id;
  await b.request('thread/goal/set',{threadId:unselected,objective:'Unselected owned Goal',status:'paused',tokenBudget:999,origin:'user'});
  unselectedGoal=(await b.request('thread/goal/get',{threadId:unselected})).goal;
  assert.equal(JSON.parse(execFileSync(transfer,[a.home,b.home,id],{encoding:'utf8',timeout:10000})).verified,true);
 }
 const resumed=await b.request('thread/resume',{threadId:id,path:destination}),target=(await b.request('thread/read',{threadId:resumed.thread.id,includeTurns:true})).thread;
 if(checkSettings){
  assert.equal(resumed.reasoningEffort,'high');assert.equal(resumed.serviceTier,'flex');
  assert.deepEqual(resumed.disabledPluginIds,disabledPlugins);assert.deepEqual(resumed.runtimeWorkspaceRoots,[workspaceRoot]);
 }
 for(const key of ['model','modelProvider','cwd','approvalPolicy','approvalsReviewer','sandbox','serviceTier','reasoningEffort'])if(Object.hasOwn(start,key))assert.deepEqual(resumed[key],start[key],key+' must survive first resume');
 const goal=(await b.request('thread/goal/get',{threadId:id})).goal;
 const report={verified:true,actualInstalledCodex:version,ownedHomes:2,realCredentialsUsed:false,existingSessionsTouched:false,providerRequests:requests,sameUUID:target.id===id,nonemptyHistoryPreserved:JSON.stringify(source.turns)===JSON.stringify(target.turns),sourceGoal:{tokensUsed:sourceGoal.tokensUsed,timeUsedSeconds:sourceGoal.timeUsedSeconds,tokenBudget:sourceGoal.tokenBudget,status:sourceGoal.status},destinationGoal:goal,goalPreserved:JSON.stringify(goal)===JSON.stringify(sourceGoal),independentRollout:true,settings:{model:resumed.model,modelProvider:resumed.modelProvider,approvalPolicy:resumed.approvalPolicy,sandbox:resumed.sandbox},gap:goal===null?'Public rollout resume does not import the Goal record. Exact goal_id/counters require a separately validated transfer contract.':null};
 assert.ok(report.sameUUID);assert.ok(report.nonemptyHistoryPreserved);
 if(requireGoal)assert.deepEqual(goal,sourceGoal,'Cross-home resume must preserve the exact nonzero Goal state');
 else assert.equal(goal,null,'Reassess preservation contract if public resume starts importing Goals');
 if(restoreGoal){
  assert.deepEqual((await b.request('thread/goal/get',{threadId:unselected})).goal,unselectedGoal);
  const rowJSON=home=>sql(home,`SELECT json_object('thread_id',thread_id,'goal_id',goal_id,'objective',objective,'status',status,'token_budget',token_budget,'tokens_used',tokens_used,'time_used_seconds',time_used_seconds,'created_at_ms',created_at_ms,'updated_at_ms',updated_at_ms) FROM thread_goals WHERE thread_id='${id}';`);
  assert.equal(rowJSON(b.home),rowJSON(a.home),'Native resume must retain exact Goal instance and millisecond counters');
  console.error(JSON.stringify({stage:'first-transfer',sameUUID:true,exactGoalRow:true,publicGoal:true,unselectedGoal:true}));
  let expectedReturnTurns=source.turns;
  if(checkRetirement){
   assert.equal(JSON.parse(execFileSync(transfer,['--record-retirement',a.home,b.home,id,firstRollout],{encoding:'utf8',timeout:10000})).nativeRetirementWitnessed,true);
   const originalRow=rowJSON(a.home),originalHistory=await readFile(firstRollout);
   const receipt=JSON.parse(execFileSync(transfer,['--backup-retired',a.home,b.home,id],{encoding:'utf8',timeout:10000}));
   assert.equal(receipt.retiredBackupVerified,true);assert.equal(receipt.goalReplacementPerformed,false);
   const recovered=JSON.parse(execFileSync(transfer,['--verify-retired-backup',root],{encoding:'utf8',timeout:10000}));
   assert.equal(recovered.backupSurvivedProcessExit,true);assert.equal(recovered.cancelledReservationRejected,true);
   assert.equal(rowJSON(a.home),originalRow);assert.deepEqual(await readFile(firstRollout),originalHistory);
   Object.assign(report,{nativeRetirementAndIndependentBackup:true,backupPreservedOriginalGoalAndHistory:true,backupVerifiedAfterProcessExit:true,cancelledBackupDoesNotAuthorizeReplacement:true});
  }
  let nativeResumeResult,nativeRestoreResult;
  if(returnOriginal&&checkRetirement){
   const follow=await b.request('turn/start',{threadId:id,input:[{type:'text',text:'Owned new history created only in home B.',text_elements:[]}]});
   const finished=await b.wait('turn/completed',p=>p.threadId===id&&p.turn.id===follow.turn.id);
   assert.equal(finished.turn.status,'completed');
   expectedReturnTurns=(await b.request('thread/read',{threadId:id,includeTurns:true})).thread.turns;
   assert.ok(expectedReturnTurns.length>source.turns.length,'Direct return must preserve newer B history, not merely reopen the stale A archive');
   console.error(JSON.stringify({stage:'direct-return-new-history',newerBHistory:true}));
  }
  if(returnCleared)await b.request('thread/goal/clear',{threadId:id,origin:'user'});
  const unsubscribed=await b.request('thread/unsubscribe',{threadId:id});assert.equal(unsubscribed.status,'unsubscribed');
  if(process.argv.includes('--archive-source'))await b.request('thread/archive',{threadId:id});
  const end=Date.now()+5000;let loaded;
  do{loaded=(await b.request('thread/loaded/list',{})).data;if(!loaded.includes(id))break;await new Promise(r=>setTimeout(r,25));}while(Date.now()<end);
  assert.ok(!loaded.includes(id),'Selected writer must actually unload before return transfer');assert.ok(loaded.includes(unselected));
  const files=execFileSync('/usr/sbin/lsof',['-nP','-p',String(b.pid),'-Fn'],{encoding:'utf8',timeout:10000});
  assert.ok(!files.split('\n').some(line=>line.startsWith('n')&&line.includes(id)),'Selected rollout writer must actually close and flush');
  let expectedReturnGoal=sourceGoal;
  if(returnOriginal){
   if(returnCleared){expectedReturnGoal=null;assert.equal(rowJSON(b.home),'');}
   else{sql(b.home,`UPDATE thread_goals SET tokens_used=73,time_used_seconds=29 WHERE thread_id='${id}';`);expectedReturnGoal={...sourceGoal,tokensUsed:73,timeUsedSeconds:29};}
  }
  const expectedReturnRow=rowJSON(b.home);
  const c=await server(returnOriginal?a.home:root+'/c'),third=(await c.request('thread/start',{cwd:root,approvalPolicy:'never',sandbox:'read-only'})).thread.id;
  await c.request('thread/goal/set',{threadId:third,objective:'Third home unselected Goal',status:'paused',origin:'user'});
  const thirdGoal=(await c.request('thread/goal/get',{threadId:third})).goal;
  const relative=path.relative(a.home,source.path);assert.ok(!relative.startsWith('..'));
  let closedRollout=target.path;
  if(process.argv.includes('--archive-source')){
   closedRollout=await archivedRollout(b.home,id);
  }
  const returning=path.join(c.home,relative);await mkdir(path.dirname(returning),{recursive:true});
  if(!returnOriginal)await copyFile(closedRollout,returning);
  if(returnOriginal)console.error(JSON.stringify({stage:'return-to-original-home',existingRetiredGoal:true,oldTokens:37,newTokens:returnCleared?null:73}));
  if(returnOriginal&&checkRetirement){
   const result=JSON.parse(execFileSync(transfer,['--return-goal',b.home,c.home,id,closedRollout],{encoding:'utf8',timeout:10000}));
   assert.equal(result.exactGoalReturned,true);assert.equal(result.nativeOwnershipCommitted,false);
   assert.equal(result.latestHistoryReturned,true);
   console.error(JSON.stringify({stage:'goal-storage-return',exactGoalReturned:true,nativeOwnershipCommitted:false,clearedSource:returnCleared}));
   // The parent owns the only stdio connection and constructed all root-only
   // threads. This is not a discovery implementation for preexisting TUIs.
   const nativeCounts={'thread/unarchive':0,'thread/resume':0},dropped=new Set();let controllerRestarts=0;
   const nativeAttempt=()=>new Promise((resolve,reject)=>{
    const helper=spawn(transfer,['--native-restore',b.home,c.home,id],{stdio:['pipe','pipe','pipe']});
    let stderr='',final,error;
    helper.stderr.on('data',bytes=>stderr+=bytes);
    const send=value=>helper.stdin.write(JSON.stringify(value)+'\n');
    helper.stdin.on('error',()=>{});
    createInterface({input:helper.stdout}).on('line',line=>{void(async()=>{
     const message=JSON.parse(line);
     if(message.type==='result'){final=message.result;return;}
     assert.equal(message.type,'rpc');assert.equal(message.params.threadId,id);
     try {
      let result;
      assert.equal(c.alive(),true);
      if(message.method==='owned/observe'){
       assert.equal((await c.request('account/read',{refreshToken:false})).account,null);
       const thread=(await c.request('thread/read',{threadId:id,includeTurns:true})).thread;
       const loadedIDs=(await c.request('thread/loaded/list',{limit:100})).data;
       assert.equal(c.alive(),true);
       result={serverID:c.identity,thread,loadedIDs,ownedCompleteScope:true,settingsAcknowledgment:nativeResumeResult??null};
      }else{
       assert.ok(['thread/unarchive','thread/resume'].includes(message.method));
       nativeCounts[message.method]++;
       result=await c.request(message.method,message.params);
       assert.equal(result.thread.id,id);
       if(message.method==='thread/resume')nativeResumeResult=result;
       if(crashNativeAcks&&!dropped.has(message.method)){
        dropped.add(message.method);send({id:message.id,ownedInjectedDrop:true});return;
       }
      }
      send({id:message.id,result});
     }catch(problem){error=problem;send({id:message.id,error:{message:'Owned native bridge request failed'}});}
    })().catch(problem=>{error=problem;helper.kill('SIGTERM');});});
    const timer=setTimeout(()=>helper.kill('SIGTERM'),90000);
    helper.once('error',problem=>{clearTimeout(timer);reject(problem);});
    helper.once('exit',code=>{clearTimeout(timer);if(error)return reject(error);if(code===52&&crashNativeAcks)return resolve({restart:true});if(code!==0||!final)return reject(Error(stderr||'Owned native restoration bridge failed'));resolve(final);});
    send({serverID:c.identity,sessionRelativePath:relative,history:expectedReturnTurns,settings:resumed});
   });
   for(let attempt=0;attempt<3;attempt++){
    nativeRestoreResult=await nativeAttempt();
    if(!nativeRestoreResult.restart)break;
    controllerRestarts++;
   }
   assert.ok(!nativeRestoreResult.restart,'Owned controller never reached verified completion');
   assert.equal(nativeCounts['thread/unarchive'],1);assert.equal(nativeCounts['thread/resume'],1);
   if(crashNativeAcks){assert.equal(controllerRestarts,2);assert.equal(dropped.size,2);}
   Object.assign(nativeRestoreResult,{unarchiveRequests:nativeCounts['thread/unarchive'],resumeRequests:nativeCounts['thread/resume'],controllerRestarts});
   assert.equal(nativeRestoreResult.journaledNativeRestore,true);
   assert.equal(nativeRestoreResult.unarchiveRequests,1);assert.equal(nativeRestoreResult.resumeRequests,1);
  }else assert.equal(JSON.parse(execFileSync(transfer,[b.home,c.home,id],{encoding:'utf8',timeout:10000})).verified,true);
  const last=nativeResumeResult||await c.request('thread/resume',{threadId:id,path:returning});assert.equal(last.thread.id,id);
  if(checkSettings){
   assert.equal(last.reasoningEffort,'high');assert.equal(last.serviceTier,'flex');
   assert.deepEqual(last.disabledPluginIds,disabledPlugins);assert.deepEqual(last.runtimeWorkspaceRoots,[workspaceRoot]);
  }
  const returned=(await c.request('thread/read',{threadId:id,includeTurns:true})).thread;assert.deepEqual(returned.turns,expectedReturnTurns,'Return transfer must retain all latest user/assistant history');
  for(const key of ['model','modelProvider','cwd','approvalPolicy','approvalsReviewer','sandbox','serviceTier','reasoningEffort'])if(Object.hasOwn(start,key))assert.deepEqual(last[key],start[key],key+' must survive return resume');
  assert.deepEqual((await c.request('thread/goal/get',{threadId:id})).goal,expectedReturnGoal);assert.equal(rowJSON(c.home),expectedReturnRow);
  assert.equal(Number(sql(c.home,`SELECT COUNT(*) FROM thread_goal_continuation_deferrals WHERE thread_id='${id}';`)),Number(sql(b.home,`SELECT COUNT(*) FROM thread_goal_continuation_deferrals WHERE thread_id='${id}';`)),'Native resume must retain the current source deferral, including its absence');
  assert.deepEqual((await b.request('thread/goal/get',{threadId:unselected})).goal,unselectedGoal);
  assert.deepEqual((await c.request('thread/goal/get',{threadId:third})).goal,thirdGoal);
  assert.ok((await b.request('thread/loaded/list',{})).data.includes(unselected));process.kill(b.pid,0);
  if(returnOriginal&&checkRetirement){
   assert.equal(nativeRestoreResult.destinationOwnershipCommitted,true);
   Object.assign(report,{retiredOwnerReturnVerified:true,journaledArchiveReturn:true,journaledNativeRestore:true,unarchiveRequests:1,resumeRequests:1,controllerRestarts:nativeRestoreResult.controllerRestarts,clearedGoalNotResurrected:returnCleared,returnGoal:expectedReturnGoal});
  }
  Object.assign(report,{ownedHomes:returnOriginal?2:3,goalPreserved:true,exactGoalInstanceAndMilliseconds:true,roundTrip:true,returnedToOriginalHome:returnOriginal,roundTripHistoryAndSettings:true,unselectedGoalAndServerPreserved:true,sourceWriterClosedBeforeReturn:true,deferralAfterNativeResume:Number(sql(c.home,`SELECT COUNT(*) FROM thread_goal_continuation_deferrals WHERE thread_id='${id}';`)),productMigrationEnabled:false});report.gap=null;
  if(checkClearedSlot){
   await c.request('thread/goal/clear',{threadId:id,origin:'user'});
   assert.equal((await c.request('thread/goal/get',{threadId:id})).goal,null);
   assert.equal(JSON.parse(execFileSync(transfer,['--cleared-slot',c.home,id],{encoding:'utf8',timeout:10000})).clearedGoalSlotWitnessed,true);
   await c.request('thread/resume',{threadId:id});
   assert.equal((await c.request('thread/goal/get',{threadId:id})).goal,null);
   assert.equal(JSON.parse(execFileSync(transfer,['--cleared-slot',c.home,id],{encoding:'utf8',timeout:10000})).verified,true);
   assert.deepEqual((await c.request('thread/goal/get',{threadId:third})).goal,thirdGoal);
   Object.assign(report,{clearedGoalSlotWitnessed:true,clearedGoalRetainedAfterResume:true});
  }
  if(checkSettings){
   const follow=await c.request('turn/start',{threadId:id,input:[{type:'text',text:'Owned settings continuation only.',text_elements:[]}]});
   const finished=await c.wait('turn/completed',p=>p.threadId===id&&p.turn.id===follow.turn.id);
   assert.equal(finished.turn.status,'completed',JSON.stringify(finished.turn.error));
   assert.equal(requestBodies.length,returnOriginal&&checkRetirement?3:2);checkRequest(requestBodies.at(-1));
   Object.assign(report,{providerRequests:requests,nondefaultSettings:{reasoning:true,serviceTier:true,baseInstructions:true,developerInstructions:true,disabledPluginIDs:true,runtimeWorkspaceRoots:true},settingsInferenceRequests:requestBodies.length});
  }
 }
 console.log(JSON.stringify(report));
}finally{
 for(const child of children)if(child.exitCode===null&&child.signalCode===null){try{process.kill(-child.pid,'SIGTERM')}catch{}await new Promise(r=>{child.once('close',r);setTimeout(r,1000)});if(child.exitCode===null&&child.signalCode===null){try{process.kill(-child.pid,'SIGKILL')}catch{}}}
 provider.closeAllConnections();await new Promise(r=>provider.close(r));await rm(root,{recursive:true,force:true});
}
