// Owned feasibility check for durable source-writer retirement with original Codex.
// This is not a complete client migration or a production archive mutation path.
import assert from 'node:assert/strict';
import {spawn, execFile, execFileSync} from 'node:child_process';
import {mkdtemp, mkdir, writeFile, readFile, rename, rm, readdir, stat, open, symlink, link, unlink} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createInterface} from 'node:readline';
import {once} from 'node:events';
import {createHash} from 'node:crypto';
import path from 'node:path';
import {promisify} from 'node:util';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';

const cli=process.argv.find(v=>v.startsWith('--codex='))?.slice(8);
assert.ok(cli&&path.isAbsolute(cli),'Provide --codex=/absolute/original/bin/codex');
execFileSync('/usr/bin/codesign',['--verify','--strict','-R=anchor apple generic and identifier "codex" and certificate leaf[subject.OU] = "2DC432GLL2"',cli],{stdio:'inherit'});
assert.equal(execFileSync(cli,['--version'],{encoding:'utf8'}).trim(),'codex-cli 0.169.0');
const root=await mkdtemp('/private/tmp/aa-official-retirement-'),home=root+'/source',children=new Set();
const swiftRetirement=process.argv.includes('--swift-retirement'),run=promisify(execFile),helper=root+'/check';
const crashRetirement=process.argv.includes('--crash-retirement');assert.ok(!crashRetirement||swiftRetirement,'Crash checks require the production Swift primitive');
const baseEnv={HOME:root,PATH:'/usr/bin:/bin',HTTP_PROXY:'http://127.0.0.1:9',HTTPS_PROXY:'http://127.0.0.1:9',NO_PROXY:'localhost,127.0.0.1'};
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const alive=p=>p&&p.exitCode===null&&p.signalCode===null;
const digest=bytes=>createHash('sha256').update(bytes).digest('hex');
let posts=0,kept=false;
const provider=createServer(async(req,res)=>{
 for await(const _ of req){}
 if(req.url!=='/v1/responses'){res.writeHead(404);res.end();return;}
 const id='owned-retirement-'+(++posts),item={id:id+'-message',type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:'OWNED_RETIRED_HISTORY',annotations:[]}]};
 res.writeHead(200,{'Content-Type':'text/event-stream'});
 for(const event of [{type:'response.created',response:{id,status:'in_progress',output:[]}},
  {type:'response.output_item.added',output_index:0,item},{type:'response.output_item.done',output_index:0,item},
  {type:'response.completed',response:{id,status:'completed',output:[item],usage:{input_tokens:1,output_tokens:1,total_tokens:2}}}])res.write('data: '+JSON.stringify(event)+'\n\n');
 res.end();
});
async function stop(p){
 if(!alive(p))return;
 const done=once(p,'exit');p.kill('SIGTERM');const timer=setTimeout(()=>p.kill('SIGKILL'),3000);
 try{await done;}finally{clearTimeout(timer);children.delete(p);}
}
async function server(selectedHome){
 const child=spawn(cli,['app-server','--listen','stdio://'],{cwd:root,env:{...baseEnv,CODEX_HOME:selectedHome},stdio:['pipe','pipe','pipe']});children.add(child);
 let seq=0,stderr='';const pending=new Map(),events=[];
 child.stderr.on('data',b=>stderr=(stderr+b).slice(-3000));
 createInterface({input:child.stdout}).on('line',line=>{
  const message=JSON.parse(line);
  if(message.id!==undefined&&!message.method){const p=pending.get(message.id);pending.delete(message.id);if(p)message.error?p.reject(Object.assign(Error(message.error.message),{rpc:message.error})):p.resolve(message.result);}
  else events.push(message);
 });
 child.on('exit',()=>{for(const p of pending.values())p.reject(Error('Owned server exited '+stderr));pending.clear();});
 const request=(method,params={})=>new Promise((resolve,reject)=>{
  const id=++seq,timer=setTimeout(()=>{pending.delete(id);reject(Error('Owned RPC timeout: '+method+' '+stderr));},15000);
  pending.set(id,{resolve:value=>{clearTimeout(timer);resolve(value)},reject:error=>{clearTimeout(timer);error.message=method+': '+error.message;reject(error)}});
  child.stdin.write(JSON.stringify({id,method,params})+'\n');
 });
 await request('initialize',{clientInfo:{name:'owned-official-retirement',version:'1'},capabilities:{experimentalApi:true}});
 child.stdin.write(JSON.stringify({method:'initialized'})+'\n');
 return {child,request,events,async complete(thread,turn){
  const end=Date.now()+20000;
  while(Date.now()<end){const event=events.find(m=>m.method==='turn/completed'&&m.params.threadId===thread&&m.params.turn.id===turn);if(event){assert.equal(event.params.turn.status,'completed');return;}await delay(30);}
  throw Error('Owned model turn did not complete '+stderr);
 }};
}
async function syncFile(file){const fd=await open(file,'r');try{await fd.sync();}finally{await fd.close();}}
try{
 await mkdir(home,{mode:0o700});await new Promise(resolve=>provider.listen(0,'127.0.0.1',resolve));
 if(swiftRetirement){
  await mkdir(root+'/destination',{mode:0o700});const build=path.resolve('.build/debug');
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/OfficialRetirement'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),...await coreSwiftObjects(build),'Tests/fixtures/codex-official-retirement.swift',...await coreLinkArguments(build),'-lsqlite3','-o',helper],{stdio:'inherit',timeout:120000});
 }
 async function production(action,thread,archive){
  const {stdout}=await run(helper,[root,home,root+'/destination',thread,archive,action],{cwd:root,env:{...baseEnv,CODEX_HOME:home},timeout:20000});
  return JSON.parse(stdout);
 }
 await writeFile(home+'/config.toml',`model="owned-fixture"\nmodel_provider="owned"\ncheck_for_update_on_startup=false\ncli_auth_credentials_store="file"\n[features]\napps=false\nplugins=false\ngoals=true\ndaemon_auto_start=false\n[analytics]\nenabled=false\n[model_providers.owned]\nname="Owned local fixture"\nbase_url="http://127.0.0.1:${provider.address().port}/v1"\nwire_api="responses"\nrequires_openai_auth=false\n`,{mode:0o600});
 let source=await server(home);
 const selected=(await source.request('thread/start',{cwd:root,approvalPolicy:'never',sandbox:'read-only'})).thread.id;
 const turn=await source.request('turn/start',{threadId:selected,input:[{type:'text',text:'OWNED_RETIREMENT_USER'}]});await source.complete(selected,turn.turn.id);
 await source.request('thread/goal/set',{threadId:selected,objective:'Keep the retired Goal exactly',status:'paused',tokenBudget:1234});
 assert.match(selected,/^[0-9a-f-]{36}$/);
 // Give this owned paused fixture nonzero counters, so a reset-to-zero bug
 // cannot pass the retirement/return preservation check.
 execFileSync('/usr/bin/sqlite3',[home+'/goals_1.sqlite',`UPDATE thread_goals SET tokens_used=37,time_used_seconds=19 WHERE thread_id='${selected}' AND status='paused'`]);
 const originalGoal=(await source.request('thread/goal/get',{threadId:selected})).goal;
 assert.equal(originalGoal.tokensUsed,37);assert.equal(originalGoal.timeUsedSeconds,19);
 const goalRow=()=>JSON.parse(execFileSync('/usr/bin/sqlite3',['-json',home+'/goals_1.sqlite',`SELECT * FROM thread_goals WHERE thread_id='${selected}'`],{encoding:'utf8'}));
 const originalGoalRow=goalRow();assert.equal(originalGoalRow.length,1);
 const sibling=(await source.request('thread/start',{cwd:root,approvalPolicy:'never',sandbox:'read-only'})).thread.id;
 await source.request('thread/goal/set',{threadId:sibling,objective:'Leave the other live thread alone',status:'paused'});
 const siblingGoal=(await source.request('thread/goal/get',{threadId:sibling})).goal;
 const sourcePID=source.child.pid;
 await source.request('thread/archive',{threadId:selected});
 assert.ok(!(await source.request('thread/loaded/list',{})).data.includes(selected),'Archive must actually unload the selected runtime');
 const candidates=(await readdir(home+'/archived_sessions',{recursive:true})).filter(name=>name.endsWith('.jsonl')&&name.includes(selected));
 assert.equal(candidates.length,1);
 const archive=home+'/archived_sessions/'+candidates[0],original=await readFile(archive),originalInfo=await stat(archive);
 assert.ok(original.includes('OWNED_RETIREMENT_USER')&&original.includes('OWNED_RETIRED_HISTORY'));
 // A same-filesystem rename retains the original inode and all bytes. Record
 // intent before it. This fixture knows its entire scope; it grants no such
 // authority for an unknown user's TUI or shared subscriber.
 const quarantine=home+'/.autoapprove-migrations/retired/'+selected;
 let saved;
 if(swiftRetirement){
  assert.equal((await production('prepare',selected,archive)).state,'reserved');
  assert.equal((await production('reject-checkpoint',selected,archive)).rejected,true);
  assert.equal((await production('reject-scope',selected,archive)).rejected,true);
  assert.equal((await production('prepare-again',selected,archive)).rejected,true);
  const race=await Promise.allSettled([production('withdraw',selected,archive),production('withdraw',selected,archive)]);
  assert.ok(race.some(result=>result.status==='fulfilled'&&result.value.state==='withheld'));
  assert.equal((await production('withdraw',selected,archive)).state,'withheld');
  assert.equal(await readFile(root+'/count-'+selected+'-withdraw','utf8'),'1\n','Competing and repeated calls may rename only once');
  const driver=JSON.parse(await readFile(root+'/driver-'+selected+'.json','utf8'));
  saved=home+'/.autoapprove-migrations/official-retired/'+driver.intent.requestID+'-'+selected+'/rollout.jsonl';
 }else{
  await mkdir(quarantine,{recursive:true,mode:0o700});
  await writeFile(quarantine+'/intent.json',JSON.stringify({thread:selected,originalPath:archive,sha256:digest(original)}),{mode:0o600,flag:'wx'});
  await syncFile(quarantine+'/intent.json');await syncFile(quarantine);
  saved=quarantine+'/rollout.jsonl';await rename(archive,saved);await syncFile(saved);await syncFile(path.dirname(archive));await syncFile(quarantine);
 }
 assert.equal((await stat(saved)).ino,originalInfo.ino);assert.equal(digest(await readFile(saved)),digest(original));
 async function rejectReopen(host){
  await assert.rejects(host.request('thread/resume',{threadId:selected}));
  await assert.rejects(host.request('thread/resume',{threadId:selected,path:archive}));
  // Unarchive is itself a reopening route and cannot bypass missing bytes.
  await assert.rejects(host.request('thread/unarchive',{threadId:selected}));
  assert.ok(!(await host.request('thread/loaded/list',{})).data.includes(selected));
 }
 await rejectReopen(source);
 assert.equal(source.child.pid,sourcePID);assert.ok(alive(source.child));
 assert.equal((await source.request('thread/read',{threadId:sibling,includeTurns:false})).thread.id,sibling);
 assert.deepEqual((await source.request('thread/goal/get',{threadId:sibling})).goal,siblingGoal);
 // Public Goal lookup resolves the rollout first; withholding the rollout also
 // hides that lookup. The stored Goal itself must remain byte-for-byte exact.
 await assert.rejects(source.request('thread/goal/get',{threadId:selected}));
 assert.deepEqual(goalRow(),originalGoalRow);
 // A separate original process proves this property is not an in-memory
 // ownership flag or a held lock that disappears when AutoApprove exits.
 const cold=await server(home);await rejectReopen(cold);await stop(cold.child);
 assert.equal(source.child.pid,sourcePID);assert.ok(alive(source.child));
 if(swiftRetirement){
  assert.equal((await production('inspect',selected,archive)).state,'withheld');
  // An independently created original-path entry must never be overwritten.
  await writeFile(archive,'OWNED_COLLIDING_ORIGINAL',{mode:0o600,flag:'wx'});
  assert.equal((await production('return',selected,archive)).state,'review');
  assert.equal(await readFile(archive,'utf8'),'OWNED_COLLIDING_ORIGINAL');
  assert.equal(digest(await readFile(saved)),digest(original));
  await rename(archive,root+'/owned-collision');
  const outside=root+'/owned-outside';await writeFile(outside,'OWNED_OUTSIDE_UNCHANGED',{mode:0o600});
  await symlink(outside,archive);
  assert.equal((await production('return',selected,archive)).state,'review');
  assert.equal(await readFile(outside,'utf8'),'OWNED_OUTSIDE_UNCHANGED');await unlink(archive);
  // Identical bytes do not authorize replacing the retained original inode.
  const retained=root+'/owned-original-inode';await rename(saved,retained);await writeFile(saved,original,{mode:0o600,flag:'wx'});
  await assert.rejects(production('inspect',selected,archive));
  await assert.rejects(production('withdraw',selected,archive));
  assert.equal(digest(await readFile(retained)),digest(original));
  await rename(saved,root+'/owned-unaccepted-copy');await rename(retained,saved);
  const alias=root+'/owned-hardlink';await link(saved,alias);
  await assert.rejects(production('inspect',selected,archive));await unlink(alias);
  assert.equal((await production('inspect',selected,archive)).state,'withheld');
 }
 // Returning the exact original file re-enables ordinary public resume.
 if(swiftRetirement){
  assert.equal((await production('return',selected,archive)).state,'returned');
  assert.equal((await production('return',selected,archive)).state,'returned');
  assert.equal(await readFile(root+'/count-'+selected+'-return','utf8'),'1\n');
  assert.equal((await production('finish',selected,archive)).finished,true);
  assert.equal((await production('reject-terminal',selected,archive)).rejected,true);
 }else{await rename(saved,archive);await syncFile(archive);await syncFile(path.dirname(archive));await syncFile(quarantine);}
 await source.request('thread/unarchive',{threadId:selected});
 const resumed=await source.request('thread/resume',{threadId:selected});assert.equal(resumed.thread.id,selected);
 assert.deepEqual((await source.request('thread/goal/get',{threadId:selected})).goal,originalGoal);
 const history=JSON.stringify(await source.request('thread/read',{threadId:selected,includeTurns:true}));
 assert.ok(history.includes('OWNED_RETIREMENT_USER')&&history.includes('OWNED_RETIRED_HISTORY'));
 assert.deepEqual((await source.request('thread/goal/get',{threadId:sibling})).goal,siblingGoal);
 if(crashRetirement){
  const cases=[['prepare-crash',79,'reserved'],['withdraw-attempt-crash',80,'review'],['withdraw-rename-crash',81,'withheld'],
   ['return-attempt-crash',82,'review'],['return-rename-crash',83,'returned']];
  for(const [action,exit,state] of cases){
   const id=(await source.request('thread/start',{cwd:root,approvalPolicy:'never',sandbox:'read-only'})).thread.id;
   const {turn}=await source.request('turn/start',{threadId:id,input:[{type:'text',text:'OWNED_INDEPENDENT_CRASH_CASE'}]});await source.complete(id,turn.id);
   await source.request('thread/goal/set',{threadId:id,objective:'Owned independent retirement crash',status:'paused',tokenBudget:1234});
   await source.request('thread/archive',{threadId:id});
   const entries=(await readdir(home+'/archived_sessions',{recursive:true})).filter(name=>name.endsWith('.jsonl')&&name.includes(id));assert.equal(entries.length,1);
   const file=home+'/archived_sessions/'+entries[0],before=await readFile(file);
   if(action!=='prepare-crash')assert.equal((await production('prepare',id,file)).state,'reserved');
   if(action.startsWith('return'))assert.equal((await production('withdraw',id,file)).state,'withheld');
   await assert.rejects(production(action,id,file),error=>error.code===exit,'Crash the owned helper at the exact durable boundary');
   assert.equal((await production('recover',id,file)).state,state,'A fresh process must reconstruct physical state from the immutable intent');
   if(action!=='prepare-crash'){
    const op=action.startsWith('return')?'return':'withdraw';
    assert.equal((await production(op,id,file)).state,state,'Previously attempted effects must only be observed');
    const count=await readFile(root+'/count-'+id+'-'+op,'utf8').catch(error=>{if(error.code==='ENOENT')return '';throw error;});
    assert.equal(count,action.includes('rename')?'1\n':'','A crash cannot replay the rename');
   }
   if(state==='reserved'||state==='returned')assert.equal(digest(await readFile(file)),digest(before),'The original file must remain exact');
   else {
    const driver=JSON.parse(await readFile(root+'/driver-'+id+'.json','utf8'));
    const saved=home+'/.autoapprove-migrations/official-retired/'+driver.intent.requestID+'-'+id+'/rollout.jsonl';
    if(action.startsWith('withdraw-attempt'))assert.equal(digest(await readFile(file)),digest(before));
    else assert.equal(digest(await readFile(saved)),digest(before),'The retained file must remain exact');
   }
   assert.equal((await production('recover-finish',id,file)).finished,true);
  }
 }
 assert.deepEqual((await source.request('thread/goal/get',{threadId:sibling})).goal,siblingGoal);
 assert.ok(alive(source.child)&&source.child.pid===sourcePID);
 assert.equal(posts,crashRetirement?6:1,'Only the declared fixture seed turns may run');
 console.log(JSON.stringify({verified:true,officialVersion:'0.169.0',originalArchiveRetained:true,liveSourceReopenBlocked:true,
  coldSourceReopenBlocked:true,unarchiveCannotBypass:true,sharedServerNotRestarted:true,otherGoalPreserved:true,
  goalIdentityAndAccountingPreserved:true,returnRestoresSameUUIDAndHistory:true,modelTurns:posts,
  productionRetirementPrimitive:swiftRetirement,concurrentAndRepeatedRenameAppliedOnce:swiftRetirement,
  conflictingOriginalNeverOverwritten:swiftRetirement,symlinkTargetNeverWritten:swiftRetirement,
  replacedRetainedInodeAndHardlinkRejected:swiftRetirement,
  prepareCrashRecoversWithoutCallerReceipt:crashRetirement,beforeRenameCrashNeverReplayed:crashRetirement,
  lostRenameAcknowledgmentObservedWithoutReplay:crashRetirement,abortReturnCrashNeverReplayed:crashRetirement,
  userSessionsTouched:false,productionMigrationImplemented:false,completeClientOwnershipProven:false}));
}catch(error){
 if(process.argv.includes('--keep-on-failure')){kept=true;console.error('Owned failure artifacts: '+root);}
 throw error;
}finally{
 for(const child of children)await stop(child);provider.closeAllConnections();provider.close();
 if(!kept)await rm(root,{recursive:true,force:true});
}
