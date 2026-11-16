// Feasibility only: an original TUI started through an owned, stable Unix relay.
// Known fixture scope is NOT discovery of an arbitrary already-running client.
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,copyFile,chmod,rename,stat,rm} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {once} from 'node:events';

const cli=process.argv.find(v=>v.startsWith('--codex='))?.slice(8);
assert.ok(cli&&path.isAbsolute(cli),'Provide original native --codex=');
execFileSync('/usr/bin/codesign',['--verify','--strict','-R=anchor apple generic and identifier "codex" and certificate leaf[subject.OU] = "2DC432GLL2"',cli],{stdio:'inherit'});
assert.equal(execFileSync(cli,['--version'],{encoding:'utf8'}).trim(),'codex-cli 0.169.0');
const require=createRequire(import.meta.url),{WebSocket}=require(process.env.AUTOAPPROVE_WEBSOCKET_MODULE||path.resolve('.runtime/official-codex-probe-deps/node_modules/ws'));
const {Terminal}=require(path.resolve('extensions/vscode/node_modules/@xterm/headless'));
const root=await mkdtemp('/private/tmp/aa-official-retained-'),sourceHome=root+'/a',destinationHome=root+'/b';
const ownedServer=root+'/owned-original-server';
const directAdoption=process.argv.includes('--direct-adoption-probe');
const overviewOwnership=process.argv.includes('--overview-ownership-probe');
const cooperativeAdoption=process.argv.includes('--cooperative-adoption-probe');
assert.ok([directAdoption,overviewOwnership,cooperativeAdoption].filter(Boolean).length<=1,'Use one owned feasibility probe at a time');
const startsDirect=directAdoption||cooperativeAdoption;
const env={HOME:root,PATH:'/usr/bin:/bin',TERM:'xterm-256color',HTTP_PROXY:'http://127.0.0.1:9',HTTPS_PROXY:'http://127.0.0.1:9',NO_PROXY:'127.0.0.1,localhost'};
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms)),alive=p=>p&&p.exitCode===null&&p.signalCode===null;
const processes=new Set(),connections=new Set(),clients=[];let tui,stderr='',posts=0,kept=false,relayTarget=root+'/a.sock',relayConnections=0,relayListening=false;
const tuiRequests=[];
const terminal=new Terminal({cols:140,rows:45,allowProposedApi:true});
const screen=()=>Array.from({length:terminal.rows},(_,i)=>terminal.buffer.active.getLine(terminal.buffer.active.viewportY+i)?.translateToString(true)||'').join('\n');
const keys=value=>{assert.ok(alive(tui),'Owned TUI must be running');tui.stdin.write(JSON.stringify({keys:value})+'\n');};
terminal.onData(value=>{if(alive(tui))keys(value);});
async function until(check,label){
 const end=Date.now()+45000;
 while(Date.now()<end){if(await check())return;if(tui&&!alive(tui))break;await delay(60);}
 await writeFile(root+'/failure-screen.txt',screen());throw Error('Owned retained-state timeout: '+label+' '+stderr.slice(-2000));
}
async function stop(p){
 if(!alive(p))return;const done=once(p,'exit');p.kill('SIGTERM');const timer=setTimeout(()=>p.kill('SIGKILL'),3000);
 try{await done;}finally{clearTimeout(timer);processes.delete(p);}
}
async function assertIsolatedHomes(){
 for(const home of [sourceHome,destinationHome])assert.equal(await stat(home+'/app-server-daemon/daemon.pid').then(()=>true,error=>{
  if(error.code==='ENOENT')return false;throw error;
 }),false,'An outside manager must not create a daemon in the owned fixture home');
}
const provider=http.createServer(async(req,res)=>{
 let body='';for await(const chunk of req)body+=chunk;
 const data=JSON.parse(body),input=JSON.stringify(data.input),id='owned-retained-'+(++posts);
 const text=input.includes('OWNED_SEED_A')?'OWNED_HISTORY_A':input.includes('OWNED_SEED_B')?'OWNED_HISTORY_B':'OWNED_HISTORY_OTHER';
 const item={id:id+'-message',type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text,annotations:[]}]};
 res.writeHead(200,{'Content-Type':'text/event-stream'});
 for(const event of [{type:'response.created',response:{id,status:'in_progress',output:[]}},
  {type:'response.output_item.added',output_index:0,item},{type:'response.output_item.done',output_index:0,item},
  {type:'response.completed',response:{id,status:'completed',output:[item],usage:{input_tokens:1,output_tokens:1,total_tokens:2}}}])res.write('data: '+JSON.stringify(event)+'\n\n');
 res.end();
});
// The relay only routes one selected TUI, and never interprets model requests.
const relay=net.createServer(client=>{
 relayConnections++;const upstream=net.connect(relayTarget),pair={client,upstream};connections.add(pair);
 if(overviewOwnership||cooperativeAdoption){
  let bytes=Buffer.alloc(0),upgraded=false,fragments=[];
  client.on('data',chunk=>{
   // Observe this fixture's original TUI requests without altering or answering
   // them. Retain method/UUID only; discard prompts, drafts and config bodies.
   bytes=Buffer.concat([bytes,chunk]);assert.ok(bytes.length<=2_100_000,'Bound owned frame inspection');
   if(!upgraded){const end=bytes.indexOf('\r\n\r\n');if(end<0)return;bytes=bytes.subarray(end+4);upgraded=true;}
   while(bytes.length>=2){
    const opcode=bytes[0]&15,final=Boolean(bytes[0]&128);assert.equal(bytes[0]&112,0,'Uncompressed owned request');
    assert.ok(bytes[1]&128,'Client frames must be masked');let length=bytes[1]&127,offset=2;
    if(length===126){if(bytes.length<4)return;length=bytes.readUInt16BE(2);offset=4;}
    else if(length===127){if(bytes.length<10)return;const wide=bytes.readBigUInt64BE(2);assert.ok(wide<=2_000_000n);length=Number(wide);offset=10;}
    if(bytes.length<offset+4+length)return;
    const mask=bytes.subarray(offset,offset+4),payload=Buffer.from(bytes.subarray(offset+4,offset+4+length));
    bytes=bytes.subarray(offset+4+length);for(let i=0;i<payload.length;i++)payload[i]^=mask[i%4];
    if(opcode===1||opcode===0){
     if(opcode===1)assert.equal(fragments.length,0);fragments.push(payload);
     assert.ok(fragments.reduce((n,b)=>n+b.length,0)<=2_000_000);
     if(final){const message=JSON.parse(Buffer.concat(fragments).toString('utf8'));fragments=[];
      if(typeof message.method==='string')tuiRequests.push({method:message.method,thread:message.params?.threadId});
     }
    }
   }
  });
 }
 client.on('error',()=>upstream.destroy());upstream.on('error',()=>client.destroy());
 client.on('close',()=>{upstream.destroy();connections.delete(pair);});upstream.on('close',()=>client.destroy());
 client.pipe(upstream);upstream.pipe(client);
});
async function startServer(home,socket,reuse=false){
 await mkdir(home,{mode:0o700,recursive:reuse});
 if(!reuse){
 await writeFile(home+'/config.toml',`model="owned-fixture"\nmodel_provider="owned"\napproval_policy="never"\nsandbox_mode="read-only"\ncli_auth_credentials_store="file"\ncheck_for_update_on_startup=false\n[tui.keymap.global]\nopen_agents=["f6"]\n[features]\napps=false\nplugins=false\ndaemon_auto_start=false\n[analytics]\nenabled=false\n[projects.${JSON.stringify(root)}]\ntrust_level="trusted"\n[model_providers.owned]\nname="Owned local fixture"\nbase_url="http://127.0.0.1:${provider.address().port}/v1"\nwire_api="responses"\nrequires_openai_auth=false\n`,{mode:0o600});
 }
 const process=spawn(ownedServer,['app-server','--listen','unix://'+socket],{cwd:root,env:{...env,CODEX_HOME:home},stdio:['ignore','ignore','pipe']});processes.add(process);
 process.stderr.on('data',bytes=>stderr=(stderr+bytes).slice(-4000));
 await until(()=>stat(socket).then(s=>s.isSocket(),()=>false),'owned socket');
 const ws=new WebSocket('ws+unix://'+socket+':/');clients.push(ws);await once(ws,'open');let seq=0;const pending=new Map(),events=[];
 ws.on('message',bytes=>{
  const m=JSON.parse(bytes);if(m.id!==undefined&&!m.method){const p=pending.get(m.id);pending.delete(m.id);if(p)m.error?p.reject(Error(m.error.message)):p.resolve(m.result);}else events.push(m);
 });
 const request=(method,params={})=>new Promise((resolve,reject)=>{
  const id=++seq,timer=setTimeout(()=>{pending.delete(id);reject(Error('Owned RPC timeout '+method));},15000);
  pending.set(id,{resolve:value=>{clearTimeout(timer);resolve(value)},reject:error=>{clearTimeout(timer);reject(error)}});ws.send(JSON.stringify({id,method,params}));
 });
 await request('initialize',{clientInfo:{name:'owned-retained-reconnect',version:'1'},capabilities:{experimentalApi:true}});ws.send(JSON.stringify({method:'initialized'}));
 return {process,request,events};
}
probe: try{
 // Keep live AutoApprove discovery from enrolling these throwaway homes.
 // The copied executable retains OpenAI's original signature and bytes; only
 // its fixture basename differs, as with the already-isolated TUI below.
 await copyFile(cli,ownedServer);await chmod(ownedServer,0o700);
 execFileSync('/usr/bin/codesign',['--verify','--strict','-R=anchor apple generic and identifier "codex" and certificate leaf[subject.OU] = "2DC432GLL2"',ownedServer],{stdio:'inherit'});
 await new Promise(resolve=>provider.listen(0,'127.0.0.1',resolve));
 const source=await startServer(sourceHome,root+'/a.sock'),destination=await startServer(destinationHome,root+'/b.sock');
 async function seed(marker,name){
  const row=await source.request('thread/start',{cwd:root,approvalPolicy:'never',sandbox:'read-only'}),id=row.thread.id;
  const {turn}=await source.request('turn/start',{threadId:id,input:[{type:'text',text:marker}]});
  await until(()=>source.events.some(m=>m.method==='turn/completed'&&m.params.threadId===id&&m.params.turn.id===turn.id),'owned seed completion');
  await source.request('thread/name/set',{threadId:id,name});
  return (await source.request('thread/read',{threadId:id,includeTurns:true})).thread;
 }
 const a=await seed('OWNED_SEED_A','RetainedAlpha'),b=await seed('OWNED_SEED_B','RetainedBeta');
 const other=(await source.request('thread/start',{cwd:root,approvalPolicy:'never',sandbox:'read-only'})).thread.id;
 if(overviewOwnership)await source.request('thread/name/set',{threadId:other,name:'CatalogOnlyGamma'});
 await source.request('thread/goal/set',{threadId:other,objective:'Unselected original runtime',status:'paused'});
 const otherGoal=(await source.request('thread/goal/get',{threadId:other})).goal,sourcePID=source.process.pid;
 if(!startsDirect){await new Promise(resolve=>relay.listen(root+'/relay.sock',resolve));relayListening=true;}
 const ownedTUI=root+'/owned-retained-tui';await copyFile(cli,ownedTUI);await chmod(ownedTUI,0o700);
 function openTUI(endpoint,thread){
  tui=spawn('/usr/bin/python3',[path.resolve('Tests/fixtures/codex-approval-pty.py'),ownedTUI,'--remote','unix://'+endpoint,'--no-alt-screen','resume',thread],{cwd:root,env:{...env,CODEX_HOME:sourceHome,OWNED_APPROVAL_COLUMNS:'140'},stdio:['pipe','pipe','pipe']});processes.add(tui);
  tui.stderr.on('data',bytes=>stderr=(stderr+bytes).slice(-4000));let partial='';
  tui.stdout.on('data',bytes=>{partial+=bytes;let n;while((n=partial.indexOf('\n'))>=0){const line=partial.slice(0,n);partial=partial.slice(n+1);terminal.write(Buffer.from(JSON.parse(line).bytes,'base64'));}});
 }
 openTUI(startsDirect?root+'/a.sock':root+'/relay.sock',a.id);
 await until(()=>screen().includes('OWNED_HISTORY_A')&&screen().includes('Ask Codex'),'original TUI ready');
 const tuiPID=tui.pid,draftA='OWNED_ALPHA_DRAFT_가나다',draftB='OWNED_BETA_DRAFT_라마바';
 const nativeChildren=execFileSync('/bin/ps',['-axo','pid=,ppid=,comm='],{encoding:'utf8'}).split('\n')
  .map(line=>line.match(/^\s*(\d+)\s+(\d+)\s+(.+)$/)).filter(row=>row&&Number(row[2])===tuiPID&&row[3]===ownedTUI);
 assert.equal(nativeChildren.length,1,'Exactly one owned original native TUI child');
 const nativePID=nativeChildren[0][1];
 const nativeIdentity=()=>execFileSync('/bin/ps',['-p',nativePID,'-o','pid=,ppid=,lstart=,comm='],{encoding:'utf8'}).trim();
 const originalNativeIdentity=nativeIdentity();
 async function highlight(name){
  keys('\u001b[17~');await until(()=>screen().includes('RetainedAlpha')&&screen().includes('RetainedBeta'),'agent command center');
  const rows=screen().split('\n'),selected=rows.findIndex(row=>/^\s*›\s*[○●]/u.test(row));
  const target=rows.findIndex(row=>/^\s*(?:›\s*)?[○●]/u.test(row)&&row.includes(name));
  assert.ok(selected>=0&&target>=0,'Exact selected and target rows must be visible');
  for(let i=0;i<Math.abs(target-selected);i++){keys(target>selected?'\u001b[B':'\u001b[A');await delay(100);}
  await until(()=>screen().split('\n').some(row=>/^\s*›\s*[○●]/u.test(row)&&row.includes(name)),'exact highlighted agent');
 }
 async function select(name,history){
  await highlight(name);
  keys('\r');await until(()=>screen().includes(history)&&!screen().includes('Agent command center'),'selected '+name);
 }
 keys(draftA);await until(()=>screen().includes(draftA),'first draft');
 await select('RetainedBeta','OWNED_HISTORY_B');keys(draftB);await until(()=>screen().includes(draftB),'second draft');
 await select('RetainedAlpha','OWNED_HISTORY_A');assert.ok(screen().includes(draftA),'First offscreen draft must already survive navigation');
 await select('RetainedBeta','OWNED_HISTORY_B');assert.ok(screen().includes(draftB),'Second offscreen draft must already survive navigation');
 console.error('Owned two-draft navigation established.');
 if(cooperativeAdoption){
  // No real or active shared workload is restarted. This is an explicit
  // controlled enrollment experiment, not selected-client migration authority.
  const loaded=(await source.request('thread/loaded/list')).data;
  assert.deepEqual(new Set(loaded),new Set([a.id,b.id,other]));
  for(const id of loaded){
   assert.equal((await source.request('thread/read',{threadId:id,includeTurns:false})).thread.status.type,'idle');
   assert.equal((await source.request('thread/queue/list',{threadId:id,limit:1})).data.length,0);
   assert.equal((await source.request('thread/backgroundTerminals/list',{threadId:id,limit:1})).data.length,0);
  }
  const replacement=await startServer(sourceHome,root+'/replacement-a.sock',true);
  relayTarget=root+'/replacement-a.sock';
  // Bind after the original exits, so its normal pathname cleanup cannot
  // unlink the new listener. The original TUI's native retries bridge the gap.
  await rename(root+'/a.sock',root+'/original-a.sock');
  await stop(source.process);
  await new Promise(resolve=>relay.listen(root+'/a.sock',resolve));relayListening=true;
  await until(()=>relayConnections>0&&screen().includes(draftB)&&!screen().includes('Reconnecting'),'same-home cooperative direct-client enrollment');
  const methods=id=>[...new Set(tuiRequests.filter(r=>r.thread===id).map(r=>r.method))].sort();
  const visibleMethods=methods(b.id),offscreenMethods=methods(a.id),catalogueMethods=methods(other);
  assert.ok(visibleMethods.includes('thread/resume'),'Native reconnect must use the newly inserted relay');
  assert.equal(nativeIdentity(),originalNativeIdentity);
  await select('RetainedAlpha','OWNED_HISTORY_A');assert.ok(screen().includes(draftA));
  await select('RetainedBeta','OWNED_HISTORY_B');assert.ok(screen().includes(draftB));
  assert.deepEqual((await replacement.request('thread/goal/get',{threadId:other})).goal,otherGoal);
  for(const thread of [a,b]){
   const history=JSON.stringify(await replacement.request('thread/read',{threadId:thread.id,includeTurns:true}));
   assert.ok(history.includes('OWNED_SEED_')&&history.includes('OWNED_HISTORY_'));
   assert.ok(!history.includes(draftA)&&!history.includes(draftB));
  }
  assert.equal(posts,2);await assertIsolatedHomes();
  console.log(JSON.stringify({verified:true,officialVersion:'0.169.0',originalRuntimeUnmodified:true,
   directClientStartedWithoutRelay:true,sameHomeCooperativeAdoption:true,originalNativeProcessRetained:true,
   twoOffscreenDraftsRetained:true,goalAndHistoryRetained:true,modelTurns:posts,
   sourceRestartRequired:true,sourceVerifiedIdleBeforeRestart:true,activeWorkPreservationProven:false,
   reconnectReferenceMethods:{visible:visibleMethods,offscreen:offscreenMethods,catalogue:catalogueMethods},
   completeClientOwnershipProven:false,arbitraryDirectClientAdoptionProven:false,crossHomeMigrationProven:false,userSessionsTouched:false}));
  break probe;
 }
 if(overviewOwnership){
  // Gamma is a catalogue row, never opened by this TUI. Alpha has a retained
  // draft, then is hidden locally; a visible-row sweep cannot identify either
  // complete ownership or every retained input state.
  await highlight('RetainedAlpha');
  await until(()=>screen().includes('CatalogOnlyGamma'),'unopened catalogue row is visible');
  assert.ok(tuiRequests.some(r=>r.method==='thread/resume'&&r.thread===a.id));
  assert.ok(tuiRequests.some(r=>r.method==='thread/resume'&&r.thread===b.id));
  assert.ok(!tuiRequests.some(r=>['thread/resume','thread/fork'].includes(r.method)&&r.thread===other));
  keys('h');
  await until(()=>screen().includes('RetainedBeta')&&screen().includes('CatalogOnlyGamma')&&!screen().includes('RetainedAlpha'),'draft-owning root hidden locally');
  const hiddenOverview=screen();
  const loaded=(await source.request('thread/loaded/list')).data;
  assert.ok([a.id,b.id,other].every(id=>loaded.includes(id)));
  const publicAlpha=JSON.stringify(await source.request('thread/read',{threadId:a.id,includeTurns:true}));
  assert.ok(!publicAlpha.includes(draftA),'Public history does not disclose the retained draft');
  keys('\u001b');await until(()=>screen().includes(draftB)&&!screen().includes('Agent command center'),'original Beta composer restored');
  keys('\u0015');await until(()=>screen().includes('Ask Codex')&&!screen().includes(draftB),'clear only the owned visible draft');
  keys('/resume');await delay(300);keys('\r');
  await until(()=>screen().includes('Resume a previous session'),'native session picker');
  keys('RetainedAlpha');
  await until(()=>screen().includes('Search: RetainedAlpha')&&screen().split('\n').some(row=>row.includes('RetainedAlpha')&&!row.includes('Search:'))&&!screen().includes('Searching…'),'exact hidden Alpha picker match');
  keys('\r');
  await until(()=>screen().includes('OWNED_HISTORY_A')&&screen().includes(draftA)&&!screen().includes('Resume a previous session'),'native picker restores the hidden offscreen draft');
  await select('RetainedBeta','OWNED_HISTORY_B');
  await until(()=>screen().includes('Ask Codex')&&!screen().includes(draftB),'empty owned Beta after picker round trip');
  keys('/resume '+a.id);await delay(300);keys('\r');
  await until(()=>screen().includes('OWNED_HISTORY_A')&&screen().includes('Ask Codex'),'hidden Alpha history reopened by explicit native resume');
  assert.ok(!screen().includes(draftA),'Native explicit resume does not restore the known offscreen draft');
  assert.ok(tuiRequests.filter(r=>r.method==='thread/resume'&&r.thread===a.id).length>=2,'Explicit resume must use this same owned original backend');
  assert.equal(nativeIdentity(),originalNativeIdentity);
  assert.deepEqual((await source.request('thread/goal/get',{threadId:other})).goal,otherGoal);
  assert.equal(posts,2,'Ownership probing may not submit drafts or new turns');
  assert.ok(!hiddenOverview.includes('RetainedAlpha'));
  await assertIsolatedHomes();
  console.log(JSON.stringify({verified:true,officialVersion:'0.169.0',originalRuntimeUnmodified:true,
   catalogueIncludesUnopenedRoot:true,knownOffscreenDraftBeforeHide:true,hiddenRootOmittedFromOverview:true,
   nativePickerRestoresHiddenDraft:true,nativeExplicitResumeRestoresKnownDraft:false,publicHistoryOmitsRetainedDraft:true,
   loadedSetDoesNotIdentifyTuiOwnership:true,visibleOverviewIsNotCompleteInputInventory:true,
   exactTuiRequestsObservedWithoutModification:true,originalNativeProcessRetained:true,
   unselectedGoalRetained:true,modelTurns:posts,completeClientOwnershipProven:false,userSessionsTouched:false}));
  break probe;
 }
 if(directAdoption){
  // Changing the pathname does not retarget already-connected Unix sockets.
  // Prove the replacement listener is live while the existing TUI bypasses it.
  await rename(root+'/a.sock',root+'/original-a.sock');relayTarget=root+'/b.sock';
  await new Promise(resolve=>relay.listen(root+'/a.sock',resolve));relayListening=true;
  const marker=(await destination.request('thread/start',{cwd:root,approvalPolicy:'never',sandbox:'read-only'})).thread.id;
  const probeWS=new WebSocket('ws+unix://'+root+'/a.sock:/');clients.push(probeWS);await once(probeWS,'open');
  let sequence=0;const pending=new Map();
  probeWS.on('message',bytes=>{const m=JSON.parse(bytes),p=pending.get(m.id);if(!m.method&&p){pending.delete(m.id);m.error?p.reject(Error(m.error.message)):p.resolve(m.result);}});
  const request=(method,params={})=>new Promise((resolve,reject)=>{
   const id=++sequence,timer=setTimeout(()=>{pending.delete(id);reject(Error('Owned replacement endpoint probe timed out'));},15000);
   pending.set(id,{resolve:result=>{clearTimeout(timer);resolve(result)},reject:error=>{clearTimeout(timer);reject(error)}});probeWS.send(JSON.stringify({id,method,params}));
  });
  await request('initialize',{clientInfo:{name:'owned-replacement-listener',version:'1'},capabilities:{experimentalApi:true}});probeWS.send(JSON.stringify({method:'initialized'}));
  const loaded=(await request('thread/loaded/list')).data;assert.ok(loaded.includes(marker)&&!loaded.includes(a.id)&&!loaded.includes(b.id));
  probeWS.terminate();await delay(800);
  assert.equal(relayConnections,1,'Only the explicit endpoint probe may connect; original TUI is not adopted');
  assert.equal(nativeIdentity(),originalNativeIdentity);assert.ok(screen().includes(draftB));
  assert.ok(alive(source.process)&&source.process.pid===sourcePID);
  // Exit cleanly. Clear only the visible Beta draft to enter /quit; the Alpha
  // draft stays untouched in a different retained conversation throughout.
  const closed=once(tui,'close');keys('\u0015');
  await until(()=>screen().includes('Ask Codex')&&!screen().includes(draftB),'clear only visible fixture draft');
  keys('/quit');await delay(300);keys('\r');await until(()=>!alive(tui),'clean original TUI exit');await closed;
  await new Promise(resolve=>terminal.write('',resolve));terminal.reset();
  openTUI(root+'/original-a.sock',b.id);
  await until(()=>screen().includes('OWNED_HISTORY_B')&&screen().includes('Ask Codex'),'fresh original TUI with same home and history');
  await select('RetainedAlpha','OWNED_HISTORY_A');
  assert.ok(!screen().includes(draftA),'A clean restart does not restore the untouched hidden Alpha draft');
  assert.deepEqual((await source.request('thread/goal/get',{threadId:other})).goal,otherGoal);
  assert.equal(posts,2,'Adoption probing and restart may not submit any draft or model turn');
  await assertIsolatedHomes();
  console.log(JSON.stringify({verified:true,officialVersion:'0.169.0',directClientStartedWithoutRelay:true,
   replacementListenerRoutesToDestination:true,replacingListenerDoesNotAdoptLiveClient:true,
   cleanRestartRestoresHistory:true,hiddenDraftRestoredAfterCleanRestart:false,sharedSourceServerNotRestarted:true,
   unselectedGoalRetained:true,modelTurns:posts,existingDirectClientAdoptionProven:false,userSessionsTouched:false}));
  break probe;
 }
 // The test's source set is explicitly known. No complete discovery is inferred
 // from a loaded list, current view, or relay connection count.
 const retired=root+'/owned-retired';await mkdir(retired,{mode:0o700});
 for(const thread of [a,b]){
  await source.request('thread/archive',{threadId:thread.id});
  const originalPath=path.relative(sourceHome,thread.path),archived=sourceHome+'/archived_sessions/'+path.basename(thread.path);
  const target=destinationHome+'/'+originalPath;await mkdir(path.dirname(target),{recursive:true});await copyFile(archived,target);
  await rename(archived,retired+'/'+path.basename(archived));
  const restored=await destination.request('thread/resume',{threadId:thread.id,path:target});assert.equal(restored.thread.id,thread.id);
  // Names live in the metadata store, not the rollout. Preserve them explicitly
  // through the public API instead of silently replacing them with first input.
  assert.ok(thread.name);await destination.request('thread/name/set',{threadId:thread.id,name:thread.name});
  assert.equal((await destination.request('thread/read',{threadId:thread.id,includeTurns:false})).thread.name,thread.name);
 }
 const before=relayConnections;relayTarget=root+'/b.sock';for(const pair of [...connections]){pair.client.destroy();pair.upstream.destroy();}
 await until(()=>relayConnections>before&&screen().includes(draftB)&&!screen().includes('Reconnecting'),'selected TUI reconnected to destination');
 assert.ok(alive(tui)&&tui.pid===tuiPID);
 assert.equal(nativeIdentity(),originalNativeIdentity,'The original native TUI process and lifetime must survive');
 console.error('Owned cross-home reconnect established.');
 await select('RetainedAlpha','OWNED_HISTORY_A');assert.ok(screen().includes(draftA),'Hidden first draft must survive cross-home reconnect');
 await select('RetainedBeta','OWNED_HISTORY_B');assert.ok(screen().includes(draftB),'Hidden second draft must survive cross-home reconnect');
 assert.ok(alive(source.process)&&source.process.pid===sourcePID);
 assert.deepEqual((await source.request('thread/goal/get',{threadId:other})).goal,otherGoal);
 for(const thread of [a,b]){
  const history=JSON.stringify(await destination.request('thread/read',{threadId:thread.id,includeTurns:true}));
  assert.ok(history.includes('OWNED_SEED_')&&history.includes('OWNED_HISTORY_'));
  assert.ok(!history.includes(draftA)&&!history.includes(draftB),'Unsent drafts may not become submitted history');
 }
 assert.equal(posts,2,'Navigation and reconnect may not submit drafts or model turns');
 await assertIsolatedHomes();
 console.log(JSON.stringify({verified:true,officialVersion:'0.169.0',originalTuiProcessRetained:true,twoOffscreenDraftsRetained:true,
  crossHomeHistoryAndUUIDRetained:true,threadNamesRetained:true,sharedSourceServerNotRestarted:true,unselectedGoalRetained:true,modelTurns:posts,
  existingDirectClientAdoptionProven:false,completeClientOwnershipProven:false,productionMigrationImplemented:false,userSessionsTouched:false}));
}catch(error){
 await writeFile(root+'/failure-screen.txt',screen());
 if(process.argv.includes('--keep-on-failure')){kept=true;console.error('Owned failure artifacts: '+root);}
 throw error;
}finally{
 for(const pair of connections){pair.client.destroy();pair.upstream.destroy();}if(relayListening)relay.close();for(const ws of clients)ws.terminate();
 for(const process of processes)await stop(process);provider.closeAllConnections();provider.close();terminal.dispose();
 if(!kept)await rm(root,{recursive:true,force:true});
}
