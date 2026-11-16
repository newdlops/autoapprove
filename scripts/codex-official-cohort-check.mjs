// Production app prepare/perform against two original TUIs in owned PTYs.
// Daemons, fake model, HOME, profiles and all credentials are isolated.
import assert from 'node:assert/strict';
import {execFileSync,execFile,spawn} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp,mkdir,writeFile,rm,readFile} from 'node:fs/promises';
import path from 'node:path';
import http from 'node:http';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
import {verifyOfficialCodexRuntime} from './codex-runtime-resource.mjs';
const option=name=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3);
assert.ok(option('runtime'),'Provide the complete original official runtime');
const runtime=path.resolve(option('runtime')),cli=runtime+'/bin/codex',build=path.resolve('.build/debug');
await verifyOfficialCodexRuntime(runtime);
const root=await mkdtemp('/private/tmp/aa-managed2-daemon-cohort-');
const homes=[root+'/home',root+'/destination/home'],run=promisify(execFile),calls=[];
const env=home=>({HOME:root,CODEX_HOME:home,ZDOTDIR:root,PATH:'/usr/bin:/bin',HTTP_PROXY:'http://127.0.0.1:9',HTTPS_PROXY:'http://127.0.0.1:9',NO_PROXY:'localhost,127.0.0.1'});
let succeeded=false;const attempted=[];
async function fixture(args) {
 return await new Promise((resolve,reject)=>{
  const child=spawn(root+'/check',args,{cwd:root,env:env(homes[0]),stdio:['ignore','pipe','pipe']});
  let stdout='',stderr='',lines='',fatal='',timedOut=false,killTimer;
  const timer=setTimeout(()=>{timedOut=true;child.kill('SIGTERM');killTimer=setTimeout(()=>child.kill('SIGKILL'),2000);},240000);
  child.stdout.setEncoding('utf8');child.stderr.setEncoding('utf8');
  child.stdout.on('data',bytes=>{stdout=(stdout+bytes).slice(-1048576);});
  child.stderr.on('data',bytes=>{
   lines+=bytes;let end;
   while((end=lines.indexOf('\n'))>=0) {
    const line=lines.slice(0,end);lines=lines.slice(end+1);
    if(line.startsWith('libvterm:'))continue;
    if(line.includes('Fatal error:'))fatal=line.slice(0,16000);
    stderr=(stderr+line+'\n').slice(-16000);
   }
  });
  child.once('error',error=>{clearTimeout(timer);clearTimeout(killTimer);reject(error);});
  child.once('close',(code,signal)=>{
   clearTimeout(timer);clearTimeout(killTimer);
   if(code===0)resolve({stdout});
   else reject(Object.assign(Error(`Owned fixture ${timedOut?'deadline':signal??code}: ${fatal}\n${stderr}`),{stderr:fatal+'\n'+stderr}));
  });
 });
}
let modelFailure;
const modelEvents={goalCreate:0,heldGoalRequests:0};
let heldRootRequests=0,backgroundToolCalls=0;
const api=http.createServer((req,res)=>{void modelResponse(req,res).catch(error=>{
 modelFailure??=error;
 if(!res.headersSent)res.writeHead(500);
 res.end();
});});
async function modelResponse(req,res){
 const parts=[];for await(const bytes of req)parts.push(bytes);
 const request=JSON.parse(Buffer.concat(parts));
 const user=request.input?.at(-1)?.content?.filter(item=>item.type==='input_text').map(item=>item.text).join('')??'';
 calls.push(user);
 const id='owned-'+calls.length,input=JSON.stringify(request.input);
 if(process.argv.includes('--active-root-goals')&&input.includes('Owned migrated active root Goal')&&!user.startsWith('Generate a concise, single-line task title')) {
  heldRootRequests++;
  res.writeHead(200,{'Content-Type':'text/event-stream'});res.write('data: '+JSON.stringify({type:'response.created',response:{id,status:'in_progress',output:[]}})+'\n\n');
  const timer=setInterval(()=>{if(!res.destroyed)res.write(': owned root Goal heartbeat\n\n');},200);
  res.on('close',()=>clearInterval(timer));return;
 }
 let item={id:'message-'+id,type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:input.includes('OWNED_ROUNDTRIP_LATEST')?'OWNED_ROUNDTRIP_REPLY':input.includes('OWNED_LATE_CHILD_HISTORY')&&!input.includes('owned-late-spawn-call')?'OWNED_CHILD_HISTORY_REPLY':'OWNED_COHORT_REPLY'}]};
 if(process.argv.includes('--late-child')&&!user.startsWith('Generate a concise, single-line task title')&&input.includes('OWNED_LATE_CHILD')&&!input.includes('OWNED_LATE_CHILD_HISTORY')&&!input.includes('owned-late-spawn-call')) {
  const all=(request.tools??[]).flatMap(t=>t.type==='namespace'?(t.tools??[]).map(f=>({...f,namespace:t.name})):[t]);
  const spec=all.find(t=>t.name==='spawn_agent');assert.ok(spec,'Original runtime must expose spawn_agent');
  item={type:'function_call',id:'owned-late-spawn-item',call_id:'owned-late-spawn-call',name:'spawn_agent',...(spec.namespace?{namespace:spec.namespace}:{}),arguments:JSON.stringify({task_name:'late_child',message:'OWNED_LATE_CHILD_HISTORY',fork_turns:'none'})};
 }
 if(process.argv.includes('--active-child-goal')&&input.includes('OWNED_LATE_CHILD_HISTORY')&&!input.includes('owned-late-spawn-call')&&!user.startsWith('Generate a concise, single-line task title')) {
  if(!input.includes('owned-cohort-goal-call')) {
   const all=(request.tools??[]).flatMap(t=>t.type==='namespace'?(t.tools??[]).map(f=>({...f,namespace:t.name})):[t]);
   const spec=all.find(t=>t.name==='create_goal');assert.ok(spec,'Original child must expose create_goal');modelEvents.goalCreate++;
   item={type:'function_call',id:'owned-cohort-goal-item',call_id:'owned-cohort-goal-call',name:'create_goal',...(spec.namespace?{namespace:spec.namespace}:{}),arguments:JSON.stringify({objective:'Owned migrated active child Goal',token_budget:1234})};
  } else {
   modelEvents.heldGoalRequests++;
   res.writeHead(200,{'Content-Type':'text/event-stream'});res.write('data: '+JSON.stringify({type:'response.created',response:{id,status:'in_progress',output:[]}})+'\n\n');
   const timer=setInterval(()=>{if(!res.destroyed)res.write(': owned Goal heartbeat\n\n');},200);
   res.on('close',()=>clearInterval(timer));return;
  }
 }
 if(process.argv.includes('--background-tool')&&input.includes('OWNED_COHORT_0')&&!input.includes('owned-background-call')&&!user.startsWith('Generate a concise, single-line task title')) {
  const all=(request.tools??[]).flatMap(t=>t.type==='namespace'?(t.tools??[]).map(f=>({...f,namespace:t.name})):[t]);
  const spec=all.find(t=>t.name==='exec_command');assert.ok(spec,'Original runtime must expose exec_command');backgroundToolCalls++;
  item={type:'function_call',id:'owned-background-item',call_id:'owned-background-call',name:'exec_command',...(spec.namespace?{namespace:spec.namespace}:{}),arguments:JSON.stringify({cmd:'/bin/sleep 600',yield_time_ms:1000})};
 }
 res.writeHead(200,{'Content-Type':'text/event-stream'});
 for(const event of [{type:'response.created',response:{id,status:'in_progress',output:[]}},
  {type:'response.output_item.added',output_index:0,item},{type:'response.output_item.done',output_index:0,item},
  {type:'response.completed',response:{id,status:'completed',output:[item],usage:{input_tokens:1,output_tokens:1,total_tokens:2}}}])res.write('data: '+JSON.stringify(event)+'\n\n');
 res.end();
}
try {
 await new Promise(resolve=>api.listen(0,'127.0.0.1',resolve));
 for(const home of homes) {
  await mkdir(home+'/app-server-daemon',{recursive:true,mode:0o700});
  await writeFile(home+'/config.toml',`log_dir=${JSON.stringify(home+'/log')}\nmodel="fixture-model"\nmodel_provider="fixture"\napproval_policy="never"\nsandbox_mode="read-only"\ncli_auth_credentials_store="file"\ncheck_for_update_on_startup=false\n[model_providers.fixture]\nname="Fixture"\nbase_url="http://127.0.0.1:${api.address().port}/v1"\nwire_api="responses"\nrequires_openai_auth=false\n[features]\nmulti_agent_v2=true\ngoals=true\ndaemon_auto_start=true\napps=false\nplugins=false\n[analytics]\nenabled=false\n[projects.${JSON.stringify(root)}]\ntrust_level="trusted"\n`,{mode:0o600});
  await writeFile(home+'/app-server-daemon/settings.json',JSON.stringify({shutdownGraceSeconds:0,updater:{autoUpdateEnabled:false}}),{mode:0o600});
  attempted.push(home);
  const {stdout}=await run(path.join(build,'autoapprove-checks'),['--bundled-runtime-prepare',runtime,home],{env:env(home),cwd:root,timeout:120000,maxBuffer:1024*1024});
  assert.equal(JSON.parse(stdout).serverPrepared,true);
 }
 try {
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/OfficialCohort'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),...await coreSwiftObjects(build),'Tests/fixtures/codex-official-cohort.swift',...await coreLinkArguments(build),'-lsqlite3','-o',root+'/check'],{timeout:120000});
 } catch(error) {throw Error('Owned fixture compilation failed:\n'+String(error.stderr??error.message).slice(-8000));}
 let stdout;
 try {({stdout}=await fixture([root,cli,...process.argv.filter(value=>['--lose-launch-reply','--paused-goals','--standalone-cohort','--same-home','--automatic-enrollment','--automatic-before-effects','--dedicated-split','--late-child','--roundtrip','--active-child-goal','--active-root-goals','--background-tool','--recover-moved-intent','--superseded-moved-intent','--unsupported-history-schema'].includes(value))]));}
 catch(error) {
  const logs=await Promise.all(homes.map(home=>readFile(home+'/log/codex-tui.log','utf8').catch(()=>'')));
  throw Error(String(error.stderr??error.message).replace(/^libvterm:.*\n/gm,'').slice(-12000)+'\nOwned TUI logs:\n'+logs.join('\n').slice(-12000));
 }
 if(modelFailure)throw modelFailure;
 const result=JSON.parse(stdout);assert.equal(result.verified,true);
 const allConversationCalls=calls.filter(text=>!text.startsWith('Generate a concise, single-line task title'));
 const conversationCalls=allConversationCalls.filter(text=>text!=='OWNED_ROUNDTRIP_LATEST');
 assert.equal(allConversationCalls.length-conversationCalls.length,process.argv.includes('--roundtrip')?1:0,'Exactly one explicitly requested latest turn');
 if(process.argv.includes('--active-root-goals')) {
  assert.equal(heldRootRequests,4,'Each original root continues exactly once after restoration');assert.equal(conversationCalls.length,6,JSON.stringify(conversationCalls));
 } else if(process.argv.includes('--background-tool')) {
  assert.equal(backgroundToolCalls,1);assert.equal(conversationCalls.length,3,JSON.stringify(conversationCalls));
 } else if(process.argv.includes('--active-child-goal')) {
  assert.ok(process.argv.includes('--late-child'));
  assert.equal(conversationCalls.length,7,JSON.stringify(conversationCalls));
  assert.deepEqual(modelEvents,{goalCreate:1,heldGoalRequests:2},'One original and one resumed active Goal request');
  for(const text of ['OWNED_COHORT_0','OWNED_COHORT_1','OWNED_LATE_CHILD'])assert.equal(conversationCalls.filter(value=>value===text).length,1,JSON.stringify(conversationCalls));
 } else if(process.argv.includes('--late-child')) {
  assert.equal(conversationCalls.length,5,JSON.stringify(conversationCalls));
  for(const text of ['OWNED_COHORT_0','OWNED_COHORT_1','OWNED_LATE_CHILD',''])assert.equal(conversationCalls.filter(value=>value===text).length,1,JSON.stringify(conversationCalls));
  // V2 delivers the child task as encrypted agent content. The readable part
  // is only its envelope; never require the payload in an input_text field.
  assert.equal(conversationCalls.filter(value=>value.startsWith('Message Type: NEW_TASK\nTask name: /root/late_child\n')).length,1,JSON.stringify(conversationCalls));
 } else assert.deepEqual(conversationCalls.sort(),['OWNED_COHORT_0','OWNED_COHORT_1'],'Restoration must neither replay a turn nor create an unsolicited one');
 console.log(JSON.stringify({...result,noTurnReplay:true,lateChildChecked:process.argv.includes('--late-child'),activeChildGoalChecked:process.argv.includes('--active-child-goal'),activeRootGoalsChecked:process.argv.includes('--active-root-goals'),backgroundToolFenceChecked:process.argv.includes('--background-tool'),dedicatedSplitChecked:process.argv.includes('--dedicated-split'),latestHistoryRoundtripChecked:process.argv.includes('--roundtrip'),movedGoalIntentRecovered:process.argv.includes('--recover-moved-intent'),newerDestinationIntentPreserved:process.argv.includes('--superseded-moved-intent'),automaticBeforeEffectsRecovered:process.argv.includes('--automatic-before-effects')}));succeeded=true;
} finally {
 const extra=JSON.parse(await readFile(root+'/extra-homes.json','utf8').catch(error=>{if(error.code==='ENOENT')return '[]';throw error;}));
 for(const home of extra) {
  assert.equal(typeof home,'string');
  assert.ok(home.startsWith(root+'/profile/codex-independent-sessions/homes/')&&!path.relative(root,home).startsWith('..'),'Cleanup must remain inside owned homes');
  attempted.push(home);
 }
 for(const home of attempted.reverse()) {
  const {stdout}=await run(cli,['app-server','daemon','stop'],{env:env(home),cwd:root,timeout:30000});
  assert.ok(['stopped','notRunning'].includes(JSON.parse(stdout).status));
 }
 api.closeAllConnections();await new Promise(resolve=>api.close(resolve));
 if(process.argv.includes('--keep')||!succeeded&&process.argv.includes('--keep-on-failure'))console.error('Owned fixture retained at '+root);
 else await rm(root,{recursive:true,force:true,maxRetries:10,retryDelay:100});
}
