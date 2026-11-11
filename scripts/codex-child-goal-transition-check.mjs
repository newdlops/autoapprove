// Real isolated child + Goal; a loopback model only, no production sessions/auth.
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import {mkdtemp,mkdir,writeFile,readFile,copyFile,chmod,stat,rm,realpath,cp} from 'node:fs/promises';
import {spawn,execFileSync,execFile} from 'node:child_process';
import {createHash} from 'node:crypto';
import {promisify} from 'node:util';
import {createRequire} from 'node:module';
const option=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3);
const managedControl=process.argv.includes('--managed-control');
const daemonPackage=option('daemon-package'),execFileAsync=promisify(execFile);
assert.ok(!daemonPackage||!process.argv.includes('--app-server-binary'),'Daemon test requires the complete CLI');
const completePackage=process.argv.includes('--complete-package');
assert.ok(!completePackage||daemonPackage,'Complete package check requires --daemon-package');
assert.ok(option('codex'),'Provide --codex=/absolute/native/codex');
const require=createRequire(import.meta.url),{ws:WS}=require(path.join(path.dirname(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||require.resolve('playwright')),'../playwright-core/lib/utilsBundle.js'));
const root=await mkdtemp('/private/tmp/aa-child-goal-'),home=root+'/home',socket=home+'/app-server-control/app-server-control.sock';
const pending=new Map(),streams=new Set();let processChild,ws,seq=0,childID,rootID,childTurnID,posts=0,stderr='';
let daemonBinary,daemonEnvironment,daemonAttempted=false,daemonVerified=false;
const sha256=bytes=>createHash('sha256').update(bytes).digest('hex');
async function daemonCommand(action){
 const {stdout}=await execFileAsync(daemonBinary,['app-server','daemon',action],{cwd:root,env:daemonEnvironment,timeout:30000,maxBuffer:1024*1024});
 return JSON.parse(stdout);
}
const wait=ms=>new Promise(r=>setTimeout(r,ms));
async function until(test,label){for(let i=0;i<200;i++){if(await test())return;await wait(100);}throw Error('Owned fixture timeout: '+label+' '+stderr.slice(-300));}
function rpc(method,params){return new Promise((resolve,reject)=>{
 const id=++seq,timer=setTimeout(()=>{pending.delete(id);reject(Error('Owned fixture RPC timeout: '+method));},20000);
 pending.set(id,{resolve:value=>{clearTimeout(timer);resolve(value);},reject:error=>{clearTimeout(timer);reject(error);}});
 ws.send(JSON.stringify({id,method,params}),error=>{if(error){const request=pending.get(id);pending.delete(id);request?.reject(error);}});
});}
async function swiftGoal(action,expected){
 const args=[home,rootID,root,childID,action,...(expected?[JSON.stringify(expected)]:[])];
 const child=spawn(option('swift-helper'),args,{stdio:['ignore','pipe','pipe']});let out='',err='';
 child.stdout.on('data',bytes=>out+=bytes);child.stderr.on('data',bytes=>err=(err+bytes).slice(-2000));
 const timer=setTimeout(()=>child.kill('SIGKILL'),25000);
 let code;try{code=await new Promise((resolve,reject)=>{child.once('exit',resolve);child.once('error',reject);});}finally{clearTimeout(timer);}
 assert.equal(code,0,err);return JSON.parse(out);
}
const api=http.createServer(async(req,res)=>{
 let raw='';for await(const chunk of req)raw+=chunk;
 const data=JSON.parse(raw),input=JSON.stringify(data.input),isChild=input.includes('OWNED_GOAL_CHILD')&&!input.includes('owned-spawn-call');
 const all=(data.tools||[]).flatMap(t=>t.type==='namespace'?(t.tools||[]).map(f=>({...f,namespace:t.name})):[t]);
 res.writeHead(200,{'Content-Type':'text/event-stream'});streams.add(res);res.on('close',()=>streams.delete(res));
 const rid='owned-goal-'+(++posts),emit=v=>res.write('data: '+JSON.stringify(v)+'\n\n');
 emit({type:'response.created',response:{id:rid,status:'in_progress',output:[]}});
 if(isChild&&input.includes('owned-goal-call')){const timer=setInterval(()=>{if(!res.destroyed)res.write(': owned heartbeat\n\n');},200);res.on('close',()=>clearInterval(timer));return;}
 const name=isChild?'create_goal':'spawn_agent',spec=all.find(t=>t.name===name);
 let item;
 if(isChild)item={type:'function_call',id:'owned-goal-item',call_id:'owned-goal-call',name,...(spec?.namespace?{namespace:spec.namespace}:{}),arguments:JSON.stringify({objective:'Owned child account transition Goal',token_budget:1234})};
 else if(!input.includes('owned-spawn-call'))item={type:'function_call',id:'owned-spawn-item',call_id:'owned-spawn-call',name,...(spec?.namespace?{namespace:spec.namespace}:{}),arguments:JSON.stringify({task_name:'goal_fixture',message:'OWNED_GOAL_CHILD',fork_turns:'none'})};
 else item={id:'owned-done-'+posts,type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:'Owned parent is waiting.'}]};
 emit({type:'response.output_item.added',output_index:0,item});emit({type:'response.output_item.done',output_index:0,item});emit({type:'response.completed',response:{id:rid,status:'completed',output:[item],usage:{input_tokens:1,output_tokens:1,total_tokens:2}}});res.end();
});
try {
 await mkdir(home+'/app-server-control',{recursive:true});await new Promise((resolve,reject)=>{api.once('error',reject);api.listen(0,'127.0.0.1',resolve);});
 await writeFile(home+'/config.toml',`model="fixture-model"\nmodel_provider="fixture"\napproval_policy="never"\nsandbox_mode="read-only"\ncheck_for_update_on_startup=false\ncli_auth_credentials_store="file"\n[model_providers.fixture]\nname="Fixture"\nbase_url="http://127.0.0.1:${api.address().port}/v1"\nwire_api="responses"\nrequires_openai_auth=false\n[features]\nmulti_agent_v2=true\ngoals=true\n[analytics]\nenabled=false\n`);
 const binary=root+'/owned-goal-server';await copyFile(option('codex'),binary);await chmod(binary,0o700);
 const env={HOME:root,CODEX_HOME:home,PATH:'/usr/bin:/bin',NO_COLOR:'1',HTTP_PROXY:'http://127.0.0.1:9',HTTPS_PROXY:'http://127.0.0.1:9',NO_PROXY:'127.0.0.1,localhost'};
 if(daemonPackage){
  // Assemble only fixture package files. Never use or change the source home,
  // daemon settings, auth, or selected release. The real installer copies this
  // package into the owned home, just as it does for a fresh login group.
  const metadata=JSON.parse(await readFile(path.join(daemonPackage,'codex-package.json'),'utf8'));
  assert.equal(metadata.version,'0.167.1');assert.equal(metadata.target,'aarch64-apple-darwin');
  const fixturePackage=root+'/fixture-package';
  if(completePackage){
   assert.equal(sha256(await readFile(path.join(daemonPackage,'bin/codex'))),sha256(await readFile(binary)),'Complete package must contain the tested CLI');
   await cp(daemonPackage,fixturePackage,{recursive:true,errorOnExist:true,force:false,verbatimSymlinks:true});
   daemonBinary=fixturePackage+'/bin/codex';
  }else{
   await mkdir(fixturePackage+'/bin',{recursive:true});await mkdir(fixturePackage+'/codex-path');
   for(const file of ['bin/codex-code-mode-host','codex-path/rg']){
    await copyFile(path.join(daemonPackage,file),path.join(fixturePackage,file));await chmod(path.join(fixturePackage,file),0o700);
   }
   daemonBinary=fixturePackage+'/bin/codex';await copyFile(binary,daemonBinary);await chmod(daemonBinary,0o700);
   await writeFile(fixturePackage+'/codex-package.json',JSON.stringify({layoutVersion:1,version:metadata.version,target:metadata.target,entrypoint:'bin/codex',pathDir:'codex-path'}));
  }
  await mkdir(home+'/app-server-daemon',{recursive:true});
  await writeFile(home+'/app-server-daemon/settings.json',JSON.stringify({shutdownGraceSeconds:0,updater:{autoUpdateEnabled:false}}));
  daemonEnvironment=env;daemonAttempted=true;
  assert.equal((await daemonCommand('start')).status,'started');
  const version=await daemonCommand('version');
  assert.equal(version.status,'running');assert.equal(version.cliVersion,'0.167.1');assert.equal(version.appServerVersion,'0.167.1');
  assert.equal(version.managedCodexVersion,'0.167.1');
  const installed=await realpath(version.managedCodexPath);
  assert.ok(installed.startsWith(home+'/packages/app-server-daemon/releases/'));
  assert.equal(sha256(await readFile(installed)),sha256(await readFile(binary)),'Daemon must use the modified executable');
  daemonVerified=true;
 }else{
  processChild=spawn(binary,[...(process.argv.includes('--app-server-binary')?[]:['app-server']),'--listen','unix://'+socket],{cwd:root,env,stdio:['ignore','ignore','pipe']});processChild.stderr.on('data',c=>stderr=(stderr+c).slice(-2000));
 }
 await until(async()=>{try{return(await stat(socket)).isSocket();}catch{return false;}},'socket');
 ws=new WS('ws://localhost/',{createConnection:()=>net.connect(socket)});await new Promise((r,j)=>{ws.once('open',r);ws.once('error',j);});
 ws.on('message',bytes=>{const m=JSON.parse(bytes);if(m.id!==undefined&&!m.method){const p=pending.get(m.id);pending.delete(m.id);if(p)m.error?p.reject(Object.assign(Error(m.error.message),m.error)):p.resolve(m.result);return;}if(m.method==='thread/started'&&m.params.thread.parentThreadId){childID=m.params.thread.id;}if(m.method==='turn/started'&&m.params.threadId===childID)childTurnID=m.params.turn.id;});
 await rpc('initialize',{clientInfo:{name:'owned-child-goal',version:'1'},capabilities:{experimentalApi:true}});ws.send(JSON.stringify({method:'initialized'}));
 rootID=(await rpc('thread/start',{cwd:root,approvalPolicy:'never',sandbox:'read-only'})).thread.id;
 await rpc('turn/start',{threadId:rootID,input:[{type:'text',text:'Create the owned child task and its Goal for this isolated test.'}]});
 await until(async()=>{
  const ids=(await rpc('thread/loaded/list',{})).data;
  for(const id of ids){if(id===rootID)continue;const row=(await rpc('thread/read',{threadId:id,includeTurns:false})).thread;if(row.parentThreadId===rootID){childID=id;const turns=(await rpc('thread/turns/list',{threadId:id,limit:1,itemsView:'notLoaded',sortDirection:'desc'})).data;childTurnID=turns[0]?.id;}}
  return Boolean(childID&&childTurnID);
 },'child');
 let before;await until(async()=>{before=(await rpc('thread/goal/get',{threadId:childID})).goal;return before?.status==='active';},'active child Goal');
 assert.match(childID,/^[0-9a-f-]{36}$/);
 const goalIdentity=()=>execFileSync('/usr/bin/sqlite3',[home+'/goals_1.sqlite',"SELECT goal_id FROM thread_goals WHERE thread_id='"+childID+"';"],{encoding:'utf8'}).trim();
 const originalGoalID=goalIdentity();assert.ok(originalGoalID);
 const meta=(await rpc('thread/read',{threadId:childID,includeTurns:false})).thread;assert.equal(meta.canAcceptDirectInput,false);
 let rejected;
 try{const paused=(await rpc('thread/goal/set',{threadId:childID,status:'paused',origin:'automatic'})).goal;assert.equal(paused.status,'paused');assert.equal(paused.objective,before.objective);assert.equal(paused.tokenBudget,before.tokenBudget);assert.ok(paused.tokensUsed>=before.tokensUsed);}
 catch(error){rejected=error;}
 if(managedControl){
  // The ordinary direct-input restriction must remain intact in the managed build.
  assert.equal(rejected?.code,-32600);assert.match(rejected.message,/direct app-server input is not allowed/);
  const address={threadId:childID,parentThreadId:rootID};
  const inspect=()=>rpc('autoapprove/thread/goal/read',address);
  const control=(expected,action)=>rpc('autoapprove/thread/goal/control',{...address,expected,action});
  const initial=await inspect();assert.equal(initial.identity.goalId,originalGoalID);
  const swiftInitial=option('swift-helper')?await swiftGoal('read'):undefined;
  if(swiftInitial){assert.equal(swiftInitial.goal.instanceID,originalGoalID);assert.ok(swiftInitial.turnID,'Swift must observe the active child turn');}
  const assertRejected=async(action)=>{await assert.rejects(action,e=>e.code===-32600);assert.equal(goalIdentity(),originalGoalID);assert.equal((await inspect()).goal.status,'active');};
  await assertRejected(()=>rpc('autoapprove/thread/goal/read',{...address,parentThreadId:childID}));
  await assertRejected(()=>control({...initial.identity,goalId:'replaced-goal'},'pause'));
  await assertRejected(()=>control({...initial.identity,objective:'different objective'},'pause'));
  await assertRejected(()=>control({...initial.identity,tokenBudget:1235},'pause'));
  const parentBefore=(await rpc('thread/turns/list',{threadId:rootID,limit:10,itemsView:'notLoaded',sortDirection:'desc'})).data.map(t=>t.id);
  const swiftPaused=swiftInitial?await swiftGoal('pause',swiftInitial):undefined;
  const paused=swiftPaused?{goal:swiftPaused.goal,goalId:swiftPaused.goal.instanceID}:await control(initial.identity,'pause');assert.equal(paused.goal.status,'paused');assert.equal(paused.goalId,originalGoalID);
  assert.equal(paused.goal.objective,before.objective);assert.equal(paused.goal.tokenBudget,before.tokenBudget);
  assert.ok(paused.goal.tokensUsed>=before.tokensUsed);assert.ok(paused.goal.timeUsedSeconds>=before.timeUsedSeconds);
  await assert.rejects(()=>control(initial.identity,'pause'),e=>e.code===-32600);
  // Goal continuation is paused first; the existing exact-turn interrupt then
  // stops in-flight work. No new user turn is injected into the child.
  const pausedTurnID=childTurnID;
  if(swiftPaused)assert.equal(swiftPaused.executionState,'idle','Swift pause must interrupt and confirm the observed turn');
  else await rpc('turn/interrupt',{threadId:childID,turnId:pausedTurnID});
  await until(async()=> (await rpc('thread/read',{threadId:childID,includeTurns:false})).thread.status.type==='idle','paused child idle');
  const atRest=await inspect(),postsAtRest=posts;
  assert.equal(atRest.goal.status,'paused');await wait(1200);assert.equal(posts,postsAtRest,'Paused Goal must not autonomously start another turn');
  const swiftRest=swiftInitial?await swiftGoal('read'):undefined;
  const swiftResumed=swiftRest?await swiftGoal('resume',swiftRest):undefined;
  const resumed=swiftResumed?{goal:swiftResumed.goal,goalId:swiftResumed.goal.instanceID}:await control(atRest.identity,'resume');assert.equal(resumed.goal.status,'active');
  assert.equal(resumed.goalId,originalGoalID);assert.equal(goalIdentity(),originalGoalID);
  await until(async()=>{const turns=(await rpc('thread/turns/list',{threadId:childID,limit:1,itemsView:'notLoaded',sortDirection:'desc'})).data;return Boolean(turns[0]?.id&&turns[0].id!==pausedTurnID&&posts>postsAtRest);},'same child Goal resumed');
  const after=await inspect();assert.equal(after.identity.goalId,originalGoalID);assert.equal(after.goal.objective,before.objective);assert.equal(after.goal.tokenBudget,before.tokenBudget);
  assert.ok(after.goal.tokensUsed>=atRest.goal.tokensUsed);assert.ok(after.goal.timeUsedSeconds>=atRest.goal.timeUsedSeconds);
  assert.deepEqual((await rpc('thread/turns/list',{threadId:rootID,limit:10,itemsView:'notLoaded',sortDirection:'desc'})).data.map(t=>t.id),parentBefore);
  console.log(JSON.stringify({verified:true,realV2Child:true,pausedAndResumed:true,swiftTransportVerified:Boolean(swiftInitial),managedDaemonVerified:daemonVerified,completePackageVerified:completePackage&&daemonVerified,goalIdentityAndBudgetRetained:true,accountingMonotonic:true,parentTurnsUnchanged:true,staleIdentityRejected:true,ordinaryDirectInputStillRejected:true,existingSessionsTouched:false}));
 }
 else if(process.argv.includes('--expect-rejection')){assert.equal(rejected?.code,-32600);assert.match(rejected.message,/direct app-server input is not allowed/);console.log(JSON.stringify({verified:true,originalDefectReproduced:true,realV2Child:true,activeGoal:true,managedDaemonVerified:daemonVerified,existingSessionsTouched:false}));}
 else {assert.equal(rejected,undefined,rejected?.message);assert.equal(goalIdentity(),originalGoalID);console.log(JSON.stringify({verified:true,realV2Child:true,pausedWithoutDirectTurnInput:true,goalIdentityAndBudgetRetained:true,existingSessionsTouched:false}));}
} finally {
 for(const request of pending.values())request.reject(Error('Owned fixture closed'));pending.clear();
 for(const res of streams)res.destroy();ws?.terminate();
 if(processChild&&processChild.exitCode===null){const done=new Promise(r=>processChild.once('exit',r));processChild.kill('SIGTERM');const timer=setTimeout(()=>processChild.kill('SIGKILL'),3000);await done;clearTimeout(timer);}
 api.closeAllConnections();api.close();
 // Keep the owned home available for recovery if stopping its daemon fails.
 if(daemonAttempted){const stopped=await daemonCommand('stop');assert.ok(['stopped','notRunning'].includes(stopped.status),JSON.stringify(stopped));}
 await rm(root,{recursive:true,force:true});
}
