import assert from 'node:assert/strict';
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
let mode='active',child,interrupts=0,refusals=0,goalPauses=0,backgroundStops=0;
const pausedGoals=new Set(),stoppedBackground=new Set();
const goalReads=new Map(),quiescenceFailures=[];
try {
 await mkdir(directory+'/app-server-control');
 await writeFile(cli,`#!${process.execPath}\nimport fs from 'node:fs';import readline from 'node:readline';
const args=process.argv.slice(2),home=process.env.CODEX_HOME;
if(args.join(' ')==='app-server daemon version'){if(fs.existsSync(home+'/delay-version'))await new Promise(r=>setTimeout(r,500));console.log(JSON.stringify({status:'running',backend:'pid',managedCodexPath:process.argv[1],managedCodexVersion:'0.166.0',socketPath:home+'/app-server-control/app-server-control.sock',cliVersion:'0.166.0',appServerVersion:'0.166.0'}));process.exit(0);}
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
    case 'accountSession/list':assert.equal(m.params.refreshWorkspaceMetadata,false);result={activeSessionId:'session-old',sessions:[{sessionId:'session-old',isActive:true,userId:'user-old',selectedWorkspaceAccountId:'workspace'}]};if(mode==='bad-account')delete result.sessions[0].userId;break;
    case 'thread/loaded/list':result=mode==='repeat'?{data:[],nextCursor:'repeat'}:mode==='duplicate'?{data:[ids[0],ids[0]]}:m.params.cursor==='next'?{data:[ids[1]],nextCursor:null}:{data:[ids[0]],nextCursor:'next'};break;
    case 'thread/read':reads++;result={thread:{id:m.params.threadId,status:{type:mode==='system-error'?'systemError':((mode==='active'||mode==='empty-active'||mode==='empty-race'&&reads>1)&&m.params.threadId===ids[0])?'active':'idle'}}};break;
    case 'thread/turns/list':if(mode.startsWith('empty')){socket.send(JSON.stringify({id:m.id,error:{code:mode==='empty-code'?-32000:-32600,message:mode==='empty-other'?'different error':`thread ${mode==='empty-wrong'?'unrelated':m.params.threadId} is not materialized yet; thread/turns/list is unavailable before first user message`}}));return;}assert.equal(m.params.itemsView,'notLoaded');assert.equal(m.params.sortDirection,'desc');result={data:mode==='missing-turn'?[]:[{id:'turn-'+m.params.threadId,status:mode==='active'&&m.params.threadId===ids[0]?'inProgress':'completed'}]};break;
    case 'thread/queue/list':result={data:mode.startsWith('queue')?[{id:'queued'}]:[],nextCursor:null};break;
    case 'thread/backgroundTerminals/list':result={data:mode.includes('background')&&!stoppedBackground.has(m.params.threadId)?[{processId:'owned-background'}]:[],nextCursor:null};break;
    case 'thread/goal/get':if(mode==='goal-race'){const n=(goalReads.get(m.params.threadId)||0)+1;goalReads.set(m.params.threadId,n);result={goal:{status:n>=4?'complete':'active'}};}else result={goal:mode.includes('goal')?{status:pausedGoals.has(m.params.threadId)?'paused':'active'}:null};break;
    case 'thread/goal/set':assert.equal(m.params.status,'paused');assert.equal(m.params.origin,'automatic');assert.equal(m.params.objective,undefined);assert.equal(m.params.tokenBudget,undefined);pausedGoals.add(m.params.threadId);goalPauses++;result={goal:{status:'paused'}};break;
    case 'thread/backgroundTerminals/terminate':assert.equal(m.params.processId,'owned-background');stoppedBackground.add(m.params.threadId);backgroundStops++;result={terminated:true};break;
    case 'turn/interrupt':assert.equal(m.params.threadId,ids[0]);assert.equal(m.params.turnId,'turn-'+ids[0]);interrupts++;result={};break;
    default:throw new Error('Unexpected RPC '+m.method);
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
 for(const value of ['system-error','bad-account','duplicate','repeat','empty-code','empty-other','empty-wrong','empty-active','empty-race']){mode=value;assert.equal((await run('reject')).rejected,true);}
 mode='active';// Missing current-turn metadata must be rejected while active.
 // A successful all-idle barrier is the only route to the official lifecycle.
 mode='idle';assert.equal((await run('restart')).verified,true);
 assert.equal(await readFile(directory+'/restart.log','utf8'),'restart\nrestart\n');
 mode='active';assert.equal((await run('cancel-interrupt')).cancelled,true);assert.equal(interrupts,1,'Cancellation during inspection must not stop a user turn');
 assert.ok(refusals>0);
 assert.ok(methods.every(m=>['initialize','initialized','accountSession/list','thread/loaded/list','thread/read','thread/turns/list','thread/queue/list','thread/backgroundTerminals/list','thread/backgroundTerminals/terminate','thread/goal/get','thread/goal/set','turn/interrupt'].includes(m)));
 assert.deepEqual(quiescenceFailures,[],'Quiescence state/queue races');
 console.log(JSON.stringify({verified:true,checks:['saved metadata from owned stdio helper','complete loaded pagination','exact normal interrupt','queue/background/goal barriers','unknown/malformed/repeated pages fail closed','one official restart after fresh idle barrier','no resume, prompt or terminal input'],interrupts}));
} finally {if(child&&child.exitCode===null)child.kill();for(const socket of clients)socket.terminate();websocket.close();server.close();await rm(directory,{recursive:true,force:true});}
