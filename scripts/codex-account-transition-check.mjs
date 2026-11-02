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
let mode='active',child,interrupts=0,refusals=0;
try {
 await mkdir(directory+'/app-server-control');
 await writeFile(cli,`#!${process.execPath}\nimport fs from 'node:fs';import readline from 'node:readline';
const args=process.argv.slice(2),home=process.env.CODEX_HOME;
if(args.join(' ')==='app-server daemon version'){console.log(JSON.stringify({status:'running',backend:'pid',managedCodexPath:process.argv[1],managedCodexVersion:'0.166.0',socketPath:home+'/app-server-control/app-server-control.sock',cliVersion:'0.166.0',appServerVersion:'0.166.0'}));process.exit(0);}
if(args.join(' ')==='app-server daemon restart'){fs.appendFileSync(home+'/restart.log','restart\\n');process.exit(0);}
if(args.join(' ')!=='app-server --listen stdio://')process.exit(91);
for await(const line of readline.createInterface({input:process.stdin})){const m=JSON.parse(line);if(m.method==='initialized')continue;let result;if(m.method==='initialize')result={userAgent:'fixture'};else if(m.method==='accountSession/list'&&m.params.refreshWorkspaceMetadata===false)result={activeSessionId:'session-new',sessions:[{sessionId:'session-new',isActive:true,userId:'user-new',selectedWorkspaceAccountId:'workspace'}]};else process.exit(92);console.log(JSON.stringify({id:m.id,result}));}
`);
 await chmod(cli,0o700);
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/AccountTransport'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/codex-account-transition-transport.swift','-o',directory+'/check'],{stdio:'inherit',timeout:120000});
 server.on('upgrade',(request,socket,head)=>websocket.handleUpgrade(request,socket,head,connection=>websocket.emit('connection',connection)));
 websocket.on('connection',socket=>{
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
    case 'thread/read':result={thread:{id:m.params.threadId,status:{type:mode==='system-error'?'systemError':mode==='active'&&m.params.threadId===ids[0]?'active':'idle'}}};break;
    case 'thread/turns/list':assert.equal(m.params.itemsView,'notLoaded');assert.equal(m.params.sortDirection,'desc');result={data:mode==='missing-turn'?[]:[{id:'turn-'+m.params.threadId,status:mode==='active'&&m.params.threadId===ids[0]?'inProgress':'completed'}]};break;
    case 'thread/queue/list':result={data:mode==='queue'?[{id:'queued'}]:[],nextCursor:null};break;
    case 'thread/backgroundTerminals/list':result={data:mode==='background'?[{processId:'owned-background'}]:[],nextCursor:null};break;
    case 'thread/goal/get':result={goal:mode==='goal'?{status:'active'}:null};break;
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
 for(const value of ['system-error','bad-account','duplicate','repeat']){mode=value;assert.equal((await run('reject')).rejected,true);}
 mode='active';// Missing current-turn metadata must be rejected while active.
 // A successful all-idle barrier is the only route to the official lifecycle.
 mode='idle';assert.equal((await run('restart')).verified,true);
 assert.equal(await readFile(directory+'/restart.log','utf8'),'restart\n');
 assert.ok(refusals>0);
 assert.ok(methods.every(m=>['initialize','initialized','accountSession/list','thread/loaded/list','thread/read','thread/turns/list','thread/queue/list','thread/backgroundTerminals/list','thread/goal/get','turn/interrupt'].includes(m)));
 console.log(JSON.stringify({verified:true,checks:['saved metadata from owned stdio helper','complete loaded pagination','exact normal interrupt','queue/background/goal barriers','unknown/malformed/repeated pages fail closed','one official restart after fresh idle barrier','no resume, prompt or terminal input'],interrupts}));
} finally {if(child&&child.exitCode===null)child.kill();for(const socket of clients)socket.terminate();websocket.close();server.close();await rm(directory,{recursive:true,force:true});}
