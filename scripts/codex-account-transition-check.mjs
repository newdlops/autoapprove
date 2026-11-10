import assert from 'node:assert/strict';
import {writeFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,rm,symlink,writeFile,readFile,chmod} from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const require=createRequire(import.meta.url);
const module=process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||require.resolve('playwright');
const ws=require(path.join(path.dirname(module),'../playwright-core/lib/utilsBundle.js'));
const build=path.resolve(process.env.AUTOAPPROVE_CHECK_BUILD||'.build/debug');
const directory=await mkdtemp('/private/tmp/aa-account-rpc-'),cli=directory+'/codex';
const server=http.createServer(),websocket=new ws.wsServer({noServer:true}),clients=new Set(),methods=[];
const ids=['00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000002'];
const housekeeping='00000000-0000-4000-8000-000000000003';
let mode='active',child,interrupts=0,refusals=0,goalPauses=0,backgroundStops=0;
const pausedGoals=new Set(),stoppedBackground=new Set();
const goalReads=new Map(),quiescenceFailures=[];
let interruptRejected=false,settlementReads=0;
try {
 await mkdir(directory+'/app-server-control');
 await writeFile(cli,`#!${process.execPath}\nimport fs from 'node:fs';import readline from 'node:readline';
const args=process.argv.slice(2),home=process.env.CODEX_HOME;
if(args.join(' ')==='app-server daemon version'){if(fs.existsSync(home+'/delay-version'))await new Promise(r=>setTimeout(r,500));const version=fs.existsSync(home+'/changed-server')?'0.167.0':'0.166.0';console.log(JSON.stringify({status:'running',backend:'pid',managedCodexPath:process.argv[1],managedCodexVersion:version,socketPath:home+'/app-server-control/app-server-control.sock',cliVersion:version,appServerVersion:version}));process.exit(0);}
if(args.join(' ')==='app-server daemon restart'){fs.appendFileSync(home+'/restart.log','restart\\n');process.exit(0);}
if(args.join(' ')!=='app-server --listen stdio://')process.exit(91);
for await(const line of readline.createInterface({input:process.stdin})){const m=JSON.parse(line);if(m.method==='initialized')continue;let result;if(m.method==='initialize')result={userAgent:'fixture'};else if(m.method==='accountSession/list'&&m.params.refreshWorkspaceMetadata===false)result={activeSessionId:'session-new',sessions:[{sessionId:'session-new',isActive:true,userId:'user-new',selectedWorkspaceAccountId:'workspace'}]};else process.exit(92);console.log(JSON.stringify({id:m.id,result}));}
`);
 await chmod(cli,0o700);
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/AccountTransport'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/codex-account-transition-transport.swift','-o',directory+'/check'],{stdio:'inherit',timeout:120000});
 server.on('upgrade',(request,socket,head)=>websocket.handleUpgrade(request,socket,head,connection=>websocket.emit('connection',connection)));
 websocket.on('connection',socket=>{
  let reads=0;
  clients.add(socket);socket.on('close',()=>clients.delete(socket));
  socket.on('message',bytes=>{
   const m=JSON.parse(bytes.toString());
   if(m.id==='approval'){assert.equal(m.error?.code,-32601);refusals++;return;}
   methods.push(m.method);if(m.method==='initialized')return;
   let result;
   switch(m.method){
    case 'initialize':socket.send(JSON.stringify({id:m.id,result:{userAgent:'fixture'}}));socket.send(JSON.stringify({id:'approval',method:'item/commandExecution/requestApproval',params:{}}));return;
    case 'accountSession/list':assert.equal(m.params.refreshWorkspaceMetadata,false);result={activeSessionId:'session-old',sessions:[{sessionId:'session-old',isActive:true,userId:'user-old',selectedWorkspaceAccountId:'workspace'}]};if(mode==='bad-account')delete result.sessions[0].userId;if(mode==='signed-out')result={activeSessionId:null,sessions:[]};break;
    case 'thread/loaded/list':result=mode==='repeat'?{data:[],nextCursor:'repeat'}:mode==='duplicate'?{data:[ids[0],ids[0]]}:m.params.cursor==='next'?{data:[ids[1]],nextCursor:null}:{data:mode.startsWith('housekeeping')?[ids[0],housekeeping]:[ids[0]],nextCursor:'next'};break;
    case 'thread/read':reads++;result={thread:{id:m.params.threadId,status:{type:mode==='unknown-status'?'unknown':mode.startsWith('system-error')&&!(mode==='system-error-race'&&reads>1)?'systemError':((mode==='active'||mode==='empty-active'||mode==='system-error-race'||mode==='empty-race'&&reads>1)&&m.params.threadId===ids[0])?'active':'idle'}}};if(m.params.threadId===housekeeping)Object.assign(result.thread,{id:mode==='housekeeping-bad-id'?ids[0]:housekeeping,ephemeral:mode!=='housekeeping-not-ephemeral',threadSource:mode==='housekeeping'?'thread_title':mode==='housekeeping-user'?'user':mode==='housekeeping-not-ephemeral'||mode==='housekeeping-bad-id'?'thread_title':'unknown',status:{type:'active',activeFlags:[]}});break;
    case 'thread/turns/list':if(m.params.threadId===housekeeping){socket.send(JSON.stringify({id:m.id,error:{code:-32600,message:'ephemeral threads do not support thread/turns/list'}}));return;}if(mode.startsWith('empty')){socket.send(JSON.stringify({id:m.id,error:{code:mode==='empty-code'?-32000:-32600,message:mode==='empty-other'?'different error':`thread ${mode==='empty-wrong'?'unrelated':m.params.threadId} is not materialized yet; thread/turns/list is unavailable before first user message`}}));return;}assert.equal(m.params.itemsView,'notLoaded');assert.equal(m.params.sortDirection,'desc');result={data:mode==='missing-turn'?[]:[{id:'turn-'+m.params.threadId,status:(mode==='active'&&m.params.threadId===ids[0])||mode==='system-error-in-progress'?'inProgress':mode.startsWith('system-error')?'failed':'completed'}]};break;
    case 'thread/queue/list':result={data:mode.startsWith('queue')||mode==='system-error-queue'?[{id:'queued'}]:[],nextCursor:null};break;
    case 'thread/backgroundTerminals/list':result={data:mode.includes('background')&&!stoppedBackground.has(m.params.threadId)?[{processId:'owned-background'}]:[],nextCursor:null};break;
    case 'thread/goal/get':if(mode==='goal-race'){const n=(goalReads.get(m.params.threadId)||0)+1;goalReads.set(m.params.threadId,n);result={goal:{status:n>=4?'complete':'active'}};}else result={goal:mode.includes('goal')?{status:pausedGoals.has(m.params.threadId)?'paused':'active'}:null};break;
    case 'thread/goal/set':assert.equal(m.params.status,'paused');assert.equal(m.params.origin,'automatic');assert.equal(m.params.objective,undefined);assert.equal(m.params.tokenBudget,undefined);pausedGoals.add(m.params.threadId);goalPauses++;result={goal:{status:'paused'}};break;
    case 'thread/backgroundTerminals/terminate':assert.equal(m.params.processId,'owned-background');stoppedBackground.add(m.params.threadId);backgroundStops++;result={terminated:true};break;
    case 'turn/interrupt':assert.equal(m.params.threadId,ids[0]);assert.equal(m.params.turnId,'turn-'+ids[0]);interrupts++;
     if(mode.startsWith('interrupt-race')){interruptRejected=true;if(mode.endsWith('changed-server'))writeFileSync(directory+'/changed-server','changed');socket.send(JSON.stringify({id:m.id,error:{code:mode.endsWith('wrong-code')?-32000:-32600,message:mode.endsWith('wrong-reason')?'different interruption failure':'no active turn to interrupt'}}));return;}
     result={};break;
    default:throw new Error('Unexpected RPC '+m.method);
   }
   if(mode.startsWith('interrupt-race') && m.params.threadId===ids[0]){
    const active=!interruptRejected || mode.endsWith('still-active') || mode.endsWith('lag')&&settlementReads<3;
    if(m.method==='thread/read'){
     if(interruptRejected)settlementReads++;
     result={thread:{id:ids[0],status:{type:interruptRejected&&mode.endsWith('unknown-status')?'unknown':(!interruptRejected||mode.endsWith('still-active')||mode.endsWith('lag')&&settlementReads<3)?'active':'idle'}}};
    }
    if(m.method==='thread/turns/list')result={data:interruptRejected&&mode.endsWith('missing-turn')?[]:[{id:interruptRejected&&mode.endsWith('changed-turn')?'replacement-turn':'turn-'+ids[0],status:active?'inProgress':'interrupted'}]};
    if(m.method==='thread/goal/get')result={goal:{status:interruptRejected&&mode.endsWith('reactivated')?'active':pausedGoals.has(ids[0])?'paused':'active'}};
    if(m.method==='thread/queue/list'&&mode.endsWith('queue'))result={data:[{id:'queued'}],nextCursor:null};
    if(m.method==='thread/backgroundTerminals/list'&&interruptRejected&&mode.endsWith('background'))result={data:[{processId:'new-owned-background'}],nextCursor:null};
   }
   socket.send(JSON.stringify({id:m.id,result}));
  });
 });
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(directory+'/daemon.sock',resolve);});
 await symlink(directory+'/daemon.sock',directory+'/app-server-control/app-server-control.sock');
 async function run(action){child=spawn(directory+'/check',[directory,cli,action],{stdio:['ignore','pipe','pipe']});let output='',error='';child.stdout.on('data',c=>output+=c);child.stderr.on('data',c=>error+=c);const status=await new Promise(resolve=>child.once('exit',resolve));assert.equal(status,0,error);return JSON.parse(output);}
 assert.equal((await run('interrupt')).verified,true);assert.equal(interrupts,1);
 for(const value of ['queue','background','goal']){mode=value;assert.equal((await run('block')).blocked,true);}
 mode='goal';assert.equal((await run('quiesce')).verified,true);assert.equal(goalPauses,1);
 mode='background';assert.equal((await run('quiesce')).verified,true);assert.equal(backgroundStops,1);assert.equal(interrupts,1,'Idle Goals/background jobs must not send a fake turn interrupt');
 for(const value of ['goal-race','queue-goal','queue-background']){
  mode=value;pausedGoals.clear();stoppedBackground.clear();goalReads.clear();const beforePauses=goalPauses;
  try{assert.equal((await run(value==='goal-race'?'quiesce':'queued-worker')).verified,true);if(value==='goal-race')assert.equal(goalPauses,beforePauses,'A freshly completed Goal must stay complete');}
  catch(error){quiescenceFailures.push(value+': '+error.message.slice(0,300));}
 }
 mode='empty';assert.equal((await run('restart')).verified,true);
 mode='system-error';assert.equal((await run('restart')).verified,true,'A failed dormant conversation must allow login recovery');
 mode='system-error-queue';assert.equal((await run('block')).blocked,true);
 mode='housekeeping';assert.equal((await run('restart')).verified,true,'Internal ephemeral title generation has no retained user conversation');
 for(const value of ['housekeeping-user','housekeeping-unknown','housekeeping-not-ephemeral','housekeeping-bad-id']){mode=value;assert.equal((await run('reject')).rejected,true);}
 for(const value of ['system-error-in-progress','system-error-race','unknown-status','bad-account','duplicate','repeat','empty-code','empty-other','empty-wrong','empty-active','empty-race']){mode=value;assert.equal((await run('reject')).rejected,true);}
 mode='active';// Missing current-turn metadata must be rejected while active.
 // A successful all-idle barrier is the only route to the official lifecycle.
 mode='idle';assert.equal((await run('restart')).verified,true);
 mode='signed-out';assert.equal((await run('restart')).verified,true,'A validated signed-out server must recover using the saved login');
 assert.equal(await readFile(directory+'/restart.log','utf8'),'restart\nrestart\nrestart\nrestart\nrestart\n');
 mode='active';assert.equal((await run('cancel-interrupt')).cancelled,true);assert.equal(interrupts,1,'Cancellation during inspection must not stop a user turn');
 assert.equal(refusals,0,'Account observers must not consume original TUI approval callbacks');
 assert.ok(methods.every(m=>['initialize','initialized','accountSession/list','thread/loaded/list','thread/read','thread/turns/list','thread/queue/list','thread/backgroundTerminals/list','thread/backgroundTerminals/terminate','thread/goal/get','thread/goal/set','turn/interrupt'].includes(m)));
 assert.deepEqual(quiescenceFailures,[],'Quiescence state/queue races');
 const settledInterruptChecks=[];
 for(const [suffix,accepted]of [['idle',true],['lag',true],['queue',true],['changed-turn',false],['missing-turn',false],['still-active',false],['reactivated',false],['background',false],['unknown-status',false],['wrong-code',false],['wrong-reason',false],['changed-server',false]]){
  await rm(directory+'/changed-server',{force:true});mode='interrupt-race-goal-'+suffix;interruptRejected=false;settlementReads=0;pausedGoals.clear();stoppedBackground.clear();goalReads.clear();
  const priorInterrupts=interrupts,priorPauses=goalPauses;
  const result=await run(accepted?'interrupt':'reject-interrupt');assert.equal(result[accepted?'verified':'rejected'],true,suffix);
  assert.equal(interrupts,priorInterrupts+1,'Never retry an interrupted-turn mutation: '+suffix);
  assert.equal(goalPauses,priorPauses+1,'Pause the original Goal exactly once: '+suffix);
  settledInterruptChecks.push(suffix);
 }
 assert.equal(await readFile(directory+'/restart.log','utf8'),'restart\nrestart\nrestart\nrestart\nrestart\n','Interrupt settlement must never restart a server');

 console.log(JSON.stringify({verified:true,checks:['saved metadata from owned stdio helper','complete loaded pagination','exact normal interrupt','queue/background/goal barriers','unknown/malformed/repeated pages fail closed','one official restart after fresh idle barrier','signed-out server accepts saved login','observer preserves original approval callbacks','no resume, prompt or terminal input'],settledInterruptChecks,interrupts}));
} finally {if(child&&child.exitCode===null)child.kill();for(const socket of clients)socket.terminate();websocket.close();server.close();await rm(directory,{recursive:true,force:true});}
