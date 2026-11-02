import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,rm,symlink,writeFile,chmod} from 'node:fs/promises';
import {unlinkSync,symlinkSync} from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const require=createRequire(import.meta.url),module=process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||require.resolve('playwright');
const ws=require(path.join(path.dirname(module),'../playwright-core/lib/utilsBundle.js'));
const build=path.resolve(process.env.AUTOAPPROVE_CHECK_BUILD||'.build/debug');
const directory=await mkdtemp('/private/tmp/aa-account-continue-'),cli=directory+'/codex';
const ids=[1,2,3].map(v=>'00000000-0000-4000-8000-'+String(v).padStart(12,'0'));
const offscreen=process.argv.includes('--offscreen'),mode=process.argv.find(v=>v.startsWith('--race='))?.slice(7),lostAck=process.argv.includes('--lost-ack'),servers=[],clients=new Set();
const active=[true,true,false],turns=['turn-1','turn-2','turn-3'];
let child,goalStatus='active',hydrated=!offscreen,goalPauses=0,goalResumes=0,ordinaryResumes=0,loads=0,raced=false;
const goal=status=>({threadId:ids[0],objective:raced&&mode==='goal'?'Replacement user Goal':'Finish the owned task',status,createdAt:raced&&mode==='goal'?200:100,updatedAt:100,tokenBudget:20000,tokensUsed:200,timeUsedSeconds:12});
const account={activeSessionId:'session-a',sessions:[{sessionId:'session-a',isActive:true,userId:'fixture-user',selectedWorkspaceAccountId:'workspace'}]};
try {
 await mkdir(directory+'/app-server-control');
 await writeFile(cli,`#!${process.execPath}\nimport fs from 'node:fs';import readline from 'node:readline';
const args=process.argv.slice(2),home=process.env.CODEX_HOME;
if(args.join(' ')==='app-server daemon version'){console.log(JSON.stringify({status:'running',backend:'pid',managedCodexPath:process.argv[1],managedCodexVersion:'0.166.0',socketPath:home+'/app-server-control/app-server-control.sock',cliVersion:'0.166.0',appServerVersion:'0.166.0'}));process.exit(0);}
if(args.join(' ')==='app-server daemon restart'){fs.appendFileSync(home+'/restart.log','restart\\n');fs.unlinkSync(home+'/app-server-control/app-server-control.sock');fs.symlinkSync(home+'/daemon-2.sock',home+'/app-server-control/app-server-control.sock');process.exit(0);}
if(args.join(' ')!=='app-server --listen stdio://')process.exit(91);
for await(const line of readline.createInterface({input:process.stdin})){const m=JSON.parse(line);if(m.method==='initialized')continue;let result;if(m.method==='initialize')result={userAgent:'fixture'};else if(m.method==='accountSession/list')result=${JSON.stringify(account)};else process.exit(92);console.log(JSON.stringify({id:m.id,result}));}
`);await chmod(cli,0o700);
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/AccountContinuation'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/codex-account-continuation.swift','-o',directory+'/check'],{stdio:'inherit',timeout:120000});
 for(const serverNumber of [1,2,3]){
  const server=http.createServer(),websocket=new ws.wsServer({noServer:true});servers.push({server,websocket});
  server.on('upgrade',(request,socket,head)=>websocket.handleUpgrade(request,socket,head,c=>websocket.emit('connection',c)));
  websocket.on('connection',socket=>{
   const seen=new Set();let resumeConnection=false;
   clients.add(socket);socket.on('close',()=>clients.delete(socket));
   socket.on('message',bytes=>{
    const m=JSON.parse(bytes.toString());if(m.method==='initialized')return;
    const index=ids.indexOf(m.params?.threadId),id=ids[index];let result;
    if(serverNumber===1&&mode==='completed'&&index===1&&m.method==='thread/read'&&!seen.has('accountSession/list')){
     raced=true;active[1]=false;
    }
    if(serverNumber===2&&m.method==='thread/read'&&seen.has('accountSession/list')&&!seen.has('thread/loaded/list')){
     resumeConnection=true;
     if(index===0&&mode&&!raced){raced=true;if(mode==='turn')turns[0]='new-user-turn';if(mode==='server'){unlinkSync(directory+'/app-server-control/app-server-control.sock');symlinkSync(directory+'/daemon-3.sock',directory+'/app-server-control/app-server-control.sock');}}
    }
    seen.add(m.method);
    const row=()=>({id,source:'cli',threadSource:'user',ephemeral:false,parentThreadId:null,cwd:directory,modelProvider:'fixture',status:{type:serverNumber===2&&offscreen&&index===1&&!hydrated?'notLoaded':active[index]?'active':'idle'}});
    switch(m.method){
     case 'initialize':result={userAgent:'fixture'};break;
     case 'accountSession/list':result=mode==='account'&&resumeConnection?{...account,sessions:[{...account.sessions[0],userId:'changed-user'}]}:account;break;
     case 'thread/loaded/list':result={data:ids.filter((_,i)=>!(serverNumber===2&&offscreen&&i===1&&!hydrated)),nextCursor:null};break;
     case 'thread/read':assert.ok(index>=0);result={thread:row()};break;
     case 'thread/turns/list':result={data:[{id:turns[index],status:active[index]?'inProgress':index===2||mode==='completed'&&index===1?'completed':'interrupted'}],nextCursor:null};break;
     case 'thread/queue/list':result={data:raced&&mode==='queue'&&index===0?[{id:'new-user-queued-input'}]:[],nextCursor:null};break;
     case 'thread/backgroundTerminals/list':result={data:[],nextCursor:null};break;
     case 'thread/goal/get':result={goal:index===0?goal(goalStatus):index===2?{...goal('paused'),threadId:id,objective:'Already paused control',createdAt:100}:null};break;
     case 'thread/goal/set':
      assert.equal(index,0);assert.equal(m.params.objective,undefined);assert.equal(m.params.tokenBudget,undefined);
      if(m.params.status==='paused'){assert.equal(m.params.origin,'automatic');goalPauses++;goalStatus='paused';}
      else {assert.equal(m.params.status,'active');assert.equal(serverNumber,2);goalResumes++;goalStatus='active';active[0]=true;turns[0]='resumed-goal';}
      result={goal:goal(goalStatus)};break;
     case 'turn/interrupt':assert.ok(index===0||index===1);assert.equal(m.params.turnId,turns[index]);active[index]=false;result={};break;
     case 'thread/resume':assert.equal(serverNumber,2);assert.equal(index,1);assert.equal(active[index],false);assert.equal(m.params.model,undefined);assert.equal(m.params.cwd,undefined);hydrated=true;loads++;result={thread:row()};break;
     case 'turn/start':
      assert.equal(serverNumber,2);assert.equal(index,1);assert.equal(active[index],false);assert.ok(hydrated);assert.equal(m.params.input.length,1);assert.ok(m.params.input[0].text.length>0);assert.match(m.params.clientUserMessageId,/^[a-f0-9-]{36}$/i);
      assert.equal(m.params.model,undefined);assert.equal(m.params.cwd,undefined);ordinaryResumes++;active[index]=true;turns[index]='resumed-ordinary';if(lostAck){socket.close();return;}result={turn:{id:turns[index],status:'inProgress',items:[]}};break;
     default:throw Error('Unexpected continuation RPC '+m.method);
    }
    socket.send(JSON.stringify({id:m.id,result}));
   });
  });
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(directory+'/daemon-'+serverNumber+'.sock',resolve);});
 }
 await symlink(directory+'/daemon-1.sock',directory+'/app-server-control/app-server-control.sock');
 const blocked=['account','server'].includes(mode),scenario=blocked?'blocked':lostAck?'lost-ack':mode==='completed'?'completed':mode?'skip':'normal';
 child=spawn(directory+'/check',[directory,cli,scenario],{stdio:['ignore','pipe','pipe']});let output='',error='';child.stdout.on('data',c=>output+=c);child.stderr.on('data',c=>error+=c);
 const status=await new Promise(resolve=>child.once('exit',resolve));assert.equal(status,0,error.slice(0,1800));
 assert.equal(JSON.parse(output).verified,true);assert.equal(goalPauses,1);assert.equal(goalResumes,blocked||mode&&mode!=='completed'?0:1);assert.equal(ordinaryResumes,blocked||mode==='completed'?0:1);assert.equal(loads,offscreen&&mode!=='completed'?1:0);
 console.log(JSON.stringify({verified:true,goalResumes,ordinaryResumes,idlePausedControlUntouched:!active[2],offscreen,mode,lostAck,loads,noConfigOverrides:true,noDuplicateOnRestore:true}));
}finally{
 if(child&&child.exitCode===null)child.kill();for(const socket of clients)socket.terminate();for(const {server,websocket} of servers){websocket.close();server.close();}await rm(directory,{recursive:true,force:true});
}
