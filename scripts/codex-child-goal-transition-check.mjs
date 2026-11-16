// Real isolated child + Goal; a loopback model only, no production sessions/auth.
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import {mkdtemp,mkdir,writeFile,readFile,copyFile,chmod,stat,rm,realpath,cp} from 'node:fs/promises';
import {spawn,execFileSync,execFile} from 'node:child_process';
import {createHash,randomBytes,randomUUID} from 'node:crypto';
import {promisify} from 'node:util';
import {createRequire} from 'node:module';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3);
const managedControl=process.argv.includes('--managed-control');
const parentControl=process.argv.includes('--parent-goal-control');
const localResumeProbe=process.argv.includes('--local-goal-resume-probe');
assert.ok(!localResumeProbe||parentControl,'Local state experiment requires parent-mediated pause');
const attachResumeProbe=process.argv.includes('--resume-via-attach-probe');
assert.ok(!attachResumeProbe||localResumeProbe,'Attachment resume requires the local Goal experiment');
const engineResume=process.argv.includes('--engine-resume');
assert.ok(!engineResume||attachResumeProbe,'Engine resume requires the official attachment path');
const enginePause=process.argv.includes('--engine-pause');
const accountGoal=process.argv.includes('--account-goal');
const accountReproduce=process.argv.includes('--account-reproduce');
assert.ok(!accountReproduce||accountGoal,'Reproduction requires the account adapter check');
assert.ok(!enginePause||engineResume,'Engine pause is tested together with engine resume');
const compatibilityEntry=process.argv.includes('--compatibility-entry');
assert.ok(!compatibilityEntry||enginePause,'Compatibility entry is tested with the complete engine pause/resume flow');
const pauseCrash=option('pause-crash');
assert.ok(!pauseCrash||(['deferred','settled','paused','confirmed'].includes(pauseCrash)&&enginePause&&!compatibilityEntry),'Owned pause crash requires the requested engine pause/resume flow');
const swiftLocalState=process.argv.includes('--swift-local-state');
assert.ok(!swiftLocalState||localResumeProbe,'Swift state checks require the local Goal experiment');
assert.ok(!parentControl||!managedControl,'Parent-mediated check uses the unmodified official runtime');
const selectedAdmission=process.argv.includes('--selected-admission');
assert.ok(!selectedAdmission||managedControl,'Selected admission requires --managed-control');
const daemonPackage=option('daemon-package'),execFileAsync=promisify(execFile);
assert.ok(!daemonPackage||!process.argv.includes('--app-server-binary'),'Daemon test requires the complete CLI');
const completePackage=process.argv.includes('--complete-package');
assert.ok(!completePackage||daemonPackage,'Complete package check requires --daemon-package');
assert.ok(option('codex'),'Provide --codex=/absolute/native/codex');
const require=createRequire(import.meta.url),WS=process.env.AUTOAPPROVE_WEBSOCKET_MODULE
 ?require(process.env.AUTOAPPROVE_WEBSOCKET_MODULE)
 :require(path.join(path.dirname(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||require.resolve('playwright')),'../playwright-core/lib/utilsBundle.js')).ws;
const root=await mkdtemp('/private/tmp/aa-child-goal-'),home=root+'/home',socket=home+'/app-server-control/app-server-control.sock';
let swiftHelper=option('swift-helper');
let localStateHelper;
let engineResumeHelper,engineResumeReport;
let accountHelper;
let enginePauseReport,parentHeld=false;
const pending=new Map(),streams=new Set();let processChild,ws,seq=0,childID,rootID,childTurnID,posts=0,stderr='';
let daemonBinary,daemonEnvironment,daemonAttempted=false,daemonVerified=false;
let releaseChild,childPauseObserved=false,childResumeObserved=false,childCreateRejected=false;
let localResumeCalls=0,localContinuationObserved=false;
let localGoalRestored=false;
let selectedClient,selectedGeneration,selectedLease,selectedBuffer='',selectedPending;
async function selectedCall(op,extra={}){
 const nonce=randomBytes(16).toString('hex');
 const request={op,nonce,...extra,...(selectedGeneration?{serverGeneration:selectedGeneration}:{}),...(selectedLease?{leaseId:selectedLease}:{})};
 return new Promise((resolve,reject)=>{
  assert.equal(selectedPending,undefined);
  const timer=setTimeout(()=>{selectedPending=undefined;reject(Error('Selected lease timeout: '+op));selectedClient.destroy();},5000);
  selectedPending={resolve:value=>{clearTimeout(timer);selectedPending=undefined;try{assert.equal(value.nonce,nonce);assert.equal(value.error,undefined);resolve(value);}catch(e){reject(e);}},reject:error=>{clearTimeout(timer);selectedPending=undefined;reject(error);}};
  selectedClient.write(JSON.stringify(request)+'\n');
 });
}
async function holdSelected(){
 selectedClient=net.connect(root+'/selected.sock');
 selectedClient.on('data',bytes=>{selectedBuffer+=bytes;assert.ok(selectedBuffer.length<65536);let split;while((split=selectedBuffer.indexOf('\n'))>=0){const line=selectedBuffer.slice(0,split);selectedBuffer=selectedBuffer.slice(split+1);selectedPending?.resolve(JSON.parse(line));}});
 selectedClient.on('error',error=>selectedPending?.reject(error));
 await new Promise((resolve,reject)=>{selectedClient.once('connect',resolve);selectedClient.once('error',reject);});
 selectedGeneration=(await selectedCall('inspect')).serverGeneration;
 const held=await selectedCall('pause',{threadIds:[rootID,childID]});selectedLease=held.leaseId;
 assert.equal(held.inputAdmissionPaused,true);assert.equal(held.migrationAuthorized,false);
 assert.deepEqual(new Set(held.threadIds),new Set([rootID,childID]));
}
const sha256=bytes=>createHash('sha256').update(bytes).digest('hex');
async function daemonCommand(action){
 const {stdout}=await execFileAsync(daemonBinary,['app-server','daemon',action],{cwd:root,env:daemonEnvironment,timeout:accountGoal?120000:30000,maxBuffer:1024*1024});
 return JSON.parse(stdout);
}
const wait=ms=>new Promise(r=>setTimeout(r,ms));
async function until(test,label){for(let i=0;i<200;i++){if(await test())return;await wait(100);}throw Error('Owned fixture timeout: '+label+' '+stderr.slice(-300));}
async function connectOwnedServer(){
 ws=new WS('ws://localhost/',{createConnection:()=>net.connect(socket)});await new Promise((r,j)=>{ws.once('open',r);ws.once('error',j);});
 ws.on('message',bytes=>{const m=JSON.parse(bytes);if(m.id!==undefined&&!m.method){const p=pending.get(m.id);pending.delete(m.id);if(p)m.error?p.reject(Object.assign(Error(m.error.message),m.error)):p.resolve(m.result);return;}if(m.method==='thread/started'&&m.params.thread.parentThreadId){childID=m.params.thread.id;}if(m.method==='turn/started'&&m.params.threadId===childID)childTurnID=m.params.turn.id;});
 await rpc('initialize',{clientInfo:{name:'owned-child-goal',version:'1'},capabilities:{experimentalApi:true}});ws.send(JSON.stringify({method:'initialized'}));
}
async function stopOwnedServer(){
 if(processChild&&processChild.exitCode===null){const done=new Promise(r=>processChild.once('exit',r));processChild.kill('SIGTERM');const timer=setTimeout(()=>processChild.kill('SIGKILL'),3000);await done;clearTimeout(timer);}
}
function rpc(method,params){return new Promise((resolve,reject)=>{
 const id=++seq,timer=setTimeout(()=>{pending.delete(id);reject(Error('Owned fixture RPC timeout: '+method));},20000);
 pending.set(id,{resolve:value=>{clearTimeout(timer);resolve(value);},reject:error=>{clearTimeout(timer);reject(error);}});
 ws.send(JSON.stringify({id,method,params}),error=>{if(error){const request=pending.get(id);pending.delete(id);request?.reject(error);}});
});}
async function swiftGoal(action,expected){
 const args=[home,rootID,root,childID,action,...(expected?[JSON.stringify(expected)]:[])];
 const child=spawn(swiftHelper,args,{stdio:['ignore','pipe','pipe']});let out='',err='';
 child.stdout.on('data',bytes=>out+=bytes);child.stderr.on('data',bytes=>err=(err+bytes).slice(-2000));
 const timer=setTimeout(()=>child.kill('SIGKILL'),25000);
 let code;try{code=await new Promise((resolve,reject)=>{child.once('exit',resolve);child.once('error',reject);});}finally{clearTimeout(timer);}
 assert.equal(code,0,err);return JSON.parse(out);
}
const api=http.createServer(async(req,res)=>{
 if(req.method!=='POST'||!req.url?.split('?')[0].endsWith('/responses')){res.writeHead(503,{'Content-Type':'application/json'});res.end('{}');return;}
 let raw='';for await(const chunk of req)raw+=chunk;
 const data=JSON.parse(raw),input=JSON.stringify(data.input),isChild=input.includes('OWNED_GOAL_CHILD')&&!input.includes('owned-spawn-call');
 const all=(data.tools||[]).flatMap(t=>t.type==='namespace'?(t.tools||[]).map(f=>({...f,namespace:t.name})):[t]);
 res.writeHead(200,{'Content-Type':'text/event-stream'});streams.add(res);res.on('close',()=>streams.delete(res));
 const rid='owned-goal-'+(++posts),emit=v=>res.write('data: '+JSON.stringify(v)+'\n\n');
 emit({type:'response.created',response:{id:rid,status:'in_progress',output:[]}});
 const finish=item=>{emit({type:'response.output_item.added',output_index:0,item});emit({type:'response.output_item.done',output_index:0,item});emit({type:'response.completed',response:{id:rid,status:'completed',output:[item],usage:{input_tokens:1,output_tokens:1,total_tokens:2}}});res.end();};
 const message=text=>({id:'owned-done-'+posts,type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text}]});
 const call=(name,id,args)=>{const spec=all.find(t=>t.name===name);assert.ok(spec,'Missing official tool '+name);return {type:'function_call',id:id+'-item',call_id:id,name,...(spec.namespace?{namespace:spec.namespace}:{}),arguments:JSON.stringify(args)};};
 if(enginePause&&!isChild&&input.includes('owned-spawn-call')){
  parentHeld=true;
  const timer=setInterval(()=>{if(!res.destroyed)res.write(': owned busy parent\n\n');},200);res.on('close',()=>clearInterval(timer));return;
 }
 if((attachResumeProbe||accountGoal)&&localGoalRestored&&isChild){
  childResumeObserved=true;
  if(++localResumeCalls===1)finish(message('Owned child completed the official attachment Goal turn.'));
  else{
   localContinuationObserved=true;
   releaseChild=()=>{if(!res.destroyed)finish(message('Owned attachment Goal reached the next boundary.'));};
   const timer=setInterval(()=>{if(!res.destroyed)res.write(': owned attach heartbeat\n\n');},200);res.on('close',()=>clearInterval(timer));
  }
  return;
 }
 if(parentControl&&isChild&&input.includes('OWNED_CHILD_RESUME_REQUEST')){
  childResumeObserved=true;
  if(localResumeProbe){
   if(++localResumeCalls===1)finish(message('Owned child completed the first restored Goal turn.'));
   else{
    localContinuationObserved=true;
    releaseChild=()=>{if(!res.destroyed)finish(message('Owned restored Goal reached the next boundary.'));};
    const timer=setInterval(()=>{if(!res.destroyed)res.write(': owned resume heartbeat\n\n');},200);res.on('close',()=>clearInterval(timer));
   }
   return;
  }
  if(!input.includes('owned-child-resume-call'))finish(call('update_goal','owned-child-resume-call',{status:'active'}));
  else if(!input.includes('owned-child-recreate-call')){
   assert.match(input,/resume, budget-limited, and usage-limited status changes are controlled by the user or system/);
   finish(call('create_goal','owned-child-recreate-call',{objective:'Owned child account transition Goal',token_budget:1234}));
  }else{
   assert.match(input,/cannot create a new goal because this thread has an unfinished goal/);childCreateRejected=true;
   finish(message('Owned child could not resume or replace its paused Goal.'));
  }
  return;
 }
 if(parentControl&&isChild&&input.includes('OWNED_CHILD_PAUSE_REQUEST')){
  childPauseObserved=true;
  finish(!input.includes('owned-child-pause-call')?call('update_goal','owned-child-pause-call',{status:'paused'}):message('Owned child paused its Goal.'));return;
 }
 if(parentControl&&!isChild&&(input.includes('OWNED_PARENT_PAUSE_REQUEST')||input.includes('OWNED_PARENT_RESUME_REQUEST'))){
  const resume=input.includes('OWNED_PARENT_RESUME_REQUEST'),id=resume?'owned-parent-resume-call':'owned-parent-pause-call';
  if(!input.includes(id))finish(call('followup_task',id,{target:'/root/goal_fixture',message:resume?'OWNED_CHILD_RESUME_REQUEST: resume the existing paused Goal.':'OWNED_CHILD_PAUSE_REQUEST: the user requests that you pause your Goal.'}));
  else {if(!resume){releaseChild?.();releaseChild=undefined;}finish(message('Owned parent delivered the requested Goal instruction.'));}
  return;
 }
 if(isChild&&input.includes('owned-goal-call')){
  releaseChild=()=>{if(!res.destroyed)finish(message('Owned child reached a message boundary.'));};
  const timer=setInterval(()=>{if(!res.destroyed)res.write(': owned heartbeat\n\n');},200);res.on('close',()=>clearInterval(timer));return;
 }
 const name=isChild?'create_goal':'spawn_agent',spec=all.find(t=>t.name===name);
 let item;
 if(isChild)item={type:'function_call',id:'owned-goal-item',call_id:'owned-goal-call',name,...(spec?.namespace?{namespace:spec.namespace}:{}),arguments:JSON.stringify({objective:'Owned child account transition Goal',token_budget:1234})};
 else if(!input.includes('owned-spawn-call'))item={type:'function_call',id:'owned-spawn-item',call_id:'owned-spawn-call',name,...(spec?.namespace?{namespace:spec.namespace}:{}),arguments:JSON.stringify({task_name:'goal_fixture',message:'OWNED_GOAL_CHILD',fork_turns:'none'})};
 else item={id:'owned-done-'+posts,type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:'Owned parent is waiting.'}]};
 emit({type:'response.output_item.added',output_index:0,item});emit({type:'response.output_item.done',output_index:0,item});emit({type:'response.completed',response:{id:rid,status:'completed',output:[item],usage:{input_tokens:1,output_tokens:1,total_tokens:2}}});res.end();
});
try {
 if(process.argv.includes('--swift-read')) {
  assert.equal(swiftHelper,undefined,'Use either --swift-read or --swift-helper');
  swiftHelper=root+'/goal-observer';
  const build=path.resolve(option('build')??'.build/debug');
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/OfficialGoal'),
   '-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
   ...await coreSwiftObjects(build),'Tests/fixtures/codex-subagent-goal.swift','-o',swiftHelper],{stdio:'inherit',timeout:120000});
 }
 if(swiftLocalState){
  localStateHelper=root+'/state-check';const build=path.resolve(option('build')??'.build/debug');
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/OfficialGoalState'),
   '-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
   ...await coreSwiftObjects(build),'Tests/fixtures/codex-official-goal-state.swift','-o',localStateHelper],{stdio:'inherit',timeout:120000});
 }
 if(engineResume){
  engineResumeHelper=root+'/engine-resume';const build=path.resolve(option('build')??'.build/debug');
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/OfficialChildResume'),
   '-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
   ...await coreSwiftObjects(build),'Tests/fixtures/codex-official-child-resume.swift','-o',engineResumeHelper],{stdio:'inherit',timeout:120000});
 }
 if(accountGoal){
  assert.ok(completePackage&&daemonPackage&&!parentControl&&!engineResume,'Account adapter check requires a complete original daemon package');
  accountHelper=root+'/account-child-goal';const build=path.resolve(option('build')??'.build/debug');
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/OfficialAccountChildGoal'),
   '-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
   ...await coreSwiftObjects(build),'Tests/fixtures/codex-official-account-child-goal.swift','-o',accountHelper],{stdio:'inherit',timeout:120000});
 }
 await mkdir(home+'/app-server-control',{recursive:true});await new Promise((resolve,reject)=>{api.once('error',reject);api.listen(0,'127.0.0.1',resolve);});
 await writeFile(home+'/config.toml',`model="fixture-model"\nmodel_provider="fixture"\napproval_policy="never"\nsandbox_mode="read-only"\ncheck_for_update_on_startup=false\ncli_auth_credentials_store="file"\n[model_providers.fixture]\nname="Fixture"\nbase_url="http://127.0.0.1:${api.address().port}/v1"\nwire_api="responses"\nrequires_openai_auth=false\n[features]\nmulti_agent_v2=true\ngoals=true\n[analytics]\nenabled=false\n`);
 if(accountGoal){
  const encode=value=>Buffer.from(JSON.stringify(value)).toString('base64url');
  await writeFile(home+'/config.toml',(await readFile(home+'/config.toml','utf8')).replace('model="fixture-model"',`chatgpt_base_url="http://127.0.0.1:${api.address().port}"\nmodel="fixture-model"`));
  const claims={sub:'owned-child-user',exp:4102444800,'https://api.openai.com/auth':{chatgpt_user_id:'owned-child-user',chatgpt_account_id:'owned-child-workspace',chatgpt_plan_type:'pro'}};
  const token=encode({alg:'none',typ:'JWT'})+'.'+encode(claims)+'.synthetic-invalid-signature';
  await writeFile(home+'/auth.json',JSON.stringify({auth_mode:'chatgpt',tokens:{id_token:token,access_token:token,refresh_token:'owned-invalid-refresh',account_id:'owned-child-workspace',login_owner_id:'owned-child-login'},last_refresh:new Date().toISOString()}),{mode:0o600});
 }
 const binary=root+'/owned-goal-server';await copyFile(option('codex'),binary);await chmod(binary,0o700);
 const env={HOME:root,CODEX_HOME:home,PATH:'/usr/bin:/bin',NO_COLOR:'1',HTTP_PROXY:'http://127.0.0.1:9',HTTPS_PROXY:'http://127.0.0.1:9',NO_PROXY:'127.0.0.1,localhost'};
 if(selectedAdmission)env.AUTOAPPROVE_SELECTED_TRANSITION_SOCKET=root+'/selected.sock';
 if(daemonPackage){
  // Assemble only fixture package files. Never use or change the source home,
  // daemon settings, auth, or selected release. The real installer copies this
  // package into the owned home, just as it does for a fresh login group.
  const metadata=JSON.parse(await readFile(path.join(daemonPackage,'codex-package.json'),'utf8'));
  assert.equal(metadata.version,accountGoal?'0.169.0':'0.167.1');assert.equal(metadata.target,'aarch64-apple-darwin');
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
  if(accountGoal)console.error(JSON.stringify({ownedAccountStage:'daemon-start'}));
  assert.equal((await daemonCommand('start')).status,'started');
  const version=await daemonCommand('version');
  assert.equal(version.status,'running');assert.equal(version.cliVersion,metadata.version);assert.equal(version.appServerVersion,metadata.version);
  assert.equal(version.managedCodexVersion,metadata.version);
  const installed=await realpath(version.managedCodexPath);
  assert.ok(installed.startsWith(home+'/packages/app-server-daemon/releases/'));
  assert.equal(sha256(await readFile(installed)),sha256(await readFile(binary)),'Daemon must use the exact tested executable');
  daemonVerified=true;
  if(accountGoal)console.error(JSON.stringify({ownedAccountStage:'daemon-ready'}));
 }else{
  processChild=spawn(binary,[...(process.argv.includes('--app-server-binary')?[]:['app-server']),'--listen','unix://'+socket],{cwd:root,env,stdio:['ignore','ignore','pipe']});processChild.stderr.on('data',c=>stderr=(stderr+c).slice(-2000));
 }
 await until(async()=>{try{return(await stat(socket)).isSocket();}catch{return false;}},'socket');
 await connectOwnedServer();
 // Match the native TUI's persisted user-thread classification for account
 // continuation; the default API-created root has no threadSource marker.
 rootID=(await rpc('thread/start',{cwd:root,approvalPolicy:'never',sandbox:'read-only',...(accountGoal?{threadSource:'user'}:{})})).thread.id;
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
 if(!managedControl&&swiftHelper) {
  const observed=await swiftGoal('read');
  assert.equal(observed.rootThreadID,rootID);assert.equal(observed.parentThreadID,rootID);assert.equal(observed.threadID,childID);
  assert.equal(observed.goal.instanceID,originalGoalID);assert.equal(observed.goal.objective,before.objective);
  assert.equal(observed.goal.tokenBudget,before.tokenBudget);assert.equal(observed.goal.status,'active');
  assert.ok(observed.turnID);assert.equal(goalIdentity(),originalGoalID);
  const transition=await swiftGoal('read-transition');
  assert.equal(transition.id,childID);assert.equal(transition.goal.instanceID,originalGoalID);
  assert.equal(transition.goal.tokenBudget,before.tokenBudget);assert.equal(transition.active,true);
  assert.equal(transition.blocker,'활성 Goal','A read must not make an active child eligible for migration');
 }
 if(accountGoal){
  const runAccount=async mode=>{
   console.error(JSON.stringify({ownedAccountStage:mode}));
   const {stdout}=await execFileAsync(accountHelper,[home,option('codex'),rootID,root,childID,mode],{cwd:root,env:{...env,AUTOAPPROVE_HOME:root+'/account-state'},timeout:90000});
   return JSON.parse(stdout);
  };
  if(accountReproduce){assert.equal((await runAccount('reproduce')).accountChildDefectReproduced,true);console.log(JSON.stringify({verified:true,accountChildDefectReproduced:true,originalDaemon:true,existingSessionsTouched:false}));}
  else{
   const parentBefore=(await rpc('thread/turns/list',{threadId:rootID,limit:100,itemsView:'notLoaded',sortDirection:'desc'})).data.map(turn=>turn.id);
   await wait(2200);assert.equal((await runAccount('pause')).accountChildPaused,true);
   const paused=(await rpc('thread/goal/get',{threadId:childID})).goal,quiet=posts;
   assert.equal(paused.status,'paused');assert.ok(paused.timeUsedSeconds>=1);
   await wait(2200);assert.equal(posts,quiet);assert.deepEqual((await rpc('thread/goal/get',{threadId:childID})).goal,paused);
   ws.terminate();for(const res of streams)res.destroy();
   console.error(JSON.stringify({ownedAccountStage:'daemon-restart'}));
   assert.equal((await daemonCommand('restart')).status,'restarted');await connectOwnedServer();
   await rpc('thread/resume',{threadId:rootID,excludeTurns:true});
   const coldChild=(await rpc('thread/read',{threadId:childID,includeTurns:false})).thread;
   assert.equal(coldChild.status.type,'notLoaded');assert.equal(coldChild.canAcceptDirectInput??null,null);
   localGoalRestored=true;
   const resumed=await runAccount('resume');assert.equal(resumed.accountChildResumed,true);
   await until(()=>childResumeObserved&&localContinuationObserved,'account child native continuation');
   const after=(await rpc('thread/goal/get',{threadId:childID})).goal;
   assert.equal(goalIdentity(),originalGoalID);assert.equal(after.status,'active');assert.equal(after.objective,before.objective);assert.equal(after.tokenBudget,before.tokenBudget);
   assert.ok(after.tokensUsed>=paused.tokensUsed);assert.ok(after.timeUsedSeconds>=paused.timeUsedSeconds);
   assert.deepEqual((await rpc('thread/turns/list',{threadId:rootID,limit:100,itemsView:'notLoaded',sortDirection:'desc'})).data.map(turn=>turn.id),parentBefore);
   console.log(JSON.stringify({verified:true,productionAccountChildPausedAndResumed:true,originalDaemonRestarted:true,goalIdentityAndBudgetRetained:true,accountingMonotonic:true,pausedTimeNotCharged:true,parentTurnsUnchanged:true,alreadyActiveSkipped:resumed.alreadyActiveSkipped,existingSessionsTouched:false}));
  }
 }else{
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
  const swiftInitial=swiftHelper?await swiftGoal('read'):undefined;
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
  if(selectedAdmission){
   await holdSelected();
   const heldGoal=await inspect();
   await assert.rejects(()=>control(heldGoal.identity,'resume'),e=>e.code===-32600&&/input was not accepted/.test(e.message));
   const unchanged=await inspect();assert.deepEqual(unchanged,heldGoal);
  }
  // Goal continuation is paused first; the existing exact-turn interrupt then
  // stops in-flight work. No new user turn is injected into the child.
  const pausedTurnID=childTurnID;
  if(swiftPaused)assert.equal(swiftPaused.executionState,'idle','Swift pause must interrupt and confirm the observed turn');
  else await rpc('turn/interrupt',{threadId:childID,turnId:pausedTurnID});
  await until(async()=> (await rpc('thread/read',{threadId:childID,includeTurns:false})).thread.status.type==='idle','paused child idle');
  const atRest=await inspect(),postsAtRest=posts;
  assert.equal(atRest.goal.status,'paused');await wait(1200);assert.equal(posts,postsAtRest,'Paused Goal must not autonomously start another turn');
  if(selectedAdmission){
   assert.equal((await selectedCall('status')).inputAdmissionPaused,true);
   assert.deepEqual(await inspect(),atRest,'Held child Goal identity/accounting must stay unchanged while idle');
   assert.equal((await selectedCall('release')).inputAdmissionPaused,false);selectedClient.end();
  }
  const swiftRest=swiftInitial?await swiftGoal('read'):undefined;
  const swiftResumed=swiftRest?await swiftGoal('resume',swiftRest):undefined;
  const resumed=swiftResumed?{goal:swiftResumed.goal,goalId:swiftResumed.goal.instanceID}:await control(atRest.identity,'resume');assert.equal(resumed.goal.status,'active');
  assert.equal(resumed.goalId,originalGoalID);assert.equal(goalIdentity(),originalGoalID);
  await until(async()=>{const turns=(await rpc('thread/turns/list',{threadId:childID,limit:1,itemsView:'notLoaded',sortDirection:'desc'})).data;return Boolean(turns[0]?.id&&turns[0].id!==pausedTurnID&&posts>postsAtRest);},'same child Goal resumed');
  const after=await inspect();assert.equal(after.identity.goalId,originalGoalID);assert.equal(after.goal.objective,before.objective);assert.equal(after.goal.tokenBudget,before.tokenBudget);
  assert.ok(after.goal.tokensUsed>=atRest.goal.tokensUsed);assert.ok(after.goal.timeUsedSeconds>=atRest.goal.timeUsedSeconds);
  assert.deepEqual((await rpc('thread/turns/list',{threadId:rootID,limit:10,itemsView:'notLoaded',sortDirection:'desc'})).data.map(t=>t.id),parentBefore);
  console.log(JSON.stringify({verified:true,realV2Child:true,pausedAndResumed:true,selectedAdmissionVerified:selectedAdmission,swiftTransportVerified:Boolean(swiftInitial),managedDaemonVerified:daemonVerified,completePackageVerified:completePackage&&daemonVerified,goalIdentityAndBudgetRetained:true,accountingMonotonic:true,parentTurnsUnchanged:true,staleIdentityRejected:true,ordinaryDirectInputStillRejected:true,existingSessionsTouched:false}));
 }
 else if(parentControl){
  assert.equal(rejected?.code,-32600);assert.match(rejected.message,/direct app-server input is not allowed/);
  const parentTurnsBeforePause=(await rpc('thread/turns/list',{threadId:rootID,limit:100,itemsView:'notLoaded',sortDirection:'desc'})).data.map(turn=>turn.id);
  if(enginePause){
   await until(()=>parentHeld,'busy parent');
   await wait(2200);
   const pauseArgs=[home,option('codex'),rootID,root,childID,'pause'];
   const helperOptions={cwd:root,env:{...env,AUTOAPPROVE_HOME:root+'/compatibility-state'},timeout:30000};
   if(pauseCrash){
    const crashed=await execFileAsync(engineResumeHelper,[...pauseArgs,'crash-'+pauseCrash],helperOptions).then(()=>undefined,error=>error);
    assert.ok(crashed,'The owned controller must actually terminate before saving its result');
    assert.equal(crashed.code,{deferred:73,settled:74,paused:76,confirmed:75}[pauseCrash],crashed.stderr);
    const state=JSON.parse(execFileSync('/usr/bin/python3',['-c',`import json,sqlite3,sys\ndb=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)\nrow=db.execute('SELECT goal_id,status FROM thread_goals WHERE thread_id=?',(sys.argv[2],)).fetchone()\nprint(json.dumps({'goal':row[0],'status':row[1],'deferred':db.execute('SELECT 1 FROM thread_goal_continuation_deferrals WHERE thread_id=?',(sys.argv[2],)).fetchone() is not None}))`,home+'/goals_1.sqlite',childID],{encoding:'utf8'}));
    assert.equal(state.goal,originalGoalID);
    assert.equal(state.status,['paused','confirmed'].includes(pauseCrash)?'paused':'active');
    assert.equal(state.deferred,['deferred','settled'].includes(pauseCrash));
   }
   const {stdout}=await execFileAsync(engineResumeHelper,[...pauseArgs,...(pauseCrash?['recover-pause']:compatibilityEntry?['compatibility']:[])],helperOptions);
   enginePauseReport=JSON.parse(stdout);assert.equal(enginePauseReport.productionEnginePause,true);childPauseObserved=true;
   assert.equal(enginePauseReport.compatibilityEntry,compatibilityEntry);
   if(pauseCrash){
    assert.equal(enginePauseReport.uncertainRequestNotReplayed,true);
    assert.equal(enginePauseReport.freshObservedPauseRequired,['deferred','settled'].includes(pauseCrash));
   }
   assert.equal((await rpc('thread/read',{threadId:rootID,includeTurns:false})).thread.status.type,'active');
   assert.deepEqual((await rpc('thread/turns/list',{threadId:rootID,limit:100,itemsView:'notLoaded',sortDirection:'desc'})).data.map(turn=>turn.id),parentTurnsBeforePause);
  }else{
   await until(async()=> (await rpc('thread/read',{threadId:rootID,includeTurns:false})).thread.status.type==='idle','parent initially idle');
   await rpc('turn/start',{threadId:rootID,input:[{type:'text',text:'OWNED_PARENT_PAUSE_REQUEST'}]});
  }
  await until(async()=>childPauseObserved&&(await rpc('thread/goal/get',{threadId:childID})).goal?.status==='paused'&&(await rpc('thread/read',{threadId:childID,includeTurns:false})).thread.status.type==='idle','parent-mediated pause');
  const paused=(await rpc('thread/goal/get',{threadId:childID})).goal;
  assert.equal(goalIdentity(),originalGoalID);assert.equal(paused.objective,before.objective);assert.equal(paused.tokenBudget,before.tokenBudget);
  if(enginePause){
   assert.ok(paused.timeUsedSeconds>=1,'Native interrupt must account the elapsed active interval');
   const quietPosts=posts;await wait(3200);
   assert.equal(posts,quietPosts,'Paused Goal must not continue automatically');
   assert.deepEqual((await rpc('thread/goal/get',{threadId:childID})).goal,paused,'Paused interval may not accrue Goal usage');
  }
  const pausedTurn=(await rpc('thread/turns/list',{threadId:childID,limit:1,itemsView:'notLoaded',sortDirection:'desc'})).data[0].id;
  if(!enginePause)await until(async()=> (await rpc('thread/read',{threadId:rootID,includeTurns:false})).thread.status.type==='idle','parent pause completed');
  let localBefore;
  if(localResumeProbe&&!engineResume){
   // Feasibility experiment only, never used by production. It operates on
   // this fixture's exact idle Goal under a SQLite write transaction, retaining
   // identity, objective, budget and accounting. Runtime mutation permits,
   // events, rollout durability and crash recovery still need separate proof.
   const sql=(statement)=>JSON.parse(execFileSync('/usr/bin/sqlite3',['-json',home+'/goals_1.sqlite',statement],{encoding:'utf8'}));
   localBefore=sql("SELECT * FROM thread_goals WHERE thread_id='"+childID+"'")[0];
   assert.equal(localBefore.goal_id,originalGoalID);assert.equal(localBefore.status,'paused');
   const program=`import json,sqlite3,sys,time\npath,thread,expected=sys.argv[1:4]\nexpected=json.loads(expected)\ndb=sqlite3.connect(path,timeout=1)\ndb.row_factory=sqlite3.Row\ndb.execute('BEGIN IMMEDIATE')\nrow=dict(db.execute('SELECT * FROM thread_goals WHERE thread_id=?',(thread,)).fetchone())\nassert row==expected and row['status']=='paused'\nupdated=max(int(time.time()*1000),row['updated_at_ms']+1)\nassert db.execute("UPDATE thread_goals SET status='active',updated_at_ms=? WHERE thread_id=? AND goal_id=? AND status='paused'",(updated,thread,row['goal_id'])).rowcount==1\ndb.execute('DELETE FROM thread_goal_continuation_deferrals WHERE thread_id=?',(thread,))\nafter=dict(db.execute('SELECT * FROM thread_goals WHERE thread_id=?',(thread,)).fetchone())\nassert all(after[k]==v for k,v in row.items() if k not in ('status','updated_at_ms'))\ndb.commit()\n`;
   if(swiftLocalState){
    const state=async(mode,expected,timestamp,thread=childID)=>{
     const {stdout}=await execFileAsync(localStateHelper,[home,option('codex'),mode,thread,
      ...(expected?[JSON.stringify(expected),String(timestamp)]:[])],{env,cwd:root,timeout:20000});
     return JSON.parse(stdout);
    };
    let snapshot=await state('snapshot');assert.deepEqual(snapshot.row,{
     threadID:localBefore.thread_id,goalID:localBefore.goal_id,objective:localBefore.objective,status:localBefore.status,
     tokenBudget:localBefore.token_budget,tokensUsed:localBefore.tokens_used,timeUsedSeconds:localBefore.time_used_seconds,
     createdAtMs:localBefore.created_at_ms,updatedAtMs:localBefore.updated_at_ms});
    const timestamp=()=>Math.max(Date.now(),snapshot.row.updatedAtMs+1);
    const cancelled=await state('cancel',snapshot,timestamp());assert.equal(cancelled.rejected,true);assert.equal(cancelled.checks,3);
    assert.deepEqual(await state('snapshot'),snapshot,'Cancellation after SQL must roll back all fields and deferral');
    const disconnected=await state('lostBinding',snapshot,timestamp());assert.equal(disconnected.rejected,true);assert.equal(disconnected.checks,3);
    assert.deepEqual(await state('snapshot'),snapshot,'Binding loss after SQL must roll back');
    assert.equal((await state('reject',{...snapshot,row:{...snapshot.row,objective:'stale forged objective'}},timestamp())).rejected,true);
    assert.equal((await state('reject',snapshot,snapshot.row.updatedAtMs)).rejected,true);
    execFileSync('/usr/bin/sqlite3',[home+'/goals_1.sqlite',"UPDATE thread_goals SET updated_at_ms=updated_at_ms+1 WHERE thread_id='"+childID+"';"]);
    assert.equal((await state('reject',snapshot,timestamp())).rejected,true,'A concurrent change invalidates the exact old row');
    snapshot=await state('snapshot');
    execFileSync('/usr/bin/sqlite3',[home+'/goals_1.sqlite','CREATE TRIGGER owned_unknown_goal_schema AFTER UPDATE ON thread_goals BEGIN SELECT 1; END;']);
    try{await assert.rejects(state('snapshot'),error=>error.stderr.includes('schema object count mismatch'));}
    finally{execFileSync('/usr/bin/sqlite3',[home+'/goals_1.sqlite','DROP TRIGGER owned_unknown_goal_schema;']);}
    assert.deepEqual(await state('snapshot'),snapshot,'Unknown schema rejection may not change Goal data');
    const raceTime=timestamp(),race=await Promise.all([state('compete',snapshot,raceTime),state('compete',snapshot,raceTime)]);
    assert.equal(race.filter(result=>result.accepted===true).length,1,'Only one concurrent controller can restore the paused row');
    assert.equal(race.filter(result=>result.rejected===true).length,1);
    const resumed=race.find(result=>result.accepted).snapshot;assert.equal(resumed.row.status,'active');
    assert.equal(resumed.row.goalID,snapshot.row.goalID);assert.equal(resumed.row.tokensUsed,snapshot.row.tokensUsed);
    assert.equal(resumed.row.timeUsedSeconds,snapshot.row.timeUsedSeconds);assert.equal(resumed.continuationDeferred,false);
    assert.equal((await state('reject',snapshot,timestamp())).rejected,true,'A repeated paused-state request cannot resume again');
    // Crash only helper processes and use independent owned paused Goals for
    // these journal cases. The selected child is not reset to prepare tests.
    const crashGoal=async()=>{
     const id=(await rpc('thread/start',{cwd:root,approvalPolicy:'never',sandbox:'read-only'})).thread.id;
     await rpc('thread/goal/set',{threadId:id,objective:'Owned state crash reservation',status:'paused',tokenBudget:4321});
     return {id,snapshot:await state('snapshot',undefined,undefined,id)};
    };
    const reserved=await crashGoal(),reservedID=randomUUID(),reservedTime=reserved.snapshot.row.updatedAtMs+1;
    await assert.rejects(state('journal:'+reservedID+':reserveCrash',reserved.snapshot,reservedTime,reserved.id),error=>error.code===70);
    const reservedReplay=await state('journal:'+reservedID+':continue',reserved.snapshot,reservedTime,reserved.id);
    assert.equal(reservedReplay.phase,'review');assert.equal(reservedReplay.result,undefined);
    assert.deepEqual(await state('snapshot',undefined,undefined,reserved.id),reserved.snapshot,'A reservation surviving restart may not dispatch SQL');
    await assert.rejects(state('sqlCrash',reserved.snapshot,reservedTime,reserved.id),error=>error.code===72);
    assert.deepEqual(await state('snapshot',undefined,undefined,reserved.id),reserved.snapshot,'Process death before COMMIT must roll back SQL');
    const applied=await crashGoal(),appliedID=randomUUID(),appliedTime=applied.snapshot.row.updatedAtMs+1;
    await assert.rejects(state('journal:'+appliedID+':applyCrash',applied.snapshot,appliedTime,applied.id),error=>error.code===71);
    const appliedState=await state('snapshot',undefined,undefined,applied.id);assert.equal(appliedState.row.status,'active');
    const appliedReplay=await state('journal:'+appliedID+':continue',applied.snapshot,appliedTime,applied.id);
    assert.equal(appliedReplay.phase,'review');assert.deepEqual(await state('snapshot',undefined,undefined,applied.id),appliedState,'Lost receipt cannot replay a committed SQL mutation');
    const finished=await crashGoal(),finishedID=randomUUID(),finishedTime=finished.snapshot.row.updatedAtMs+1;
    const receipt=await state('journal:'+finishedID+':continue',finished.snapshot,finishedTime,finished.id);
    assert.equal(receipt.phase,'applied');assert.equal(receipt.result.row.status,'active');
    assert.deepEqual(await state('journal:'+finishedID+':continue',finished.snapshot,finishedTime,finished.id),receipt);
    await assert.rejects(state('journal:'+finishedID+':continue',finished.snapshot,finishedTime+1,finished.id));
    const concurrent=await crashGoal(),concurrentID=randomUUID(),concurrentTime=concurrent.snapshot.row.updatedAtMs+1;
    const journals=await Promise.all([state('journal:'+concurrentID+':continue',concurrent.snapshot,concurrentTime,concurrent.id),state('journal:'+concurrentID+':continue',concurrent.snapshot,concurrentTime,concurrent.id)]);
    assert.ok(journals.some(receipt=>receipt.phase==='applied'));
    assert.ok(journals.every(receipt=>['applied','review'].includes(receipt.phase)));
    for(const id of [appliedID,finishedID,concurrentID])assert.equal(await readFile(root+'/state-applied-'+id.toUpperCase()+'.log','utf8'),'applied\n','Committed state restoration hook must execute once per reserved ID');
   }else execFileSync('/usr/bin/python3',['-c',program,home+'/goals_1.sqlite',childID,JSON.stringify(localBefore)],{timeout:5000});
   assert.equal((await rpc('thread/goal/get',{threadId:childID})).goal.status,'active');
  }
  const parentTurnsBeforeResume=(await rpc('thread/turns/list',{threadId:rootID,limit:100,itemsView:'notLoaded',sortDirection:'desc'})).data.map(turn=>turn.id);
  if(attachResumeProbe){
   localGoalRestored=true;
   if(engineResume){
    const {stdout}=await execFileAsync(engineResumeHelper,[home,option('codex'),rootID,root,childID,...(compatibilityEntry?['compatibility']:[])],{cwd:root,env:{...env,AUTOAPPROVE_HOME:root+'/compatibility-state'},timeout:30000});
    engineResumeReport=JSON.parse(stdout);assert.equal(engineResumeReport.productionEngineResume,true);
    assert.equal(engineResumeReport.compatibilityEntry,compatibilityEntry);
   }else{
   const attachment=await rpc('thread/resume',{threadId:childID,excludeTurns:true});
   assert.equal(attachment.thread.id,childID);assert.equal(attachment.thread.canAcceptDirectInput,false);
   }
  }else await rpc('turn/start',{threadId:rootID,input:[{type:'text',text:'OWNED_PARENT_RESUME_REQUEST'}]});
  if(localResumeProbe){
   await until(async()=>childResumeObserved&&localContinuationObserved&&(await rpc('thread/read',{threadId:childID,includeTurns:false})).thread.status.type==='active','restored Goal actually continues');
   const after=(await rpc('thread/goal/get',{threadId:childID})).goal;
   assert.equal(after.status,'active');assert.equal(goalIdentity(),originalGoalID);
   assert.equal(after.objective,before.objective);assert.equal(after.tokenBudget,before.tokenBudget);
   assert.ok(after.tokensUsed>=paused.tokensUsed);assert.ok(after.timeUsedSeconds>=paused.timeUsedSeconds);
   const turns=(await rpc('thread/turns/list',{threadId:childID,limit:3,itemsView:'notLoaded',sortDirection:'desc'})).data;
   assert.ok(turns.length>=2&&turns[0].id!==pausedTurn&&turns[1].id!==pausedTurn);
   if(attachResumeProbe)assert.deepEqual((await rpc('thread/turns/list',{threadId:rootID,limit:100,itemsView:'notLoaded',sortDirection:'desc'})).data.map(turn=>turn.id),parentTurnsBeforeResume);
   assert.equal(pending.size,0);
   ws.terminate();await stopOwnedServer();await rm(socket,{force:true});
   for(const res of streams)res.destroy();
   processChild=spawn(binary,['app-server','--listen','unix://'+socket],{cwd:root,env,stdio:['ignore','ignore','pipe']});
   processChild.stderr.on('data',bytes=>stderr=(stderr+bytes).slice(-2000));
   await until(async()=>{try{return(await stat(socket)).isSocket();}catch{return false;}},'cold owned socket');
   await connectOwnedServer();
   await rpc('thread/resume',{threadId:rootID,excludeTurns:true});
   const cold=(await rpc('thread/goal/get',{threadId:childID})).goal;
   assert.equal(cold.status,'active');assert.equal(goalIdentity(),originalGoalID);
   assert.equal(cold.objective,before.objective);assert.equal(cold.tokenBudget,before.tokenBudget);
   assert.ok(cold.tokensUsed>=after.tokensUsed);assert.ok(cold.timeUsedSeconds>=after.timeUsedSeconds);
   const history=await rpc('thread/read',{threadId:childID,includeTurns:true});
   assert.equal(history.thread.parentThreadId,rootID);assert.ok(history.thread.turns.length>=2);
   console.log(JSON.stringify({verified:true,feasibilityExperimentOnly:!engineResume,realV2Child:true,officialRuntimeUnmodified:true,
    publicDirectGoalChangeRejected:true,parentPauseSucceeded:true,localStateRestored:true,parentFollowupStartedChild:!attachResumeProbe,
    officialAttachmentStartedChild:attachResumeProbe,parentTurnsUnchangedDuringResume:attachResumeProbe,
    productionEngineResume:Boolean(engineResumeReport),requestAndAppRestartReadOnly:Boolean(engineResumeReport?.repeatAndRestartReadOnly),
    productionEnginePause:Boolean(enginePauseReport),compatibilityPublicEntryVerified:compatibilityEntry,pauseCrashRecoveryPoint:pauseCrash??null,pauseCrashRecovery:pauseCrash?enginePauseReport:null,busyParentPreserved:enginePause,pausedTimeNotCharged:enginePause,
    autonomousNextGoalTurnObserved:true,goalIdentityAndBudgetRetained:true,accountingMonotonic:true,coldServerGoalAndHistoryRetained:true,
    swiftStatePrimitiveVerified:swiftLocalState,rollbackAfterSQLVerified:swiftLocalState,
    staleAndRepeatedStateRejected:swiftLocalState,concurrentResumeAppliedOnce:swiftLocalState,unknownSchemaRejected:swiftLocalState,
    crashBeforeCommitRolledBack:swiftLocalState,reservationsAndLostReceiptsNeverReplayed:swiftLocalState,concurrentRequestIDReservedOnce:swiftLocalState,
    resumeLifecycleIntegrated:engineResume,pauseLifecycleIntegrated:enginePause,fullGoalLifecycleIntegrated:enginePause&&engineResume,existingSessionsTouched:false}));
  }else{
  await until(async()=>childResumeObserved&&childCreateRejected&&(await rpc('thread/read',{threadId:childID,includeTurns:false})).thread.status.type==='idle','parent-mediated resume refused');
  const after=(await rpc('thread/goal/get',{threadId:childID})).goal;
  assert.equal(after.status,'paused');assert.equal(goalIdentity(),originalGoalID);assert.equal(after.objective,before.objective);assert.equal(after.tokenBudget,before.tokenBudget);
  const resumedTurn=(await rpc('thread/turns/list',{threadId:childID,limit:1,itemsView:'notLoaded',sortDirection:'desc'})).data[0].id;
  assert.notEqual(resumedTurn,pausedTurn,'Followup really started a new child turn');
  console.log(JSON.stringify({verified:true,realV2Child:true,publicDirectGoalChangeRejected:true,parentFollowupPauseSucceeded:true,parentFollowupStartedNewTurn:true,parentFollowupDidNotResumeGoal:true,childUpdateActiveRejected:true,recreateUnfinishedGoalRejected:true,goalIdentityAndBudgetRetained:true,existingSessionsTouched:false}));
  }
 }
 else if(process.argv.includes('--expect-rejection')){assert.equal(rejected?.code,-32600);assert.match(rejected.message,/direct app-server input is not allowed/);console.log(JSON.stringify({verified:true,originalDefectReproduced:true,realV2Child:true,activeGoal:true,officialSwiftReadVerified:Boolean(swiftHelper),officialMigrationSnapshotReadVerified:Boolean(swiftHelper),managedDaemonVerified:daemonVerified,existingSessionsTouched:false}));}
 else {assert.equal(rejected,undefined,rejected?.message);assert.equal(goalIdentity(),originalGoalID);console.log(JSON.stringify({verified:true,realV2Child:true,pausedWithoutDirectTurnInput:true,goalIdentityAndBudgetRetained:true,existingSessionsTouched:false}));}
 }
} finally {
 selectedClient?.destroy();
 for(const request of pending.values())request.reject(Error('Owned fixture closed'));pending.clear();
 for(const res of streams)res.destroy();ws?.terminate();
 await stopOwnedServer();
 api.closeAllConnections();api.close();
 // Keep the owned home available for recovery if stopping its daemon fails.
 if(daemonAttempted){const stopped=await daemonCommand('stop');assert.ok(['stopped','notRunning'].includes(stopped.status),JSON.stringify(stopped));}
 await rm(root,{recursive:true,force:true});
}
